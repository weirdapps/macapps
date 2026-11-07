import Foundation

/// `Cue --selftest`: checks the counting, timing, motion and persistence logic. Returns 0 when all pass.
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

    static func run() -> Int32 {
        // Word counting.
        check(Metrics.wordCount("") == 0, "empty text has no words")
        check(Metrics.wordCount("Hello,   world!\nAgain") == 3, "words across spaces and lines")
        check(Metrics.wordCount("Wait - what? 3 times") == 4, "lone dashes are not words, digits are")
        check(Metrics.wordCount("  \n\t ") == 0, "whitespace only")

        // Timing.
        check(Metrics.duration(words: 140, wpm: 140) == 60, "140 words at 140 wpm is a minute")
        check(Metrics.duration(words: 10, wpm: 0) == 0, "zero pace gives zero, not infinity")
        check(Metrics.clock(42.9) == "0:42", "clock truncates seconds")
        check(Metrics.clock(190) == "3:10", "clock minutes")
        check(Metrics.clock(3723) == "1:02:03", "clock hours")
        check(Metrics.clock(-5) == "0:00", "clock never negative")
        check(Metrics.spoken(45) == "45 s", "spoken seconds")
        check(Metrics.spoken(190) == "3 min 10 s", "spoken minutes and seconds")
        check(Metrics.spoken(120) == "2 min", "spoken whole minutes")
        check(Metrics.spoken(3720) == "1 h 2 min", "spoken hours")

        // Speed is in lines, so it feels the same at any text size.
        let small = Metrics.pointsPerSecond(speed: 5, fontSize: 40) / Metrics.lineHeight(fontSize: 40)
        let big = Metrics.pointsPerSecond(speed: 5, fontSize: 120) / Metrics.lineHeight(fontSize: 120)
        check(abs(small - 1) < 1e-9 && abs(big - 1) < 1e-9, "speed 5 is one line a second at any size")

        // Settings clamping and steps.
        var s = PromptSettings()
        s.changeSpeed(by: 100)
        check(s.speed == PromptSettings.speedRange.upperBound, "speed clamps high")
        s.changeSpeed(by: -100)
        check(s.speed == PromptSettings.speedRange.lowerBound, "speed clamps low")
        s.speed = 3.2
        s.changeSpeed(by: 0.5)
        check(s.speed == 3.5, "speed snaps to half steps")
        s.changeFont(by: -1000)
        check(s.fontSize == PromptSettings.fontRange.lowerBound, "font clamps")

        // Tolerant settings decoding.
        let partial = try? JSONDecoder().decode(PromptSettings.self, from: Data(#"{"speed": 6, "mirror": true, "margin": 4}"#.utf8))
        check(partial?.speed == 6 && partial?.mirror == true && partial?.fontSize == 72, "older settings files decode with defaults")
        check(partial?.margin == PromptSettings.marginRange.upperBound, "decoded values are clamped")

        // Prompt motion.
        var clock = PromptClock()
        clock.limit = 1000
        clock.start(countdown: true)
        check(clock.countdownNumber == 3, "countdown starts at 3")
        for _ in 0..<11 { clock.advance(by: 0.1, rate: 100) }
        check(clock.countdownNumber == 2 && clock.offset == 0, "countdown does not scroll")
        for _ in 0..<20 { clock.advance(by: 0.1, rate: 100) }
        check(clock.isPlaying, "countdown ends in playing")
        let before = clock.offset
        clock.advance(by: 0.05, rate: 100)
        check(abs(clock.offset - before - 5) < 1e-9, "playing scrolls at the rate")
        clock.advance(by: 5, rate: 100)
        check(abs(clock.offset - before - 15) < 1e-9, "a long frame is capped, no jumps after a stall")
        clock.toggle(countdown: true)
        let paused = clock.offset
        clock.advance(by: 0.1, rate: 100)
        check(clock.phase == .paused && clock.offset == paused, "paused does not move")
        clock.toggle(countdown: true)
        for _ in 0..<200 { clock.advance(by: 0.1, rate: 100) }
        check(clock.phase == .finished && clock.offset == 1000, "stops at the end")
        check(clock.progress == 1, "progress is full at the end")
        clock.nudge(by: -50)
        check(clock.phase == .paused && clock.offset == 950, "stepping back from the end pauses")
        clock.nudge(by: -5000)
        check(clock.offset == 0, "nudge never goes above the top")
        clock.start(countdown: false)
        check(clock.isPlaying && clock.elapsed == 0, "restart without countdown plays at once")
        clock.phase = .countdown(2)
        clock.toggle(countdown: true)
        check(clock.isPlaying, "space during the countdown starts at once")

        // Titles of imported files.
        check(Metrics.title(fileName: "Keynote.txt", text: "x") == "Keynote", "title from file name")
        check(Metrics.title(fileName: ".txt", text: "\nFirst line\nmore") == "First line", "title from first line")

        // Persistence round trip.
        let scripts = [Script(title: "One", text: "Hello there"), Script(title: "", text: "")]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cue-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try? JSONEncoder().encode(scripts)
        try? data?.write(to: url)
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Script].self, from: $0) }
        check(loaded == scripts, "scripts survive a save and load")
        check(loaded?.last?.displayTitle == "Untitled script", "blank titles show as Untitled script")

        // The library.
        let ok = MainActor.assumeIsolated { () -> Bool in
            let model = CueModel(persists: false)
            model.newScript()
            let first = model.selection
            model.newScript()
            guard model.scripts.count == 2, model.selection == model.scripts[0].id else { return false }
            model.binding(for: model.scripts[1].id)?.wrappedValue.text = "Changed words here"
            guard model.scripts[1].words == 3 else { return false }
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            model.delete(model.scripts[0].id, undo: undo)
            undo.endUndoGrouping()
            guard model.scripts.count == 1, model.selection == first else { return false }
            undo.undo()
            return model.scripts.count == 2 && model.selection == model.scripts[0].id
        }
        check(ok, "new, edit, delete and undo delete in the library")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
