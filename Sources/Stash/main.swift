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
    let store = SnippetStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "square.stack.3d.up.fill", accessibilityLabel: "Stash") {
            StashView().environmentObject(self.store)
        }
        store.onCopied = { [weak self] in self?.status.close() }
        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: cmdKey | optionKey) { [weak self] in self?.status.toggle() }
    }
}

// MARK: - Model

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var uses = 0
}

@MainActor
final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] { didSet { Storage.save(snippets, app: "Stash", file: "snippets.json") } }
    @Published var query = ""
    /// The snippet being edited; a new one has an id not yet in `snippets`.
    @Published var editing: Snippet?
    var onCopied: (() -> Void)?

    init() {
        snippets = Storage.load([Snippet].self, app: "Stash", file: "snippets.json") ?? SnippetStore.samples
    }

    var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snippets }
        return snippets.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.text.localizedCaseInsensitiveContains(q) }
    }

    func copy(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.text, forType: .string)
        if let i = snippets.firstIndex(where: { $0.id == snippet.id }) { snippets[i].uses += 1 }
        HUD.show(symbol: "doc.on.clipboard.fill", title: "Copied", tint: Color(red: 0.48, green: 0.38, blue: 0.95))
        query = ""
        onCopied?()
    }

    func newSnippet() {
        let clip = NSPasteboard.general.string(forType: .string) ?? ""
        editing = Snippet(title: "", text: clip.count < 2000 ? clip : "")
    }

    func save(_ snippet: Snippet) {
        var s = snippet
        s.title = s.title.trimmingCharacters(in: .whitespaces)
        if s.title.isEmpty { s.title = Snippet.derivedTitle(s.text) }
        if let i = snippets.firstIndex(where: { $0.id == s.id }) { snippets[i] = s } else { snippets.insert(s, at: 0) }
        editing = nil
    }

    func delete(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        if editing?.id == snippet.id { editing = nil }
    }

    func move(_ snippet: Snippet, by offset: Int) {
        guard let i = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let j = i + offset
        guard snippets.indices.contains(j) else { return }
        snippets.swapAt(i, j)
    }

    /// Moves `dragged` to the slot `target` occupies; used by drag and drop.
    func move(_ dragged: UUID, onto target: UUID) {
        guard dragged != target, let from = snippets.firstIndex(where: { $0.id == dragged }),
              let to = snippets.firstIndex(where: { $0.id == target }) else { return }
        snippets.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    static let samples = [
        Snippet(title: "Email signature", text: "Best regards,\nYour Name\nyou@example.com"),
        Snippet(title: "Meeting link", text: "https://meet.example.com/your-room"),
        Snippet(title: "Shrug", text: "¯\\_(ツ)_/¯"),
        Snippet(title: "Thanks", text: "Thanks for getting back to me so quickly. I will take a look and reply by tomorrow."),
    ]
}

extension Snippet {
    static func derivedTitle(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "Untitled" : String(first.prefix(40))
    }
}

extension Color {
    static let stash = [Color(red: 0.62, green: 0.55, blue: 1), Color(red: 0.36, green: 0.25, blue: 0.85)]
}

// MARK: - Views

struct StashView: View {
    @EnvironmentObject var store: SnippetStore

