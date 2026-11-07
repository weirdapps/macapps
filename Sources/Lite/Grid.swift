import AppKit
import SwiftUI

// AppKit views where SwiftUI falls short: a data grid with any number of columns, and a plain code editor.

/// A spreadsheet like grid over a result: a row number gutter, sortable headers, resizable columns, copy.
/// With `onSort` the owner sorts (a table page, sorted by SQLite); without it the grid sorts in memory.
struct GridView: NSViewRepresentable {
    var result: ResultSet
    var rowOffset = 0
    var sort: SortKey?
    var onSort: ((SortKey?) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DataTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        table.menu = context.coordinator.contextMenu(for: table)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(result: result, offset: rowOffset, sort: sort, onSort: onSort)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private var columns: [String] = []
        private var rows: [[SQLValue]] = []
        private var source: [[SQLValue]] = []
        private var offset = 0
        private var onSort: ((SortKey?) -> Void)?
        private var updating = false
        private var localSort: SortKey?

        static let gutter = NSUserInterfaceItemIdentifier("#")
        static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let nullFont = NSFont.systemFont(ofSize: 11, weight: .medium)

        func update(result: ResultSet, offset: Int, sort: SortKey?, onSort: ((SortKey?) -> Void)?) {
            guard let table else { return }
            updating = true
            defer { updating = false }
            self.onSort = onSort
            self.offset = offset
            let rebuilt = result.columns != columns
            if rebuilt {
                columns = result.columns
                localSort = nil
                rebuildColumns(sample: result.rows)
            }
            source = result.rows
            if onSort == nil {
                applyLocalSort()
                table.sortDescriptors = localSort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
            } else {
                rows = source
                table.sortDescriptors = sort.map { [NSSortDescriptor(key: $0.column, ascending: $0.ascending)] } ?? []
            }
            table.reloadData()
            if rebuilt { table.scrollRowToVisible(0) }
        }

        private func applyLocalSort() {
            guard let localSort, let i = columns.firstIndex(of: localSort.column) else { rows = source; return }
            rows = source.sorted { a, b in
                localSort.ascending ? SQLValue.ascending(a[i], b[i]) : SQLValue.ascending(b[i], a[i])
            }
        }

        private func rebuildColumns(sample: [[SQLValue]]) {
            guard let table else { return }
            for column in table.tableColumns { table.removeTableColumn(column) }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
            let header: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]

            let gutter = NSTableColumn(identifier: Self.gutter)
            gutter.title = ""
            gutter.width = 46
            gutter.minWidth = 36
            gutter.resizingMask = []
            table.addTableColumn(gutter)

            for (i, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                column.headerCell = PaddedHeaderCell(textCell: name)
                column.title = name
                column.headerToolTip = name
                column.sortDescriptorPrototype = NSSortDescriptor(key: name, ascending: true)
                var width = (name as NSString).size(withAttributes: header).width + 30
                for row in sample.prefix(60) where i < row.count {
                    let text = Self.text(row[i])
                    width = max(width, (text as NSString).size(withAttributes: attrs).width + 18)
                }
                column.width = min(max(width, 54), 320)
                column.minWidth = 40
                column.maxWidth = 2000
                if let first = sample.first, i < first.count, first[i].isNumeric {
                    column.headerCell.alignment = .right
                }
                table.addTableColumn(column)
            }
        }

        static func text(_ value: SQLValue) -> String {
            let s = value.display
            guard case .text = value else { return s }
            let line = s.count > 400 ? String(s.prefix(400)) : s
            return line.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let id = tableColumn.identifier
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? Self.makeCell(id)
            guard let label = cell.textField else { return cell }
            if id == Self.gutter {
                label.stringValue = String(offset + row + 1)
                label.textColor = .tertiaryLabelColor
                label.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
                label.alignment = .right
                label.toolTip = nil
                return cell
            }
            guard let i = Int(id.rawValue.dropFirst()), row < rows.count, i < rows[row].count else { return cell }
            let value = rows[row][i]
            label.stringValue = Self.text(value)
            label.alignment = value.isNumeric ? .right : .left
            switch value {
            case .null:
                label.font = Self.nullFont
                label.textColor = .tertiaryLabelColor
            case .blob:
                label.font = Self.nullFont
                label.textColor = .secondaryLabelColor
            default:
                label.font = Self.font
                label.textColor = .labelColor
            }
            if case .text(let s) = value, s.count > 40 { label.toolTip = String(s.prefix(2000)) } else { label.toolTip = nil }
            return cell
        }

