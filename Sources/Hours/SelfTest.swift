import Foundation

/// `Hours --selftest`: checks the timesheet maths, the timer rules, undo and persistence.
enum SelfTest {
    static func run() -> Int32 {
        MainActor.assumeIsolated { runChecks() }
    }

    @MainActor
    private static func runChecks() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Athens")!
        cal.firstWeekday = 2
        func date(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 11) -> Date {
            cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
        }
        let a = Project(name: "Alpha, Inc.", color: 0, rate: 80)
        let b = Project(name: "Beta", color: 1, rate: nil)

        // Splitting at midnight.
        let late = Entry(projectID: a.id, start: date(4, 22, 30), end: date(5, 1, 15), note: "Night \"fix\"")
        let pieces = Timesheet.pieces(of: late, now: date(6, 12), calendar: cal)
        check("cross-midnight entry splits in two", pieces.count == 2)
        check("first piece ends at midnight", pieces.first?.end == date(5, 0))
        check("pieces add up to the entry", abs(pieces.reduce(0) { $0 + $1.duration } - 2.75 * 3600) < 0.5)
        let twoNights = Entry(projectID: a.id, start: date(4, 23), end: date(6, 1))
        check("a 26 hour entry spans three days", Timesheet.pieces(of: twoNights, now: date(7, 0), calendar: cal).count == 3)
        check("zero length entry has no pieces",
              Timesheet.pieces(of: Entry(projectID: a.id, start: date(4, 9), end: date(4, 9)), now: date(4, 10), calendar: cal).isEmpty)

        // Clipping to days.
        let day4 = Timesheet.day(date(4, 12), calendar: cal), day5 = Timesheet.day(date(5, 12), calendar: cal)
        check("day before midnight counts 1:30", Timesheet.seconds(of: late, in: day4, now: date(6, 12)) == 5400)
        check("day after midnight counts 1:15", Timesheet.seconds(of: late, in: day5, now: date(6, 12)) == 4500)
        let running = Entry(projectID: b.id, start: date(5, 23), end: nil)
        check("running timer counts up to now", Timesheet.seconds(of: running, in: day5, now: date(6, 0, 30)) == 3600)
        check("running timer past midnight counts into today",
              Timesheet.seconds(of: running, in: Timesheet.day(date(6, 9), calendar: cal), now: date(6, 0, 30)) == 1800)

        // Weeks, days and periods.
        let week = Timesheet.week(containing: date(5, 12), calendar: cal)
        check("week starts on Monday November 2", week.start == date(2, 0))
        check("week has seven days", Timesheet.days(in: week, calendar: cal).count == 7)
        let last = Timesheet.interval(for: .lastWeek, now: date(5, 12), customStart: .now, customEnd: .now, calendar: cal)
        check("last week starts October 26", last.start == date(26, 0, month: 10))
        let month = Timesheet.interval(for: .thisMonth, now: date(5, 12), customStart: .now, customEnd: .now, calendar: cal)
        check("this month has 30 days", Timesheet.days(in: month, calendar: cal).count == 30)
        let custom = Timesheet.interval(for: .custom, now: .now, customStart: date(10, 15), customEnd: date(3, 8), calendar: cal)
        check("custom range orders its ends and includes both days", custom.start == date(3, 0) && custom.end == date(11, 0))
        let dst = Timesheet.week(containing: date(27, 12, month: 10), calendar: cal)
        check("the week with the clock change has seven days", Timesheet.days(in: dst, calendar: cal).count == 7)

        // Totals and earnings.
        let day = Entry(projectID: a.id, start: date(3, 9), end: date(3, 12, 30))
        let other = Entry(projectID: b.id, start: date(3, 13), end: date(3, 15))
        let byProject = Timesheet.secondsByProject([day, other, late], in: week, now: date(6, 12))
        check("seconds by project", byProject[a.id] == 3.5 * 3600 + 2.75 * 3600 && byProject[b.id] == 7200)
        check("earnings use only billed projects", abs(Timesheet.earnings(byProject, projects: [a, b]) - 80 * 6.25) < 0.001)

        // Formatting.
        check("duration h:mm", Timesheet.duration(7 * 3600 + 5 * 60 + 59) == "7:05")
        check("duration with seconds", Timesheet.duration(3723, withSeconds: true) == "1:02:03")
        check("negative duration clamps to zero", Timesheet.duration(-40) == "0:00")
        check("CSV field quoting", Timesheet.field("say \"hi\", ok") == "\"say \"\"hi\"\", ok\"" && Timesheet.field("plain") == "plain")

        // CSV.
        let ledger = Ledger(projects: [a, b], entries: [late, day, other])
        let csv = Timesheet.csv(ledger, in: week, project: nil, now: date(6, 12), calendar: cal)
        let lines = csv.split(separator: "\n").map(String.init)
        check("CSV header", lines.first == Timesheet.csvHeader)
        check("CSV has one row per entry per day", lines.count == 5)
        check("CSV row before midnight ends at 24:00", lines.contains("2026-11-04,\"Alpha, Inc.\",22:30,24:00,1.50,80.00,120.00,\"Night \"\"fix\"\"\""))
        check("CSV row after midnight starts at 00:00", lines.contains { $0.hasPrefix("2026-11-05,\"Alpha, Inc.\",00:00,01:15,1.25,80.00,100.00") })
        check("CSV unbilled project leaves rate empty", lines.contains("2026-11-03,Beta,13:00,15:00,2.00,,,"))
        let onlyB = Timesheet.csv(ledger, in: week, project: b.id, now: date(6, 12), calendar: cal)
        check("CSV filtered by project", onlyB.split(separator: "\n").count == 2)
        let clipped = Timesheet.csv(ledger, in: Timesheet.day(date(5, 12), calendar: cal), project: nil, now: date(6, 12), calendar: cal)
        check("CSV clipped to the interval", clipped.split(separator: "\n").count == 2)

