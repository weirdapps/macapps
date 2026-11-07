import Foundation

enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }
        func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

        // Pure sines at the two common sample rates, within one cent.
        for rate in [44100.0, 48000.0] {
            for f in [82.41, 110, 440, 1000] {
                let found = Pitch.detect(Pitch.sine(f, sampleRate: rate, count: 4096), sampleRate: rate)?.frequency ?? 0
                let error = found > 0 ? Music.cents(found, from: f) : .infinity
                check(abs(error) < 1, "sine \(f) Hz at \(Int(rate)) Hz read as \(found) (\(error) cents)")
            }
        }

        // Low bass E and high violin E.
        for f in [41.2, 659.26] {
            let found = Pitch.detect(Pitch.sine(f, sampleRate: 48000, count: 4096), sampleRate: 48000)?.frequency ?? 0
            check(found > 0 && abs(Music.cents(found, from: f)) < 1, "sine \(f) Hz read as \(found)")
        }

        // A plucked-string-like tone: strong overtones must not pull the reading up an octave.
        let harmonic: [Float] = (0..<4096).map { i in
            let t = Double(i) / 48000
            let parts = [(1, 0.4), (2, 0.8), (3, 0.5), (4, 0.3), (5, 0.2)]
            return Float(parts.reduce(0) { $0 + $1.1 * sin(2 * .pi * 110 * Double($1.0) * t + Double($1.0)) } * 0.3)
        }
        let rich = Pitch.detect(harmonic, sampleRate: 48000)?.frequency ?? 0
        check(rich > 0 && abs(Music.cents(rich, from: 110)) < 2, "harmonic tone at 110 Hz read as \(rich)")

        // A little noise still reads within a few cents.
        var seed: UInt64 = 42
        let noisy = Pitch.sine(196, sampleRate: 48000, count: 4096).map { s -> Float in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return s + Float(Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.05
        }
        let g = Pitch.detect(noisy, sampleRate: 48000)?.frequency ?? 0
        check(g > 0 && abs(Music.cents(g, from: 196)) < 3, "noisy 196 Hz read as \(g)")

        // Silence and white noise carry no pitch; the gate sees silence as very quiet.
        let silence = [Float](repeating: 0, count: 4096)
        check(Pitch.detect(silence, sampleRate: 48000) == nil, "silence has no pitch")
        check(Pitch.decibels(silence) <= -100, "silence is below the gate")
        let white: [Float] = (0..<4096).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(seed >> 40) / Double(1 << 24) - 0.5)
        }
        check(Pitch.detect(white, sampleRate: 48000) == nil, "white noise has no pitch")
        check(near(Pitch.decibels(Pitch.sine(440, sampleRate: 48000, count: 4800, amplitude: 1)), -3.01, 0.05),
              "full scale sine is -3 dBFS")

        // Note maths.
        check(near(Music.frequency(midi: 69, a4: 440), 440, 1e-9), "A4 is 440 Hz")
        check(near(Music.frequency(midi: 60, a4: 440), 261.6256, 0.001), "middle C")
        check(near(Music.frequency(midi: 40, a4: 440), 82.4069, 0.001), "low E")
        check(near(Music.frequency(midi: 69, a4: 432), 432, 1e-9), "A4 follows the reference")
        check(Music.label(69) == "A4" && Music.label(60) == "C4" && Music.label(28) == "E1" && Music.label(61) == "C♯4",
              "note labels")
        check(near(Music.cents(445, from: 440), 19.56, 0.01), "445 Hz is 19.56 cents sharp of 440")
        check(near(Music.cents(220, from: 440), -1200, 1e-9), "an octave is 1200 cents")
        check(Music.clampReference(425) == 430 && Music.clampReference(455) == 450 && Music.clampReference(441.6) == 442,
              "reference stays within 430 to 450")
        check(Music.centsText(-3.44) == "\u{2212}3.4" && Music.centsText(2) == "+2.0" && Music.centsText(-312) == "\u{2212}312",
              "cents text")
        check(Music.median([5, 1, 3, 100, 2]) == 3 && Music.median([1, 2, 3, 4]) == 2.5, "median")

        // Targets.
        check(Tuning.target(for: 440, instrument: .chromatic, a4: 440) == Target(midi: 69, string: nil), "chromatic A4")
        check(Tuning.target(for: 446, instrument: .chromatic, a4: 446) == Target(midi: 69, string: nil), "A4 at 446")
        check(Tuning.target(for: 452, instrument: .chromatic, a4: 440).midi == 69 &&
              Tuning.target(for: 454, instrument: .chromatic, a4: 440).midi == 70, "chromatic rounds to the nearest note")
        let held = Target(midi: 69, string: nil)
        check(Tuning.target(for: 454, instrument: .chromatic, a4: 440, previous: held) == held, "chromatic hysteresis")
        check(Tuning.target(for: 83, instrument: .guitar, a4: 440) == Target(midi: 40, string: 0), "guitar low E")
        check(Tuning.target(for: 150, instrument: .guitar, a4: 440) == Target(midi: 50, string: 2), "guitar D")
        check(Tuning.target(for: 320, instrument: .guitar, a4: 440) == Target(midi: 64, string: 5), "guitar high E")
        check(Tuning.target(for: 150, instrument: .guitar, a4: 440, locked: 1) == Target(midi: 45, string: 1), "locked string")
        check(Tuning.target(for: 42, instrument: .bass, a4: 440) == Target(midi: 28, string: 0), "bass E")
        check(Tuning.target(for: 390, instrument: .ukulele, a4: 440) == Target(midi: 67, string: 0), "ukulele G")
        check(Tuning.target(for: 262, instrument: .ukulele, a4: 440) == Target(midi: 60, string: 1), "ukulele C")
        check(Tuning.target(for: 660, instrument: .violin, a4: 440) == Target(midi: 76, string: 3), "violin E")
        check(Instrument.allCases.allSatisfy { $0 == .chromatic || $0.strings.count == $0.tuningName.split(separator: " ").count - 1 },
              "every preset names its strings")

        print("\(passed + failed) checks, \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
