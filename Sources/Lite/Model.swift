import Foundation
import SQLite3

// MARK: - Values and results

/// One cell, as SQLite stores it. Blobs keep only their size; export reads the bytes again.
enum SQLValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Int)

    /// What a grid cell shows.
    var display: String {
        switch self {
        case .null: "NULL"
        case .integer(let v): String(v)
        case .real(let v): String(v)
        case .text(let s): s
        case .blob(let n): "BLOB " + ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
        }
    }

    /// The text that goes into CSV and onto the clipboard. NULL becomes an empty field.
    var plain: String {
        switch self {
        case .null: ""
        default: display
        }
    }

    var isNumeric: Bool {
        switch self {
        case .integer, .real: true
        default: false
        }
    }

    /// SQLite's own ordering across storage classes: NULL, numbers, text, blobs.
    static func ascending(_ a: SQLValue, _ b: SQLValue) -> Bool {
        func rank(_ v: SQLValue) -> Int {
            switch v {
            case .null: 0
            case .integer, .real: 1
            case .text: 2
            case .blob: 3
            }
        }
        switch (a, b) {
        case (.integer(let x), .integer(let y)): return x < y
        case (.integer(let x), .real(let y)): return Double(x) < y
        case (.real(let x), .integer(let y)): return x < Double(y)
        case (.real(let x), .real(let y)): return x < y
        case (.text(let x), .text(let y)): return x.localizedStandardCompare(y) == .orderedAscending
        case (.blob(let x), .blob(let y)): return x < y
        default: return rank(a) < rank(b)
        }
    }
}

struct ResultSet: Sendable {
    var columns: [String]
    var rows: [[SQLValue]]
    /// More rows exist than were fetched.
    var truncated = false
    /// Rows inserted, updated or deleted by the statements that ran.
    var changes = 0
    var elapsed: TimeInterval = 0
    var statements = 1
    /// The statement that produced `rows`, so a truncated result can be exported in full.
    var source = ""
    var sourceIsReadOnly = true
}

struct SortKey: Hashable, Sendable {
    var column: String
    var ascending: Bool
}

struct DBObject: Identifiable, Hashable, Sendable {
    var name: String
    var isView: Bool
    var sql: String
    var rowCount: Int?
    var id: String { name }
}

struct ColumnInfo: Hashable, Sendable {
    var name: String
    var type: String
    var notNull: Bool
    var defaultValue: String?
    var primaryKey: Int
    var references: String?
}

struct IndexInfo: Hashable, Sendable {
    var name: String
    var columns: [String]
    var unique: Bool
    var automatic: Bool
    var sql: String?
}

struct TableSchema: Sendable {
    var name: String
    var isView: Bool
    var columns: [ColumnInfo]
    var indexes: [IndexInfo]
    var sql: String
}

enum LiteError: LocalizedError, Equatable {
    case sqlite(String)
    case readOnly
    case notDatabase
    case nothingToRun

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): message.prefix(1).uppercased() + message.dropFirst()
        case .readOnly: "This statement changes the database. Lite opened it read only; choose Database > Allow Writing to run it."
        case .notDatabase: "This file is not a SQLite database."
        case .nothingToRun: "There is no SQL to run."
        }
    }
}

// MARK: - SQL text helpers

