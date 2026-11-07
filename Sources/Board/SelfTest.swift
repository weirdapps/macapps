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

        print("\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }
}
