import Foundation

/// `Streak --selftest`: checks the day arithmetic, the streak maths and persistence.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func d(_ y: Int, _ m: Int, _ day: Int) -> Day { Day(year: y, month: m, day: day) }

    private static func run(_ from: Day, _ count: Int) -> Set<Day> { Set((0..<count).map { from.adding($0) }) }

    private static func calendar(_ zone: String, firstWeekday: Int = 2) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.firstWeekday = firstWeekday
        return c
    }

    static func run() -> Int32 {
        // Day numbers and the civil calendar.
        check(d(1970, 1, 1).n == 0, "1 January 1970 is day 0")
        check(d(2000, 3, 1).n - d(2000, 2, 28).n == 2, "2000 is a leap year")
        check(d(1900, 3, 1).n - d(1900, 2, 28).n == 1, "1900 is not a leap year")
        check(d(2026, 11, 7).weekday == 7, "7 November 2026 is a Saturday")
        check(d(1969, 12, 31).weekday == 4, "Weekdays before 1970 are right")
        let roundTrip = (d(1890, 1, 1).n...d(2110, 12, 31).n).allSatisfy { n in
            let (y, m, dd) = Day(n: n).ymd
            return Day(year: y, month: m, day: dd).n == n
        }
        check(roundTrip, "Every day 1890 to 2110 survives a round trip through year, month and day")
        check(Day(iso: "2024-02-29") == d(2024, 2, 29) && Day(iso: "2023-02-29") == nil && Day(iso: "x") == nil,
              "ISO parsing accepts real dates only")

        // Week starts follow the calendar's first weekday.
        let saturday = d(2026, 11, 7)
        check(saturday.weekStart(firstWeekday: 2) == d(2026, 11, 2), "Monday weeks start on Monday 2 November")
        check(saturday.weekStart(firstWeekday: 1) == d(2026, 11, 1), "Sunday weeks start on Sunday 1 November")
        check(saturday.weekStart(firstWeekday: 7) == saturday, "Saturday weeks start on the Saturday itself")

        // Dates to days across daylight saving changes.
        let athens = calendar("Europe/Athens")
        // Clocks go forward at 03:00 on 29 March 2026 and back at 04:00 on 25 October 2026.
        check(hourly(athens, from: d(2026, 3, 27), days: 4), "Athens spring forward: each hour maps to its own day")
        check(hourly(athens, from: d(2026, 10, 23), days: 4), "Athens fall back: each hour maps to its own day")
        // Midnight did not exist in São Paulo on 4 November 2018; Havana skips midnight too.
        let saoPaulo = calendar("America/Sao_Paulo")
        check(hourly(saoPaulo, from: d(2018, 11, 2), days: 4), "São Paulo missing midnight keeps days distinct")
        check(Day(d(2018, 11, 4).date(in: saoPaulo), calendar: saoPaulo) == d(2018, 11, 4), "A day without a midnight still has a date")
        let auckland = calendar("Pacific/Auckland")
        check(hourly(auckland, from: d(2026, 4, 3), days: 4), "Auckland fall back keeps days distinct")
        let late = athens.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 23, minute: 59))!
        check(Day(late, calendar: athens) == d(2026, 3, 29), "23:59 on the 23 hour day is still that day")
        let utc = calendar("UTC")
        let instant = utc.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 30))!
        check(Day(instant, calendar: athens) == d(2027, 1, 1) && Day(instant, calendar: utc) == d(2026, 12, 31),
              "The same instant falls on the local day of each time zone")

        // Daily streaks.
        let feb = Streaks.daily(run(d(2026, 1, 28), 6), today: d(2026, 2, 2))
        check(feb == (6, 6), "A streak crosses the end of January")
        let newYear = Streaks.daily(run(d(2025, 12, 29), 5), today: d(2026, 1, 2))
        check(newYear == (5, 5), "A streak crosses New Year")
        let leap = Streaks.daily(run(d(2024, 2, 27), 4), today: d(2024, 3, 1))
        check(leap == (4, 4), "A streak crosses 29 February")
        let dst = Streaks.daily(run(d(2026, 3, 27), 5), today: d(2026, 3, 31))
        check(dst == (5, 5), "A streak crosses the daylight saving change")
        let pending = Streaks.daily(run(d(2026, 11, 1), 5), today: d(2026, 11, 6))
        check(pending.current == 5, "Today not yet done keeps yesterday's streak alive")
        let broken = Streaks.daily(run(d(2026, 11, 1), 4), today: d(2026, 11, 6))
        check(broken.current == 0 && broken.longest == 4, "A missed yesterday ends the current streak")
        var gaps = run(d(2026, 1, 1), 10)
        gaps.formUnion(run(d(2026, 2, 1), 3))
        check(Streaks.daily(gaps, today: d(2026, 2, 3)) == (3, 10), "Longest streak is kept after a break")
        check(Streaks.daily([], today: saturday) == (0, 0), "No check-ins, no streak")

        // Weekly targets.
        let mon = d(2026, 10, 5)
        var weekly: Set<Day> = []
        for w in 0..<4 { weekly.formUnion([mon.adding(w * 7), mon.adding(w * 7 + 2), mon.adding(w * 7 + 4)]) }
        let w1 = Streaks.weekly(weekly, perWeek: 3, today: d(2026, 11, 3), firstWeekday: 2)
        check(w1 == (4, 4), "Four met weeks, current week still open")
        weekly.formUnion([d(2026, 11, 2), d(2026, 11, 3), d(2026, 11, 4)])
        let w2 = Streaks.weekly(weekly, perWeek: 3, today: d(2026, 11, 4), firstWeekday: 2)
        check(w2 == (5, 5), "The current week counts once its goal is met")
        // Sunday 1 November is in the week of 26 October for Monday weeks, but starts a new week for Sunday weeks.
        let edge: Set<Day> = [d(2026, 10, 30), d(2026, 10, 31), d(2026, 11, 1)]
        check(Streaks.weekly(edge, perWeek: 3, today: d(2026, 11, 2), firstWeekday: 2).current == 1,
              "Monday weeks put Sunday with the days before it")
        check(Streaks.weekly(edge, perWeek: 3, today: d(2026, 11, 2), firstWeekday: 1).current == 0,
              "Sunday weeks start a new week on Sunday")
        let acrossYear: Set<Day> = [d(2025, 12, 29), d(2025, 12, 31), d(2026, 1, 2), d(2026, 1, 5), d(2026, 1, 7), d(2026, 1, 9)]
        check(Streaks.weekly(acrossYear, perWeek: 3, today: d(2026, 1, 10), firstWeekday: 2) == (2, 2),
              "A week spanning New Year counts once")

        // Completion rate.
        let today = d(2026, 11, 6)
        check(Streaks.rate(run(today.adding(-29), 30), target: .daily, today: today, created: d(2026, 1, 1)) == 1,
              "Every day of 30 is 100%")
        check(abs(Streaks.rate(run(today.adding(-14), 15), target: .daily, today: today, created: d(2026, 1, 1)) - 0.5) < 1e-9,
              "15 of 30 days is 50%")
        check(Streaks.rate(run(today.adding(-4), 5), target: .daily, today: today, created: today.adding(-4)) == 1,
              "A new habit is measured from the day it began")
        let threeAWeek = Set(stride(from: 0, to: 30, by: 2).map { today.adding(-$0) })
        check(Streaks.rate(threeAWeek, target: .weekly(3), today: today, created: d(2026, 1, 1)) == 1,
              "More than the weekly goal caps at 100%")

        // Heatmap grid.
        let grid = HeatGrid(range: .year(2026), today: today, firstWeekday: 2)
        check(grid.day(column: 0, row: 3) == d(2026, 1, 1) && grid.day(column: 0, row: 2) == nil,
              "2026 starts on a Thursday in the fourth row")
        check(grid.monthStarts().count == 12, "A calendar year shows twelve month labels")
        let past = HeatGrid(range: .pastYear, today: today, firstWeekday: 2)
        check(past.columns == 53 && past.day(column: 52, row: 4) == today, "Past 12 months ends in this week's column")

        // Persistence round trip.
        var habit = Habit(name: "Read", icon: "📚", tint: .teal, target: .weekly(4), created: d(2026, 1, 1))
        habit.done = run(d(2026, 2, 27), 4)
        habit.setNote("Chapter 3", on: d(2026, 3, 1))
        habit.setNote("   ", on: d(2026, 3, 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("streak-selftest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try? JSONEncoder().encode([habit])
        try? data?.write(to: url)
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Habit].self, from: $0) }
        check(loaded == [habit], "Habits survive a save and load")
        check(habit.notes.count == 1 && !habit.iconIsSymbol && Habit(name: "", icon: "book.fill", tint: .red, target: .daily,
              created: today).iconIsSymbol, "Blank notes are dropped and icons are told apart")
        check(String(data: data ?? Data(), encoding: .utf8)?.contains("\"2026-03-01\"") == true, "Days are stored as ISO dates")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }

    /// Walks every half hour across `days` local days and checks that the day changes exactly once per day, in order.
    private static func hourly(_ calendar: Calendar, from start: Day, days: Int) -> Bool {
        var date = start.date(in: calendar).addingTimeInterval(-12 * 3600 + 60)
        let end = start.adding(days - 1).date(in: calendar).addingTimeInterval(12 * 3600 - 60)
        var seen: [Day] = []
        while date < end {
            let day = Day(date, calendar: calendar)
            if seen.last != day { seen.append(day) }
            date.addTimeInterval(1800)
        }
        return seen == (0..<days).map { start.adding($0) }
    }
}
