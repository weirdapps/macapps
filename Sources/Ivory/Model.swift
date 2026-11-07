import AppKit
import Carbon.HIToolbox
import Foundation
import Kit
import UniformTypeIdentifiers

// MARK: - Sounds and notes

enum Sound: String, CaseIterable, Codable, Identifiable {
    case piano, electric, organ, pad

    var id: String { rawValue }

    var title: String {
        switch self {
        case .piano: "Piano"
        case .electric: "Electric Piano"
        case .organ: "Organ"
        case .pad: "Soft Pad"
        }
    }

    var shortTitle: String {
        switch self {
        case .piano: "Piano"
        case .electric: "Electric"
        case .organ: "Organ"
        case .pad: "Pad"
        }
    }

    var symbol: String {
        switch self {
        case .piano: "pianokeys"
        case .electric: "bolt.fill"
        case .organ: "building.columns.fill"
        case .pad: "cloud.fill"
        }
    }

    /// The General MIDI program the exported file asks for.
    var program: UInt8 {
        switch self {
        case .piano: 0     // Acoustic Grand Piano
        case .electric: 4  // Electric Piano 1
        case .organ: 16    // Drawbar Organ
        case .pad: 89      // Pad 2 (warm)
        }
    }
}

enum Note {
    static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

    static func name(_ note: Int) -> String { names[((note % 12) + 12) % 12] }
    /// Scientific pitch notation: MIDI 60 is C4, middle C.
    static func fullName(_ note: Int) -> String { name(note) + "\(note / 12 - 1)" }
    static func isBlack(_ note: Int) -> Bool { [1, 3, 6, 8, 10].contains(((note % 12) + 12) % 12) }
    static func frequency(_ note: Int) -> Double { 440 * pow(2, Double(note - 69) / 12) }
}

/// Musical typing: the A row plays the white keys, the W row the black keys above them, like GarageBand.
/// Key codes are positions, so the mapping holds on any keyboard layout.
enum KeyMap {
    static let rows: [(code: Int, label: String)] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_W, "W"), (kVK_ANSI_S, "S"), (kVK_ANSI_E, "E"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_F, "F"), (kVK_ANSI_T, "T"), (kVK_ANSI_G, "G"), (kVK_ANSI_Y, "Y"), (kVK_ANSI_H, "H"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_O, "O"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_P, "P"), (kVK_ANSI_Semicolon, ";"), (kVK_ANSI_Quote, "'"), (kVK_ANSI_RightBracket, "]"),
    ]
    static let octaveDown = UInt16(kVK_ANSI_Z)
    static let octaveUp = UInt16(kVK_ANSI_X)
    static let sustain = UInt16(kVK_Space)

    /// Semitones above the lowest C on screen for a key code, or nil for keys that play nothing.
    static func offset(for code: UInt16) -> Int? {
        rows.firstIndex { $0.code == Int(code) }
    }

    /// The letter printed on the on-screen key `offset` semitones above the lowest C.
    static func label(forOffset offset: Int) -> String? {
        rows.indices.contains(offset) ? rows[offset].label : nil
    }
}

// MARK: - Keyboard layout

/// Geometry of the two-octave keyboard: 15 white keys from C to C, black keys on top. Pure, so hit testing is testable.
struct PianoLayout {
    struct Key: Identifiable {
        let note: Int
        let rect: CGRect
        let isBlack: Bool
        var id: Int { note }
    }

    static let span = 24
    let lowest: Int
    let size: CGSize
    let keys: [Key]

    init(lowest: Int, size: CGSize) {
        self.lowest = lowest
        self.size = size
        let whiteCount = (0...Self.span).filter { !Note.isBlack(lowest + $0) }.count
        let whiteWidth = size.width / CGFloat(whiteCount)
        let blackWidth = whiteWidth * 0.6
        let blackHeight = size.height * 0.62
        var keys: [Key] = []
        var whiteIndex = 0
        for offset in 0...Self.span {
            let note = lowest + offset
            if Note.isBlack(note) {
                // Sits over the line between the previous white key and the next, nudged like a real keyboard.
                let nudge: CGFloat = switch ((note % 12) + 12) % 12 {
                case 1, 6: -0.08
                case 3, 10: 0.08
                default: 0
                }
                let x = CGFloat(whiteIndex) * whiteWidth - blackWidth / 2 + nudge * blackWidth
                keys.append(Key(note: note, rect: CGRect(x: x, y: 0, width: blackWidth, height: blackHeight), isBlack: true))
            } else {
                keys.append(Key(note: note, rect: CGRect(x: CGFloat(whiteIndex) * whiteWidth, y: 0, width: whiteWidth,
                                                         height: size.height), isBlack: false))
                whiteIndex += 1
            }
        }
        self.keys = keys
    }

