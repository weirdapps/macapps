import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 0x3D / 255, green: 0x7B / 255, blue: 0xFF / 255)
    static let bottom = Color(red: 0x1D / 255, green: 0x3F / 255, blue: 0xAF / 255)
    static let accent = top
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)

    static func color(_ kind: SQLToken) -> NSColor {
        switch kind {
        case .keyword: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgbNS(0x7FA8FF) : rgbNS(0x2459E0) }
        case .string: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgbNS(0xFF8A70) : rgbNS(0xC4361B) }
        case .identifier: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgbNS(0x6FD3C5) : rgbNS(0x0E7C72) }
        case .number: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgbNS(0xD7A6FF) : rgbNS(0x7C3AC4) }
        case .comment: .secondaryLabelColor
        }
    }

    static func attributes(_ kind: SQLToken) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.foregroundColor: color(kind)]
        if kind == .keyword { a[.font] = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold) }
        return a
    }

    /// Coloured SQL for read only display (the CREATE statement).
    static func highlighted(_ sql: String) -> AttributedString {
        let s = NSMutableAttributedString(string: sql, attributes: [.foregroundColor: NSColor.labelColor])
        for (kind, range) in SQLHighlighter.tokens(sql) where NSMaxRange(range) <= s.length {
            s.addAttribute(.foregroundColor, value: color(kind), range: range)
        }
        return (try? AttributedString(s, including: \.appKit)) ?? AttributedString(sql)
    }

    private static func rgbNS(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Window root

/// One browser window. Its value is the database URL, so SwiftUI restores open databases on relaunch.
struct DatabaseWindow: View {
    @Binding var url: URL?
    @StateObject private var model = DatabaseModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model) { opened in
            if model.url == nil { url = opened; model.open(opened) } else { openWindow(value: opened) }
        }
        .focusedSceneObject(model)
        .onAppear {
            if let url, model.url == nil { model.open(url) }
            let binding = $url, open = openWindow
            let target = model
            Router.shared.attach { [weak target] opened in
                if let target, target.url == nil { binding.wrappedValue = opened; target.open(opened) } else { open(value: opened) }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: DatabaseModel
    var openURL: (URL) -> Void = { _ in }
    @State private var targeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .empty:
                DropZone(symbol: "cylinder.split.1x2", title: "Open a SQLite database",
                         message: "Drop a .sqlite, .db or .sqlite3 file here, or choose one. Lite opens it read only, so nothing changes.",
                         button: "Open Database…", tint: Theme.accent, isTargeted: targeted) {
                    if let url = FileTypes.choose() { openURL(url) }
                }
            case .failed(let message):
                FailureView(name: model.fileName, message: message) {
                    if let url = FileTypes.choose() { model.open(url) }
                }
            case .loading, .open:
                BrowserView(model: model)
            }
        }
        .frame(minWidth: 780, minHeight: 480)
        .tint(Theme.accent)
        .navigationTitle(model.url?.lastPathComponent ?? "Lite")
        .navigationSubtitle(model.isOpen ? (model.readOnly ? "Read only" : "Writing allowed") : "")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !Desktop.isSnapshot else { return false }
            openURL(url)
            return true
        } isTargeted: { targeted = $0 }
    }
}

