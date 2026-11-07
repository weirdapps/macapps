import AppKit
import Kit
import SwiftUI

// MARK: - Chart description

enum ChartKind: String, Codable, CaseIterable, Identifiable {
    case line, bar, stacked, area, scatter, pie

    var id: String { rawValue }

    var name: String {
        switch self {
        case .line: "Line"
        case .bar: "Bar"
        case .stacked: "Stacked"
        case .area: "Area"
        case .scatter: "Scatter"
        case .pie: "Pie"
        }
    }

    var menuName: String { self == .stacked ? "Stacked Bar" : name }

    var symbol: String {
        switch self {
        case .line: "chart.xyaxis.line"
        case .bar: "chart.bar.fill"
        case .stacked: "square.split.1x2.fill"
        case .area: "chart.line.uptrend.xyaxis"
        case .scatter: "chart.dots.scatter"
        case .pie: "chart.pie.fill"
        }
    }

    var shortcut: KeyEquivalent { KeyEquivalent(Character("\((ChartKind.allCases.firstIndex(of: self) ?? 0) + 1)")) }
}

enum PaletteName: String, Codable, CaseIterable, Identifiable {
    case plot, vivid, ocean, pastel, sunset, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .plot: "Plot"
        case .vivid: "Vivid"
        case .ocean: "Ocean"
        case .pastel: "Pastel"
        case .sunset: "Sunset"
        case .graphite: "Graphite"
        }
    }

    var hexes: [UInt32] {
        switch self {
        case .plot: [0x1E6FD9, 0x4FC3F7, 0xF5A524, 0x14B87A, 0xEF4F5F, 0x8B5CF6, 0xEC4899, 0x64748B]
        case .vivid: [0x007AFF, 0xFF9500, 0x34C759, 0xFF3B30, 0xAF52DE, 0x00C7BE, 0xFFCC00, 0x5856D6]
        case .ocean: [0x0B3C8C, 0x1E6FD9, 0x4FC3F7, 0x0E7490, 0x22D3EE, 0x7DD3FC, 0x155E75, 0xA5F3FC]
        case .pastel: [0x7FB3F5, 0xF59E9E, 0x7BD8A4, 0xF6D47A, 0xB7A6F6, 0xF5A3CF, 0x82E0D6, 0xF8B57E]
        case .sunset: [0xF97316, 0xE11D48, 0xFBBF24, 0x9333EA, 0xDB2777, 0xB45309, 0xF472B6, 0x6D28D9]
        case .graphite: [0x1E6FD9, 0x334155, 0x64748B, 0x94A3B8, 0xCBD5E1, 0x0F172A, 0x475569, 0xE2E8F0]
        }
    }

    var colors: [Color] { hexes.map { Color(nsColor: rgb($0)) } }

    /// `count` colours, cycling through the palette when there are more series than colours.
    func colors(_ count: Int) -> [Color] {
        let all = colors
        return (0..<max(count, 1)).map { all[$0 % all.count] }
    }
}

// MARK: - Data table

struct Series: Identifiable, Equatable {
    var id: Int
    var name: String
    var values: [Double?]
}

/// A grid of strings: `headers[0]` names the label column, the other headers name the series.
/// Every row has exactly `headers.count` cells.
struct DataTable: Codable, Hashable {
    var headers: [String]
    var rows: [[String]]

    init(headers: [String], rows: [[String]]) {
        self.headers = headers.isEmpty ? ["Label"] : headers
        self.rows = rows
        normalize()
    }

