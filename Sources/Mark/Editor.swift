import AppKit
import Kit
import PDFKit
import SwiftUI

// MARK: - Theme

enum Theme {
    static let top = Color(nsColor: rgb(0x4F7DF3))
    static let bottom = Color(nsColor: rgb(0x2343A6))
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    /// Accent for text: deep enough to read on white, light enough to read on dark grey.
    static let accentText = dynamic(0x2F5BD8, 0x8AA9FF)
    static let codeText = dynamic(0x8A3FB8, 0xD2A6F5)
    static let editorBackground = dynamic(0xF8F9FB, 0x1D1E21)
    static let previewBackground = dynamic(0xFFFFFF, 0x242528)
    static var accent: Color { Color(nsColor: accentText) }
}

// MARK: - Highlighting

/// Light syntax colouring for the source: structure in the accent, markup characters dimmed.
enum Highlighter {
    static let size: CGFloat = 13.5
    static let regular = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    static let bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    static let italic = withTraits(regular, .italic)
    static let boldItalic = withTraits(bold, [.italic, .bold])

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.22
        return p
    }()

    static var base: [NSAttributedString.Key: Any] {
        [.font: regular, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    private static func withTraits(_ font: NSFont, _ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
    static let heading = rx("^ {0,3}(#{1,6})(?=[ \\t]|$).*$")
    static let quote = rx("^[ \\t]*(?:>[ \\t]?)+")
    static let listMarker = rx("^[ \\t]*(?:>[ \\t]?)*[ \\t]*([-*+]|\\d{1,9}[.)])(?=[ \\t])")
    static let task = rx("^[ \\t]*(?:>[ \\t]?)*[ \\t]*(?:[-*+]|\\d{1,9}[.)])[ \\t]+(\\[[ xX]\\])")
    static let rule = rx("^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    static let strong = rx("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    static let emphasis = rx("(?<![\\*\\w])\\*(?=[^\\s*])([^*\\n]+?)(?<=[^\\s*])\\*(?!\\*)|(?<![_\\w])_(?=[^\\s_])([^_\\n]+?)(?<=[^\\s_])_(?![_\\w])")
    static let strike = rx("~~(?=\\S)(.+?)(?<=\\S)~~")
    static let link = rx("(!?\\[)([^\\]\\n]*)(\\]\\()([^)\\n]*)(\\))")
    static let code = rx("(`+)(?!`)(.+?)(?<!`)\\1(?!`)")
    static let table = rx("^[ \\t]*\\|?(?:[ \\t]*:?-+:?[ \\t]*\\|)+[ \\t]*:?-*:?[ \\t]*$")

    static func apply(_ ts: NSTextStorage) {
        let s = ts.string as NSString
        let full = NSRange(location: 0, length: s.length)
        guard full.length > 0 else { return }
        let dim = NSColor.tertiaryLabelColor
        let accent = Theme.accentText

        ts.beginEditing()
        ts.setAttributes(base, range: full)

        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            regex.enumerateMatches(in: ts.string, range: full) { m, _, _ in if let m { body(m) } }
        }
        func color(_ r: NSRange, _ c: NSColor) { if r.location != NSNotFound { ts.addAttribute(.foregroundColor, value: c, range: r) } }
        func trait(_ r: NSRange, bold makeBold: Bool = false, italic makeItalic: Bool = false) {
            ts.enumerateAttribute(.font, in: r) { value, sub, _ in
                let f = value as? NSFont
                let isBold = makeBold || f == bold || f == boldItalic
                let isItalic = makeItalic || f == italic || f == boldItalic
                ts.addAttribute(.font, value: isBold ? (isItalic ? boldItalic : bold) : (isItalic ? italic : regular), range: sub)
            }
        }

        each(heading) { m in
            trait(m.range, bold: true)
            color(m.range, accent)
            color(m.range(at: 1), accent.withAlphaComponent(0.45))
        }
        each(quote) { m in
            let line = s.lineRange(for: m.range)
            color(line, .secondaryLabelColor)
            color(m.range, accent)
        }
        each(listMarker) { m in
            color(m.range(at: 1), accent)
            trait(m.range(at: 1), bold: true)
        }
        each(task) { m in color(m.range(at: 1), accent) }
        each(rule) { m in color(m.range, dim) }
        each(table) { m in color(m.range, dim) }
        each(strong) { m in
            trait(m.range, bold: true)
            color(NSRange(location: m.range.location, length: 2), dim)
            color(NSRange(location: m.range.upperBound - 2, length: 2), dim)
        }
        each(emphasis) { m in
            trait(m.range, italic: true)
            color(NSRange(location: m.range.location, length: 1), dim)
            color(NSRange(location: m.range.upperBound - 1, length: 1), dim)
        }
        each(strike) { m in
            ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 1))
            color(m.range, .secondaryLabelColor)
        }
        each(link) { m in
            color(m.range(at: 1), dim)
            color(m.range(at: 2), accent)
            color(m.range(at: 3), dim)
            color(m.range(at: 4), .secondaryLabelColor)
            color(m.range(at: 5), dim)
        }
        each(code) { m in
            ts.addAttributes([.font: regular, .foregroundColor: Theme.codeText], range: m.range)
            color(m.range(at: 1), dim)
            color(NSRange(location: m.range.upperBound - m.range(at: 1).length, length: m.range(at: 1).length), dim)
        }

        // Fenced code last, so nothing inside it is styled as Markdown.
        var location = 0
        var fence: String?
        while location < s.length {
            let line = s.lineRange(for: NSRange(location: location, length: 0))
            let trimmed = s.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if let f = fence {
                if trimmed.hasPrefix(f), trimmed.allSatisfy({ $0 == f.first! }) {
                    ts.setAttributes(base, range: line)
                    color(line, dim)
                    fence = nil
                } else {
                    ts.setAttributes(base, range: line)
                    color(line, Theme.codeText)
                }
            } else if MarkdownParser.leadingSpaces(s.substring(with: line)) < 4, let open = MarkdownParser.fenceOpening(trimmed) {
                fence = open.marker
                ts.setAttributes(base, range: line)
                color(line, dim)
            }
            location = line.upperBound
        }
        ts.endEditing()
    }
}

