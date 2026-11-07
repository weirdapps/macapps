import Accelerate
import AppKit
import AVFoundation
import Foundation

// MARK: - Pitch detection

enum Pitch {
    /// The fundamental frequency of `samples` by the YIN method (de Cheveigné and Kawahara, 2002), refined with
    /// parabolic interpolation on the difference function. Returns nil when no periodic tone stands out.
    static func detect(_ samples: [Float], sampleRate: Double, range: ClosedRange<Double> = 30...2000,
                       threshold: Double = 0.15) -> (frequency: Double, clarity: Double)? {
        let n = samples.count
        let maxTau = min(Int(sampleRate / range.lowerBound), n / 2)
        let minTau = max(2, Int(sampleRate / range.upperBound))
        let w = n - maxTau
        guard maxTau > minTau + 2, w > 0 else { return nil }

        // Difference function d(tau) = sum (x[j] - x[j + tau])^2 = e0 + e(tau) - 2 r(tau).
        let x = samples.map(Double.init)
        var d = [Double](repeating: 0, count: maxTau + 1)
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            var e0 = 0.0
            vDSP_svesqD(base, 1, &e0, vDSP_Length(w))
            var et = e0
            for tau in 1...maxTau {
                et += x[tau - 1 + w] * x[tau - 1 + w] - x[tau - 1] * x[tau - 1]
                var r = 0.0
                vDSP_dotprD(base, 1, base + tau, 1, &r, vDSP_Length(w))
                d[tau] = max(0, e0 + et - 2 * r)
            }
        }

        // Cumulative mean normalised difference, then the first dip under the threshold.
        var cmnd = [Double](repeating: 1, count: maxTau + 1)
        var running = 0.0
        for tau in 1...maxTau {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Double(tau) / running : 1
        }
        var found: Int?
        var tau = minTau
        while tau < maxTau {
            if cmnd[tau] < threshold {
                while tau + 1 < maxTau, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                found = tau
                break
            }
            tau += 1
        }
        guard var t = found else { return nil }
        let clarity = 1 - cmnd[t]
        // The raw difference function has its true minimum within a sample of the normalised one.
        if t - 1 > minTau, d[t - 1] < d[t] { t -= 1 } else if t + 1 < maxTau, d[t + 1] < d[t] { t += 1 }
        guard t > 1, t < maxTau else { return nil }
        let a = d[t - 1], b = d[t], c = d[t + 1]
        let denominator = a - 2 * b + c
        let shift = denominator > 0 ? 0.5 * (a - c) / denominator : 0
        let period = Double(t) + min(1, max(-1, shift))
        return (sampleRate / period, clarity)
    }

    /// The loudness of `samples` in dB relative to full scale; silence is -120.
    static func decibels(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms > 0 ? max(-120, 20 * log10(Double(rms))) : -120
    }

    /// A sine wave for tests: `count` samples at `frequency`.
    static func sine(_ frequency: Double, sampleRate: Double, count: Int, amplitude: Double = 0.5, phase: Double = 0.3) -> [Float] {
        (0..<count).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate + phase)) }
    }
}

// MARK: - Notes

enum Music {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    static let referenceRange: ClosedRange<Double> = 430...450

    static func frequency(midi: Int, a4: Double) -> Double { a4 * pow(2, Double(midi - 69) / 12) }
    static func midiValue(_ frequency: Double, a4: Double) -> Double { 69 + 12 * log2(frequency / a4) }
    static func cents(_ frequency: Double, from target: Double) -> Double { 1200 * log2(frequency / target) }
    static func name(_ midi: Int) -> String { names[((midi % 12) + 12) % 12] }
    static func octave(_ midi: Int) -> Int { Int((Double(midi) / 12).rounded(.down)) - 1 }
    static func label(_ midi: Int) -> String { "\(name(midi))\(octave(midi))" }

    static func clampReference(_ value: Double) -> Double {
        min(referenceRange.upperBound, max(referenceRange.lowerBound, value.rounded()))
    }

    static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Signed cents as people read them, with a real minus sign.
    static func centsText(_ cents: Double) -> String {
        let text = abs(cents) >= 100 ? String(format: "%+.0f", cents) : String(format: "%+.1f", cents)
        return text.replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

enum Instrument: String, CaseIterable, Identifiable {
    case chromatic, guitar, bass, ukulele, violin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chromatic: "Chromatic"
        case .guitar: "Guitar"
        case .bass: "Bass"
        case .ukulele: "Ukulele"
        case .violin: "Violin"
        }
    }

