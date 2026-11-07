import AppKit
import Kit
import SwiftUI

// MARK: - Days

/// A calendar day as a plain count of days since 1 January 1970 in the proleptic Gregorian calendar.
/// Streak maths runs on these integers, so daylight saving changes, 23 and 25 hour days and missing
/// midnights can never shift a day. Only the conversion from a `Date` looks at the time zone.
struct Day: Hashable, Comparable, Codable, Sendable {
    let n: Int

    init(n: Int) { self.n = n }

    init(year: Int, month: Int, day: Int) {
        // Days from civil (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        n = era * 146097 + doe - 719468
    }

    /// The local day `date` falls on, in the calendar's time zone.
    init(_ date: Date, calendar: Calendar) {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let c = g.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    var ymd: (year: Int, month: Int, day: Int) {
        let z = n + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 1 is Sunday through 7 Saturday, as `Calendar` numbers weekdays. 1 January 1970 was a Thursday.
    var weekday: Int { ((n % 7 + 7 + 4) % 7) + 1 }

    func adding(_ days: Int) -> Day { Day(n: n + days) }

    /// The first day of the week containing this day, for a calendar whose weeks start on `firstWeekday`.
    func weekStart(firstWeekday: Int) -> Day { adding(-((weekday - firstWeekday + 7) % 7)) }

    /// Midday of this day in the calendar's time zone: a time that exists on every day, unlike midnight.
    func date(in calendar: Calendar) -> Date {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        let (y, m, d) = ymd
        return g.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    var iso: String {
        let (y, m, d) = ymd
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
        guard ymd.day == parts[2] else { return nil }
    }

    static func < (a: Day, b: Day) -> Bool { a.n < b.n }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(iso: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(s)"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

// MARK: - Habits

enum Target: Codable, Hashable, Sendable {
    case daily
    case weekly(Int)

    var perWeek: Int {
        switch self {
        case .daily: 7
        case .weekly(let n): n
        }
    }

    var label: String {
        switch self {
        case .daily: "Every day"
        case .weekly(1): "Once a week"
        case .weekly(let n): "\(n) times a week"
        }
    }

    /// The unit streaks count in.
    func unit(_ count: Int) -> String {
        switch self {
        case .daily: count == 1 ? "day" : "days"
        case .weekly: count == 1 ? "week" : "weeks"
        }
    }
}

enum Tint: String, Codable, CaseIterable, Sendable {
    case orange, red, pink, purple, indigo, blue, teal, green, yellow, graphite

    var color: Color {
        switch self {
        case .orange: Color(hex: 0xF7731E)
        case .red: Color(hex: 0xE5484D)
        case .pink: Color(hex: 0xE34BA9)
        case .purple: Color(hex: 0x8E4EC6)
        case .indigo: Color(hex: 0x5B5BD6)
        case .blue: Color(hex: 0x0A84FF)
        case .teal: Color(hex: 0x12A594)
        case .green: Color(hex: 0x30A46C)
        case .yellow: Color(hex: 0xE2A336)
        case .graphite: Color(hex: 0x6F6E77)
        }
    }

    var name: String { rawValue.capitalized }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

struct Habit: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    /// An SF Symbol name, or a single emoji.
    var icon: String
    var tint: Tint
    var target: Target
    var created: Day
    var done: Set<Day> = []
    /// Notes keyed by ISO date, so the JSON stays readable.
    var notes: [String: String] = [:]

    var iconIsSymbol: Bool { icon.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") } }

    func note(_ day: Day) -> String { notes[day.iso] ?? "" }

    mutating func setNote(_ text: String, on day: Day) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[day.iso] = trimmed.isEmpty ? nil : text
    }

    mutating func toggle(_ day: Day) {
        if done.contains(day) { done.remove(day) } else { done.insert(day) }
    }
}

// MARK: - Streak maths

struct Stats: Equatable {
    var current: Int
    var longest: Int
    /// Share of the target met over the last 30 days (or since the habit began), 0...1.
    var rate: Double
    /// Check-ins in the current week, for weekly targets.
    var thisWeek: Int
}

enum Streaks {
    static func stats(_ habit: Habit, today: Day, firstWeekday: Int) -> Stats {
        let done = habit.done.filter { $0 <= today }
        let (current, longest): (Int, Int)
        switch habit.target {
        case .daily: (current, longest) = daily(done, today: today)
        case .weekly(let n): (current, longest) = weekly(done, perWeek: n, today: today, firstWeekday: firstWeekday)
        }
        let start = today.weekStart(firstWeekday: firstWeekday)
        let thisWeek = done.filter { $0 >= start && $0 <= today }.count
        return Stats(current: current, longest: longest,
                     rate: rate(done, target: habit.target, today: today, created: habit.created), thisWeek: thisWeek)
    }

    /// Consecutive days. Today not being done yet does not break the current streak; yesterday does.
    static func daily(_ done: Set<Day>, today: Day) -> (current: Int, longest: Int) {
        var current = 0
        var day = done.contains(today) ? today : today.adding(-1)
        while done.contains(day) {
            current += 1
            day = day.adding(-1)
        }
        var longest = 0, run = 0
        var previous: Day?
        for d in done.sorted() {
            run = (previous.map { d.n == $0.n + 1 } ?? false) ? run + 1 : 1
            longest = max(longest, run)
            previous = d
        }
        return (current, longest)
    }

    /// Consecutive weeks with at least `perWeek` check-ins. The current week counts once met and never breaks the streak.
    static func weekly(_ done: Set<Day>, perWeek: Int, today: Day, firstWeekday: Int) -> (current: Int, longest: Int) {
        var counts: [Day: Int] = [:]
        for d in done { counts[d.weekStart(firstWeekday: firstWeekday), default: 0] += 1 }
        let met = Set(counts.filter { $0.value >= perWeek }.keys)

        let thisWeek = today.weekStart(firstWeekday: firstWeekday)
        var current = 0
        var week = met.contains(thisWeek) ? thisWeek : thisWeek.adding(-7)
        while met.contains(week) {
            current += 1
            week = week.adding(-7)
        }
        var longest = 0, run = 0
        var previous: Day?
        for w in met.sorted() {
            run = (previous.map { w.n == $0.n + 7 } ?? false) ? run + 1 : 1
            longest = max(longest, run)
            previous = w
        }
        return (current, longest)
    }

    /// Check-ins against the target over the last 30 days, or since the habit was created if later. Capped at 100%.
    static func rate(_ done: Set<Day>, target: Target, today: Day, created: Day) -> Double {
        let start = max(today.adding(-29), min(created, today))
        let days = today.n - start.n + 1
        let count = done.filter { $0 >= start && $0 <= today }.count
        let expected = Double(target.perWeek) * Double(days) / 7
        return min(1, Double(count) / max(expected, 1))
    }
}

// MARK: - Heatmap layout

enum HeatRange: Hashable {
    case pastYear
    case year(Int)
}

/// The columns of a GitHub style grid: one column per week, rows in the calendar's weekday order.
struct HeatGrid {
    let first: Day // Start of the first week shown.
    let start: Day // First day in range.
    let end: Day // Last day in range.
    let columns: Int
    let firstWeekday: Int

    init(range: HeatRange, today: Day, firstWeekday: Int) {
        switch range {
        case .pastYear:
            end = today.weekStart(firstWeekday: firstWeekday).adding(6)
            start = end.adding(-52 * 7 - 6)
        case .year(let y):
            start = Day(year: y, month: 1, day: 1)
            end = Day(year: y, month: 12, day: 31)
        }
        self.firstWeekday = firstWeekday
        first = start.weekStart(firstWeekday: firstWeekday)
        columns = (end.n - first.n) / 7 + 1
    }

    func day(column: Int, row: Int) -> Day? {
        let d = first.adding(column * 7 + row)
        return d >= start && d <= end ? d : nil
    }

    /// Columns whose week holds the first of a month, for the month labels.
    func monthStarts() -> [(column: Int, month: Int, year: Int)] {
        var result: [(Int, Int, Int)] = []
        for c in 0..<columns {
            for r in 0..<7 {
                if let d = day(column: c, row: r), d.ymd.day == 1 {
                    let (y, m, _) = d.ymd
                    result.append((c, m, y))
                }
            }
        }
        return result
    }
}

// MARK: - Model

@MainActor
final class StreakModel: ObservableObject {
    @Published var habits: [Habit] { didSet { if persists { Storage.save(habits, app: "Streak", file: "habits.json") } } }
    @Published var selection: Habit.ID?
    @Published var selectedDay: Day
    @Published var range: HeatRange = .pastYear
    @Published var editing: EditorState?
    @Published var confirmingDelete = false
    @Published private(set) var today: Day

    let calendar: Calendar
    weak var undoManager: UndoManager?
    private let persists: Bool
    private var observers: [NSObjectProtocol] = []

    init() {
        calendar = .autoupdatingCurrent
        persists = !Desktop.isSnapshot
        let today = Day(Date(), calendar: .autoupdatingCurrent)
        self.today = today
        selectedDay = today
        habits = Storage.load([Habit].self, app: "Streak", file: "habits.json") ?? []
        selection = habits.first?.id
        // Midnight, a clock change or a new time zone can each move "today".
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshToday() }
            })
        }
    }

    init(demo habits: [Habit], today: Day, calendar: Calendar) {
        self.calendar = calendar
        persists = false
        self.today = today
        selectedDay = today.adding(-1)
        self.habits = habits
        selection = habits.first?.id
    }

    var firstWeekday: Int { calendar.firstWeekday }

    var selected: Habit? { habits.first { $0.id == selection } }

    func stats(_ habit: Habit) -> Stats { Streaks.stats(habit, today: today, firstWeekday: firstWeekday) }

    func refreshToday() {
        let now = Day(Date(), calendar: calendar)
        guard now != today else { return }
        if selectedDay == today { selectedDay = now }
        today = now
    }

    /// Every change goes through here, so each one is a single undoable step.
    func change(_ name: String, _ body: (inout [Habit]) -> Void) {
        let before = habits
        body(&habits)
        guard habits != before else { return }
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring old: [Habit]) {
        guard let undoManager else { return }
        let current = habits
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.habits = old
                if model.selected == nil { model.selection = old.first?.id }
                model.registerUndo(name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    func update(_ id: Habit.ID, _ name: String, _ body: (inout Habit) -> Void) {
        change(name) { habits in
            if let i = habits.firstIndex(where: { $0.id == id }) { body(&habits[i]) }
        }
    }

    func toggle(_ id: Habit.ID, on day: Day) {
        guard day <= today else { return }
        update(id, "Check-In") { $0.toggle(day) }
    }

    func toggleToday() {
        guard let selection else { return }
        toggle(selection, on: today)
    }

    /// Notes save as you type, quietly: one undo step per keystroke would be noise, and the text field has its own undo.
    func setNote(_ text: String, id: Habit.ID, on day: Day) {
        guard let i = habits.firstIndex(where: { $0.id == id }), habits[i].note(day) != text else { return }
        habits[i].setNote(text, on: day)
    }

    func save(_ state: EditorState) {
        let name = state.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let target: Target = state.weekly ? .weekly(state.perWeek) : .daily
        if let id = state.id {
            update(id, "Edit Habit") {
                $0.name = name
                $0.icon = state.icon
                $0.tint = state.tint
                $0.target = target
            }
        } else {
            let habit = Habit(name: name, icon: state.icon, tint: state.tint, target: target, created: today)
            change("New Habit") { $0.append(habit) }
            selection = habit.id
        }
    }

    func deleteSelected() {
        guard let selection, let i = habits.firstIndex(where: { $0.id == selection }) else { return }
        change("Delete Habit") { $0.remove(at: i) }
        self.selection = habits.indices.contains(i) ? habits[i].id : habits.last?.id
    }

    func move(from source: IndexSet, to destination: Int) {
        change("Move Habit") { $0.move(fromOffsets: source, toOffset: destination) }
    }

    // Year navigation.

    var rangeTitle: String {
        switch range {
        case .pastYear: "Past 12 months"
        case .year(let y): String(y)
        }
    }

    var currentYear: Int { today.ymd.year }

    var earliestYear: Int { (habits.map(\.created) + habits.flatMap(\.done)).min()?.ymd.year ?? currentYear }

    func shiftYear(_ delta: Int) {
        let year: Int = switch range {
        case .pastYear: delta < 0 ? currentYear - 1 : currentYear
        case .year(let y): y + delta
        }
        range = year > currentYear ? .pastYear : .year(max(earliestYear, year))
    }

    var canGoBack: Bool {
        switch range {
        case .pastYear: true
        case .year(let y): y > earliestYear
        }
    }

    var canGoForward: Bool { range != .pastYear }
}

/// The New Habit and Edit Habit sheet's working copy.
struct EditorState: Identifiable {
    var id: Habit.ID?
    var name = ""
    var icon = "book.fill"
    var tint = Tint.orange
    var weekly = false
    var perWeek = 3

    init() {}

    init(_ habit: Habit) {
        id = habit.id
        name = habit.name
        icon = habit.icon
        tint = habit.tint
        if case .weekly(let n) = habit.target {
            weekly = true
            perWeek = n
        }
    }
}

extension EditorState {
    static let symbols = [
        "book.fill", "figure.run", "drop.fill", "bed.double.fill", "leaf.fill", "dumbbell.fill",
        "brain.head.profile", "pencil", "music.note", "heart.fill", "pills.fill", "fork.knife",
        "bicycle", "figure.walk", "sun.max.fill", "moon.stars.fill", "cup.and.saucer.fill", "nosign",
        "guitars.fill", "paintbrush.fill", "globe", "banknote.fill", "iphone.slash", "sparkles",
    ]
}

// MARK: - Demo data

extension StreakModel {
    /// Fixed habits for the website screenshot: a deterministic year of check-ins ending on a fixed Friday.
    static var demo: StreakModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        calendar.locale = Locale(identifier: "en_GB")
        let today = Day(year: 2026, month: 11, day: 6)
        var seed: UInt64 = 0x5EED
        func chance(_ p: Double) -> Bool {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31) < p
        }
        func make(_ name: String, _ icon: String, _ tint: Tint, _ target: Target, days: Int, p: (Day) -> Double) -> Habit {
            var h = Habit(name: name, icon: icon, tint: tint, target: target, created: today.adding(-days))
            for k in 0...days {
                let d = today.adding(-k)
                if chance(p(d)) { h.done.insert(d) }
            }
            return h
        }
        var read = make("Read 20 pages", "book.fill", .orange, .daily, days: 330) { d in
            d.n > today.n - 24 ? 1 : (d.weekday == 1 ? 0.55 : 0.84)
        }
        read.done.remove(today.adding(-25))
        read.setNote("Finished The Overstory. Starting Piranesi tonight.", on: today.adding(-1))
        let run = make("Run 5 km", "figure.run", .green, .weekly(3), days: 300) { d in
            [2, 4, 7].contains(d.weekday) ? 0.86 : 0.06
        }
        let meditate = make("Meditate", "brain.head.profile", .purple, .daily, days: 210) { _ in 0.72 }
        let water = make("Two litres of water", "drop.fill", .blue, .daily, days: 160) { _ in 0.9 }
        let guitar = make("Practise guitar", "guitars.fill", .pink, .weekly(4), days: 120) { d in
            d.weekday == 1 || d.weekday == 7 ? 0.8 : 0.45
        }
        let phone = make("No phone in bed", "🌙", .indigo, .daily, days: 60) { _ in 0.65 }
        return StreakModel(demo: [read, run, meditate, water, guitar, phone], today: today, calendar: calendar)
    }
}
