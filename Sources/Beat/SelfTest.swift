import Foundation

/// `Beat --selftest`: the scheduling maths, tap tempo, synthesis and persistence.
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

    private static func frames(_ ticks: [ScheduledTick]) -> [Int64] { ticks.map(\.frame) }

    static func run() -> Int32 {
        // Beat spacing.
        check(BeatClock.framesPerBeat(bpm: 120, sampleRate: 48_000) == 24_000, "120 BPM at 48 kHz is 24000 frames a beat")
        check(BeatClock.framesPerBeat(bpm: 60, sampleRate: 44_100) == 44_100, "60 BPM at 44.1 kHz is one second a beat")
        let clock = BeatClock(anchorBeat: 0, anchorFrame: 0, framesPerBeat: BeatClock.framesPerBeat(bpm: 120, sampleRate: 48_000))
        check(clock.frame(ofBeat: 10_000) == 240_000_000, "beat 10000 lands exactly, with no drift")

        // Quarter notes at 120 BPM from frame 4800.
        var s = Scheduler(config: MeterConfig(bpm: 120), sampleRate: 48_000, startFrame: 4_800)
        let first = s.ticks(through: 4_800 + 48_000 * 2)
        check(frames(first) == [4_800, 28_800, 52_800, 76_800], "quarters at 120 BPM are 24000 frames apart")
        check(first.map(\.level) == [.accent, .beat, .beat, .beat], "beat one carries the accent in 4/4")
        check(s.ticks(through: 4_800 + 48_000 * 2).isEmpty, "a click is handed out only once")
        let next = s.ticks(through: 4_800 + 48_000 * 2 + 1)
        check(next.first?.frame == 100_800 && next.first?.level == .accent, "the next bar starts with an accent")

        // Subdivisions are exact fractions of the beat.
        var sixteenths = Scheduler(config: MeterConfig(bpm: 120, subdivision: .sixteenths), sampleRate: 48_000, startFrame: 0)
        check(frames(sixteenths.ticks(through: 24_000)) == [0, 6_000, 12_000, 18_000], "sixteenths split the beat in four")
        var triplets = Scheduler(config: MeterConfig(bpm: 100, subdivision: .triplets), sampleRate: 44_100, startFrame: 0)
        let trip = triplets.ticks(through: 26_460)
        check(frames(trip) == [0, 8_820, 17_640], "triplets at 100 BPM split 26460 frames in three")
        check(trip.map(\.level) == [.accent, .sub, .sub], "subdivision clicks are quieter than beats")

        // A tempo that does not divide the sample rate never drifts more than half a frame.
        var odd = Scheduler(config: MeterConfig(bpm: 137), sampleRate: 44_100, startFrame: 0)
        let many = odd.ticks(through: 44_100 * 600 - 1)
        let spacing = 44_100.0 * 60 / 137
        check(many.count == 1_370, "ten minutes at 137 BPM has the right number of beats")
        check(many.enumerated().allSatisfy { abs(Double($1.frame) - Double($0) * spacing) <= 0.5 }, "every beat is within half a frame")

        // A tempo change lands on the next beat, spaced at the new tempo.
        var change = Scheduler(config: MeterConfig(bpm: 120), sampleRate: 48_000, startFrame: 0)
        _ = change.ticks(through: 30_000) // Beats 0 and 1 (0 and 24000).
        var faster = change.config
        faster.bpm = 240
        check(change.update(faster, now: 26_000), "a tempo change moves the beat grid")
        let after = change.ticks(through: 60_000)
        check(frames(after) == [36_000, 48_000], "after 120 to 240 BPM the next beats come 12000 frames apart")
        var slower = change.config
        slower.bpm = 30
        _ = change.update(slower, now: 50_000)
        check(change.ticks(through: 48_000 + 96_000 + 1).last?.frame == 144_000, "slowing to 30 BPM spaces beats 96000 frames")

        // A big jump in tempo never schedules a beat in the past.
        var jump = Scheduler(config: MeterConfig(bpm: 30), sampleRate: 48_000, startFrame: 0)
        _ = jump.ticks(through: 1)
        var quick = jump.config
        quick.bpm = 300
        _ = jump.update(quick, now: 40_000)
        check((jump.ticks(through: 100_000).first?.frame ?? 0) >= 40_000, "the first beat after a jump is not in the past")

        // A faster tempo cuts the rest of a subdivided beat short instead of overlapping the next beat.
        var cut = Scheduler(config: MeterConfig(bpm: 60, subdivision: .sixteenths), sampleRate: 48_000, startFrame: 0)
        _ = cut.ticks(through: 1_000) // The first click of beat 0.
        var cutFaster = cut.config
        cutFaster.bpm = 240
        _ = cut.update(cutFaster, now: 1_000)
        let cutTicks = cut.ticks(through: 30_000)
        check(cutTicks.first?.frame == 12_000 && cutTicks.first?.sub == 0, "remaining sixteenths after the new beat are dropped")

        // Signatures and accents.
        var six = Scheduler(config: MeterConfig(bpm: 120, signature: .sixEight), sampleRate: 48_000, startFrame: 0)
        check(six.ticks(through: 6 * 24_000).map(\.level) == [.accent, .beat, .beat, .group, .beat, .beat], "6/8 groups in two threes")
        var seven = Scheduler(config: MeterConfig(bpm: 120, signature: .sevenEight), sampleRate: 48_000, startFrame: 0)
        check(seven.ticks(through: 7 * 24_000).map(\.level) == [.accent, .beat, .group, .beat, .group, .beat, .beat],
              "7/8 groups as two, two, three")
        var plain = Scheduler(config: MeterConfig(bpm: 120, accent: false), sampleRate: 48_000, startFrame: 0)
        check(plain.ticks(through: 4 * 24_000).allSatisfy { $0.level == .beat }, "with the accent off every beat is equal")
        var meter = Scheduler(config: MeterConfig(bpm: 120), sampleRate: 48_000, startFrame: 0)
        _ = meter.ticks(through: 30_000) // Beats 0 and 1 of 4/4.
        var waltz = meter.config
        waltz.signature = .threeFour
        _ = meter.update(waltz, now: 30_000)
        check(meter.ticks(through: 48_001).first?.level == .accent, "a new signature starts a fresh bar on the next beat")
        check(TimeSignature.allCases.map(\.beats) == [2, 3, 4, 5, 6, 7], "six signatures with their beat counts")

        // Visual anchor and phase.
        var vis = Scheduler(config: MeterConfig(bpm: 120, subdivision: .eighths), sampleRate: 48_000, startFrame: 4_800)
        let anchor = vis.anchor(at: Date(timeIntervalSinceReferenceDate: 100), nowFrame: 0)
        check(abs(anchor.time - 100.1) < 1e-9 && anchor.secondsPerBeat == 0.5, "the anchor maps the first beat to wall clock time")
        _ = vis.ticks(through: 4_801)
        check(vis.anchor(at: .now, nowFrame: 0).beat == 1, "after a beat starts the anchor points at the next one")
        let phase = BeatPhase(position: anchor.position(at: 100.1 + 0.5 * 5.75), barStart: 0, beats: 4, ticks: 2)
        check(phase.beatInBar == 1 && phase.tick == 1 && abs(phase.fraction - 0.75) < 1e-9, "phase finds beat, click and fraction")
        check(BeatPhase(position: -0.5, barStart: 0, beats: 4, ticks: 1).beatInBar == 3, "phase wraps before the bar")

        // Tap tempo.
        var tap = TapTempo()
        check(tap.tap(at: 10) == nil, "one tap is not a tempo")
        check(tap.tap(at: 10.5) == 120, "two taps half a second apart are 120 BPM")
        _ = tap.tap(at: 11.0)
        check(tap.tap(at: 11.62) == 111, "taps are averaged: 1.62 s over three intervals is 111 BPM")
        check(tap.tap(at: 20) == nil, "a long pause starts the taps over")
        var window = TapTempo()
        for i in 0..<20 { _ = window.tap(at: Double(i) * 0.4) }
        check(window.taps.count == TapTempo.window && window.bpm == 150, "only the last few taps count")
        var extreme = TapTempo()
        _ = extreme.tap(at: 0)
        check(extreme.tap(at: 0.05) == 300, "very fast taps clamp to 300 BPM")
        check(Tempo.clamp(12) == 30 && Tempo.clamp(999) == 300, "tempo stays within 30 to 300")

        // Markings.
        check(Tempo.marking(60) == "Larghetto" && Tempo.marking(120) == "Allegro" && Tempo.marking(300) == "Prestissimo",
              "Italian tempo markings")

        // Synthesis.
        for sound in Sound.allCases {
            let accent = Synth.samples(sound, .accent, sampleRate: 48_000)
            let sub = Synth.samples(sound, .sub, sampleRate: 48_000)
            let peakA = accent.map(abs).max() ?? 0, peakS = sub.map(abs).max() ?? 0
            check(accent.count == Int(Synth.duration * 48_000) && abs(peakA - 1) < 1e-4 && peakS < peakA,
                  "\(sound.label) is normalised and accents are louder")
            check(abs(accent.last ?? 1) < 1e-3, "\(sound.label) ends on silence")
            check(Double(accent.count) / 48_000 < 60.0 / 300 / 4, "\(sound.label) is shorter than a sixteenth at 300 BPM")
        }
        check(Synth.samples(.wood, .beat, sampleRate: 44_100) == Synth.samples(.wood, .beat, sampleRate: 44_100),
              "the same click sounds the same every time")

        // Presets and persistence.
        let custom = MeterConfig(bpm: 88, signature: .fiveFour, subdivision: .triplets, sound: .beep, accent: false, volume: 0.3)
        let preset = Preset(name: "Test", config: custom)
        check(preset.applied(to: MeterConfig()).volume == MeterConfig().volume && preset.matches(custom),
              "presets carry the meter but keep the volume")
        let state = SavedState(config: custom, presets: [preset] + Preset.starters)
        let data = try? JSONEncoder().encode(state)
        let back = data.flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check(back == state, "saved state survives a JSON round trip")
        check(Preset.starters.allSatisfy { Tempo.range.contains($0.bpm) }, "starter presets are in range")

        print(failures == 0 ? "PASS: \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
