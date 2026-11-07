import AppKit
import Kit
import SwiftUI

// The tree itself is an NSOutlineView: lazy rows, native disclosure, type-ahead and keyboard navigation, and it
// stays smooth with millions of nodes where a SwiftUI list would not.

enum TypeStyle {
    static func color(_ kind: JSONKind) -> NSColor {
        switch kind {
        case .object: Theme.keyColor
        case .array: .systemOrange
        case .string: .systemRed
        case .number: .systemBlue
        case .bool: .systemPurple
        case .null: .systemGray
        }
    }

    static func swiftUI(_ kind: JSONKind) -> Color { Color(nsColor: color(kind)) }
}

/// Wraps a node id so NSOutlineView can track it by identity.
final class NodeItem: NSObject {
    let id: Int32
    init(_ id: Int32) { self.id = id }
}

struct TreeOutline: NSViewRepresentable {
    @ObservedObject var model: ViewerModel

    func makeCoordinator() -> OutlineController { OutlineController(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        let outline = CanopyOutlineView()
        outline.controller = controller
        let column = NSTableColumn(identifier: .init("node"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .inset
        outline.rowHeight = 24
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.usesAutomaticRowHeights = false
        outline.allowsEmptySelection = true
        outline.dataSource = controller
        outline.delegate = controller
        outline.target = controller
        outline.doubleAction = #selector(OutlineController.doubleClicked(_:))
        outline.menu = controller.contextMenu()
        outline.setAccessibilityLabel("JSON tree")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        controller.outline = outline
        model.outline = controller
        controller.reload()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        model.outline = context.coordinator
        if context.coordinator.tree !== model.tree { context.coordinator.reload() }
        if context.coordinator.query != model.query { context.coordinator.refreshVisible() }
    }
}

final class CanopyOutlineView: NSOutlineView {
    weak var controller: OutlineController?

    @objc func copy(_ sender: Any?) {
        guard selectedRow >= 0 else { NSSound.beep(); return }
        MainActor.assumeIsolated { controller?.model.copyValue() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return row >= 0 ? super.menu(for: event) : nil
    }
}

@MainActor
final class OutlineController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var model: ViewerModel
    weak var outline: NSOutlineView?
    private(set) var tree: JSONTree?
    private(set) var query = ""
    private var items: [Int32: NodeItem] = [:]
    private var syncing = false
    /// Expanding more rows than this at once would stall the window; Expand All stops there and says so.
    static let rowBudget = 60_000

    init(model: ViewerModel) { self.model = model }

    func item(_ id: Int32) -> NodeItem {
        if let item = items[id] { return item }
        let item = NodeItem(id)
        items[id] = item
        return item
    }

    func reload() {
        guard let outline else { return }
        tree = model.tree
        items = [:]
        query = model.query
        outline.reloadData()
        guard let tree, tree.count > 0 else { return }
        switch model.initialExpansion {
        case .level(let level): expand(toLevel: level, quiet: true)
        case .nodes(let ids):
            for id in ids { outline.expandItem(item(id)) }
        }
        if let selected = model.selected { reveal(selected) }
        DispatchQueue.main.async { [weak outline] in
            guard let outline, let window = outline.window, !(window.firstResponder is NSText) else { return }
            window.makeFirstResponder(outline)
        }
    }

    func refreshVisible() {
        guard let outline else { return }
        query = model.query
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        outline.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: [0])
    }

    /// Selects a node, opening its ancestors, and scrolls it into the middle of the view.
    func reveal(_ id: Int32) {
        guard let outline, let tree, Int(id) < tree.count else { return }
        for a in tree.ancestors(id) { outline.expandItem(item(a)) }
        let row = outline.row(forItem: item(id))
        guard row >= 0 else { return }
        syncing = true
        outline.selectRowIndexes([row], byExtendingSelection: false)
        syncing = false
        let rect = outline.rect(ofRow: row)
        if let clip = outline.enclosingScrollView?.contentView, !clip.bounds.contains(rect) {
            let y = max(0, rect.midY - clip.bounds.height / 2)
            clip.scroll(to: NSPoint(x: 0, y: min(y, max(0, outline.bounds.height - clip.bounds.height))))
            outline.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// Shows containers down to `level` levels open (1 opens just the root), within the row budget.
    func expand(toLevel level: Int, quiet: Bool = false) {
        guard let outline, let tree, tree.count > 0 else { return }
        let selected = model.selected
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        outline.collapseItem(nil, collapseChildren: true)
        var rows = 1, frontier: [Int32] = [0], depth = 0, stopped = false
        while depth < level, !frontier.isEmpty {
            var next: [Int32] = []
            for id in frontier {
                let n = tree.childCount(id)
                if depth > 0, rows + n > Self.rowBudget { stopped = true; break }
                outline.expandItem(item(id))
                rows += n
                next.append(contentsOf: tree.childIDs(id).filter { tree.kind($0).isContainer && tree.childCount($0) > 0 })
            }
            if stopped { break }
            frontier = next
            depth += 1
        }
        NSAnimationContext.endGrouping()
        if let selected, tree.ancestors(selected).allSatisfy({ outline.isItemExpanded(item($0)) }) { reveal(selected) }
        if stopped, !quiet {
            model.show(.init(message: "Opened \(rows.formatted()) rows; open deeper branches one by one"))
        }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let tree, tree.count > 0 else { return 0 }
        guard let node = item as? NodeItem else { return 1 }
        return tree.childCount(node.id)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? NodeItem, let tree else { return self.item(0) }
        return self.item(tree.child(node.id, index))
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? NodeItem, let tree else { return false }
        return tree.childCount(node.id) > 0
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NodeItem, let tree else { return nil }
        let cell = outlineView.makeView(withIdentifier: NodeCell.identifier, owner: nil) as? NodeCell ?? NodeCell()
        cell.configure(tree: tree, id: node.id, query: query, expanded: outlineView.isItemExpanded(node))
        return cell
    }

    // A collapsed container shows a one-line preview; an open one does not need it.
    func outlineViewItemDidExpand(_ notification: Notification) { refreshRow(of: notification) }
    func outlineViewItemDidCollapse(_ notification: Notification) { refreshRow(of: notification) }

    private func refreshRow(of notification: Notification) {
        guard let outline, let item = notification.userInfo?["NSObject"] else { return }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.reloadData(forRowIndexes: [row], columnIndexes: [0]) }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { AccentRowView() }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let outline else { return }
        let id = (outline.item(atRow: outline.selectedRow) as? NodeItem)?.id
        let model = model
        DispatchQueue.main.async { model.outlineSelected(id) }
    }

    @objc func doubleClicked(_ sender: NSOutlineView) {
        guard let node = sender.item(atRow: sender.clickedRow) as? NodeItem else { return }
        if sender.isItemExpanded(node) { sender.animator().collapseItem(node) } else { sender.animator().expandItem(node) }
    }

    // MARK: Context menu

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        add("Copy Value", #selector(menuCopyValue))
        add("Copy JSONPath", #selector(menuCopyPath))
        add("Copy jq Path", #selector(menuCopyJQ))
        menu.addItem(.separator())
        add("Expand Children", #selector(menuExpandChildren))
        add("Collapse Children", #selector(menuCollapseChildren))
        return menu
    }

    private var clickedID: Int32? {
        guard let outline else { return nil }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return (outline.item(atRow: row) as? NodeItem)?.id
    }

    @objc private func menuCopyValue() { if let id = clickedID { model.copyValue(id) } }
    @objc private func menuCopyPath() { if let id = clickedID { model.copyJSONPath(id) } }
    @objc private func menuCopyJQ() { if let id = clickedID { model.copyJQPath(id) } }

    @objc private func menuExpandChildren() {
        guard let id = clickedID, let tree, let outline else { return }
        if tree.count <= Self.rowBudget { outline.animator().expandItem(item(id), expandChildren: true) } else { outline.animator().expandItem(item(id)) }
    }

    @objc private func menuCollapseChildren() {
        guard let id = clickedID, let outline else { return }
        outline.animator().collapseItem(item(id), collapseChildren: true)
    }
}

// MARK: - Cell

final class NodeCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("NodeCell")
    private let badge = Badge()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        count.setContentHuggingPriority(.required, for: .horizontal)
        preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        preview.textColor = .tertiaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.setContentCompressionResistancePriority(.init(100), for: .horizontal)
        for v in [badge, label, count, preview] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = label
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 32),
            badge.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            count.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            preview.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 10),
            preview.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            preview.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
    static let valueFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var last: (tree: JSONTree, id: Int32, query: String, expanded: Bool)?

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            badge.emphasized = backgroundStyle == .emphasized
            if let last, oldValue != backgroundStyle { configure(tree: last.tree, id: last.id, query: last.query, expanded: last.expanded) }
        }
    }

    func configure(tree: JSONTree, id: Int32, query: String, expanded: Bool) {
        last = (tree, id, query, expanded)
        let kind = tree.kind(id)
        badge.kind = kind
        let onAccent = backgroundStyle == .emphasized
        count.textColor = onAccent ? NSColor.white.withAlphaComponent(0.75) : .tertiaryLabelColor
        preview.textColor = onAccent ? NSColor.white.withAlphaComponent(0.6) : .tertiaryLabelColor
        let text = NSMutableAttributedString()
        let q = query.trimmingCharacters(in: .whitespaces)
        func append(_ s: String, _ color: NSColor, _ font: NSFont, highlight: Bool = true) {
            let part = NSMutableAttributedString(string: s, attributes: [.foregroundColor: onAccent ? NSColor.white : color, .font: font])
            if highlight, !q.isEmpty {
                for r in ViewerModel.ranges(of: q, in: s, limit: 20) {
                    part.addAttributes([.backgroundColor: Theme.highlight, .foregroundColor: NSColor.black], range: r)
                }
            }
            text.append(part)
        }
        if let parent = tree.parent(id) {
            if tree.kind(parent) == .object {
                append(JSONTree.oneLine(tree.key(id) ?? ""), .labelColor, Self.keyFont)
            } else {
                append("[\(tree.position(id))]", .secondaryLabelColor, Self.valueFont, highlight: false)
            }
        } else {
            append(tree.isLines ? "records" : "root", .secondaryLabelColor, Self.keyFont, highlight: false)
        }
        if !kind.isContainer {
            append("   ", .labelColor, Self.valueFont, highlight: false)
            var value = tree.scalarText(id, maxBytes: 1200)
            if kind == .string {
                if value.utf16.count > 400 { value = String(value.prefix(400)) + "…" }
                value = "\"" + JSONTree.oneLine(value) + "\""
            }
            append(value, TypeStyle.color(kind), Self.valueFont)
            count.stringValue = ""
            preview.stringValue = ""
        } else {
            count.stringValue = tree.summary(id)
            if expanded || tree.childCount(id) == 0 {
                preview.stringValue = ""
            } else {
                let r = tree.render(id, indent: nil, limit: 240)
                preview.stringValue = String(decoding: r.bytes, as: UTF8.self) + (r.truncated ? "…" : "")
            }
        }
        label.attributedStringValue = text
        setAccessibilityLabel("\(text.string), \(kind.name)")
    }
}

/// Selected rows in the leaf green instead of the system accent.
final class AccentRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 10, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        if isEmphasized {
            NSGradient(starting: rgb(0x34A86A), ending: rgb(0x1F8A5B))?.draw(in: path, angle: -90)
        } else {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            path.fill()
        }
    }
}

/// The small rounded type tag at the start of each row.
final class Badge: NSView {
    var kind: JSONKind = .null { didSet { if kind != oldValue { restyle() } } }
    var emphasized = false { didSet { if emphasized != oldValue { restyle() } } }
    private let label = NSTextField(labelWithString: "")
    private static let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4.5
        layer?.cornerCurve = .continuous
        label.font = Self.font
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = emphasized ? NSColor.white : TypeStyle.color(kind)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.withAlphaComponent(emphasized ? 0.22 : 0.14).cgColor
        }
    }

    private func restyle() {
        label.stringValue = kind.badge
        label.textColor = emphasized ? .white : TypeStyle.color(kind)
        needsDisplay = true
    }
}