    var whiteKeys: [Key] { keys.filter { !$0.isBlack } }
    var blackKeys: [Key] { keys.filter(\.isBlack) }

    /// The key under a point (y grows downwards), black keys first because they lie on top.
    func key(at point: CGPoint) -> Key? {
        if let black = blackKeys.first(where: { $0.rect.contains(point) }) { return black }
        return whiteKeys.first { $0.rect.contains(point) }
    }

    /// Velocity from where the key is struck: nearer the front plays louder.
    func velocity(for key: Key, at point: CGPoint) -> UInt8 {
        let depth = max(0, min(1, (point.y - key.rect.minY) / max(1, key.rect.height)))
        return UInt8(56 + 70 * depth)
    }
}

// MARK: - Takes

struct TakeEvent: Codable, Equatable {
    enum Kind: String, Codable { case on, off, sustainOn, sustainOff }
    var time: Double
    var kind: Kind
    var note: UInt8 = 0
    var velocity: UInt8 = 0
}

struct Take: Codable, Equatable {
    var events: [TakeEvent]
    var duration: Double
    var sound: Sound

    var noteCount: Int { events.filter { $0.kind == .on }.count }

    /// The take with times that cannot hurt playback or export: finite, not negative, in order, inside the duration.
    /// A take file that was edited or damaged by hand still loads.
    var sanitized: Take {
        let limit = 24 * 3600.0
        let kept = events.filter { $0.time.isFinite && $0.time >= 0 && $0.time <= limit }
            .enumerated().sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)
        let last = kept.last?.time ?? 0
        let length = duration.isFinite && duration >= last ? min(duration, limit) : last
        return Take(events: kept, duration: length, sound: sound)
    }

    /// Notes as bars for the take overview: (note, start, end).
    var bars: [(note: Int, start: Double, end: Double)] {
        var open: [UInt8: [Double]] = [:]
        var bars: [(note: Int, start: Double, end: Double)] = []
        for event in events {
            switch event.kind {
            case .on: open[event.note, default: []].append(event.time)
            case .off:
                if var starts = open[event.note], !starts.isEmpty {
                    bars.append((Int(event.note), starts.removeFirst(), event.time))
                    open[event.note] = starts
                }
            default: break
            }
        }
        for (note, starts) in open { for start in starts { bars.append((Int(note), start, duration)) } }
        return bars.sorted { $0.start < $1.start }
    }
}

enum TimeText {
    /// "0:12.4": minutes, seconds and tenths.
    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

// MARK: - Standard MIDI File

/// Writes a take as a format 0 Standard MIDI File: one track, 480 ticks per quarter note at 120 bpm.
enum MIDIFile {
    static let ticksPerQuarter: UInt16 = 480
    static let microsecondsPerQuarter: UInt32 = 500_000
    static var ticksPerSecond: Double { Double(ticksPerQuarter) * 1_000_000 / Double(microsecondsPerQuarter) }

    /// Variable-length quantity: 7 bits per byte, most significant first, high bit set on all but the last.
    static func vlq(_ value: UInt32) -> [UInt8] {
        var value = value & 0x0FFF_FFFF
        var bytes = [UInt8(value & 0x7F)]
        value >>= 7
        while value > 0 {
            bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
            value >>= 7
        }
        return bytes
    }

    /// The largest delta a variable-length quantity can carry, about 77 hours at 960 ticks a second.
    static let maxTicks: UInt32 = 0x0FFF_FFFF

    /// Seconds to ticks, clamped so negative, infinite or absurdly long times can never trap.
    static func ticks(_ seconds: Double) -> UInt32 {
        let t = seconds * ticksPerSecond
        guard t.isFinite, t > 0 else { return t == .infinity ? maxTicks : 0 }
        return UInt32(min(Double(maxTicks), t.rounded()))
    }

