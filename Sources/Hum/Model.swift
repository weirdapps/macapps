import Foundation
import Kit
import SwiftUI

/// A saved set of volumes. Presets ship with the app; the user's own mixes are stored next to them.
struct Mix: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var name: String
    var levels: [String: Double]

    static let defaultVolume = 0.6

    init(id: UUID = UUID(), name: String, volumes: [Sound: Double]) {
        self.id = id
        self.name = name
        levels = Dictionary(uniqueKeysWithValues: volumes.filter { $0.value > 0 }.map { ($0.key.rawValue, $0.value) })
    }

    init(id: UUID = UUID(), name: String, vector: [Double]) {
        var volumes: [Sound: Double] = [:]
        for (i, s) in Sound.allCases.enumerated() where i < vector.count { volumes[s] = vector[i] }
        self.init(id: id, name: name, volumes: volumes)
    }

    func volume(_ sound: Sound) -> Double { levels[sound.rawValue] ?? 0 }

    var vector: [Double] { Sound.allCases.map(volume) }

    /// The sounds in this mix, loudest first.
    var sounds: [Sound] { Sound.allCases.filter { volume($0) > 0 }.sorted { volume($0) > volume($1) } }

    var summary: String { sounds.isEmpty ? "Silence" : sounds.map(\.shortName).joined(separator: ", ") }

    var symbol: String { sounds.first?.symbol ?? "speaker.slash" }

    func matches(_ volumes: [Double]) -> Bool {
        zip(vector, volumes).allSatisfy { abs($0 - $1) < 0.005 } && volumes.count == vector.count
    }

    static let presets: [Mix] = [
        Mix(id: UUID(uuidString: "6A7BD900-0000-4000-8000-000000000001")!, name: "Deep Focus", volumes: [.pink: 0.55, .brown: 0.4]),
        Mix(id: UUID(uuidString: "6A7BD900-0000-4000-8000-000000000002")!, name: "Rainy Night", volumes: [.rain: 0.7, .brown: 0.35]),
        Mix(id: UUID(uuidString: "6A7BD900-0000-4000-8000-000000000003")!, name: "Seaside", volumes: [.waves: 0.75, .pink: 0.2]),
        Mix(id: UUID(uuidString: "6A7BD900-0000-4000-8000-000000000004")!, name: "Bedroom Fan", volumes: [.fan: 0.7, .brown: 0.25]),
        Mix(id: UUID(uuidString: "6A7BD900-0000-4000-8000-000000000005")!, name: "Pure White", volumes: [.white: 0.5]),
    ]
}

/// What Hum remembers between launches.
struct SavedState: Codable, Equatable {
    var volumes: [Double]
    var master: Double
    var mixes: [Mix]
    var sleepMinutes: Int?
}

enum Sleep {
    static let choices = [15, 30, 45, 60, 90, 120, 180]

    /// Seconds before the end over which the sound fades away: the last 3 minutes, or the second half of a short timer.
    static func fadeWindow(total: TimeInterval) -> TimeInterval { min(180, total / 2) }