        // Timer rules, undo and persistence on a model that saves nothing.
        let model = HoursModel(ledger: Ledger(projects: [a, b]), persists: false, currency: "EUR")
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        undo.beginUndoGrouping(); model.start(a.id); undo.endUndoGrouping()
        undo.beginUndoGrouping(); model.start(b.id); undo.endUndoGrouping()
        check("only one timer runs at a time", model.entries.filter(\.isRunning).count == 1 && model.running?.projectID == b.id)
        check("starting another timer stops the first", model.entries.count == 2 && model.entries[0].end != nil)
        undo.beginUndoGrouping(); model.stop(); undo.endUndoGrouping()
        check("stop ends the timer", model.running == nil)
        undo.undo()
        check("undo restarts the stopped timer", model.running?.projectID == b.id)
        undo.redo()
        check("redo stops it again", model.running == nil)
        undo.beginUndoGrouping(); model.deleteProject(a.id); undo.endUndoGrouping()
        check("deleting a project deletes its entries", model.projects.count == 1 && model.entries.allSatisfy { $0.projectID == b.id })
        undo.undo()
        check("undo brings the project and entries back", model.projects.count == 2 && model.entries.count == 2)
        check("default project is the most recent one", model.defaultProjectID == b.id)

        let data = try? JSONEncoder().encode(ledger)
        let back = data.flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
        check("ledger survives a JSON round trip", back == ledger)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hours-selftest-\(UUID().uuidString).json")
        try? data?.write(to: file)
        check("ledger survives a file round trip",
              (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) } == ledger)
        try? FileManager.default.removeItem(at: file)

        // Loading: a file that cannot be read is kept aside, never overwritten by the next save.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hours-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = dir.appendingPathComponent("ledger.json")
        check("missing ledger loads empty", Ledger.load(from: saved) == Ledger())
        try? data?.write(to: saved)
        check("saved ledger loads", Ledger.load(from: saved) == ledger)
        try? Data("{\"projects\": [ broken".utf8).write(to: saved)
        let fromBroken = Ledger.load(from: saved)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check("unreadable ledger loads empty", fromBroken == Ledger())
        check("unreadable ledger is moved aside, not lost",
              !FileManager.default.fileExists(atPath: saved.path) && kept.contains { $0.hasPrefix("ledger.unreadable-") })
        try? Data().write(to: saved)
        check("empty ledger file loads empty", Ledger.load(from: saved) == Ledger())
        try? FileManager.default.removeItem(at: dir)

        // A stale editor on a running timer must not restart it or leave two running.
        let editing = HoursModel(ledger: Ledger(projects: [a, b]), persists: false, currency: "EUR")
        editing.start(a.id)
        var stale = editing.running!
        editing.stop()
        stale.note = "Edited later"
        editing.saveEntry(stale)
        check("saving a stale running entry keeps it stopped", editing.running == nil && editing.entries.first?.note == "Edited later")
        editing.start(a.id)
        let first = editing.running!
        editing.start(b.id)
        editing.saveEntry(first)
        check("saving never leaves two timers running", editing.entries.filter(\.isRunning).count <= 1)
        editing.saveEntry(Entry(projectID: a.id, start: date(3, 9), end: nil))
        check("a new entry without an end is not a second timer", editing.entries.filter(\.isRunning).count <= 1)

        // Hourly rates typed by hand.
        check("rate 85", Timesheet.parseRate("85") == 85)
        check("rate with a decimal point", Timesheet.parseRate(" 72.50 ") == 72.5)
        check("rate with a decimal comma", Timesheet.parseRate("85,5") == 85.5)
        check("rate with grouping", Timesheet.parseRate("1,250.00") == 1250 && Timesheet.parseRate("1.250,00") == 1250
              && Timesheet.parseRate("1.250") == 1250)
        check("rate rejects text and negatives", Timesheet.parseRate("abc") == nil && Timesheet.parseRate("-5") == nil
              && Timesheet.parseRate("") == nil && Timesheet.parseRate(",") == nil)

        // Day buckets used by the charts agree with summing each day.
        let byDay = Timesheet.secondsByDay([day, other, late, running], in: week, now: date(6, 0, 30), calendar: cal)
        let agree = Timesheet.days(in: week, calendar: cal).allSatisfy { d in
            let direct = Timesheet.secondsByProject([day, other, late, running], in: Timesheet.day(d, calendar: cal), now: date(6, 0, 30))
            return (byDay[d] ?? [:]).filter { $0.value > 0 } == direct
        }
        check("day buckets match per day totals", agree && byDay[date(4, 0)]?[a.id] == 5400 && byDay[date(6, 0)]?[b.id] == 1800)

        let demo = HoursModel.demo
        check("demo has a running timer", demo.running != nil)
        check("demo week has time on five days",
              Timesheet.days(in: demo.week, calendar: demo.calendar)
                .filter { Timesheet.seconds(demo.entries, in: Timesheet.day($0, calendar: demo.calendar), now: demo.now()) > 0 }.count >= 5)

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