enum SQL {
    /// Quotes an identifier for SQLite: "my ""odd"" table".
    static func quote(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func page(table: String, sort: SortKey?, offset: Int, limit: Int) -> String {
        var sql = "SELECT * FROM \(quote(table))"
        if let sort { sql += " ORDER BY \(quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")" }
        sql += " LIMIT \(limit) OFFSET \(offset)"
        return sql
    }

    static func all(table: String, sort: SortKey?) -> String {
        var sql = "SELECT * FROM \(quote(table))"
        if let sort { sql += " ORDER BY \(quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")" }
        return sql
    }

    /// True when the file starts with the SQLite header. An empty file is a valid, empty database.
    static func looksLikeDatabase(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        return head.isEmpty || head == Data("SQLite format 3\0".utf8)
    }
}

enum CSV {
    static func field(_ s: String) -> String {
        let needsQuotes = s.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
            || s.first == " " || s.last == " "
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func line(_ fields: [String]) -> String {
        fields.map(field).joined(separator: ",") + "\r\n"
    }

    static func text(columns: [String], rows: [[SQLValue]]) -> String {
        line(columns) + rows.map { line($0.map(\.plain)) }.joined()
    }

    /// Parses CSV back into rows, used by the self test to prove the output round trips.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, chars = Array(text), i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\r\n" || c == "\n" {
                row.append(field); rows.append(row); row = []; field = ""
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

// MARK: - Connection

/// A SQLite connection. Used from one serial queue at a time (see `Database`).
final class Connection: @unchecked Sendable {
    let handle: OpaquePointer
    private(set) var readOnly: Bool

    /// Opens an existing file. Read only uses SQLITE_OPEN_READONLY and `query_only`, so nothing can write.
    init(path: String, readOnly: Bool, create: Bool = false) throws {
        var db: OpaquePointer?
        var flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        if create { flags |= SQLITE_OPEN_CREATE }
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the file."
            sqlite3_close(db)
            throw LiteError.sqlite(message)
        }
        handle = db
        self.readOnly = readOnly
        sqlite3_busy_timeout(db, 3000)
        if readOnly { try exec("PRAGMA query_only = ON") }
        do {
            _ = try query("SELECT count(*) FROM sqlite_master")
        } catch {
            throw LiteError.notDatabase
        }
    }

    deinit { sqlite3_close_v2(handle) }

    /// Makes a connection opened for writing refuse writes from now on (used for the demo database).
    func lock() throws {
        try exec("PRAGMA query_only = ON")
        readOnly = true
    }

    static var version: String { String(cString: sqlite3_libversion()) }

    private var lastError: LiteError {
        let code = sqlite3_errcode(handle)
        if code == SQLITE_INTERRUPT { return .sqlite("Query stopped.") }
        if code == SQLITE_READONLY, readOnly { return .readOnly }
        return .sqlite(String(cString: sqlite3_errmsg(handle)))
    }

    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw lastError }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw lastError }
        return stmt
    }

    private func value(_ stmt: OpaquePointer, _ i: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, i))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, i))
        case SQLITE_TEXT:
            guard let p = sqlite3_column_text(stmt, i) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: p, count: Int(sqlite3_column_bytes(stmt, i))), as: UTF8.self))
        case SQLITE_BLOB: return .blob(Int(sqlite3_column_bytes(stmt, i)))
        default: return .null
        }
    }

    private func columnNames(_ stmt: OpaquePointer) -> [String] {
        (0..<sqlite3_column_count(stmt)).map { sqlite3_column_name(stmt, $0).map { String(cString: $0) } ?? "" }
    }

    private func collect(_ stmt: OpaquePointer, limit: Int) throws -> ResultSet {
        let columns = columnNames(stmt)
        var result = ResultSet(columns: columns, rows: [])
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError }
            if result.rows.count == limit { result.truncated = true; break }
            result.rows.append((0..<Int32(columns.count)).map { value(stmt, $0) })
        }
        return result
    }

    /// Runs one statement and returns up to `limit` rows.
    func query(_ sql: String, limit: Int = .max) throws -> ResultSet {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        return try collect(stmt, limit: limit)
    }

    /// Runs every statement in `script` in order. The result shows the last statement that returned columns.
    /// A read only connection refuses any statement that would write, before it runs.
    func run(script: String, limit: Int) throws -> ResultSet {
        let start = Date()
        let before = sqlite3_total_changes(handle)
        var result = ResultSet(columns: [], rows: [])
        var count = 0
        let bytes = Array(script.utf8CString)
        try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var cursor: UnsafePointer<CChar> = base
            while cursor.pointee != 0 {
                var stmt: OpaquePointer?
                var tail: UnsafePointer<CChar>?
                guard sqlite3_prepare_v2(handle, cursor, -1, &stmt, &tail) == SQLITE_OK else { throw lastError }
                guard let next = tail, next != cursor else { sqlite3_finalize(stmt); break }
                cursor = next
                guard let stmt else { continue } // Only whitespace or a comment.
                defer { sqlite3_finalize(stmt) }
                let writes = sqlite3_stmt_readonly(stmt) == 0
                if readOnly, writes { throw LiteError.readOnly }
                count += 1
                let part = try collect(stmt, limit: limit)
                if !part.columns.isEmpty || result.columns.isEmpty {
                    result.columns = part.columns
                    result.rows = part.rows
                    result.truncated = part.truncated
                    result.source = sqlite3_sql(stmt).map { String(cString: $0) } ?? ""
                    result.sourceIsReadOnly = !writes
                }
            }
        }
        guard count > 0 else { throw LiteError.nothingToRun }
        result.statements = count
        result.changes = Int(sqlite3_total_changes(handle) - before)
        result.elapsed = Date().timeIntervalSince(start)
        return result
    }

    func objects() throws -> [DBObject] {
        try query("""
            SELECT name, type, coalesce(sql, '') FROM sqlite_master
            WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite_%'
            ORDER BY name COLLATE NOCASE
            """).rows.map {
            DBObject(name: $0[0].plain, isView: $0[1].plain == "view", sql: $0[2].plain)
        }
    }

    func count(_ table: String) throws -> Int {
        guard case .integer(let n) = try query("SELECT count(*) FROM \(SQL.quote(table))").rows.first?.first else { return 0 }
        return Int(n)
    }

    func schema(_ object: DBObject) throws -> TableSchema {
        let q = SQL.quote(object.name)
        var references: [String: String] = [:]
        if !object.isView {
            for row in try query("PRAGMA foreign_key_list(\(q))").rows {
                // id, seq, table, from, to, on_update, on_delete, match
                let target = row[4].plain.isEmpty ? row[2].plain : "\(row[2].plain).\(row[4].plain)"
                references[row[3].plain] = target
            }
        }
        let columns = try query("PRAGMA table_info(\(q))").rows.map { row in
            // cid, name, type, notnull, dflt_value, pk
            ColumnInfo(name: row[1].plain, type: row[2].plain, notNull: row[3] == .integer(1),
                       defaultValue: row[4] == .null ? nil : row[4].plain,
                       primaryKey: { if case .integer(let n) = row[5] { Int(n) } else { 0 } }(),
                       references: references[row[1].plain])
        }
        var indexes: [IndexInfo] = []
        if !object.isView {
            for row in try query("PRAGMA index_list(\(q))").rows {
                // seq, name, unique, origin, partial
                let name = row[1].plain
                let cols = try query("PRAGMA index_info(\(SQL.quote(name)))").rows.map { $0[2] == .null ? "(expression)" : $0[2].plain }
                let sql = try query("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = '\(name.replacingOccurrences(of: "'", with: "''"))'")
                    .rows.first?.first
                indexes.append(IndexInfo(name: name, columns: cols, unique: row[2] == .integer(1), automatic: row[3].plain != "c",
                                         sql: sql == nil || sql == .null ? nil : sql?.plain))
            }
            indexes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return TableSchema(name: object.name, isView: object.isView, columns: columns, indexes: indexes, sql: object.sql)
    }

    /// Streams every row of a read only statement into a CSV file. Returns the number of rows written.
    @discardableResult
    func exportCSV(_ sql: String, to url: URL) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_stmt_readonly(stmt) != 0 else { throw LiteError.readOnly }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let n = sqlite3_column_count(stmt)
        var buffer = CSV.line(columnNames(stmt))
        var rows = 0
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw lastError }
            buffer += CSV.line((0..<n).map { i in
                if sqlite3_column_type(stmt, i) == SQLITE_BLOB, let p = sqlite3_column_blob(stmt, i) {
                    let data = Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
                    return data.map { String(format: "%02x", $0) }.joined()
                }
                return value(stmt, i).plain
            })
            rows += 1
            if buffer.utf8.count > 1 << 16 {
                try file.write(contentsOf: Data(buffer.utf8))
                buffer = ""
            }
        }
        try file.write(contentsOf: Data(buffer.utf8))
        return rows
    }
}

