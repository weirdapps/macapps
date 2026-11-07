import AppKit
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    static let dark = Color(red: 0x17 / 255, green: 0x7A / 255, blue: 0x3A / 255)
    static let gradient = LinearGradient(colors: [light, dark], startPoint: .top, endPoint: .bottom)
}

/// One window per file. Owns the model so it lives as long as the window.
struct DocumentWindow: View {
    @StateObject private var model: GridModel

    init(file: CSVFile, url: URL?) {
        _model = StateObject(wrappedValue: GridModel(data: file.data, name: url?.lastPathComponent ?? "Untitled", url: url))
    }

    var body: some View {
        GridView(model: model)
            .task { if model.allRows.isEmpty, case .loading = model.phase { model.load() } }
    }
}

struct GridView: View {
    @ObservedObject var model: GridModel
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            StatusBar(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView(model: model)
                .inspectorColumnWidth(min: 240, ideal: 268, max: 380)
        }
        .frame(minWidth: 620, minHeight: 360)
        .searchable(text: $model.query, placement: .toolbar, prompt: model.searchColumn.flatMap { model.columns[safe: $0] }.map { "Filter \($0)" } ?? "Filter rows")
        .modifier(SearchFocus(focused: $searchFocused))
        .onChange(of: model.findRequest) { searchFocused = true }
        .onChange(of: model.query) { model.refresh(debounce: true) }
        .onChange(of: model.searchColumn) { model.refresh() }
        .toolbar { toolbar }
        .focusedSceneObject(model)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
            return !urls.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.light, lineWidth: 3).padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading(let fraction):
            LoadingView(name: model.name, fraction: fraction, bytes: model.byteCount) { model.cancelLoad() }
        case .stopped:
            ContentUnavailableView {
                Label("Loading stopped", systemImage: "stop.circle")
            } description: {
                Text("\(model.name) was not read to the end.")
            } actions: {
                Button("Load Again") { model.load() }.buttonStyle(.borderedProminent).tint(Theme.dark)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.columns.isEmpty {
                ContentUnavailableView("No rows", systemImage: "tablecells",
                                       description: Text("\(model.name) has no records to show."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    GridTable(model: model)
                    if model.visible.isEmpty && !model.busy {
                        if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("No rows", systemImage: "tablecells",
                                                   description: Text("\(model.name) has a header row and nothing below it."))
                                .background(.background)
                        } else {
                            ContentUnavailableView.search(text: model.query).background(.background)
                        }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                SearchScopePicker(model: model)
            } label: {
                Label("Search In", systemImage: model.searchColumn == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Choose which column the filter searches")
            .disabled(model.phase != .ready)

            Menu {
                ForEach(CopyFormat.allCases, id: \.self) { f in
                    Button("Copy as \(f.label)") { model.copy(format: f) }
                }
            } label: {
                Label("Copy Rows", systemImage: "doc.on.doc")
            }
            .help("Copy the selected rows as CSV, TSV or Markdown")
            .disabled(!model.canCopy)

            Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export the rows on screen as CSV (⇧⌘E)")
                .disabled(!model.canExport)

            Button { withAnimation(.snappy) { model.showInspector.toggle() } } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide column statistics (⌥⌘I)")
        }
    }
}

/// Edit > Find moves the cursor into the toolbar's filter field (macOS 15 and later).
struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.searchFocused(focused) } else { content }
    }
}

struct SearchScopePicker: View {
    @ObservedObject var model: GridModel

    var body: some View {
        Picker("Search In", selection: $model.searchColumn) {
            Text("All Columns").tag(Int?.none)
            Divider()
            ForEach(Array(model.columns.enumerated()), id: \.offset) { i, name in
                Text(name).tag(Int?.some(i))
            }
        }
        .pickerStyle(.inline)
    }
}

// MARK: - Loading

