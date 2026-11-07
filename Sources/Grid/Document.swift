import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

/// The file as Finder hands it over: raw bytes. Decoding and parsing happen later, off the main thread, with progress.
struct CSVFile: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText, .tabSeparatedText, .delimitedText, .plainText]

    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    init(data: Data) { self.data = data }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class GridModel: ObservableObject {
    enum Phase: Equatable {
        case loading(Double)
        case ready
        case stopped
    }

    struct Sort: Equatable {
        var column: Int
        var ascending: Bool
    }

    let name: String
    let url: URL?
    private var data: Data

    @Published private(set) var phase: Phase = .loading(0)
    @Published private(set) var encoding: TextEncoding = .utf8
    @Published private(set) var delimiter: Delimiter = .comma
    @Published private(set) var hasHeader = true
    /// Every parsed record, the header row included when there is one.
    private(set) var allRows: [[String]] = []
    @Published private(set) var columns: [String] = []
    private(set) var numeric: [Bool] = []
    /// Bumps when the columns change, so the table rebuilds them.
    @Published private(set) var layoutID = 0

    /// Indices into `allRows` of the rows on screen, in screen order.
    @Published private(set) var visible: [Int] = []
    /// Bumps when `visible` changes, so the table reloads.
    @Published private(set) var generation = 0
    @Published private(set) var busy = false
    @Published private(set) var sort: Sort?
    @Published var query = ""
    @Published var searchColumn: Int?
    @Published var selection = IndexSet()
    /// Bumped by Edit > Find to focus the filter field.
    @Published var findRequest = 0

    @Published var inspectedColumn = 0
    @Published private(set) var stats: ColumnStats?
    @Published var showInspector: Bool {
        didSet { if !Desktop.isSnapshot { UserDefaults.standard.set(showInspector, forKey: "showInspector") } }
    }
    @Published private(set) var notice: String?
    @Published private(set) var exportedURL: URL?

    private var sortedCache: [Int]?
    private var loadTask: Task<Void, Never>?
    private var viewTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(data: Data, name: String, url: URL?) {
        self.data = data
        self.name = name
        self.url = url
        showInspector = Desktop.isSnapshot ? true : (UserDefaults.standard.object(forKey: "showInspector") as? Bool ?? true)
    }

    /// Files split by something other than commas may write decimals with a comma.
    var decimalComma: Bool { delimiter != .comma }
    var bodyStart: Int { hasHeader && !allRows.isEmpty ? 1 : 0 }
    var rowCount: Int { allRows.count - bodyStart }
    var byteCount: Int { data.count }

    func cell(_ row: Int, _ column: Int) -> String {
        guard row >= 0, row < allRows.count else { return "" }
        let r = allRows[row]
        return column >= 0 && column < r.count ? r[column] : ""
    }

    /// The row number as the file counts records, not counting a header.
    func recordNumber(_ row: Int) -> Int { row - bodyStart + 1 }

    // MARK: Loading

    /// Decodes and parses the file in the background. Without overrides it detects encoding, delimiter and header.
    func load(encoding forcedEncoding: TextEncoding? = nil, delimiter forcedDelimiter: Delimiter? = nil, header forcedHeader: Bool? = nil) {
        loadTask?.cancel()
        viewTask?.cancel()
        statsTask?.cancel()
        phase = .loading(0)
        let data = data
        let preferTab = ["tsv", "tab"].contains(url?.pathExtension.lowercased() ?? "")
        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            let (text, encoding): (String, TextEncoding)
            if let forcedEncoding { (text, encoding) = (CSV.decode(data, as: forcedEncoding), forcedEncoding) } else { (text, encoding) = CSV.decode(data) }
            let delimiter = forcedDelimiter ?? CSV.detectDelimiter(text, preferred: preferTab ? .tab : nil)
            var last = 0.0
            let rows = CSV.parse(text, delimiter: delimiter) { fraction in
                if Task.isCancelled { return false }
                if fraction - last > 0.01 {
                    last = fraction
                    Task { @MainActor [weak self] in
                        if case .loading = self?.phase { self?.phase = .loading(fraction) }
                    }
                }
                return true
            }
            guard let rows, !Task.isCancelled else { return }
            let comma = delimiter != .comma
            let header = forcedHeader ?? CSV.detectHeader(rows, decimalComma: comma)
            let width = rows.reduce(0) { max($0, $1.count) }
            let start = header && !rows.isEmpty ? 1 : 0
            let numeric = (0..<width).map { CSV.isNumericColumn(rows, column: $0, from: start, decimalComma: comma) }
            await MainActor.run { [weak self] in
                self?.finishLoad(rows: rows, encoding: encoding, delimiter: delimiter, header: header, width: width, numeric: numeric)
            }
        }
    }

    func finishLoad(rows: [[String]], encoding: TextEncoding, delimiter: Delimiter, header: Bool, width: Int, numeric: [Bool]) {
        // The rows on screen index the old records; a reload with another encoding or delimiter can have far fewer.
        // Clear them first so the table never asks for a record that no longer exists.
        visible = []
        selection = []
        stats = nil
        generation += 1
        allRows = rows
        self.encoding = encoding
        self.delimiter = delimiter
        self.numeric = numeric
        applyHeader(header, width: width)
        phase = .ready
    }

    private func applyHeader(_ header: Bool, width: Int) {
        hasHeader = header
        let names = header ? (allRows.first ?? []) : []
        columns = (0..<width).map { c in
            let n = c < names.count ? names[c].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            return n.isEmpty ? CSV.columnLetter(c) : n
        }
        if inspectedColumn >= width { inspectedColumn = 0 }
        if let s = sort, s.column >= width { sort = nil }
        if let c = searchColumn, c >= width { searchColumn = nil }
        layoutID += 1
        sortedCache = nil
        refresh()
    }

    func cancelLoad() {
        loadTask?.cancel()
        phase = .stopped
    }

    func setEncoding(_ e: TextEncoding) { if e != encoding { load(encoding: e, header: nil) } }
    func setDelimiter(_ d: Delimiter) { if d != delimiter { load(encoding: encoding, delimiter: d) } }

    func setHeader(_ on: Bool) {
        guard on != hasHeader, phase == .ready else { return }
        numeric = (0..<columns.count).map { CSV.isNumericColumn(allRows, column: $0, from: on ? 1 : 0, decimalComma: decimalComma) }
        applyHeader(on, width: columns.count)
    }

    // MARK: Sort, filter, stats

    func setSort(_ sort: Sort?) {
        guard sort != self.sort else { return }
        self.sort = sort
        sortedCache = nil
        refresh()
    }

    /// Recomputes the visible rows in the background: sort (cached until the sort changes), then filter.
    func refresh(debounce: Bool = false) {
        viewTask?.cancel()
        let rows = allRows, start = bodyStart, sort = sort, query = query, column = searchColumn, cached = sortedCache
        let comma = decimalComma
        busy = true
        viewTask = Task.detached(priority: .userInitiated) { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(160)) }
            if Task.isCancelled { return }
            let order: [Int]?
            if let cached { order = cached } else if let sort {
                order = CSV.sortedOrder(rows, from: start, column: sort.column, ascending: sort.ascending, decimalComma: comma) { Task.isCancelled }
            } else {
                order = Array(start..<max(start, rows.count))
            }
            guard let order, let shown = CSV.filter(rows, order: order, query: query, column: column, isCancelled: { Task.isCancelled }),
                  !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.sortedCache = order
                self.visible = shown
                self.selection = []
                self.generation += 1
                self.busy = false
                self.refreshStats()
            }
        }
    }

    func refreshStats() {
        statsTask?.cancel()
        guard inspectedColumn < columns.count else { stats = nil; return }
        let rows = allRows, shown = visible, column = inspectedColumn, comma = decimalComma
        statsTask = Task.detached(priority: .utility) { [weak self] in
            guard let s = CSV.stats(rows, indices: shown, column: column, decimalComma: comma, isCancelled: { Task.isCancelled }), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled, self.inspectedColumn == column else { return }
                self.stats = s
            }
        }
    }

    func inspect(_ column: Int) {
        guard column != inspectedColumn, column < columns.count else { return }
        inspectedColumn = column
        stats = nil
        refreshStats()
    }

    // MARK: Copy and export

    var numericSet: Set<Int> { Set(numeric.indices.filter { numeric[$0] }) }

    /// Copies rows on screen as text. Plain Copy gives TSV without the header, which pastes into any spreadsheet;
    /// the Copy As formats carry the header. The text is built off the main thread: a Select All of a million rows
    /// is hundreds of megabytes.
    func copy(_ viewRows: IndexSet? = nil, format: CopyFormat, header: Bool = true) {
        let rows = viewRows ?? selection
        guard !rows.isEmpty, !Desktop.isSnapshot else { return }
        let picked = rows.filter { $0 < visible.count }.map { visible[$0] }
        let all = allRows, head: [String]? = header ? columns : nil, width = columns.count, numeric = numericSet
        busy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = CSV.serialize(header: head, rows: picked.map { all[$0] }, format: format, columns: width, numeric: numeric)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.say("Copied \(picked.count == 1 ? "1 row" : "\(CSV.format(picked.count)) rows") as \(format.label)")
            }
        }
    }

    var canCopy: Bool { phase == .ready && !selection.isEmpty }
    var canExport: Bool { phase == .ready && !visible.isEmpty }

    func export() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let base = (name as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + (visible.count == rowCount ? " copy.csv" : " filtered.csv")
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        panel.message = "Exports the \(CSV.format(visible.count)) rows on screen, in their current order, as UTF-8 CSV."
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let rows = allRows, order = visible, width = columns.count, header: [String]? = hasHeader ? columns : nil
        busy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let failure: String?
            do {
                try CSV.export(header: header, rows: rows, order: order, columns: width, to: target)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy = false
                if let failure {
                    self.say("Export failed: \(failure)")
                } else {
                    self.exportedURL = target
                    self.say("Exported \(CSV.format(order.count)) rows to \(target.lastPathComponent)", seconds: 8)
                }
            }
        }
    }

    func say(_ text: String, seconds: Double = 3) {
        noticeTask?.cancel()
        withAnimation(.snappy) { notice = text }
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            withAnimation(.snappy) {
                self?.notice = nil
                self?.exportedURL = nil
            }
        }
    }

    // MARK: Demo

    /// Fixed sample data for the website screenshot: a sorted order book with a few rows selected.
    static var demo: GridModel {
        let text = DemoData.csv
        let m = GridModel(data: Data(text.utf8), name: "orders-2026.csv", url: nil)
        let rows = CSV.parse(text, delimiter: .comma) ?? []
        let width = rows.first?.count ?? 0
        m.allRows = rows
        m.numeric = (0..<width).map { CSV.isNumericColumn(rows, column: $0, from: 1) }
        m.hasHeader = true
        m.columns = rows.first ?? []
        m.sort = Sort(column: 7, ascending: false)
        m.visible = CSV.sortedOrder(rows, from: 1, column: 7, ascending: false) ?? []
        m.selection = IndexSet([1, 2, 3])
        m.inspectedColumn = 7
        m.stats = CSV.stats(rows, indices: m.visible, column: 7)
        m.phase = .ready
        m.layoutID = 1
        m.generation = 1
        return m
    }
}

