import AppKit
import Foundation
import Kit
import SwiftUI

// MARK: - Patterns

enum PhaseKind: String, Codable, Equatable {
    case inhale, topUp, holdFull, exhale, holdEmpty

    var label: String {
        switch self {
        case .inhale: "Breathe in"
        case .topUp: "In a little more"
        case .holdFull, .holdEmpty: "Hold"
        case .exhale: "Breathe out"
        }
    }

    /// Whether the lungs are full at the end of this phase.
    var endsFull: Bool { self != .exhale && self != .holdEmpty }
}

struct Phase: Equatable {
    var kind: PhaseKind
    var seconds: Double
}

enum PatternID: String, CaseIterable, Identifiable, Codable {
    case box, relax, coherent, sigh, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .box: "Box breathing"
        case .relax: "4-7-8 relax"
        case .coherent: "Coherent"
        case .sigh: "Physiological sigh"
        case .custom: "Custom"
        }
    }

    var symbol: String {
        switch self {
        case .box: "square"
        case .relax: "moon.stars"
        case .coherent: "water.waves"
        case .sigh: "wind"
        case .custom: "slider.horizontal.3"
        }
    }

    var blurb: String {
        switch self {
        case .box: "Even sides to steady attention."
        case .relax: "A long hold and slow exhale to wind down."
        case .coherent: "About five and a half breaths a minute."
        case .sigh: "Two inhales, one long sigh out."
        case .custom: "Your own rhythm."
        }
    }

    /// The menu shortcut digit.
    var key: Character {
        switch self {
        case .box: "1"
        case .relax: "2"
        case .coherent: "3"
        case .sigh: "4"
        case .custom: "5"
        }
    }
}

struct CustomRhythm: Codable, Equatable {
    var inhale: Double = 4
    var holdFull: Double = 2
    var exhale: Double = 6
    var holdEmpty: Double = 0

    static let range: ClosedRange<Double> = 0...12
}

enum Patterns {
    static func phases(_ id: PatternID, custom: CustomRhythm = CustomRhythm()) -> [Phase] {
        switch id {
        case .box: [Phase(kind: .inhale, seconds: 4), Phase(kind: .holdFull, seconds: 4),
                    Phase(kind: .exhale, seconds: 4), Phase(kind: .holdEmpty, seconds: 4)]
        case .relax: [Phase(kind: .inhale, seconds: 4), Phase(kind: .holdFull, seconds: 7), Phase(kind: .exhale, seconds: 8)]
        case .coherent: [Phase(kind: .inhale, seconds: 5.5), Phase(kind: .exhale, seconds: 5.5)]
        case .sigh: [Phase(kind: .inhale, seconds: 2), Phase(kind: .topUp, seconds: 1), Phase(kind: .exhale, seconds: 6)]
        case .custom:
            // Breathing needs an inhale and an exhale of at least a second; holds of zero are dropped.
            [Phase(kind: .inhale, seconds: max(1, custom.inhale)), Phase(kind: .holdFull, seconds: custom.holdFull),
             Phase(kind: .exhale, seconds: max(1, custom.exhale)), Phase(kind: .holdEmpty, seconds: custom.holdEmpty)]
                .filter { $0.seconds > 0 }
        }
    }

    /// "4 · 4 · 4 · 4" style summary of a rhythm.
    static func summary(_ phases: [Phase]) -> String {
        phases.map { $0.seconds == $0.seconds.rounded() ? String(Int($0.seconds)) : String(format: "%.1f", $0.seconds) }
            .joined(separator: " · ")
    }
}

// MARK: - Timing engine

struct BreathState: Equatable {
    var phaseIndex: Int
    var kind: PhaseKind
    var cycle: Int // Zero based.
    var phaseElapsed: Double
    var phaseRemaining: Double
    /// 0 is empty lungs, 1 is full.
    var fullness: Double

    /// The whole seconds left in this phase, as the countdown shows them.
    var countdown: Int { max(1, Int(phaseRemaining.rounded(.up))) }
}

enum Breath {
    static func cycleLength(_ phases: [Phase]) -> Double { phases.reduce(0) { $0 + $1.seconds } }

    /// The session runs whole cycles, so it never stops halfway through a breath.
    static func sessionLength(minutes: Int, phases: [Phase]) -> Double {
        let cycle = cycleLength(phases)
        guard cycle > 0 else { return 0 }
        return (Double(minutes * 60) / cycle).rounded(.up) * cycle
    }

    static func ease(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return 0.5 - cos(t * .pi) / 2
    }

    static func state(at elapsed: Double, phases: [Phase]) -> BreathState {
        let cycle = cycleLength(phases)
        guard cycle > 0, !phases.isEmpty else {
            return BreathState(phaseIndex: 0, kind: .holdEmpty, cycle: 0, phaseElapsed: 0, phaseRemaining: 0, fullness: 0)
        }
        let t = max(0, elapsed)
        let cycleIndex = Int((t / cycle).rounded(.down))
        var within = t - Double(cycleIndex) * cycle
        // Guard floating point at the very end of a cycle.
        if within >= cycle { within = 0 }
        var start = 0.0
        var index = 0
        while index < phases.count - 1, within >= start + phases[index].seconds - 1e-9 {
            start += phases[index].seconds
            index += 1
        }
        let phase = phases[index]
        let into = within - start
        let from = index == 0 ? 0 : target(phases, index - 1)
        let p = phase.seconds > 0 ? into / phase.seconds : 1
        let fullness = from + (target(phases, index) - from) * ease(p)
        return BreathState(phaseIndex: index, kind: phase.kind, cycle: cycleIndex, phaseElapsed: into,
                           phaseRemaining: max(0, phase.seconds - into), fullness: fullness)
    }

