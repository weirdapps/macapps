import Carbon.HIToolbox
import Foundation

/// `Ivory --selftest`: checks the MIDI writer, the key mapping, the keyboard layout, the model and the synth offline.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func run() -> Int32 {
        midi()
        keys()
        layout()
        model()
        synth()
        print(failures == 0 ? "PASS: all \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: MIDI

    private static func midi() {
        let vlqCases: [(UInt32, [UInt8])] = [
            (0, [0x00]), (0x40, [0x40]), (0x7F, [0x7F]), (0x80, [0x81, 0x00]), (0x2000, [0xC0, 0x00]),
            (0x3FFF, [0xFF, 0x7F]), (0x4000, [0x81, 0x80, 0x00]), (0x1F_FFFF, [0xFF, 0xFF, 0x7F]),
            (0x0FFF_FFFF, [0xFF, 0xFF, 0xFF, 0x7F]),
        ]
        for (value, bytes) in vlqCases { check(MIDIFile.vlq(value) == bytes, "VLQ of \(value)") }
        check(MIDIFile.ticks(0.5) == 480 && MIDIFile.ticks(1) == 960, "960 ticks per second at 120 bpm")

        // Middle C held for half a second, then the file ends a quarter second later.
        let take = Take(events: [TakeEvent(time: 0, kind: .on, note: 60, velocity: 100),
                                 TakeEvent(time: 0.5, kind: .off, note: 60)], duration: 0.75, sound: .piano)
        let bytes = [UInt8](MIDIFile.data(for: take, name: "T"))
        let expected: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0, // MThd, format 0, 1 track, 480 ppq
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 37,                         // MTrk and its length
            0x00, 0xFF, 0x03, 0x01, 0x54,                                // Track name "T"
            0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20,                    // Tempo 500000 us per quarter
            0x00, 0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,              // 4/4
            0x00, 0xC0, 0x00,                                            // Program 0
            0x00, 0x90, 60, 100,                                         // Note on
            0x83, 0x60, 0x80, 60, 0x40,                                  // 480 ticks later, note off
            0x81, 0x70, 0xFF, 0x2F, 0x00,                                // 240 ticks later, end of track
        ]
        check(bytes == expected, "exact bytes of a one-note file")
        if bytes != expected { print("  got \(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))") }

        let demo = [UInt8](MIDIFile.data(for: Take.demo))
        check(Array(demo.prefix(4)) == Array("MThd".utf8), "header chunk id")
        let trackLength = demo.count >= 22 ? Int(demo[18]) << 24 | Int(demo[19]) << 16 | Int(demo[20]) << 8 | Int(demo[21]) : -1
        check(trackLength == demo.count - 22, "track length matches the bytes that follow")
        check(Array(demo.suffix(3)) == [0xFF, 0x2F, 0x00], "file ends with end of track")
        check(parseNoteOns(demo) == Take.demo.noteCount, "every note on is written")

        let organ = Take(events: [TakeEvent(time: 0, kind: .sustainOn), TakeEvent(time: 0, kind: .on, note: 64, velocity: 0),
                                  TakeEvent(time: 0, kind: .off, note: 64), TakeEvent(time: 0.1, kind: .sustainOff)],
                         duration: 0.1, sound: .organ)
        let o = [UInt8](MIDIFile.data(for: organ, name: ""))
        check(contains(o, [0x00, 0xC0, 16]), "organ asks for General MIDI program 16")
        check(contains(o, [0x00, 0xB0, 0x40, 0x7F]), "sustain pedal down is CC 64")
        check(contains(o, [0x00, 0x90, 64, 1, 0x00, 0x80, 64]), "same-tick events keep their order and velocity 0 becomes 1")
        check(contains(o, [0x60, 0xB0, 0x40, 0x00]), "sustain pedal up 96 ticks later")

        let data = try? JSONEncoder().encode(Take.demo)
        check(data.flatMap { try? JSONDecoder().decode(Take.self, from: $0) } == Take.demo, "take survives a JSON round trip")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ivory-selftest-\(UUID().uuidString).mid")
        try? MIDIFile.data(for: take).write(to: url)
        check((try? Data(contentsOf: url)) == MIDIFile.data(for: take), "MIDI file writes and reads back")
        try? FileManager.default.removeItem(at: url)
        check(PianoModel.suggestedFileName(date: Date(timeIntervalSince1970: 0)).hasSuffix(".mid"), "export file name ends in .mid")
    }

    private static func contains(_ bytes: [UInt8], _ run: [UInt8]) -> Bool {
        guard bytes.count >= run.count else { return false }
        return (0...(bytes.count - run.count)).contains { Array(bytes[$0..<($0 + run.count)]) == run }
    }

    /// Walks the single track and counts note ons with a nonzero velocity.
    private static func parseNoteOns(_ bytes: [UInt8]) -> Int {
        var i = 22, count = 0
        func readVLQ() -> Int {
            var value = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                value = value << 7 | Int(b & 0x7F)
                if b & 0x80 == 0 { break }
            }
            return value
        }
        while i < bytes.count {
            _ = readVLQ()
            guard i < bytes.count else { break }
            let status = bytes[i]
            switch status {
            case 0xFF:
                i += 2
                let length = readVLQ()
                i += length
            case 0x90...0x9F:
                if bytes[i + 2] > 0 { count += 1 }
                i += 3
            case 0x80...0x8F, 0xB0...0xBF: i += 3
            case 0xC0...0xCF: i += 2
            default: return -1
            }
        }
        return count
    }

    // MARK: Keys

    private static func keys() {
        check(KeyMap.offset(for: UInt16(kVK_ANSI_A)) == 0, "A plays C")
        check(KeyMap.offset(for: UInt16(kVK_ANSI_W)) == 1, "W plays C sharp")
        check(KeyMap.offset(for: UInt16(kVK_ANSI_K)) == 12, "K plays the next C")
        check(KeyMap.offset(for: UInt16(kVK_ANSI_Quote)) == 17, "' plays F above the next C")
        check(KeyMap.offset(for: UInt16(kVK_ANSI_Z)) == nil && KeyMap.offset(for: UInt16(kVK_ANSI_Q)) == nil, "Z and Q play nothing")
        let whiteRow = [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K,
                        kVK_ANSI_L, kVK_ANSI_Semicolon, kVK_ANSI_Quote]
        check(whiteRow.allSatisfy { !Note.isBlack(60 + KeyMap.offset(for: UInt16($0))!) }, "the A row only plays white keys")
        let blackRow = [kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_O, kVK_ANSI_P]
        check(blackRow.allSatisfy { Note.isBlack(60 + KeyMap.offset(for: UInt16($0))!) }, "the W row only plays black keys")
        check(Set(KeyMap.rows.map(\.code)).count == KeyMap.rows.count, "no key is mapped twice")
        check(Note.fullName(60) == "C4" && Note.fullName(61) == "C♯4" && Note.fullName(21) == "A0", "note names")
        check(abs(Note.frequency(69) - 440) < 1e-9 && abs(Note.frequency(60) - 261.6256) < 0.001, "equal temperament")
        check(TimeText.format(12.46) == "0:12.4" && TimeText.format(75) == "1:15.0", "time text")
    }

    // MARK: Layout

    private static func layout() {
        let l = PianoLayout(lowest: 60, size: CGSize(width: 750, height: 200))
        check(l.keys.count == 25 && l.whiteKeys.count == 15 && l.blackKeys.count == 10, "two octaves: 25 keys, 15 white")
        check(l.keys.first?.note == 60 && l.keys.last?.note == 84, "C4 to C6")
        let cSharp = l.keys.first { $0.note == 61 }!
        check(l.key(at: CGPoint(x: cSharp.rect.midX, y: 40))?.note == 61, "a click on a black key hits it, not the white below")
        check(l.key(at: CGPoint(x: cSharp.rect.midX, y: 180))?.note == 60 || l.key(at: CGPoint(x: cSharp.rect.midX, y: 180))?.note == 62,
              "below a black key the white key plays")
        check(l.key(at: CGPoint(x: 749, y: 190))?.note == 84, "the last white key is C6")
        check(l.key(at: CGPoint(x: 900, y: 10)) == nil, "outside the keyboard plays nothing")
        let e = l.keys.first { $0.note == 64 }!
        check(l.velocity(for: e, at: CGPoint(x: e.rect.midX, y: 190)) > l.velocity(for: e, at: CGPoint(x: e.rect.midX, y: 10)),
              "striking nearer the front is louder")
    }

    // MARK: Model

    private static func model() {
        let m = PianoModel(synth: nil, persists: false)
        var now: TimeInterval = 100
        m.clock = { now }
        check(m.lowestNote == 60, "default keyboard starts at middle C")
        m.keyDown(UInt16(kVK_ANSI_A))
        m.keyDown(UInt16(kVK_ANSI_A), isRepeat: true)
        check(m.pressed == [60: 1], "A presses C4 once, key repeat ignored")
        m.keyDown(KeyMap.octaveUp)
        check(m.lowestNote == 72, "X shifts up an octave")
        m.keyUp(UInt16(kVK_ANSI_A))
        check(m.pressed.isEmpty, "releasing A after an octave shift lets go of the note it started")
        for _ in 0..<10 { m.shiftOctave(1) }
        check(m.baseOctave == PianoModel.octaves.upperBound, "octave stops at the top")
        for _ in 0..<10 { m.shiftOctave(-1) }
        check(m.baseOctave == PianoModel.octaves.lowerBound, "octave stops at the bottom")
        m.shiftOctave(3)

        m.startRecording()
        check(m.isRecording, "recording starts")
        now += 0.5
        m.keyDown(UInt16(kVK_ANSI_D))
        m.keyDown(KeyMap.sustain)
        now += 0.5
        m.keyUp(UInt16(kVK_ANSI_D))
        m.keyDown(UInt16(kVK_ANSI_G))
        now += 0.25
        m.stopRecording()
        let take = m.take
        check(take?.noteCount == 2, "take has two notes")
        check(take.map { abs($0.duration - 1.25) < 1e-9 } == true, "take lasts until Stop")
        check(take?.events.first == TakeEvent(time: 0.5, kind: .on, note: 64, velocity: 100), "first event is E4 at 0.5 s")
        check(take?.events.filter { $0.kind == .off }.count == 2, "a note still held at Stop gets its note off")
        check(take?.events.last?.kind == .sustainOff, "a pedal still down at Stop is lifted")
        check(take?.bars.count == 2, "take overview has two bars")

        m.releaseHeldKeys()
        check(m.pressed.isEmpty && !m.sustain, "losing focus releases keys and the pedal")

        let undo = UndoManager()
        undo.groupsByEvent = false
        m.undoManager = undo
        undo.beginUndoGrouping()
        m.clearTake()
        undo.endUndoGrouping()
        check(m.take == nil, "Clear Take empties the take")
        undo.undo()
        check(m.take == take, "Undo brings the take back")

        m.startRecording()
        m.stopRecording()
        check(m.take == take, "an empty recording keeps the previous take")

        m.mouseDown(note: 70, velocity: 90)
        m.mouseDown(note: 71, velocity: 90)
        check(m.pressed == [71: 1], "dragging across keys moves the note")
        m.mouseUp()
        check(m.pressed.isEmpty, "mouse up releases")
    }

    // MARK: Synth

    private static func synth() {
        let rate = 44_100.0, frames = 4_410
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames), right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        func peak(_ core: inout SynthCore, blocks: Int = 1) -> Float {
            var p: Float = 0
            for _ in 0..<blocks {
                core.render(left: left, right: right, frames: frames)
                for i in 0..<frames { p = max(p, abs(left[i]), abs(right[i])) }
            }
            return p
        }

        for sound in Sound.allCases {
            var core = SynthCore(sampleRate: rate)
            core.handle(.noteOn(60, 100, sound))
            check(peak(&core, blocks: 5) > 0.02, "\(sound.title) makes a sound")
        }

        var piano = SynthCore(sampleRate: rate)
        piano.handle(.noteOn(60, 100, .piano))
        _ = peak(&piano)
        piano.handle(.noteOff(60))
        _ = peak(&piano, blocks: 15)
        check(piano.voices.isEmpty && peak(&piano) < 1e-4, "a released piano note falls silent within a second and a half")

        var sustained = SynthCore(sampleRate: rate)
        sustained.handle(.sustain(true))
        sustained.handle(.noteOn(60, 100, .piano))
        sustained.handle(.noteOff(60))
        _ = peak(&sustained, blocks: 5)
        check(sustained.voices.count == 1, "the sustain pedal keeps a released note ringing")
        sustained.handle(.sustain(false))
        _ = peak(&sustained, blocks: 15)
        check(sustained.voices.isEmpty, "lifting the pedal ends the note")

        var organ = SynthCore(sampleRate: rate)
        organ.handle(.noteOn(57, 100, .organ))
        _ = peak(&organ, blocks: 20)
        check(peak(&organ) > 0.05, "a held organ note does not fade")

        var chord = SynthCore(sampleRate: rate)
        for note in 40..<80 { chord.handle(.noteOn(note, 127, .organ)) }
        check(chord.voices.count == SynthCore.maxVoices, "polyphony is capped at \(SynthCore.maxVoices) voices")
        check(peak(&chord, blocks: 3) <= 1, "a forty-note chord never clips")

        var quiet = SynthCore(sampleRate: rate)
        quiet.handle(.gain(0))
        quiet.handle(.noteOn(60, 127, .piano))
        check(peak(&quiet) == 0, "volume zero is silent")
    }
}