    /// Decoding goes through `init`, so a hand edited or damaged file with ragged rows is padded, never indexed past its end.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(headers: (try? c.decode([String].self, forKey: .headers)) ?? [],
                  rows: (try? c.decode([[String]].self, forKey: .rows)) ?? [])
    }

    static let blank = DataTable(headers: ["Label", "Series 1"], rows: [])

    /// Pasted or imported tables keep this many rows; a chart of more is unreadable and slow to draw.
    static let maxRows = 5000

    var columnCount: Int { headers.count }

    mutating func normalize() {
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        while headers.count < width { headers.append("Series \(headers.count)") }
        rows = rows.map { $0.count < width ? $0 + Array(repeating: "", count: width - $0.count) : $0 }
    }

    /// Sets a cell; writing one row past the end appends a row, so the grid always has a spare row to type in.
    mutating func set(row: Int, column: Int, to value: String) {
        guard column >= 0, column < columnCount, row >= 0 else { return }
        if row == rows.count {
            guard !value.isEmpty else { return }
            rows.append(Array(repeating: "", count: columnCount))
        }
        guard row < rows.count else { return }
        rows[row][column] = value
    }

    mutating func addRow() { rows.append(Array(repeating: "", count: columnCount)) }

    mutating func addColumn() {
        headers.append("Series \(headers.count)")
        rows = rows.map { $0 + [""] }
    }

    mutating func removeRow(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    mutating func removeColumn(_ index: Int) {
        guard index > 0, index < columnCount, columnCount > 2 else { return }
        headers.remove(at: index)
        rows = rows.map { var r = $0; r.remove(at: index); return r }
    }

    /// Rows with at least one non-empty cell; trailing blank rows never reach the chart.
    var filledRows: [[String]] { rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } } }

    /// Row labels from the first column: blanks get their row number, duplicates a suffix, so each one is unique.
    var labels: [String] {
        DataTable.unique(filledRows.enumerated().map { i, row in
            let label = row[0].trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? "\(i + 1)" : label
        })
    }

    /// Makes names unique with a (2), (3) suffix, also when a suffixed name is itself already taken.
    static func unique(_ names: [String]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            var candidate = name, n = 1
            while used.contains(candidate) {
                n += 1
                candidate = "\(name) (\(n))"
            }
            used.insert(candidate)
            return candidate
        }
    }

    /// The categories to label on the x axis: all of them up to `fit`, otherwise every nth, about `target` in all.
    func axisLabels(fit: Int = 16, target: Int = 10) -> [String] {
        let all = labels
        guard all.count > fit else { return all }
        let step = Int((Double(all.count) / Double(target)).rounded(.up))
        return stride(from: 0, to: all.count, by: step).map { all[$0] }
    }

    /// One series per column after the first, named by its header (made unique).
    var series: [Series] {
        let filled = filledRows
        let columns = Array(1..<max(columnCount, 1))
        let names = DataTable.unique(columns.map { c in
            let name = headers[c].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "Series \(c)" : name
        })
        return zip(columns, names).map { c, name in
            Series(id: c, name: name, values: filled.map { Number.parse($0[c]) })
        }
    }

    /// Numeric x positions for scatter plots: the label column when every label is a number, the row number otherwise.
    var xValues: [Double] {
        let raw = filledRows.map { Number.parse($0[0]) }
        if !raw.isEmpty, raw.allSatisfy({ $0 != nil }) { return raw.map { $0! } }
        return raw.indices.map { Double($0 + 1) }
    }

    var labelsAreNumeric: Bool {
        let raw = filledRows.map { Number.parse($0[0]) }
        return !raw.isEmpty && raw.allSatisfy { $0 != nil }
    }

    var hasNumbers: Bool { series.contains { $0.values.contains { $0 != nil } } }

    /// The table as delimited text, quoting cells that need it.
    func text(separator: Character = "\t") -> String {
        func quote(_ s: String) -> String {
            guard s.contains(separator) || s.contains("\"") || s.contains("\n") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return ([headers] + rows).map { $0.map(quote).joined(separator: String(separator)) }.joined(separator: "\n")
    }

    // MARK: Parsing

    /// Parses CSV, TSV or semicolon separated text, as copied from Numbers, Excel or a file.
    /// A first row whose series cells are not numbers is the header; a single column of numbers gets row labels.
    static func parse(_ text: String) -> DataTable? { read(text)?.table }

    /// Like `parse`, and also says how many rows past `maxRows` were left out.
    static func read(_ text: String) -> (table: DataTable, dropped: Int)? {
        var text = text
        if text.unicodeScalars.first == "\u{FEFF}" { text = String(text.unicodeScalars.dropFirst()) }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var grid = split(normalized, by: delimiter(for: normalized))
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
        while let last = grid.last, last.allSatisfy(\.isEmpty) { grid.removeLast() }
        while let first = grid.first, first.allSatisfy(\.isEmpty) { grid.removeFirst() }
        guard !grid.isEmpty else { return nil }
        let width = grid.map(\.count).max() ?? 0
        grid = grid.map { $0 + Array(repeating: "", count: width - $0.count) }

        if width == 1 {
            // A bare column of numbers: label the rows 1, 2, 3.
            var header = "Value"
            if Number.parse(grid[0][0]) == nil { header = grid.removeFirst()[0] }
            guard !grid.isEmpty, grid.contains(where: { Number.parse($0[0]) != nil }) else { return nil }
            let dropped = max(grid.count - maxRows, 0)
            let rows = grid.prefix(maxRows).enumerated().map { ["\($0.offset + 1)", $0.element[0]] }
            return (DataTable(headers: ["Item", header], rows: rows), dropped)
        }

        let first = grid[0]
        // A header has text over the series, or nothing but years there (Quarter, 2024, 2025), or a blank corner cell.
        let seriesCells = first.dropFirst().filter { !$0.isEmpty }
        let isYear = { (s: String) in s.count == 4 && Int(s).map { (1800...2200).contains($0) } == true }
        // Years over the series only make a header when the values below them are not years too.
        let restAreYears = grid.dropFirst().allSatisfy { $0.dropFirst().allSatisfy { $0.isEmpty || isYear($0) } }
        let isHeader = grid.count > 1 && (seriesCells.isEmpty
            || seriesCells.contains { Number.parse($0) == nil }
            || first[0].isEmpty
            || (Number.parse(first[0]) == nil && seriesCells.allSatisfy(isYear) && !restAreYears))
        var headers: [String]
        if isHeader {
            headers = grid.removeFirst()
            if headers[0].isEmpty { headers[0] = "Label" }
        } else {
            headers = ["Label"] + (1..<width).map { "Series \($0)" }
        }
        guard grid.contains(where: { $0.dropFirst().contains { Number.parse($0) != nil } }) else { return nil }
        let dropped = max(grid.count - maxRows, 0)
        return (DataTable(headers: headers, rows: Array(grid.prefix(maxRows))), dropped)
    }

    /// Text from a file: UTF-16 with a byte order mark (Excel's Unicode Text), UTF-8, or Windows Latin.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
    }

    /// Files larger than this are refused rather than read into a chart nobody could read.
    static let maxFileBytes = 20_000_000

    enum LoadResult: Sendable {
        case table(DataTable, dropped: Int)
        case tooLarge, unreadable
    }

    /// Reads and parses one file. Runs off the main thread.
    static func load(_ url: URL) -> LoadResult {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxFileBytes { return .tooLarge }
        guard let data = try? Data(contentsOf: url), let text = decode(data), let result = read(text) else { return .unreadable }
        return .table(result.table, dropped: result.dropped)
    }

    /// Tab when the text has tabs, then semicolon or comma when it splits most lines into the same number of columns.
    static func delimiter(for text: String) -> Character {
        if text.contains("\t") { return "\t" }
        let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: true).prefix(50))
        for candidate: Character in [";", ","] {
            let counts = split(lines.joined(separator: "\n"), by: candidate).map(\.count)
            guard let mode = Dictionary(grouping: counts, by: { $0 }).max(by: { $0.value.count < $1.value.count })?.key,
                  mode > 1 else { continue }
            let matching = counts.filter { $0 == mode }.count
            if Double(matching) >= Double(counts.count) * 0.8 { return candidate }
        }
        return ","
    }

    /// A small RFC 4180 reader: quoted fields may hold separators, doubled quotes and newlines.
    static func split(_ text: String, by separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? chars.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                quoted = true
            } else if ch == separator {
                row.append(field); field = ""
            } else if ch == "\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// Reading numbers the way people type them: 1,234.5 or 1.234,5, $12, 45%, (300) for negatives, a Unicode minus.
