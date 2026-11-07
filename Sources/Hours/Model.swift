import AppKit
import Kit
import SwiftUI

// MARK: - Data

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var color: Int
    /// Hourly rate in the app's currency; nil when the project is not billed.
    var rate: Double?
}

struct Entry: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: UUID
    var start: Date
    /// nil while the timer runs.
    var end: Date?
    var note: String = ""

    var isRunning: Bool { end == nil }
    func duration(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}

struct Ledger: Codable, Equatable {
    var projects: [Project] = []
    var entries: [Entry] = []
}

enum Period: String, CaseIterable, Identifiable {
    case thisWeek = "This week", lastWeek = "Last week", thisMonth = "This month", custom = "Custom"
    var id: String { rawValue }
}

enum Mode: String, CaseIterable, Identifiable {
    case week = "Week", totals = "Totals"
    var id: String { rawValue }
}

enum SidebarItem: Hashable {
    case all
    case project(UUID)
}

enum Sheet: Identifiable {
    case entry(Entry, isNew: Bool)
    case project(Project, isNew: Bool)

    var id: String {
        switch self {
        case .entry(let e, _): "e" + e.id.uuidString
        case .project(let p, _): "p" + p.id.uuidString
        }
    }
}

// MARK: - Timesheet maths

/// Pure functions over entries: splitting at midnight, totals, earnings, CSV.
enum Timesheet {
    /// The entry cut at every midnight it crosses, so each piece lies inside one calendar day.
    static func pieces(of entry: Entry, now: Date, calendar: Calendar) -> [DateInterval] {
        let end = entry.end ?? now
        guard end > entry.start else { return [] }
        var out: [DateInterval] = []
        var start = entry.start
        while start < end {
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            let stop = min(midnight, end)
            out.append(DateInterval(start: start, end: stop))
            start = stop
        }
        return out
    }

    /// Seconds of `entry` that fall inside `interval`.
    static func seconds(of entry: Entry, in interval: DateInterval, now: Date) -> TimeInterval {
        let start = max(entry.start, interval.start), end = min(entry.end ?? now, interval.end)
        return max(0, end.timeIntervalSince(start))
    }

    static func seconds(_ entries: [Entry], in interval: DateInterval, now: Date) -> TimeInterval {
        entries.reduce(0) { $0 + seconds(of: $1, in: interval, now: now) }
    }

    static func secondsByProject(_ entries: [Entry], in interval: DateInterval, now: Date) -> [UUID: TimeInterval] {
        var out: [UUID: TimeInterval] = [:]
        for e in entries {
            let s = seconds(of: e, in: interval, now: now)
            if s > 0 { out[e.projectID, default: 0] += s }
        }
        return out
    }

    static func earnings(_ byProject: [UUID: TimeInterval], projects: [Project]) -> Double {
        projects.reduce(0) { sum, p in sum + (p.rate ?? 0) * (byProject[p.id] ?? 0) / 3600 }
    }

    /// Start of each day in `interval`.
    static func days(in interval: DateInterval, calendar: Calendar) -> [Date] {
        var out: [Date] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            out.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return out
    }

