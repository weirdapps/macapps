import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Maths

enum Stats {
    /// Gross (raw) WPM: every typed character, in standard five character words, per minute.
    static func grossWPM(characters: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(characters) / 5 / (seconds / 60)
    }

    /// Net WPM: gross WPM less one word per minute for each error left uncorrected, never below zero.
    static func netWPM(characters: Int, uncorrectedErrors: Int, seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return max(0, grossWPM(characters: characters, seconds: seconds) - Double(uncorrectedErrors) / (seconds / 60))
    }

    /// Keystroke accuracy in percent: right keystrokes over all keystrokes, corrected mistakes included.
    static func accuracy(correct: Int, total: Int) -> Double {
        guard total > 0 else { return 100 }
        return Double(correct) / Double(total) * 100
    }
}

enum KeyMap {
    private static let shifted: [Character: String] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// The physical key (on a US layout) that types `c`: "a" for "A", "1" for "!", "space" for " ".
    static func key(for c: Character) -> String {
        if c == " " { return "space" }
        if let base = shifted[c] { return base }
        return c.lowercased()
    }
}

enum Wrap {
    /// Greedy word wrap of `text` into lines of at most `columns` characters. Each line keeps its trailing space,
    /// so the ranges tile the whole text; a word longer than a line is broken.
    static func lines(_ text: [Character], columns: Int) -> [Range<Int>] {
        let columns = max(1, columns)
        var lines: [Range<Int>] = []
        var start = 0
        while start < text.count {
            var end = min(start + columns, text.count)
            if end < text.count {
                if text[end] == " " {
                    end += 1 // The space after a full line belongs to it.
                } else if let space = text[start..<end].lastIndex(of: " ") {
                    end = space + 1
                }
            }
            lines.append(start..<end)
            start = end
        }
        return lines.isEmpty ? [0..<0] : lines
    }

    /// The index of the line holding character `index` (the end of text sits on the last line).
    static func line(of index: Int, in lines: [Range<Int>]) -> Int {
        lines.firstIndex { $0.contains(index) } ?? max(0, lines.count - 1)
    }
}

// MARK: - Session

/// One test's keystrokes against its text. Pure, so the self-test can drive it.
struct TypingSession {
    var target: [Character]
    private(set) var typed: [Character] = []
    private(set) var correctKeys = 0
    private(set) var wrongKeys = 0
    private(set) var keyHits: [String: Int] = [:]
    private(set) var keyErrors: [String: Int] = [:]

    init(text: String) { target = Array(text) }

    var isComplete: Bool { !target.isEmpty && typed.count >= target.count }
    var uncorrectedErrors: Int { zip(typed, target).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) } }
    var totalWords: Int { String(target).split(separator: " ").count }
    var wordsDone: Int {
        let full = typed.indices.filter { typed[$0] == " " && target[$0] == " " }.count
        return isComplete ? totalWords : min(full, totalWords)
    }

    mutating func type(_ c: Character) {
        guard typed.count < target.count else { return }
        let expected = target[typed.count]
        let key = KeyMap.key(for: expected)
        keyHits[key, default: 0] += 1
        if c == expected {
            correctKeys += 1
        } else {
            wrongKeys += 1
            keyErrors[key, default: 0] += 1
        }
        typed.append(c)
    }

    mutating func backspace() {
        if !typed.isEmpty { typed.removeLast() }
    }

    /// Option-Delete: back to the start of the current (or previous) word.
    mutating func deleteWord() {
        while typed.last == " " { typed.removeLast() }
        while let last = typed.last, last != " " { typed.removeLast() }
    }

    mutating func append(_ text: String) { target += Array(text) }
}

// MARK: - Settings and results

enum TestMode: String, CaseIterable, Codable, Identifiable {
    case time, words, quote
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct TestConfig: Equatable, Codable {
    var mode: TestMode = .time
    var seconds = 30
    var wordCount = 25
    var punctuation = false
    var numbers = false

    static let secondOptions = [15, 30, 60, 120]
    static let wordOptions = [10, 25, 50, 100]

    var label: String {
        switch mode {
        case .time: "\(seconds) seconds"
        case .words: "\(wordCount) words"
        case .quote: "Quote"
        }
    }

    var extras: [String] {
        guard mode != .quote else { return [] }
        return (punctuation ? ["punctuation"] : []) + (numbers ? ["numbers"] : [])
    }
}

struct TestResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var mode: String
    var netWPM: Double
    var rawWPM: Double
    var accuracy: Double
    var seconds: Double
    var characters: Int
    var errors: Int
    var keyHits: [String: Int]
    var keyErrors: [String: Int]
}

struct Sample: Identifiable, Equatable {
    var second: Int
    var wpm: Double
    var raw: Double
    var errors: Int
    var id: Int { second }
}