enum Number {
    static func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "\u{2212}", with: "-")
        s.removeAll { "$€£¥₹%' \u{00A0}\u{202F}".contains($0) }
        guard !s.isEmpty else { return nil }
        let hasComma = s.contains(","), hasDot = s.contains(".")
        if hasComma && hasDot {
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            if s.range(of: #"^[-+]?\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
                s = s.replacingOccurrences(of: ",", with: "")
            } else {
                s = s.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot, s.range(of: #"^[-+]?\d{1,3}(\.\d{3}){2,}$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        // Double() also reads hex (0x1F) and words (inf, nan); only plain decimals count as numbers here.
        guard s.unicodeScalars.allSatisfy({ "0123456789+-.eE".unicodeScalars.contains($0) }),
              let value = Double(s), value.isFinite else { return nil }
        return negative ? -value : value
    }

    /// Short labels for values on the chart: 1,250 then 12.5K, 3.4M.
    static func short(_ value: Double) -> String {
        if abs(value) >= 10_000 {
            return value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

// MARK: - Charts

struct PlotChart: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var kind: ChartKind = .bar
    var palette: PaletteName = .plot
    var xLabel = ""
    var yLabel = ""
    var showLegend = true
    var showValues = false
    var table: DataTable
    var modified = Date()

    var subtitle: String {
        let series = max(table.columnCount - 1, 0)
        let rows = table.filledRows.count
        return "\(kind.name) · \(series) series · \(rows) \(rows == 1 ? "row" : "rows")"
    }
}

extension PlotChart {
    /// Missing or unknown fields fall back to defaults, so charts saved by another version still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: (try? c.decode(String.self, forKey: .title)) ?? "Untitled Chart",
                  table: (try? c.decode(DataTable.self, forKey: .table)) ?? .blank)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decode(ChartKind.self, forKey: .kind)) ?? .bar
        palette = (try? c.decode(PaletteName.self, forKey: .palette)) ?? .plot
        xLabel = (try? c.decode(String.self, forKey: .xLabel)) ?? ""
        yLabel = (try? c.decode(String.self, forKey: .yLabel)) ?? ""
        showLegend = (try? c.decode(Bool.self, forKey: .showLegend)) ?? true
        showValues = (try? c.decode(Bool.self, forKey: .showValues)) ?? false
        modified = (try? c.decode(Date.self, forKey: .modified)) ?? Date()
    }
}

