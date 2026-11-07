import Foundation

/// `Canopy --selftest`: checks the parser, the paths, printing and search.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    private static func parse(_ s: String, _ mode: JSONParser.Mode = .auto) -> JSONTree? { try? JSONParser.parse(Array(s.utf8), mode: mode) }

    private static func error(_ s: String) -> ParseError? {
        do { _ = try JSONParser.parse(Array(s.utf8)); return nil } catch let e as ParseError { return e } catch { return nil }
    }

    private static func find(_ tree: JSONTree, _ path: [PathSegment]) -> Int32? {
        var id: Int32 = 0
        for seg in path {
            switch seg {
            case .key(let k): guard let c = tree.childIDs(id).first(where: { tree.key($0) == k }) else { return nil }; id = c
            case .index(let n): guard n < tree.childCount(id) else { return nil }; id = tree.child(id, n)
            }
        }
        return id
    }

    static func run() -> Int32 {
        // Structure, order and counts.
        let doc = #"{"b": 1, "a": [true, false, null, "x"], "c": {"d": {"e": -1.5e3}}, "": 0}"#
        if let t = parse(doc) {
            check(t.childIDs(0).map { t.key($0) ?? "?" } == ["b", "a", "c", ""], "keys keep document order")
            check(t.stats.objects == 3 && t.stats.arrays == 1 && t.stats.numbers == 3, "type counts")
            check(t.stats.bools == 2 && t.stats.nulls == 1 && t.stats.strings == 1 && t.stats.nodes == 11, "scalar counts and total")
            check(t.stats.maxDepth == 3, "max depth counts container levels (got \(t.stats.maxDepth))")
            if let e = find(t, [.key("c"), .key("d"), .key("e")]) {
                check(t.scalarText(e) == "-1.5e3", "numbers keep their literal text")
                check(JSONPathFormat.jsonPath(t.segments(e)) == "$.c.d.e", "JSONPath of a nested key")
                check(JSONPathFormat.jq(t.segments(e)) == ".c.d.e", "jq path of a nested key")
                check(t.depth(e) == 3 && t.ancestors(e).count == 3, "depth and ancestors")
            } else { check(false, "find nested key") }
            if let x = find(t, [.key("a"), .index(3)]) {
                check(JSONPathFormat.jsonPath(t.segments(x)) == "$.a[3]", "JSONPath of an array element")
                check(JSONPathFormat.jq(t.segments(x)) == ".a[3]", "jq path of an array element")
                check(t.copyText(x) == "x", "copy value of a string is its text")
            } else { check(false, "find array element") }
            check(t.summary(0) == "4 keys" && t.summary(find(t, [.key("a")])!) == "4 items", "container summaries")
        } else { check(false, "parse a mixed document") }

        // Path quoting.
        check(JSONPathFormat.jsonPath([.key("first name"), .key("it's")]) == #"$['first name']['it\'s']"#, "JSONPath quotes odd keys")
        check(JSONPathFormat.jq([.key("first name"), .key("$x"), .index(0)]) == #"."first name"."$x"[0]"#, "jq quotes odd keys")
        check(JSONPathFormat.jsonPath([.key("$x"), .key("_a1")]) == "$.$x._a1", "JSONPath allows $ and _ identifiers")
        check(JSONPathFormat.jq([]) == "." && JSONPathFormat.jsonPath([]) == "$", "root paths")
        check(JSONPathFormat.jq([.index(2), .key("id")]) == ".[2].id", "jq path starting with an index")

        // Escapes.
        if let t = parse(#"{"kéy": "a\"b\\c\nd é 🌳 \/"}"#) {
            let v = t.child(0, 0)
            check(t.key(v) == "kéy", "escaped key decodes")
            check(t.scalarText(v) == "a\"b\\c\nd é 🌳 /", "string escapes and surrogate pairs decode")
            check(t.search("KÉY") == [v], "search finds an escaped key, ignoring case")
        } else { check(false, "parse escapes") }

        // Errors carry a clear position.
        if let e = error("{\n  \"a\": 1,\n  \"b\" 2\n}") {
            check(e.line == 3 && e.column == 7, "error position is line 3 column 7 (got \(e.location))")
            check(e.message == "Expected ':' after the key", "missing colon message")
            check(e.excerpt == #"  "b" 2"# && e.caret == 6, "error excerpt and caret")
        } else { check(false, "missing colon is an error") }
        check(error(#"{"a": [1, 2,]}"#)?.message == "Trailing comma before ']'", "trailing comma is named")
        check(error(#"{"a": 01}"#)?.message == "Numbers cannot have leading zeros", "leading zeros rejected")
        check(error(#"[1.]"#) != nil && error("[-]") != nil && error("[1e]") != nil, "malformed numbers rejected")
        check(error(#"["a"#)?.message == "Unterminated string", "unterminated string")
        check(error("[\"a\u{1}\"]") != nil, "control characters in strings rejected")
        check(error(#"{'a': 1}"#) != nil && error("[tru]") != nil && error(#"["\x"]"#) != nil, "bad quotes, words and escapes rejected")
        check(error("   ")?.message == "The document is empty", "empty document")
        check(error("[1] [2]") != nil, "two values on one line are not JSON Lines")
        check(error(#"{"a":1"#)?.message == "Unexpected end of file; expected '}'", "unclosed object")

        // JSON Lines.
        let lines = "{\"n\": 1}\n{\"n\": 2}\n\n[3]\n"
        if let t = parse(lines) {
            check(t.isLines && t.childCount(0) == 3, "JSON Lines detected with three records")
            check(t.summary(0) == "3 records", "records summary")
            let n2 = find(t, [.index(1), .key("n")])!
            check(JSONPathFormat.jsonPath(t.segments(n2)) == "$[1].n" && t.scalarText(n2) == "2", "record paths")
            check(t.stats.maxDepth == 2, "records count as one level")
        } else { check(false, "parse JSON Lines") }
        if let e = error("{\"a\":1}\n{\"b\" 2}\n") {
            check(e.line == 2 && e.message == "Expected ':' after the key", "JSON Lines errors point at the bad record (got \(e.location))")
        } else { check(false, "bad JSON Lines record is an error") }
        check(parse("[1]", .lines)?.isLines == true, "a .jsonl file with one record")

        // BOM, scalars and deep nesting.
        check(parse("\u{FEFF}{\"a\": 1}")?.count == 2, "byte order mark skipped")
        if let t = parse(" 42 ") { check(t.count == 1 && t.kind(0) == .number && t.stats.maxDepth == 0, "top level scalar") }
        let deep = String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000)
        check(parse(deep)?.stats.maxDepth == 20_000, "deep nesting parses without recursion")

        // Printing round trip.
        let src = #"{"a":[1,{"b":"x\ny"},[]],"c":{},"d":null}"#
        if let t = parse(src) {
            let pretty = t.prettyString(0)
            let expected = "{\n  \"a\": [\n    1,\n    {\n      \"b\": \"x\\ny\"\n    },\n    []\n  ],\n  \"c\": {},\n  \"d\": null\n}"
            check(pretty == expected, "pretty printing")
            check(String(decoding: t.render(0, indent: nil).bytes, as: UTF8.self) == #"{"a":[1,{"b":"x\ny"},[]],"c":{},"d":null}"#, "compact printing")
            check(parse(pretty)?.kinds == t.kinds && parse(pretty)?.childCount == t.childCount, "pretty output parses back to the same document")
            check(t.render(0, limit: 10).truncated && t.render(0, limit: 10).bytes.count == 10, "printing stops at the limit")
            check(t.copyText(find(t, [.key("a")])!).hasPrefix("[\n  1,"), "copy value of an array is pretty JSON")
        } else { check(false, "parse printing sample") }

        // Locating a node in the pretty text, past non-ASCII text.
        if let t = parse(#"{"emoji": "🌳é", "list": [1, {"deep": "x"}], "last": "end"}"#) {
            let r = t.render(0, track: true)
            check(r.starts.count == t.count && !r.ends.contains(-1), "every printed node is located")
            let list = find(t, [.key("list")])!
            let k = Int(list)
            check(String(decoding: r.bytes[Int(r.starts[k])..<Int(r.ends[k])], as: UTF8.self) == t.prettyString(list).replacingOccurrences(of: "\n", with: "\n  "),
                  "a container's printed range is its own pretty text")
            let pretty = PrettyText.make(t, focus: find(t, [.key("last")])!)
            if let range = pretty.range(of: find(t, [.key("last")])!) {
                check((pretty.string.string as NSString).substring(with: range) == "\"end\"", "text range of a node after an emoji")
            } else { check(false, "text range of a node after an emoji") }
            check(pretty.node == 0 && pretty.range(of: 0)?.location == 0, "small documents show whole in the text view")
        }

        // Search.
        if let t = parse(#"{"Status": "Pending", "items": [{"status": "pending"}, {"status": "done", "pend": 3}], "n": 12345}"#) {
            check(t.search("pend").count == 3, "search matches keys and values ignoring case")
            check(t.search("234").count == 1, "search matches numbers")
            check(t.search("   ").isEmpty, "blank search matches nothing")
            let hits = t.search("status")
            check(hits == hits.sorted(), "matches come in document order")
        }

        // A big document, timed.
        var big = "["
        for i in 0..<60_000 { big += #"{"id":\#(i),"name":"item \#(i)","tags":["a","b"],"ok":true},"# }
        big.removeLast()
        big += "]"
        let started = Date()
        if let t = parse(big) {
            let seconds = Date().timeIntervalSince(started)
            check(t.childCount(0) == 60_000 && t.stats.nodes == 1 + 60_000 * 7, "big document node count")
            check(seconds < 2, "big document (\(big.utf8.count / 1_000_000) MB) parses quickly (\(String(format: "%.2f", seconds)) s)")
            check(t.search("item 59999").count == 1, "search a big document")
        } else { check(false, "parse a big document") }

        // Cancellation.
        let progress = ParseProgress()
        progress.cancel()
        let huge = Array(("[" + String(repeating: "1,", count: 3_000_000) + "1]").utf8)
        do { _ = try JSONParser.parse(huge, progress: progress); check(false, "cancelled parse stops") } catch {
            check(error is ParseCancelled, "cancelled parse stops")
        }

        print(failures == 0 ? "PASS: \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