/// A connection plus the serial queue it lives on.
final class Database: @unchecked Sendable {
    let connection: Connection
    let queue = DispatchQueue(label: "com.weirdapps.lite.database", qos: .userInitiated)

    init(_ connection: Connection) { self.connection = connection }

    /// Stops the statement running on the queue, from any thread.
    func interrupt() { sqlite3_interrupt(connection.handle) }
}

// MARK: - Syntax colouring

enum SQLToken: Equatable {
    case keyword, string, identifier, number, comment
}

enum SQLHighlighter {
    static let keywords: Set<String> = [
        "ABORT", "ADD", "ALL", "ALTER", "ANALYZE", "AND", "AS", "ASC", "ATTACH", "AUTOINCREMENT", "BEGIN", "BETWEEN", "BY",
        "CASE", "CAST", "CHECK", "COLLATE", "COLUMN", "COMMIT", "CONFLICT", "CONSTRAINT", "CREATE", "CROSS", "CURRENT",
        "DEFAULT", "DELETE", "DESC", "DETACH", "DISTINCT", "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXISTS", "EXPLAIN",
        "FOREIGN", "FROM", "FULL", "GLOB", "GROUP", "HAVING", "IF", "IGNORE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
        "INTO", "IS", "ISNULL", "JOIN", "KEY", "LEFT", "LIKE", "LIMIT", "MATCH", "NATURAL", "NOT", "NOTNULL", "NULL", "OF",
        "OFFSET", "ON", "OR", "ORDER", "OUTER", "OVER", "PARTITION", "PRAGMA", "PRIMARY", "QUERY", "RECURSIVE",
        "REFERENCES", "REINDEX", "RELEASE", "RENAME", "REPLACE", "RETURNING", "RIGHT", "ROLLBACK", "ROW", "ROWID",
        "SAVEPOINT", "SELECT", "SET", "TABLE", "TEMP", "THEN", "TO", "TRANSACTION", "TRIGGER", "UNION", "UNIQUE",
        "UPDATE", "USING", "VACUUM", "VALUES", "VIEW", "VIRTUAL", "WHEN", "WHERE", "WINDOW", "WITH", "WITHOUT",
        "INTEGER", "TEXT", "REAL", "BLOB", "NUMERIC",
    ]

