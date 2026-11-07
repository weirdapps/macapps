import AppKit
import Kit
import SwiftUI

// MARK: - Meter

enum TimeSignature: String, CaseIterable, Codable, Identifiable {
    case twoFour = "2/4", threeFour = "3/4", fourFour = "4/4", fiveFour = "5/4", sixEight = "6/8", sevenEight = "7/8"

    var id: String { rawValue }

    var beats: Int {
        switch self {
        case .twoFour: 2
        case .threeFour: 3
        case .fourFour: 4
        case .fiveFour: 5
        case .sixEight: 6
        case .sevenEight: 7
        }
    }

    /// Beats that open a group and get a lighter accent: 3+2 for 5/4, 3+3 for 6/8, 2+2+3 for 7/8.
    var groupStarts: Set<Int> {
        switch self {
        case .fiveFour: [0, 3]
        case .sixEight: [0, 3]
        case .sevenEight: [0, 2, 4]
        default: [0]
        }
    }
}

enum Subdivision: Int, CaseIterable, Codable, Identifiable {
    case none = 1, eighths = 2, triplets = 3, sixteenths = 4

    var id: Int { rawValue }
    /// Clicks per beat.
    var ticks: Int { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .eighths: "Eighths"
        case .triplets: "Triplets"
        case .sixteenths: "Sixteenths"
        }
    }
}

enum Sound: String, CaseIterable, Codable, Identifiable {
    case click, wood, beep
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// How loud and bright one click is.
enum TickLevel: Int, CaseIterable {
    case accent, group, beat, sub
}

struct MeterConfig: Codable, Equatable {
    var bpm = 120
    var signature = TimeSignature.fourFour
    var subdivision = Subdivision.none
    var sound = Sound.click
    var accent = true
    var volume = 0.8
}

enum Tempo {
    static let range = 30...300

    static func clamp(_ bpm: Int) -> Int { min(max(bpm, range.lowerBound), range.upperBound) }

    /// The traditional Italian marking for a tempo.
    static func marking(_ bpm: Int) -> String {
        switch bpm {
        case ..<40: "Grave"
        case ..<60: "Largo"
        case ..<66: "Larghetto"
        case ..<76: "Adagio"
        case ..<108: "Andante"
        case ..<120: "Moderato"
        case ..<156: "Allegro"
        case ..<176: "Vivace"
        case ..<200: "Presto"
        default: "Prestissimo"
        }
    }
}

// MARK: - Scheduling

/// Beat times as sample frames on the player's timeline: beat n starts at anchorFrame + (n - anchorBeat) * framesPerBeat.
/// Times are computed from the anchor, never accumulated, so nothing drifts over a long session.
struct BeatClock: Equatable {
    var anchorBeat: Int
    var anchorFrame: Double
    var framesPerBeat: Double

    static func framesPerBeat(bpm: Int, sampleRate: Double) -> Double { sampleRate * 60 / Double(bpm) }

    func frame(ofBeat beat: Int) -> Double { anchorFrame + Double(beat - anchorBeat) * framesPerBeat }
}

struct ScheduledTick: Equatable {
    var frame: Int64
    var beat: Int
    var sub: Int
    var level: TickLevel
}

/// The pure heart of the metronome: hands out every click, sample accurate, up to a horizon.
/// Tempo, signature and subdivision changes land on the next beat; sound, accent and volume apply at once.
struct Scheduler {
    let sampleRate: Double
    private(set) var config: MeterConfig
    private(set) var clock: BeatClock
    private(set) var barStart = 0
    /// The beat being played, its start frame, its spacing and its clicks per beat.
    private(set) var beat = -1
    private var sub = 0
    private var beatFrame = 0.0
    private var beatSpacing = 0.0
    private var beatTicks = 0

    init(config: MeterConfig, sampleRate: Double, startFrame: Double) {
        self.sampleRate = sampleRate
        self.config = config
        clock = BeatClock(anchorBeat: 0, anchorFrame: startFrame,
                          framesPerBeat: BeatClock.framesPerBeat(bpm: config.bpm, sampleRate: sampleRate))
    }