enum DemoData {
    static var csv: String {
        let customers = ["Avery Chen", "Lucía Romero", "Noah Fischer", "Mia Laurent", "Kenji Sato", "Sofia Rossi", "Liam O'Brien",
                         "Emma Johansson", "Mateo Silva", "Chloé Martin", "Elena Popescu", "Jonas Berg", "Amara Okafor",
                         "Ivan Petrov", "Hana Kim", "Oliver Smith", "Zoe Andersen", "Luca Bianchi"]
        let cities = ["Lisbon", "Berlin", "Paris", "Madrid", "Milan", "Vienna", "Dublin", "Oslo", "Athens", "Tokyo", "Seoul", "Austin"]
        let products: [(String, Double)] = [("Desk lamp", 49), ("Walnut desk", 640), ("Office chair", 389), ("Monitor arm", 129),
                                            ("Bookshelf", 279), ("Standing mat", 59), ("Pendant light", 189), ("Lounge chair", 1120),
                                            ("Side table", 165), ("Rug, wool", 420)]
        let statuses = ["Delivered", "Delivered", "Delivered", "Shipped", "Shipped", "Processing", "Returned"]
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var lines = ["Order,Date,Customer,City,Product,Qty,Unit price,Total,Status"]
        for i in 0..<2400 {
            let p = products[next(products.count)]
            let qty = 1 + next(next(4) == 0 ? 12 : 3)
            let price = p.1 * (1 - Double(next(4)) * 0.05)
            let day = 1 + next(28), month = 1 + next(10)
            let total = (price * Double(qty) * 100).rounded() / 100
            let product = p.0.contains(",") ? "\"\(p.0)\"" : p.0
            lines.append("\(10_481 + i),2026-\(String(format: "%02d", month))-\(String(format: "%02d", day)),\(customers[next(customers.count)]),"
                + "\(cities[next(cities.count)]),\(product),\(qty),\(String(format: "%.2f", price)),\(String(format: "%.2f", total)),"
                + statuses[next(statuses.count)])
        }
        return lines.joined(separator: "\n")
    }
}