struct LoadingView: View {
    let name: String
    let fraction: Double
    let bytes: Int
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tablecells")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.gradient)
            VStack(spacing: 4) {
                Text("Reading \(name)").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("\(ByteCountFormatter.string(fromByteCount: Int64(Double(bytes) * fraction), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            ProgressView(value: fraction).frame(width: 260).tint(Theme.dark)
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy, value: fraction)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: GridModel

    var body: some View {
        HStack(spacing: 10) {
            if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.multicolor)
                    .transition(.opacity)
                if let url = model.exportedURL {
                    Button("Show in Finder") { revealInFinder([url]) }.buttonStyle(.link)
                }
            } else {
                Text(summary).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
            }
            if model.busy { ProgressView().controlSize(.mini) }
            Spacer(minLength: 8)
            if model.phase == .ready {
                Menu(model.delimiter.label) {
                    Picker("Delimiter", selection: Binding(get: { model.delimiter }, set: { model.setDelimiter($0) })) {
                        ForEach(Delimiter.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .fixedSize()
                .help("Field delimiter")
                Menu(model.encoding.label) {
                    Picker("Encoding", selection: Binding(get: { model.encoding }, set: { model.setEncoding($0) })) {
                        ForEach(TextEncoding.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .fixedSize()
                .help("Text encoding")
                Toggle("Header row", isOn: Binding(get: { model.hasHeader }, set: { model.setHeader($0) }))
                    .toggleStyle(.checkbox)
                    .help("Use the first row as column names (⇧⌘H)")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    private var summary: String {
        guard model.phase == .ready else { return "" }
        let total = model.rowCount, shown = model.visible.count
        var s = shown == total || model.busy ? "\(CSV.format(total)) rows" : "\(CSV.format(shown)) of \(CSV.format(total)) rows"
        s += ", \(model.columns.count) columns"
        if !model.selection.isEmpty { s += ", \(CSV.format(model.selection.count)) selected" }
        return s
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var model: GridModel

    var body: some View {
        // The inspector already sits below the toolbar, yet a scroll view in it insets by the toolbar's height
        // once more. Lay the scroll view out edge to edge and pad its content by that inset exactly once.
        GeometryReader { g in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.columns.isEmpty {
                        Text(model.phase == .ready ? "This file has no columns to describe." : "Column statistics appear here once the file is read.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        header
                        if let s = model.stats { body(s) } else {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 30)
                        }
                    }
                }
                .padding(16)
                .padding(.top, g.safeAreaInsets.top)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Column").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Picker("Column", selection: Binding(get: { model.inspectedColumn }, set: { model.inspect($0) })) {
                ForEach(Array(model.columns.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func body(_ s: ColumnStats) -> some View {
        HStack(spacing: 6) {
            Label(s.isNumeric ? "Numbers" : "Text", systemImage: s.isNumeric ? "number" : "textformat")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.light.opacity(0.16)))
                .foregroundStyle(Theme.dark)
            Text("in \(CSV.format(s.rows)) \(s.rows == 1 ? "row" : "rows")").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            Tile(label: "Count", value: CSV.format(s.count))
            Tile(label: "Empty", value: CSV.format(s.empty))
            Tile(label: "Unique", value: CSV.format(s.unique))
            if let mean = s.mean { Tile(label: "Mean", value: CSV.format(mean), accent: true) } else {
                Tile(label: "Filled", value: s.rows == 0 ? "0%" : (Double(s.count) / Double(s.rows)).formatted(.percent.precision(.fractionLength(0))))
            }
            Tile(label: "Min", value: s.min ?? "None")
            Tile(label: "Max", value: s.max ?? "None")
        }
        if let sum = s.sum {
            Tile(label: "Sum", value: CSV.format(sum, decimals: s.decimals))
        }
        if let most = s.top.first?.count, most < 2, s.count > 0 {
            Label("Every value is different", systemImage: "sparkles")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !s.top.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Most common").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                let most = s.top.first?.count ?? 1
                ForEach(s.top, id: \.value) { v in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(v.value.replacingOccurrences(of: "\n", with: " ")).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 6)
                            Text(CSV.format(v.count)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        GeometryReader { g in
                            Capsule().fill(Theme.gradient)
                                .frame(width: max(4, g.size.width * CGFloat(v.count) / CGFloat(most)))
                        }
                        .frame(height: 4)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

struct Tile: View {
    let label: String
    let value: String
    var accent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.tail)
                .foregroundStyle(accent ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.primary))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

// MARK: - Table

/// An NSTableView: dynamic columns, millions of rows, resizable widths, sortable headers, multiple selection.
struct GridTable: NSViewRepresentable {
    @ObservedObject var model: GridModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = GridTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidVerticalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAutomaticRowHeights = false
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        table.menu = context.coordinator.contextMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        context.coordinator.table = table
        context.coordinator.sync()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
        var model: GridModel
        weak var table: GridTableView?
        private var layoutID = -1
        private var generation = -1
        private var updating = false

        init(model: GridModel) { self.model = model }

        func sync() {
            guard let table else { return }
            updating = true
            defer { updating = false }
            if layoutID != model.layoutID {
                layoutID = model.layoutID
                rebuildColumns(table)
            }
            if generation != model.generation {
                generation = model.generation
                table.reloadData()
                table.selectRowIndexes(model.selection, byExtendingSelection: false)
            }
            if Desktop.isSnapshot, let window = table.window, window.firstResponder !== table {
                window.makeFirstResponder(table)
            }
            let wanted = model.sort.map { [NSSortDescriptor(key: "\($0.column)", ascending: $0.ascending)] } ?? []
            if table.sortDescriptors != wanted { table.sortDescriptors = wanted }
        }

        private func rebuildColumns(_ table: NSTableView) {
            for c in table.tableColumns { table.removeTableColumn(c) }
            let font = NSFont.systemFont(ofSize: 12)
            let bodyFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let digits = String(max(model.rowCount, 1)).count
            let number = NSTableColumn(identifier: .init("#"))
            number.title = ""
            number.width = CGFloat(max(digits, 2)) * 7.5 + 18
            number.minWidth = 30
            number.resizingMask = []
            table.addTableColumn(number)
            let first = model.bodyStart
            let sample = first..<min(model.allRows.count, first + 300)
            for (i, name) in model.columns.enumerated() {
                let col = NSTableColumn(identifier: .init(String(i)))
                col.title = name
                col.headerToolTip = "\(name), \(model.numeric[safe: i] == true ? "numbers" : "text"). Click to sort."
                col.sortDescriptorPrototype = NSSortDescriptor(key: String(i), ascending: true)
                col.headerCell = GridHeaderCell(textCell: name)
                if model.numeric[safe: i] == true { col.headerCell.alignment = .right }
                var width = (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width + 30
                for r in sample {
                    let text = model.cell(r, i)
                    guard !text.isEmpty else { continue }
                    let w = (String(text.prefix(80)) as NSString).size(withAttributes: [.font: model.numeric[safe: i] == true ? bodyFont : font]).width + 18
                    width = max(width, w)
                }
                col.width = min(max(width, 56), 340)
                col.minWidth = 36
                col.maxWidth = 4000
                table.addTableColumn(col)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { model.visible.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, row < model.visible.count else { return nil }
            let id = tableColumn.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? GridCell ?? GridCell(identifier: id)
            let r = model.visible[row]
            if id.rawValue == "#" {
                cell.set(String(model.recordNumber(r)), numeric: true, secondary: true)
            } else if let c = Int(id.rawValue) {
                let text = model.cell(r, c)
                let shown = text.contains(where: \.isNewline)
                    ? text.replacingOccurrences(of: "\r\n", with: " ⏎ ").replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\r", with: " ⏎ ")
                    : text
                cell.set(shown, numeric: model.numeric[safe: c] == true, secondary: false)
                cell.toolTip = shown.count > 40 || shown != text ? String(text.prefix(2000)) : nil
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            guard let d = tableView.sortDescriptors.first, let key = d.key, let c = Int(key) else { model.setSort(nil); return }
            model.setSort(.init(column: c, ascending: d.ascending))
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            if let c = Int(tableColumn.identifier.rawValue) { model.inspect(c) }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let rows = table.selectedRowIndexes
            if rows != model.selection { model.selection = rows }
        }

        func tableView(_ tableView: NSTableView, shouldSelect tableColumn: NSTableColumn?) -> Bool { false }

        // MARK: Copy

        /// The rows a context menu acts on: the clicked row unless it is part of the selection.
        private var targetRows: IndexSet {
            guard let table else { return [] }
            let clicked = table.clickedRow
            if clicked >= 0 && !table.selectedRowIndexes.contains(clicked) { return [clicked] }
            return table.selectedRowIndexes
        }

        func contextMenu() -> NSMenu {
            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy", action: #selector(copyPlain(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.addItem(.separator())
            for (i, f) in CopyFormat.allCases.enumerated() {
                let item = NSMenuItem(title: "Copy as \(f.label)", action: #selector(copyAs(_:)), keyEquivalent: "")
                item.tag = i
                item.target = self
                menu.addItem(item)
            }
            return menu
        }

        @objc func copyPlain(_ sender: Any?) { model.copy(targetRows, format: .tsv, header: false) }
        @objc func copyAs(_ sender: NSMenuItem) { model.copy(targetRows, format: CopyFormat.allCases[sender.tag]) }

        func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !targetRows.isEmpty }

        func copySelection() { model.copy(format: .tsv, header: false) }
    }
}

/// The table, answering Edit > Copy with the selected rows as tab-separated text.
final class GridTableView: NSTableView {
    weak var coordinator: GridTable.Coordinator?

    @objc func copy(_ sender: Any?) { coordinator?.copySelection() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

/// A header cell with room between a right-aligned title and the next column's divider.
final class GridHeaderCell: NSTableHeaderCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect).insetBy(dx: 4, dy: 0)
    }
}

final class GridCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func set(_ text: String, numeric: Bool, secondary: Bool) {
        label.stringValue = text
        label.alignment = numeric ? .right : .left
        label.font = secondary ? .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            : numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
        label.textColor = secondary ? .tertiaryLabelColor : .labelColor
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