    /// Applies new settings. Returns true when the beat grid moved, so the visuals need a new anchor.
    mutating func update(_ new: MeterConfig, now: Double) -> Bool {
        var moved = false
        if new.bpm != config.bpm {
            let spacing = BeatClock.framesPerBeat(bpm: new.bpm, sampleRate: sampleRate)
            if beat < 0 {
                clock.framesPerBeat = spacing
            } else {
                // The next beat follows the current one at the new spacing, never in the past.
                let next = max(beatFrame + spacing, now + 0.03 * sampleRate)
                clock = BeatClock(anchorBeat: beat + 1, anchorFrame: next, framesPerBeat: spacing)
            }
            moved = true
        }
        if new.signature != config.signature {
            barStart = beat + 1
            moved = true
        }
        if new.subdivision != config.subdivision { moved = true }
        config = new
        return moved
    }

    /// Every click that starts before `horizon`, in order. Call repeatedly; each click is returned once.
    mutating func ticks(through horizon: Double) -> [ScheduledTick] {
        var out: [ScheduledTick] = []
        let nextBeatFrame = { (s: Scheduler) in s.clock.frame(ofBeat: s.beat + 1) }
        while true {
            if sub < beatTicks {
                let f = beatFrame + Double(sub) * beatSpacing / Double(beatTicks)
                if f >= nextBeatFrame(self) { sub = beatTicks; continue } // A faster tempo cut this beat short.
                if f >= horizon { break }
                out.append(ScheduledTick(frame: Int64(f.rounded()), beat: beat, sub: sub, level: level(beat: beat, sub: sub)))
                sub += 1
            } else {
                let f = nextBeatFrame(self)
                if f >= horizon { break }
                beat += 1
                beatFrame = f
                beatSpacing = clock.framesPerBeat
                beatTicks = config.subdivision.ticks
                sub = 0
            }
        }
        return out
    }

    func beatInBar(_ beat: Int) -> Int { Scheduler.mod(beat - barStart, config.signature.beats) }

    func level(beat: Int, sub: Int) -> TickLevel {
        if sub > 0 { return .sub }
        guard config.accent else { return .beat }
        let b = beatInBar(beat)
        if b == 0 { return .accent }
        return config.signature.groupStarts.contains(b) ? .group : .beat
    }

    /// What the window needs to draw beats in step with the sound.
    func anchor(at date: Date, nowFrame: Double) -> VisualAnchor {
        let beatZero = beat < 0 ? 0 : beat + 1
        let seconds = (clock.frame(ofBeat: beatZero) - nowFrame) / sampleRate
        return VisualAnchor(beat: beatZero, time: date.timeIntervalSinceReferenceDate + seconds,
                            secondsPerBeat: clock.framesPerBeat / sampleRate, barStart: barStart,
                            beats: config.signature.beats, ticks: config.subdivision.ticks)
    }

    static func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}

/// A beat whose wall clock time is known; the visuals extrapolate from the latest one that has started.
struct VisualAnchor: Equatable {
    var beat: Int
    var time: TimeInterval
    var secondsPerBeat: Double
    var barStart: Int
    var beats: Int
    var ticks: Int

    func position(at t: TimeInterval) -> Double { Double(beat) + (t - time) / secondsPerBeat }
}

/// Where the metronome is at one instant: which beat of the bar, which click of the beat, how far through it.
struct BeatPhase: Equatable {
    var position: Double
    var beatInBar: Int
    var tick: Int
    var fraction: Double

    init(position: Double, barStart: Int, beats: Int, ticks: Int) {
        self.position = position
        let whole = Int(position.rounded(.down))
        beatInBar = Scheduler.mod(whole - barStart, beats)
        fraction = position - Double(whole)
        tick = min(Int(fraction * Double(ticks)), ticks - 1)
    }
}

// MARK: - Tap tempo

/// Averages taps over the last few, starting over after a pause.
struct TapTempo {
    static let resetGap = 2.0
    static let window = 6
    private(set) var taps: [TimeInterval] = []

    /// Adds a tap; returns the tempo once there are two taps in a row.
    mutating func tap(at t: TimeInterval) -> Int? {
        if let last = taps.last, t - last > TapTempo.resetGap || t <= last { taps.removeAll() }
        taps.append(t)
        if taps.count > TapTempo.window { taps.removeFirst(taps.count - TapTempo.window) }
        return bpm
    }

