import AppKit
import Carbon.HIToolbox
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    private var hotKey: HotKey?
    let store = NoteStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "square.and.pencil", accessibilityLabel: "Jot") {
            JotView().environmentObject(self.store)
        }
        hotKey = HotKey(keyCode: kVK_ANSI_J, modifiers: cmdKey | optionKey) { [weak self] in self?.status.toggle() }
    }

    func applicationWillTerminate(_ notification: Notification) { store.saveNow() }
}

// MARK: - Model

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text = ""
    var updated = Date()

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Empty page" : first
    }
}

@MainActor
final class NoteStore: ObservableObject {
    @Published var notes: [Note] { didSet { scheduleSave() } }
    @Published var selection: UUID

    private var saveWork: DispatchWorkItem?

    init() {
        let loaded = Storage.load([Note].self, app: "Jot", file: "notes.json") ?? []
        let notes = loaded.isEmpty ? [Note(text: NoteStore.welcome)] : loaded
        self.notes = notes
        selection = notes[0].id
    }

    var index: Int { notes.firstIndex { $0.id == selection } ?? 0 }

    var current: Binding<String> {
        Binding(get: { self.notes[self.index].text },
                set: { self.notes[self.index].text = $0; self.notes[self.index].updated = Date() })
    }

    func add() {
        let note = Note()
        notes.append(note)
        selection = note.id
    }

    func deleteCurrent() {
        let i = index
        notes.remove(at: i)
        if notes.isEmpty { notes = [Note()] }
        selection = notes[min(i, notes.count - 1)].id
    }

    func select(offset: Int) {
        selection = notes[(index + offset + notes.count) % notes.count].id
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() { Storage.save(notes, app: "Jot", file: "notes.json") }

    static let welcome = """
    Welcome to Jot

    A scratchpad that lives in your menu bar. Press ⌥⌘J from anywhere to open it, type, and press Esc to get back to work.

    Everything saves as you type. Add pages with ＋ and flip between them with ⌘[ and ⌘].
    """
}

// MARK: - Views

struct JotView: View {
    @EnvironmentObject var store: NoteStore
    @FocusState private var editorFocused: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            TextEditor(text: store.current)
                .font(.system(size: 14, design: .default))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .focused($editorFocused)
            HStack {
                Spacer()
                Text(stats)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            Divider().opacity(0.5)
            PanelFooter(name: "Jot", shortcut: "⌥⌘J") {
                Button("New Page") { store.add() }.keyboardShortcut("n")
                Button("Delete Page", role: .destructive) { store.deleteCurrent() }
            }
        }
        .frame(width: 400, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { editorFocused = true }
        }
        .background {
            // Invisible buttons for page navigation shortcuts.
            Group {
                Button("") { store.select(offset: -1) }.keyboardShortcut("[")
                Button("") { store.select(offset: 1) }.keyboardShortcut("]")
                Button("") { store.add() }.keyboardShortcut("n")
            }
            .opacity(0)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.notes.enumerated()), id: \.element.id) { offset, note in
                        PageTab(number: offset + 1, title: note.title, selected: note.id == store.selection) {
                            withAnimation(.snappy(duration: 0.2)) { store.selection = note.id }
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            GlassIconButton("plus", help: "New page (⌘N)") { withAnimation(.snappy) { store.add() } }
            GlassIconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy page") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.current.wrappedValue, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var stats: String {
        let text = store.current.wrappedValue
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return "\(words) word\(words == 1 ? "" : "s") · \(text.count) characters"
    }
}

struct PageTab: View {
    let number: Int
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(selected ? .white : .secondary)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary)))
                if selected {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: 140, alignment: .leading)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, selected ? 9 : 4)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary.opacity(selected ? 0.7 : (hovering ? 0.4 : 0))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .onHover { hovering = $0 }
    }
}

extension Color {
    static let accentGradient = LinearGradient(colors: [Color(red: 1, green: 0.78, blue: 0.2), Color(red: 1, green: 0.58, blue: 0.05)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a ruled note card and a pencil

func appIcon() -> NSBitmapImageRep {
    render(0xFFD84F, 0xFF9500) { ctx in
        ctx.saveGState()
        ctx.translateBy(x: 470, y: 520)
        ctx.rotate(by: 6 * .pi / 180)
        let card = CGRect(x: -250, y: -290, width: 500, height: 580)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.28)
        ctx.addPath(roundedRect(card, 44))
        ctx.setFillColor(rgb(0xFFFDF4).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(card, 44))
        ctx.clip()
        // Header band.
        ctx.setFillColor(rgb(0xFFF1C9).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 110, width: card.width, height: 110))
        // Ruled lines and the margin.
        ctx.setStrokeColor(rgb(0xBFD7F2).cgColor)
        ctx.setLineWidth(5)
        for i in 0..<7 {
            let y = card.maxY - 160 - CGFloat(i) * 62
            ctx.move(to: CGPoint(x: card.minX, y: y)); ctx.addLine(to: CGPoint(x: card.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0xFF8A80).cgColor)
        ctx.move(to: CGPoint(x: card.minX + 88, y: card.minY)); ctx.addLine(to: CGPoint(x: card.minX + 88, y: card.maxY))
        ctx.strokePath()
        // Handwriting, as soft strokes.
        ctx.setStrokeColor(rgb(0x5B6B82, 0.75).cgColor)
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        for (i, w) in [300.0, 240, 330, 170].enumerated() {
            let y = card.maxY - 160 - CGFloat(i) * 62 + 22
            ctx.move(to: CGPoint(x: card.minX + 120, y: y)); ctx.addLine(to: CGPoint(x: card.minX + 120 + w, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Pencil, laid diagonally across the lower right, drawn as one shadowed layer.
        ctx.saveGState()
        ctx.translateBy(x: 610, y: 380)
        ctx.rotate(by: 40 * .pi / 180)
        shadow(ctx, y: -14, blur: 24, alpha: 0.35)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(roundedRect(CGRect(x: -370, y: -42, width: 90, height: 84), 26))
        ctx.setFillColor(rgb(0xFF7AA2).cgColor)
        ctx.fillPath()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -300, y: -42, width: 72, height: 84))
        gradient([rgb(0xF2F4F7), rgb(0x9AA4B1)], from: CGPoint(x: 0, y: 42), to: CGPoint(x: 0, y: -42), in: ctx)
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x3A7BFF).cgColor)
        ctx.fill(CGRect(x: -230, y: -42, width: 360, height: 84))
        ctx.setFillColor(rgb(0x6FA0FF).cgColor)
        ctx.fill(CGRect(x: -230, y: 6, width: 360, height: 22))
        ctx.setFillColor(rgb(0x2A5FD6).cgColor)
        ctx.fill(CGRect(x: -230, y: -42, width: 360, height: 18))
        // Sharpened wood and graphite tip.
        ctx.move(to: CGPoint(x: 130, y: 42)); ctx.addLine(to: CGPoint(x: 250, y: 0)); ctx.addLine(to: CGPoint(x: 130, y: -42))
        ctx.closePath()
        ctx.setFillColor(rgb(0xF5CFA0).cgColor)
        ctx.fillPath()
        ctx.move(to: CGPoint(x: 210, y: 14)); ctx.addLine(to: CGPoint(x: 250, y: 0)); ctx.addLine(to: CGPoint(x: 210, y: -14))
        ctx.closePath()
        ctx.setFillColor(rgb(0x2B2F36).cgColor)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
