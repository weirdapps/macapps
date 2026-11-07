import AppKit
import Foundation

@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(name)") }
    }

    static func run() -> Int32 {
        // Word and character counts.
        check(TextStats.countWords("") == 0, "empty text has no words")
        check(TextStats.countWords("Hello, world!") == 2, "two words with punctuation")
        check(TextStats.countWords("don't stop") == 2, "apostrophe stays inside a word")
        check(TextStats.countWords("a well-known fact") == 3, "hyphenated word counts once")
        check(TextStats.countWords("# Title\n\n- one\n- two **bold**") == 4, "Markdown marks are not words")
        check(TextStats.countWords("Καλημέρα κόσμε") == 2, "Greek words with accents")
        check(TextStats.countWords("1984 was 3 words") == 4, "numbers are words")
        check(TextStats.countWords("end -- start") == 2, "a lone dash is not a word")
        check(TextStats("héllo 👋").characters == 7, "characters count graphemes")

        // Reading time.
        check(TextStats("").readingMinutes == 0, "no words, no reading time")
        check(TextStats("one").readingMinutes == 1, "one word is one minute")
        check(TextStats(Array(repeating: "word", count: 239).joined(separator: " ")).readingMinutes == 2, "239 words round up")

        // Session goal.
        let session = WritingSession()
        session.update(words: 100)
        check(session.written == 0, "session starts at the opening word count")
        session.update(words: 160)
        check(session.written == 60, "session counts words added")
        session.update(words: 80)
        check(session.written == 0, "deleting below the start never goes negative")
        session.update(words: 90)
        check(session.written == 10, "after deleting, new words count from the new low")
        session.restart()
        check(session.written == 0, "restart sets the start to now")
        check(WritingSession.progress(written: 250, goal: 500) == 0.5, "progress is a fraction")
        check(WritingSession.progress(written: 900, goal: 500) == 1, "progress caps at one")
        check(WritingSession.progress(written: 10, goal: 0) == 0, "zero goal has no progress")

        // Focus ranges.
        let text = "First one. Second one.\n\nNext paragraph here." as NSString
        check(FocusRange.range(in: text, caret: 3, mode: .paragraph) == NSRange(location: 0, length: 22), "paragraph around the caret")
        check(FocusRange.range(in: text, caret: 22, mode: .paragraph) == NSRange(location: 0, length: 22),
              "caret at a paragraph end belongs to it")
        check(FocusRange.range(in: text, caret: text.length, mode: .paragraph) == NSRange(location: 24, length: 20),
              "caret at the end of the text")
        check(FocusRange.range(in: text, caret: 14, mode: .sentence) == text.range(of: "Second one."), "sentence around the caret")
        check(FocusRange.range(in: text, caret: 2, mode: .sentence).location == 0, "first sentence")
        check(FocusRange.range(in: text, caret: 5, mode: .off) == NSRange(location: 0, length: text.length), "off keeps everything")
        check(FocusRange.range(in: "" as NSString, caret: 0, mode: .sentence) == NSRange(location: 0, length: 0), "empty text")

        // Markdown spans.
        let md = "## Heading\n> quoted\n- item with **strong** and *soft* words\nsnake_case_name stays plain" as NSString
        let spans = Markdown.spans(in: md, range: NSRange(location: 0, length: md.length))
        check(spans.contains(.heading(NSRange(location: 0, length: 10))), "heading line")
        check(spans.contains(.marker(NSRange(location: 0, length: 2))), "heading marks")
        check(spans.contains(.quote(md.range(of: "> quoted"))), "quote line")
        check(spans.contains(.strong(md.range(of: "**strong**"))), "strong text")
        check(spans.contains(.emphasis(md.range(of: "*soft*"))), "emphasis")
        check(spans.contains(.marker(md.range(of: "-"))), "list marker")
        check(!spans.contains { if case .emphasis(let r) = $0 { return NSIntersectionRange(r, md.range(of: "snake_case_name")).length > 0 }; return false },
              "underscores inside words are not emphasis")
        check(Markdown.spans(in: "#hashtag" as NSString, range: NSRange(location: 0, length: 8)).isEmpty, "a hashtag is not a heading")

        // Files: encoding round trip on a temporary file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft-selftest-\(UUID().uuidString).md")
        let sample = "# Café\n\nNaïve résumé, Ελληνικά, 漢字.\n"
        do {
            try DraftDocument.encode(sample).write(to: url)
            check(DraftDocument.decode(try Data(contentsOf: url)) == sample, "UTF-8 file round trip")
        } catch {
            check(false, "temporary file round trip: \(error)")
        }
        try? FileManager.default.removeItem(at: url)
        check(DraftDocument.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)) == "hi", "UTF-8 byte order mark is dropped")
        check(DraftDocument.decode("hé".data(using: .utf16)!) == "hé", "UTF-16 with a mark")
        check(DraftDocument.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café", "Windows Latin 1 fallback")

        // Layout.
        let style = Prefs(store: nil).style(markdown: true)
        check(style.columnWidth > 400 && style.columnWidth < 800, "66 characters at 18 pt is a comfortable column")
        check(EditorStyle.horizontalInset(viewWidth: 1000, column: 600) == 200, "column centres")
        check(EditorStyle.horizontalInset(viewWidth: 500, column: 600) == 32, "narrow windows keep a margin")
        let prefs = Prefs(store: nil)
        prefs.size = 32
        prefs.bigger()
        check(prefs.size == 32, "Bigger stops at the largest size")
        check(Typeface.serif.font(size: 18).pointSize == 18, "serif font resolves")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
