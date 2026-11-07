import AVFoundation
import Kit

/// Synthesised cues for phase changes: a small bell chime or a soft sine swell, pitched per phase.
@MainActor
final class Chimes {
    enum Cue: CaseIterable {
        case inhale, hold, exhale, done

        init(_ kind: PhaseKind) {
            switch kind {
            case .inhale, .topUp: self = .inhale
            case .holdFull, .holdEmpty: self = .hold
            case .exhale: self = .exhale
            }
        }

        /// A calm pentatonic set: D5, B4, G4, and a low G for the end.
        var frequency: Double {
            switch self {
            case .inhale: 587.33
            case .hold: 493.88
            case .exhale: 392.0
            case .done: 293.66
            }
        }
    }

    nonisolated static let sampleRate = 44_100.0

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var cache: [String: AVAudioPCMBuffer] = [:]

    func play(_ cue: Cue, style: SoundStyle, volume: Double) {
        guard style != .off, !Desktop.isSnapshot, volume > 0 else { return }
        guard let (engine, player) = ready(), let buffer = buffer(cue, style) else { return }
        player.volume = Float(volume)
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func ready() -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine, let player { return (engine, player) }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else { return nil }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return nil }
        self.engine = engine
        self.player = player
        return (engine, player)
    }

    private func buffer(_ cue: Cue, _ style: SoundStyle) -> AVAudioPCMBuffer? {
        let key = "\(cue)-\(style.rawValue)"
        if let cached = cache[key] { return cached }
        let samples = Self.samples(cue, style)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { channel[i] = s }
        cache[key] = buffer
        return buffer
    }

    /// The raw mono samples of a cue, peak below 0.5 so cues never clip when they overlap.
    nonisolated static func samples(_ cue: Cue, _ style: SoundStyle) -> [Float] {
        let f = cue.frequency
        switch style {
        case .off:
            return []
        case .chime:
            // A small bell: a few inharmonic partials with fast attack and exponential decay.
            let length = cue == .done ? 3.2 : 2.0
            let n = Int(length * sampleRate)
            let partials: [(ratio: Double, amp: Double, decay: Double)] = [(1, 1, 1.6), (2.01, 0.32, 0.9), (3.03, 0.12, 0.55),
                                                                         (4.2, 0.05, 0.35)]
            let norm = partials.reduce(0) { $0 + $1.amp }
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.006)
                let tail = min(1, (length - t) / 0.05) // Avoid a click at the very end.
                var v = 0.0
                for p in partials { v += p.amp * sin(2 * .pi * f * p.ratio * t) * exp(-t * (cue == .done ? 0.7 : 1) / p.decay * 2.2) }
                return Float(0.42 * attack * tail * v / norm)
            }
        case .tone:
            // A soft swell: sine plus a quiet octave under a raised cosine envelope.
            let length = cue == .done ? 2.6 : 1.5
            let n = Int(length * sampleRate)
            return (0..<n).map { i in
                let t = Double(i) / sampleRate
                let env = 0.5 - cos(2 * .pi * t / length) / 2
                let v = sin(2 * .pi * f * 0.5 * t) + 0.18 * sin(2 * .pi * f * t)
                return Float(0.34 * env * v / 1.18)
            }
        }
    }
}
