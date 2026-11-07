import Foundation

/// `Diary --selftest`: exercises the journal logic and persistence, prints failures and returns the exit code.
enum SelfTest {
    private static var failures = 0
    private static var count = 0

    private static func check(_ name: String, _ condition: Bool) {
        count += 1
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func run() -> Int32 {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current
        let today = Day(year: 2026, month: 11, day: 7)

        // Days.
        check("day formats", today.string == "2026-11-07")
        check("day parses", Day("2026-11-07") == today)
        check("bad day rejected", Day("2026-13-01") == nil && Day("hello") == nil)
        check("day arithmetic crosses months", Day(year: 2026, month: 3, day: 1).adding(days: -1, calendar: cal) == Day(year: 2026, month: 2, day: 28))
        check("leap year", Day(year: 2028, month: 2, day: 28).adding(days: 1, calendar: cal) == Day(year: 2028, month: 2, day: 29))
        check("month arithmetic", Day(year: 2026, month: 12, day: 1).adding(months: 1, calendar: cal) == Day(year: 2027, month: 1, day: 1))
        check("day ordering", Day(year: 2025, month: 12, day: 31) < Day(year: 2026, month: 1, day: 1))
        check("day round trips through a date", Day(today.date(cal), calendar: cal) == today)

        // Month grid: November 2026 starts on a Sunday, so a Monday-first grid has six blanks.
        let grid = Journal.monthGrid(year: 2026, month: 11, calendar: cal)
        check("grid leading blanks", grid.prefix(6).allSatisfy { $0 == nil } && grid[6] == Day(year: 2026, month: 11, day: 1))
        check("grid has every day", grid.compactMap { $0 }.count == 30)
        check("grid is whole weeks", grid.count % 7 == 0)
        check("weekday symbols start Monday", Journal.weekdaySymbols(cal).count == 7 && Journal.weekdaySymbols(cal).first == cal.veryShortStandaloneWeekdaySymbols[1])

        // Words and tags.
        check("word count", Journal.wordCount("One  two\nthree\tfour ") == 4)
        check("empty word count", Journal.wordCount("  \n ") == 0)
        check("tag normalised", Journal.normalizeTag("  #Work Trips ") == "work-trips")
        check("empty tag", Journal.normalizeTag(" # ") == nil)
        check("tags parsed", Journal.parseTags("family, #walk  Books, walk") == ["family", "walk", "books"])

        // Streaks.
        let days: Set<Day> = Set((0..<5).map { today.adding(days: -$0, calendar: cal) } + [today.adding(days: -9, calendar: cal)])
        check("streak ending today", Journal.streak(days, today: today, calendar: cal) == 5)
        check("streak ending yesterday", Journal.streak(days.subtracting([today]), today: today, calendar: cal) == 4)
        check("broken streak", Journal.streak(days, today: today.adding(days: 3, calendar: cal), calendar: cal) == 0)
        check("longest streak", Journal.longestStreak(days.union([today.adding(days: -10, calendar: cal)]), calendar: cal) == 5)
        check("streak across new year", Journal.streak([Day(year: 2026, month: 1, day: 1), Day(year: 2025, month: 12, day: 31)],
                                                       today: Day(year: 2026, month: 1, day: 1), calendar: cal) == 2)

        // Search, snippets, on this day.
        let a = Entry(day: today, text: "Walked to the Café by the harbour.", mood: .good, tags: ["walk", "family"])
        let b = Entry(day: Day(year: 2025, month: 11, day: 7), text: "Rain all day.", tags: ["home"])
        let c = Entry(day: Day(year: 2024, month: 11, day: 7), text: "Coast road.", tags: ["walk"])
        let d = Entry(day: Day(year: 2025, month: 11, day: 8), text: "Not the same day.")
        let all = [a, b, c, d]
        check("search ignores case and accents", Journal.matches(a, query: "cafe") && Journal.matches(a, query: "HARBOUR"))
        check("search misses", !Journal.matches(b, query: "harbour"))
        check("blank query matches nothing", Journal.search(all, query: "  ").isEmpty)
        check("tag query", Journal.search(all, query: "#walk").map(\.day) == [a.day, c.day])
        check("plain query also finds tags", Journal.matches(b, query: "home"))
        check("snippet around match", Journal.snippet(String(repeating: "x ", count: 80) + "needle" + String(repeating: " y", count: 80),
                                                      query: "needle", radius: 10).contains("needle"))
        check("snippet is short", Journal.snippet(String(repeating: "word ", count: 100), radius: 20).count <= 41)
        check("short text snippet unchanged", Journal.snippet("Line one\nLine two") == "Line one Line two")
        check("on this day", Journal.onThisDay(all, day: today).map(\.day.year) == [2025, 2024])
        check("on this day skips the future", Journal.onThisDay(all, day: Day(year: 2024, month: 11, day: 7)).isEmpty)

        // Stats.
        let stats = Journal.stats(all, today: today, calendar: cal)
        check("stats", stats.entries == 4 && stats.words == a.words + b.words + c.words + d.words && stats.streak == 1)

        // Store editing, with no persistence.
        let store = DiaryStore(entries: [b], today: today, calendar: cal)
        store.setText("Hello there", for: today)
        check("typing creates an entry", store.entries[today]?.text == "Hello there")
        store.setMood(.great, for: today)
        store.addTags("one, two, one", to: today)
        check("mood and tags", store.entries[today]?.mood == .great && store.entries[today]?.tags == ["one", "two"])
        store.removeTag("one", from: today)
        check("remove tag", store.entries[today]?.tags == ["two"])
        store.setText("Future", for: today.adding(days: 1, calendar: cal))
        check("future days stay empty", store.entries[today.adding(days: 1, calendar: cal)] == nil)
        store.setText("", for: today)
        store.setMood(nil, for: today)
        store.removeTag("two", from: today)
        check("blank entry is dropped", store.entries[today] == nil)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        store.delete(b.day)
        undo.endUndoGrouping()
        check("delete", store.entries[b.day] == nil)
        undo.undo()
        check("undo delete", store.entries[b.day]?.text == "Rain all day.")
        undo.redo()
        check("redo delete", store.entries[b.day] == nil)

        // Persistence round trip.
        if let data = try? JSONEncoder().encode(all), let back = try? JSONDecoder().decode([Entry].self, from: data) {
            check("JSON round trip", back == all)
            check("days stored as text", String(data: data, encoding: .utf8)?.contains("\"2026-11-07\"") == true)
        } else {
            check("JSON round trip", false)
        }

        // Markdown export into a temporary folder.
        let md = Journal.markdown(a, calendar: cal)
        check("markdown heading", md.hasPrefix("# ") && md.contains("2026"))
        check("markdown meta", md.contains("Mood: Good") && md.contains("#walk #family"))
        check("markdown body", md.hasSuffix("harbour.\n"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("diary-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let first = try Journal.export(all, into: tmp, on: today, calendar: cal)
            let second = try Journal.export(all, into: tmp, on: today, calendar: cal)
            let files = try FileManager.default.contentsOfDirectory(atPath: first.path).sorted()
            check("export writes one file per entry", files == ["2024-11-07.md", "2025-11-07.md", "2025-11-08.md", "2026-11-07.md"])
            check("export never reuses a folder", first != second && second.lastPathComponent == "Diary Export 2026-11-07 2")
            let text = try String(contentsOf: first.appendingPathComponent("2026-11-07.md"), encoding: .utf8)
            check("exported file content", text == md)
        } catch {
            check("export: \(error.localizedDescription)", false)
        }
        try? FileManager.default.removeItem(at: tmp)

        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