// MARK: - Session

enum ViewMode: String, CaseIterable, Identifiable {
    case editor, preview, both
    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor Only"
        case .preview: "Preview Only"
        case .both: "Editor and Preview"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "text.alignleft"
        case .preview: "eye"
        case .both: "rectangle.split.2x1"
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .editor: "1"
        case .preview: "2"
        case .both: "3"
        }
    }
}

/// Per-window state: the parsed blocks, the counts, the layout and the export actions the menus call.
@MainActor
final class EditorSession: ObservableObject {
    @Published private(set) var blocks: [Block]
    @Published private(set) var stats: TextStats
    @Published var mode: ViewMode {
        didSet { if !Desktop.isSnapshot { UserDefaults.standard.set(mode.rawValue, forKey: "viewMode") } }
    }
    @Published var split: CGFloat = 0.5
    @Published var exported: URL?

    weak var textView: NSTextView?
    var fileURL: URL?
    private(set) var text: String
    private var pending: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(text: String, fileURL: URL?) {
        self.text = text
        self.fileURL = fileURL
        let blocks = MarkdownParser.parse(text)
        self.blocks = blocks
        stats = TextStats(source: text, blocks: blocks)
        let saved = Desktop.isSnapshot ? nil : UserDefaults.standard.string(forKey: "viewMode")
        mode = saved.flatMap(ViewMode.init(rawValue:)) ?? .both
    }

    var baseURL: URL? { fileURL?.deletingLastPathComponent() }
    var name: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var canFormat: Bool { textView != nil && mode != .preview }