        private static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            let key = tableView.sortDescriptors.first.flatMap { d in d.key.map { SortKey(column: $0, ascending: d.ascending) } }
            if let onSort {
                onSort(key)
            } else {
                localSort = key
                applyLocalSort()
                tableView.reloadData()
            }
        }

        // MARK: Copy

        /// Tab separated rows, the way spreadsheets paste them.
        func copyRows(_ indexes: IndexSet) {
            let text = indexes.compactMap { $0 < rows.count ? rows[$0].map(\.plain).joined(separator: "\t") : nil }.joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        func copyValue(row: Int, column: Int) {
            guard row >= 0, row < rows.count, let table, column > 0, column < table.tableColumns.count,
                  let i = Int(table.tableColumns[column].identifier.rawValue.dropFirst()), i < rows[row].count else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rows[row][i].plain, forType: .string)
        }

        func copyHeader() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(columns.joined(separator: "\t"), forType: .string)
        }

        func contextMenu(for table: DataTableView) -> NSMenu {
            let menu = NSMenu()
            menu.addItem(withTitle: "Copy Value", action: #selector(DataTableView.copyClickedValue(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Rows", action: #selector(DataTableView.copy(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Copy Column Names", action: #selector(DataTableView.copyColumnNames(_:)), keyEquivalent: "")
            for item in menu.items { item.target = table }
            return menu
        }
    }
}

/// A header cell with the same side padding as the cells below it.
final class PaddedHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        super.drawInterior(withFrame: NSRect(x: frame.minX + 3, y: frame.minY, width: frame.width - 10, height: frame.height), in: view)
    }
}

/// The grid's table view: Edit > Copy copies the selected rows.
final class DataTableView: NSTableView, NSMenuItemValidation {
    weak var coordinator: GridView.Coordinator?

    @objc func copy(_ sender: Any?) {
        var rows = selectedRowIndexes
        if rows.isEmpty, clickedRow >= 0 { rows = [clickedRow] }
        coordinator?.copyRows(rows)
    }

    @objc func copyClickedValue(_ sender: Any?) {
        coordinator?.copyValue(row: clickedRow, column: clickedColumn)
    }

    @objc func copyColumnNames(_ sender: Any?) {
        coordinator?.copyHeader()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return !selectedRowIndexes.isEmpty || clickedRow >= 0
        case #selector(copyClickedValue(_:)): return clickedRow >= 0 && clickedColumn > 0
        default: return true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return super.menu(for: event)
    }
}

// MARK: - SQL editor

/// A plain text editor for SQL: monospaced, no smart quotes or autocorrect, coloured as you type.
struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    var onSelection: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.font = Coordinator.font
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.typingAttributes = Coordinator.base
        view.string = text
        context.coordinator.highlight(view)
        // A new editor has no selection yet, whatever the last one had.
        onSelection("")
        // Switching to the SQL editor puts the cursor in it, ready to type.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        context.coordinator.highlight(view)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]

        init(_ parent: SQLEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            highlight(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let range = view.selectedRange()
            parent.onSelection(range.length > 0 ? (view.string as NSString).substring(with: range) : "")
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(Self.base, range: all)
            for (kind, range) in SQLHighlighter.tokens(storage.string) where NSMaxRange(range) <= storage.length {
                storage.addAttributes(Theme.attributes(kind), range: range)
            }
            storage.endEditing()
        }
    }
}
