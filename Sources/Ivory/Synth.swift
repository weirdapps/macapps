import AVFoundation
import Foundation
import os

// MARK: - Synth core

/// The sound engine without any audio hardware: voices, envelopes and the mix. `Synth` feeds it from the audio thread,
/// and the self-test renders it offline.
struct SynthCore {
    enum Command {
        case noteOn(Int, UInt8, Sound)
        case noteOff(Int)
        case sustain(Bool)
        case gain(Float)
        case allOff
    }

    static let maxVoices = 24
    static let partials = 8

    struct Voice {
        var note: Int
        var sound: Sound
        var frequency: Double
        var velocity: Float
        var age: Int = 0
        var held = true
        var released = false
        var releaseGain: Float = 1
        var releaseCoefficient: Float = 1
        // Fixed-size and inline, so the audio thread never allocates.
        var phases = SIMD8<Double>(repeating: 0)
        var increments = SIMD8<Double>(repeating: 0)
        var amps = SIMD8<Float>(repeating: 0)
        var decays = SIMD8<Float>(repeating: 1)
        var noise: Float = 0
        var noiseDecay: Float = 0
        var filter: Float = 0
        var pan: Float = 0
    }

    let sampleRate: Double
    private(set) var voices: [Voice] = []
    private(set) var sustain = false
    var gain: Float = 0.8
    private var seed: UInt32 = 0x1234_5678
    private var lfoPhase: Double = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        voices.reserveCapacity(Self.maxVoices + 1)
    }

    mutating func handle(_ command: Command) {
        switch command {
        case .noteOn(let note, let velocity, let sound): noteOn(note, velocity: velocity, sound: sound)
        case .noteOff(let note):
            for i in voices.indices where voices[i].note == note && voices[i].held {
                voices[i].held = false
                if !sustain { startRelease(&voices[i]) }
            }
        case .sustain(let on):
            sustain = on
            if !on { for i in voices.indices where !voices[i].held { startRelease(&voices[i]) } }
        case .gain(let value): gain = max(0, min(1, value))
        case .allOff:
            for i in voices.indices { voices[i].held = false; startRelease(&voices[i]) }
        }
    }

    private mutating func noteOn(_ note: Int, velocity: UInt8, sound: Sound) {
        // A repeated key damps the string it struck before.
        for i in voices.indices where voices[i].note == note { voices[i].held = false; startRelease(&voices[i], seconds: 0.06) }
        if voices.count >= Self.maxVoices {
            // Steal the quietest released voice, or else the oldest.
            // A plain loop, because this runs on the audio thread and must not allocate.
            var victim = 0
            for i in voices.indices {
                let a = voices[i], b = voices[victim]
                if a.released != b.released ? a.released : (a.released ? a.releaseGain < b.releaseGain : a.age > b.age) { victim = i }
            }
            voices.remove(at: victim)
        }
        voices.append(makeVoice(note, velocity: Float(velocity) / 127, sound: sound))
    }

    private func makeVoice(_ note: Int, velocity: Float, sound: Sound) -> Voice {
        let f = Note.frequency(note)
        var v = Voice(note: note, sound: sound, frequency: f, velocity: velocity)
        v.pan = Float(max(-1, min(1, Double(note - 60) / 36))) * 0.35
        let nyquist = sampleRate * 0.45
        func decay(_ seconds: Double) -> Float { Float(exp(-1 / (max(0.001, seconds) * sampleRate))) }
        // Low notes ring longer, as on a real instrument.
        let pitchFactor = pow(2, -Double(note - 60) / 24)
        switch sound {
        case .piano:
            let inharmonicity = 0.0004
            let ring = min(9, max(0.9, 4.5 * pitchFactor))
            for n in 0..<Self.partials {
                let k = Double(n + 1)
                let freq = f * k * sqrt(1 + inharmonicity * k * k)
                guard freq < nyquist else { continue }
                v.increments[n] = 2 * .pi * freq / sampleRate
                // Harder strikes are brighter.
                let brightness = pow(Double(velocity), 0.4 + 0.25 * k)
                v.amps[n] = Float(brightness / pow(k, 1.15))
                v.decays[n] = decay(ring / (1 + 0.7 * (k - 1)))
            }
            v.noise = 0.06 * velocity
            v.noiseDecay = decay(0.006)
        case .electric:
            // Two-operator FM: slot 0 carrier, slot 1 modulator index, slot 2 the bell tine.
            v.increments[0] = 2 * .pi * f / sampleRate
            v.increments[1] = 2 * .pi * f / sampleRate
            v.increments[2] = f * 7 < nyquist ? 2 * .pi * f * 7 / sampleRate : 0
            v.amps[0] = 0.9
            v.decays[0] = decay(min(6, max(0.8, 2.8 * pitchFactor)))
            v.amps[1] = 0.4 + 2.2 * velocity
            v.decays[1] = decay(0.28)
            v.amps[2] = 0.12 * velocity
            v.decays[2] = decay(0.06)
        case .organ:
            let ratios: [Double] = [0.5, 1, 2, 3, 4, 6, 8]
            let levels: [Float] = [0.5, 1, 0.65, 0.4, 0.32, 0.18, 0.12]
            for (n, ratio) in ratios.enumerated() where f * ratio < nyquist {
                v.increments[n] = 2 * .pi * f * ratio / sampleRate
                v.amps[n] = levels[n] * 0.55
            }
            v.noise = 0.05
            v.noiseDecay = decay(0.003)
        case .pad:
            let ratios: [Double] = [0.996, 1.004, 1.997, 2.003, 3, 4.002]
            let levels: [Float] = [0.55, 0.55, 0.28, 0.28, 0.16, 0.08]
            for (n, ratio) in ratios.enumerated() where f * ratio < nyquist {
                v.increments[n] = 2 * .pi * f * ratio / sampleRate
                v.amps[n] = levels[n]
            }
        }
        return v
    }

    private func releaseSeconds(_ sound: Sound) -> Double {
        switch sound {
        case .piano: 0.18
        case .electric: 0.3
        case .organ: 0.07
        case .pad: 1.4
        }
    }

    private func attackSeconds(_ sound: Sound) -> Double {
        switch sound {
        case .piano: 0.002
        case .electric: 0.003
        case .organ: 0.006
        case .pad: 0.45
        }
    }

    private func startRelease(_ voice: inout Voice, seconds: Double? = nil) {
        guard !voice.released || seconds != nil else { return }
        voice.released = true
        let s = seconds ?? releaseSeconds(voice.sound)
        voice.releaseCoefficient = Float(exp(-1 / (s * sampleRate)))
    }

    private mutating func random() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }

    /// Mixes `frames` samples into `left` and `right`, overwriting them.
    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames { left[i] = 0; right[i] = 0 }
        let lfoIncrement = 2 * Double.pi * 5.6 / sampleRate
        for v in voices.indices {
            var voice = voices[v]
            let attack = Float(attackSeconds(voice.sound) * sampleRate)
            let leftGain = 1 - max(0, voice.pan), rightGain = 1 + min(0, voice.pan)
            var lfo = lfoPhase
            for i in 0..<frames {
                var sample: Float = 0
                switch voice.sound {
                case .piano:
                    for n in 0..<Self.partials where voice.increments[n] > 0 {
                        sample += Float(sin(voice.phases[n])) * voice.amps[n]
                        voice.phases[n] += voice.increments[n]
                        if voice.phases[n] > 2 * .pi { voice.phases[n] -= 2 * .pi }
                        voice.amps[n] *= voice.decays[n]
                    }
                    sample *= 0.42
                case .electric:
                    let modulator = sin(voice.phases[1]) * Double(voice.amps[1])
                    sample = Float(sin(voice.phases[0] + modulator)) * voice.amps[0]
                    if voice.increments[2] > 0 { sample += Float(sin(voice.phases[2])) * voice.amps[2] }
                    for n in 0..<3 {
                        voice.phases[n] += voice.increments[n]
                        if voice.phases[n] > 2 * .pi { voice.phases[n] -= 2 * .pi }
                    }
                    voice.amps[0] *= voice.decays[0]
                    voice.amps[1] = max(0.25, voice.amps[1] * voice.decays[1])
                    voice.amps[2] *= voice.decays[2]
                    sample *= 0.55
                case .organ, .pad:
                    for n in 0..<Self.partials where voice.increments[n] > 0 {
                        sample += Float(sin(voice.phases[n])) * voice.amps[n]
                        voice.phases[n] += voice.increments[n]
                        if voice.phases[n] > 2 * .pi { voice.phases[n] -= 2 * .pi }
                    }
                    let depth: Float = voice.sound == .organ ? 0.07 : 0.12
                    sample *= (1 - depth + depth * Float(sin(lfo))) * (voice.sound == .organ ? 0.32 : 0.36)
                    lfo += lfoIncrement * (voice.sound == .organ ? 1 : 0.18)
                }
                if voice.noise > 0.0001 {
                    // A filtered thump for the hammer or the key click.
                    voice.filter += 0.35 * (random() - voice.filter)
                    sample += voice.filter * voice.noise
                    voice.noise *= voice.noiseDecay
                }
                if Float(voice.age) < attack { sample *= Float(voice.age) / attack }
                if voice.released {
                    sample *= voice.releaseGain
                    voice.releaseGain *= voice.releaseCoefficient
                }
                sample *= 0.45 + 0.55 * voice.velocity
                voice.age += 1
                left[i] += sample * leftGain
                right[i] += sample * rightGain
            }
            voices[v] = voice
        }
        lfoPhase = (lfoPhase + lfoIncrement * Double(frames)).truncatingRemainder(dividingBy: 2 * .pi)
        // Soft clip the mix so chords never crackle.
        let g = gain * gain
        for i in 0..<frames {
            left[i] = tanhf(left[i] * 0.5 * g)
            right[i] = tanhf(right[i] * 0.5 * g)
        }
        voices.removeAll { voice in
            if voice.released && voice.releaseGain < 0.002 { return true }
            // A piano or electric piano note that has died away on its own.
            if voice.sound == .piano || voice.sound == .electric {
                let level = (voice.sound == .piano ? voice.amps.sum() : voice.amps[0]) * (voice.released ? voice.releaseGain : 1)
                return voice.age > Int(sampleRate * 0.05) && level < 0.0004
            }
            return false
        }
    }
}