    static func day(_ date: Date, calendar: Calendar) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    static func week(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: date)!
    }

    static func interval(for period: Period, now: Date, customStart: Date, customEnd: Date, calendar: Calendar) -> DateInterval {
        switch period {
        case .thisWeek:
            return week(containing: now, calendar: calendar)
        case .lastWeek:
            return week(containing: calendar.date(byAdding: .day, value: -7, to: now)!, calendar: calendar)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: now)!
        case .custom:
            let a = calendar.startOfDay(for: min(customStart, customEnd))
            let b = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(customStart, customEnd)))!
            return DateInterval(start: a, end: b)
        }
    }

    /// "7:05", or "1:02:03" with seconds.
    static func duration(_ seconds: TimeInterval, withSeconds: Bool = false) -> String {
        let total = Int(max(0, seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return withSeconds ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", h, m)
    }

    static func field(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static let csvHeader = "Date,Project,Start,End,Hours,Rate,Amount,Note"

    /// A timesheet: one row per entry per day, so a timer that ran past midnight gives two rows.
    static func csv(_ ledger: Ledger, in interval: DateInterval, project: UUID?, now: Date, calendar: Calendar) -> String {
        let dateFormat = DateFormatter(), timeFormat = DateFormatter()
        for f in [dateFormat, timeFormat] {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
        }
        dateFormat.dateFormat = "yyyy-MM-dd"
        timeFormat.dateFormat = "HH:mm"
        let projects = Dictionary(uniqueKeysWithValues: ledger.projects.map { ($0.id, $0) })
        var lines = [csvHeader]
        let entries = ledger.entries.filter { project == nil || $0.projectID == project }.sorted { $0.start < $1.start }
        for entry in entries {
            guard let p = projects[entry.projectID] else { continue }
            for piece in pieces(of: entry, now: now, calendar: calendar) {
                guard let clipped = piece.intersection(with: interval), clipped.duration > 0 else { continue }
                let dayStart = calendar.startOfDay(for: clipped.start)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let end = clipped.end == nextDay ? "24:00" : timeFormat.string(from: clipped.end)
                let hours = clipped.duration / 3600
                let rate = p.rate.map { String(format: "%.2f", $0) } ?? ""
                let amount = p.rate.map { String(format: "%.2f", $0 * hours) } ?? ""
                lines.append([dateFormat.string(from: dayStart), field(p.name), timeFormat.string(from: clipped.start), end,
                              String(format: "%.2f", hours), rate, amount, field(entry.note)].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Theme

enum Theme {
    static let top = Color(nsColor: rgb(0x22B8CF))
    static let bottom = Color(nsColor: rgb(0x1A6FA3))
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let palette: [UInt32] = [0x22B8CF, 0x5B6CF0, 0xF2994A, 0xEB5A8C, 0x3CC47C, 0x9B6CF0, 0xE8B931, 0xE5534B, 0x1A6FA3, 0x8E8E93]
    static func color(_ index: Int) -> Color { Color(nsColor: rgb(palette[((index % palette.count) + palette.count) % palette.count])) }
    static let currencies = ["EUR", "USD", "GBP", "CHF", "CAD", "AUD", "JPY", "SEK", "NOK", "DKK", "PLN"]
}

// MARK: - Model

@MainActor
final class HoursModel: ObservableObject {
    static let shared = HoursModel(ledger: Storage.load(Ledger.self, app: "Hours", file: "ledger.json") ?? Ledger(), persists: true)

    @Published private(set) var ledger: Ledger
    @Published var filter: SidebarItem? = .all
    @Published var mode: Mode = .week
    @Published var weekStart: Date
    @Published var selectedDay: Date
    @Published var period: Period = .thisWeek
    @Published var customStart: Date
    @Published var customEnd: Date
    @Published var sheet: Sheet?
    @Published var lastExport: URL?
    @Published var currency: String {
        didSet { if persists { UserDefaults.standard.set(currency, forKey: "currency") } }
    }

    let persists: Bool
    let fixedNow: Date?
    var calendar = Calendar.current
    weak var undoManager: UndoManager?
    private var badgeTimer: Timer?

    init(ledger: Ledger, persists: Bool, now: Date? = nil, currency: String? = nil, calendar: Calendar = .current) {
        self.ledger = ledger
        self.calendar = calendar
        self.persists = persists
        self.fixedNow = now
        let today = now ?? Date()
        weekStart = Timesheet.week(containing: today, calendar: calendar).start
        selectedDay = calendar.startOfDay(for: today)
        customStart = calendar.date(byAdding: .day, value: -13, to: today)!
        customEnd = today
        self.currency = currency ?? UserDefaults.standard.string(forKey: "currency")
            ?? (Locale.current.currency?.identifier).flatMap { Theme.currencies.contains($0) ? $0 : nil } ?? "EUR"
        if persists {
            badgeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                MainActor.assumeIsolated { HoursModel.shared.updateBadge() }
            }
            DispatchQueue.main.async { self.updateBadge() }
        }
    }

    func now() -> Date { fixedNow ?? Date() }

    var projects: [Project] { ledger.projects }
    var entries: [Entry] { ledger.entries }
    var running: Entry? { ledger.entries.first { $0.end == nil } }
    func project(_ id: UUID) -> Project? { ledger.projects.first { $0.id == id } }

    var filterProject: UUID? {
        if case .project(let id) = filter { return id }
        return nil
    }

    /// Entries the sidebar filter lets through.
    var visibleEntries: [Entry] {
        guard let id = filterProject else { return ledger.entries }
        return ledger.entries.filter { $0.projectID == id }
    }

    /// The project a new timer or entry uses: the sidebar's, else the most recent one.
    var defaultProjectID: UUID? {
        if let id = filterProject, project(id) != nil { return id }
        if let last = ledger.entries.max(by: { $0.start < $1.start }), project(last.projectID) != nil { return last.projectID }
        return ledger.projects.first?.id
    }

    func money(_ value: Double) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(currency == "JPY" ? 0 : 2)))
    }

    // MARK: Editing, with undo

    private func change(_ action: String, _ body: (inout Ledger) -> Void) {
        let before = ledger
        body(&ledger)
        guard ledger != before else { return }
        registerUndo(restoring: before, action: action)
        save()
    }

    private func registerUndo(restoring old: Ledger, action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.ledger
                model.ledger = old
                model.save()
                model.registerUndo(restoring: current, action: action)
            }
        }
        undoManager.setActionName(action)
    }

    private func save() {
        updateBadge()
        guard persists else { return }
        Storage.save(ledger, app: "Hours", file: "ledger.json")
    }

    /// Starts a timer, stopping any other first: only one runs at a time.
    func start(_ projectID: UUID, note: String = "") {
        guard project(projectID) != nil else { return }
        let t = now()
        change("Start Timer") { l in
            for i in l.entries.indices where l.entries[i].end == nil { l.entries[i].end = t }
            l.entries.append(Entry(projectID: projectID, start: t, note: note))
        }
        selectedDay = calendar.startOfDay(for: t)
        weekStart = Timesheet.week(containing: t, calendar: calendar).start
    }

    func stop() {
        let t = now()
        change("Stop Timer") { l in
            for i in l.entries.indices where l.entries[i].end == nil { l.entries[i].end = max(t, l.entries[i].start) }
        }
    }

    func toggleTimer() {
        if running != nil { stop() } else if let id = defaultProjectID { start(id) }
    }

    /// The running timer's note, saved as you type without filling the undo stack.
    func setRunningNote(_ note: String) {
        guard let i = ledger.entries.firstIndex(where: { $0.end == nil }) else { return }
        ledger.entries[i].note = note
        save()
    }

    func saveEntry(_ entry: Entry) {
        change("Edit Entry") { l in
            if let i = l.entries.firstIndex(where: { $0.id == entry.id }) { l.entries[i] = entry } else { l.entries.append(entry) }
        }
    }

    func deleteEntry(_ id: UUID) {
        change("Delete Entry") { l in l.entries.removeAll { $0.id == id } }
    }

    func saveProject(_ project: Project) {
        change("Edit Project") { l in
            if let i = l.projects.firstIndex(where: { $0.id == project.id }) { l.projects[i] = project } else { l.projects.append(project) }
        }
    }

    func deleteProject(_ id: UUID) {
        change("Delete Project") { l in
            l.projects.removeAll { $0.id == id }
            l.entries.removeAll { $0.projectID == id }
        }
        if filterProject == id { filter = .all }
    }

    func newEntry() {
        guard let pid = defaultProjectID else { sheet = .project(newProjectDraft(), isNew: true); return }
        let day = selectedDay
        let dayEntries = ledger.entries.filter { calendar.isDate($0.start, inSameDayAs: day) && $0.end != nil }
        let start = dayEntries.compactMap(\.end).max() ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        sheet = .entry(Entry(projectID: pid, start: start, end: start.addingTimeInterval(3600)), isNew: true)
    }

    func newProjectDraft() -> Project {
        Project(name: "", color: ledger.projects.count % Theme.palette.count, rate: nil)
    }

    // MARK: Week navigation

    var week: DateInterval {
        DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart)!)
    }

    func moveWeek(_ by: Int) {
        weekStart = calendar.date(byAdding: .day, value: 7 * by, to: weekStart)!
        selectedDay = calendar.date(byAdding: .day, value: 7 * by, to: selectedDay)!
    }

    func goToToday() {
        let t = now()
        weekStart = Timesheet.week(containing: t, calendar: calendar).start
        selectedDay = calendar.startOfDay(for: t)
        mode = .week
    }

    var periodInterval: DateInterval {
        Timesheet.interval(for: period, now: now(), customStart: customStart, customEnd: customEnd, calendar: calendar)
    }

    // MARK: Export

    /// The interval on screen: the week in week mode, the period in totals mode.
    var exportInterval: DateInterval { mode == .week ? week : periodInterval }

    func exportCSV() {
        guard !Desktop.isSnapshot else { return }
        let interval = exportInterval
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let last = calendar.date(byAdding: .second, value: -1, to: interval.end)!
        let projectName = filterProject.flatMap { project($0)?.name }.map { " \($0)" } ?? ""
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Hours\(projectName) \(f.string(from: interval.start)) to \(f.string(from: last)).csv"
        panel.title = "Export Timesheet"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = Timesheet.csv(ledger, in: interval, project: filterProject, now: now(), calendar: calendar)
        do {
            // A byte order mark so Excel reads accents and non-Latin text correctly.
            try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: url, options: .atomic)
            lastExport = url
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                if self?.lastExport == url { self?.lastExport = nil }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: Dock

    func updateBadge() {
        guard persists, let app = NSApp else { return }
        app.dockTile.badgeLabel = running.map { Timesheet.duration($0.duration(now: now())) }
    }

    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        if let r = running, let p = project(r.projectID) {
            menu.addItem(ClosureMenuItem("Stop \(p.name)") { HoursModel.shared.stop() })
            menu.addItem(.separator())
        }
        for p in ledger.projects where p.id != running?.projectID {
            menu.addItem(ClosureMenuItem("Start \(p.name)") { HoursModel.shared.start(p.id) })
        }
        return menu
    }
}