struct Toast: Equatable {
    var message: String
    var url: URL?
}

@MainActor
final class PlotModel: ObservableObject {
    static let shared = PlotModel(persisting: true)

    @Published var charts: [PlotChart] { didSet { scheduleSave() } }
    @Published var selection: PlotChart.ID?
    @Published var showInspector = true
    @Published var editingText = false
    @Published var toast: Toast?
    weak var undoManager: UndoManager?
    private let persisting: Bool
    private var saveTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?

    init(persisting: Bool, charts: [PlotChart]? = nil) {
        self.persisting = persisting && !Desktop.isSnapshot
        if let charts {
            self.charts = charts
        } else if self.persisting, let saved = Storage.load([PlotChart].self, app: "Plot", file: "charts.json") {
            self.charts = saved
        } else {
            if self.persisting { PlotModel.setAsideUnreadableStore() }
            self.charts = [Demo.revenue, Demo.visitors]
        }
        selection = self.charts.first?.id
    }

    /// A charts file that exists but cannot be read is renamed, not overwritten by the starter charts.
    nonisolated static func setAsideUnreadableStore() {
        let url = Storage.url(app: "Plot", file: "charts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("charts-unreadable-\(stamp).json"))
    }

    static var demo: PlotModel {
        let model = PlotModel(persisting: false, charts: Demo.all)
        model.selection = Demo.all.first?.id
        return model
    }

    var selected: PlotChart? { charts.first { $0.id == selection } }

    func chart(_ id: PlotChart.ID) -> PlotChart? { charts.first { $0.id == id } }

    /// Changes one chart. With an action name the change is undoable; typing in fields is undone by the field itself.
    func update(_ id: PlotChart.ID?, action: String? = nil, _ change: (inout PlotChart) -> Void) {
        guard let id, let i = charts.firstIndex(where: { $0.id == id }) else { return }
        var chart = charts[i]
        change(&chart)
        guard chart != charts[i] else { return }
        chart.modified = Date()
        if let action {
            perform(action) { self.charts[i] = chart }
        } else {
            charts[i] = chart
        }
    }

    func binding<T>(_ id: PlotChart.ID, _ path: WritableKeyPath<PlotChart, T>, action: String? = nil) -> Binding<T> {
        Binding(
            get: { [weak self] in (self?.chart(id) ?? Demo.revenue)[keyPath: path] },
            set: { [weak self] value in self?.update(id, action: action) { $0[keyPath: path] = value } }
        )
    }

    // MARK: Undoable actions

    private func perform(_ action: String, _ body: () -> Void) {
        let before = charts, selected = selection
        body()
        guard charts != before else { return }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(before, selected, action) }
        }
        undoManager?.setActionName(action)
    }

    private func restore(_ charts: [PlotChart], _ selected: PlotChart.ID?, _ action: String) {
        perform(action) {
            withAnimation(.snappy) {
                self.charts = charts
                self.selection = selected
            }
        }
    }

    func newChart(table: DataTable = .blank, title: String = "Untitled Chart") {
        let chart = PlotChart(title: title, table: table)
        perform("New Chart") {
            withAnimation(.snappy) {
                charts.insert(chart, at: 0)
                selection = chart.id
            }
        }
    }

    func duplicate(_ id: PlotChart.ID?) {
        guard let id, let i = charts.firstIndex(where: { $0.id == id }) else { return }
        var copy = charts[i]
        copy.id = UUID()
        copy.title += " copy"
        copy.modified = Date()
        perform("Duplicate Chart") {
            withAnimation(.snappy) {
                charts.insert(copy, at: i + 1)
                selection = copy.id
            }
        }
    }

    func delete(_ id: PlotChart.ID?) {
        guard let id, let i = charts.firstIndex(where: { $0.id == id }) else { return }
        perform("Delete Chart") {
            withAnimation(.snappy) {
                charts.remove(at: i)
                if selection == id { selection = charts.isEmpty ? nil : charts[min(i, charts.count - 1)].id }
            }
        }
    }

    /// Replaces the selected chart's data with a table from text, or starts a new chart when none is selected.
    @discardableResult
    func paste(_ text: String?) -> Bool {
        guard let text, let (table, dropped) = DataTable.read(text) else {
            show(Toast(message: "The clipboard holds no numbers to plot."))
            return false
        }
        if let id = selection, chart(id) != nil {
            update(id, action: "Paste Data") { $0.table = table }
        } else {
            newChart(table: table)
        }
        if dropped > 0 { show(Toast(message: PlotModel.droppedMessage(dropped))) }
        return true
    }

    func pasteFromClipboard() { paste(NSPasteboard.general.string(forType: .string)) }

    /// New charts from CSV or TSV files, titled after the file.
    /// Files are read and parsed off the main thread, so a large CSV never stalls the window.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            var failed: [String] = [], tooLarge: [String] = [], dropped = 0
            for url in urls {
                switch await Task.detached(priority: .userInitiated, operation: { DataTable.load(url) }).value {
                case let .table(table, cut):
                    dropped += cut
                    newChart(table: table, title: url.deletingPathExtension().lastPathComponent)
                case .tooLarge: tooLarge.append(url.lastPathComponent)
                case .unreadable: failed.append(url.lastPathComponent)
                }
            }
            if !tooLarge.isEmpty {
                show(Toast(message: "Too large to chart (20 MB at most): \(tooLarge.joined(separator: ", "))."))
            } else if !failed.isEmpty {
                show(Toast(message: "No numbers found in \(failed.joined(separator: ", "))."))
            } else if dropped > 0 {
                show(Toast(message: PlotModel.droppedMessage(dropped)))
            }
        }
    }

    static func droppedMessage(_ dropped: Int) -> String {
        "Charted the first \(DataTable.maxRows.formatted()) rows; \(dropped.formatted()) more were left out."
    }

    /// Records one finished cell edit as a single undo step (the field undoes its own keystrokes while it has focus).
    /// `row` nil means the header cell.
    func registerCellEdit(_ id: PlotChart.ID, row: Int?, column: Int, from old: String, to new: String) {
        guard old != new, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.setCell(id, row: row, column: column, to: old)
                model.registerCellEdit(id, row: row, column: column, from: new, to: old)
            }
        }
        undoManager.setActionName("Typing")
    }

    func setCell(_ id: PlotChart.ID, row: Int?, column: Int, to value: String) {
        update(id) { chart in
            if let row {
                chart.table.set(row: row, column: column, to: value)
            } else if column < chart.table.headers.count {
                chart.table.headers[column] = value
            }
        }
    }

    func show(_ toast: Toast) {
        withAnimation(.snappy) { self.toast = toast }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard persisting else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            Storage.save(self.charts, app: "Plot", file: "charts.json")
        }
    }

    func saveNow() {
        guard persisting else { return }
        saveTask?.cancel()
        Storage.save(charts, app: "Plot", file: "charts.json")
    }
}