    static func data(for take: Take, name: String = "Ivory") -> Data {
        var track: [UInt8] = []
        let title = Array(name.utf8.prefix(120))
        track += [0x00, 0xFF, 0x03] + vlq(UInt32(title.count)) + title
        let tempo = microsecondsPerQuarter
        track += [0x00, 0xFF, 0x51, 0x03, UInt8((tempo >> 16) & 0xFF), UInt8((tempo >> 8) & 0xFF), UInt8(tempo & 0xFF)]
        track += [0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]
        track += [0x00, 0xC0, take.sound.program & 0x7F]

        // Stable order: events at the same tick keep the order they were played in.
        let ordered = take.events.enumerated().sorted { a, b in
            let ta = ticks(a.element.time), tb = ticks(b.element.time)
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
        var last: UInt32 = 0
        for event in ordered {
            let tick = ticks(event.time)
            track += vlq(tick - last)
            last = tick
            let note = event.note & 0x7F
            switch event.kind {
            case .on: track += [0x90, note, max(1, min(127, event.velocity))]
            case .off: track += [0x80, note, 0x40]
            case .sustainOn: track += [0xB0, 0x40, 0x7F]
            case .sustainOff: track += [0xB0, 0x40, 0x00]
            }
        }
        let end = max(last, ticks(take.duration))
        track += vlq(end - last) + [0xFF, 0x2F, 0x00]

        var file: [UInt8] = Array("MThd".utf8) + be32(6) + be16(0) + be16(1) + be16(ticksPerQuarter)
        file += Array("MTrk".utf8) + be32(UInt32(track.count)) + track
        return Data(file)
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
}

// MARK: - Model

@MainActor
final class PianoModel: ObservableObject {
    static let octaves = 1...6

    @Published var sound: Sound { didSet { persist() } }
    @Published var volume: Double { didSet { synth?.setGain(Float(volume)); persist() } }
    @Published private(set) var baseOctave: Int { didSet { persist() } }
    @Published var showNoteNames: Bool { didSet { persist() } }
    @Published var showKeyLabels: Bool { didSet { persist() } }
    @Published private(set) var pressed: [Int: Int] = [:]
    @Published var sustainLatched = false { didSet { updateSustain() } }
    @Published private(set) var sustainKey = false
    @Published private(set) var take: Take?
    @Published private(set) var recordStart: TimeInterval?
    @Published private(set) var playStart: TimeInterval?
    @Published private(set) var exportedURL: URL?
    @Published private(set) var focusRequest = 0
    /// A fixed playhead for the website screenshot.
    var demoPlayhead: Double?

    let synth: Synth?
    private let persists: Bool
    weak var undoManager: UndoManager?
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private var keyNotes: [UInt16: Int] = [:]
    private var mouseNote: Int?
    private var recorded: [TakeEvent] = []
    private var playbackNotes: [Int: Int] = [:]
    private var playbackSustain = false
    private var playbackGeneration = 0
    private var exportToken = 0

    init(synth: Synth?, persists: Bool) {
        self.synth = synth
        self.persists = persists
        let d = UserDefaults.standard
        sound = persists ? Sound(rawValue: d.string(forKey: "sound") ?? "") ?? .piano : .piano
        volume = persists && d.object(forKey: "volume") != nil ? d.double(forKey: "volume") : 0.8
        let octave = persists && d.object(forKey: "octave") != nil ? d.integer(forKey: "octave") : 4
        baseOctave = min(max(octave, Self.octaves.lowerBound), Self.octaves.upperBound)
        showNoteNames = persists ? d.object(forKey: "noteNames") as? Bool ?? true : true
        showKeyLabels = persists ? d.object(forKey: "keyLabels") as? Bool ?? true : true
        if persists, let saved = Storage.load(Take.self, app: "Ivory", file: "take.json")?.sanitized, saved.noteCount > 0 {
            take = saved
        }
        synth?.setGain(Float(volume))
    }

    static func live() -> PianoModel { PianoModel(synth: Synth(), persists: true) }

    static var demo: PianoModel {
        let model = PianoModel(synth: nil, persists: false)
        // A C major seventh voicing with the melody note on top.
        for note in [60, 64, 67, 71, 76] { model.pressed[note] = 1 }
        model.take = Take.demo
        model.playStart = 0
        model.demoPlayhead = 5.2
        model.sustainLatched = true
        return model
    }

    private func persist() {
        guard persists else { return }
        let d = UserDefaults.standard
        d.set(sound.rawValue, forKey: "sound")
        d.set(volume, forKey: "volume")
        d.set(baseOctave, forKey: "octave")
        d.set(showNoteNames, forKey: "noteNames")
        d.set(showKeyLabels, forKey: "keyLabels")
    }

    // MARK: Derived state

    var lowestNote: Int { (baseOctave + 1) * 12 }
    var rangeText: String { "\(Note.fullName(lowestNote)) to \(Note.fullName(lowestNote + PianoLayout.span))" }
    var sustain: Bool { sustainKey || sustainLatched || playbackSustain }
    var isRecording: Bool { recordStart != nil }
    var isPlaying: Bool { playStart != nil }
    func isDown(_ note: Int) -> Bool { (pressed[note] ?? 0) > 0 }

    func requestFocus() { focusRequest &+= 1 }

    // MARK: Keyboard

    /// Handles a key press from the window; returns false for keys the piano does not use.
    @discardableResult
    func keyDown(_ code: UInt16, isRepeat: Bool = false) -> Bool {
        if code == KeyMap.octaveDown { if !isRepeat { shiftOctave(-1) }; return true }
        if code == KeyMap.octaveUp { if !isRepeat { shiftOctave(1) }; return true }
        if code == KeyMap.sustain {
            if !sustainKey { sustainKey = true; updateSustain() }
            return true
        }
        guard let offset = KeyMap.offset(for: code) else { return false }
        guard keyNotes[code] == nil, !isRepeat else { return true }
        let note = lowestNote + offset
        guard note <= 127 else { return true }
        keyNotes[code] = note
        press(note, velocity: 100)
        return true
    }

    @discardableResult
    func keyUp(_ code: UInt16) -> Bool {
        if code == KeyMap.sustain {
            if sustainKey { sustainKey = false; updateSustain() }
            return true
        }
        if code == KeyMap.octaveDown || code == KeyMap.octaveUp { return true }
        guard KeyMap.offset(for: code) != nil else { return false }
        if let note = keyNotes.removeValue(forKey: code) { release(note) }
        return true
    }

    /// Lets go of everything the keyboard and mouse hold, so no note sticks when the window loses focus.
    func releaseHeldKeys() {
        for note in keyNotes.values { release(note) }
        keyNotes.removeAll()
        mouseUp()
        if sustainKey { sustainKey = false; updateSustain() }
    }

    func shiftOctave(_ delta: Int) {
        let next = min(max(baseOctave + delta, Self.octaves.lowerBound), Self.octaves.upperBound)
        guard next != baseOctave else { return }
        baseOctave = next
    }

    // MARK: Mouse

    func mouseDown(note: Int, velocity: UInt8) {
        guard mouseNote != note else { return }
        mouseUp()
        mouseNote = note
        press(note, velocity: velocity)
    }

    func mouseUp() {
        if let note = mouseNote { release(note) }
        mouseNote = nil
    }

    // MARK: Notes

    private func press(_ note: Int, velocity: UInt8) {
        pressed[note, default: 0] += 1
        synth?.noteOn(note, velocity: velocity, sound: sound)
        if let start = recordStart {
            recorded.append(TakeEvent(time: clock() - start, kind: .on, note: UInt8(note), velocity: velocity))
        }
    }

    private func release(_ note: Int) {
        guard let count = pressed[note] else { return }
        if count <= 1 {
            pressed[note] = nil
            synth?.noteOff(note)
        } else {
            pressed[note] = count - 1
        }
        if let start = recordStart {
            recorded.append(TakeEvent(time: clock() - start, kind: .off, note: UInt8(note)))
        }
    }

    private var lastSustain = false
    private func updateSustain() {
        let now = sustain
        guard now != lastSustain else { return }
        lastSustain = now
        synth?.setSustain(now)
        if let start = recordStart, !playbackSustain {
            recorded.append(TakeEvent(time: clock() - start, kind: now ? .sustainOn : .sustainOff))
        }
    }

    // MARK: Recording

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        stopPlayback()
        recorded = []
        recordStart = clock()
        // Notes already held when recording starts belong to the take.
        for note in Set(keyNotes.values).union(mouseNote.map { [$0] } ?? []).sorted() {
            recorded.append(TakeEvent(time: 0, kind: .on, note: UInt8(note), velocity: 100))
        }
        if sustainKey || sustainLatched { recorded.append(TakeEvent(time: 0, kind: .sustainOn)) }
    }

    func stopRecording() {
        guard let start = recordStart else { return }
        let end = clock() - start
        // Close what is still sounding so every note on has its note off.
        var open: [UInt8: Int] = [:]
        var sustained = false
        for event in recorded {
            switch event.kind {
            case .on: open[event.note, default: 0] += 1
            case .off: open[event.note, default: 0] -= 1
            case .sustainOn: sustained = true
            case .sustainOff: sustained = false
            }
        }
        for (note, count) in open.sorted(by: { $0.key < $1.key }) where count > 0 {
            for _ in 0..<count { recorded.append(TakeEvent(time: end, kind: .off, note: note)) }
        }
        if sustained { recorded.append(TakeEvent(time: end, kind: .sustainOff)) }
        recordStart = nil
        guard recorded.contains(where: { $0.kind == .on }) else { recorded = []; return }
        replaceTake(with: Take(events: recorded, duration: end, sound: sound), actionName: "Record Take")
        recorded = []
    }

    func clearTake() {
        guard take != nil else { return }
        stopPlayback()
        replaceTake(with: nil, actionName: "Clear Take")
    }

    private func replaceTake(with new: Take?, actionName: String) {
        let old = take
        take = new
        if persists {
            if let new { Storage.save(new, app: "Ivory", file: "take.json") } else {
                try? FileManager.default.removeItem(at: Storage.url(app: "Ivory", file: "take.json"))
            }
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceTake(with: old, actionName: actionName) }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: Playback

    func togglePlayback() { isPlaying ? stopPlayback() : play() }

    func play() {
        guard let take, !isRecording else { return }
        stopPlayback()
        playbackGeneration += 1
        let generation = playbackGeneration
        playStart = clock()
        let origin = DispatchTime.now()
        for event in take.events {
            DispatchQueue.main.asyncAfter(deadline: origin + event.time) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.apply(event)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: origin + take.duration + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.playbackGeneration == generation else { return }
                self.stopPlayback()
            }
        }
    }

    func stopPlayback() {
        playbackGeneration += 1
        playStart = nil
        for (note, count) in playbackNotes { for _ in 0..<count { releasePlayback(note) } }
        playbackNotes.removeAll()
        if playbackSustain { playbackSustain = false; updateSustain() }
    }

    private func apply(_ event: TakeEvent) {
        let note = Int(event.note)
        switch event.kind {
        case .on:
            playbackNotes[note, default: 0] += 1
            pressed[note, default: 0] += 1
            synth?.noteOn(note, velocity: event.velocity, sound: sound)
        case .off:
            guard let count = playbackNotes[note], count > 0 else { return }
            playbackNotes[note] = count > 1 ? count - 1 : nil
            releasePlayback(note)
        case .sustainOn: playbackSustain = true; updateSustain()
        case .sustainOff: playbackSustain = false; updateSustain()
        }
    }

    private func releasePlayback(_ note: Int) {
        guard let count = pressed[note] else { return }
        if count <= 1 { pressed[note] = nil; synth?.noteOff(note) } else { pressed[note] = count - 1 }
    }

    /// Seconds into the current recording or playback.
    func elapsed(at now: TimeInterval) -> Double {
        if let demoPlayhead { return demoPlayhead }
        if let recordStart { return now - recordStart }
        if let playStart { return now - playStart }
        return 0
    }

    // MARK: Export

    static func suggestedFileName(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm"
        return "Ivory Take \(f.string(from: date)).mid"
    }

    func export() {
        guard let take else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid") ?? .midi]
        panel.nameFieldStringValue = Self.suggestedFileName()
        panel.canCreateDirectories = true
        panel.message = "Export the take as a Standard MIDI File for GarageBand, Logic or any DAW."
        guard panel.runModal() == .OK, let url = panel.url else { requestFocus(); return }
        do {
            try MIDIFile.data(for: take).write(to: url, options: .atomic)
            exportedURL = url
            exportToken += 1
            let token = exportToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                MainActor.assumeIsolated {
                    if self?.exportToken == token { self?.exportedURL = nil }
                }
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
        requestFocus()
    }

    func dismissExport() { exportedURL = nil }
}

extension Take {
    /// The opening of a little C major tune, for the website screenshot.
    static var demo: Take {
        var events: [TakeEvent] = []
        func note(_ n: UInt8, _ start: Double, _ length: Double, _ velocity: UInt8 = 92) {
            events.append(TakeEvent(time: start, kind: .on, note: n, velocity: velocity))
            events.append(TakeEvent(time: start + length, kind: .off, note: n))
        }
        let melody: [(UInt8, Double, Double)] = [
            (72, 0, 0.45), (76, 0.5, 0.45), (79, 1, 0.9), (77, 2, 0.45), (76, 2.5, 0.45), (74, 3, 0.9),
            (72, 4, 0.45), (74, 4.5, 0.45), (76, 5, 0.45), (79, 5.5, 0.45), (81, 6, 1.4), (79, 7.5, 0.45),
            (77, 8, 0.45), (76, 8.5, 0.45), (74, 9, 0.45), (71, 9.5, 0.45), (72, 10, 2),
        ]
        for (n, s, l) in melody { note(n, s, l) }
        let chords: [([UInt8], Double)] = [([48, 55, 64], 0), ([53, 57, 65], 2), ([55, 59, 62], 4), ([57, 60, 64], 6),
                                           ([53, 57, 60], 8), ([48, 55, 64], 10)]
        for (notes, s) in chords { for n in notes { note(n, s, 1.9, 70) } }
        events.sort { $0.time < $1.time }
        return Take(events: events, duration: 12.4, sound: .piano)
    }
}