// MARK: - Command ring

/// The queue between the main thread and the audio thread. A fixed ring that never allocates; the volume is kept
/// apart and only its newest value counts, so dragging the slider can never fill the ring and drop a note.
struct CommandRing {
    private var slots: [SynthCore.Command]
    private var head = 0, tail = 0
    private var pendingGain: Float?

    init(capacity: Int = 512) { slots = Array(repeating: .allOff, count: max(2, capacity)) }

    /// Returns false when the ring is full and the command was dropped.
    @discardableResult
    mutating func push(_ command: SynthCore.Command) -> Bool {
        if case .gain(let value) = command { pendingGain = value; return true }
        let next = (tail + 1) % slots.count
        guard next != head else { return false }
        slots[tail] = command
        tail = next
        return true
    }

    mutating func drain(into core: inout SynthCore) {
        if let gain = pendingGain { core.handle(.gain(gain)); pendingGain = nil }
        while head != tail {
            core.handle(slots[head])
            head = (head + 1) % slots.count
        }
    }
}

// MARK: - Audio engine

/// Plays `SynthCore` through AVAudioEngine. The main thread posts commands into a small ring; the render callback drains it.
final class Synth: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var core: SynthCore
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var ring = CommandRing()
    private var started = false
    private var observer: NSObjectProtocol?

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        core = SynthCore(sampleRate: rate > 0 ? rate : 48_000)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: .main) { [weak self] _ in
            guard let self, self.started else { return }
            try? self.engine.start()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    /// Starts the engine on first use, so launching the app never grabs the audio device.
    private func start() {
        guard !started else { return }
        started = true
        guard let format = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            self.render(frames: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
        do { try engine.start() } catch { NSLog("Ivory: audio engine did not start: \(error.localizedDescription)") }
    }

    private func post(_ command: SynthCore.Command) {
        os_unfair_lock_lock(lock)
        ring.push(command)
        os_unfair_lock_unlock(lock)
    }

    private func render(frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        os_unfair_lock_lock(lock)
        ring.drain(into: &core)
        os_unfair_lock_unlock(lock)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        core.render(left: l, right: r, frames: frames)
    }

    func noteOn(_ note: Int, velocity: UInt8, sound: Sound) {
        start()
        post(.noteOn(note, velocity, sound))
    }

    func noteOff(_ note: Int) { post(.noteOff(note)) }
    func setSustain(_ on: Bool) { post(.sustain(on)) }
    func setGain(_ gain: Float) { post(.gain(gain)) }
    func allOff() { post(.allOff) }
}
