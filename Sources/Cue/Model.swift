import AppKit
import Kit
import SwiftUI

// MARK: - Data

struct Script: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var title: String
    var text: String
    var modified = Date()

    var words: Int { Metrics.wordCount(text) }
    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled script" : title }
}

/// How the prompt looks and moves. Shared by the preview, the inspector and the full screen prompt.
struct PromptSettings: Codable, Equatable {
    var speed = 3.0 // 0.5 to 10, roughly lines per five seconds
    var fontSize = 72.0
    var margin = 0.12 // Fraction of the width left empty on each side.
    var mirror = false
    var showReadingLine = true
    var readingLine = 0.38 // Fraction of the height, from the top.
    var countdown = true
    var wordsPerMinute = 140
    var displayID: UInt32 = 0 // 0 is the main display.

    static let speedRange = 0.5...10.0
    static let fontRange = 32.0...160.0
    static let marginRange = 0.0...0.3
    static let lineRange = 0.15...0.7
    static let wpmRange = 80...220

    init() {}

    // Tolerant decoding, so a settings file from an older version keeps what it has.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PromptSettings()
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? d.speed
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        margin = (try? c.decode(Double.self, forKey: .margin)) ?? d.margin
        mirror = (try? c.decode(Bool.self, forKey: .mirror)) ?? d.mirror
        showReadingLine = (try? c.decode(Bool.self, forKey: .showReadingLine)) ?? d.showReadingLine
        readingLine = (try? c.decode(Double.self, forKey: .readingLine)) ?? d.readingLine
        countdown = (try? c.decode(Bool.self, forKey: .countdown)) ?? d.countdown
        wordsPerMinute = (try? c.decode(Int.self, forKey: .wordsPerMinute)) ?? d.wordsPerMinute
        displayID = (try? c.decode(UInt32.self, forKey: .displayID)) ?? d.displayID
        clamp()
    }

    mutating func clamp() {
        speed = min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
        fontSize = min(max(fontSize, Self.fontRange.lowerBound), Self.fontRange.upperBound)
        margin = min(max(margin, Self.marginRange.lowerBound), Self.marginRange.upperBound)
        readingLine = min(max(readingLine, Self.lineRange.lowerBound), Self.lineRange.upperBound)
        wordsPerMinute = min(max(wordsPerMinute, Self.wpmRange.lowerBound), Self.wpmRange.upperBound)
    }

    mutating func changeSpeed(by delta: Double) {
        speed = ((speed + delta) * 2).rounded() / 2
        clamp()
    }

    mutating func changeFont(by delta: Double) {
        fontSize += delta
        clamp()
    }

    var pointsPerSecond: Double { Metrics.pointsPerSecond(speed: speed, fontSize: fontSize) }
    var lineHeight: Double { Metrics.lineHeight(fontSize: fontSize) }
}

// MARK: - Pure logic

enum Metrics {
    /// Words a speaker says: runs of non-space characters that contain a letter or a digit.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    static func duration(words: Int, wpm: Int) -> TimeInterval {
        wpm > 0 ? Double(words) / Double(wpm) * 60 : 0
    }

    /// 0:42, 3:10, 1:02:03.
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 45 s, 3 min 10 s, 1 h 2 min.
    static func spoken(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s / 60 % 60) min"
    }

    static func lineHeight(fontSize: Double) -> Double { fontSize * 1.5 }

    /// About `speed / 5` lines a second, whatever the text size.
    static func pointsPerSecond(speed: Double, fontSize: Double) -> Double {
        speed / 5 * lineHeight(fontSize: fontSize)
    }

    /// A title from the first line of an imported text, or from the file name.
    static func title(fileName: String, text: String) -> String {
        let name = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, !name.hasPrefix(".") { return name }
        let first = text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? "Untitled script" : String(first.prefix(60))
    }
}

/// The prompt's motion: a countdown, then scrolling at a rate until the last line reaches the reading line.
struct PromptClock: Equatable {
    enum Phase: Equatable { case countdown(Double), playing, paused, finished }

    var phase: Phase = .paused
    var offset = 0.0
    var elapsed = 0.0
    var limit = Double.greatestFiniteMagnitude

    var isPlaying: Bool { phase == .playing }
    var countdownNumber: Int? {
        if case .countdown(let left) = phase { return max(1, Int(left.rounded(.up))) }
        return nil
    }
    var progress: Double { limit > 0 && limit < .greatestFiniteMagnitude ? min(1, offset / limit) : 0 }

    mutating func start(countdown: Bool) {
        offset = 0
        elapsed = 0
        phase = countdown ? .countdown(3) : .playing
    }

    /// Space: play or pause. During the countdown it starts at once; at the end it starts over.
    mutating func toggle(countdown: Bool) {
        switch phase {
        case .playing: phase = .paused
        case .paused: phase = .playing
        case .countdown: phase = .playing
        case .finished: start(countdown: countdown)
        }
    }

    mutating func advance(by dt: Double, rate: Double) {
        let dt = min(max(dt, 0), 0.1)
        switch phase {
        case .countdown(let left):
            phase = left - dt <= 0 ? .playing : .countdown(left - dt)
        case .playing:
            elapsed += dt
            offset = min(limit, offset + rate * dt)
            if offset >= limit { phase = .finished }
        case .paused, .finished:
            break
        }
    }