    var bpm: Int? {
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return nil }
        let interval = (last - first) / Double(taps.count - 1)
        return Tempo.clamp(Int((60 / interval).rounded()))
    }
}

// MARK: - Presets

struct Preset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bpm: Int
    var signature: TimeSignature
    var subdivision: Subdivision
    var sound: Sound
    var accent: Bool

    init(name: String, config: MeterConfig) {
        self.name = name
        bpm = config.bpm
        signature = config.signature
        subdivision = config.subdivision
        sound = config.sound
        accent = config.accent
    }

    func applied(to config: MeterConfig) -> MeterConfig {
        var c = config
        c.bpm = bpm
        c.signature = signature
        c.subdivision = subdivision
        c.sound = sound
        c.accent = accent
        return c
    }

    func matches(_ config: MeterConfig) -> Bool { applied(to: config) == config }

    var summary: String { "\(bpm) BPM, \(signature.rawValue)" }

    static func make(_ name: String, _ bpm: Int, _ sig: TimeSignature, _ sub: Subdivision = .none, _ sound: Sound = .click) -> Preset {
        Preset(name: name, config: MeterConfig(bpm: bpm, signature: sig, subdivision: sub, sound: sound))
    }

    static let starters: [Preset] = [
        make("Slow practice", 60, .fourFour, .none, .wood),
        make("Ballad", 72, .fourFour, .eighths, .wood),
        make("Waltz", 90, .threeFour),
        make("Jig", 116, .sixEight, .none, .wood),
        make("Rock", 120, .fourFour, .eighths),
        make("Funk sixteenths", 98, .fourFour, .sixteenths, .beep),
        make("Shuffle", 132, .fourFour, .triplets),
        make("Take Five", 172, .fiveFour),
        make("Balkan seven", 210, .sevenEight, .none, .wood),
    ]
}

struct SavedState: Codable, Equatable {
    var config = MeterConfig()
    var presets = Preset.starters
}

/// What the naming sheet is for.
struct NameRequest: Identifiable {
    enum Kind { case new, rename(UUID) }
    let id = UUID()
    var kind: Kind
    var text: String
}

// MARK: - Model

@MainActor
final class BeatModel: ObservableObject {
    @Published var config: MeterConfig { didSet { configChanged(from: oldValue) } }
    @Published var presets: [Preset] { didSet { save() } }
    @Published var selection: Preset.ID?
    @Published private(set) var isPlaying = false
    @Published private(set) var anchors: [VisualAnchor] = []
    @Published private(set) var audioError: String?
    @Published var naming: NameRequest?

    /// Fixed beat position for the website screenshot.
    private(set) var demoPosition: Double?
    private let persists: Bool
    private var tapTempo = TapTempo()
    private lazy var engine = ClickEngine { [weak self] anchor in
        Task { @MainActor in self?.receive(anchor) }
    }

    init(state: SavedState, persists: Bool) {
        config = state.config
        presets = state.presets
        self.persists = persists
        selection = state.presets.first(where: { $0.matches(state.config) })?.id
    }

    convenience init() {
        let saved = Desktop.isSnapshot ? nil : Storage.load(SavedState.self, app: "Beat", file: "state.json")
        self.init(state: saved ?? SavedState(), persists: !Desktop.isSnapshot)
    }

    static var demo: BeatModel {
        var config = MeterConfig(bpm: 120, signature: .fourFour, subdivision: .eighths, sound: .click)
        config.volume = 0.8
        let model = BeatModel(state: SavedState(config: config), persists: false)
        model.isPlaying = true
        model.demoPosition = 1.32
        model.anchors = [VisualAnchor(beat: 0, time: 0, secondsPerBeat: 0.5, barStart: 0, beats: 4, ticks: 2)]
        return model
    }

    var selectedPreset: Preset? { presets.first { $0.id == selection } }

    // MARK: Transport

    func toggle() { isPlaying ? stop() : start() }

