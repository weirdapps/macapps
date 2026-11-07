import AVFoundation

// MARK: - Synthesis

/// The three click voices, made from sines and noise at the output's sample rate. Each lasts under 40 ms, so
/// even sixteenths at 300 BPM (50 ms apart) never overlap on the one player node.
enum Synth {
    static let duration = 0.038

    static func gain(_ level: TickLevel) -> Float {
        switch level {
        case .accent: 1.0
        case .group: 0.82
        case .beat: 0.7
        case .sub: 0.42
        }
    }

    /// Pitch of the voice per level, in hertz: accents sit higher, subdivisions lower.
    static func pitch(_ sound: Sound, _ level: TickLevel) -> Double {
        let base: Double = switch sound {
        case .click: 2000
        case .wood: 900
        case .beep: 880
        }
        let ratio: Double = switch level {
        case .accent: 1.5
        case .group: 1.26
        case .beat: 1
        case .sub: 0.84
        }
        return base * ratio
    }

    static func samples(_ sound: Sound, _ level: TickLevel, sampleRate: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        let f = pitch(sound, level)
        var noise = SplitMix(seed: UInt64(level.rawValue + 7))
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let v: Double
            switch sound {
            case .click:
                // A sharp transient over a fast decaying ping.
                let transient = noise.next() * exp(-t / 0.0012) * 0.6
                v = transient + sin(2 * .pi * f * t) * exp(-t / 0.005)
            case .wood:
                // Two inharmonic partials, like a struck wood block.
                let knock = noise.next() * exp(-t / 0.0008) * 0.35
                v = knock + sin(2 * .pi * f * t) * exp(-t / 0.011) + 0.45 * sin(2 * .pi * f * 2.76 * t) * exp(-t / 0.006)
            case .beep:
                // A soft edged tone with a touch of octave.
                let attack = min(t / 0.002, 1)
                let release = min((duration - t) / 0.008, 1)
                v = (sin(2 * .pi * f * t) + 0.18 * sin(4 * .pi * f * t)) * attack * release * 0.8
            }
            out[i] = Float(v)
        }
        // Normalise so the peak is exactly the level's gain, and end on silence.
        let peak = out.map(abs).max() ?? 1
        let scale = peak > 0 ? gain(level) / peak : 0
        let fade = min(64, count)
        for i in 0..<count {
            out[i] *= scale
            if i >= count - fade { out[i] *= Float(count - i) / Float(fade) }
        }
        return out
    }

    static func buffer(_ sound: Sound, _ level: TickLevel, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let data = samples(sound, level, sampleRate: format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(data.count)
        data.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: data.count) }
        return buffer
    }
}

/// A tiny deterministic noise source, so every click of a kind sounds the same.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53) * 2 - 1
    }
}

// MARK: - Engine

/// Plays the clicks: a `Scheduler` decides the sample frames, a timer on a private queue keeps about 120 ms
/// scheduled ahead on an `AVAudioPlayerNode`, and every buffer is placed at an exact sample time.
final class ClickEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.weirdapps.beat.audio", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let onAnchor: @Sendable (VisualAnchor?) -> Void
    private var timer: DispatchSourceTimer?
    private var scheduler: Scheduler?
    private var config = MeterConfig()
    private var sampleRate = 48_000.0
    private var buffers: [Sound: [TickLevel: AVAudioPCMBuffer]] = [:]
    private var observer: NSObjectProtocol?

    static let lookahead = 0.12
    static let leadIn = 0.1

    init(onAnchor: @escaping @Sendable (VisualAnchor?) -> Void) {
        self.onAnchor = onAnchor
        engine.attach(player)
        // A new output device stops the engine; start again on the new one.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { if self.scheduler != nil { self.begin() } }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start(_ config: MeterConfig) {
        queue.async {
            self.config = config
            self.begin()
        }
    }

    func stop() {
        queue.async { self.halt() }
    }

    func update(_ config: MeterConfig) {
        queue.async {
            self.config = config
            self.player.volume = Float(config.volume)
            guard var s = self.scheduler else { return }
            let now = self.nowFrame()
            if s.update(config, now: now) { self.onAnchor(s.anchor(at: Date(), nowFrame: now - self.latencyFrames)) }
            self.scheduler = s
            self.pump()
        }
    }

    private func begin() {
        halt()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if rate > 0 { sampleRate = rate }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return onAnchor(nil) }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        if buffers.isEmpty || buffers.values.first?.values.first?.format.sampleRate != sampleRate {
            buffers = [:]
            for sound in Sound.allCases {
                var voice: [TickLevel: AVAudioPCMBuffer] = [:]
                for level in TickLevel.allCases { voice[level] = Synth.buffer(sound, level, format: format) }
                buffers[sound] = voice
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return onAnchor(nil) }
        player.volume = Float(config.volume)
        player.play()
        let now = nowFrame()
        let s = Scheduler(config: config, sampleRate: sampleRate, startFrame: now + ClickEngine.leadIn * sampleRate)
        scheduler = s
        onAnchor(s.anchor(at: Date(), nowFrame: now - latencyFrames))
        pump()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(15), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func halt() {
        timer?.cancel()
        timer = nil
        scheduler = nil
        player.stop()
        engine.stop()
    }

    /// Schedules every click up to the lookahead horizon.
    private func pump() {
        guard var s = scheduler else { return }
        let horizon = nowFrame() + ClickEngine.lookahead * sampleRate
        for tick in s.ticks(through: horizon) {
            guard let buffer = buffers[config.sound]?[tick.level] else { continue }
            player.scheduleBuffer(buffer, at: AVAudioTime(sampleTime: tick.frame, atRate: sampleRate), options: [])
        }
        scheduler = s
    }

    /// The player's current position in sample frames; it starts at 0 when the player starts.
    private func nowFrame() -> Double {
        guard let render = player.lastRenderTime, render.isSampleTimeValid,
              let time = player.playerTime(forNodeTime: render) else { return 0 }
        return Double(time.sampleTime)
    }

    /// How far the sound reaches the speakers after it is rendered, so the visuals land with the ear.
    private var latencyFrames: Double { (engine.outputNode.presentationLatency) * sampleRate }
}
