import Foundation

// `Hum --selftest`: the generators, the mixer and the model logic, checked offline without touching audio hardware.

enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else {
            failures += 1
            print("FAIL: \(name) \(detail())")
        }
    }

    static func samples(_ sound: Sound, seconds: Double, rate: Double = 48_000, seed: UInt64 = 7) -> [Float] {
        var g = Generator(sound, sampleRate: rate, seed: seed, sharedSeed: seed &+ 1)
        return (0..<Int(seconds * rate)).map { _ in g.next() }
    }

    static func rms<C: Collection>(_ x: C) -> Float where C.Element == Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    /// In place radix 2 FFT.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            for start in stride(from: 0, to: n, by: len) {
                for k in 0..<len / 2 {
                    let wr = cos(ang * Double(k)), wi = sin(ang * Double(k))
                    let a = start + k, b = a + len / 2
                    let xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr
                    re[b] = re[a] - xr; im[b] = im[a] - xi
                    re[a] += xr; im[a] += xi
                }
            }
            len <<= 1
        }
    }

    /// Welch power spectrum density, then the least squares slope of band density in dB per octave.
    static func slope(_ x: [Float], rate: Double, from low: Double, octaves: Int) -> Double {
        let n = 4096
        var psd = [Double](repeating: 0, count: n / 2)
        let window = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n - 1)) }
        var segments = 0
        for start in stride(from: 0, to: x.count - n, by: n / 2) {
            var re = (0..<n).map { Double(x[start + $0]) * window[$0] }
            var im = [Double](repeating: 0, count: n)
            fft(&re, &im)
            for k in 0..<n / 2 { psd[k] += re[k] * re[k] + im[k] * im[k] }
            segments += 1
        }
        let binHz = rate / Double(n)
        var xs: [Double] = [], ys: [Double] = []
        for o in 0..<octaves {
            let lo = low * pow(2, Double(o)), hi = lo * 2
            let bins = Int(lo / binHz)..<Int(hi / binHz)
            let mean = bins.map { psd[$0] }.reduce(0, +) / Double(bins.count) / Double(segments)
            xs.append(Double(o))
            ys.append(10 * log10(mean))
        }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let den = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        return num / den
    }

    static func run() -> Int32 {
        let rate = 48_000.0

        // Every generator: finite, bounded, at a comparable loudness.
        for sound in Sound.allCases {
            let x = samples(sound, seconds: 20, rate: rate)
            check(x.allSatisfy(\.isFinite), "\(sound.name) produces no NaN or infinity")
            let peak = x.map(abs).max() ?? 0
            check(peak < 1.6, "\(sound.name) peak is bounded", "peak \(peak)")
            let level = rms(x[...])
            print(String(format: "info: %@ rms %.3f peak %.3f", sound.name, level, peak))
            check(level > 0.1 && level < 0.3, "\(sound.name) loudness is comparable", "rms \(level)")
            let dc = x.reduce(0, +) / Float(x.count)
            check(abs(dc) < 0.03, "\(sound.name) has no DC offset", "mean \(dc)")
        }

        // Spectral slopes.
        let pink = slope(samples(.pink, seconds: 12, rate: rate), rate: rate, from: 50, octaves: 8)
        print(String(format: "info: pink slope %.2f dB/octave", pink))
        check(abs(pink + 3) < 0.6, "pink noise falls about 3 dB per octave", "\(pink)")
        let pink44 = slope(samples(.pink, seconds: 12, rate: 44_100), rate: 44_100, from: 50, octaves: 8)
        check(abs(pink44 + 3) < 0.6, "pink noise slope holds at 44.1 kHz", "\(pink44)")
        let white = slope(samples(.white, seconds: 8, rate: rate), rate: rate, from: 50, octaves: 8)
        check(abs(white) < 0.5, "white noise is flat", "\(white)")
        let brown = slope(samples(.brown, seconds: 12, rate: rate), rate: rate, from: 100, octaves: 6)
        print(String(format: "info: brown slope %.2f dB/octave", brown))
        check(abs(brown + 6) < 0.8, "brown noise falls about 6 dB per octave", "\(brown)")
        let fanSlope = slope(samples(.fan, seconds: 8, rate: rate), rate: rate, from: 1000, octaves: 3)
        check(fanSlope < -6, "fan is dark above 1 kHz", "\(fanSlope)")

        // Rain has drops at a believable rate.
        var rainGen = Generator(.rain, sampleRate: rate, seed: 3, sharedSeed: 4)
        for _ in 0..<Int(rate * 10) { _ = rainGen.next() }
        check(rainGen.drops > 150 && rainGen.drops < 900, "rain drops fall 15 to 90 times a second", "\(rainGen.drops) in 10 s")

        // Waves swell: loud and quiet half seconds differ clearly.
        let waves = samples(.waves, seconds: 30, rate: rate)
        let chunk = Int(rate / 2)
        let levels = stride(from: 0, to: waves.count - chunk, by: chunk).map { rms(waves[$0..<($0 + chunk)]) }
        let ratio = (levels.max() ?? 0) / max(levels.min() ?? 1, 0.0001)
        check(ratio > 2.5, "ocean waves swell and recede", "loud/quiet \(ratio)")

        // Same seed, same sound; different seed, different sound.
        check(samples(.rain, seconds: 0.1, seed: 9) == samples(.rain, seconds: 0.1, seed: 9), "generators are deterministic")
        check(samples(.pink, seconds: 0.1, seed: 9) != samples(.pink, seconds: 0.1, seed: 10), "seeds give different noise")

        // The mixer.
        let frames = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames), right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        let core = RenderCore(sampleRate: rate)
        for s in Sound.allCases { core.setVolume(1, for: s) }
        core.setMaster(1)
        core.render(frames: frames, left: left, right: right)
        check((0..<frames).allSatisfy { left[$0] == 0 && right[$0] == 0 }, "silent before the fade in starts")

        core.fade(to: 1, over: 0.5)
        var outPeak: Float = 0, firstPeak: Float = 0, allFinite = true, maxJump: Float = 0, previous: Float = 0
        for block in 0..<Int(rate * 3) / frames {
            core.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                allFinite = allFinite && left[i].isFinite && right[i].isFinite
                outPeak = max(outPeak, abs(left[i]), abs(right[i]))
                if block == 0 { firstPeak = max(firstPeak, abs(left[i]), abs(right[i])) }
                if block < 4 { maxJump = max(maxJump, abs(left[i] - previous)) }
                previous = left[i]
            }
        }
        check(allFinite, "full mix produces no NaN")
        check(outPeak < 1, "full mix of all six stays below full scale", "peak \(outPeak)")
        check(firstPeak < 0.01, "fade in starts from silence, no click", "first block peak \(firstPeak)")
        check(maxJump < 0.05, "fade in has no sample jumps", "\(maxJump)")
        check(abs(core.currentFade - 1) < 0.0001, "fade in reaches full level", "\(core.currentFade)")
        check(core.level > 0.05, "level meter reports the output", "\(core.level)")

        core.fade(to: 0, over: 0.25)
        for _ in 0..<Int(rate * 0.3) / frames { core.render(frames: frames, left: left, right: right) }
        core.render(frames: frames, left: left, right: right)
        check((0..<frames).allSatisfy { left[$0] == 0 }, "fade out ends in exact silence")
        check(core.level == 0, "level meter reads zero when silent")

        // Turning one sound off while playing ramps it out smoothly.
        let solo = RenderCore(sampleRate: rate)
        solo.setVolume(0.8, for: .brown)
        solo.setMaster(1)
        solo.fade(to: 1, over: 0.01)
        for _ in 0..<200 { solo.render(frames: frames, left: left, right: right) }
        let before = rms(UnsafeBufferPointer(start: left, count: frames)[...])
        solo.setVolume(0, for: .brown)
        solo.render(frames: frames, left: left, right: right)
        let after = rms(UnsafeBufferPointer(start: left, count: 48)[...])
        for _ in 0..<60 { solo.render(frames: frames, left: left, right: right) }
        check(after > before * 0.6, "muting ramps the sound out instead of cutting it", "\(after) after vs \(before) before")
        check(solo.level < 0.0001, "a muted sound goes quiet", "\(solo.level)")

        check(softClip(0.5) == 0.5 && softClip(-0.3) == -0.3, "soft clip is transparent at normal levels")
        check(softClip(50) < 1 && softClip(-50) > -1 && softClip(0.9) > 0.8, "soft clip bounds and stays monotonic")

        // Model logic.
        modelChecks()

        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    static func modelChecks() {
        let mix = Mix(name: "Test", volumes: [.pink: 0.4, .rain: 0.7])
        let data = try? JSONEncoder().encode([mix])
        let back = data.flatMap { try? JSONDecoder().decode([Mix].self, from: $0) }
        check(back == [mix], "saved mixes survive a JSON round trip")
        check(mix.volume(.rain) == 0.7 && mix.volume(.fan) == 0, "a mix reads missing sounds as off")
        check(mix.summary == "Rain, Pink", "mix summary lists the loudest first", mix.summary)
        check(mix.matches(mix.vector) && !mix.matches(Mix(name: "x", volumes: [.pink: 0.4]).vector), "mix matching")
        check(Mix.presets.count >= 4 && Set(Mix.presets.map(\.id)).count == Mix.presets.count, "presets have unique ids")

        let state = SavedState(volumes: [0.1, 0.2, 0, 0, 0.5, 0], master: 0.6, mixes: [mix], sleepMinutes: 30)
        let stateBack = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check(stateBack == state, "app state survives a JSON round trip")

        check(Sleep.fadeWindow(total: 30 * 60) == 180, "a long sleep timer fades over its last 3 minutes")
        check(Sleep.fadeWindow(total: 120) == 60, "a short sleep timer fades over its second half")
        check(Sleep.format(23 * 60 + 41) == "23:41" && Sleep.format(65 * 60) == "1:05:00" && Sleep.format(9) == "0:09",
              "remaining time formats like a clock")
        check(Sleep.label(minutes: 90) == "1 h 30 min" && Sleep.label(minutes: 45) == "45 min" && Sleep.label(minutes: 120) == "2 h",
              "sleep timer labels")
        check(Level.decibels(1) == 0 && Level.decibels(0) == -60 && abs(Level.decibels(0.1) + 20) < 0.001, "level in decibels")
        check(Level.meter(-60) == 0 && Level.meter(0) == 1 && Level.meter(-30) == 0.5, "meter scale")
        MainActor.assumeIsolated {
            let model = HumModel(demo: true)
            model.volumes = [0, 0.5, 0, 0, 0, 0]
            model.toggle(.pink)
            check(model.volumes[1] == 0, "clicking an active sound mutes it")
            model.toggle(.pink)
            check(model.volumes[1] == 0.5, "clicking it again restores its volume")
            model.toggle(.fan)
            check(model.volumes[5] == Mix.defaultVolume, "a sound never used starts at a sensible volume")
            model.apply(Mix.presets[0])
            check(model.matchingMix?.id == Mix.presets[0].id, "applying a mix makes it the current one")
            model.adjustMaster(by: 0.5)
            check(model.master == 1, "master volume clamps at full")
            model.adjustMaster(by: -5)
            check(model.master == 0, "master volume clamps at silence")

            // A saved mix with the same volumes as a preset is titled by its own name once selected.
            let twin = HumModel(demo: true)
            twin.apply(Mix.presets[1])
            twin.saveCurrent(as: "  Storm  ", undo: nil)
            check(twin.title == "Storm", "a saved twin of a preset shows its own name", twin.title)
            check(twin.mixes.first?.name == "Storm", "mix names are trimmed")
            twin.saveCurrent(as: "   ", undo: nil)
            check(twin.mixes.last?.name == "Mix 2", "a blank name falls back to the next free name", twin.mixes.last?.name ?? "")

            // Update with Current Sounds can be undone and redone.
            let undo = UndoManager()
            undo.groupsByEvent = false
            let editing = HumModel(demo: true)
            editing.apply(Mix(name: "A", volumes: [.fan: 0.5]))
            editing.saveCurrent(as: "Fan Only", undo: nil)
            let saved = editing.mixes[0]
            editing.setVolume(0.9, for: .rain)
            undo.beginUndoGrouping()
            editing.update(saved, undo: undo)
            undo.endUndoGrouping()
            check(editing.mixes[0].volume(.rain) == 0.9 && editing.mixes[0].name == "Fan Only", "update keeps the name and takes the new volumes")
            undo.undo()
            check(editing.mixes[0].volume(.rain) == 0 && editing.mixes[0].volume(.fan) == 0.5, "undo restores the old volumes")
            undo.redo()
            check(editing.mixes[0].volume(.rain) == 0.9, "redo applies the update again")
            editing.clearMix()
            editing.update(editing.mixes[0], undo: nil)
            check(editing.mixes[0].volume(.fan) == 0.5, "updating with every sound off is refused, so a mix never turns silent")

            // The sleep timer is one shot: when it runs out it stops and goes back to Off.
            let sleeper = HumModel.demo
            check(sleeper.sleepMinutes == 30 && sleeper.isPlaying, "demo starts with a running sleep timer")
            sleeper.finishSleep()
            check(!sleeper.isPlaying && sleeper.sleepMinutes == nil && sleeper.sleepRemaining == nil, "a finished sleep timer stops and resets to Off")
        }

        // A damaged or hand edited state file loads safely.
        let bad = SavedState(volumes: [2, -1, .nan, 0.5, 0, 0], master: 7,
                             mixes: [Mix(id: Mix.presets[0].id, name: "Clash", volumes: [.pink: 0.3]), Mix(name: "Empty", volumes: [:]),
                                     Mix(name: "Loud", volumes: [.rain: 4]), Mix(name: "Unicode \u{1F327}\u{FE0F} Ünïcødé", volumes: [.waves: 0.4])],
                             sleepMinutes: 45)
        let clean = bad.sanitized()
        check(clean.volumes == [1, 0, 0, 0.5, 0, 0] && clean.master == 1, "loaded volumes are clamped to 0...1", "\(clean.volumes) \(clean.master)")
        check(clean.mixes.map(\.name) == ["Loud", "Unicode \u{1F327}\u{FE0F} Ünïcødé"], "silent mixes and ids that clash with presets are dropped",
              clean.mixes.map(\.name).joined(separator: ","))
        check(clean.mixes.first?.volume(.rain) == 1, "a saved mix louder than full is clamped")
        check(clean.sleepMinutes == nil, "the sleep timer never comes back after a relaunch")
        check(SavedState(volumes: [0.5], master: 0.5, mixes: [], sleepMinutes: nil).sanitized().volumes.count == Sound.allCases.count,
              "a state from a build with a different sound count still loads")
    }
}
