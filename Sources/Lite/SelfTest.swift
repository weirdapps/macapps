import Foundation

/// `Lite --selftest`: builds a database in a temporary folder and checks the engine against it.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: @autoclosure () throws -> Bool) {
            do {
                if try ok() { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
            } catch {
                failed += 1
                print("FAIL: \(name) threw \(error.localizedDescription)")
            }
        }
        func throwsError(_ work: () throws -> Void, _ match: (Error) -> Bool = { _ in true }) -> Bool {
            do { try work(); return false } catch { return match(error) }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lite-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("test.sqlite").path

        do {
            // A writable connection builds the fixture, then goes away.
            do {
                let w = try Connection(path: path, readOnly: false, create: true)
                try w.exec(#"""
                    CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER DEFAULT 30, note TEXT, photo BLOB);
                    CREATE TABLE "odd ""name""" (x REAL);
                    CREATE TABLE pets (id INTEGER PRIMARY KEY, owner INTEGER REFERENCES people(id), kind TEXT UNIQUE);
                    CREATE INDEX people_age ON people(age);
                    CREATE VIEW adults AS SELECT name FROM people WHERE age >= 18;
                    INSERT INTO "odd ""name""" VALUES (1.5), (2.25);
                    """#)
                try w.exec("BEGIN")
                for i in 1...1234 {
                    try w.exec("INSERT INTO people (name, age, note) VALUES ('person \(i)', \(i % 90), \(i % 7 == 0 ? "NULL" : "'n\(i)'"))")
                }
                try w.exec("INSERT INTO people (name, age, note, photo) VALUES ('Zoë, \"the\" one', 40, 'line1\nline2', x'00ff10')")
                try w.exec("COMMIT")
            }

            check("header sniff accepts a database", SQL.looksLikeDatabase(URL(fileURLWithPath: path)))
            let text = dir.appendingPathComponent("not.db")
            try "hello, this is not sqlite at all".write(to: text, atomically: true, encoding: .utf8)
            check("header sniff rejects a text file", !SQL.looksLikeDatabase(text))
            check("opening a text file fails", throwsError({ _ = try Connection(path: text.path, readOnly: true) }))
            check("opening a missing file does not create it", throwsError({ _ = try Connection(path: dir.appendingPathComponent("nope.db").path, readOnly: true) })
                && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("nope.db").path))

            let c = try Connection(path: path, readOnly: true)
            let objects = try c.objects()
            check("lists tables and views, sorted", objects.map(\.name) == ["adults", "odd \"name\"", "people", "pets"])
            check("marks views", objects.first { $0.name == "adults" }?.isView == true && objects.first { $0.name == "people" }?.isView == false)
            check("counts rows", try c.count("people") == 1235)
            check("counts a table with quotes in its name", try c.count("odd \"name\"") == 2)
            check("counts a view", try c.count("adults") > 0)

            let page = try c.query(SQL.page(table: "people", sort: nil, offset: 500, limit: 500))
            check("pages 500 rows", page.rows.count == 500 && page.columns == ["id", "name", "age", "note", "photo"])
            check("page offset starts where it should", page.rows.first?.first == .integer(501))
            let last = try c.query(SQL.page(table: "people", sort: nil, offset: 1000, limit: 500))
            check("last page is partial", last.rows.count == 235)
            let sorted = try c.query(SQL.page(table: "people", sort: SortKey(column: "age", ascending: false), offset: 0, limit: 5))
            check("sorts descending in SQL", sorted.rows.first?[2] == .integer(89))
            let limited = try c.query("SELECT * FROM people", limit: 10)
            check("limit marks the result truncated", limited.rows.count == 10 && limited.truncated)

            let zoe = try c.query("SELECT name, photo, note FROM people WHERE photo IS NOT NULL").rows.first
            check("reads UTF-8 text", zoe?[0] == .text("Zoë, \"the\" one"))
            check("reads blobs by size", zoe?[1] == .blob(3))
            check("reads NULL", try c.query("SELECT note FROM people WHERE id = 7").rows.first?.first == .null)

            let schema = try c.schema(objects.first { $0.name == "people" }!)
            check("schema lists columns with types", schema.columns.map(\.type) == ["INTEGER", "TEXT", "INTEGER", "TEXT", "BLOB"])
            check("schema knows primary key, not null and default",
                  schema.columns[0].primaryKey == 1 && schema.columns[1].notNull && schema.columns[2].defaultValue == "30")
            check("schema lists indexes", schema.indexes.map(\.name) == ["people_age"] && schema.indexes[0].columns == ["age"]
                && schema.indexes[0].sql?.hasPrefix("CREATE INDEX") == true)
            check("schema keeps the CREATE statement", schema.sql.hasPrefix("CREATE TABLE people"))
            let pets = try c.schema(objects.first { $0.name == "pets" }!)
            check("schema shows foreign keys", pets.columns.first { $0.name == "owner" }?.references == "people.id")
            check("schema shows automatic unique indexes", pets.indexes.contains { $0.unique && $0.automatic })

            // Read only is enforced before a statement runs.
            check("read only refuses INSERT", throwsError({ _ = try c.run(script: "INSERT INTO pets (kind) VALUES ('cat')", limit: 10) },
                                                       { ($0 as? LiteError) == .readOnly }))
            check("read only refuses a write hidden after a SELECT",
                  throwsError({ _ = try c.run(script: "SELECT 1; DELETE FROM people;", limit: 10) }))
            check("nothing was deleted", try c.count("people") == 1235)
            check("read only refuses a raw exec too", throwsError({ try c.exec("DROP TABLE pets") }))

            let multi = try c.run(script: "SELECT 1 AS a; -- comment\nSELECT name FROM people ORDER BY id LIMIT 3;\n  ", limit: 100)
            check("runs several statements and shows the last result", multi.statements == 2 && multi.columns == ["name"] && multi.rows.count == 3)
            check("remembers the statement behind the result", multi.source.contains("SELECT name FROM people"))
            check("syntax errors come back as messages",
                  throwsError({ _ = try c.run(script: "SELEC * FROM people", limit: 10) }) { $0.localizedDescription.contains("syntax error") })
            check("empty SQL is reported", throwsError({ _ = try c.run(script: "  -- just a comment\n", limit: 10) },
                                                       { ($0 as? LiteError) == .nothingToRun }))

            // Writing works only on a connection opened for it.
            do {
                let w = try Connection(path: path, readOnly: false)
                let r = try w.run(script: "INSERT INTO pets (owner, kind) VALUES (1, 'cat'), (2, 'dog')", limit: 10)
                check("writable connection reports changes", r.changes == 2 && r.columns.isEmpty)
            }
            check("read only connection sees the write", try c.count("pets") == 2)

            // CSV.
            check("CSV quotes commas, quotes and newlines", CSV.field("a,\"b\"\nc") == "\"a,\"\"b\"\"\nc\"" && CSV.field("plain") == "plain")
            check("CSV keeps leading spaces", CSV.field(" x") == "\" x\"")
            let csvURL = dir.appendingPathComponent("people.csv")
            let rows = try c.exportCSV(SQL.all(table: "people", sort: SortKey(column: "id", ascending: true)), to: csvURL)
            let parsed = CSV.parse(try String(contentsOf: csvURL, encoding: .utf8))
            check("export streams every row", rows == 1235 && parsed.count == 1236)
            check("export header matches columns", parsed.first == ["id", "name", "age", "note", "photo"])
            check("export round trips awkward text", parsed.last == ["1235", "Zoë, \"the\" one", "40", "line1\nline2", "00ff10"])
            check("export writes NULL as empty", parsed[7][3] == "")
            check("export refuses a writing statement", throwsError({ try c.exportCSV("DELETE FROM people", to: csvURL) }))

            // Values, quoting, sorting.
            check("identifiers are quoted", SQL.quote("a\"b") == "\"a\"\"b\"")
            check("value display", SQLValue.null.display == "NULL" && SQLValue.real(2.5).display == "2.5" && SQLValue.blob(2048).display.hasPrefix("BLOB"))
            let mixed: [SQLValue] = [.text("b"), .integer(3), .null, .real(1.5), .text("a10"), .text("a9")]
            check("sorts like SQLite across types", mixed.sorted(by: SQLValue.ascending) == [.null, .real(1.5), .integer(3), .text("a9"), .text("a10"), .text("b")])

            // Highlighter.
            let tokens = SQLHighlighter.tokens("SELECT 'it''s', \"col\" FROM t -- note\nWHERE x = 42")
            check("highlights keywords", tokens.filter { $0.0 == .keyword }.count == 3)
            check("highlights strings with escaped quotes", tokens.contains { $0.0 == .string && $0.1 == NSRange(location: 7, length: 7) })
            check("highlights identifiers, numbers and comments",
                  tokens.contains { $0.0 == .identifier } && tokens.contains { $0.0 == .number } && tokens.contains { $0.0 == .comment })

            // History.
            var history = QueryHistory()
            history.add("SELECT 1", database: "a")
            history.add("SELECT 2", database: "a")
            history.add("  SELECT 1  ", database: "a")
            check("history moves repeats to the top", history.entries.map(\.sql) == ["SELECT 1", "SELECT 2"])
            for i in 0..<150 { history.add("SELECT \(i + 10)", database: "a") }
            check("history is capped", history.entries.count == QueryHistory.cap)
            let data = try JSONEncoder().encode(history)
            check("history round trips as JSON", try JSONDecoder().decode(QueryHistory.self, from: data).entries == history.entries)
            check("history titles fit on one line", QueryHistory.title("SELECT *\n  FROM t") == "SELECT * FROM t")

            // Demo database used for the screenshot.
            let demo = try Demo.connection()
            check("demo database has its tables", try demo.count("tracks") == 3503 && demo.readOnly)

            // The window model, driven the way the UI drives it (the demo runs synchronously).
            MainActor.assumeIsolated {
                let m = DatabaseModel.demo
                check("model selects the table it was asked for", m.selection == "tracks" && m.pageResult?.rows.count == DatabaseModel.pageSize)
                check("model counts every object", m.objects.allSatisfy { $0.rowCount != nil } && m.totalRows == 3503)
                check("model pages forward and back", { m.nextPage(); let ok = m.page == 1 && m.pageResult?.rows.first?.first == .integer(501)
                    m.previousPage(); return ok && m.page == 0 }())
                m.setSort(SortKey(column: "milliseconds", ascending: false))
                check("model sorts in SQL", { guard case .integer(let a) = m.pageResult?.rows[0][5], case .integer(let b) = m.pageResult?.rows[1][5] else { return false }; return a >= b }())
                check("last page cannot go forward", { for _ in 0..<10 { m.nextPage() }; return m.page == 7 && !m.canGoForward }())
                m.sql = "SELECT 1; SELECT name FROM genres ORDER BY name"
                m.editorSelection = "SELECT count(*) AS n FROM artists"
                m.run()
                check("run uses only the selected text", m.sqlResult?.columns == ["n"] && m.sqlResult?.rows.first?.first == .integer(120) && m.mode == .sql)
                m.editorSelection = ""
                m.sql = "DELETE FROM artists"
                m.run()
                check("read only model refuses writes with a clear message", m.sqlError?.contains("read only") == true && m.sqlResult == nil)
                check("history records what ran", m.history.entries.first?.sql == "DELETE FROM artists")
                m.selection = "genres"
                check("choosing a table returns to the data view", m.mode == .data && m.page == 0 && m.sort == nil && m.pageResult?.rows.count == 18)
                check("schema follows the selection", m.schema?.name == "genres" && m.schema?.indexes.contains { $0.unique } == true)
            }
        } catch {
            failed += 1
            print("FAIL: setup threw \(error.localizedDescription)")
        }

        print(failed == 0 ? "All \(passed) checks passed" : "\(failed) failed, \(passed) passed")
        return failed == 0 ? 0 : 1
    }
}
