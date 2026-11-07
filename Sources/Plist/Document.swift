import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PlistSnapshot: Sendable {
    var root: PNode
    var format: FileFormat
}

/// A property list or JSON file. Every change goes through `replace`, which registers undo and so marks the document edited.
final class PlistDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.propertyList, .xmlPropertyList, .binaryPropertyList, .json]
    static let writableContentTypes: [UTType] = [.propertyList, .json]

    @Published private(set) var root: PNode
    /// The format the file is saved in: the one it was opened in, unless the user converts it.
    @Published private(set) var format: FileFormat
    weak var undoManager: UndoManager?

    init(root: PNode = PNode(key: "Root", value: .dictionary([])), format: FileFormat = .xml) {
        self.root = root
        self.format = format
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        (root, format) = try Codec.read(data)
        if configuration.contentType.conforms(to: .json) && format != .json {
            format = .json
        }
    }

    func snapshot(contentType: UTType) throws -> PlistSnapshot {
        PlistSnapshot(root: root, format: Self.format(for: contentType, current: format))
    }

    func fileWrapper(snapshot: PlistSnapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try Codec.encode(snapshot.root, as: snapshot.format))
    }

    /// The bytes to write for a file type: JSON for .json, otherwise the document's plist format.
    static func format(for contentType: UTType, current: FileFormat) -> FileFormat {
        if contentType.conforms(to: .json) { return .json }
        return current == .json ? .xml : current
    }

    var isJSON: Bool { format == .json }

    /// Applies a change to the tree as one undoable step named `name`. Does nothing when the tree does not change.
    func update(_ name: String, _ change: (inout PNode) -> Void) {
        var new = root
        change(&new)
        guard new != root else { return }
        replace(root: new, format: format, name: name)
    }

    func setFormat(_ new: FileFormat) {
        guard new != format else { return }
        replace(root: root, format: new, name: "Change Format")
    }

    func replace(root newRoot: PNode, format newFormat: FileFormat, name: String) {
        let oldRoot = root, oldFormat = format
        root = newRoot
        format = newFormat
        undoManager?.registerUndo(withTarget: self) { doc in
            doc.replace(root: oldRoot, format: oldFormat, name: name)
        }
        undoManager?.setActionName(name)
    }
}

enum EditorMode: String, CaseIterable, Identifiable {
    case outline, source
    var id: String { rawValue }
}

/// Per-window state: selection, open containers, view mode, filter and the source text being edited.
@MainActor
final class Editor: ObservableObject {
    let document: PlistDocument
    @Published var selection: UUID?
    @Published var expanded: Set<UUID> = []
    @Published var mode: EditorMode = .outline {
        didSet { if mode == .source && oldValue != .source && !sourceEdited { regenerateSource() } }
    }
    @Published var search = ""
    @Published var searchFocused = false
    @Published var exported: URL?
    var fileName = "Untitled"
    /// The new entry whose key field should start editing.
    @Published var editRequest: UUID?
    @Published var source = ""
    @Published var sourceError: String?
    @Published private(set) var sourceEdited = false
    private var observer: AnyCancellable?

