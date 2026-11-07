import AppKit
import PDFKit
import SwiftUI

@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(what)") }
    }

    static func run() -> Int32 {
        parser()
        lists()
        tables()
        html()
        stats()
        editing()
        exports()
        oddInput()
        print(failures == 0 ? "OK: \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    private static func parser() {
        check(MarkdownParser.parse("# Title #") == [.heading(level: 1, text: "Title")], "ATX heading with closing hashes")
        check(MarkdownParser.parse("#NoSpace") == [.paragraph("#NoSpace")], "hash without a space is text")
        check(MarkdownParser.parse("Title\n=====\n\nSub\n---") == [.heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub")],
              "setext headings")
        check(MarkdownParser.parse("one\ntwo") == [.paragraph("one two")], "soft line break joins with a space")
        check(MarkdownParser.parse("one  \ntwo") == [.paragraph("one\ntwo")], "two trailing spaces make a hard break")
        check(MarkdownParser.parse("a\n\n***\n\nb") == [.paragraph("a"), .rule, .paragraph("b")], "thematic break")
        check(MarkdownParser.parse("```swift\nlet x = 1\n\n# not a heading\n```") == [.code(language: "swift", code: "let x = 1\n\n# not a heading")],
              "fenced code keeps its content and language")
        check(MarkdownParser.parse("    indented\n    code") == [.code(language: "", code: "indented\ncode")], "indented code block")
        check(MarkdownParser.parse("> quoted\n> # inside\nlazy") == [.quote([.paragraph("quoted"), .heading(level: 1, text: "inside")]), .paragraph("lazy")],
              "block quote with a nested heading")
        check(MarkdownParser.parse("> a\ncontinued") == [.quote([.paragraph("a continued")])], "lazy quote continuation")
        check(MarkdownParser.parse("![Cat](images/cat.png \"Our cat\")") == [.image(alt: "Cat", source: "images/cat.png", title: "Our cat")],
              "standalone image with a title")
        check(MarkdownParser.parse("\tcode") == [.code(language: "", code: "code")], "a leading tab counts as indentation")
    }

    private static func lists() {
        guard case .list(let bullets)? = MarkdownParser.parse("- one\n- two\n  - nested\n- three").first else {
            return check(false, "bullet list parses")
        }
        check(!bullets.ordered && bullets.tight && bullets.items.count == 3, "tight bullet list with three items")
        if case .list(let inner)? = bullets.items[1].blocks.last { check(inner.items.count == 1, "nested list") } else { check(false, "nested list") }

        guard case .list(let numbered)? = MarkdownParser.parse("3. c\n4. d\n\n5. e").first else { return check(false, "ordered list parses") }
        check(numbered.ordered && numbered.start == 3 && numbered.items.count == 3 && !numbered.tight, "ordered list keeps its start and looseness")

        let blocks = MarkdownParser.parse("- [ ] open\n- [x] done\n\n> - [X] quoted")
        guard case .list(let tasks)? = blocks.first, case .quote(let q)? = blocks.last, case .list(let quoted)? = q.first else {
            return check(false, "task lists parse")
        }
        check(tasks.items.map(\.checked) == [false, true], "task boxes read")
        check(tasks.items.map(\.taskIndex) == [0, 1] && quoted.items.first?.taskIndex == 2, "task boxes are numbered in source order")
        check(tasks.items[0].blocks == [.paragraph("open")], "task text without its box")
        check(MarkdownParser.parse("- - -") == [.rule], "dashes with spaces are a rule, not a list")
        check(MarkdownParser.parse("Text\n2. not a list").count == 1, "only 1. can interrupt a paragraph")
    }

    private static func tables() {
        let blocks = MarkdownParser.parse("| Name | Qty | Note |\n|:--|--:|:-:|\n| a \\| b | 2 | `x|y` |\n| short |")
        guard case .table(let t)? = blocks.first else { return check(false, "table parses") }
        check(t.alignments == [.left, .right, .center], "column alignments")
        check(t.header == ["Name", "Qty", "Note"], "header cells")
        check(t.rows.first == ["a | b", "2", "`x|y`"], "escaped pipes and pipes in code stay in the cell")
        check(t.rows.last == ["short", "", ""], "short rows are padded")
        check(MarkdownParser.parse("a | b\nnot a separator").count == 1, "a pipe alone is not a table")
    }

    private static func html() {
        check(HTMLExporter.inline("**bold** and _it_ `a<b` [link](https://x.com/?a=1&b=2)")
              == "<strong>bold</strong> and <em>it</em> <code>a&lt;b</code> <a href=\"https://x.com/?a=1&amp;b=2\">link</a>",
              "inline HTML: strong, em, code, link, escaping")
        check(!HTMLExporter.inline("[x](javascript:alert(1))").contains("href"), "javascript: links are dropped from HTML")
        check(!HTMLExporter.inline("[x](JaVaScRiPt:alert(1))").contains("href"), "scheme check ignores case")
        check(!HTMLExporter.inline("![x](data:text/html,hi)").contains("src"), "data: images are dropped from HTML")
        check(HTMLExporter.inline("[x](mailto:a@b.c)").contains("href=\"mailto:a@b.c\""), "mailto links stay")
        check(HTMLExporter.inline("[x](docs/a.md)").contains("href=\"docs/a.md\""), "relative links stay")
        check(HTMLExporter.safeURL("img/a:b.png") == "img/a:b.png", "a colon after a slash is a relative path")
        let doc = HTMLExporter.body(MarkdownParser.parse("- [x] done\n\n```\n<tag>\n```"))
        check(doc.contains("<input type=\"checkbox\" disabled checked> done"), "task list HTML")
        check(doc.contains("<pre><code>&lt;tag&gt;\n</code></pre>"), "code HTML is escaped")
        let full = HTMLExporter.document(MarkdownParser.parse(Demo.text), title: "A & B")
        check(full.hasPrefix("<!doctype html>") && full.contains("<title>A &amp; B</title>") && full.contains("<table>"), "full HTML document")
        check(!full.contains("\u{2014}") && !full.contains("\u{2013}"), "no em or en dashes in the HTML template")
    }

    private static func stats() {
        let text = "# Hello world\n\nThis is **bold** text with a [link](https://example.com/a/b/c)."
        let s = TextStats(source: text, blocks: MarkdownParser.parse(text))
        check(s.words == 9, "word count ignores markup and link targets (got \(s.words))")
        check(s.characters == text.count && s.minutes == 1, "characters and reading time")
        check(TextStats(source: "", blocks: []).minutes == 0, "empty document reads in no time")
        check(MarkDocument.decode(Data([0xEF, 0xBB, 0xBF] + Array("héllo".utf8))) == "héllo", "UTF-8 with a byte order mark")
        check(MarkDocument.decode(Data([0x63, 0x61, 0x66, 0x8E])) == "café", "Mac Roman fallback")
    }

    private static func editing() {
        let wrapped = Formatting.toggleWrap("say hi now", NSRange(location: 4, length: 2), marker: "**")
        check(wrapped.apply(to: "say hi now") == "say **hi** now" && wrapped.selection == NSRange(location: 6, length: 2), "bold wraps the selection")
        let unwrapped = Formatting.toggleWrap("say **hi** now", NSRange(location: 6, length: 2), marker: "**")
        check(unwrapped.apply(to: "say **hi** now") == "say hi now" && unwrapped.selection == NSRange(location: 4, length: 2), "bold again unwraps")
        let link = Formatting.link("see docs", NSRange(location: 4, length: 4))
        check(link.apply(to: "see docs") == "see [docs](https://)" && link.selection == NSRange(location: 11, length: 8), "link selects the URL to type")
        let h2 = Formatting.heading("one\n# two\nthree", NSRange(location: 6, length: 0), level: 2)
        check(h2.apply(to: "one\n# two\nthree") == "one\n## two\nthree" && h2.selection.location == 7, "heading level changes in place")
        let off = Formatting.heading("## two", NSRange(location: 4, length: 0), level: 2)
        check(off.apply(to: "## two") == "two" && off.selection.location == 1, "same heading level toggles off")
        let source = "- [ ] a\n```\n- [ ] fake\n```\n1. [x] b"
        check(Formatting.toggleTask(source, index: 1)?.apply(to: source) == "- [ ] a\n```\n- [ ] fake\n```\n1. [ ] b", "task toggle skips code")
        check(Formatting.toggleTask(source, index: 0)?.apply(to: source).hasPrefix("- [x] a") == true, "task toggle ticks")
        check(Formatting.toggleTask(source, index: 5) == nil, "missing task index")

        let storage = NSTextStorage(string: "# Title\n**bold** `code`\n```\n**not bold**\n```")
        Highlighter.apply(storage)
        let font = { (i: Int) in storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont }
        check(font(2) == Highlighter.bold && font(10) == Highlighter.bold, "headings and strong text are bold")
        check(font(30) == Highlighter.regular, "fenced code is not styled as Markdown")
    }

    /// Input people produce while typing, or that arrives in odd files: none of it may crash or hang the preview.
    private static func oddInput() {
        // Half-typed image titles used to trap on an inverted string range.
        check(MarkdownParser.parse("![a](x \")") == [.image(alt: "a", source: "x \"", title: nil)], "half-typed image title does not crash")
        check(MarkdownParser.parse("![a](x \"\")") == [.image(alt: "a", source: "x", title: "")], "empty image title")
        check(MarkdownParser.parse("![](") == [.paragraph("![](")], "unfinished image is text")

        // A selection covering the heading marks must stay inside the new text.
        let source = "## Title"
        let off = Formatting.heading(source, NSRange(location: 0, length: 8), level: 2)
        let result = off.apply(to: source)
        check(result == "Title" && off.selection == NSRange(location: 0, length: 5), "heading off keeps the selection in range (\(off.selection))")
        let on = Formatting.heading("Title", NSRange(location: 0, length: 5), level: 1)
        check(on.apply(to: "Title") == "# Title" && on.selection == NSRange(location: 2, length: 5), "heading on shifts the selection")
        let empty = Formatting.heading("", NSRange(location: 0, length: 0), level: 3)
        check(empty.apply(to: "") == "### " && empty.selection == NSRange(location: 4, length: 0), "heading on an empty document")

        // Pathological nesting is capped instead of recursing until the stack runs out.
        let deepQuote = String(repeating: ">", count: 5000) + " deep"
        check(nesting(MarkdownParser.parse(deepQuote)) <= MarkdownParser.maxDepth + 1, "five thousand nested quotes are capped")
        let deepList = (0..<400).map { String(repeating: "  ", count: $0) + "- item" }.joined(separator: "\n")
        check(nesting(MarkdownParser.parse(deepList)) <= MarkdownParser.maxDepth + 1, "four hundred nested list levels are capped")
        check(TextStats(source: deepQuote, blocks: MarkdownParser.parse(deepQuote)).words == 1, "the capped text is still counted")

        check(MarkdownParser.parse("").isEmpty && MarkdownParser.parse("\n\n  \n\t").isEmpty, "empty and blank documents have no blocks")
        check(MarkdownParser.parse("```").count == 1, "an unclosed fence is one code block")
        check(MarkdownParser.parse("|\n|-|") != [], "a bare pipe table does not crash")
        check(MarkdownParser.parse("1.") .count == 1 && MarkdownParser.parse("-").count == 1, "lone list markers")
        let unicode = "# Καλημέρα 🌍\n\n日本語のテキスト and émigré café"
        check(TextStats(source: unicode, blocks: MarkdownParser.parse(unicode)).words >= 5, "unicode words are counted")
        check(HTMLExporter.inline("🌍 <b>").contains("&lt;b&gt;"), "raw HTML is escaped in the export")

        // A long document parses quickly enough to reparse after each pause in typing.
        let big = String(repeating: Demo.text + "\n", count: 400)
        let start = Date()
        let blocks = MarkdownParser.parse(big)
        _ = TextStats(source: big, blocks: blocks)
        let seconds = Date().timeIntervalSince(start)
        check(blocks.count == 3200 && seconds < 3, "a 240 KB document parses and counts in \(String(format: "%.2f", seconds)) s")
        let storage = NSTextStorage(string: big)
        let hl = Date()
        Highlighter.apply(storage)
        check(Date().timeIntervalSince(hl) < 3, "a 240 KB document highlights in \(String(format: "%.2f", Date().timeIntervalSince(hl))) s")
    }

    private static func nesting(_ blocks: [Block]) -> Int {
        blocks.map { block -> Int in
            switch block {
            case .quote(let inner): 1 + nesting(inner)
            case .list(let list): 1 + (list.items.map { nesting($0.blocks) }.max() ?? 0)
            default: 0
            }
        }.max() ?? 0
    }

    private static func exports() {
        let long = (1...80).map { "## Section \($0)\n\nParagraph \($0) with some words to fill the line." }.joined(separator: "\n\n")
        let data = PDFExporter.pdf(MarkdownParser.parse(long), baseURL: nil)
        let pdf = PDFDocument(data: data)
        check(data.starts(with: Array("%PDF".utf8)), "PDF export writes a PDF")
        check((pdf?.pageCount ?? 0) > 2, "long documents paginate (\(pdf?.pageCount ?? 0) pages)")
        check(pdf?.page(at: 0)?.string?.contains("Section 1") == true, "PDF text is real text, not pixels")
        let empty = PDFDocument(data: PDFExporter.pdf([], baseURL: nil))
        check(empty?.pageCount == 1, "an empty document still exports one page")

        // Relative image paths resolve against the document's folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mark-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("img/dot.png")
        try? appIcon().representation(using: .png, properties: [:])?.write(to: png)
        check(ImageCache.resolve("img/dot.png", base: dir)?.path == png.path, "relative image path resolves")
        check(ImageCache.image("img/dot.png", base: dir) != nil, "relative image loads")
        check(ImageCache.resolve("https://example.com/a.png", base: dir) == nil, "remote images are never fetched")
    }
}
