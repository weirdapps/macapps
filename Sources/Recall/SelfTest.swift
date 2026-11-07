import Foundation

/// `Recall --selftest`: checks the scheduler, the session queue, stats, CSV and persistence.
enum SelfTest {
    @MainActor
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Athens")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))!
        let today = cal.startOfDay(for: now)
        func days(_ d: Date) -> Int { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: d)).day ?? -99 }

        // Scheduler: the SM-2 ladder for a card answered Good every time.
        var c = Card(front: "a", back: "b", created: now)
        c = Scheduler.answer(c, .good, now: now, calendar: cal)
        check("first Good is 1 day", c.interval == 1 && days(c.due) == 1 && c.reps == 1)
        check("due lands on the start of a day", c.due == cal.startOfDay(for: c.due))
        c = Scheduler.answer(c, .good, now: now, calendar: cal)
        check("second Good is 6 days", c.interval == 6 && c.reps == 2)
        c = Scheduler.answer(c, .good, now: now, calendar: cal)
        check("third Good multiplies by ease (6 x 2.5 = 15)", c.interval == 15 && c.ease == 2.5)
        check("reviewed date is recorded", c.reviewed == now && !c.isNew)

        // Again: back in the session in a minute, ease drops, lapse counted.
        let lapsed = Scheduler.answer(c, .again, now: now, calendar: cal)
        check("Again resets reps and interval", lapsed.reps == 0 && lapsed.interval == 0)
        check("Again counts a lapse on a learned card", lapsed.lapses == 1)
        check("Again lowers ease by 0.2", abs(lapsed.ease - 2.3) < 1e-9)
        check("Again is due again in a minute", lapsed.due == now.addingTimeInterval(Scheduler.relearnDelay))
        let freshAgain = Scheduler.answer(Card(front: "a", back: "b", created: now), .again, now: now, calendar: cal)
        check("Again on a new card is not a lapse", freshAgain.lapses == 0)

        // Ease floor.
        var floor = Card(front: "a", back: "b", created: now)
        for _ in 0..<10 { floor = Scheduler.answer(floor, .again, now: now, calendar: cal) }
        check("ease never goes below 1.3", floor.ease == Scheduler.minEase)
        for _ in 0..<5 { floor = Scheduler.answer(floor, .hard, now: now, calendar: cal) }
        check("Hard keeps ease at the floor", floor.ease == Scheduler.minEase)

        // The four buttons order their intervals.
        var mature = Card(front: "a", back: "b", created: now)
        mature.reps = 4; mature.interval = 20; mature.ease = 2.5; mature.reviewed = now
        let ladder = Grade.allCases.map { Scheduler.interval(for: mature, $0) }
        check("Again < Hard < Good < Easy", ladder[0] < ladder[1] && ladder[1] < ladder[2] && ladder[2] < ladder[3])
        check("Hard is 1.2x, Good is ease x", ladder[1] == 24 && ladder[2] == 50)
        check("Easy adds a bonus and raises ease", ladder[3] == 65 && Scheduler.answer(mature, .easy, now: now, calendar: cal).ease == 2.65)
        let newLadder = Grade.allCases.map { Scheduler.interval(for: Card(front: "", back: "", created: now), $0) }
        check("new card: 0, 1, 1, 4 days", newLadder == [0, 1, 1, 4])
        var huge = mature
        huge.interval = 30_000
        check("intervals are capped at 100 years", Scheduler.interval(for: huge, .easy) == Scheduler.maxInterval)
        check("interval labels", Scheduler.label(days: 0) == "1m" && Scheduler.label(days: 6) == "6d"
            && Scheduler.label(days: 21) == "3w" && Scheduler.label(days: 90) == "3mo" && Scheduler.label(days: 365) == "1y"
            && Scheduler.label(days: 548) == "1.5y")

        // Session queue: Again puts the card back a few places later; the session ends when the queue is empty.
        let ids = (0..<5).map { _ in UUID() }
        var s = Session(deckID: UUID(), queue: ids, started: now)
        s.record(.again)
        check("Again requeues three cards later", s.queue.count == 5 && s.queue[3] == ids[0] && s.current == ids[1])
        var order: [UUID] = []
        while let id = s.current { order.append(id); s.record(.good) }
        check("requeued card comes back after three others", order == [ids[1], ids[2], ids[3], ids[0], ids[4]])
        check("session finishes with tally", s.finished && s.answered == 6 && s.tally[.again] == 1 && s.tally[.good] == 5)
        check("correct share excludes Again", abs((s.correct ?? 0) - 5.0 / 6) < 1e-9 && s.progress == 1)
        check("empty session is finished", Session(deckID: UUID(), queue: [], started: now).finished)

        // Stats, due counts and the new card limit.
        var deck = Deck(name: "Test")
        for i in 0..<30 { deck.cards.append(Card(front: "n\(i)", back: "b", created: now.addingTimeInterval(Double(i)))) }
        for i in 0..<10 {
            var r = Card(front: "r\(i)", back: "b", created: now)
            r.reviewed = now.addingTimeInterval(-86_400 * 3)
            r.reps = 2
            r.interval = i < 4 ? 30 : 3
            r.due = cal.date(byAdding: .day, value: i < 6 ? (i < 3 ? -2 : 0) : 5, to: today)!
            deck.cards.append(r)
        }
        let reviews = (0..<10).map { i in
            Review(cardID: UUID(), deckID: deck.id, date: now.addingTimeInterval(-86_400 * Double(i + 1)), grade: i < 2 ? .again : .good, wasNew: false)
        } + [Review(cardID: UUID(), deckID: deck.id, date: now.addingTimeInterval(-60), grade: .good, wasNew: true)]
        let st = DeckStats(deck: deck, reviews: reviews, newPerDay: 20, now: now, calendar: cal)
        check("due reviews count overdue and today", st.dueReviews == 6)
        check("new cards capped by today's remaining allowance", st.newToday == 19 && st.newCards == 30)
        check("due today adds reviews and new", st.dueToday == 25)
        check("learned and mature", st.learned == 10 && st.mature == 4)
        check("retention over 30 days ignores new card reviews", st.retention == 0.8)
        check("no reviews means no retention", DeckStats.retention([], now: now) == nil)
        let forecast = DeckStats.forecast(deck, days: 7, now: now, calendar: cal)
        check("forecast folds overdue into today", forecast[0] == 6 && forecast[5] == 4 && forecast.reduce(0, +) == 10)
        let queue = RecallModel.queue(for: deck, newAllowed: st.newToday, now: now, calendar: cal)
        check("queue holds due reviews and allowed new cards", queue.count == 25 && Set(queue).count == 25)
        check("queue starts with the most overdue reviews", queue.prefix(3).allSatisfy { id in deck.cards.first { $0.id == id }.map { $0.due < today } == true })
        check("queue mixes new cards in", deck.cards.first { $0.id == queue[3] }?.isNew == true)
        check("zero allowance studies reviews only", RecallModel.queue(for: deck, newAllowed: 0, now: now, calendar: cal).count == 6)

        // Due labels.
        var labelled = deck.cards[30]
        check("due label for overdue", Format.due(labelled, now: now, calendar: cal) == "Overdue")
        labelled.due = cal.date(byAdding: .day, value: 1, to: today)!
        check("due label for tomorrow", Format.due(labelled, now: now, calendar: cal) == "Tomorrow")
        labelled.due = cal.date(byAdding: .day, value: 9, to: today)!
        check("due label in days", Format.due(labelled, now: now, calendar: cal) == "In 9 days")
        check("due label for a new card", Format.due(deck.cards[0], now: now, calendar: cal) == "New")

        // Markdown-lite.
        check("markdown is stripped for the table", Format.plain("**bold** and *it* `x`") == "bold and it x")
        check("line breaks become spaces in the table", Format.plain("one\ntwo") == "one \u{00B7} two")
        let rich = Format.rich("a **b**")
        check("bold runs are styled", rich.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        check("broken markdown still shows", String(Format.rich("[unclosed *").characters) == "[unclosed *")

        // CSV and TSV.
        let csv = "front,back\r\nhola,hello\n\"a, b\",\"say \"\"hi\"\"\"\n\"two\nlines\",x\n\n,empty front\nonly one\n"
        let pairs = CSV.cards(from: csv)
        check("CSV header skipped and bad rows dropped", pairs.count == 3)
        check("CSV plain row", pairs.first.map { $0.front == "hola" && $0.back == "hello" } == true)
        check("CSV quoted comma and doubled quotes", pairs.count > 1 && pairs[1].front == "a, b" && pairs[1].back == "say \"hi\"")
        check("CSV quoted line break", pairs.count > 2 && pairs[2].front == "two\nlines")
        let tsv = CSV.cards(from: "\u{FEFF}perro\tdog\tnoun\ngato\tcat", pathExtension: "txt")
        check("TSV detected, BOM dropped, extra columns ignored", tsv.count == 2 && tsv[0].front == "perro" && tsv[0].back == "dog")
        check("delimiter from extension", CSV.delimiter(for: "a,b", pathExtension: "tsv") == "\t")
        check("semicolon delimiter", CSV.cards(from: "uno;one\ndos;two").count == 2)
        let tricky = [Card(front: "comma, here", back: "quote \"q\"", created: now), Card(front: "line\nbreak", back: "plain", created: now)]
        let round = CSV.cards(from: CSV.export(tricky))
        check("CSV export round trip", round.count == 2 && round[0].front == "comma, here" && round[0].back == "quote \"q\""
            && round[1].front == "line\nbreak")

        // Persistence round trip.
        var lib = Library(decks: [deck])
        lib.reviews = reviews
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recall-selftest-\(UUID().uuidString).json")
        do {
            try JSONEncoder().encode(lib).write(to: url)
            let back = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
            check("library JSON round trip", back == lib)
        } catch {
            check("library JSON round trip (\(error))", false)
        }
        try? FileManager.default.removeItem(at: url)

        // Model: undo of an answer restores card and session.
        let model = RecallModel(library: Library(decks: [deck]), persists: false, now: now)
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        model.selection = deck.id
        model.session = Session(deckID: deck.id, queue: [deck.cards[30].id], started: now)
        model.reveal()
        undo.beginUndoGrouping()
        model.answer(.good)
        undo.endUndoGrouping()
        check("answering logs a review and finishes", model.library.reviews.count == 1 && model.session?.finished == true)
        undo.undo()
        check("undo takes the answer back", model.library.reviews.isEmpty && model.session?.current == deck.cards[30].id
            && model.library.decks[0].cards[30] == deck.cards[30])
        model.endSession()
        undo.beginUndoGrouping()
        model.delete([deck.cards[0].id])
        undo.endUndoGrouping()
        check("delete removes the card", model.library.decks[0].cards.count == 39)
        undo.undo()
        check("undo restores the deleted card", model.library.decks[0].cards.count == 40 && model.library.decks[0].cards[0].id == deck.cards[0].id)
        model.undoManager = nil
        let draft = RecallModel.CardDraft(deckID: deck.id, front: "  new  ", back: "card")
        model.save(draft)
        check("saving a draft adds a trimmed card", model.library.decks[0].cards.last?.front == "new" && model.library.decks[0].cards.count == 41)

        // Undo of an edit made before a session must not end the session, and ending a session keeps the undo stack.
        let deckB = Deck(name: "Undo", cards: [Card(front: "q1", back: "a1", created: now), Card(front: "q2", back: "a2", created: now)])
        let m2 = RecallModel(library: Library(decks: [deckB]), persists: false, now: now)
        let undo2 = UndoManager()
        undo2.groupsByEvent = false
        m2.undoManager = undo2
        undo2.beginUndoGrouping()
        m2.rename(deckB.id, to: "Renamed")
        undo2.endUndoGrouping()
        m2.session = Session(deckID: deckB.id, queue: deckB.cards.map(\.id), started: now)
        undo2.undo()
        check("undoing a rename keeps the session running", m2.session != nil && m2.library.decks[0].name == "Undo")
        undo2.redo()
        m2.endSession()
        check("ending a session keeps earlier undo", undo2.canUndo)
        // Undo that removes a card in the running queue drops it from the queue instead of showing a blank card.
        undo2.beginUndoGrouping()
        m2.save(RecallModel.CardDraft(deckID: deckB.id, front: "q3", back: "a3"))
        undo2.endUndoGrouping()
        let added = m2.library.decks[0].cards[2].id
        m2.session = Session(deckID: deckB.id, queue: [added, deckB.cards[0].id], started: now)
        undo2.undo()
        check("undo removes a vanished card from the queue", m2.session?.queue == [deckB.cards[0].id] && m2.session?.finished == false)
        m2.endSession()
        undo2.beginUndoGrouping()
        m2.deleteDeck(deckB.id)
        undo2.endUndoGrouping()
        check("deleting the last deck clears the selection", m2.selection == nil && m2.deck == nil)
        undo2.undo()
        check("undoing a deck delete selects it again", m2.selection == deckB.id)

        // Importing the same file twice does not duplicate cards; a new name makes a new deck.
        let m3 = RecallModel(library: Library(), persists: false, now: now)
        let file = URL(fileURLWithPath: "/tmp/Verbs.csv")
        let filePairs = [Pair(front: "ser", back: "to be"), Pair(front: "ir", back: "to go"), Pair(front: "ser", back: "to be")]
        m3.apply([RecallModel.ParsedFile(url: file, pairs: filePairs)])
        check("import makes a deck named after the file, without repeats", m3.library.decks.count == 1
            && m3.library.decks[0].name == "Verbs" && m3.library.decks[0].cards.count == 2 && m3.selection == m3.library.decks[0].id)
        m3.apply([RecallModel.ParsedFile(url: file, pairs: filePairs + [Pair(front: "dar", back: "to give")])])
        check("reimport adds only the new card", m3.library.decks.count == 1 && m3.library.decks[0].cards.count == 3
            && m3.notice?.message.contains("already there") == true)
        m3.apply([RecallModel.ParsedFile(url: URL(fileURLWithPath: "/tmp/empty.csv"), pairs: []),
                  RecallModel.ParsedFile(url: URL(fileURLWithPath: "/tmp/gone.csv"), pairs: nil)])
        check("empty and unreadable files import nothing and say why", m3.library.decks.count == 1
            && m3.notice?.title == "Nothing new to import" && m3.notice?.message.contains("could not be read") == true)

        // File decoding and delimiters.
        let utf16 = "front\tback\nκαλημέρα\tgood morning\n".data(using: .utf16LittleEndian)!
        let decoded = CSV.decode(Data([0xFF, 0xFE]) + utf16)
        let greek = CSV.cards(from: decoded, pathExtension: "txt")
        check("UTF-16 Unicode text from Excel decodes", greek.count == 1 && greek[0].front == "καλημέρα")
        check("UTF-8 with BOM decodes", CSV.cards(from: CSV.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hola,hello".utf8))).first?.front == "hola")
        check("Latin 1 bytes still decode", CSV.decode(Data([0x63, 0x61, 0x66, 0xE9, 0x2C, 0x78])) == "caf\u{E9},x")
        check("a TSV line with commas in it stays a TSV", CSV.cards(from: "a, b, c\tletters\none, two\tnumbers").count == 2)
        check("empty file has no cards", CSV.cards(from: "").isEmpty && CSV.cards(from: CSV.decode(Data())).isEmpty)
        check("unicode fronts survive", CSV.cards(from: "日本,Japan\n🍎,apple").map(\.front) == ["日本", "🍎"])

        // Plain text for the table: fast path matches the Markdown path.
        check("plain text without markup is unchanged", Format.plain("hello world") == "hello world" && Format.plain("a\nb") == "a \u{00B7} b")
        let bigDeck = (0..<5000).map { "front number \($0) with some words" }
        let t0 = Date()
        _ = bigDeck.map(Format.plain)
        check("table text for 5000 cards takes under 0.2 s", Date().timeIntervalSince(t0) < 0.2)

        // An unreadable library is moved aside, never overwritten.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recall-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("library.json")
        try? Data("{\"decks\": [ oops".utf8).write(to: broken)
        let loaded = RecallModel.loadLibrary(at: broken)
        let aside = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        check("unreadable library is kept aside", loaded == nil && !FileManager.default.fileExists(atPath: broken.path)
            && aside.contains { $0.hasPrefix("library (unreadable") })
        try? JSONEncoder().encode(lib).write(to: broken)
        check("readable library loads", RecallModel.loadLibrary(at: broken) == lib)
        check("missing library is just empty", RecallModel.loadLibrary(at: dir.appendingPathComponent("none.json")) == nil)
        try? FileManager.default.removeItem(at: dir)

        print("\(passed) checks passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