    /// Open strings as MIDI notes, in the order players name them.
    var strings: [Int] {
        switch self {
        case .chromatic: []
        case .guitar: [40, 45, 50, 55, 59, 64] // E2 A2 D3 G3 B3 E4
        case .bass: [28, 33, 38, 43] // E1 A1 D2 G2
        case .ukulele: [67, 60, 64, 69] // G4 C4 E4 A4, re-entrant
        case .violin: [55, 62, 69, 76] // G3 D4 A4 E5
        }
    }

    var tuningName: String {
        switch self {
        case .chromatic: "Any note"
        case .guitar: "Standard E A D G B E"
        case .bass: "Standard E A D G"
        case .ukulele: "Standard G C E A"
        case .violin: "Standard G D A E"
        }
    }
}

struct Target: Equatable {
    var midi: Int
    var string: Int? // Index into the instrument's strings.
}

enum Tuning {
    /// What the player is aiming for: the nearest semitone in chromatic mode (sticking to `previous` until the pitch
    /// is clearly past it), otherwise the locked string or the nearest open string.
    static func target(for frequency: Double, instrument: Instrument, a4: Double, locked: Int? = nil,
                       previous: Target? = nil) -> Target {
        let value = Music.midiValue(frequency, a4: a4)
        let strings = instrument.strings
        if strings.isEmpty {
            if let previous, previous.string == nil, abs(value - Double(previous.midi)) < 0.6 { return previous }
            return Target(midi: Int(value.rounded()), string: nil)
        }
        if let locked, strings.indices.contains(locked) { return Target(midi: strings[locked], string: locked) }
        let best = strings.indices.min { abs(Double(strings[$0]) - value) < abs(Double(strings[$1]) - value) }!
        return Target(midi: strings[best], string: best)
    }
}

// MARK: - Microphone

struct Reading: Sendable {
    var frequency: Double?
    var decibels: Double
}

/// Listens to the default input with AVAudioEngine and analyses overlapping windows off the main thread.
final class Listener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.weirdapps.tune.analysis", qos: .userInteractive)
    private var window: [Float] = [] // Touched only on `queue`.
    private var pending = 0
    private var gate = -55.0
    private let deliver: @Sendable (Reading) -> Void
    private var observer: NSObjectProtocol?

    enum Failure: Error { case noInput }

    init(deliver: @escaping @Sendable (Reading) -> Void) {
        self.deliver = deliver
    }

    func setGate(_ decibels: Double) { queue.async { self.gate = decibels } }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw Failure.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let rate = buffer.format.sampleRate
            self.queue.async { self.consume(samples, sampleRate: rate) }
        }
        engine.prepare()
        try engine.start()
        if observer == nil {
            // A new default input (headset plugged in, interface switched) changes the format: start over.
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: .main) { [weak self] _ in
                guard let self else { return }
                self.stop()
                try? self.start()
            }
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.async { self.window.removeAll(); self.pending = 0 }
    }

    var sampleRate: Double { engine.inputNode.outputFormat(forBus: 0).sampleRate }

    private func consume(_ samples: [Float], sampleRate: Double) {
        let size = sampleRate > 60000 ? 8192 : 4096
        window.append(contentsOf: samples)
        if window.count > size { window.removeFirst(window.count - size) }
        pending += samples.count
        guard window.count == size, pending >= size / 4 else { return }
        pending = 0
        let level = Pitch.decibels(window)
        var frequency: Double?
        if level > gate, let pitch = Pitch.detect(window, sampleRate: sampleRate) { frequency = pitch.frequency }
        deliver(Reading(frequency: frequency, decibels: level))
    }
}

// MARK: - Model

@MainActor
final class TuneModel: ObservableObject {
    enum Access { case unknown, granted, denied, noDevice }

    struct Display: Equatable {
        var frequency: Double
        var target: Target
        var targetFrequency: Double
        var cents: Double
        var inTune: Bool { abs(cents) <= 5 }
    }

    @Published var access: Access = .unknown
    @Published var isListening = false
    @Published var display: Display?
    @Published var isHolding = false // Signal gone; the last note stays, dimmed.
    @Published var level = 0.0 // 0...1
    @Published var deviceName = "Microphone"
    @Published var sampleRate = 48000.0
    @Published var lockedString: Int?