    func start() {
        guard !isPlaying, demoPosition == nil else { return }
        audioError = nil
        isPlaying = true
        engine.start(config)
    }

    func stop() {
        guard isPlaying, demoPosition == nil else { return }
        isPlaying = false
        anchors = []
        engine.stop()
    }

    private func receive(_ anchor: VisualAnchor?) {
        guard isPlaying else { return }
        guard let anchor else {
            isPlaying = false
            anchors = []
            audioError = "The sound output could not start."
            return
        }
        // Keep the anchor still in force until the new one starts.
        let now = Date.timeIntervalSinceReferenceDate
        let current = anchors.last(where: { $0.time <= now })
        anchors = (current.map { [$0] } ?? []) + [anchor]
    }

    /// The beat position at a moment, or nil when the metronome is not running yet.
    func phase(at date: Date) -> BeatPhase? {
        guard isPlaying else { return nil }
        if let demoPosition, let a = anchors.first {
            return BeatPhase(position: demoPosition, barStart: a.barStart, beats: a.beats, ticks: a.ticks)
        }
        let t = date.timeIntervalSinceReferenceDate
        guard let a = anchors.last(where: { $0.time <= t }) else { return nil }
        return BeatPhase(position: a.position(at: t), barStart: a.barStart, beats: config.signature.beats, ticks: a.ticks)
    }

    // MARK: Settings

    func setBPM(_ bpm: Int) { config.bpm = Tempo.clamp(bpm) }
    func nudge(_ delta: Int) { setBPM(config.bpm + delta) }

    func tap() {
        if let bpm = tapTempo.tap(at: ProcessInfo.processInfo.systemUptime) { setBPM(bpm) }
    }

    private func configChanged(from old: MeterConfig) {
        guard config != old else { return }
        if isPlaying, demoPosition == nil { engine.update(config) }
        if let p = selectedPreset, !p.matches(config), !p.matches(old) { selection = nil }
        save()
    }

    private func save() {
        guard persists else { return }
        Storage.save(SavedState(config: config, presets: presets), app: "Beat", file: "state.json")
    }

    // MARK: Presets

    func select(_ id: Preset.ID?) {
        selection = id
        if let p = selectedPreset { config = p.applied(to: config) }
    }

    func requestNewPreset() { naming = NameRequest(kind: .new, text: suggestedName()) }

    func requestRename(_ id: Preset.ID) {
        guard let p = presets.first(where: { $0.id == id }) else { return }
        naming = NameRequest(kind: .rename(id), text: p.name)
    }

    func finishNaming(_ request: NameRequest, undo: UndoManager?) {
        naming = nil
        let name = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch request.kind {
        case .new:
            let preset = Preset(name: name, config: config)
            change(undo, "New Preset") { $0.append(preset) }
            selection = preset.id
        case .rename(let id):
            change(undo, "Rename Preset") { list in
                if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = name }
            }
        }
    }

    func updatePreset(_ id: Preset.ID, undo: UndoManager?) {
        let config = config
        change(undo, "Update Preset") { list in
            if let i = list.firstIndex(where: { $0.id == id }) {
                list[i] = Preset(name: list[i].name, config: config).with(id: id)
            }
        }
        selection = id
    }

    func deletePreset(_ id: Preset.ID, undo: UndoManager?) {
        change(undo, "Delete Preset") { $0.removeAll { $0.id == id } }
        if selection == id { selection = nil }
    }

    func movePresets(from source: IndexSet, to destination: Int, undo: UndoManager?) {
        change(undo, "Move Preset") { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Edits the preset list with an undo step that restores the previous list.
    private func change(_ undo: UndoManager?, _ name: String, _ edit: (inout [Preset]) -> Void) {
        let before = presets
        edit(&presets)
        undo?.registerUndo(withTarget: self) { model in
            let redo = model.presets
            model.presets = before
            undo?.registerUndo(withTarget: model) { $0.presets = redo }
        }
        undo?.setActionName(name)
    }

    private func suggestedName() -> String {
        "\(Tempo.marking(config.bpm)) in \(config.signature.rawValue)"
    }
}

extension Preset {
    func with(id: UUID) -> Preset {
        var p = self
        p.id = id
        return p
    }
}
