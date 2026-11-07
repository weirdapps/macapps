import Foundation

/// `Grid --selftest`: exercises decoding, detection, parsing, sorting, filtering, statistics and the writers.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        // Parsing, RFC 4180.
        let quoted = "name,note,qty\r\n\"Smith, Jane\",\"said \"\"hi\"\"\nthen left\",3\r\nBo,,\n"
        let rows = CSV.parse(quoted, delimiter: .comma) ?? []
        check("quoted rows count", rows.count == 3)
        check("comma inside quotes", rows[safe: 1]?[0] == "Smith, Jane")
        check("doubled quotes and embedded newline", rows[safe: 1]?[1] == "said \"hi\"\nthen left")
        check("empty trailing fields", rows[safe: 2] == ["Bo", "", ""])
        check("CR only line endings", CSV.parse("a,b\rc,d\r", delimiter: .comma) == [["a", "b"], ["c", "d"]])
        check("blank lines skipped", CSV.parse("a\n\n\nb\n", delimiter: .comma) == [["a"], ["b"]])
        check("trailing delimiter at end of file", CSV.parse("a,b,", delimiter: .comma) == [["a", "b", ""]])
        check("unterminated quote keeps text", CSV.parse("\"abc", delimiter: .comma) == [["abc"]])
        check("maxRows stops early", CSV.parse("1\n2\n3\n4", delimiter: .comma, maxRows: 2)?.count == 2)
        check("unicode fields", CSV.parse("café;日本\n", delimiter: .semicolon) == [["café", "日本"]])

        // Delimiter detection.
        check("detects comma", CSV.detectDelimiter("a,b,c\n1,2,3\n4,5,6\n") == .comma)
        check("detects tab", CSV.detectDelimiter("a\tb\tc\n1\t2\t3\n") == .tab)
        check("detects semicolon with decimal commas", CSV.detectDelimiter("Name;Price\nA;3,5\nB;4,2\nC;1,0\n") == .semicolon)
        check("detects pipe", CSV.detectDelimiter("a|b\n1|2\n3|4\n") == .pipe)
        check("commas inside quotes do not fool detection", CSV.detectDelimiter("\"a,b\";c\n\"d,e,f\";g\n\"h\";i\n") == .semicolon)

        // Encodings.
        let utf8BOM = Data([0xEF, 0xBB, 0xBF]) + Data("é,x".utf8)
        check("UTF-8 BOM stripped", CSV.decode(utf8BOM) == ("é,x", .utf8))
        let le = Data([0xFF, 0xFE]) + "a,ü\n".data(using: .utf16LittleEndian)!
        check("UTF-16 LE BOM", CSV.decode(le) == ("a,ü\n", .utf16LE))
        let be = "name,value\n1,2\n".data(using: .utf16BigEndian)!
        check("UTF-16 BE without BOM", CSV.decode(be) == ("name,value\n1,2\n", .utf16BE))
        let latin = Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x80])
        check("Latin 1 fallback", CSV.decode(latin) == ("café,€", .latin1))

        // Header detection.
        check("header over numbers", CSV.detectHeader([["id", "price"], ["1", "9.5"], ["2", "3"]]))
        check("no header when first row is data", !CSV.detectHeader([["1", "9.5"], ["2", "3"], ["3", "4"]]))
        check("header over text by distinct labels", CSV.detectHeader([["Name", "City"], ["Ann", "Oslo"], ["Bo", "Rome"]]))
        check("no header when first row repeats below", !CSV.detectHeader([["x", "y"], ["x", "y"], ["z", "w"]]))

        // Numbers.
        check("number parsing", CSV.number("-12.5") == -12.5 && CSV.number("1e3") == 1000 && CSV.number(" 7 ") == 7)
        check("text is not a number", CSV.number("inf") == nil && CSV.number("0x1A") == nil && CSV.number("1,234") == nil && CSV.number("") == nil)

        check("decimal comma numbers", CSV.number("3,50", decimalComma: true) == 3.5 && CSV.number("1.234,5", decimalComma: true) == 1234.5
            && CSV.number("7.25", decimalComma: true) == 7.25)
        let euro = [["n"], ["10,5"], ["9,25"], ["100"]]
        check("decimal comma sort", CSV.sortedOrder(euro, from: 1, column: 0, ascending: true, decimalComma: true) == [2, 1, 3])
        check("decimal comma stats", CSV.stats(euro, indices: [1, 2, 3], column: 0, decimalComma: true)?.sum == 119.75)

        // Sorting.
        let table = [["n", "t"], ["10", "file 10"], ["", "File 2"], ["9", "file 1"], ["-1", ""], ["100", "b"]]
        let asc = CSV.sortedOrder(table, from: 1, column: 0, ascending: true) ?? []
        check("numeric sort ascending, empty last", asc == [4, 3, 1, 5, 2])
        let desc = CSV.sortedOrder(table, from: 1, column: 0, ascending: false) ?? []
        check("numeric sort descending, empty still last", desc == [5, 1, 3, 4, 2])
        let text = CSV.sortedOrder(table, from: 1, column: 1, ascending: true) ?? []
        check("natural text sort", text == [5, 3, 2, 1, 4])
        check("natural compare digits", CSV.naturalCompare("a2", "a10") == .orderedAscending && CSV.naturalCompare("B", "a") == .orderedDescending)
        check("natural compare non-ASCII", CSV.naturalCompare("été", "zoo") == .orderedAscending)

        // Filtering.
        let people = [["name", "city"], ["Ann", "Oslo"], ["Bob", "Lisbon"], ["Cléa", "Paris"], ["Dan", "oslo"]]
        check("filter any column, case-insensitive", CSV.filter(people, order: [1, 2, 3, 4], query: "OSLO") == [1, 4])
        check("filter one column", CSV.filter(people, order: [1, 2, 3, 4], query: "an", column: 0) == [1, 4])
        check("filter non-ASCII and diacritics", CSV.filter(people, order: [1, 2, 3, 4], query: "Cléa") == [3]
            && CSV.filter(people, order: [1, 2, 3, 4], query: "é") == [3])
        check("empty filter keeps order", CSV.filter(people, order: [4, 2], query: "  ") == [4, 2])

        // Statistics.
        let nums = [["v"], ["4"], ["2"], [""], ["4"], ["10"]]
        let s = CSV.stats(nums, indices: [1, 2, 3, 4, 5], column: 0)
        check("stats counts", s?.count == 4 && s?.empty == 1 && s?.unique == 3)
        check("stats numbers", s?.isNumeric == true && s?.mean == 5 && s?.sum == 20 && s?.min == "2" && s?.max == "10")
        check("stats top values", s?.top.first == ValueCount(value: "4", count: 2))
        let ts = CSV.stats(people, indices: [1, 2, 3, 4], column: 1)
        check("stats text", ts?.isNumeric == false && ts?.min == "Lisbon" && ts?.max == "Paris" && ts?.mean == nil)

        // Writers.
        let csv = CSV.serialize(header: ["a", "b"], rows: [["x,y", "say \"no\""], ["1"]], format: .csv, columns: 2)
        check("CSV quoting", csv == "a,b\r\n\"x,y\",\"say \"\"no\"\"\"\r\n1,")
        let tsv = CSV.serialize(header: nil, rows: [["a b", "c\td"]], format: .tsv, columns: 2)
        check("TSV quoting", tsv == "a b\t\"c\td\"")
        let md = CSV.serialize(header: ["Name", "Qty"], rows: [["a|b", "3"], ["two\nlines", "4"]], format: .markdown, columns: 2, numeric: [1])
        check("Markdown table", md == "| Name | Qty |\n| --- | ---: |\n| a\\|b | 3 |\n| two<br>lines | 4 |")
        check("column letters", CSV.columnLetter(0) == "A" && CSV.columnLetter(25) == "Z" && CSV.columnLetter(26) == "AA" && CSV.columnLetter(701) == "ZZ")

        // Export round trip through a temporary file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grid-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("out.csv")
        let source = [["id", "note"], ["1", "a, \"b\"\nc"], ["2", "plain"], ["3", "x"]]
        do {
            try CSV.export(header: source[0], rows: source, order: [3, 1], columns: 2, to: out)
            let back = CSV.parse(try String(contentsOf: out, encoding: .utf8), delimiter: .comma)
            check("export round trip", back == [source[0], source[3], source[1]])
        } catch {
            check("export wrote a file", false)
        }
        try? FileManager.default.removeItem(at: dir)

        // A large synthetic file: progress reports and cancellation.
        var big = "id,name,amount\n"
        for i in 0..<120_000 { big += "\(i),\"Name \(i % 97)\",\(Double(i) * 0.5)\n" }
        var reports = 0
        let start = Date()
        let parsed = CSV.parse(big, delimiter: .comma) { _ in reports += 1; return true }
        check("large parse", parsed?.count == 120_001 && parsed?.last == ["119999", "Name 10", "59999.5"])
        check("large parse reports progress", reports >= 2)
        check("large parse is fast", Date().timeIntervalSince(start) < 3)
        check("parse cancels", CSV.parse(big, delimiter: .comma) { _ in false } == nil)
        check("demo data parses", (CSV.parse(DemoData.csv, delimiter: .comma)?.count ?? 0) == 2401)

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