// MARK: - Demo data

enum Demo {
    static func table(_ text: String) -> DataTable { DataTable.parse(text)! }

    static let revenue = PlotChart(
        title: "Quarterly revenue", kind: .bar, palette: .plot, xLabel: "Quarter", yLabel: "Revenue (€ thousands)",
        showLegend: true, showValues: true,
        table: table("Quarter\t2024\t2025\t2026\nQ1\t182\t214\t268\nQ2\t205\t241\t296\nQ3\t219\t262\t324\nQ4\t248\t301\t361"))

    static let visitors = PlotChart(
        title: "Website visitors", kind: .line, palette: .plot, xLabel: "Month", yLabel: "Visitors",
        table: table("""
        Month,Mac,iPhone,iPad
        Jan,4210,6120,1320
        Feb,4480,6390,1290
        Mar,5120,7010,1460
        Apr,4980,7420,1510
        May,5630,8120,1580
        Jun,6020,8650,1720
        Jul,5810,9230,1690
        Aug,6340,9810,1810
        Sep,6880,10420,1930
        Oct,7210,11050,2010
        Nov,7650,11620,2140
        Dec,8120,12480,2290
        """))

    static let share = PlotChart(
        title: "Browser share", kind: .pie, palette: .vivid, showValues: true,
        table: table("Browser;Share\nSafari;48,5\nChrome;31,2\nFirefox;9,6\nEdge;6,4\nOther;4,3"))