    var body: some View {
        VStack(spacing: 0) {
            if let editing = store.editing {
                EditorView(draft: editing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                ListPane()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Stash", shortcut: "⌥⌘S") {
                Button("New Snippet") { withAnimation(.snappy) { store.newSnippet() } }.keyboardShortcut("n")
            }
        }
        .frame(width: 360, height: 440)
        .animation(.snappy(duration: 0.25), value: store.editing == nil)
    }
}

struct ListPane: View {
    @EnvironmentObject var store: SnippetStore
    @FocusState private var searchFocused: Bool
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Stash").font(.system(size: 17, weight: .bold, design: .rounded))
                Text("\(store.snippets.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(LinearGradient(colors: Color.stash, startPoint: .top, endPoint: .bottom)))
                    .contentTransition(.numericText())
                Spacer()
                GlassIconButton("plus", help: "New snippet from the clipboard (⌘N)") {
                    withAnimation(.snappy) { store.newSnippet() }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search snippets", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { if let first = store.filtered.first { store.copy(first) } }
                if !store.query.isEmpty {
                    Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if store.snippets.isEmpty {
                EmptyState(symbol: "square.stack.3d.up", text: "Save text you type often, then copy it with one click.")
            } else if store.filtered.isEmpty {
                EmptyState(symbol: "magnifyingglass", text: "No snippet matches \u{201C}\(store.query)\u{201D}.")
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.filtered) { snippet in
                            SnippetRow(snippet: snippet)
                                .opacity(dragging == snippet.id ? 0.4 : 1)
                                .onDrag {
                                    dragging = snippet.id
                                    return NSItemProvider(object: snippet.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: RowDrop(target: snippet.id, dragging: $dragging, store: store))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

struct RowDrop: DropDelegate {
    let target: UUID
    @Binding var dragging: UUID?
    let store: SnippetStore

    func dropEntered(info: DropInfo) {
        guard let dragging, store.query.isEmpty else { return }
        withAnimation(.snappy(duration: 0.2)) { store.move(dragging, onto: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct EmptyState: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 30)
        .frame(maxWidth: .infinity)
    }
}

struct SnippetRow: View {
    @EnvironmentObject var store: SnippetStore
    let snippet: Snippet
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(snippet.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hovering {
                HStack(spacing: 2) {
                    RowButton(symbol: "pencil", help: "Edit") { withAnimation(.snappy) { store.editing = snippet } }
                    RowButton(symbol: "trash", help: "Delete") { withAnimation(.snappy) { store.delete(snippet) } }
                }
                .transition(.opacity)
            } else {
                Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0.3)))
        .contentShape(Rectangle())
        .onTapGesture { store.copy(snippet) }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Click to copy")
        .contextMenu {
            Button("Copy") { store.copy(snippet) }
            Button("Edit") { store.editing = snippet }
            Divider()
            Button("Move Up") { withAnimation(.snappy) { store.move(snippet, by: -1) } }
            Button("Move Down") { withAnimation(.snappy) { store.move(snippet, by: 1) } }
            Divider()
            Button("Delete", role: .destructive) { withAnimation(.snappy) { store.delete(snippet) } }
        }
    }
}

struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary.opacity(hovering ? 0.9 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
    }
}

struct EditorView: View {
    @EnvironmentObject var store: SnippetStore
    @State var draft: Snippet
    @FocusState private var titleFocused: Bool

    private var isNew: Bool { !store.snippets.contains { $0.id == draft.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { withAnimation(.snappy) { store.editing = nil } } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(isNew ? "New Snippet" : "Edit Snippet").font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            TextField("Name", text: $draft.title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
                .focused($titleFocused)
            TextEditor(text: $draft.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { withAnimation(.snappy) { store.delete(draft) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("\(draft.text.count) characters").font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                Button("Save") { withAnimation(.snappy) { store.save(draft) } }
                    .buttonStyle(PillButtonStyle(Color.stash))
                    .keyboardShortcut("s")
                    .disabled(draft.text.isEmpty)
                    .opacity(draft.text.isEmpty ? 0.5 : 1)
            }
        }
        .padding(14)
        .onAppear { DispatchQueue.main.async { titleFocused = true } }
    }
}

// MARK: - Icon

//: a fanned stack of snippet cards

func appIcon() -> NSBitmapImageRep {
    render(0xA08CFF, 0x4B2FC9) { ctx in
        let card = CGRect(x: -220, y: -150, width: 440, height: 300)
        func drawCard(at p: CGPoint, angle: CGFloat, fill: NSColor, lines: Bool) {
            ctx.saveGState()
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.saveGState()
            shadow(ctx, y: -16, blur: 30, alpha: 0.3)
            ctx.addPath(roundedRect(card, 46))
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if lines {
                // A title bar and two lines of text.
                ctx.setLineCap(.round)
                ctx.setStrokeColor(rgb(0x6A55E8).cgColor)
                ctx.setLineWidth(30)
                ctx.move(to: CGPoint(x: card.minX + 60, y: card.maxY - 76)); ctx.addLine(to: CGPoint(x: card.minX + 210, y: card.maxY - 76))
                ctx.strokePath()
                ctx.setStrokeColor(rgb(0xC9C0F5).cgColor)
                ctx.setLineWidth(22)
                for (i, w) in [250.0, 190].enumerated() {
                    let y = card.maxY - 150 - CGFloat(i) * 54
                    ctx.move(to: CGPoint(x: card.minX + 60, y: y)); ctx.addLine(to: CGPoint(x: card.minX + 60 + w, y: y))
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        drawCard(at: CGPoint(x: 530, y: 650), angle: 8, fill: rgb(0xD9D1FF, 0.75), lines: false)
        drawCard(at: CGPoint(x: 505, y: 545), angle: -4, fill: rgb(0xEDE9FF, 0.92), lines: false)
        drawCard(at: CGPoint(x: 512, y: 425), angle: 0, fill: .white, lines: true)
        // A bookmark ribbon on the front card.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 12, alpha: 0.25)
        let r = CGMutablePath()
        r.move(to: CGPoint(x: 640, y: 575))
        r.addLine(to: CGPoint(x: 640, y: 435))
        r.addLine(to: CGPoint(x: 675, y: 467))
        r.addLine(to: CGPoint(x: 710, y: 435))
        r.addLine(to: CGPoint(x: 710, y: 575))
        r.closeSubpath()
        ctx.addPath(r)
        ctx.setFillColor(rgb(0xFF6B9A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