    /// Where the shape sits at the end of phase `i`, from 0 (empty lungs) to 1 (full). An inhale followed by a
    /// top-up sip stops short of full.
    static func target(_ phases: [Phase], _ i: Int) -> Double {
        guard phases[i].kind.endsFull else { return 0 }
        if phases[i].kind == .inhale, i + 1 < phases.count, phases[i + 1].kind == .topUp { return 0.78 }
        return 1
    }

    /// "4:05" for a number of seconds, rounded up so it reads 0:00 only at the very end.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - History

struct Session: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var pattern: PatternID
    var seconds: Double
    var completed: Bool
}

enum History {
    static let minimumSeconds = 30.0

    /// The seven days of the week containing `now`, each with the minutes breathed that day.
    static func week(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> [(day: Date, minutes: Double)] {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let minutes = sessions.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.seconds } / 60
            return (day, minutes)
        }
    }

    static func minutesThisWeek(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> Double {
        week(sessions, now: now, calendar: calendar).reduce(0) { $0 + $1.minutes }
    }

    /// Consecutive days with at least one session, ending today or yesterday.
    static func streak(_ sessions: [Session], now: Date, calendar: Calendar = .current) -> Int {
        let days = Set(sessions.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day), let yesterday = calendar.date(byAdding: .day, value: -1, to: day) { day = yesterday }
        var count = 0
        while days.contains(day), let previous = calendar.date(byAdding: .day, value: -1, to: day) {
            count += 1
            day = previous
        }
        return count
    }
}

// MARK: - Model

enum SoundStyle: String, CaseIterable, Identifiable, Codable {
    case off, chime, tone
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: "No sound"
        case .chime: "Gentle chime"
        case .tone: "Soft tone"
        }
    }
}

struct Settings: Codable, Equatable {
    var pattern: PatternID = .box
    var minutes: Int = 5
    var sound: SoundStyle = .chime
    var volume: Double = 0.6
    var custom = CustomRhythm()

    static let minutesRange = 1...20

    /// Settings read from disk may have been edited by hand or come from an older build: pull every value back in range.
    func sanitized() -> Settings {
        var s = self
        s.minutes = min(Self.minutesRange.upperBound, max(Self.minutesRange.lowerBound, s.minutes))
        s.volume = s.volume.isFinite ? min(1, max(0, s.volume)) : 0.6
        let r = CustomRhythm.range
        func clamp(_ v: Double, _ low: Double) -> Double { v.isFinite ? min(r.upperBound, max(low, v.rounded())) : low }
        s.custom.inhale = clamp(s.custom.inhale, 1)
        s.custom.holdFull = clamp(s.custom.holdFull, 0)
        s.custom.exhale = clamp(s.custom.exhale, 1)
        s.custom.holdEmpty = clamp(s.custom.holdEmpty, 0)
        return s
    }
}

