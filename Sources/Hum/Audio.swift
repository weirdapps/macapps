import AVFoundation
import Foundation

// The sounds, their generators and the real time mixer. Everything here is allocation free on the audio thread.

enum Sound: String, CaseIterable, Codable, Identifiable {
    case white, pink, brown, rain, waves, fan

    var id: String { rawValue }

    var name: String {
        switch self {
        case .white: "White Noise"
        case .pink: "Pink Noise"
        case .brown: "Brown Noise"
        case .rain: "Rain"
        case .waves: "Ocean Waves"
        case .fan: "Fan"
        }
    }

    var shortName: String {
        switch self {
        case .white: "White"
        case .pink: "Pink"
        case .brown: "Brown"
        case .rain: "Rain"
        case .waves: "Waves"
        case .fan: "Fan"
        }
    }

    var blurb: String {
        switch self {
        case .white: "Bright, even hiss"
        case .pink: "Balanced, like wind"
        case .brown: "Deep, soft rumble"
        case .rain: "Patter on a quiet roof"
        case .waves: "Slow swells and surf"
        case .fan: "A gentle electric hum"
        }
    }

    var symbol: String {
        switch self {
        case .white: "waveform.path"
        case .pink: "aqi.medium"
        case .brown: "aqi.low"
        case .rain: "cloud.rain.fill"
        case .waves: "water.waves"
        case .fan: "fan.fill"
        }
    }

    var index: Int { Sound.allCases.firstIndex(of: self)! }
}

/// xorshift64*: fast, deterministic, good enough for audio noise.
struct RNG {
    var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 0x2545_F491_4F6C_DD1D
    }

    /// Uniform in [-1, 1).
    mutating func white() -> Float { Float(Int64(bitPattern: next()) >> 40) / 8_388_608 }

    /// Uniform in (0, 1].
    mutating func unit() -> Float { (Float(next() >> 40) + 1) / 16_777_216 }
}

/// One-pole low pass.
struct OnePole {
    var a: Float
    var y: Float = 0

    init(cutoff: Float, sampleRate: Float) { a = 1 - exp(-2 * .pi * cutoff / sampleRate) }

    mutating func setCutoff(_ cutoff: Float, sampleRate: Float) { a = 1 - exp(-2 * .pi * cutoff / sampleRate) }

    mutating func low(_ x: Float) -> Float { y += a * (x - y); return y }

    mutating func high(_ x: Float) -> Float { x - low(x) }
}

/// Paul Kellet's refined pink filter: within 0.05 dB of -3 dB per octave above 9 Hz.
struct PinkFilter {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0

    mutating func process(_ w: Float) -> Float {
        b0 = 0.99886 * b0 + w * 0.0555179
        b1 = 0.99332 * b1 + w * 0.0750759
        b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856
        b4 = 0.55000 * b4 + w * 0.5329522
        b5 = -0.7616 * b5 - w * 0.0168980
        let out = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362
        b6 = w * 0.115926
        return out * 0.11
    }
}

/// Leaky integrator of white noise: -6 dB per octave above about 20 Hz.
struct BrownFilter {
    var leak: Float
    var y: Float = 0

    init(sampleRate: Float) { leak = exp(-2 * .pi * 20 / sampleRate) }

    mutating func process(_ w: Float) -> Float {
        y = leak * y + w * 0.04
        return y
    }
}

