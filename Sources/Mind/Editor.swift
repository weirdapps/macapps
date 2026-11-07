import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

/// Everything one window knows beyond the document: selection, the topic being typed, the viewport and a drag.
/// Every change to the map goes through `change`, which registers one undo step restoring the previous map.
@MainActor
final class Editor: ObservableObject {
    let document: MindDocument
    weak var undoManager: UndoManager?
    weak var catcher: KeyCatcherView?
    var fileURL: URL?

    @Published var selection: UUID
    @Published var editingID: UUID?
    @Published var draft = ""
    @Published var viewport = Viewport(size: .zero)
    @Published var drag: DragState?
    @Published var exported: URL?

    /// When the topic being typed was just added, the map and selection before it, so cancel can drop it
    /// and commit can record add and text as a single undo step.
    private var pendingNew: (id: UUID, map: MindMap, selection: UUID)?
    private(set) var selectAllOnEdit = true
    private var hasFitted = false

    struct DragState: Equatable {
        var id: UUID
        var location: CGPoint
        var target: UUID?
    }

    init(document: MindDocument, selection: UUID? = nil) {
        self.document = document
        self.selection = selection ?? document.map.root.id
    }

    var map: MindMap { document.map }

    var layout: MapLayout {
        let editing = editingID, text = draft
        return MapLayout.make(document.map) { node, depth in
            Style.measure(node.id == editing ? text : node.text, depth: depth)
        }
    }

