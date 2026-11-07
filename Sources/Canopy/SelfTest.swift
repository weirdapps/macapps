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

        // Keys with line breaks, tabs and control characters still give one-line, readable-back paths.
        check(JSONPathFormat.jsonPath([.key("a\nb")]) == #"$['a\nb']"#, "JSONPath escapes a line break in a key")
        check(JSONPathFormat.jq([.key("a\tb\u{1}")]) == #"."a\tb\u0001""#, "jq path escapes tabs and control characters")
        check(!JSONPathFormat.jq([.key("x\ny")]).contains("\n"), "jq path stays on one line")

        // UTF-16 and UTF-32 files are read through their byte order mark.
        let sample = #"{"ключ": "🌳"}"#
        for (encoding, name) in [(String.Encoding.utf16LittleEndian, "UTF-16 LE"), (.utf16BigEndian, "UTF-16 BE"), (.utf32LittleEndian, "UTF-32 LE")] {
            let bom: [UInt8] = switch name {
            case "UTF-16 LE": [0xFF, 0xFE]
            case "UTF-16 BE": [0xFE, 0xFF]
            default: [0xFF, 0xFE, 0, 0]
            }
            let bytes = bom + [UInt8](sample.data(using: encoding)!)
            let t = try? JSONParser.parse(JSONParser.utf8(bytes))
            check(t.map { $0.key($0.child(0, 0)) == "ключ" && $0.scalarText($0.child(0, 0)) == "🌳" } == true, "\(name) file parses")
        }
        check(JSONParser.utf8(Array("[1]".utf8)) == Array("[1]".utf8), "UTF-8 bytes pass through unchanged")

        // Export names never carry path separators from a key.
        check(ViewerModel.exportName(base: "data", part: " a/b:c\nd") == "data a-b-c-d pretty.json", "export name drops slashes, colons and line breaks")
        check(ViewerModel.exportName(base: "x", part: " " + String(repeating: "k", count: 500)).count < 140, "export name stays short")

        // Text search used by the text view and row highlights.
        check(ViewerModel.ranges(of: "ab", in: "xABab").count == 2, "text search ignores case")
        check(ViewerModel.ranges(of: "a", in: String(repeating: "a", count: 50), limit: 10).count == 10, "text search stops at its limit")

        // A path thousands of levels deep keeps the breadcrumb bar short.
        if let t = parse(String(repeating: "[", count: 3000) + "1" + String(repeating: "]", count: 3000)) {
            let leaf = Int32(t.count - 1)
            let crumbs = PathBar.crumbs(t, leaf)
            check(crumbs.count == 26 && crumbs.first == 0 && crumbs[1] == -1 && crumbs.last == leaf, "deep breadcrumbs are capped (got \(crumbs.count))")
            check(PathBar.crumbs(t, 3) == [0, 1, 2, 3], "shallow breadcrumbs show every level")
        } else { check(false, "parse a deep path") }

        // The inspector never decodes a whole huge string on every redraw.
        let long = String(repeating: "é", count: 300_000)
        if let t = parse("[\"\(long)\", \"pending\", \"x\"]") {
            check(SelectionSection.lengthText(t, t.child(0, 0)).hasSuffix("KB"), "a huge string's length is shown as its size")
            check(SelectionSection.lengthText(t, t.child(0, 1)) == "7 characters", "a short string's length in characters")
            check(SelectionSection.lengthText(t, t.child(0, 2)) == "1 character", "one character, singular")
            let preview = SelectionSection.previewText(t, t.child(0, 0))
            check(preview.count == 2001 && preview.hasSuffix("…"), "a huge string's preview is cut")
            check(SelectionSection.previewText(t, t.child(0, 1)) == "pending", "a short string's preview is whole")
        } else { check(false, "parse a huge string") }

        // The text view of a document over the size limit.
        var wide = "{\"head\": 1, \"rows\": ["
        for i in 0..<120_000 { wide += #"{"id":\#(i),"label":"row \#(i)"},"# }
        wide.removeLast()
        wide += "], \"tail\": {\"end\": true}}"
        if let t = parse(wide) {
            let root = PrettyText.make(t, focus: 0)
            check(root.node == 0 && root.truncated, "the root of a big document shows its first 4 MB")
            let end = find(t, [.key("tail"), .key("end")])!
            let part = PrettyText.make(t, focus: end)
            check(part.node != 0 && !part.truncated && part.range(of: end) != nil, "a node past the limit is shown with its branch")
            if let r = part.range(of: end) {
                check((part.string.string as NSString).substring(with: r) == "true", "and its text range is right")
            }
        } else { check(false, "parse a wide document") }

        // Labels stay on one line.
        check(JSONTree.oneLine("multi\nline\tkey\r\nend") == #"multi\nline\tkey\r\nend"#, "line breaks and tabs show as escapes in labels")
        check(JSONTree.oneLine("plain é") == "plain é", "plain labels are unchanged")

        // Files named on the command line.
        let argv = ["/Applications/Canopy.app/Contents/MacOS/Canopy", "-NSQuitAlwaysKeepsWindows", "NO", "/tmp/a.json", "--flag",
                    "/tmp/b.jsonl", "/tmp/a.json", "-psn_0_123", "/tmp/missing.json"]
        let files = CommandLineFiles.urls(argv) { $0 != "/tmp/missing.json" }
        check(files.map(\.path) == ["/tmp/a.json", "/tmp/b.jsonl"], "command line files skip flags, defaults pairs, repeats and missing files (got \(files.map(\.path)))")
        check(CommandLineFiles.urls(["Canopy", "--selftest"]).isEmpty, "no files on a plain launch")

        print(failures == 0 ? "PASS: \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