/// An NSMenuItem that runs a closure, for the Dock menu.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

// MARK: - Demo data

extension HoursModel {
    /// A fixed, realistic week for the website screenshot: Friday afternoon with a timer running.
    static var demo: HoursModel {
        var cal = Calendar.current
        cal.firstWeekday = 2 // Monday, as most timesheets start.
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 15, minute: 47, second: 12))!
        let northwind = Project(name: "Northwind website", color: 0, rate: 85)
        let atlas = Project(name: "Atlas iOS app", color: 1, rate: 95)
        let harbor = Project(name: "Harbor analytics", color: 2, rate: 70)
        let studio = Project(name: "Studio admin", color: 3, rate: nil)
        var entries: [Entry] = []
        func add(_ p: Project, _ day: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int, _ note: String, endDay: Int? = nil) {
            let s = cal.date(from: DateComponents(year: 2026, month: day < 0 ? 10 : 11, day: day < 0 ? -day : day, hour: h1, minute: m1))!
            let ed = endDay ?? day
            let e = cal.date(from: DateComponents(year: 2026, month: ed < 0 ? 10 : 11, day: ed < 0 ? -ed : ed, hour: h2, minute: m2))!
            entries.append(Entry(projectID: p.id, start: s, end: e, note: note))
        }
        // Last week (October 26 to 30, as negative days).
        for d in [-26, -27, -28, -29, -30] {
            add(northwind, d, 9, 0, 12, 30, "Page templates")
            add(atlas, d, 13, 30, 17, 15, "Sprint work")
        }
        add(studio, -30, 17, 15, 18, 0, "Invoices")
        // This week.
        add(northwind, 2, 9, 5, 12, 40, "Homepage hero and navigation")
        add(studio, 2, 12, 40, 13, 10, "Inbox and invoices")
        add(atlas, 2, 14, 0, 17, 50, "Onboarding screens")
        add(harbor, 3, 8, 45, 11, 30, "Dashboard queries")
        add(northwind, 3, 11, 45, 13, 0, "Client review call")
        add(atlas, 3, 14, 15, 18, 5, "Settings and sign in")
        add(northwind, 4, 9, 30, 12, 15, "Product grid")
        add(harbor, 4, 13, 0, 16, 40, "Retention cohort chart")
        add(harbor, 4, 22, 30, 0, 50, "Fixing the nightly import", endDay: 5)
        add(atlas, 5, 10, 0, 13, 20, "Push notifications")
        add(studio, 5, 13, 20, 14, 0, "Proposal for Kestrel")
        add(northwind, 5, 14, 30, 17, 45, "Checkout flow")
        add(northwind, 6, 9, 0, 11, 50, "Accessibility pass")
        add(harbor, 6, 12, 15, 14, 0, "Weekly report")
        entries.append(Entry(projectID: atlas.id, start: cal.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 14, minute: 12))!,
                             end: nil, note: "Onboarding flow polish"))
        let model = HoursModel(ledger: Ledger(projects: [northwind, atlas, harbor, studio], entries: entries),
                               persists: false, now: now, currency: "EUR", calendar: cal)
        return model
    }
}
