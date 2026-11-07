import AppKit
import Combine
import Foundation
import Kit
import LocalAuthentication
import SwiftUI

// MARK: - Day

extension Calendar {
    /// Days are always Gregorian, whatever calendar the Mac shows, so stored dates and file names never shift.
    /// The week still starts on the user's first weekday.
    static var diary: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .current
        calendar.timeZone = .current
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }
}

/// A calendar day, independent of time and time zone. Stored as "yyyy-MM-dd".
struct Day: Hashable, Comparable, Codable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .diary) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }

    init?(_ string: String) {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
              (1...Day.daysIn(month: parts[1], year: parts[0])).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    var string: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var firstOfMonth: Day { Day(year: year, month: month, day: 1) }

    /// Noon on this day, which keeps day arithmetic clear of daylight saving changes.
    func date(_ calendar: Calendar = .diary) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
    }

    /// Pure Gregorian day arithmetic through `ordinal`, so it is exact and fast.
    func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's days_from_civil).
    var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(ordinal: Int) {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: doy - (153 * mp + 2) / 5 + 1)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][(month - 1 + 12) % 12]
    }

    func adding(months: Int, calendar: Calendar = .diary) -> Day {
        Day(calendar.date(byAdding: .month, value: months, to: date(calendar)) ?? date(calendar), calendar: calendar)
    }

    static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let day = Day(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day \(text)"))
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

// MARK: - Entry

enum Mood: Int, Codable, CaseIterable, Identifiable {
    case rough = 1, low, okay, good, great

    var id: Int { rawValue }
    var name: String { ["Rough", "Low", "Okay", "Good", "Great"][rawValue - 1] }
    var symbol: String { ["cloud.bolt.rain.fill", "cloud.drizzle.fill", "cloud.sun.fill", "sun.max.fill", "sparkles"][rawValue - 1] }
    var color: Color {
        let hex: [UInt32] = [0x6F7C99, 0x6FA2D8, 0xA898D6, 0xF0A04B, 0xE2557F]
        return Color(nsColor: rgb(hex[rawValue - 1]))
    }
}

struct Entry: Codable, Identifiable, Equatable {
    var day: Day
    var text: String
    var mood: Mood?
    var tags: [String]
    var created: Date
    var modified: Date

    var id: Day { day }
    var words: Int { Journal.wordCount(text) }
    var isBlank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mood == nil && tags.isEmpty }

    init(day: Day, text: String = "", mood: Mood? = nil, tags: [String] = [], created: Date = Date(), modified: Date = Date()) {
        self.day = day
        self.text = text
        self.mood = mood
        self.tags = tags
        self.created = created
        self.modified = modified
    }
}

/// Decodes an array of entries, skipping the ones that are damaged instead of failing the whole diary.
struct LossyEntries: Decodable {
    var entries: [Entry] = []
    var skipped = 0

    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let entry = try? container.decode(Entry.self) {
                entries.append(entry)
            } else {
                _ = try container.decode(Skip.self)
                skipped += 1
            }
        }
    }
}

struct Stats: Equatable {
    var entries = 0
    var words = 0
    var streak = 0
    var longest = 0
}

// MARK: - Journal logic