    init(document: PlistDocument) {
        self.document = document
        observer = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            DispatchQueue.main.async { self?.documentChanged() }
        }
    }

    var root: PNode { document.root }
    var rows: [Row] { Outline.rows(document.root, expanded: expanded, filter: search) }
    var selectedNode: PNode? { selection.flatMap { document.root.node($0) } }

    private var selectionLocation: (parent: UUID, index: Int)? { selection.flatMap { document.root.location(of: $0) } }

    var canDelete: Bool { selection != nil && selection != root.id && mode == .outline }

    var canMoveUp: Bool {
        guard mode == .outline, let loc = selectionLocation else { return false }
        return loc.index > 0
    }

    var canMoveDown: Bool {
        guard mode == .outline, let loc = selectionLocation, let siblings = root.node(loc.parent)?.children else { return false }
        return loc.index < siblings.count - 1
    }

    // MARK: Editing

    /// Adds an entry: inside the selected container when it is open (or is the root), after the selection otherwise.
    func addItem() {
        mode = .outline
        search = ""
        let root = document.root
        var parent = root.id, index = root.children?.count ?? 0
        if let sel = selection, let node = root.node(sel) {
            if node.children != nil && (sel == root.id || expanded.contains(sel)) {
                parent = sel
                index = sel == root.id ? (node.children?.count ?? 0) : 0
            } else if let loc = root.location(of: sel) {
                parent = loc.parent
                index = loc.index + 1
            }
        }
        guard let container = root.node(parent), let siblings = container.children else { return }
        let item = PNode(key: container.isDictionary ? PNode.uniqueKey("New item", in: siblings) : "", value: .string(""))
        document.update("Add Item") { $0.insert(item, in: parent, at: index) }
        expanded.insert(parent)
        selection = item.id
        editRequest = item.id
    }

    func deleteSelection() {
        guard canDelete, let sel = selection, let loc = root.location(of: sel) else { return }
        let siblings = root.node(loc.parent)?.children ?? []
        let next: UUID = siblings.count > 1 ? siblings[loc.index + 1 < siblings.count ? loc.index + 1 : loc.index - 1].id : loc.parent
        document.update("Delete Item") { $0.remove(sel) }
        selection = next
    }

    func move(by offset: Int) {
        guard let sel = selection else { return }
        document.update(offset < 0 ? "Move Up" : "Move Down") { $0.move(sel, by: offset) }
    }

    func setKey(_ id: UUID, _ key: String) {
        document.update("Rename Key") { $0.modify(id) { $0.key = key } }
    }

    func setValue(_ id: UUID, _ value: PValue) {
        document.update("Edit Value") { $0.modify(id) { $0.value = value } }
    }

    func setType(_ id: UUID, _ type: PType) {
        document.update("Change Type") { $0.modify(id) { $0.value = $0.value.converted(to: type) } }
        if type.isContainer { expanded.insert(id) }
    }

    /// Commits typed text for a scalar. Returns false (and changes nothing) when the text does not fit the type.
    func commit(_ id: UUID, text: String) -> Bool {
        guard let node = root.node(id) else { return false }
        let value: PValue?
        switch node.value {
        case .string: value = .string(text)
        case .integer: value = Format.number(text, preferReal: text.contains(".") || text.lowercased().contains("e"))
        case .real: value = Format.number(text, preferReal: true)
        case .data: value = Format.parseHex(text).map(PValue.data)
        default: value = nil
        }
        guard let value else { return false }
        setValue(id, value)
        return true
    }

    func toggle(_ id: UUID) {
        withAnimation(.snappy(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    func expandAll() {
        var ids = Set<UUID>()
        func walk(_ n: PNode) {
            guard let c = n.children else { return }
            ids.insert(n.id)
            c.forEach(walk)
        }
        walk(root)
        expanded = ids
    }

    func collapseAll() {
        expanded = []
        if let sel = selection, let path = root.path(to: sel), path.count > 2 { selection = path[1].id }
    }

    // MARK: Source

    var sourceFormatName: String { document.isJSON ? "JSON" : "XML" }

    func regenerateSource() {
        source = document.isJSON ? Codec.json(root) : Codec.xml(root)
        sourceEdited = false
        sourceError = nil
    }

    func sourceChanged(_ text: String) {
        source = text
        sourceEdited = true
        sourceError = nil
    }

    func applySource() {
        do {
            let parsed = document.isJSON ? try Codec.parseJSON(Data(source.utf8)) : try Codec.parseXML(Data(source.utf8))
            if !parsed.isSame(as: root) {
                document.replace(root: PNode(id: root.id, key: parsed.key, value: parsed.value), format: document.format, name: "Edit Source")
            }
            regenerateSource()
        } catch {
            sourceError = error.localizedDescription
            NSSound.beep()
        }
    }

    private func documentChanged() {
        if mode == .source && !sourceEdited { regenerateSource() }
        if let sel = selection, root.node(sel) == nil { selection = nil }
    }

    // MARK: Export

    /// Writes a copy in another format next to wherever the user picks, then offers Reveal in Finder in the status bar.
    func export() {
        let name = fileName
        let panel = NSSavePanel()
        let picker = ExportFormatPicker(panel: panel, initial: document.isJSON ? .xml : .json)
        panel.accessoryView = picker.view
        panel.nameFieldStringValue = (name as NSString).deletingPathExtension + "." + picker.format.fileExtension
        panel.allowedContentTypes = [picker.format == .json ? .json : .propertyList]
        panel.canSelectHiddenExtension = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Codec.encode(root, as: picker.format).write(to: url, options: .atomic)
            withAnimation(.snappy) { exported = url }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The format popup under the export panel; switching it updates the file extension.
@MainActor
final class ExportFormatPicker: NSObject {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton()
    let view: NSView
    private(set) var format: FileFormat

    init(panel: NSSavePanel, initial: FileFormat) {
        self.panel = panel
        format = initial
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: FileFormat.allCases.map(\.longName))
        popup.selectItem(at: FileFormat.allCases.firstIndex(of: initial) ?? 0)
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        format = FileFormat.allCases[popup.indexOfSelectedItem]
        guard let panel else { return }
        panel.allowedContentTypes = [format == .json ? .json : .propertyList]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + format.fileExtension
    }
}