enum CSV {
    static func history(_ results: [TestResult]) -> String {
        let f = ISO8601DateFormatter()
        var out = "date,test,net_wpm,raw_wpm,accuracy,seconds,characters,errors\n"
        for r in results {
            out += [f.string(from: r.date), r.mode, String(format: "%.1f", r.netWPM), String(format: "%.1f", r.rawWPM),
                    String(format: "%.1f", r.accuracy), String(format: "%.1f", r.seconds), "\(r.characters)", "\(r.errors)"]
                .joined(separator: ",") + "\n"
        }
        return out
    }
}

// MARK: - Model

@MainActor
final class TypistModel: ObservableObject {
    enum Phase { case ready, running, finished }

    @Published var config: TestConfig {
        didSet {
            guard config != oldValue else { return }
            if persists, let data = try? JSONEncoder().encode(config) { UserDefaults.standard.set(data, forKey: "config") }
            newTest()
        }
    }
    @Published private(set) var session = TypingSession(text: "")
    @Published private(set) var phase = Phase.ready
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var history: [TestResult] = []
    @Published private(set) var lastResult: TestResult?
    @Published private(set) var author: String?
    @Published var confirmingClear = false
    @Published var exporting = false

    private let persists: Bool
    private var startDate: Date?
    private var timer: Timer?
    private var monitor: Any?
    private var lastQuote = -1
    private var wrongAtLastSample = 0

    init(persists: Bool = true) {
        self.persists = persists
        if persists, let data = UserDefaults.standard.data(forKey: "config"),
           let saved = try? JSONDecoder().decode(TestConfig.self, from: data) {
            config = saved
        } else {
            config = TestConfig()
        }
        if persists { history = Storage.load([TestResult].self, app: "Typist", file: "history.json") ?? [] }
        newTest()
    }

    // MARK: Tests

    /// A fresh text for the current settings.
    func newTest() {
        var rng = SystemRandomNumberGenerator()
        load(text: makeText(using: &rng))
    }

    /// The same text again, from the top.
    func restart() { load(text: String(session.target), keepAuthor: true) }

    func makeText<R: RandomNumberGenerator>(using rng: inout R) -> String {
        switch config.mode {
        case .time:
            return TextGenerator.words(max(60, config.seconds * 4), punctuation: config.punctuation, numbers: config.numbers, using: &rng)
                .joined(separator: " ")
        case .words:
            return TextGenerator.words(config.wordCount, punctuation: config.punctuation, numbers: config.numbers, using: &rng)
                .joined(separator: " ")
        case .quote:
            var i = Int.random(in: 0..<Words.quotes.count, using: &rng)
            if i == lastQuote { i = (i + 1) % Words.quotes.count }
            lastQuote = i
            return Words.quotes[i].text
        }
    }

    private func load(text: String, keepAuthor: Bool = false) {
        timer?.invalidate()
        timer = nil
        startDate = nil
        session = TypingSession(text: text)
        if !keepAuthor { author = config.mode == .quote ? Words.quotes.first { $0.text == text }?.author : nil }
        phase = .ready
        elapsed = 0
        samples = []
        wrongAtLastSample = 0
        lastResult = nil
    }

    func type(_ c: Character) {
        guard phase != .finished else { return }
        if phase == .ready { begin() }
        session.type(c)
        if config.mode == .time, session.target.count - session.typed.count < 80 {
            var rng = SystemRandomNumberGenerator()
            session.append(" " + TextGenerator.words(40, punctuation: config.punctuation, numbers: config.numbers, using: &rng)
                .joined(separator: " "))
        }
        if config.mode != .time, session.isComplete { finish() }
    }

    func backspace(word: Bool) {
        guard phase == .running else { return }
        if word { session.deleteWord() } else { session.backspace() }
    }

    private func begin() {
        phase = .running
        startDate = Date()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard phase == .running, let startDate else { return }
        elapsed = Date().timeIntervalSince(startDate)
        while samples.count < Int(elapsed) { recordSample(at: samples.count + 1) }
        if config.mode == .time, elapsed >= Double(config.seconds) {
            elapsed = Double(config.seconds)
            finish()
        }
    }

    private func recordSample(at second: Int) {
        let s = Double(second)
        samples.append(Sample(second: second,
                              wpm: Stats.netWPM(characters: session.typed.count, uncorrectedErrors: session.uncorrectedErrors, seconds: s),
                              raw: Stats.grossWPM(characters: session.typed.count, seconds: s),
                              errors: session.wrongKeys - wrongAtLastSample))
        wrongAtLastSample = session.wrongKeys
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if config.mode != .time, let startDate { elapsed = Date().timeIntervalSince(startDate) }
        if Double(samples.count) < elapsed.rounded(.down) || samples.isEmpty { recordSample(at: samples.count + 1) }
        phase = .finished
        let result = TestResult(date: Date(), mode: config.mode == .quote ? "quote" : config.label + config.extras.map { " +" + $0 }.joined(),
                                netWPM: liveNet, rawWPM: liveRaw, accuracy: liveAccuracy, seconds: elapsed,
                                characters: session.typed.count, errors: session.uncorrectedErrors,
                                keyHits: session.keyHits, keyErrors: session.keyErrors)
        lastResult = result
        history.append(result)
        if history.count > 1000 { history.removeFirst(history.count - 1000) }
        save()
    }