    static func format(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func label(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

enum Level {
    static func decibels(_ rms: Float) -> Double { rms <= 0.001 ? -60 : max(-60, 20 * log10(Double(rms))) }
    static func meter(_ db: Double) -> Double { min(1, max(0, (db + 60) / 60)) }
}

/// The output level, polled from the audio thread. Its own object so only the visualiser redraws 30 times a second.
@MainActor
final class Meter: ObservableObject {
    @Published var level: Double = 0
    @Published var decibels: Double = -60
}

@MainActor
final class HumModel: ObservableObject {
    @Published var volumes: [Double] = Array(repeating: 0, count: Sound.allCases.count) {
        didSet { pushVolumes(); scheduleSave() }
    }
    @Published var master: Double = 0.8 {
        didSet { engine?.core.setMaster(master); scheduleSave() }
    }
    @Published private(set) var isPlaying = false
    @Published var mixes: [Mix] = [] { didSet { scheduleSave() } }
    @Published var selection: UUID?
    @Published var sleepMinutes: Int?
    @Published private(set) var sleepEnd: Date?
    @Published private(set) var now = Date()
    @Published var showingSave = false
    @Published var renaming: Mix?

    let meter = Meter()
    let isDemo: Bool
    private var lastVolumes: [Double] = Array(repeating: 0, count: Sound.allCases.count)
    private var engine: HumEngine?
    private var ticker: Timer?
    private var meterTimer: Timer?
    private var saveWork: DispatchWorkItem?
    private var pauseWork: DispatchWorkItem?
    private var sleepFading = false

    static let fadeIn = 1.5
    static let fadeOut = 1.2

    init(demo: Bool = false) {
        isDemo = demo
        guard !demo, let saved = Storage.load(SavedState.self, app: "Hum", file: "state.json") else { return }
        if saved.volumes.count == Sound.allCases.count { volumes = saved.volumes }
        master = saved.master
        mixes = saved.mixes
        selection = matchingMix?.id
    }

    /// The window's demo state for the website screenshot: a rainy night with a sleep timer running.
    static var demo: HumModel {
        let m = HumModel(demo: true)
        let train = Mix(name: "Night Train", volumes: [.rain: 0.7, .brown: 0.35, .pink: 0.25])
        m.mixes = [Mix(name: "Library", volumes: [.pink: 0.35, .fan: 0.3]), train, Mix(name: "Harbour", volumes: [.waves: 0.6, .fan: 0.2])]
        m.apply(train)
        m.master = 0.72
        m.isPlaying = true
        m.sleepMinutes = 30
        m.sleepEnd = m.now.addingTimeInterval(23 * 60 + 41)
        m.meter.level = 0.62
        m.meter.decibels = -22.8
        return m
    }

    var allSounds: [Mix] { Mix.presets + mixes }

    var matchingMix: Mix? { allSounds.first { $0.matches(volumes) } }

    var activeCount: Int { volumes.filter { $0 > 0 }.count }

    var title: String { matchingMix?.name ?? (activeCount == 0 ? "Silence" : "Your Mix") }

    var subtitle: String {
        if activeCount == 0 { return "Turn on a sound below to begin" }
        let names = Sound.allCases.filter { volumes[$0.index] > 0 }.sorted { volumes[$0.index] > volumes[$1.index] }.map(\.shortName)
        return names.joined(separator: ", ")
    }

    var sleepRemaining: TimeInterval? { sleepEnd.map { max(0, $0.timeIntervalSince(now)) } }

    // MARK: Volumes

    func volume(_ sound: Sound) -> Double { volumes[sound.index] }

    func binding(_ sound: Sound) -> Binding<Double> {
        Binding(get: { self.volumes[sound.index] }, set: { self.setVolume($0, for: sound) })
    }

    func setVolume(_ value: Double, for sound: Sound) {
        volumes[sound.index] = value
        if value > 0 { lastVolumes[sound.index] = value }
        syncSelection()
        if value > 0 && !isPlaying && !isDemo { play() }
    }

    /// Clicking a sound switches it off, or back on at the volume it had.
    func toggle(_ sound: Sound) {
        let i = sound.index
        if volumes[i] > 0 {
            lastVolumes[i] = volumes[i]
            volumes[i] = 0
        } else {
            volumes[i] = lastVolumes[i] > 0 ? lastVolumes[i] : Mix.defaultVolume
            if !isPlaying && !isDemo { play() }
        }
        syncSelection()
    }

    func apply(_ mix: Mix) {
        for (i, v) in mix.vector.enumerated() where v > 0 { lastVolumes[i] = v }
        volumes = mix.vector
        selection = mix.id
        if !isPlaying && !isDemo { play() }
    }

    func adjustMaster(by delta: Double) {
        master = min(1, max(0, (master + delta) * 100).rounded() / 100)
    }

    func clearMix() {
        for (i, v) in volumes.enumerated() where v > 0 { lastVolumes[i] = v }
        volumes = Array(repeating: 0, count: Sound.allCases.count)
        syncSelection()
    }

    private func syncSelection() {
        if let id = selection, let mix = allSounds.first(where: { $0.id == id }), mix.matches(volumes) { return }
        selection = matchingMix?.id
    }

    // MARK: Saved mixes

    func nextMixName() -> String {
        var n = mixes.count + 1
        while mixes.contains(where: { $0.name == "Mix \(n)" }) { n += 1 }
        return "Mix \(n)"
    }

    func saveCurrent(as name: String, undo: UndoManager?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mix = Mix(name: trimmed.isEmpty ? nextMixName() : trimmed, vector: volumes)
        mixes.append(mix)
        selection = mix.id
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(mix, undo: undo) }
        }
        undo?.setActionName("Save Mix")
    }

    func delete(_ mix: Mix, undo: UndoManager?) {
        guard let i = mixes.firstIndex(where: { $0.id == mix.id }) else { return }
        mixes.remove(at: i)
        if selection == mix.id { selection = matchingMix?.id }
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.mixes.insert(mix, at: min(i, model.mixes.count))
                model.registerRedoDelete(mix, undo: undo)
            }
        }
        undo?.setActionName("Delete Mix")
    }

    private func registerRedoDelete(_ mix: Mix, undo: UndoManager?) {
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(mix, undo: undo) }
        }
        undo?.setActionName("Delete Mix")
    }

    func rename(_ mix: Mix, to name: String, undo: UndoManager?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = mixes.firstIndex(where: { $0.id == mix.id }), mixes[i].name != trimmed else { return }
        let old = mixes[i].name
        mixes[i].name = trimmed
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if let m = model.mixes.first(where: { $0.id == mix.id }) { model.rename(m, to: old, undo: undo) }
            }
        }
        undo?.setActionName("Rename Mix")
    }

    /// Replaces a saved mix's volumes with the current ones.
    func update(_ mix: Mix) {
        guard let i = mixes.firstIndex(where: { $0.id == mix.id }) else { return }
        mixes[i] = Mix(id: mix.id, name: mix.name, vector: volumes)
        selection = mix.id
    }

    // MARK: Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isDemo else { return }
        if activeCount == 0 {
            volumes = Mix.presets[0].vector
            selection = Mix.presets[0].id
        }
        pauseWork?.cancel()
        let engine = self.engine ?? HumEngine()
        self.engine = engine
        pushVolumes()
        engine.core.setMaster(master)
        engine.start()
        engine.core.fade(to: 1, over: Self.fadeIn)
        isPlaying = true
        sleepFading = false
        if let minutes = sleepMinutes, sleepEnd == nil { sleepEnd = Date().addingTimeInterval(TimeInterval(minutes * 60)) }
        startTimers()
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        sleepEnd = nil
        sleepFading = false
        engine?.core.fade(to: 0, over: Self.fadeOut)
        // Stop the engine once the fade has finished, so a paused Hum costs nothing.
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine?.pause()
            self.stopTimers()
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeOut + 0.25, execute: work)
    }

    /// Sets or clears the sleep timer. Setting one starts playback, since that is what it is for.
    func setSleep(minutes: Int?) {
        sleepMinutes = minutes
        sleepEnd = nil
        if sleepFading {
            sleepFading = false
            if isPlaying { engine?.core.fade(to: 1, over: 2) }
        }
        guard let minutes else { return }
        if isPlaying {
            sleepEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            play()
        }
    }

    private func startTimers() {
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        if meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.readMeter() }
            }
        }
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        meterTimer?.invalidate()
        meterTimer = nil
        meter.level = 0
        meter.decibels = -60
    }

    private func tick() {
        now = Date()
        guard isPlaying, let end = sleepEnd, let minutes = sleepMinutes else { return }
        let remaining = end.timeIntervalSince(now)
        if remaining <= 0 {
            pause()
            return
        }
        if !sleepFading && remaining <= Sleep.fadeWindow(total: TimeInterval(minutes * 60)) {
            sleepFading = true
            engine?.core.fade(to: 0, over: remaining)
        }
    }

    private func readMeter() {
        guard let core = engine?.core else { return }
        let db = Level.decibels(core.level)
        // Fast attack, slow release, like a real meter.
        let target = Level.meter(db)
        let smoothed = target > meter.level ? meter.level + (target - meter.level) * 0.5 : meter.level + (target - meter.level) * 0.12
        meter.level = smoothed
        meter.decibels = db
    }

    private func pushVolumes() {
        guard let core = engine?.core else { return }
        for s in Sound.allCases { core.setVolume(volumes[s.index], for: s) }
    }

    private func scheduleSave() {
        guard !isDemo, !Desktop.isSnapshot else { return }
        saveWork?.cancel()
        let state = SavedState(volumes: volumes, master: master, mixes: mixes, sleepMinutes: nil)
        let work = DispatchWorkItem { Storage.save(state, app: "Hum", file: "state.json") }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
