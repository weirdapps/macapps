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
        check("day arithmetic crosses months", Day(year: 2026, month: 3, day: 1).adding(days: -1) == Day(year: 2026, month: 2, day: 28))
        check("leap year", Day(year: 2028, month: 2, day: 28).adding(days: 1) == Day(year: 2028, month: 2, day: 29))
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
        check("word count with unicode and no-break spaces", Journal.wordCount("  Καλημέρα\u{00A0}κόσμε 👋🏽 café\r\n") == 4)
        check("empty word count", Journal.wordCount("  \n ") == 0)
        check("tag normalised", Journal.normalizeTag("  #Work Trips ") == "work-trips")
        check("empty tag", Journal.normalizeTag(" # ") == nil)
        check("tags parsed", Journal.parseTags("family, #walk  Books, walk") == ["family", "walk", "books"])

        // Streaks.
        let days: Set<Day> = Set((0..<5).map { today.adding(days: -$0) } + [today.adding(days: -9)])
        check("streak ending today", Journal.streak(days, today: today) == 5)
        check("streak ending yesterday", Journal.streak(days.subtracting([today]), today: today) == 4)
        check("broken streak", Journal.streak(days, today: today.adding(days: 3)) == 0)
        check("longest streak", Journal.longestStreak(days.union([today.adding(days: -10)])) == 5)
        check("streak across new year", Journal.streak([Day(year: 2026, month: 1, day: 1), Day(year: 2025, month: 12, day: 31)],
                                                       today: Day(year: 2026, month: 1, day: 1)) == 2)

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
        let stats = Journal.stats(all, today: today)
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
        store.setText("Future", for: today.adding(days: 1))
        check("future days stay empty", store.entries[today.adding(days: 1)] == nil)
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

        // Dates that do not exist are rejected, and day arithmetic is exact Gregorian.
        check("Feb 31 rejected", Day("2026-02-31") == nil && Day("2027-02-29") == nil && Day("2028-02-29") != nil)
        check("empty and odd day strings rejected", Day("") == nil && Day("2026-11") == nil && Day("0-0-0") == nil && Day("2026-11-07-1") == nil)
        check("epoch ordinal", Day(year: 1970, month: 1, day: 1).ordinal == 0 && Day(ordinal: 0) == Day(year: 1970, month: 1, day: 1))
        check("ordinal round trips", stride(from: -200_000, to: 200_000, by: 97).allSatisfy { Day(ordinal: $0).ordinal == $0 })
        let base = Day(year: 1999, month: 12, day: 30)
        check("day arithmetic agrees with Calendar", stride(from: -4000, to: 4000, by: 13).allSatisfy {
            base.adding(days: $0) == Day(cal.date(byAdding: .day, value: $0, to: base.date(cal))!, calendar: cal)
        })
        check("diary calendar is Gregorian", Calendar.diary.identifier == .gregorian)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = cal.timeZone
        check("days ignore the Mac's display calendar", Day(today.date(cal)) == today && Day(today.date(cal), calendar: buddhist).year != 2026)
        check("longest streak with gaps", Journal.longestStreak(Set([1, 2, 3, 5, 6, 10].map { Day(year: 2026, month: 1, day: $0) })) == 3)
        check("no streak in an empty diary", Journal.streak([], today: today) == 0 && Journal.longestStreak([]) == 0)

        // Typing a space or a return first on an empty day must stay in the editor, without counting as an entry.
        let typing = DiaryStore(entries: [], today: today, calendar: cal)
        typing.setText("\n", for: today)
        check("leading return is kept while typing", typing.entries[today]?.text == "\n")
        check("whitespace is not an entry yet", typing.entry(today) == nil && !typing.hasEntries && typing.stats.entries == 0 && typing.journal.isEmpty)
        typing.setText("\nHello", for: today)
        check("then it becomes an entry", typing.entry(today)?.text == "\nHello" && typing.stats.entries == 1)
        typing.setText("", for: today)
        check("cleared text removes it", typing.entries[today] == nil)

        // Loading never loses the original file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diary-load-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("entries.json")
        let missing = DiaryStore.load(from: file)
        check("missing file is an empty diary", missing.entries.isEmpty && missing.backup == nil && missing.writable)
        try? Data().write(to: file)
        check("empty file is an empty diary", DiaryStore.load(from: file).entries.isEmpty && DiaryStore.load(from: file).writable)
        try? "this is not json".write(to: file, atomically: true, encoding: .utf8)
        let corrupt = DiaryStore.load(from: file)
        check("corrupt file is copied aside", corrupt.backup.map { (try? String(contentsOf: $0, encoding: .utf8)) == "this is not json" } == true
              && corrupt.writable)
        let goodJSON = (try? String(data: JSONEncoder().encode([a]), encoding: .utf8)) ?? "[]"
        let mixed = "[" + goodJSON.dropFirst().dropLast() + ",{\"day\":\"2026-02-31\",\"text\":\"x\",\"tags\":[],\"created\":0,\"modified\":0},42]"
        try? mixed.write(to: file, atomically: true, encoding: .utf8)
        let lossy = DiaryStore.load(from: file)
        check("damaged entries are skipped, good ones kept", lossy.entries == [a])
        check("damaged file is copied aside under a new name", lossy.backup != nil && lossy.backup != corrupt.backup
              && lossy.backup.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == mixed)
        try? JSONEncoder().encode(all).write(to: file)
        let clean = DiaryStore.load(from: file)
        check("clean file loads with no copy", clean.entries == all && clean.backup == nil && clean.writable)
        try? FileManager.default.removeItem(at: dir)

        // Ten years of long entries stay quick to count, since stats rebuild on every keystroke.
        let decade = (0..<3650).map { Entry(day: today.adding(days: -$0), text: String(repeating: "word ", count: 250)) }
        let started = Date()
        let big = Journal.stats(decade, today: today)
        let elapsed = Date().timeIntervalSince(started)
        check("ten years of stats", big.entries == 3650 && big.words == 912_500 && big.streak == 3650 && big.longest == 3650)
        check("ten years of stats in under 150 ms (took \(Int(elapsed * 1000)) ms)", elapsed < 0.15)

        print(failures == 0 ? "All \(count) checks passed." : "\(failures) of \(count) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