@MainActor
final class ExhaleModel: ObservableObject {
    enum RunState: Equatable { case idle, running, paused, finished }

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            // A finished session stays on screen until the plan changes; then the stage shows the new plan.
            if runState == .finished, settings.pattern != oldValue.pattern || settings.minutes != oldValue.minutes
                || settings.custom != oldValue.custom { reset() }
            saveSettings()
        }
    }
    @Published private(set) var sessions: [Session]
    @Published private(set) var runState: RunState = .idle
    @Published var showHistory = true

    /// Elapsed seconds banked before the current run segment started.
    private var banked = 0.0
    private var segmentStart: Date?
    private var lastPhase: (cycle: Int, index: Int)?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private let persist: Bool
    /// For the website screenshot: a moment frozen in time.
    private var frozen: Double?
    private(set) var sessionPattern: PatternID = .box
    private var sessionPhases: [Phase] = []
    private(set) var sessionTotal = 0.0
    let sound = Chimes()

    init(persist: Bool = true) {
        self.persist = persist
        settings = (persist ? Storage.load(Settings.self, app: "Exhale", file: "settings.json") ?? Settings() : Settings()).sanitized()
        let saved = persist ? (Storage.load([Session].self, app: "Exhale", file: "history.json") ?? []) : []
        sessions = saved.filter { $0.seconds.isFinite && $0.seconds > 0 }.sorted { $0.date > $1.date }
        guard persist, !Desktop.isSnapshot else { return }
        // The clock keeps running while the Mac sleeps; pause so a nap is not counted as breathing.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            })
        // Quitting mid-session still keeps the minutes breathed so far.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            })
    }

    static var demo: ExhaleModel {
        let model = ExhaleModel(persist: false)
        model.settings.pattern = .relax
        model.settings.minutes = 5
        let cal = Calendar.current
        let now = Date()
        let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let today = cal.dateComponents([.day], from: start, to: now).day ?? 0
        let plan: [(Int, Int, PatternID, Double)] = [(0, 8, .coherent, 600), (0, 21, .relax, 300), (1, 7, .box, 300),
                                                     (2, 22, .relax, 480), (3, 9, .coherent, 900), (4, 13, .sigh, 120),
                                                     (5, 10, .coherent, 600), (6, 21, .box, 300), (-3, 8, .coherent, 600)]
        model.sessions = plan.compactMap { day, hour, pattern, seconds in
            guard day <= today, let d = cal.date(byAdding: .day, value: day, to: start),
                  let at = cal.date(bySettingHour: hour, minute: 15, second: 0, of: d) else { return nil }
            return Session(date: at, pattern: pattern, seconds: seconds, completed: true)
        }.sorted { $0.date > $1.date }
        model.begin()
        model.stopTimer()
        model.frozen = 3 * 19 + 4 + 2.3 // The fourth breath, early in the hold.
        return model
    }

    var phases: [Phase] {
        runState == .idle ? Patterns.phases(settings.pattern, custom: settings.custom) : sessionPhases
    }

    var plannedLength: Double { Breath.sessionLength(minutes: settings.minutes, phases: Patterns.phases(settings.pattern, custom: settings.custom)) }

    func elapsed(at date: Date) -> Double {
        if let frozen { return frozen }
        var total = banked
        if let segmentStart { total += date.timeIntervalSince(segmentStart) }
        return min(total, sessionTotal)
    }

    func remaining(at date: Date) -> Double {
        runState == .idle ? plannedLength : max(0, sessionTotal - elapsed(at: date))
    }

    // MARK: Session control

    func toggle() {
        switch runState {
        case .idle, .finished: begin()
        case .running: pause()
        case .paused: resume()
        }
    }

    func begin() {
        sessionPattern = settings.pattern
        sessionPhases = Patterns.phases(settings.pattern, custom: settings.custom)
        sessionTotal = Breath.sessionLength(minutes: settings.minutes, phases: sessionPhases)
        banked = 0
        frozen = nil
        lastPhase = nil
        withAnimation(.snappy) { runState = .running }
        resume()
    }

    func pause() {
        guard runState == .running, let segmentStart else { return }
        banked += Date().timeIntervalSince(segmentStart)
        self.segmentStart = nil
        stopTimer()
        withAnimation(.snappy) { runState = .paused }
    }

    func resume() {
        segmentStart = Date()
        withAnimation(.snappy) { runState = .running }
        startTimer()
    }

    /// Ends the session early; anything past half a minute still counts.
    func stop() {
        guard runState == .running || runState == .paused else { return }
        let done = elapsed(at: Date())
        stopTimer()
        segmentStart = nil
        record(seconds: done, completed: false)
        withAnimation(.snappy) { runState = .idle }
    }

    func reset() {
        guard runState == .finished else { return }
        withAnimation(.snappy) { runState = .idle }
    }

    private func finish() {
        stopTimer()
        segmentStart = nil
        banked = sessionTotal
        record(seconds: sessionTotal, completed: true)
        sound.play(.done, style: settings.sound, volume: settings.volume)
        withAnimation(.snappy) { runState = .finished }
    }

    private func startTimer() {
        timer?.invalidate()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated],
                                                             reason: "Guided breathing session")
        }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    fileprivate func stopTimer() {
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Self-test hook: jumps the session clock to `elapsed` seconds and runs one tick.
    func simulate(elapsed: Double) {
        frozen = elapsed
        tick()
    }

    private func tick() {
        let now = elapsed(at: Date())
        if now >= sessionTotal { finish(); return }
        let state = Breath.state(at: now, phases: sessionPhases)
        if let last = lastPhase, last.cycle == state.cycle, last.index == state.phaseIndex { return }
        lastPhase = (state.cycle, state.phaseIndex)
        sound.play(Chimes.Cue(state.kind), style: settings.sound, volume: settings.volume)
    }

    // MARK: History

    private func record(seconds: Double, completed: Bool) {
        guard seconds >= History.minimumSeconds else { return }
        sessions.insert(Session(date: Date(), pattern: sessionPattern, seconds: seconds, completed: completed), at: 0)
        saveHistory()
    }

    func delete(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        saveHistory()
    }

    func clearHistory() {
        sessions = []
        saveHistory()
    }

    private func saveHistory() {
        guard persist, !Desktop.isSnapshot else { return }
        Storage.save(sessions, app: "Exhale", file: "history.json")
    }

    private func saveSettings() {
        guard persist, !Desktop.isSnapshot else { return }
        Storage.save(settings, app: "Exhale", file: "settings.json")
    }

    // MARK: Adjustments

    func nudgeMinutes(_ delta: Int) {
        settings.minutes = min(Settings.minutesRange.upperBound, max(Settings.minutesRange.lowerBound, settings.minutes + delta))
    }

    var canEdit: Bool { runState == .idle || runState == .finished }
}
