import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Launch plan.md", size: CGSize(width: 1080, height: 680)) {
    ContentView(document: .constant(MarkDocument(text: Demo.text)), fileURL: nil)
}
MarkApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {}

struct MarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: MarkDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Mark")
            MarkCommands()
        }
    }
}

// MARK: - Window

struct ContentView: View {
    @Binding var document: MarkDocument
    let fileURL: URL?
    @StateObject private var session: EditorSession

    init(document: Binding<MarkDocument>, fileURL: URL?) {
        _document = document
        self.fileURL = fileURL
        _session = StateObject(wrappedValue: EditorSession(text: document.wrappedValue.text, fileURL: fileURL))
    }

    var body: some View {
        VStack(spacing: 0) {
            SplitLayout(session: session) {
                MarkdownEditor(text: $document.text, session: session)
                    .overlay(alignment: .topLeading) {
                        if document.text.isEmpty {
                            Text("# Start writing")
                                .font(.system(size: Highlighter.size, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 27)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }
            } preview: {
                PreviewView(blocks: session.blocks)
                    .background(Color(nsColor: Theme.previewBackground))
            }
            Divider()
            StatusBar(stats: session.stats)
        }
        .overlay(alignment: .bottom) { ExportToast(url: session.exported) }
        .environment(\.documentBase, session.baseURL)
        .environment(\.toggleTask) { [weak session] in session?.toggleTask($0) }
        .tint(Theme.accent)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Layout", selection: $session.mode) {
                    ForEach(ViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .help("Show the editor, the preview or both (Command 1, 2, 3)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export as HTML\u{2026}") { session.exportHTML() }
                    Button("Export as PDF\u{2026}") { session.exportPDF() }
                    Divider()
                    Button("Print\u{2026}") { session.printDocument() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export as HTML or PDF, or print")
            }
        }
        .focusedSceneObject(session)
        .onChange(of: document.text) { _, new in session.textChanged(new) }
        .onChange(of: fileURL) { _, new in session.fileURL = new }
        .onChange(of: session.mode) { _, mode in
            guard let tv = session.textView else { return }
            if mode == .preview {
                if tv.window?.firstResponder === tv { tv.window?.makeFirstResponder(nil) }
            } else {
                DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

/// Editor and preview side by side with a draggable divider. Both stay alive in every mode,
/// so switching layouts keeps the cursor, the scroll position and the undo history.
struct SplitLayout<Editor: View, Preview: View>: View {
    @ObservedObject var session: EditorSession
    @ViewBuilder var editor: Editor
    @ViewBuilder var preview: Preview
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    private let minimum: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let editorWidth: CGFloat = switch session.mode {
            case .editor: total
            case .preview: 0
            case .both: min(max(total * session.split, minimum), max(minimum, total - minimum))
            }
            HStack(spacing: 0) {
                editor
                    .frame(width: editorWidth)
                    .clipped()
                    .opacity(editorWidth > 0 ? 1 : 0)
                    .allowsHitTesting(editorWidth > 0)
                    .accessibilityHidden(editorWidth == 0)
                if session.mode == .both {
                    Rectangle()
                        .fill(hovering || dragStart != nil ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color(nsColor: .separatorColor)))
                        .frame(width: hovering || dragStart != nil ? 2 : 1)
                        .overlay {
                            Color.clear
                                .frame(width: 10)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    hovering = inside
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(DragGesture(minimumDistance: 1)
                                    .onChanged { value in
                                        let start = dragStart ?? editorWidth
                                        dragStart = start
                                        session.split = min(max((start + value.translation.width) / total, 0.2), 0.8)
                                    }
                                    .onEnded { _ in dragStart = nil })
                                .onTapGesture(count: 2) { withAnimation(.snappy) { session.split = 0.5 } }
                        }
                        .zIndex(1)
                }
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(session.mode == .editor ? 0 : 1)
                    .allowsHitTesting(session.mode != .editor)
                    .accessibilityHidden(session.mode == .editor)
            }
            .animation(dragStart == nil ? .snappy(duration: 0.28) : nil, value: session.mode)
        }
    }
}

struct StatusBar: View {
    let stats: TextStats

    var body: some View {
        HStack(spacing: 16) {
            item(stats.words, stats.words == 1 ? "word" : "words")
            item(stats.characters, stats.characters == 1 ? "character" : "characters")
            item(stats.minutes, "min read")
            Spacer()
            Text("Markdown")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.gradient))
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
        .animation(.snappy, value: stats)
    }

    private func item(_ value: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value.formatted())
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: Double(value)))
            Text(label)
        }
    }
}

struct ExportToast: View {
    let url: URL?

