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

        // Keeping the place when the text reflows.
        var reflow = PromptClock()
        reflow.limit = 4000
        reflow.offset = 500
        reflow.rescale(by: 1.5)
        check(reflow.offset == 750, "a larger text size keeps the reader on the same words")
        reflow.limit = 600
        reflow.rescale(by: 1)
        check(reflow.offset == 600, "a reflow never scrolls past the end")
        reflow.rescale(by: .nan)
        check(reflow.offset == 600, "a bad reflow factor is ignored")

        // Importing files: encodings, line breaks, binaries, rich text, empty and huge files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cue-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ data: Data) -> URL {
            let url = dir.appendingPathComponent(name)
            try? data.write(to: url)
            return url
        }
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Καλημέρα\r\nworld".data(using: .utf16LittleEndian)!)
        check(Importer.text(from: write("notepad.txt", utf16)) == "Καλημέρα\nworld", "UTF-16 files with a byte order mark import")
        check(Importer.text(from: write("bom.txt", Data([0xEF, 0xBB, 0xBF]) + Data("Hi".utf8))) == "Hi", "the UTF-8 byte order mark is dropped")
        check(Importer.text(from: write("mac.txt", Data("one\rtwo\r\nthree".utf8))) == "one\ntwo\nthree", "old Mac and Windows line breaks become one kind")
        check(Importer.text(from: write("latin.txt", Data([0x63, 0x61, 0x66, 0xE9]))) == "café", "a Latin-1 file still imports")
        check(Importer.text(from: write("binary.txt", Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]))) == nil, "binary files are refused")
        check(Importer.text(from: write("empty.txt", Data())) == "", "an empty file imports as an empty script")
        check(Importer.text(from: write("huge.txt", Data(repeating: 0x61, count: Importer.maxBytes + 1))) == nil, "huge files are refused")
        let rtf = Data(#"{\rtf1\ansi{\fonttbl\f0 Helvetica;}\f0 Hello \b bold\b0  world.\par Second line}"#.utf8)
        let rtfText = Importer.text(from: write("talk.rtf", rtf))
        check(rtfText?.hasPrefix("Hello bold world.\nSecond line") == true, "rich text imports as plain words")
        check(Importer.text(from: dir) == nil, "a folder is not a script")
        let original = write("keep.txt", Data("Original".utf8))
        let importModel = MainActor.assumeIsolated { () -> (Int, String?) in
            let model = CueModel(persists: false)
            let added = model.importFiles([original, dir.appendingPathComponent("binary.txt")])
            return (added, model.selected?.title)
        }
        check(importModel.0 == 1 && importModel.1 == "keep", "importing skips the unreadable and titles from the file name")
        check((try? String(contentsOf: original, encoding: .utf8)) == "Original", "importing never changes the original file")

        // A library file that no longer reads is moved aside, not overwritten.
        let broken = write("scripts.json", Data("{not json".utf8))
        let recovered = MainActor.assumeIsolated { CueModel.loadScripts(at: broken) }
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasPrefix("scripts.unreadable-") } ?? false
        check(recovered.count == 1 && aside && !FileManager.default.fileExists(atPath: broken.path), "an unreadable library is kept aside")
        let missing = MainActor.assumeIsolated { CueModel.loadScripts(at: dir.appendingPathComponent("none.json")) }
        check(missing.first?.title == "Welcome to Cue", "a first launch seeds the welcome script")

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

        let redo = MainActor.assumeIsolated { () -> Bool in
            let model = CueModel(persists: false)
            model.newScript()
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            model.delete(model.scripts[0].id, undo: undo)
            undo.endUndoGrouping()
            undo.undo()
            guard model.scripts.count == 1, undo.canRedo else { return false }
            undo.redo()
            return model.scripts.isEmpty && model.selection == nil
        }
        check(redo, "a deleted script can be redeleted with redo")

        let dup = MainActor.assumeIsolated { () -> String? in
            let model = CueModel(persists: false)
            model.scripts = [Script(title: "  ", text: "x")]
            model.duplicate(model.scripts[0].id)
            return model.selected?.title
        }
        check(dup == "Untitled script copy", "duplicating an untitled script names the copy sensibly")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