    /// Moves the text by hand (arrow keys, scroll wheel); leaving the end makes it pausable again.
    mutating func nudge(by delta: Double) {
        offset = min(max(0, offset + delta), limit)
        if phase == .finished, offset < limit { phase = .paused }
    }
}

// MARK: - Library

@MainActor
final class CueModel: ObservableObject {
    @Published var scripts: [Script] { didSet { scheduleSave() } }
    @Published var selection: Script.ID?
    @Published var settings: PromptSettings { didSet { if persists, settings != oldValue { Storage.save(settings, app: "Cue", file: "settings.json") } } }
    @Published var isImporting = false

    let persists: Bool
    private var saveTask: Task<Void, Never>?

    init(persists: Bool = true) {
        self.persists = persists
        if persists {
            scripts = Storage.load([Script].self, app: "Cue", file: "scripts.json") ?? [Self.welcome]
            settings = Storage.load(PromptSettings.self, app: "Cue", file: "settings.json") ?? PromptSettings()
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
        } else {
            scripts = []
            settings = PromptSettings()
        }
        selection = scripts.first?.id
    }

    var selected: Script? { scripts.first { $0.id == selection } }

    func binding(for id: Script.ID) -> Binding<Script>? {
        guard scripts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { self.scripts.first { $0.id == id } ?? Script(title: "", text: "") },
            set: { value in
                guard let i = self.scripts.firstIndex(where: { $0.id == id }), self.scripts[i] != value else { return }
                var value = value
                value.modified = Date()
                self.scripts[i] = value
            })
    }

    func newScript() {
        let script = Script(title: "Untitled script", text: "")
        withAnimation(.snappy) { scripts.insert(script, at: 0) }
        selection = script.id
    }

    func delete(_ id: Script.ID, undo: UndoManager?) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        let removed = scripts[i]
        _ = withAnimation(.snappy) { scripts.remove(at: i) }
        if selection == id { selection = scripts.indices.contains(i) ? scripts[i].id : scripts.last?.id }
        undo?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.scripts.insert(removed, at: min(i, model.scripts.count))
                model.selection = removed.id
            }
        }
        undo?.setActionName("Delete Script")
    }

    func duplicate(_ id: Script.ID) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        var copy = scripts[i]
        copy.id = UUID()
        copy.title += " copy"
        copy.modified = Date()
        scripts.insert(copy, at: i + 1)
        selection = copy.id
    }

    /// Adds each readable text file as a new script and selects the last one.
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
                  !text.contains("\u{0}") else { continue }
            let script = Script(title: Metrics.title(fileName: url.lastPathComponent, text: text), text: text)
            scripts.insert(script, at: 0)
            selection = script.id
            added += 1
        }
        if added == 0, !urls.isEmpty { NSSound.beep() }
        return added
    }

    func export(_ id: Script.ID) {
        guard let script = scripts.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = script.displayTitle + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try script.text.write(to: url, atomically: true, encoding: .utf8)
            revealInFinder([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard persists else { return }
        saveTask?.cancel()
        Storage.save(scripts, app: "Cue", file: "scripts.json")
    }

    static let welcome = Script(title: "Welcome to Cue", text: """
    Welcome to Cue, a teleprompter that keeps out of your way.

    Write or paste your script here. When you are ready, press Command Return to start prompting on the display you picked in the panel on the right.

    While the text scrolls, press Space to pause and resume. The up and down arrows change the speed, the left and right arrows step back or forward a line, and R starts again from the top with a fresh countdown.

    Keep your eyes on the cyan reading line and talk like a person, not a newsreader. Press Escape when you are done.
    """)

    static var demo: CueModel {
        let model = CueModel(persists: false)
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
        model.scripts = [
            Script(title: "Keynote opening", text: """
            Good morning, everyone, and thank you for being here.

            Five years ago we asked a simple question. What if paying for something felt as natural as saying thank you? No cards to find, no codes to remember, no queue that moves slower than the one next to you.

            Today, more than three million of you open our app every month. You pay a friend back for dinner in two taps. You split the rent before the landlord even asks.

            But we are not here to look back. We are here to show you what comes next, and it starts with a single idea: your money should work for you while you sleep.

            Let me show you how.
            """, modified: now),
            Script(title: "Channel intro", text: "Hey, welcome back to the workshop. Today we are building a walnut desk shelf with nothing but hand tools.", modified: now - day),
            Script(title: "Product demo", text: "Here is the dashboard you see the moment you sign in. Everything that needs you is at the top, and everything else waits politely below.", modified: now - 2 * day),
            Script(title: "Wedding toast", text: "For those who do not know me, I am the one who introduced these two, so any complaints come to me.", modified: now - 5 * day),
            Script(title: "Podcast ad read", text: "This episode is brought to you by a coffee roaster that actually tells you when your beans were roasted.", modified: now - 9 * day),
        ]
        model.selection = model.scripts[0].id
        model.settings.speed = 3.5
        return model
    }
}

// MARK: - Displays

extension NSScreen {
    var displayID: UInt32 { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0 }

    /// The display a prompt goes to: the chosen one if it is connected, otherwise the main display.
    static func prompt(_ id: UInt32) -> NSScreen? {
        screens.first { id != 0 && $0.displayID == id } ?? screens.first ?? main
    }
}
