import Foundation

/// `Board --selftest`: checks the board operations, search, due dates, persistence and undo.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL: \(name)") }
        }
        func titles(_ b: Board, _ c: Int) -> [String] { b.columns[c].cards.map(\.title) }

        // New boards.
        var b = Board.new("Test")
        check(b.columns.map(\.name) == ["To do", "Doing", "Done"], "a new board has To do, Doing and Done")
        let todo = b.columns[0].id, doing = b.columns[1].id, done = b.columns[2].id

        // Cards.
        let a = Card(title: "A"), bb = Card(title: "B"), c = Card(title: "C")
        for card in [a, bb, c] { b.addCard(card, to: todo) }
        check(titles(b, 0) == ["A", "B", "C"], "cards append in order")
        check(b.cardCount == 3, "card count")

        b.moveCard(a.id, to: todo, near: bb.id, after: true)
        check(titles(b, 0) == ["B", "A", "C"], "move down within a column, after the target")
        b.moveCard(c.id, to: todo, near: bb.id)
        check(titles(b, 0) == ["C", "B", "A"], "move up within a column, before the target")
        b.moveCard(a.id, to: todo, near: c.id, after: true)
        check(titles(b, 0) == ["C", "A", "B"], "move to the middle")
        check(!b.moveCard(a.id, to: todo, near: a.id), "dropping a card on itself does nothing")
        check(!b.moveCard(bb.id, to: todo, near: nil), "moving the last card to the end changes nothing")

        b.moveCard(a.id, to: doing, near: nil)
        check(titles(b, 0) == ["C", "B"] && titles(b, 1) == ["A"], "move across columns to the end")
        b.moveCard(c.id, to: doing, near: a.id)
        check(titles(b, 1) == ["C", "A"], "move across columns before a card")
        check(b.location(of: a.id)! == (1, 1), "location finds a card")

        b.updateCard(a.id) { $0.notes = "note"; $0.label = .red }
        check(b.card(a.id)?.notes == "note" && b.card(a.id)?.label == .red, "update a card")

        b.deleteCard(bb.id)
        check(b.card(bb.id) == nil && b.cardCount == 2, "delete a card")

        // Archive.
        b.moveCard(c.id, to: done, near: nil)
        b.moveCard(a.id, to: done, near: nil)
        check(b.archiveDone() == 2 && b.columns[2].cards.isEmpty, "archive the last column")
        check(b.archived.map(\.title) == ["C", "A"], "archived cards keep their order")
        check(b.archiveDone() == 0, "archiving an empty column archives nothing")
        b.restore(a.id)
        check(titles(b, 2) == ["A"] && b.archived.map(\.title) == ["C"], "restore puts a card back in the last column")
        b.archiveCard(a.id)
        check(b.archived.first?.id == a.id, "archive one card, newest first")
        b.deleteCard(c.id)
        check(b.card(c.id) == nil, "delete an archived card")

        // Columns.
        let review = b.addColumn("Review")
        check(b.columns.last?.name == "Review", "add a column at the end")
        b.renameColumn(review, to: "  Checked  ")
        check(b.columns.last?.name == "Checked", "rename trims spaces")
        b.renameColumn(review, to: "   ")
        check(b.columns.last?.name == "Checked", "an empty name is ignored")
        b.moveColumn(review, by: -1)
        check(b.columns.map(\.name) == ["To do", "Doing", "Checked", "Done"], "move a column left")
        b.moveColumn(review, to: -5)
        check(b.columns.first?.name == "Checked", "column moves clamp at the start")
        b.moveColumn(review, to: 99)
        check(b.columns.last?.name == "Checked", "column moves clamp at the end")
        b.addCard(Card(title: "X"), to: review)
        b.deleteColumn(review)
        check(b.columns.count == 3 && b.columnIndex(review) == nil, "delete a column with its cards")

        // Search.
        let card = Card(title: "Café menu draft", notes: "Ask Zoë about prices")
        check(Search.matches(card, ""), "an empty search matches")
        check(Search.matches(card, "cafe"), "search ignores accents")
        check(Search.matches(card, "MENU zoe"), "every word must match, title or notes")
        check(!Search.matches(card, "menu tea"), "a missing word fails")

        // Due dates.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Athens")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 22))!
        func day(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: cal.startOfDay(for: now))! }
        check(DueStatus.of(day(-1), now: now, calendar: cal) == .overdue, "yesterday is overdue")
        check(DueStatus.of(day(0).addingTimeInterval(3600), now: now, calendar: cal) == .today, "today")
        check(DueStatus.of(day(2), now: now, calendar: cal) == .soon, "two days is soon")
        check(DueStatus.of(day(3), now: now, calendar: cal) == .later, "three days is later")
        check(DueStatus.text(day(1), now: now, calendar: cal) == "Tomorrow", "tomorrow text")
        check(DueStatus.text(day(-1), now: now, calendar: cal) == "Yesterday", "yesterday text")
        check(DueStatus.text(day(5), now: now, calendar: cal) == "Nov 12", "date text")
        check(DueStatus.text(day(60), now: now, calendar: cal) == "Jan 6, 2027", "date text in another year")

        // Persistence.
        var dated = Board.new("Round trip")
        dated.addCard(Card(title: "Due", notes: "n", label: .teal, due: day(3)), to: dated.columns[0].id)
        dated.archived = [Card(title: "Old")]
        let file = BoardFile(boards: [dated, Board.new("Two")], selection: dated.id)
        if let data = try? JSONEncoder().encode(file), let back = try? JSONDecoder().decode(BoardFile.self, from: data) {
            check(back.boards == file.boards && back.selection == dated.id, "JSON round trip")
        } else {
            check(false, "JSON round trip")
        }

        // Store and undo.
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = BoardStore(boards: Demo.boards, persists: false)
        store.undoManager = undo
        let id = store.boards[0].id
        func step(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        let first = store.boards[0].columns[0].cards[0]
        let doneColumn = store.boards[0].columns[2].id
        step { store.moveCard(first.id, in: id, to: doneColumn, near: nil) }
        check(store.boards[0].columns[2].cards.last?.id == first.id, "store moves a card")
        check(undo.undoActionName == "Move Card", "the undo menu names the move")
        undo.undo()
        check(store.boards[0].columns[0].cards[0].id == first.id, "undo puts the card back")
        undo.redo()
        check(store.boards[0].columns[2].cards.last?.id == first.id, "redo moves it again")

        step { store.change("Delete Card", board: id) { $0.deleteCard(first.id) } }
        check(store.boards[0].card(first.id) == nil, "store deletes a card")
        undo.undo()
        check(store.boards[0].card(first.id) != nil, "undo brings a deleted card back")

        let count = store.boards.count
        step { store.deleteBoard(id) }
        check(store.boards.count == count - 1 && store.selection != id, "deleting a board selects another")
        undo.undo()
        check(store.boards.count == count && store.selection == id, "undo restores the board and the selection")

        let before = store.boards
        store.edit(board: id) { $0.updateCard(first.id) { $0.title = "Renamed" } }
        step { store.commitEdit(since: before) }
        check(undo.undoActionName == "Edit Card", "popover edits become one undo step")
        undo.undo()
        check(store.boards[0].card(first.id)?.title == first.title, "undo reverts the popover edit")
        let unchanged = store.boards
        let canUndo = undo.canUndo
        step { store.commitEdit(since: unchanged) }
        check(undo.canUndo == canUndo && store.boards == unchanged, "an unchanged popover registers nothing")

        step { store.addCard("   ", to: doneColumn, in: id) }
        check(store.boards == unchanged, "a blank quick add adds nothing")
        step { store.addCard(" Ship it ", to: doneColumn, in: id) }
        check(store.boards[0].columns[2].cards.last?.title == "Ship it", "quick add trims the title")

        // Deselecting in the sidebar keeps a board shown.
        let shown = store.selection
        store.selection = nil
        check(store.selection == shown && store.current != nil, "a nil selection keeps the current board")

        // New boards get unique names.
        let named = BoardStore(boards: [Board.new("Untitled Board"), Board.new("Untitled Board 2"), Board.new("X")], persists: false)
        named.addBoard()
        check(named.boards.last?.name == "Untitled Board 3", "a new board gets a name no other board has")
        check(named.boards.map(\.name) != [] && Set(named.boards.map(\.name)).count == named.boards.count, "board names stay unique")

        // Drags only count when the dropped text is ours.
        let dragStore = BoardStore(boards: Demo.boards, persists: false)
        let dragCard = dragStore.boards[0].columns[0].cards[0]
        _ = dragStore.beginDrag(.card(dragCard.id), text: dragCard.title)
        check(dragStore.claimDrag(text: "Text from another app") == nil, "foreign dropped text moves nothing")
        check(dragStore.draggingCard == nil, "a foreign drop ends the stale drag")
        _ = dragStore.beginDrag(.card(dragCard.id), text: dragCard.title)
        check(dragStore.claimDrag(text: dragCard.title) == .card(dragCard.id), "our own drop claims the drag")
        check(dragStore.claimDrag(text: dragCard.title) == nil, "a drag is claimed only once")
        _ = dragStore.beginDrag(.column(dragStore.boards[0].columns[1].id), text: "Doing")
        check(dragStore.draggingColumn != nil && dragStore.draggingCard == nil, "a column drag replaces a card drag")

        // Lenient loading.
        let legacy = """
        {"boards":[{"name":"Old","columns":[{"name":"To do","cards":[{"title":"Kept","label":"magenta"},{"title":"Émoji 🧪 ünïcode"}]}]}]}
        """
        if let old = BoardFile.decode(Data(legacy.utf8)) {
            let cards = old.boards.first?.columns.first?.cards ?? []
            check(cards.map(\.title) == ["Kept", "Émoji 🧪 ünïcode"], "a file with missing fields still loads its cards")
            check(cards.first?.label == CardLabel.none && cards.first?.notes == "" && old.boards[0].archived.isEmpty, "missing or unknown fields fall back to defaults")
            check(old.selection == nil, "a file without a selection loads")
        } else {
            check(false, "a file with missing fields still loads its cards")
            check(false, "missing or unknown fields fall back to defaults")
            check(false, "a file without a selection loads")
        }
        check(BoardFile.decode(Data()) == nil, "an empty file is unreadable")
        check(BoardFile.decode(Data("{\"boards\": 12}".utf8)) == nil, "a file of the wrong shape is unreadable")
        check(BoardFile.decode(Data("{\"boards\": []}".utf8))?.boards.isEmpty == true, "a file with no boards loads empty")

        // An unreadable file is set aside, never overwritten.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BoardSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("boards.json")
        try? Data("not json".utf8).write(to: broken)
        let moved = BoardFile.setAside(broken, now: now, timeZone: cal.timeZone)
        check(moved?.lastPathComponent == "boards (unreadable 2026-11-07 220000).json", "the unreadable file is renamed with the time")
        check(!FileManager.default.fileExists(atPath: broken.path) && moved.map { (try? Data(contentsOf: $0)) == Data("not json".utf8) } == true,
              "the unreadable file keeps its contents")
        try? FileManager.default.removeItem(at: dir)

        // Moving a card whose column vanished, or into a missing column, does nothing.
        var odd = Board.new("Odd")
        let lone = Card(title: "Lone")
        odd.addCard(lone, to: odd.columns[0].id)
        check(!odd.moveCard(lone.id, to: UUID(), near: nil) && odd.cardCount == 1, "a move to a missing column keeps the card")
        odd.columns = []
        odd.restore(lone.id)
        check(odd.archiveDone() == 0 && odd.columns.isEmpty, "a board without columns survives archive and restore")

        print("\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }
}