/// RBJ band pass with 0 dB peak gain.
struct BandPass {
    var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func tune(_ freq: Float, q: Float, sampleRate: Float) {
        let w0 = 2 * Float.pi * freq / sampleRate
        let alpha = sin(w0) / (2 * q), a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// One channel of one sound. `noise` differs per channel for width; `slow` is shared so swells stay coherent.
struct Generator {
    let sound: Sound
    let fs: Float
    var noise: RNG
    var slow: RNG
    var pink = PinkFilter()
    var brown: BrownFilter
    var f1: OnePole
    var f2: OnePole
    var f3: OnePole
    // Rain.
    var drop = BandPass()
    var dropEnv: Float = 0
    var dropDecay: Float = 0
    var countdown: Int = 0
    var intensity: Float = 0.5
    var intensityTarget: Float = 0.5
    var intensityCountdown = 0
    private(set) var drops = 0
    // Waves.
    var phase: Float = 0
    var period: Float = 9
    // Fan.
    var humPhase: Float = 0
    var bladePhase: Float = 0

    init(_ sound: Sound, sampleRate: Double, seed: UInt64, sharedSeed: UInt64) {
        self.sound = sound
        fs = Float(sampleRate)
        noise = RNG(seed: seed)
        slow = RNG(seed: sharedSeed)
        brown = BrownFilter(sampleRate: fs)
        switch sound {
        case .rain:
            f1 = OnePole(cutoff: 450, sampleRate: fs)
            f2 = OnePole(cutoff: 7000, sampleRate: fs)
        case .waves:
            f1 = OnePole(cutoff: 600, sampleRate: fs)
            f2 = OnePole(cutoff: 600, sampleRate: fs)
        case .fan:
            f1 = OnePole(cutoff: 700, sampleRate: fs)
            f2 = OnePole(cutoff: 900, sampleRate: fs)
        default:
            f1 = OnePole(cutoff: 1000, sampleRate: fs)
            f2 = OnePole(cutoff: 1000, sampleRate: fs)
        }
        f3 = OnePole(cutoff: 30, sampleRate: fs)
        phase = slow.unit() * 0.6
        period = 7 + slow.unit() * 6
        countdown = Int(fs * 0.01)
    }

    /// The next sample, with a long term RMS near 0.18.
    mutating func next() -> Float {
        let w = noise.white()
        switch sound {
        case .white:
            return w * 0.31
        case .pink:
            return pink.process(w) * 0.85
        case .brown:
            return brown.process(w) * 0.57
        case .rain:
            return rain(w)
        case .waves:
            return waves(w)
        case .fan:
            return fan(w)
        }
    }

    private mutating func rain(_ w: Float) -> Float {
        // The bed: pink noise without its low end, softened at the top.
        let bed = f2.low(f1.high(pink.process(w)))
        // Intensity wanders every few seconds, so the shower breathes.
        intensityCountdown -= 1
        if intensityCountdown <= 0 {
            intensityTarget = 0.3 + slow.unit() * 0.7
            intensityCountdown = Int(fs * (2 + slow.unit() * 4))
        }
        intensity += (intensityTarget - intensity) * 0.00002
        // Drops: a Poisson stream of short resonant ticks.
        countdown -= 1
        if countdown <= 0 {
            let rate = 18 + 60 * intensity
            countdown = max(1, Int(-log(noise.unit()) / rate * fs))
            let a = noise.unit()
            dropEnv = min(1.1, dropEnv + 0.15 + a * a * 0.85)
            dropDecay = exp(-1 / (fs * (0.004 + noise.unit() * 0.02)))
            drop.tune(1200 + noise.unit() * 4200, q: 3 + noise.unit() * 5, sampleRate: fs)
            drops += 1
        }
        dropEnv *= dropDecay
        let tick = drop.process(noise.white()) * dropEnv
        return bed * (1.1 + intensity * 0.6) + tick * 0.9
    }

    private mutating func waves(_ w: Float) -> Float {
        phase += 1 / (period * fs)
        if phase >= 1 {
            phase -= 1
            period = 7 + slow.unit() * 6
        }
        // A swell rises slowly, breaks at about 55 percent, then drains away.
        let rise = smoothstep(0, 0.55, phase)
        let fall = 1 - smoothstep(0.55, 1, phase)
        let swell = rise * fall * fall.squareRoot()
        let level = 0.22 + 0.78 * swell
        f2.setCutoff(250 + 2600 * swell * swell, sampleRate: fs)
        let body = brown.process(w) * 0.6
        let foam = f2.low(pink.process(noise.white())) * swell
        return (body + foam * 1.1) * level
    }

    private mutating func fan(_ w: Float) -> Float {
        let air = f2.low(f1.low(pink.process(w))) * 1.2 + brown.process(noise.white()) * 0.2
        humPhase += 100 / fs
        if humPhase >= 1 { humPhase -= 1 }
        bladePhase += 7.5 / fs
        if bladePhase >= 1 { bladePhase -= 1 }
        let hum = sin(2 * .pi * humPhase) * 0.035 + sin(4 * .pi * humPhase) * 0.018
        let blades = 1 + 0.12 * sin(2 * .pi * bladePhase)
        return air * blades + hum
    }

    private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Keeps peaks below 1 without touching normal levels: transparent up to 0.8, then a tanh knee.
@inline(__always) func softClip(_ x: Float) -> Float {
    let m = abs(x)
    if m <= 0.8 { return x }
    let y = 0.8 + 0.199 * tanh((m - 0.8) / 0.2)
    return x < 0 ? -y : y
}

/// The mixer the audio thread runs. The main thread writes targets into `params`; the render loop smooths them.
final class RenderCore {
    enum Param {
        static let master = Sound.allCases.count
        static let fadeTarget = master + 1
        static let fadeStep = master + 2
        static let level = master + 3
        static let fade = master + 4
        static let count = master + 5
    }

    let sampleRate: Double
    let params: UnsafeMutablePointer<Float>
    private let gens: UnsafeMutablePointer<Generator>
    private let gains: UnsafeMutablePointer<Float>
    private var master: Float = 0
    private var fade: Float = 0
    private let smoothing: Float
    private let voices = Sound.allCases.count

    init(sampleRate: Double, seed: UInt64 = 0x48_75_6D) {
        self.sampleRate = sampleRate
        params = .allocate(capacity: Param.count)
        params.initialize(repeating: 0, count: Param.count)
        gains = .allocate(capacity: voices)
        gains.initialize(repeating: 0, count: voices)
        gens = .allocate(capacity: voices * 2)
        for (i, sound) in Sound.allCases.enumerated() {
            let shared = seed &+ UInt64(i) &* 7919
            (gens + 2 * i).initialize(to: Generator(sound, sampleRate: sampleRate, seed: seed &+ UInt64(i * 2 + 1) &* 104_729, sharedSeed: shared))
            (gens + 2 * i + 1).initialize(to: Generator(sound, sampleRate: sampleRate, seed: seed &+ UInt64(i * 2 + 2) &* 104_729, sharedSeed: shared))
        }
        smoothing = 1 - exp(-1 / Float(sampleRate * 0.05))
    }

    deinit {
        params.deallocate()
        gains.deallocate()
        gens.deinitialize(count: voices * 2)
        gens.deallocate()
    }

    /// Slider positions (0 to 1) map to amplitude by their square, which feels even to the ear.
    func setVolume(_ volume: Double, for sound: Sound) { params[sound.index] = Float(max(0, min(1, volume))) }
    func setMaster(_ volume: Double) { params[Param.master] = Float(max(0, min(1, volume))) }

    /// Ramps the overall fade towards `target` (0 or 1) over `seconds`, from wherever it is now.
    func fade(to target: Float, over seconds: Double) {
        let distance = max(abs(target - params[Param.fade]), 0.001)
        params[Param.fadeStep] = distance / Float(max(seconds, 0.01) * sampleRate)
        params[Param.fadeTarget] = target
    }

    var level: Float { params[Param.level] }
    var currentFade: Float { params[Param.fade] }

    func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let p = params
        let target = p[Param.fadeTarget], step = p[Param.fadeStep]
        let masterTarget = p[Param.master] * p[Param.master]
        var energy: Float = 0
        for f in 0..<frames {
            if fade < target { fade = min(target, fade + step) } else if fade > target { fade = max(target, fade - step) }
            master += (masterTarget - master) * smoothing
            var l: Float = 0, r: Float = 0
            if fade > 0 {
                for i in 0..<voices {
                    let t = p[i] * p[i]
                    gains[i] += (t - gains[i]) * smoothing
                    if t == 0 && gains[i] < 0.000_01 { gains[i] = 0; continue }
                    l += gens[2 * i].next() * gains[i]
                    r += gens[2 * i + 1].next() * gains[i]
                }
            }
            let g = master * fade * fade
            l = softClip(l * g)
            r = softClip(r * g)
            left[f] = l
            right[f] = r
            energy += l * l + r * r
        }
        p[Param.level] = frames > 0 ? (energy / Float(2 * frames)).squareRoot() : 0
        p[Param.fade] = fade
    }
}

/// AVAudioEngine with one source node that pulls from a `RenderCore`. Created only when the user first plays.
final class HumEngine {
    let engine = AVAudioEngine()
    let core: RenderCore
    private var node: AVAudioSourceNode!
    private var observer: NSObjectProtocol?
    var wantsRunning = false

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        core = RenderCore(sampleRate: rate > 0 ? rate : 48_000, seed: UInt64(Date().timeIntervalSince1970))
        let format = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2)!
        let core = core
        node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            core.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        // Headphones unplugged or the output changed: the engine stops itself, so start it again.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self, self.wantsRunning else { return }
            try? self.engine.start()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func start() {
        wantsRunning = true
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { NSLog("Hum: audio engine failed to start: \(error.localizedDescription)") }
    }

    func pause() {
        wantsRunning = false
        engine.pause()
    }
}