    var body: some View {
        if let url {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.gradient).font(.system(size: 15))
                Text("Exported \(url.lastPathComponent)").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Button("Show in Finder") { revealInFinder([url]) }
                    .buttonStyle(.link)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Menus

struct MarkCommands: Commands {
    @FocusedObject private var session: EditorSession?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Export as HTML\u{2026}") { session?.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session == nil)
            Button("Export as PDF\u{2026}") { session?.exportPDF() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(session == nil)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") { session?.printDocument() }
                .keyboardShortcut("p")
                .disabled(session == nil)
        }
        CommandGroup(before: .toolbar) {
            ForEach(ViewMode.allCases) { mode in
                Toggle(mode.title, isOn: Binding(get: { session?.mode == mode }, set: { if $0 { session?.mode = mode } }))
                    .keyboardShortcut(mode.key)
                    .disabled(session == nil)
            }
            Divider()
        }
        CommandMenu("Format") {
            let off = !(session?.canFormat ?? false)
            Button("Bold") { session?.wrap("**") }.keyboardShortcut("b").disabled(off)
            Button("Italic") { session?.wrap("_") }.keyboardShortcut("i").disabled(off)
            Button("Strikethrough") { session?.wrap("~~") }.keyboardShortcut("x", modifiers: [.command, .shift]).disabled(off)
            Button("Inline Code") { session?.wrap("`") }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(off)
            Button("Link") { session?.link() }.keyboardShortcut("k").disabled(off)
            Divider()
            Button("Heading 1") { session?.heading(1) }.keyboardShortcut("1", modifiers: [.command, .option]).disabled(off)
            Button("Heading 2") { session?.heading(2) }.keyboardShortcut("2", modifiers: [.command, .option]).disabled(off)
            Button("Heading 3") { session?.heading(3) }.keyboardShortcut("3", modifiers: [.command, .option]).disabled(off)
            Button("Body Text") { session?.heading(0) }.keyboardShortcut("0", modifiers: [.command, .option]).disabled(off)
        }
    }
}

// MARK: - Icon

//: the Markdown mark, an M and a down arrow, on a paper card with a folded corner

func appIcon() -> NSBitmapImageRep {
    render(0x4F7DF3, 0x2343A6) { ctx in
        let card = CGRect(x: 172, y: 262, width: 680, height: 500)
        let r: CGFloat = 64, fold: CGFloat = 120

        let paper = CGMutablePath()
        paper.move(to: CGPoint(x: card.minX + r, y: card.minY))
        paper.addArc(tangent1End: CGPoint(x: card.maxX, y: card.minY), tangent2End: CGPoint(x: card.maxX, y: card.maxY), radius: r)
        paper.addLine(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        paper.addLine(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        paper.addArc(tangent1End: CGPoint(x: card.minX, y: card.maxY), tangent2End: CGPoint(x: card.minX, y: card.minY), radius: r)
        paper.addArc(tangent1End: CGPoint(x: card.minX, y: card.minY), tangent2End: CGPoint(x: card.maxX, y: card.minY), radius: r)
        paper.closeSubpath()

        // Card with a soft drop shadow.
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 44, alpha: 0.38)
        ctx.addPath(paper)
        ctx.setFillColor(rgb(0xFFFFFF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(paper)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE9EEFA)], from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY), in: ctx)
        ctx.restoreGState()

        // The folded corner.
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: card.maxX - fold, y: card.maxY))
        flap.addArc(tangent1End: CGPoint(x: card.maxX - fold, y: card.maxY - fold), tangent2End: CGPoint(x: card.maxX, y: card.maxY - fold), radius: 26)
        flap.addLine(to: CGPoint(x: card.maxX, y: card.maxY - fold))
        flap.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 16, alpha: 0.22)
        ctx.addPath(flap)
        ctx.setFillColor(rgb(0xCBD5EE).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(flap)
        ctx.clip()
        gradient([rgb(0xF4F7FF), rgb(0xBFCBEA)], from: CGPoint(x: card.maxX - fold, y: card.maxY - fold),
                 to: CGPoint(x: card.maxX - fold * 0.5, y: card.maxY - fold * 0.5), in: ctx)
        ctx.restoreGState()

        // The glyphs: a bold M and a down arrow, in the tile's blue.
        let glyph = CGMutablePath()
        let base: CGFloat = 372, top: CGFloat = 652, x0: CGFloat = 230, stroke: CGFloat = 76, mid: CGFloat = 390
        glyph.addLines(between: [
            CGPoint(x: x0, y: base), CGPoint(x: x0, y: top), CGPoint(x: x0 + stroke, y: top),
            CGPoint(x: mid, y: 548), CGPoint(x: 2 * mid - x0 - stroke, y: top), CGPoint(x: 2 * mid - x0, y: top),
            CGPoint(x: 2 * mid - x0, y: base), CGPoint(x: 2 * mid - x0 - stroke, y: base),
            CGPoint(x: 2 * mid - x0 - stroke, y: 518), CGPoint(x: mid, y: 430), CGPoint(x: x0 + stroke, y: 518),
            CGPoint(x: x0 + stroke, y: base),
        ])
        glyph.closeSubpath()
        let ax: CGFloat = 690
        glyph.addLines(between: [
            CGPoint(x: ax - 44, y: top), CGPoint(x: ax + 44, y: top), CGPoint(x: ax + 44, y: 512),
            CGPoint(x: ax + 104, y: 512), CGPoint(x: ax, y: base), CGPoint(x: ax - 104, y: 512),
            CGPoint(x: ax - 44, y: 512),
        ])
        glyph.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: rgb(0x1A2F7A, 0.35).cgColor)
        ctx.addPath(glyph)
        ctx.setFillColor(rgb(0x2F55CC).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(glyph)
        ctx.clip()
        gradient([rgb(0x5C87F7), rgb(0x2343A6)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: base), in: ctx)
        // A thin highlight along the top edge of the glyphs.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.fill(CGRect(x: 0, y: top - 10, width: 1024, height: 10))
        ctx.restoreGState()
    }
}