    static let energy = PlotChart(
        title: "Energy mix", kind: .stacked, palette: .sunset, xLabel: "Year", yLabel: "TWh",
        table: table("Year\tSolar\tWind\tHydro\tGas\n2022\t6.1\t10.4\t4.2\t18.0\n2023\t7.9\t11.2\t3.8\t15.6\n2024\t10.2\t12.5\t4.5\t13.1\n2025\t12.8\t13.9\t4.1\t10.7\n2026\t15.6\t15.2\t4.4\t8.2"))

    static let growth = PlotChart(
        title: "Seedling growth", kind: .scatter, palette: .plot, xLabel: "Day", yLabel: "Height (cm)",
        table: table("Day,Basil,Mint\n1,0.4,0.3\n3,1.1,0.7\n5,1.9,1.4\n7,2.6,2.2\n9,3.8,2.9\n11,4.6,3.3\n13,5.9,4.1\n15,6.8,4.6"))

    static let rain = PlotChart(
        title: "Rainfall", kind: .area, palette: .ocean, xLabel: "Month", yLabel: "mm",
        table: table("Month,Athens,London\nJan,56,55\nFeb,46,41\nMar,41,42\nApr,31,44\nMay,23,49\nJun,11,45\nJul,6,45\nAug,7,50\nSep,15,49\nOct,49,69\nNov,58,59\nDec,69,55"))

    static let all = [revenue, visitors, share, energy, growth, rain]
}
