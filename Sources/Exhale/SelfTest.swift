import Foundation
import Kit

/// `Exhale --selftest`: checks phase timing, session maths, history sums and the synthesised cues.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-6) -> Bool { abs(a - b) <= tolerance }

    static func run() -> Int32 {
        let box = Patterns.phases(.box)
        check(Breath.cycleLength(box) == 16, "box cycle is 16 s")
        check(Breath.state(at: 0, phases: box).kind == .inhale, "box starts with an inhale")
        check(Breath.state(at: 3.999, phases: box).kind == .inhale, "box still inhaling just before 4 s")
        check(Breath.state(at: 4, phases: box).kind == .holdFull, "box holds at 4 s")
        check(Breath.state(at: 8, phases: box).kind == .exhale, "box exhales at 8 s")
        check(Breath.state(at: 12, phases: box).kind == .holdEmpty, "box holds empty at 12 s")
        let second = Breath.state(at: 16, phases: box)
        check(second.kind == .inhale && second.cycle == 1, "box starts cycle two at 16 s")
        check(Breath.state(at: 1.2, phases: box).countdown == 3, "countdown rounds up (2.8 s left reads 3)")
        check(Breath.state(at: 3.99, phases: box).countdown == 1, "countdown never reads 0")
        check(near(Breath.state(at: 2, phases: box).fullness, 0.5), "half way through the inhale is half full")
        check(near(Breath.state(at: 6, phases: box).fullness, 1), "full during the hold")
        check(near(Breath.state(at: 13, phases: box).fullness, 0), "empty during the empty hold")
        check(near(Breath.state(at: 10, phases: box).fullness, 0.5), "half way out is half empty")

        let relax = Patterns.phases(.relax)
        check(Breath.cycleLength(relax) == 19, "4-7-8 cycle is 19 s")
        let r = Breath.state(at: 10.9, phases: relax)
        check(r.kind == .holdFull && r.countdown == 1, "4-7-8 still holding at 10.9 s with 1 s left")
        check(Breath.state(at: 11, phases: relax).kind == .exhale, "4-7-8 exhales at 11 s")
        check(Breath.state(at: 19 * 3 + 6.3, phases: relax).countdown == 5, "4-7-8 hold countdown in the fourth breath")

        let coherent = Patterns.phases(.coherent)
        check(near(Breath.cycleLength(coherent), 11), "coherent cycle is 11 s")
        check(Breath.state(at: 5.6, phases: coherent).kind == .exhale, "coherent exhales after 5.5 s")
        check(near(60 / Breath.cycleLength(coherent), 5.4545, 0.001), "coherent is about 5.5 breaths a minute")

        let sigh = Patterns.phases(.sigh)
        check(sigh.map(\.kind) == [.inhale, .topUp, .exhale], "sigh is in, in again, out")
        check(near(Breath.state(at: 2, phases: sigh).fullness, 0.78), "sigh first inhale stops short of full")
        check(near(Breath.state(at: 3, phases: sigh).fullness, 1), "sigh top-up fills the lungs")
        check(Breath.state(at: 2.5, phases: sigh).kind.label == "In a little more", "sigh second inhale is labelled")

        let custom = Patterns.phases(.custom, custom: CustomRhythm(inhale: 0, holdFull: 0, exhale: 5, holdEmpty: 2))
        check(custom.map(\.kind) == [.inhale, .exhale, .holdEmpty], "custom drops zero holds")
        check(custom[0].seconds == 1, "custom inhale is at least one second")
        check(Patterns.summary(coherent) == "5.5 · 5.5", "summary shows half seconds")
        check(Patterns.summary(relax) == "4 · 7 · 8", "summary of 4-7-8")

        check(Breath.sessionLength(minutes: 5, phases: relax) == 304, "5 min of 4-7-8 runs 16 whole breaths")
        check(Breath.sessionLength(minutes: 1, phases: box) == 64, "1 min of box runs 4 whole breaths")
        check(near(Breath.sessionLength(minutes: 20, phases: coherent), 1210), "20 min of coherent is 110 breaths")
        check(Breath.clock(240.2) == "4:01" && Breath.clock(0) == "0:00" && Breath.clock(59.5) == "1:00", "clock formatting")

        // Phase changes across a whole session: one cue per phase, no doubles, no gaps.
        var cues = 0
        var last: (Int, Int)?
        for step in 0...(64 * 20) {
            let s = Breath.state(at: Double(step) * 0.05, phases: box)
            if last.map({ $0 != (s.cycle, s.phaseIndex) }) ?? true { cues += 1; last = (s.cycle, s.phaseIndex) }
        }
        check(cues == 17, "a 64 s box session sees 16 phases plus the first of the next breath at the end")

        // History.
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = TimeZone(identifier: "Europe/Athens")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 20))! // A Saturday.
        let day = { (d: Int, h: Int) in cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h))! }
        let sessions = [Session(date: day(7, 9), pattern: .box, seconds: 300, completed: true),
                        Session(date: day(6, 22), pattern: .relax, seconds: 90, completed: false),
                        Session(date: day(5, 8), pattern: .coherent, seconds: 600, completed: true),
                        Session(date: day(2, 8), pattern: .coherent, seconds: 600, completed: true),
                        Session(date: day(1, 8), pattern: .sigh, seconds: 600, completed: true)] // Last Sunday.
        let week = History.week(sessions, now: now, calendar: cal)
        check(week.count == 7 && cal.component(.weekday, from: week[0].day) == 2, "week runs Monday to Sunday")
        check(near(History.minutesThisWeek(sessions, now: now, calendar: cal), 26.5), "minutes this week skip last week")
        check(near(week[5].minutes, 5), "Saturday has five minutes")
        check(History.streak(sessions, now: now, calendar: cal) == 3, "three day streak")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("exhale-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try? JSONEncoder().encode(sessions)
        try? data?.write(to: url)
        let back = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Session].self, from: $0) }
        check(back == sessions, "history survives a JSON round trip")
        let settings = Settings(pattern: .custom, minutes: 12, sound: .tone, volume: 0.3, custom: CustomRhythm(inhale: 5))
        let settingsBack = (try? JSONEncoder().encode(settings)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
        check(settingsBack == settings, "settings survive a JSON round trip")

        check(History.streak([], now: now, calendar: cal) == 0, "no sessions is no streak")
        let lapsed = [Session(date: day(4, 9), pattern: .box, seconds: 300, completed: true)]
        check(History.streak(lapsed, now: now, calendar: cal) == 0, "a streak ends after a missed day")

        // Settings from disk are pulled back into range.
        let wild = Settings(pattern: .custom, minutes: 0, sound: .chime, volume: 7,
                            custom: CustomRhythm(inhale: -3, holdFull: 50, exhale: 0.4, holdEmpty: -1)).sanitized()
        check(wild.minutes == 1 && wild.volume == 1, "minutes and volume clamp into range")
        check(wild.custom == CustomRhythm(inhale: 1, holdFull: 12, exhale: 1, holdEmpty: 0), "custom rhythm clamps into range")
        check(Settings(minutes: 99).sanitized().minutes == 20, "a session is at most 20 minutes")
        check(Settings().sanitized() == Settings(), "default settings are already in range")

        // The session controller, driven with a simulated clock.
        MainActor.assumeIsolated {
            let model = ExhaleModel(persist: false)
            model.settings.sound = .off
            model.settings.pattern = .box
            model.settings.minutes = 1
            model.begin()
            check(model.runState == .running && model.sessionTotal == 64, "a one minute box session runs 64 s")
            model.simulate(elapsed: 64)
            check(model.runState == .finished, "the session finishes at its planned length")
            check(model.sessions.count == 1 && model.sessions[0].completed && model.sessions[0].seconds == 64,
                  "a finished session is recorded as completed")
            model.settings.pattern = .relax
            check(model.runState == .idle && model.phases == Patterns.phases(.relax),
                  "choosing a new pattern after a session shows the new plan")
            model.begin()
            model.simulate(elapsed: 20)
            model.stop()
            check(model.runState == .idle && model.sessions.count == 1, "a session stopped before 30 s is not saved")
            model.begin()
            model.simulate(elapsed: 45)
            model.stop()
            check(model.sessions.count == 2 && !model.sessions[0].completed && model.sessions[0].seconds == 45,
                  "a session stopped early keeps the time breathed")
            model.begin()
            check(model.elapsed(at: Date()) < 1, "a new session starts from zero")
            model.stop()
            model.clearHistory()
            check(model.sessions.isEmpty, "clear history empties the list")
        }

        // Synthesised cues: real audio, never clipping, silent at the edges.
        for style in [SoundStyle.chime, .tone] {
            for cue in Chimes.Cue.allCases {
                let s = Chimes.samples(cue, style)
                let peak = s.map { abs($0) }.max() ?? 0
                check(s.count > 40_000 && peak > 0.05 && peak < 0.5, "\(style) \(cue) has sound below clipping")
                check(abs(s.first ?? 1) < 0.01 && abs(s.last ?? 1) < 0.01, "\(style) \(cue) starts and ends quietly")
            }
        }
        check(Chimes.samples(.inhale, .off).isEmpty, "no sound is silent")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