    @Published var instrument: Instrument {
        didSet {
            guard instrument != oldValue else { return }
            lockedString = nil
            resetReadings()
            save(instrument.rawValue, "instrument")
        }
    }

    @Published var reference: Double {
        didSet {
            let clamped = Music.clampReference(reference)
            if clamped != reference { reference = clamped }
            if let display { self.display = remeasure(display.frequency, keepTarget: display.target) }
            save(reference, "reference")
        }
    }

    @Published var gate: Double {
        didSet {
            listener?.setGate(gate)
            save(gate, "gate")
        }
    }

    private let isDemo: Bool
    private var listener: Listener?
    private var recent: [Double] = []
    private var smoothed = 0.0
    private var lastVoiced = Date.distantPast

    init() {
        isDemo = false
        let defaults = UserDefaults.standard
        instrument = Instrument(rawValue: defaults.string(forKey: "instrument") ?? "") ?? .guitar
        let saved = defaults.double(forKey: "reference")
        reference = saved == 0 ? 440 : Music.clampReference(saved)
        let savedGate = defaults.double(forKey: "gate")
        gate = savedGate == 0 ? -55 : savedGate
    }

    private init(demo: Void) {
        isDemo = true
        instrument = .guitar
        reference = 440
        gate = -55
        access = .granted
        isListening = true
        deviceName = "MacBook Pro Microphone"
        level = 0.64
        let frequency = 110.13
        display = Display(frequency: frequency, target: Target(midi: 45, string: 1), targetFrequency: 110,
                          cents: Music.cents(frequency, from: 110))
    }

    /// Fixed data for the website snapshot: a guitar's A string, just in tune.
    static var demo: TuneModel { TuneModel(demo: ()) }

    private func save(_ value: Any, _ key: String) {
        if !isDemo { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: Listening

    func start() {
        guard !isDemo, !isListening else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            access = .granted
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { self.access = .granted; self.begin() } else { self.access = .denied }
                    }
                }
            }
        default:
            access = .denied
        }
    }

    private func begin() {
        guard AVCaptureDevice.default(for: .audio) != nil else { access = .noDevice; return }
        let listener = listener ?? Listener { [weak self] reading in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(reading) } }
        }
        self.listener = listener
        listener.setGate(gate)
        do {
            try listener.start()
            access = .granted
            isListening = true
            deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
            sampleRate = listener.sampleRate
        } catch {
            access = .noDevice
            isListening = false
        }
    }

    func pause() {
        listener?.stop()
        isListening = false
        level = 0
        isHolding = display != nil
    }

    func toggleListening() {
        if isListening { pause() } else { start() }
    }

    func retry() {
        access = .unknown
        start()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Readings

    func receive(_ reading: Reading) {
        guard isListening else { return }
        let meter = min(1, max(0, (reading.decibels + 70) / 60))
        level = max(meter, level * 0.8)
        guard let frequency = reading.frequency else {
            let quiet = Date().timeIntervalSince(lastVoiced)
            if quiet > 0.35 { isHolding = display != nil; recent.removeAll() }
            if quiet > 8 { display = nil }
            return
        }
        lastVoiced = Date()
        isHolding = false
        recent.append(frequency)
        if recent.count > 5 { recent.removeFirst() }
        display = remeasure(Music.median(recent), keepTarget: display?.target)
    }

    /// Turns a frequency into what the window shows, smoothing the cents while the target stays the same.
    private func remeasure(_ frequency: Double, keepTarget previous: Target?) -> Display {
        let target = Tuning.target(for: frequency, instrument: instrument, a4: reference, locked: lockedString,
                                   previous: previous)
        let targetFrequency = Music.frequency(midi: target.midi, a4: reference)
        let cents = Music.cents(frequency, from: targetFrequency)
        if target == previous, abs(cents - smoothed) < 30 {
            smoothed += 0.35 * (cents - smoothed)
        } else {
            smoothed = cents
        }
        return Display(frequency: frequency, target: target, targetFrequency: targetFrequency, cents: smoothed)
    }

    func toggleLock(_ string: Int) {
        lockedString = lockedString == string ? nil : string
        if let display { self.display = remeasure(display.frequency, keepTarget: nil) }
    }

    func unlock() {
        lockedString = nil
        if let display { self.display = remeasure(display.frequency, keepTarget: nil) }
    }

    private func resetReadings() {
        recent.removeAll()
        display = nil
        isHolding = false
    }
}