    var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? map.root.text
    }

    // MARK: Changes and undo

    private func apply(_ map: MindMap, selection: UUID) {
        withAnimation(.snappy(duration: 0.28)) {
            document.map = map
            self.selection = map.node(selection) == nil ? map.root.id : selection
        }
    }

    func change(_ name: String, select: UUID? = nil, _ body: (inout MindMap) -> Void) {
        let before = document.map, beforeSelection = selection
        var after = before
        body(&after)
        guard after != before else { return }
        apply(after, selection: select ?? selection)
        registerUndo(name, restoring: before, selection: beforeSelection)
    }

    private func registerUndo(_ name: String, restoring map: MindMap, selection: UUID) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated {
                editor.finishEditing()
                let redoMap = editor.document.map, redoSelection = editor.selection
                editor.apply(map, selection: selection)
                editor.registerUndo(name, restoring: redoMap, selection: redoSelection)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: Selection and navigation

    func select(_ id: UUID) {
        if editingID != nil, editingID != id { commitEditing(refocus: false) }
        selection = id
        focusCanvas()
    }

    func go(_ direction: Direction) {
        finishEditing()
        let layout = self.layout
        if let next = layout.neighbour(of: selection, direction, in: map) {
            selection = next
            ensureVisible(next)
            return
        }
        // Arrowing outward into a collapsed topic opens it.
        guard direction == .left || direction == .right, let node = map.node(selection), node.collapsed,
              let f = layout.frames[selection], f.side == 0 || f.side == (direction == .right ? 1 : -1) else { return }
        change("Expand") { $0.toggleCollapsed(node.id) }
    }

    // MARK: Structure

    func addChild() {
        finishEditing()
        startNew { $0.addChild(to: selection) }
    }

    func addSibling() {
        finishEditing()
        startNew { $0.addSibling(after: selection) }
    }

    private func startNew(_ add: (inout MindMap) -> UUID?) {
        let before = document.map, beforeSelection = selection
        var after = before
        guard let id = add(&after) else { return }
        apply(after, selection: id)
        pendingNew = (id, before, beforeSelection)
        beginEditing(id, initial: "")
    }

    var canDelete: Bool { selection != map.root.id }

    func deleteSelection() {
        finishEditing()
        guard canDelete else { return NSSound.beep() }
        let id = selection
        var next: UUID?
        change("Delete Topic") { next = $0.remove(id) }
        if let next { selection = next }
    }

    var canToggle: Bool { !(map.node(selection)?.children.isEmpty ?? true) }

    func toggleCollapse() {
        finishEditing()
        guard let node = map.node(selection), !node.children.isEmpty else { return NSSound.beep() }
        change(node.collapsed ? "Expand" : "Collapse") { $0.toggleCollapsed(node.id) }
    }

    func setAllCollapsed(_ collapsed: Bool) {
        finishEditing()
        let keep = selection
        change(collapsed ? "Collapse All" : "Expand All") { $0.setAllCollapsed(collapsed) }
        // A selection hidden inside a collapsed branch moves up to the visible main branch.
        if layout.frames[keep] == nil, let path = map.root.path(to: keep), let first = path.first {
            selection = map.root.children[first].id
        }
    }

    // MARK: Typing

    func beginEditing(_ id: UUID, initial: String? = nil) {
        guard let node = map.node(id) else { return }
        selection = id
        draft = initial ?? node.text
        selectAllOnEdit = initial == nil
        editingID = id
        ensureVisible(id)
    }

    /// Ends typing, keeping the text. Committing an empty new topic drops it again.
    func commitEditing(refocus: Bool = true) {
        guard let id = editingID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        if let pending = pendingNew, pending.id == id {
            pendingNew = nil
            if text.isEmpty {
                apply(pending.map, selection: pending.selection)
            } else {
                var after = document.map
                after.setText(id, text)
                apply(after, selection: id)
                registerUndo("Add Topic", restoring: pending.map, selection: pending.selection)
            }
        } else if !text.isEmpty, text != map.node(id)?.text {
            change("Edit Topic") { $0.setText(id, text) }
        }
        if refocus { focusCanvas() }
    }

    func cancelEditing() {
        guard editingID != nil else { return }
        editingID = nil
        if let pending = pendingNew {
            pendingNew = nil
            apply(pending.map, selection: pending.selection)
        }
        focusCanvas()
    }

    /// Commits any typing before another command acts on the map.
    func finishEditing() {
        if editingID != nil { commitEditing(refocus: false) }
    }

    // MARK: Clipboard

    func copySelection() {
        guard let node = map.node(selection) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Outline.markdown(branch: node), forType: .string)
    }

    func cutSelection() {
        guard canDelete else { return NSSound.beep() }
        copySelection()
        deleteSelection()
    }

    var canPaste: Bool { NSPasteboard.general.string(forType: .string)?.isEmpty == false }

    /// Pastes an outline (or plain lines) as children of the selection.
    func paste(_ text: String? = NSPasteboard.general.string(forType: .string)) {
        finishEditing()
        guard let text else { return }
        let items = Outline.forest(text)
        guard !items.isEmpty else { return NSSound.beep() }
        let parent = selection
        change("Paste", select: items[0].id) { m in
            for item in items { m.addChild(to: parent, item) }
        }
    }

    // MARK: Dragging topics

    func dragChanged(_ id: UUID, at location: CGPoint) {
        if editingID != nil { commitEditing(refocus: false) }
        let layout = self.layout
        let excluded = layout.branch(of: id, in: map)
        var target = layout.node(at: viewport.world(location), excluding: excluded)
        if target == map.parent(of: id)?.id { target = nil }
        drag = DragState(id: id, location: location, target: target)
    }

    func dragEnded() {
        guard let drag else { return }
        self.drag = nil
        if let target = drag.target {
            change("Move Topic", select: drag.id) { $0.move(drag.id, to: target) }
        }
        focusCanvas()
    }

    // MARK: Viewport

    func setViewSize(_ size: CGSize) {
        guard size != viewport.size, size.width > 0, size.height > 0 else { return }
        viewport.size = size
        if !hasFitted {
            hasFitted = true
            viewport.fit(layout.bounds)
        }
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let point = anchor ?? CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2)
        viewport.zoom(to: viewport.scale * factor, around: point)
    }

    func actualSize() {
        viewport.zoom(to: 1, around: CGPoint(x: viewport.size.width / 2, y: viewport.size.height / 2))
    }

    func fit() { viewport.fit(layout.bounds) }

    func pan(by delta: CGSize) {
        viewport.offset.width += delta.width
        viewport.offset.height += delta.height
    }

    /// Pans just enough to bring a topic fully into view.
    func ensureVisible(_ id: UUID) {
        guard viewport.size.width > 0, let frame = layout.frames[id] else { return }
        let r = viewport.screen(frame.rect).insetBy(dx: -40, dy: -40)
        var dx: CGFloat = 0, dy: CGFloat = 0
        if r.minX < 0 { dx = -r.minX } else if r.maxX > viewport.size.width { dx = viewport.size.width - r.maxX }
        if r.minY < 0 { dy = -r.minY } else if r.maxY > viewport.size.height { dy = viewport.size.height - r.maxY }
        guard dx != 0 || dy != 0 else { return }
        withAnimation(.snappy(duration: 0.25)) { pan(by: CGSize(width: dx, height: dy)) }
    }

    func focusCanvas() {
        guard let catcher else { return }
        DispatchQueue.main.async { catcher.window?.makeFirstResponder(catcher) }
    }

    // MARK: Keys

    /// Keys typed on the canvas. The Node menu normally handles the structural keys first; this is the fallback,
    /// and the path for typing a letter to start replacing the selected topic's text.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty || mods == .option else { return false }
        switch event.keyCode {
        case 48: addChild(); return true
        case 36, 76: addSibling(); return true
        case 49: toggleCollapse(); return true
        case 51, 117: deleteSelection(); return true
        case 123: go(.left); return true
        case 124: go(.right); return true
        case 125: go(.down); return true
        case 126: go(.up); return true
        case 53: return true
        default: break
        }
        guard let chars = event.characters, let scalar = chars.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !(0xF700...0xF8FF).contains(scalar.value) else { return false }
        beginEditing(selection, initial: chars)
        return true
    }

    // MARK: Export

    func exportMarkdown() {
        finishEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = title + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Outline.markdown(map).write(to: url, atomically: true, encoding: .utf8)
            didExport(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportPNG() {
        finishEditing()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = title + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = Self.png(of: map) else { return NSSound.beep() }
        do {
            try data.write(to: url)
            didExport(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The whole map, expanded branches only, drawn at 2x on a light background.
    static func png(of map: MindMap) -> Data? {
        let layout = MapLayout.make(map) { Style.measure($0.text, depth: $1) }
        let renderer = ImageRenderer(content: MapArtwork(map: map, layout: layout).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private func didExport(_ url: URL) {
        withAnimation(.snappy) { exported = url }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard self?.exported == url else { return }
            withAnimation(.snappy) { self?.exported = nil }
        }
    }

    /// Opens a Markdown outline as a new, untitled map.
    static func importMarkdown(newDocument: NewDocumentAction) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let map = Outline.map(fromMarkdown: text, title: url.deletingPathExtension().lastPathComponent)
            newDocument { MindDocument(map: map) }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - Keyboard and scroll

/// The canvas's first responder. Takes keys, scroll wheel and pinch, and answers the Node menu and Copy/Paste
/// through the responder chain, so those menu items are enabled only while the canvas has focus (never while typing).
final class KeyCatcherView: NSView, NSMenuItemValidation {
    weak var editor: Editor?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        if editor?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            let handled = MainActor.assumeIsolated { self?.handle(incoming) == true }
            return handled ? nil : event
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !(window.firstResponder is NSTextView) else { return }
            window.makeFirstResponder(self)
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let editor, let window, event.window === window, window.attachedSheet == nil else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        if event.type == .magnify {
            editor.zoom(by: 1 + event.magnification, around: point)
        } else if event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            editor.zoom(by: exp(dy * 0.01), around: point)
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            editor.pan(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
        }
        return true
    }

    @objc func mindAddChild(_ sender: Any?) { editor?.addChild() }
    @objc func mindAddSibling(_ sender: Any?) { editor?.addSibling() }
    @objc func mindEdit(_ sender: Any?) { if let e = editor { e.beginEditing(e.selection) } }
    @objc func mindToggle(_ sender: Any?) { editor?.toggleCollapse() }
    @objc func mindExpandAll(_ sender: Any?) { editor?.setAllCollapsed(false) }
    @objc func mindCollapseAll(_ sender: Any?) { editor?.setAllCollapsed(true) }
    @objc func mindLeft(_ sender: Any?) { editor?.go(.left) }
    @objc func mindRight(_ sender: Any?) { editor?.go(.right) }
    @objc func mindUp(_ sender: Any?) { editor?.go(.up) }
    @objc func mindDown(_ sender: Any?) { editor?.go(.down) }
    @objc func mindDelete(_ sender: Any?) { editor?.deleteSelection() }
    @objc func delete(_ sender: Any?) { editor?.deleteSelection() }
    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) { editor?.cutSelection() }
    @objc func paste(_ sender: Any?) { editor?.paste() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor, editor.editingID == nil else { return false }
        switch item.action {
        case #selector(mindToggle(_:)):
            item.title = editor.map.node(editor.selection)?.collapsed == true ? "Expand Topic" : "Collapse Topic"
            return editor.canToggle
        case #selector(mindDelete(_:)), #selector(delete(_:)), #selector(cut(_:)): return editor.canDelete
        case #selector(paste(_:)): return editor.canPaste
        default: return true
        }
    }
}

struct KeyCatcher: NSViewRepresentable {
    let editor: Editor

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.editor = editor
        editor.catcher = view
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.editor = editor
    }
}

/// The Node menu, built in AppKit so its plain keys (Tab, Return, Space, arrows, Delete) go through
/// the responder chain: they reach the canvas and never steal keys from a text field or a save sheet.
@MainActor
enum NodeMenu {
    static let title = "Node"

    static func install() {
        guard let main = NSApp.mainMenu, main.item(withTitle: title) == nil, main.items.count > 2 else { return }
        let menu = NSMenu(title: title)
        func add(_ name: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: name, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            menu.addItem(item)
        }
        func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
        add("Add Child", #selector(KeyCatcherView.mindAddChild(_:)), "\t")
        add("Add Sibling", #selector(KeyCatcherView.mindAddSibling(_:)), "\r")
        add("Edit Topic", #selector(KeyCatcherView.mindEdit(_:)), "\r", .command)
        menu.addItem(.separator())
        add("Collapse Topic", #selector(KeyCatcherView.mindToggle(_:)), " ")
        add("Collapse All", #selector(KeyCatcherView.mindCollapseAll(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])
        add("Expand All", #selector(KeyCatcherView.mindExpandAll(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])
        menu.addItem(.separator())
        add("Select Left", #selector(KeyCatcherView.mindLeft(_:)), arrow(NSLeftArrowFunctionKey))
        add("Select Right", #selector(KeyCatcherView.mindRight(_:)), arrow(NSRightArrowFunctionKey))
        add("Select Up", #selector(KeyCatcherView.mindUp(_:)), arrow(NSUpArrowFunctionKey))
        add("Select Down", #selector(KeyCatcherView.mindDown(_:)), arrow(NSDownArrowFunctionKey))
        menu.addItem(.separator())
        add("Delete Topic", #selector(KeyCatcherView.mindDelete(_:)), String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        let window = main.items.firstIndex { $0.title == "Window" } ?? main.items.count - 1
        main.insertItem(item, at: window)
    }
}

// MARK: - Inline text field

/// The text field over a topic while typing. Return commits, Tab commits and adds a child, Escape cancels.
struct NodeTextField: NSViewRepresentable {
    @ObservedObject var editor: Editor
    let font: NSFont
    let color: NSColor

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    /// Takes focus as soon as it is in a window, placing the caret at the end or selecting everything.
    final class Field: NSTextField {
        var selectAllOnFocus = true
        private var focused = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !focused, let window else { return }
            focused = true
            guard window.makeFirstResponder(self), let text = currentEditor() else { return }
            let length = (stringValue as NSString).length
            text.selectedRange = selectAllOnFocus ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
        }
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Field(string: editor.draft)
        field.selectAllOnFocus = editor.selectAllOnEdit
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = font
        field.textColor = color
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.placeholderString = Style.placeholder
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.font != font { field.font = font }
        field.textColor = color
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let editor: Editor
        init(editor: Editor) { self.editor = editor }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            editor.draft = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                editor.commitEditing()
            case #selector(NSResponder.insertTab(_:)):
                editor.commitEditing(refocus: false)
                editor.addChild()
            case #selector(NSResponder.cancelOperation(_:)):
                editor.cancelEditing()
            default:
                return false
            }
            return true
        }

        func controlTextDidEndEditing(_ note: Notification) {
            if editor.editingID != nil { editor.commitEditing(refocus: false) }
        }
    }
}
