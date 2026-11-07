import Foundation

/// `Typist --selftest`: the speed and accuracy maths, the text generator and the typing session.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.001) -> Bool { abs(a - b) <= tolerance }

    static func run() -> Int32 {
        // WPM: five characters make a word.
        check(near(Stats.grossWPM(characters: 300, seconds: 60), 60), "300 characters in a minute is 60 wpm")
        check(near(Stats.grossWPM(characters: 150, seconds: 15), 120), "150 characters in 15 s is 120 wpm")
        check(Stats.grossWPM(characters: 50, seconds: 0) == 0, "no time means 0 wpm, not infinity")
        check(near(Stats.netWPM(characters: 300, uncorrectedErrors: 10, seconds: 60), 50), "10 errors in a minute cost 10 wpm")
        check(near(Stats.netWPM(characters: 150, uncorrectedErrors: 5, seconds: 30), 50), "5 errors in 30 s cost 10 wpm")
        check(Stats.netWPM(characters: 20, uncorrectedErrors: 30, seconds: 60) == 0, "net wpm never goes negative")
        check(near(Stats.accuracy(correct: 95, total: 100), 95), "95 of 100 keystrokes is 95%")
        check(Stats.accuracy(correct: 0, total: 0) == 100, "no keystrokes is 100%")

        // Keys.
        check(KeyMap.key(for: "A") == "a" && KeyMap.key(for: "!") == "1" && KeyMap.key(for: "?") == "/", "shifted characters map to their key")
        check(KeyMap.key(for: " ") == "space" && KeyMap.key(for: "\"") == "'", "space and quote keys")

        // Heatmap scale: a single slip on a rare key must not wash out the rest of the map.
        let heat: [String: (hits: Int, errors: Int)] = ["q": (1, 1), "e": (100, 10), "r": (50, 10), "t": (40, 0), "x": (5, 9)]
        check(Heat.rate(heat["q"]) == 1 && Heat.rate(heat["x"]) == 1 && Heat.rate(nil) == nil, "miss rate is clamped and nil when untyped")
        check(near(Heat.worst(["q": (1, 1), "e": (100, 10)]), 0.1), "rarely typed keys do not set the heat scale")
        check(Heat.worst([:]) == 0.02, "an empty map still has a scale")
        check(Heat.trouble(heat).map(\.0) == ["x", "r", "e"], "most missed keys, worst first, rare keys left out")
        check(Heat.trouble(["a": (10, 1), "b": (10, 1)]).map(\.0) == ["a", "b"], "ties sort by key so the list does not flicker")

        // Wrapping.
        let text = Array("the quick brown fox jumps over the lazy dog")
        let lines = Wrap.lines(text, columns: 12)
        check(lines.map { String(text[$0]) } == ["the quick ", "brown fox ", "jumps over ", "the lazy dog"], "greedy wrap keeps words whole")
        check(lines.first?.lowerBound == 0 && lines.last?.upperBound == text.count
              && zip(lines, lines.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound }, "wrapped lines tile the text")
        check(Wrap.lines(Array("abcdefghij"), columns: 4).count == 3, "an overlong word breaks")
        check(Wrap.line(of: 11, in: lines) == 1 && Wrap.line(of: text.count, in: lines) == 3, "caret line lookup")

        // Text generation.
        var a = SplitMix64(seed: 1), b = SplitMix64(seed: 1)
        let w1 = TextGenerator.words(25, punctuation: false, numbers: false, using: &a)
        let w2 = TextGenerator.words(25, punctuation: false, numbers: false, using: &b)
        check(w1 == w2, "the same seed gives the same words")
        check(w1.count == 25 && w1.allSatisfy { Words.common.contains($0) }, "plain words come from the list")
        check(zip(w1, w1.dropFirst()).allSatisfy { $0 != $1 }, "no word repeats back to back")
        var c = SplitMix64(seed: 2)
        let punct = TextGenerator.words(200, punctuation: true, numbers: false, using: &c)
        check(punct.first?.first?.isUppercase == true && punct.last?.hasSuffix(".") == true, "punctuated text starts capitalised and ends with a full stop")
        check(punct.contains { $0.contains(",") } && punct.contains { $0.contains(".") }, "punctuation appears")
        var d = SplitMix64(seed: 3)
        check(TextGenerator.words(200, punctuation: false, numbers: true, using: &d).contains { Int($0) != nil }, "numbers appear")
        check(Words.common.count >= 200 && Words.quotes.count >= 20, "embedded word list and quotes")
        check(Words.quotes.allSatisfy { !$0.text.contains("\u{2014}") && !$0.text.contains("\u{2013}") && !$0.author.isEmpty }, "quotes are clean")

        // A session: one corrected slip and one left in.
        var s = TypingSession(text: "cat sat")
        for ch in "cx" { s.type(ch) }
        s.backspace()
        for ch in "at sxt" { s.type(ch) }
        check(s.isComplete, "session completes at the end of the text")
        check(s.correctKeys == 6 && s.wrongKeys == 2, "keystrokes counted, corrected ones too")
        check(s.uncorrectedErrors == 1, "one error left in")
        check(near(Stats.accuracy(correct: s.correctKeys, total: s.correctKeys + s.wrongKeys), 75), "session accuracy")
        check(s.keyErrors == ["a": 2] && s.keyHits["a"] == 3, "errors land on the expected key")
        check(s.wordsDone == 2 && s.totalWords == 2, "word progress")
        s.type("z")
        check(s.typed.count == 7, "typing past the end is ignored")
        s.deleteWord()
        check(String(s.typed) == "cat ", "option delete removes a word")
        s.deleteWord()
        check(s.typed.isEmpty, "option delete again reaches the start")

        // Persistence and export.
        let result = TestResult(date: Date(timeIntervalSince1970: 0), mode: "30 seconds", netWPM: 71.25, rawWPM: 75, accuracy: 96.5,
                                seconds: 30, characters: 187, errors: 2, keyHits: ["e": 20], keyErrors: ["e": 1])
        let decoded = (try? JSONEncoder().encode([result])).flatMap { try? JSONDecoder().decode([TestResult].self, from: $0) }
        check(decoded == [result], "history survives a JSON round trip")
        let csv = CSV.history([result]).split(separator: "\n")
        check(csv.count == 2 && csv[1] == "1970-01-01T00:00:00Z,30 seconds,71.2,75.0,96.5,30.0,187,2", "CSV export row")
        let config = TestConfig(mode: .words, seconds: 60, wordCount: 50, punctuation: true, numbers: false)
        check((try? JSONEncoder().encode(config)).flatMap { try? JSONDecoder().decode(TestConfig.self, from: $0) } == config, "settings round trip")
        check(config.label == "50 words" && config.extras == ["punctuation"], "settings labels")

        // The model runs a whole words test to a result.
        MainActor.assumeIsolated {
            let model = TypistModel(persists: false)
            model.config = TestConfig(mode: .words, wordCount: 10)
            check(model.session.totalWords == 10 && model.phase == .ready, "a words test has its words")
            for ch in model.session.target { model.type(ch) }
            check(model.phase == .finished && model.history.count == 1, "finishing a test records a result")
            check(model.lastResult?.errors == 0 && model.lastResult?.accuracy == 100, "a clean run scores 100%")
            check(model.samples.last.map { near($0.wpm, model.lastResult?.netWPM ?? -1) } ?? false, "the last chart point matches the result")
            let text = model.session.target
            model.restart()
            check(model.session.target == text && model.phase == .ready && model.session.typed.isEmpty, "restart keeps the text")
            model.config.mode = .quote
            check(model.author != nil && Words.quotes.contains { Array($0.text) == model.session.target }, "quote mode shows a quote and its author")
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            model.clearHistory(undoManager: undo)
            undo.endUndoGrouping()
            check(model.history.isEmpty, "history clears")
            undo.undo()
            check(model.history.count == 1, "undo brings the history back")
            check(undo.canRedo, "clearing can be redone")
            undo.redo()
            check(model.history.isEmpty, "redo clears it again")
        }

        print(failures == 0 ? "PASS: \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