    // MARK: Live numbers

    private var measuredSeconds: Double { max(elapsed, 1) }
    var liveNet: Double { Stats.netWPM(characters: session.typed.count, uncorrectedErrors: session.uncorrectedErrors, seconds: measuredSeconds) }
    var liveRaw: Double { Stats.grossWPM(characters: session.typed.count, seconds: measuredSeconds) }
    var liveAccuracy: Double { Stats.accuracy(correct: session.correctKeys, total: session.correctKeys + session.wrongKeys) }
    var secondsLeft: Int { max(0, Int((Double(config.seconds) - elapsed).rounded(.up))) }

    // MARK: History

    /// Presses and misses per key across the last 50 tests and the one in progress.
    var keyStats: [String: (hits: Int, errors: Int)] {
        var out: [String: (hits: Int, errors: Int)] = [:]
        var sources = history.suffix(50).map { ($0.keyHits, $0.keyErrors) }
        if phase == .running { sources.append((session.keyHits, session.keyErrors)) }
        for (hits, errors) in sources {
            for (k, v) in hits { out[k, default: (0, 0)].hits += v }
            for (k, v) in errors { out[k, default: (0, 0)].errors += v }
        }
        return out
    }

    func clearHistory(undoManager: UndoManager?) {
        let old = history
        history = []
        save()
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.history = old
                model.save()
            }
        }
        undoManager?.setActionName("Clear History")
    }

    private func save() {
        if persists { Storage.save(history, app: "Typist", file: "history.json") }
    }

    // MARK: Keys

    /// Listens to key presses in Typist's own window only (a local monitor, so no permissions are needed).
    func startListening() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let event = event // Local monitors run on the main thread.
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window.attachedSheet == nil, !(window is NSPanel) else { return false }
        if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) { return false }
        switch event.keyCode {
        case 53: newTest(); return true // Escape
        case 36, 76: // Return
            if phase == .finished { newTest(); return true }
            return false
        case 51: backspace(word: flags.contains(.option)); return true // Delete
        case 48: return false // Tab moves focus as usual.
        default: break
        }
        guard phase != .finished, let chars = event.characters, chars.count == 1, let c = chars.first else { return false }
        if c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) {
            return false
        }
        if event.isARepeat { return true } // Holding a key does not type it over and over.
        type(c)
        return true
    }

    // MARK: Demo

    /// Fixed data for the website snapshot: a test under way and a few weeks of history.
    nonisolated static var demo: TypistModel { MainActor.assumeIsolated { makeDemo() } }

    private static func makeDemo() -> TypistModel {
        let m = TypistModel(persists: false)
        m.config = TestConfig(mode: .time, seconds: 60, punctuation: true)
        var rng = SplitMix64(seed: 7)
        m.load(text: m.makeText(using: &rng))
        var s = m.session
        let target = s.target
        for (i, c) in target.prefix(128).enumerated() {
            if i == 23 { s.type("w"); s.backspace() }
            if i == 61 || i == 97 { s.type(c == "e" ? "r" : "e"); continue }
            s.type(c)
        }
        m.session = s
        m.phase = .running
        m.elapsed = 21.6
        var h: [TestResult] = []
        var r = SplitMix64(seed: 42)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let keys = Array("etaoinshrdlucmfwypvbgkqjxz").map(String.init) + ["space", ",", ".", ";"]
        for i in 0..<28 {
            let net = 58 + Double(i) * 0.95 + Double(Int.random(in: -40...40, using: &r)) / 10
            var hits: [String: Int] = [:], errors: [String: Int] = [:]
            for (n, k) in keys.enumerated() {
                hits[k] = max(4, 60 - n * 2)
                let weight = ["e": 3, "r": 4, "b": 5, "y": 3, "p": 3, "o": 2, ",": 3, ";": 4, "q": 2][k] ?? 0
                errors[k] = Int.random(in: 0...(1 + weight), using: &r)
            }
            h.append(TestResult(date: start.addingTimeInterval(Double(i) * 43_000), mode: "60 seconds", netWPM: net,
                                rawWPM: net + 4, accuracy: 93 + Double(i) / 6, seconds: 60, characters: Int(net * 5),
                                errors: 2, keyHits: hits, keyErrors: errors))
        }
        m.history = h
        return m
    }
}

/// The exported history file.
struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
