import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 0x8F / 255, green: 0xA3 / 255, blue: 0xBF / 255)
    static let bottom = Color(red: 0x4A / 255, green: 0x5A / 255, blue: 0x75 / 255)
    static let accent = Color(red: 0x5B / 255, green: 0x72 / 255, blue: 0x96 / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    /// Above this size data is shown, not edited, as hex.
    static let editableDataLimit = 512
}

struct ContentView: View {
    @ObservedObject var document: PlistDocument
    @StateObject private var editor: Editor
    @Environment(\.undoManager) private var undoManager
    let fileURL: URL?

    init(document: PlistDocument, fileURL: URL?, editor: Editor? = nil) {
        self.document = document
        self.fileURL = fileURL
        _editor = StateObject(wrappedValue: editor ?? Editor(document: document))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch editor.mode {
                case .outline: OutlineTable(editor: editor)
                case .source: SourcePane(editor: editor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StatusBar(editor: editor)
        }
        .frame(minWidth: 640, minHeight: 380)
        .toolbar { toolbar }
        .searchable(text: $editor.search, placement: .toolbar, prompt: "Filter keys and values")
        .modifier(SearchFocus(focused: $editor.searchFocused))
        .focusedSceneObject(editor)
        .onAppear {
            document.undoManager = undoManager
            editor.fileName = fileURL?.lastPathComponent ?? "Untitled"
        }
        .onChange(of: fileURL) { _, url in editor.fileName = url?.lastPathComponent ?? "Untitled" }
        .onChange(of: undoManager) { _, manager in document.undoManager = manager }
        .dropDestination(for: URL.self) { urls, _ in
            guard !Desktop.isSnapshot else { return false }
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
            return !urls.isEmpty
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $editor.mode.animation(.snappy(duration: 0.2))) {
                Label("Outline", systemImage: "list.bullet.indent").tag(EditorMode.outline)
                Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(EditorMode.source)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the outline (⌘1) or the source text (⌘2)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if document.isJSON {
                Text("JSON")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .help("JSON files are saved as JSON. Use Export to write a property list.")
            } else {
                Picker("Format", selection: Binding(get: { document.format }, set: { document.setFormat($0) })) {
                    Text("XML").tag(FileFormat.xml)
                    Text("Binary").tag(FileFormat.binary)
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help("Save as an XML or a binary property list")
            }
            Button { editor.addItem() } label: { Label("Add Item", systemImage: "plus") }
                .help("Add an item (⌘↩)")
            Button { editor.deleteSelection() } label: { Label("Delete Item", systemImage: "minus") }
                .help("Delete the selected item (⌥⌘⌫)")
                .disabled(!editor.canDelete)
        }
    }
}

/// `searchFocused` arrived in macOS 15; on 14 the field still works, ⌘F just does not focus it.
struct SearchFocus: ViewModifier {
    @Binding var focused: Bool
    @FocusState private var field: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .searchFocused($field)
                .onChange(of: focused) { _, now in if now { field = true } }
                .onChange(of: field) { _, now in focused = now }
        } else {
            content
        }
    }
}

// MARK: - Outline

struct OutlineTable: View {
    @ObservedObject var editor: Editor

    var body: some View {
        let rows = editor.rows
        let json = editor.document.isJSON
        Table(rows, selection: $editor.selection) {
            TableColumn("Key") { row in KeyCell(row: row, editor: editor) }
                .width(min: 180, ideal: 280)
            TableColumn("Type") { row in TypeCell(row: row, json: json, editor: editor) }
                .width(min: 110, ideal: 120, max: 150)
            TableColumn("Value") { row in ValueCell(row: row, editor: editor) }
                .width(min: 180, ideal: 380)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onDeleteCommand { editor.deleteSelection() }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Add Item") { editor.selection = id; editor.addItem() }
                Divider()
                Button("Move Up") { editor.selection = id; editor.move(by: -1) }
                Button("Move Down") { editor.selection = id; editor.move(by: 1) }
                Divider()
                Button("Delete") { editor.selection = id; editor.deleteSelection() }
                    .disabled(id == editor.root.id)
            }
        }
        .overlay {
            if rows.count == 1 {
                if editor.search.isEmpty {
                    ContentUnavailableView("No Items", systemImage: "list.bullet.indent",
                                           description: Text("Add a key with ⌘↩ or the + button, or drop a property list or JSON file here."))
                } else {
                    ContentUnavailableView.search(text: editor.search)
                }
            }
        }
    }
}