    /// Reparses shortly after typing pauses, so long documents stay responsive.
    func textChanged(_ new: String) {
        guard new != text else { return }
        text = new
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.reparse()
        }
    }

    private func reparse() {
        let blocks = MarkdownParser.parse(text)
        if blocks != self.blocks { self.blocks = blocks }
        stats = TextStats(source: text, blocks: blocks)
    }

    // MARK: Editing

    /// Applies an edit through the text view, so it is undoable and marks the document edited.
    func perform(_ edit: TextEdit) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard tv.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        tv.didChangeText()
        tv.setSelectedRange(edit.selection)
        tv.scrollRangeToVisible(edit.selection)
        if mode != .preview { tv.window?.makeFirstResponder(tv) }
    }

    func wrap(_ marker: String) {
        guard let tv = textView else { return }
        perform(Formatting.toggleWrap(tv.string, tv.selectedRange(), marker: marker))
    }

    func link() {
        guard let tv = textView else { return }
        perform(Formatting.link(tv.string, tv.selectedRange()))
    }

    func heading(_ level: Int) {
        guard let tv = textView else { return }
        perform(Formatting.heading(tv.string, tv.selectedRange(), level: level))
    }

    func toggleTask(_ index: Int) {
        guard let tv = textView, let edit = Formatting.toggleTask(tv.string, index: index) else { return }
        let keep = tv.selectedRange()
        perform(edit)
        tv.setSelectedRange(keep)
    }

    // MARK: Export

    private var currentBlocks: [Block] { MarkdownParser.parse(textView?.string ?? text) }

    private var title: String {
        for case .heading(1, let t) in currentBlocks { return Inline.plain(t) }
        return name
    }

    func exportHTML() {
        let html = HTMLExporter.document(currentBlocks, title: title)
        save(type: "html", data: Data(html.utf8))
    }

    func exportPDF() {
        save(type: "pdf", data: PDFExporter.pdf(currentBlocks, baseURL: baseURL))
    }

    func printDocument() {
        let data = PDFExporter.pdf(currentBlocks, baseURL: baseURL)
        guard let doc = PDFDocument(data: data),
              let op = doc.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleNone, autoRotate: false) else { return }
        op.jobTitle = name
        if let window = textView?.window ?? NSApp.keyWindow {
            op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }

    private func save(type: String, data: Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name).\(type)"
        panel.allowedContentTypes = [type == "pdf" ? .pdf : .html]
        panel.canCreateDirectories = true
        if let dir = baseURL { panel.directoryURL = dir }
        let write: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                self?.showExported(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window = textView?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    private func showExported(_ url: URL) {
        withAnimation(.snappy) { exported = url }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.exported = nil }
        }
    }
}

// MARK: - Editor view

/// The source editor: an AppKit text view, for undo, find, spelling and fast highlighting.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let session: EditorSession

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = !Desktop.isSnapshot
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 22, height: 20)
        tv.backgroundColor = Theme.editorBackground
        tv.insertionPointColor = Theme.accentText
        tv.font = Highlighter.regular
        tv.typingAttributes = Highlighter.base
        tv.setAccessibilityLabel("Markdown source")
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.scrollerStyle = .overlay
        tv.string = text
        if let storage = tv.textStorage { Highlighter.apply(storage) }
        tv.delegate = context.coordinator
        session.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        session.textView = tv
        if tv.string != text {
            // The document changed underneath us (Revert, or another app): reload, keeping the cursor where it can stay.
            let selection = tv.selectedRange()
            tv.string = text
            if let storage = tv.textStorage { Highlighter.apply(storage) }
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Leave text being composed (an accent dead key, an input method) alone until it is committed.
            if !tv.hasMarkedText(), let storage = tv.textStorage { Highlighter.apply(storage) }
            tv.typingAttributes = Highlighter.base
            parent.text = tv.string
        }
    }
}