    /// Tokens worth colouring, as UTF-16 ranges (what NSTextStorage wants).
    static func tokens(_ text: String) -> [(SQLToken, NSRange)] {
        let u = Array(text.utf16)
        var out: [(SQLToken, NSRange)] = []
        var i = 0
        func isWord(_ c: UInt16) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        while i < u.count {
            let c = u[i]
            let start = i
            if c == 45, i + 1 < u.count, u[i + 1] == 45 { // -- comment
                while i < u.count, u[i] != 10 { i += 1 }
                out.append((.comment, NSRange(location: start, length: i - start)))
            } else if c == 47, i + 1 < u.count, u[i + 1] == 42 { // /* comment */
                i += 2
                while i < u.count, !(u[i] == 42 && i + 1 < u.count && u[i + 1] == 47) { i += 1 }
                i = min(i + 2, u.count)
                out.append((.comment, NSRange(location: start, length: i - start)))
            } else if c == 39 || c == 34 || c == 96 { // 'string', "identifier", `identifier`
                i += 1
                while i < u.count {
                    if u[i] == c {
                        if i + 1 < u.count, u[i + 1] == c { i += 2; continue }
                        i += 1
                        break
                    }
                    i += 1
                }
                out.append((c == 39 ? .string : .identifier, NSRange(location: start, length: i - start)))
            } else if c >= 48 && c <= 57 {
                while i < u.count, isWord(u[i]) || u[i] == 46 { i += 1 }
                out.append((.number, NSRange(location: start, length: i - start)))
            } else if isWord(c) {
                while i < u.count, isWord(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[start..<i]), count: i - start).uppercased()
                if keywords.contains(word) { out.append((.keyword, NSRange(location: start, length: i - start))) }
            } else {
                i += 1
            }
        }
        return out
    }
}

// MARK: - History and recents

struct HistoryEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var sql: String
    var date: Date
    var database: String
}

struct QueryHistory: Codable {
    static let cap = 100
    var entries: [HistoryEntry] = []

    /// Adds a query at the top. Running the same text again moves it up instead of repeating it.
    mutating func add(_ sql: String, database: String, date: Date = Date()) {
        let text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.removeAll { $0.sql == text }
        entries.insert(HistoryEntry(sql: text, date: date, database: database), at: 0)
        if entries.count > Self.cap { entries.removeLast(entries.count - Self.cap) }
    }

    /// A one line summary for menus.
    static func title(_ sql: String, max: Int = 70) -> String {
        let flat = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }
}