struct FailureView: View {
    let name: String
    let message: String
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Could not open \(name)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Open Another…", action: action).buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - Browser

struct BrowserView: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 224, max: 340)
        } detail: {
            Group {
                if model.phase == .loading {
                    ProgressView().controlSize(.small)
                } else {
                    switch model.mode {
                    case .data: DataPane(model: model)
                    case .schema: SchemaPane(model: model)
                    case .sql: SQLPane(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { NoticeBanner(model: model) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.mode) {
                    ForEach(DatabaseModel.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Show the table's data, its schema, or the SQL editor (⌘1, ⌘2, ⌘3)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload tables and row counts (⌘R)")
                Button { model.export() } label: { Label("Export as CSV", systemImage: "square.and.arrow.up") }
                    .disabled(!model.canExport)
                    .help(model.mode == .sql ? "Export the query result as CSV (⇧⌘E)" : "Export this table as CSV (⇧⌘E)")
                Button { model.toggleReadOnly() } label: {
                    Label(model.readOnly ? "Read Only" : "Writable", systemImage: model.readOnly ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(model.readOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
                .help(model.readOnly ? "Read only. Click to allow writing (⇧⌘L)" : "Writing allowed. Click to go back to read only (⇧⌘L)")
            }
        }
        .alert("Allow changes to \u{201C}\(model.fileName)\u{201D}?", isPresented: $model.confirmingWrite) {
            Button("Allow Writing", role: .destructive) { model.allowWriting() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Lite opens databases read only. With writing allowed, the SQL you run can change or delete data in this file, and there is no undo. Make a copy first if it matters.")
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Tables") {
                ForEach(model.tables) { SidebarRow(object: $0).tag($0.name) }
            }
            if !model.views.isEmpty {
                Section("Views") {
                    ForEach(model.views) { SidebarRow(object: $0).tag($0.name) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.isOpen, model.objects.isEmpty {
                Text("No tables").font(.callout).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.fileName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("\(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file)), SQLite \(Connection.version)")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Image(systemName: model.readOnly ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(model.readOnly ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    .help(model.readOnly ? "Opened read only" : "Writing allowed")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

struct SidebarRow: View {
    let object: DBObject

    var body: some View {
        Label {
            Text(object.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: object.isView ? "eye" : "tablecells")
        }
        .badge(object.rowCount.map { Text($0.grouped).monospacedDigit() })
        .help(object.rowCount.map { "\(object.name), \($0.grouped) rows" } ?? object.name)
    }
}

// MARK: - Data

struct DataPane: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.selection == nil {
                    ContentUnavailableView("No table selected", systemImage: "tablecells",
                                           description: Text("Choose a table or view in the sidebar."))
                } else if let error = model.pageError {
                    ErrorCard(message: error).frame(maxHeight: .infinity, alignment: .top)
                } else if let result = model.pageResult {
                    if result.rows.isEmpty, model.page == 0 {
                        ContentUnavailableView("No rows", systemImage: "tray",
                                               description: Text("\(model.selection ?? "This table") is empty."))
                    } else {
                        GridView(result: result, rowOffset: model.page * DatabaseModel.pageSize, sort: model.sort,
                                 onSort: { model.setSort($0) })
                    }
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PagerBar(model: model)
        }
    }
}

struct PagerBar: View {
    @ObservedObject var model: DatabaseModel

    private var range: String {
        guard let r = model.pageResult, !r.rows.isEmpty else { return "No rows" }
        let first = model.page * DatabaseModel.pageSize + 1
        let last = first + r.rows.count - 1
        if let total = model.totalRows { return "Rows \(first.grouped) to \(last.grouped) of \(total.grouped)" }
        return "Rows \(first.grouped) to \(last.grouped)"
    }

    var body: some View {
        HStack(spacing: 10) {
            if let r = model.pageResult {
                Text(r.columns.count == 1 ? "1 column" : "\(r.columns.count) columns").foregroundStyle(.secondary)
            }
            if let sort = model.sort {
                HStack(spacing: 4) {
                    Image(systemName: sort.ascending ? "arrow.up" : "arrow.down")
                    Text("Sorted by \(sort.column)")
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
            }
            Spacer()
            Text(range).monospacedDigit().foregroundStyle(.secondary).contentTransition(.numericText())
            ControlGroup {
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack)
                    .help("Previous page (⌘[)")
                Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Next page (⌘])")
            }
            .controlSize(.small)
            .fixedSize()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: model.page)
    }
}

struct ErrorCard: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 16)).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("SQLite reported an error").font(.system(size: 13, weight: .semibold))
                Text(message).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.2)))
        .padding(16)
    }
}

// MARK: - Schema

struct SchemaPane: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        if let schema = model.schema, schema.name == model.selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(schema)
                    Card(title: "Columns", symbol: "list.bullet") { ColumnsGrid(columns: schema.columns) }
                    if !schema.isView {
                        Card(title: "Indexes", symbol: "arrow.up.arrow.down") {
                            if schema.indexes.isEmpty {
                                Text("No indexes").font(.callout).foregroundStyle(.secondary).padding(14)
                            } else {
                                IndexList(indexes: schema.indexes)
                            }
                        }
                    }
                    Card(title: "Create statement", symbol: "chevron.left.forwardslash.chevron.right", trailing: {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(schema.sql, forType: .string)
                        } label: { Label("Copy", systemImage: "doc.on.doc") }
                            .buttonStyle(.borderless).controlSize(.small)
                            .help("Copy the CREATE statement")
                    }) {
                        Text(Theme.highlighted(schema.sql))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                }
                .padding(22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if model.selection == nil {
            ContentUnavailableView("No table selected", systemImage: "list.bullet.rectangle",
                                   description: Text("Choose a table or view in the sidebar."))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func header(_ schema: TableSchema) -> some View {
        HStack(spacing: 12) {
            Image(systemName: schema.isView ? "eye" : "tablecells")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(schema.name).font(.system(size: 20, weight: .semibold, design: .rounded))
                let rows = model.selectedObject?.rowCount.map { ", \($0.grouped) rows" } ?? ""
                Text("\(schema.isView ? "View" : "Table"), \(schema.columns.count) columns\(rows)")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

struct Card<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(title: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            .padding(.horizontal, 4)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        }
    }
}

struct Tag: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct ColumnsGrid: View {
    let columns: [ColumnInfo]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
            GridRow {
                Text("Name"); Text("Type"); Text("Constraints")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .padding(.vertical, 7)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                            .opacity(column.primaryKey > 0 ? 1 : 0)
                        Text(column.name).font(.system(size: 12.5, weight: column.primaryKey > 0 ? .semibold : .regular))
                    }
                    Text(column.type.isEmpty ? "any" : column.type)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(column.type.isEmpty ? .tertiary : .secondary)
                    HStack(spacing: 5) {
                        if column.primaryKey > 0 { Tag(text: "Primary key", tint: Theme.accent) }
                        if column.notNull { Tag(text: "Not null") }
                        if let d = column.defaultValue { Tag(text: "Default \(d)") }
                        if let r = column.references { Tag(text: "References \(r)", tint: .teal) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct IndexList: View {
    let indexes: [IndexInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(indexes.enumerated()), id: \.offset) { i, index in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Text(index.name).font(.system(size: 12.5, design: .monospaced))
                    Text("on " + index.columns.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    if index.unique { Tag(text: "Unique", tint: Theme.accent) }
                    if index.automatic { Tag(text: "Automatic") }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - SQL

struct SQLPane: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        VSplitView {
            SQLEditor(text: $model.sql) { model.editorSelection = $0 }
                .frame(minHeight: 100, idealHeight: 190)
            VStack(spacing: 0) {
                RunBar(model: model)
                Divider()
                results.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 170)
        }
        .onAppear {
            if model.sql.isEmpty, let name = model.selection { model.sql = "SELECT * FROM \(SQL.quote(name));" }
        }
    }

    @ViewBuilder private var results: some View {
        if let error = model.sqlError {
            ErrorCard(message: error).frame(maxHeight: .infinity, alignment: .top)
        } else if let r = model.sqlResult {
            if r.columns.isEmpty {
                ContentUnavailableView("Done", systemImage: "checkmark.circle",
                                       description: Text(r.changes == 1 ? "1 row changed." : "\(r.changes.grouped) rows changed."))
            } else {
                GridView(result: r)
            }
        } else {
            ContentUnavailableView("Run a query", systemImage: "play.circle",
                                   description: Text("Write SQL above and press ⌘Return. Select part of it to run just that part."))
        }
    }
}

struct RunBar: View {
    @ObservedObject var model: DatabaseModel

    private var status: String {
        if model.running { return "Running…" }
        guard model.sqlError == nil, let r = model.sqlResult else { return "" }
        let time = r.elapsed < 1 ? "\(max(1, Int((r.elapsed * 1000).rounded()))) ms" : String(format: "%.2f s", r.elapsed)
        if r.columns.isEmpty { return "\(r.statements == 1 ? "1 statement" : "\(r.statements) statements") in \(time)" }
        let rows = r.rows.count == 1 ? "1 row" : "\(r.rows.count.grouped) rows"
        return r.truncated ? "First \(rows) in \(time)" : "\(rows) in \(time)"
    }

    var body: some View {
        HStack(spacing: 10) {
            if model.running {
                Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.small)
                    .help("Stop the running query (⌘.)")
            } else {
                Button { model.run() } label: { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(model.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Run the SQL, or only the selected part (⌘Return)")
            }
            KeyCap("⌘↩")
            Menu {
                if model.history.entries.isEmpty {
                    Text("No queries yet")
                } else {
                    ForEach(model.history.entries.prefix(25)) { entry in
                        Button(QueryHistory.title(entry.sql)) { model.useHistory(entry) }
                    }
                    Divider()
                    Button("Clear History") { model.clearHistory() }
                }
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Earlier queries")
            Spacer()
            if model.running { ProgressView().controlSize(.mini) }
            if model.sqlResult?.truncated == true {
                Tag(text: "Limited to \(DatabaseModel.resultLimit.grouped) rows, export gets all", tint: .orange)
            }
            Text(status).font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(.bar)
    }
}

// MARK: - Notices

struct NoticeBanner: View {
    @ObservedObject var model: DatabaseModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Image(systemName: notice.url == nil ? "info.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(notice.url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green))
                Text(notice.text).font(.system(size: 12.5)).lineLimit(2)
                if model.exporting {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.stop() }.controlSize(.small).help("Stop the export (⌘.)")
                }
                if let url = notice.url {
                    Button("Show in Finder") { revealInFinder([url]) }.controlSize(.small)
                }
                if !model.exporting {
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.bottom, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice) {
                guard notice.url != nil else { return }
                try? await Task.sleep(for: .seconds(8))
                if model.notice == notice { model.notice = nil }
            }
        }
    }
}