/// The pure parts of the diary: counting, searching, streaks, the month grid and Markdown export.
enum Journal {
    /// Runs of non-space characters. Scans scalars without allocating, since stats recount the whole diary as you type.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let space = v < 0x80 ? (v == 0x20 || (0x09...0x0D).contains(v)) : scalar.properties.isWhitespace
            if !space && !inWord { count += 1 }
            inWord = !space
        }
        return count
    }

    /// "#Work Trips " becomes "work-trips". Returns nil for nothing.
    static func normalizeTag(_ raw: String) -> String? {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("#") { tag.removeFirst() }
        tag = tag.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
        return tag.isEmpty ? nil : tag
    }

    /// Splits "family, #walk  books" style input into clean tags, keeping order and dropping repeats.
    static func parseTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        return raw.split(separator: ",").flatMap { $0.split(separator: " ") }
            .compactMap { normalizeTag(String($0)) }
            .filter { seen.insert($0).inserted }
    }

    /// Consecutive days with an entry, ending today, or yesterday when today is not written yet.
    static func streak(_ days: Set<Day>, today: Day) -> Int {
        let set = Set(days.map(\.ordinal))
        var n = set.contains(today.ordinal) ? today.ordinal : today.ordinal - 1
        var count = 0
        while set.contains(n) {
            count += 1
            n -= 1
        }
        return count
    }

    static func longestStreak(_ days: Set<Day>) -> Int {
        var best = 0
        var run = 0
        var last: Int?
        for n in days.map(\.ordinal).sorted() {
            run = last == n - 1 ? run + 1 : 1
            best = max(best, run)
            last = n
        }
        return best
    }

    static func stats(_ entries: [Entry], today: Day) -> Stats {
        let days = Set(entries.map(\.day))
        return Stats(entries: entries.count, words: entries.reduce(0) { $0 + $1.words },
                     streak: streak(days, today: today), longest: longestStreak(days))
    }

    /// Text and tags, ignoring case and accents. A query starting with "#" matches tags only.
    static func matches(_ entry: Entry, query raw: String) -> Bool {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        if query.hasPrefix("#") {
            guard let tag = normalizeTag(query) else { return false }
            return entry.tags.contains { $0.hasPrefix(tag) }
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entry.text.range(of: query, options: options) != nil || entry.tags.contains { $0.range(of: query, options: options) != nil }
    }

    static func search(_ entries: [Entry], query: String) -> [Entry] {
        entries.filter { matches($0, query: query) }.sorted { $0.day > $1.day }
    }

    /// A one-line excerpt around the first match, or the opening of the text.
    static func snippet(_ text: String, query: String = "", radius: Int = 48) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !q.hasPrefix("#"),
              let range = flat.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return flat.count > radius * 2 ? String(flat.prefix(radius * 2)).trimmingCharacters(in: .whitespaces) + "…" : flat
        }
        let start = flat.index(range.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        var out = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start > flat.startIndex { out = "…" + out }
        if end < flat.endIndex { out += "…" }
        return out
    }

    /// Entries from the same month and day in earlier years, newest first.
    static func onThisDay(_ entries: [Entry], day: Day) -> [Entry] {
        entries.filter { $0.day.month == day.month && $0.day.day == day.day && $0.day.year < day.year }
            .sorted { $0.day > $1.day }
    }

    /// The month as rows of seven, with nil for the blanks before the first and after the last day.
    static func monthGrid(year: Int, month: Int, calendar: Calendar = .diary) -> [Day?] {
        let first = Day(year: year, month: month, day: 1).date(calendar)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        var cells: [Day?] = Array(repeating: nil, count: lead) + (1...count).map { Day(year: year, month: month, day: $0) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    static func weekdaySymbols(_ calendar: Calendar = .diary) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    static func longDate(_ day: Day, calendar: Calendar = .diary) -> String {
        day.date(calendar).formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func markdown(_ entry: Entry, calendar: Calendar = .diary) -> String {
        var out = "# \(longDate(entry.day, calendar: calendar))\n\n"
        var meta: [String] = []
        if let mood = entry.mood { meta.append("Mood: \(mood.name)") }
        if !entry.tags.isEmpty { meta.append("Tags: " + entry.tags.map { "#" + $0 }.joined(separator: " ")) }
        if !meta.isEmpty { out += meta.joined(separator: "  \n") + "\n\n" }
        out += entry.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return out
    }

    /// Writes one Markdown file per entry into a new "Diary Export <date>" folder inside `parent` and returns it.
    /// Never reuses an existing folder.
    static func export(_ entries: [Entry], into parent: URL, on day: Day, calendar: Calendar = .diary) throws -> URL {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent("Diary Export \(day.string)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("Diary Export \(day.string) \(n)", isDirectory: true)
            n += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in entries.sorted(by: { $0.day < $1.day }) {
            try markdown(entry, calendar: calendar).write(to: folder.appendingPathComponent("\(entry.day.string).md"),
                                                          atomically: true, encoding: .utf8)
        }
        return folder
    }
}

// MARK: - Store

/// The diary: one entry per day, saved as JSON in Application Support, plus selection, search and the lock.
final class DiaryStore: ObservableObject {
    static let appName = "Diary"
    static let file = "entries.json"

    @Published private(set) var entries: [Day: Entry] = [:]
    @Published var selected: Day
    @Published var visibleMonth: Day
    @Published var query = ""
    @Published var locked = false
    @Published var lockMessage: String?
    @Published var searchFocusRequest = 0
    @Published var notice: String?
    /// True only while the lock screen shows at launch, so it asks once; a manual lock waits for the Unlock button.
    var promptToUnlock = false
    private var lastToday: Day
    private var canSave = true

    let calendar: Calendar
    private let fixedToday: Day?
    private let persists: Bool
    weak var undoManager: UndoManager?
    private var bag = Set<AnyCancellable>()

    var today: Day { fixedToday ?? Day(Date(), calendar: calendar) }

    init(entries: [Entry]? = nil, today: Day? = nil, calendar: Calendar = .diary) {
        self.calendar = calendar
        fixedToday = today
        persists = entries == nil && !Desktop.isSnapshot
        let start = today ?? Day(Date(), calendar: calendar)
        selected = start
        visibleMonth = start.firstOfMonth
        lastToday = start
        var loaded = entries ?? []
        if persists {
            let result = Self.load(from: Storage.url(app: Self.appName, file: Self.file))
            loaded = result.entries
            canSave = result.writable
            if !result.writable {
                notice = "Diary could not read its entries file safely, so changes in this session will not be saved."
            } else if let backup = result.backup {
                notice = "Some of your diary could not be read. The original file was kept as \u{201C}\(backup.lastPathComponent)\u{201D} next to your entries."
            }
        }
        self.entries = Dictionary(loaded.map { ($0.day, $0) }, uniquingKeysWith: { a, b in a.modified > b.modified ? a : b })
        guard persists else { return }
        locked = UserDefaults.standard.bool(forKey: Prefs.lockEnabled)
        promptToUnlock = locked
        $entries.dropFirst().debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.save() }.store(in: &bag)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.dayChanged() }.store(in: &bag)
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.willSleepNotification] {
            workspace.publisher(for: name).sink { [weak self] _ in self?.lockIfAway() }.store(in: &bag)
        }
    }

    /// Reads the entries file, skipping any entry that cannot be decoded. When anything is skipped, or the file is
    /// not JSON at all, the original is copied aside first, so the next save can never destroy what was there.
    static func load(from url: URL) -> (entries: [Entry], backup: URL?, writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil, true) }
        guard let data = try? Data(contentsOf: url) else { return ([], nil, false) }
        if data.isEmpty { return ([], nil, true) }
        let decoded = try? JSONDecoder().decode(LossyEntries.self, from: data)
        if let decoded, decoded.skipped == 0 { return (decoded.entries, nil, true) }
        let stamp = Day(Date()).string
        var backup = url.deletingLastPathComponent().appendingPathComponent("entries unreadable \(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingLastPathComponent().appendingPathComponent("entries unreadable \(stamp) \(n).json")
            n += 1
        }
        // Without a safe copy, saving would replace the only one, so the diary stays read only for this session.
        guard (try? FileManager.default.copyItem(at: url, to: backup)) != nil else { return (decoded?.entries ?? [], nil, false) }
        return (decoded?.entries ?? [], backup, true)
    }

    func save() {
        guard persists, canSave else { return }
        Storage.save(journal.sorted { $0.day < $1.day }, app: Self.appName, file: Self.file)
    }

    /// Entries with something in them. A day holding only spaces while it is being typed is not one yet.
    var journal: [Entry] { entries.values.filter { !$0.isBlank } }
    var hasEntries: Bool { entries.values.contains { !$0.isBlank } }
    func entry(_ day: Day) -> Entry? { entries[day].flatMap { $0.isBlank ? nil : $0 } }
    var stats: Stats { Journal.stats(journal, today: today) }
    var results: [Entry] { Journal.search(journal, query: query) }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var current: Entry? { entries[selected] }
    func isFuture(_ day: Day) -> Bool { day > today }
    func onThisDay(_ day: Day) -> [Entry] { Journal.onThisDay(journal, day: day) }

    /// At midnight, a window left on today moves on to the new today.
    private func dayChanged() {
        let now = today
        if selected == lastToday { select(now) }
        lastToday = now
        objectWillChange.send()
    }

    // MARK: Navigation

    func select(_ day: Day) {
        withAnimation(.snappy(duration: 0.22)) {
            selected = day
            visibleMonth = day.firstOfMonth
        }
    }

    func goToday() { select(today) }
    func step(days: Int) { select(selected.adding(days: days)) }

    func step(months: Int) {
        withAnimation(.snappy(duration: 0.22)) { visibleMonth = visibleMonth.adding(months: months, calendar: calendar) }
    }

    // MARK: Editing

    func setText(_ text: String, for day: Day) {
        guard !isFuture(day), text != (entries[day]?.text ?? "") else { return }
        change(day, action: nil) { $0.text = text }
    }

    func setMood(_ mood: Mood?, for day: Day) {
        change(day, action: "Mood") { $0.mood = mood }
    }

    func addTags(_ raw: String, to day: Day) {
        let new = Journal.parseTags(raw).filter { !(entries[day]?.tags.contains($0) ?? false) }
        guard !new.isEmpty else { return }
        change(day, action: "Add Tag") { $0.tags += new }
    }

    func removeTag(_ tag: String, from day: Day) {
        change(day, action: "Remove Tag") { $0.tags.removeAll { $0 == tag } }
    }

    func delete(_ day: Day) {
        guard entries[day] != nil else { return }
        let old = entries[day]
        entries[day] = nil
        registerUndo(day, old: old, action: "Delete Entry")
    }

    /// Applies `edit` to the day's entry (creating it), drops it again if it ends up blank, and records undo.
    private func change(_ day: Day, action: String?, _ edit: (inout Entry) -> Void) {
        guard !isFuture(day) else { return }
        let old = entries[day]
        var entry = old ?? Entry(day: day)
        edit(&entry)
        entry.modified = Date()
        entries[day] = entry.text.isEmpty && entry.mood == nil && entry.tags.isEmpty ? nil : entry
        if let action { registerUndo(day, old: old, action: action) }
    }

    private func registerUndo(_ day: Day, old: Entry?, action: String) {
        guard let undoManager else { return }
        let now = entries[day]
        undoManager.registerUndo(withTarget: self) { store in
            store.entries[day] = old
            store.registerUndo(day, old: now, action: action)
        }
        undoManager.setActionName(action)
    }

    // MARK: Export

    func exportAll() {
        guard hasEntries else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose where to put the Diary Export folder. Each entry becomes one Markdown file."
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        do {
            let folder = try Journal.export(journal, into: parent, on: today, calendar: calendar)
            revealInFinder([folder])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func confirmDelete() {
        guard let entry = current else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the entry for \(Journal.longDate(entry.day, calendar: calendar))?"
        alert.informativeText = "You can bring it back with Undo."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { withAnimation(.snappy) { delete(entry.day) } }
    }

    // MARK: Lock

    func lock() {
        query = ""
        withAnimation(.snappy) { locked = true }
    }

    private func lockIfAway() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Prefs.lockEnabled), defaults.object(forKey: Prefs.lockOnSleep) as? Bool ?? true { lock() }
    }

    func unlock() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // A Mac with no password cannot verify anyone, so the lock cannot hold the diary hostage.
            lockMessage = nil
            withAnimation(.snappy) { locked = false }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "unlock your diary") { [weak self] ok, failure in
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.lockMessage = nil
                    withAnimation(.snappy) { self.locked = false }
                } else if let code = (failure as? LAError)?.code, code != .userCancel, code != .appCancel, code != .systemCancel {
                    self.lockMessage = failure?.localizedDescription
                }
            }
        }
    }

    static var canAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }
}

enum Prefs {
    static let lockEnabled = "lockEnabled"
    static let lockOnSleep = "lockOnSleep"
}
