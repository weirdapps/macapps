import Foundation

/// `Tail --selftest`: exercises line splitting, tail reading, following (appends, truncation, rotation, deletion),
/// filtering, highlighting and the log buffer, on temporary files it creates and deletes.
@MainActor
enum SelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }

    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TailSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        splitting()
        tailReading(dir)
        bigFile(dir)
        following(dir)
        openedMidLine(dir)
        filtering()
        highlighting()
        buffer()

        print("\(passed) checks passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    // MARK: Splitting

    private static func splitting() {
        var s = LineSplitter()
        check(s.feed(Data("a\nb".utf8)) == ["a"], "splitter emits complete lines only")
        check(s.feed(Data("c\n".utf8)) == ["bc"], "splitter joins a line across reads")
        check(s.feed(Data("x\r\ny\r\n".utf8)) == ["x", "y"], "splitter drops carriage returns")
        let accented = Data("café\n".utf8)
        check(s.feed(accented.prefix(4)) == [] && s.feed(accented.dropFirst(4)) == ["café"], "UTF-8 split across reads decodes")
        check(s.feed(Data("\u{1B}[31mred\u{1B}[0m text\n".utf8)) == ["red text"], "terminal colour codes are stripped")
        _ = s.feed(Data("tail".utf8))
        check(s.flush() == "tail" && s.flush() == nil, "flush returns the unfinished line once")
        check(s.feed(Data("\n\n".utf8)) == ["", ""], "empty lines are kept")
        check(LineSplitter.stripEscapes("\u{1B}]0;build\u{07}ok \u{1B}]8;;https://x\u{1B}\\link") == "ok link",
              "terminal title and hyperlink codes are stripped")
    }

    // MARK: Tail reading

    private static func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url)
    }

    private static func tailReading(_ dir: URL) {
        let url = dir.appendingPathComponent("ten.log")
        write((1...10).map { "line \($0)\n" }.joined(), to: url)
        let three = try? TailReader.read(url: url, lines: 3)
        check(three?.lines == ["line 8", "line 9", "line 10"], "last 3 of 10 lines")
        check(three?.reachedStart == true, "small file is read from its start")
        check((try? TailReader.read(url: url, lines: 50))?.lines.count == 10, "asking for more lines than exist returns all")
        let tiny = try? TailReader.read(url: url, lines: 4, chunk: 7)
        check(tiny?.lines == ["line 7", "line 8", "line 9", "line 10"], "tail is right across tiny chunk boundaries")

        let open = dir.appendingPathComponent("open.log")
        write("first\nsecond\nno newline yet", to: open)
        check((try? TailReader.read(url: open, lines: 2))?.lines == ["second", "no newline yet"], "a last line without newline is shown")

        let empty = dir.appendingPathComponent("empty.log")
        write("", to: empty)
        check((try? TailReader.read(url: empty, lines: 10))?.lines == [], "empty file gives no lines")
        check((try? TailReader.read(url: dir.appendingPathComponent("absent.log"), lines: 5)) == nil, "missing file throws")
    }

    /// A sparse 1 GB file with 200 lines at its end: reading the tail must be instant and exact.
    private static func bigFile(_ dir: URL) {
        let url = dir.appendingPathComponent("huge.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { check(false, "create 1 GB file"); return }
        let gigabyte: UInt64 = 1 << 30
        try? handle.truncate(atOffset: gigabyte)
        _ = try? handle.seekToEnd()
        handle.write(Data(("\n" + (1...200).map { "request \($0) ok\n" }.joined()).utf8))
        try? handle.close()

        let start = Date()
        let result = try? TailReader.read(url: url, lines: 50)
        let elapsed = Date().timeIntervalSince(start)
        check(result?.lines.count == 50 && result?.lines.last == "request 200 ok" && result?.lines.first == "request 151 ok",
              "last 50 lines of a 1 GB file")
        check(result?.reachedStart == false && (result?.size ?? 0) > gigabyte, "1 GB file is not read from the start")
        check(elapsed < 0.25, "tail of a 1 GB file reads in \(String(format: "%.3f", elapsed)) s")
        let capped = try? TailReader.read(url: url, lines: 5_000, maxBytes: 4 << 20)
        check(capped?.lines.count == 200, "a byte cap stops the walk back through a huge file")
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Following

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [Follower.Event] = []
        func add(_ event: Follower.Event) { lock.withLock { events.append(event) } }
        var all: [Follower.Event] { lock.withLock { events } }
        var lines: [String] {
            all.flatMap { event -> [String] in
                switch event {
                case .loaded(let lines, _, _), .appended(let lines, _), .completed(let lines, _): lines
                default: []
                }
            }
        }
    }

    private static func wait(_ seconds: Double = 3, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    private static func append(_ text: String, to url: URL) {
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    private static func following(_ dir: URL) {
        let url = dir.appendingPathComponent("live.log")
        write("old 1\nold 2\nold 3\n", to: url)
        let recorder = Recorder()
        let follower = Follower(path: url.path, initialLines: 2, pollInterval: 0.15, staleAfter: 0.3) { recorder.add($0) }
        follower.start()
        defer { follower.stop() }

        check(wait { recorder.all.first == .loaded(lines: ["old 2", "old 3"], reachedStart: true, size: 18) },
              "initial load shows the last lines")
        append("new 1\nnew 2\n", to: url)
        check(wait { recorder.lines.suffix(2) == ["new 1", "new 2"] }, "appended lines arrive")

        append("half", to: url)
        Thread.sleep(forTimeInterval: 0.05)
        append(" done\n", to: url)
        check(wait { recorder.lines.last == "half done" }, "a line written in two parts arrives whole")

        append("no newline", to: url)
        check(wait { recorder.lines.last == "no newline" }, "an unfinished line shows once the writer pauses")
        append(" finished\n", to: url)
        check(wait { recorder.all.last == .completed(["no newline finished"], size: 60) },
              "a finished line replaces its unfinished start")

        // copytruncate style rotation: the same file emptied in place.
        try? FileHandle(forWritingTo: url).truncate(atOffset: 0)
        check(wait { recorder.all.contains(.truncated) }, "truncation is noticed")
        append("after truncate\n", to: url)
        check(wait { recorder.lines.last == "after truncate" }, "lines after truncation arrive")

        // Rename and recreate, like logrotate's default.
        try? FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("live.log.1"))
        write("fresh 1\n", to: url)
        check(wait { recorder.all.contains(.rotated) }, "rotation to a new file is noticed")
        check(wait { recorder.lines.last == "fresh 1" }, "the new file's lines arrive")
        append("fresh 2\n", to: url)
        check(wait { recorder.lines.last == "fresh 2" }, "the new file is followed")

        // Deleted, then back.
        try? FileManager.default.removeItem(at: url)
        check(wait { recorder.all.contains(.missing) }, "a deleted file is noticed")
        let rotations = recorder.all.count(where: { $0 == .rotated })
        write("back again\n", to: url)
        check(wait { recorder.all.count(where: { $0 == .rotated }) > rotations && recorder.lines.last == "back again" },
              "a file that comes back is followed again")
    }

    /// A file whose last line is unfinished when it is opened.
    private static func openedMidLine(_ dir: URL) {
        let url = dir.appendingPathComponent("midline.log")
        write("one\ntw", to: url)
        let recorder = Recorder()
        let follower = Follower(path: url.path, initialLines: 5, pollInterval: 0.15, staleAfter: 0.3) { recorder.add($0) }
        follower.start()
        defer { follower.stop() }
        check(wait { recorder.all.first == .loaded(lines: ["one", "tw"], reachedStart: true, size: 6) }, "an unfinished last line is loaded")
        append("o\nthree\n", to: url)
        check(wait { recorder.all.last == .completed(["two", "three"], size: 14) }, "its rest joins it instead of starting a new line")
    }

    // MARK: Filtering and highlighting

    private static func filtering() {
        let plain = LineMatcher(text: "timeout", isRegex: false)
        check(plain.matches("SMTP Timeout after 10s") && !plain.matches("all good"), "plain filter ignores case")
        check(plain.ranges(in: "timeout, timeout").count == 2, "plain filter finds every match")
        let regex = LineMatcher(text: #"\b(4|5)\d\d\b"#, isRegex: true)
        check(regex.matches("GET /x 502 3ms") && !regex.matches("GET /x 200 3ms"), "regex filter")
        let broken = LineMatcher(text: "([a-", isRegex: true)
        check(broken.isInvalid && broken.matches("anything") && !broken.isActive, "an invalid regex hides nothing")
        check(!LineMatcher(text: "", isRegex: true).isActive, "an empty filter is inactive")
    }

    private static func highlighting() {
        let highlighter = Highlighter(rules: HighlightRule.defaults)
        check(highlighter.tone(of: "12:00 ERROR disk full") == .red, "ERROR is red")
        check(highlighter.tone(of: "warn: low memory") == .orange, "rules ignore case")
        check(highlighter.tone(of: "INFORMATION only") == nil, "rules match whole words")
        check(highlighter.tone(of: "WARN then ERROR") == .red, "the first rule in the list wins")
        check(highlighter.matches(in: "INFO and ERROR").count == 2, "every rule word is highlighted")
        var rules = HighlightRule.defaults
        rules[1].isEnabled = false
        check(Highlighter(rules: rules).tone(of: "ERROR x") == nil, "a disabled rule is ignored")
        let data = try? JSONEncoder().encode(HighlightRule.defaults)
        check(data.flatMap { try? JSONDecoder().decode([HighlightRule].self, from: $0) } == HighlightRule.defaults, "rules round trip as JSON")
    }

    // MARK: The buffer

    private static func buffer() {
        let source = LogSource(url: URL(fileURLWithPath: "/tmp/x.log"), maxLines: 5, highlighter: Highlighter(rules: HighlightRule.defaults))
        source.ingest((1...8).map { $0 == 2 || $0 == 7 ? "ERROR \($0)" : "line \($0)" })
        check(source.lines.map(\.text) == ["line 4", "line 5", "line 6", "ERROR 7", "line 8"], "buffer keeps the last N lines")
        check(source.errorCount == 1, "error count follows trimming")
        source.apply(matcher: LineMatcher(text: "error", isRegex: false))
        check(source.visible.map(\.text) == ["ERROR 7"], "filter narrows the visible lines")
        source.ingest(["ERROR 9", "line 10"])
        check(source.visible.map(\.text) == ["ERROR 7", "ERROR 9"], "new lines are filtered as they arrive")
        check(source.visible.map(\.id) == source.visible.map(\.id).sorted(), "visible ids stay in order")

        source.togglePause()
        source.ingest(["line 11", "line 12"])
        check(source.pendingCount == 2 && source.lines.last?.text == "line 10", "pause holds new lines")
        source.togglePause()
        check(source.pendingCount == 0 && source.lines.last?.text == "line 12", "resume releases held lines")

        source.follow = false
        source.apply(matcher: .all)
        source.ingest(["a", "b", "c"])
        check(source.unseen == 3, "lines arriving with auto-scroll off are counted")
        source.jumpToBottom()
        check(source.follow && source.unseen == 0, "jump to bottom turns auto-scroll back on")

        let token = source.rebuildToken
        source.clear()
        check(source.lines.isEmpty && source.visible.isEmpty && source.errorCount == 0 && source.rebuildToken > token, "clear empties the view")
        source.handle(.missing)
        check(source.state == .waiting && source.visible.first?.isNotice == true, "a missing file shows a notice")
        source.ingest([String(repeating: "x", count: 20_000)])
        check(source.lines.last.map { $0.text.count < 9_000 } == true, "very long lines are cut")
        let wide = String(repeating: "日", count: 4_000)
        source.ingest([wide])
        check(source.lines.last?.text == wide, "a long line of wide characters under the limit is not cut")

        // A line shown unfinished, then finished by the writer.
        let partial = LogSource(url: URL(fileURLWithPath: "/tmp/p.log"), maxLines: 10, highlighter: Highlighter(rules: HighlightRule.defaults))
        partial.ingest(["start", "ERROR half"])
        partial.handle(.completed(["ERROR half done", "next"], size: 40))
        check(partial.lines.map(\.text) == ["start", "ERROR half done", "next"] && partial.visible.map(\.text) == partial.lines.map(\.text),
              "a completed line replaces the unfinished one")
        check(partial.errorCount == 1, "a completed error line is counted once")
        check(LogTextView.Coordinator.contains(partial.visible, partial.visible[1].id)
              && !LogTextView.Coordinator.contains(partial.visible, 1), "the view finds which lines are still shown")
        partial.togglePause()
        partial.ingest(["held"])
        partial.handle(.completed(["held more"], size: 50))
        check(partial.pendingCount == 1 && partial.lines.last?.text == "next", "completing a held line keeps it held")
        partial.togglePause()
        check(partial.lines.last?.text == "held more", "the completed held line appears on resume")

        // Opening a big log must not stall the window.
        let big = LogSource(url: URL(fileURLWithPath: "/tmp/big.log"), maxLines: 100_000, highlighter: Highlighter(rules: HighlightRule.defaults))
        let lines = (0..<100_000).map { "2026-11-07 09:41:\($0 % 60) INFO  [http] GET /api/products/\($0) 200 14ms" }
        let start = Date()
        big.handle(.loaded(lines: lines, reachedStart: true, size: 8_000_000))
        let elapsed = Date().timeIntervalSince(start)
        check(big.lines.count == 100_000 && elapsed < 1.5, "100,000 lines are taken in \(String(format: "%.2f", elapsed)) s")
    }
}
