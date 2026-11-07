import AppKit
import Combine
import Kit
import SwiftUI
import UniformTypeIdentifiers

/// One window's database: the connection, what the sidebar lists, the page on screen and the SQL editor.
@MainActor
final class DatabaseModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data", schema = "Schema", sql = "SQL"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .data: "tablecells"
            case .schema: "list.bullet.rectangle"
            case .sql: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    enum Phase: Equatable {
        case empty, loading, open, failed(String)
    }

    struct Notice: Equatable {
        var text: String
        var url: URL?
    }

    static let pageSize = 500
    static let resultLimit = 10_000

    @Published private(set) var url: URL?
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var readOnly = true
    @Published private(set) var objects: [DBObject] = []
    @Published var selection: String? {
        didSet { if selection != oldValue { selectionChanged() } }
    }
    @Published var mode: Mode = .data
    @Published private(set) var page = 0
    @Published private(set) var sort: SortKey?
    @Published private(set) var pageResult: ResultSet?
    @Published private(set) var pageError: String?
    @Published private(set) var schema: TableSchema?
    @Published var sql = ""
    @Published private(set) var sqlResult: ResultSet?
    @Published private(set) var sqlError: String?
    @Published private(set) var running = false
    @Published private(set) var exporting = false
    @Published private(set) var history = QueryHistory()
    @Published var confirmingWrite = false
    @Published var notice: Notice?
    @Published private(set) var fileSize: Int64 = 0

    /// The text selected in the SQL editor; Run runs only that when there is some.
    var editorSelection = ""

    let isDemo: Bool
    private(set) var db: Database?
    private var historyFeed: AnyCancellable?
    private var pageToken = 0
    private var schemaToken = 0

    init(demo: Bool = false) {
        isDemo = demo
        if !demo, !Desktop.isSnapshot {
            history = Self.storedHistory
            // Another window ran a query: show it in this window's history too.
            historyFeed = NotificationCenter.default.publisher(for: Self.historyChanged).sink { [weak self] _ in
                MainActor.assumeIsolated { self?.history = Self.storedHistory }
            }
        }
    }

    static let historyChanged = Notification.Name("LiteHistoryChanged")
    private static var storedHistory: QueryHistory { Storage.load(QueryHistory.self, app: "Lite", file: "history.json") ?? QueryHistory() }

    /// Changes the history every window shares, starting from what is on disk so no window's queries are lost.
    private func changeHistory(_ change: (inout QueryHistory) -> Void) {
        guard !isDemo, !Desktop.isSnapshot else { change(&history); return }
        var stored = Self.storedHistory
        change(&stored)
        Storage.save(stored, app: "Lite", file: "history.json")
        history = stored
        NotificationCenter.default.post(name: Self.historyChanged, object: nil)
    }

    var fileName: String { url?.lastPathComponent ?? "Lite" }
    var tables: [DBObject] { objects.filter { !$0.isView } }
    var views: [DBObject] { objects.filter(\.isView) }
    var selectedObject: DBObject? { objects.first { $0.name == selection } }
    var isOpen: Bool { phase == .open }

    var totalRows: Int? { selectedObject?.rowCount }
    var pageCount: Int { max(1, Int((Double(totalRows ?? 0) / Double(Self.pageSize)).rounded(.up))) }
    var canGoBack: Bool { isOpen && page > 0 }
    var canGoForward: Bool {
        guard isOpen, let r = pageResult else { return false }
        if let totalRows { return (page + 1) * Self.pageSize < totalRows }
        return r.rows.count == Self.pageSize
    }

    var canExport: Bool {
        guard isOpen, !exporting else { return false }
        switch mode {
        case .sql: return !(sqlResult?.columns.isEmpty ?? true)
        default: return selection != nil
        }
    }

    // MARK: Opening

    func open(_ url: URL) {
        self.url = url
        Recents.shared.add(url)
        reopen(readOnly: true, keepSelection: false)
    }

    private func reopen(readOnly: Bool, keepSelection: Bool) {
        guard let url else { return }
        let previous = keepSelection ? selection : nil
        phase = .loading
        db = nil
        if !keepSelection {
            objects = []; pageResult = nil; schema = nil; sqlResult = nil; sqlError = nil
        }
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Database, Error>
            if !SQL.looksLikeDatabase(URL(fileURLWithPath: path)) {
                result = .failure(FileManager.default.fileExists(atPath: path)
                    ? LiteError.notDatabase : LiteError.sqlite("The file could not be found. It may have been moved or deleted."))
            } else {
                result = Result { Database(try Connection(path: path, readOnly: readOnly), counter: try? Connection(path: path, readOnly: true)) }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.url?.path == path else { return }
                    switch result {
                    case .success(let database):
                        self.db = database
                        self.readOnly = readOnly
                        self.phase = .open
                        self.loadObjects(select: previous)
                    case .failure(let error):
                        self.phase = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Runs `work` on the database queue and hands the result back on the main actor. The demo runs inline.
    /// With `counting`, the work goes to the counting connection when there is one.
    private func perform<T>(counting: Bool = false, _ work: @escaping (Connection) throws -> T,
                            done: @escaping @MainActor (Result<T, Error>) -> Void) {
        guard let db else { return }
        if isDemo {
            done(Result { try work(db.connection) })
            return
        }
        let (connection, queue) = counting && db.counter != nil ? (db.counter ?? db.connection, db.countQueue) : (db.connection, db.queue)
        queue.async {
            let result = Result { try work(connection) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.db === db else { return } // Reopened meanwhile.
                    done(result)
                }
            }
        }
    }

    func reload() {
        guard isOpen else { return }
        loadObjects(select: selection)
    }

    private func loadObjects(select: String?) {
        perform({ try $0.objects() }) { result in
            switch result {
            case .success(let list):
                let counts = Dictionary(uniqueKeysWithValues: self.objects.map { ($0.name, $0.rowCount) })
                self.objects = list.map { var o = $0; o.rowCount = counts[o.name] ?? nil; return o }
                let keep = select.flatMap { name in list.contains { $0.name == name } ? name : nil }
                let wanted = keep ?? self.tables.first?.name ?? list.first?.name
                if self.selection == wanted { self.selectionChanged(keepPage: true) } else { self.selection = wanted }
                self.countRows(list.map(\.name))
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Counts rows table by table in the background, so a huge table never holds up the window.
    private func countRows(_ names: [String]) {
        for name in names {
            perform(counting: true, { try $0.count(name) }) { result in
                guard let i = self.objects.firstIndex(where: { $0.name == name }) else { return }
                self.objects[i].rowCount = try? result.get()
            }
        }
    }

    // MARK: Browsing

    private func selectionChanged(keepPage: Bool = false) {
        if !keepPage { page = 0; sort = nil }
        pageResult = nil
        pageError = nil
        if mode == .sql, !keepPage { mode = .data }
        loadPage()
        loadSchema()
    }

    func setSort(_ key: SortKey?) {
        guard key != sort else { return }
        sort = key
        page = 0
        loadPage()
    }

    func nextPage() { if canGoForward { page += 1; loadPage() } }
    func previousPage() { if canGoBack { page -= 1; loadPage() } }

    private func loadPage() {
        guard let object = selectedObject else { pageResult = nil; return }
        pageToken += 1
        let token = pageToken
        let sql = SQL.page(table: object.name, sort: sort, offset: page * Self.pageSize, limit: Self.pageSize)
        perform({ try $0.query(sql) }) { result in
            guard token == self.pageToken else { return }
            switch result {
            case .success(let r): self.pageResult = r; self.pageError = nil
            case .failure(let error): self.pageResult = nil; self.pageError = error.localizedDescription
            }
        }
    }

    private func loadSchema() {
        guard let object = selectedObject else { schema = nil; return }
        schemaToken += 1
        let token = schemaToken
        perform({ try $0.schema(object) }) { result in
            guard token == self.schemaToken else { return }
            self.schema = try? result.get()
        }
    }

    // MARK: SQL

    func run() {
        guard isOpen, !running else { return }
        let selected = editorSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = selected.isEmpty ? sql : selected
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        mode = .sql
        running = true
        let writable = !readOnly
        perform({ try $0.run(script: text, limit: Self.resultLimit) }) { result in
            self.running = false
            switch result {
            case .success(let r):
                self.sqlResult = r
                self.sqlError = nil
                if writable { self.reload() }
            case .failure(let error):
                self.sqlResult = nil
                self.sqlError = error.localizedDescription
            }
            let name = self.fileName
            self.changeHistory { $0.add(text, database: name) }
        }
    }

    /// Stops the running query or export.
    func stop() { db?.interrupt() }

    func useHistory(_ entry: HistoryEntry) {
        sql = entry.sql
        editorSelection = ""
        mode = .sql
    }

    func clearHistory() {
        changeHistory { $0 = QueryHistory() }
    }

    // MARK: Writing

    func toggleReadOnly() {
        guard isOpen, !isDemo else { return }
        if readOnly { confirmingWrite = true } else { reopen(readOnly: true, keepSelection: true) }
    }

    func allowWriting() { reopen(readOnly: false, keepSelection: true) }

    // MARK: Export

    func export() {
        guard canExport, !Desktop.isSnapshot else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let base = mode == .sql ? (url?.deletingPathExtension().lastPathComponent ?? "Query") + " query" : (selection ?? "Table")
        panel.nameFieldStringValue = base + ".csv"
        guard panel.runModal() == .OK, let target = panel.url else { return }

        if mode == .sql, let r = sqlResult {
            if !r.truncated || !r.sourceIsReadOnly {
                do {
                    try CSV.text(columns: r.columns, rows: r.rows).write(to: target, atomically: true, encoding: .utf8)
                    notice = Notice(text: "Exported \(r.rows.count.grouped) rows to \(target.lastPathComponent)", url: target)
                } catch {
                    notice = Notice(text: error.localizedDescription, url: nil)
                }
                return
            }
            exportQuery(r.source, to: target)
        } else if let name = selection {
            exportQuery(SQL.all(table: name, sort: sort), to: target)
        }
    }

    private func exportQuery(_ query: String, to target: URL) {
        notice = Notice(text: "Exporting to \(target.lastPathComponent)…", url: nil)
        exporting = true
        perform({ try $0.exportCSV(query, to: target) }) { result in
            self.exporting = false
            switch result {
            case .success(let n): self.notice = Notice(text: "Exported \(n.grouped) rows to \(target.lastPathComponent)", url: target)
            case .failure(let error):
                self.notice = Notice(text: (error as? LiteError) == .stopped ? "Export stopped." : error.localizedDescription, url: nil)
            }
        }
    }
}

// MARK: - Demo

extension DatabaseModel {
    /// A made up music store in memory, for the website screenshot.
    static var demo: DatabaseModel {
        let model = DatabaseModel(demo: true)
        guard let connection = try? Demo.connection() else { return model }
        model.url = URL(fileURLWithPath: "/Users/demo/Music Store.sqlite")
        model.fileSize = 2_412_544
        model.db = Database(connection)
        model.phase = .open
        model.readOnly = true
        model.loadObjects(select: "tracks")
        model.sql = """
            -- Longest albums, with their artist
            SELECT ar.name AS artist, al.title AS album,
                   count(*) AS tracks,
                   round(sum(t.milliseconds) / 60000.0, 1) AS minutes
            FROM tracks t
            JOIN albums al ON al.id = t.album_id
            JOIN artists ar ON ar.id = al.artist_id
            GROUP BY al.id
            ORDER BY minutes DESC
            LIMIT 50;
            """
        for (i, q) in ["SELECT * FROM customers WHERE country = 'Greece';", "SELECT genre, count(*) FROM tracks GROUP BY genre;",
                       "PRAGMA table_info(invoices);"].enumerated() {
            model.history.add(q, database: model.fileName, date: Date(timeIntervalSinceNow: Double(-3600 * (i + 1))))
        }
        model.run()
        model.mode = .data
        return model
    }
}

enum Demo {
    static func connection() throws -> Connection {
        let c = try Connection(path: ":memory:", readOnly: false, create: true)
        try c.exec("""
            CREATE TABLE artists (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE albums (id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist_id INTEGER NOT NULL REFERENCES artists(id), year INTEGER);
            CREATE TABLE genres (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
            CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                album_id INTEGER REFERENCES albums(id),
                genre TEXT,
                composer TEXT,
                milliseconds INTEGER NOT NULL,
                bytes INTEGER,
                unit_price REAL NOT NULL DEFAULT 0.99
            );
            CREATE INDEX tracks_album ON tracks(album_id);
            CREATE INDEX tracks_genre_name ON tracks(genre, name);
            CREATE TABLE customers (id INTEGER PRIMARY KEY, first_name TEXT, last_name TEXT, city TEXT, country TEXT, email TEXT UNIQUE);
            CREATE TABLE invoices (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), date TEXT, total REAL);
            CREATE TABLE invoice_items (id INTEGER PRIMARY KEY, invoice_id INTEGER REFERENCES invoices(id), track_id INTEGER REFERENCES tracks(id), quantity INTEGER DEFAULT 1);
            CREATE TABLE playlists (id INTEGER PRIMARY KEY, name TEXT);
            CREATE VIEW album_lengths AS SELECT al.title, count(*) AS tracks, sum(t.milliseconds) AS ms FROM tracks t JOIN albums al ON al.id = t.album_id GROUP BY al.id;
            CREATE VIEW top_customers AS SELECT c.first_name || ' ' || c.last_name AS name, sum(i.total) AS spent FROM invoices i JOIN customers c ON c.id = i.customer_id GROUP BY c.id ORDER BY spent DESC;
            """)
        var rng = Rng(seed: 7)
        let first = ["Glass", "Neon", "Paper", "Velvet", "Silver", "Quiet", "Hollow", "Golden", "Northern", "Wild", "Electric", "Amber",
                     "Midnight", "Coral", "Iron", "Lunar", "Copper", "Indigo", "Static", "Winter"]
        let second = ["Harbor", "Orchard", "Lanterns", "Engines", "Atlas", "Tides", "Parade", "Comets", "Foxes", "Gardens", "Signals",
                      "Rivers", "Choir", "Pilots", "Mirrors", "Season", "Arcade", "Valley", "Kites", "Machines"]
        let words = ["Morning", "Light", "Echo", "Driftwood", "Satellite", "Home", "Ocean", "Fever", "Summer", "Shadows", "Run",
                     "Heartbeat", "Window", "Dust", "Coastline", "Gravity", "Stars", "Avenue", "Wire", "Bloom", "Weather", "Ghost",
                     "Paper Planes", "Salt", "Horizon", "Low Tide", "Daydream", "Northbound", "Sparks", "Velvet Sky"]
        let genres = ["Rock", "Jazz", "Electronic", "Alternative", "Pop", "Classical", "Blues", "Soundtrack", "Latin", "Folk",
                      "Hip Hop", "Metal", "Reggae", "Soul", "Ambient", "Country", "World", "Indie"]
        let composers = ["A. Reyes", "M. Lindqvist", "J. Okafor", "S. Moreau", "K. Tanaka", "L. Petrova", "D. Costa", "E. Novak", "R. Haddad"]
        try c.exec("BEGIN;")
        var artists: [String] = []
        for a in first { for b in second where artists.count < 120 && rng.next(4) != 0 { artists.append("\(a) \(b)") } }
        for (i, name) in artists.enumerated() { try c.exec("INSERT INTO artists VALUES (\(i + 1), '\(name)');") }
        for (i, g) in genres.enumerated() { try c.exec("INSERT INTO genres VALUES (\(i + 1), '\(g)');") }
        for i in 1...340 {
            let title = words[rng.next(words.count)] + (rng.next(3) == 0 ? " Sessions" : "")
            try c.exec("INSERT INTO albums VALUES (\(i), '\(title)', \(rng.next(artists.count) + 1), \(1968 + rng.next(57)));")
        }
        for i in 1...3503 {
            let name = rng.next(5) == 0 ? "\(words[rng.next(words.count)]) (\(["Live", "Remastered", "Acoustic", "Demo"][rng.next(4)]))"
                : "\(words[rng.next(words.count)])\(rng.next(3) == 0 ? " " + words[rng.next(words.count)] : "")"
            let composer = rng.next(4) == 0 ? "NULL" : "'\(composers[rng.next(composers.count)])'"
            let ms = 150_000 + rng.next(240_000)
            try c.exec("""
                INSERT INTO tracks VALUES (\(i), '\(name)', \((i - 1) / 11 % 340 + 1), '\(genres[rng.next(genres.count)])', \(composer), \(ms), \(ms * 33 + rng.next(90_000)), \(rng.next(6) == 0 ? "1.99" : "0.99"));
                """)
        }
        let cities = [("Athens", "Greece"), ("Lisbon", "Portugal"), ("Oslo", "Norway"), ("Toronto", "Canada"), ("Prague", "Czechia"),
                      ("Austin", "USA"), ("Sydney", "Australia"), ("Berlin", "Germany"), ("Dublin", "Ireland"), ("Lyon", "France")]
        let names = ["Eleni", "Marco", "Ingrid", "Noah", "Petra", "Lucas", "Aiko", "Sofia", "Liam", "Clara", "Yusuf", "Nina"]
        let surnames = ["Papadaki", "Silva", "Berg", "Martin", "Novak", "Weber", "Sato", "Rossi", "Byrne", "Laurent"]
        for i in 1...59 {
            let (city, country) = cities[rng.next(cities.count)]
            let f = names[rng.next(names.count)], l = surnames[rng.next(surnames.count)]
            try c.exec("INSERT INTO customers VALUES (\(i), '\(f)', '\(l)', '\(city)', '\(country)', '\(f.lowercased()).\(l.lowercased())\(i)@example.com');")
        }
        for i in 1...412 {
            try c.exec("INSERT INTO invoices VALUES (\(i), \(rng.next(59) + 1), '2025-\(String(format: "%02d-%02d", rng.next(12) + 1, rng.next(28) + 1))', \(Double(rng.next(2000) + 99) / 100));")
        }
        for i in 1...2240 { try c.exec("INSERT INTO invoice_items VALUES (\(i), \(rng.next(412) + 1), \(rng.next(3503) + 1), 1);") }
        for (i, p) in ["Favourites", "Road trip", "Focus", "Sunday morning", "Workout", "Dinner party", "Rainy day", "Late night",
                       "Classics", "Discover", "Running", "Coding", "Party", "Chill", "Throwbacks", "Live sets", "Acoustic", "Sleep"].enumerated() {
            try c.exec("INSERT INTO playlists VALUES (\(i + 1), '\(p)');")
        }
        try c.exec("COMMIT;")
        try c.lock()
        return c
    }

    /// A tiny deterministic generator, so the demo looks the same every time.
    struct Rng {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(max(n, 1)))
        }
    }
}

// MARK: - Recents and routing

/// Recently opened databases for File > Open Recent.
@MainActor
final class Recents: ObservableObject {
    static let shared = Recents()
    private static let key = "recentDatabases"
    @Published private(set) var urls: [URL] = []

    init() {
        guard !Desktop.isSnapshot else { return }
        urls = (UserDefaults.standard.stringArray(forKey: Self.key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ url: URL) {
        guard !Desktop.isSnapshot, !SelfTest.isRunning, url.path.hasPrefix("/") else { return }
        urls.removeAll { $0.path == url.path }
        urls.insert(url, at: 0)
        if urls.count > 10 { urls.removeLast(urls.count - 10) }
        UserDefaults.standard.set(urls.map(\.path), forKey: Self.key)
    }

    func clear() {
        urls = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// Hands files from Finder (Open With, drops on the Dock icon) to a window, once a window exists.
@MainActor
final class Router {
    static let shared = Router()
    private var pending: [URL] = []
    private var handler: ((URL) -> Void)?

    func open(_ urls: [URL]) {
        if let handler { urls.forEach(handler) } else { pending += urls }
    }

    func attach(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        let waiting = pending
        pending = []
        waiting.forEach(handler)
    }
}

enum FileTypes {
    static let extensions = ["sqlite", "sqlite3", "db", "db3", "sqlitedb"]
    static var all: [UTType] { extensions.compactMap { UTType(filenameExtension: $0) } }

    /// Asks for a database with the standard Open panel.
    @MainActor
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = all
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a SQLite database. Lite opens it read only."
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Int {
    /// Digits grouped for the reader's locale; the website screenshot always uses English grouping.
    var grouped: String {
        formatted(.number.locale(Desktop.isSnapshot ? Locale(identifier: "en_US") : .current))
    }
}