struct KeyCell: View {
    let row: Row
    @ObservedObject var editor: Editor

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 14)
            if row.type.isContainer && !row.isRoot {
                Button { editor.toggle(row.id) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }
            if row.isRoot {
                Text("Root").fontWeight(.semibold)
            } else if row.inArray {
                Text("Item \(row.index)").foregroundStyle(.secondary).monospacedDigit()
            } else {
                CommitField(value: row.key, autofocus: editor.editRequest == row.id, onFocus: { editor.editRequest = nil }) {
                    editor.setKey(row.id, $0)
                    return true
                }
                if row.isDuplicate {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("Another key in this dictionary has the same name; only one survives saving.")
                }
            }
        }
    }
}

struct TypeCell: View {
    let row: Row
    let json: Bool
    @ObservedObject var editor: Editor

    var body: some View {
        let types = row.isRoot ? [PType.array, .dictionary] : (json ? PType.jsonTypes : PType.plistTypes)
        Menu {
            ForEach(types) { type in
                Button { editor.setType(row.id, type) } label: {
                    if type == row.type { Label(type.label(json: json), systemImage: "checkmark") } else { Text(type.label(json: json)) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: row.type.symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                    .frame(width: 16)
                Text(row.type.label(json: json))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundStyle(.primary)
    }
}

struct ValueCell: View {
    let row: Row
    @ObservedObject var editor: Editor

    var body: some View {
        switch row.value {
        case .dictionary, .array:
            Text(row.value.text).foregroundStyle(.secondary).monospacedDigit()
        case .string(let s):
            CommitField(value: s) { editor.commit(row.id, text: $0) }
        case .integer, .real:
            CommitField(value: row.value.text) { editor.commit(row.id, text: $0) }
        case .boolean(let b):
            let json = editor.document.isJSON
            Menu {
                Button(json ? "true" : "YES") { editor.setValue(row.id, .boolean(true)) }
                Button(json ? "false" : "NO") { editor.setValue(row.id, .boolean(false)) }
            } label: {
                Text(json ? (b ? "true" : "false") : (b ? "YES" : "NO"))
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .foregroundStyle(.primary)
        case .date(let d):
            DatePicker("Date", selection: Binding(get: { d }, set: { editor.setValue(row.id, .date($0)) }),
                       displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .controlSize(.small)
                .fixedSize()
        case .data(let d):
            if d.count <= Theme.editableDataLimit {
                CommitField(value: Format.hex(d), monospaced: true) { editor.commit(row.id, text: $0) }
                    .help("\(Format.bytes(d.count)). Type hex digits; spaces are ignored.")
            } else {
                Text(String(Format.hex(d.prefix(24)).dropLast()) + " …>  " + Format.bytes(d.count))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Large data is shown, not edited, here. Edit it in the source view.")
            }
        case .null:
            Text("null").foregroundStyle(.secondary).font(.system(.body, design: .monospaced))
        }
    }
}

/// A plain text field that commits on Return or when it loses focus, so each edit is one undo step.
/// `commit` returns false to reject the text (it then snaps back with a beep).
struct CommitField: View {
    let value: String
    var monospaced = false
    var autofocus = false
    var onFocus: (() -> Void)? = nil
    let commit: (String) -> Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .lineLimit(1)
            .focused($focused)
            .onAppear {
                text = value
                if autofocus { DispatchQueue.main.async { focused = true } }
            }
            .onChange(of: autofocus) { _, now in if now { DispatchQueue.main.async { focused = true } } }
            .onChange(of: value) { _, new in text = new }
            .onSubmit(save)
            .onChange(of: focused) { _, now in
                if now { onFocus?() } else { save() }
            }
    }

    private func save() {
        guard text != value else { return }
        if !commit(text) {
            NSSound.beep()
            text = value
        }
    }
}

// MARK: - Source

struct SourcePane: View {
    @ObservedObject var editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Theme.gradient)
                if let error = editor.sourceError {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else if editor.sourceEdited {
                    Text("Edited. Apply to update the document.").foregroundStyle(.secondary)
                } else if editor.document.format == .binary {
                    Text("Binary property lists are shown as XML. Saving keeps the binary format.").foregroundStyle(.secondary)
                } else {
                    Text("\(editor.sourceFormatName) source. Edit it here, then apply.").foregroundStyle(.secondary)
                }
                Spacer()
                if editor.sourceEdited {
                    Button("Revert") { editor.regenerateSource() }
                    Button("Apply") { editor.applySource() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .animation(.snappy(duration: 0.2), value: editor.sourceEdited)
            Divider()
            SourceText(text: editor.source, json: editor.document.isJSON) { editor.sourceChanged($0) }
        }
    }
}

/// A plain-text, monospaced, lightly highlighted NSTextView with smart substitutions off.
struct SourceText: NSViewRepresentable {
    let text: String
    let json: Bool
    let changed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false
        view.allowsUndo = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.font = Highlight.font
        view.delegate = context.coordinator
        context.coordinator.set(text, in: view, json: json)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        context.coordinator.set(text, in: view, json: json)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourceText
        init(_ parent: SourceText) { self.parent = parent }

        func set(_ text: String, in view: NSTextView, json: Bool) {
            let selected = view.selectedRanges
            view.string = text
            Highlight.apply(to: view, json: json)
            if (selected.last?.rangeValue.upperBound ?? 0) <= (text as NSString).length { view.selectedRanges = selected }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            Highlight.apply(to: view, json: parent.json)
            parent.changed(view.string)
        }
    }
}

enum Highlight {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    /// Tabs four characters wide, as in Xcode.
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.defaultTabInterval = 4 * ("0" as NSString).size(withAttributes: [.font: font]).width
        style.tabStops = []
        return style
    }()
    private static let tag = try! NSRegularExpression(pattern: "</?[A-Za-z]+[^>]*>|<\\?xml[^>]*>|<!DOCTYPE[^>]*>")
    private static let key = try! NSRegularExpression(pattern: "(?<=<key>)[^<]*(?=</key>)")
    private static let jsonKey = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"(?=\\s*:)")
    private static let jsonString = try! NSRegularExpression(pattern: "(?<!\\w)\"(?:[^\"\\\\]|\\\\.)*\"(?!\\s*:)")
    private static let jsonLiteral = try! NSRegularExpression(pattern: "\\b(?:true|false|null)\\b|-?\\b\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?\\b")

    /// Colours tags and keys; skipped for very large files so typing stays instant.
    @MainActor
    static func apply(to view: NSTextView, json: Bool) {
        guard let storage = view.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph], range: whole)
        if storage.length < 150_000 {
            let s = storage.string
            func paint(_ re: NSRegularExpression, _ color: NSColor) {
                re.enumerateMatches(in: s, range: whole) { m, _, _ in
                    if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
                }
            }
            if json {
                paint(jsonLiteral, .systemOrange)
                paint(jsonString, .systemRed)
                paint(jsonKey, .systemIndigo)
            } else {
                paint(tag, .secondaryLabelColor)
                paint(key, .systemIndigo)
            }
        }
        storage.endEditing()
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var editor: Editor

    var body: some View {
        HStack(spacing: 8) {
            if let url = editor.exported {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.gradient)
                Text("Exported \(url.lastPathComponent)").lineLimit(1)
                Button("Reveal in Finder") { revealInFinder([url]) }.buttonStyle(.link)
                Button { withAnimation(.snappy) { editor.exported = nil } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Dismiss")
            } else {
                path
            }
            Spacer(minLength: 12)
            Text(Format.items(editor.root.count - 1))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: editor.root.count)
            Text("·").foregroundStyle(.tertiary)
            Text(editor.document.format.longName)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    @ViewBuilder private var path: some View {
        if let sel = editor.selection, let nodes = editor.root.path(to: sel) {
            HStack(spacing: 4) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                    if i > 0 { Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary) }
                    Text(label(nodes, i))
                        .foregroundStyle(i == nodes.count - 1 ? .primary : .secondary)
                        .lineLimit(1)
                }
            }
            .truncationMode(.head)
        } else {
            Text("No selection").foregroundStyle(.tertiary)
        }
    }

    private func label(_ nodes: [PNode], _ i: Int) -> String {
        if i == 0 { return "Root" }
        let parent = nodes[i - 1]
        if parent.isDictionary { return nodes[i].key.isEmpty ? "\"\"" : nodes[i].key }
        return "Item \(parent.children?.firstIndex { $0.id == nodes[i].id } ?? 0)"
    }
}
