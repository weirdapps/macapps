import Foundation

/// `Score --selftest`: exercises the game rules, the parser, undo and persistence without touching the user's data.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var failures = 0, checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL: \(name)") }
        }

        let a = Player(name: "Ann", color: 0), b = Player(name: "Ben", color: 1), c = Player(name: "Cat", color: 2)

        // Totals and leaders.
        var g = Game(name: "Test", players: [a, b, c])
        check(g.leaders.isEmpty, "no leader before any score")
        check(g.resultText == nil, "no result text before any score")
        g.addRound()
        g.setScore(10, round: 0, player: 0)
        g.setScore(25, round: 0, player: 1)
        g.addRound()
        g.setScore(30, round: 1, player: 0)
        g.setScore(-5, round: 1, player: 1)
        check(g.totals == [40, 20, 0], "totals sum rounds and treat blanks as 0")
        check(g.leaders == [0], "highest total leads")
        check(g.rank(of: 0) == 1 && g.rank(of: 1) == 2 && g.rank(of: 2) == 3, "ranking highest wins")
        check(g.resultText == "Ann leads", "leader text")
        check(g.standingText(0) == "Ahead by 20" && g.standingText(2) == "40 behind", "standing text")
        g.rule = .lowest
        check(g.leaders == [2], "lowest total leads under lowest wins")
        check(g.rank(of: 0) == 3, "ranking lowest wins")
        g.rule = .highest
        g.setScore(15, round: 1, player: 1)
        check(g.leaders == [0, 1], "a tie has two leaders")
        check(g.rank(of: 1) == 1 && g.rank(of: 2) == 3, "ties share a rank and skip the next")
        check(g.resultText == "Ann and Ben are tied", "tie text")
        check(g.standingText(1) == "Tied for the lead", "standing text on a tie")
        g.setScore(99, round: 7, player: 0)
        check(g.totals == [40, 40, 0], "out of range cells are ignored")

        // Quick buttons.
        var q = Game(name: "Tally", players: [a, b])
        q.add(1, player: 0)
        check(q.rounds.count == 1 && q.rounds[0] == [1, nil], "quick add starts the first round")
        q.add(5, player: 0)
        q.add(-1, player: 1)
        check(q.rounds[0] == [6, -1], "quick add accumulates in the current round")
        q.addRound()
        q.add(1, player: 1)
        check(q.rounds[1] == [nil, 1] && q.totals == [6, 0], "quick add goes to the last round")
        q.removeRound(1)
        check(q.rounds.count == 1 && q.totals == [6, -1], "removing a round drops its points")

        // Target ends the game, a correction reopens it, a manual end sticks.
        var t = Game(name: "Race", players: [a, b], target: 100)
        t.addRound()
        t.setScore(60, round: 0, player: 0)
        check(!t.isOver, "below target keeps playing")
        t.setScore(110, round: 0, player: 1)
        check(t.isOver && t.endedByTarget, "reaching the target ends the game")
        check(t.resultText == "Ben wins", "winner text")
        t.setScore(90, round: 0, player: 1)
        check(!t.isOver, "a correction below target reopens the game")
        t.end()
        t.setScore(50, round: 0, player: 1)
        check(t.isOver, "a manually ended game stays ended")
        t.resume()
        check(!t.isOver, "resume reopens")
        var hearts = Game(name: "Hearts", players: [a, b], rule: .lowest, target: 100)
        hearts.add(104, player: 0)
        hearts.add(40, player: 1)
        check(hearts.isOver && hearts.leaders == [1], "lowest wins ends when someone passes the target")

        // Rematch.
        let r = t.rematch()
        check(r.id != t.id && r.players.map(\.name) == ["Ann", "Ben"], "rematch keeps the players")
        check(r.players[0].id != t.players[0].id, "rematch gets fresh player ids")
        check(r.rule == t.rule && r.target == 100, "rematch keeps the rules")
        check(r.rounds == [[nil, nil]] && !r.isOver, "rematch starts empty with one round")

        // Parser.
        check(ScoreParser.parse("12") == .some(12), "parse plain number")
        check(ScoreParser.parse(" +5 ") == .some(5), "parse plus sign and spaces")
        check(ScoreParser.parse("-3") == .some(-3) && ScoreParser.parse("\u{2212}3") == .some(-3), "parse minus signs")
        check(ScoreParser.parse("1,250") == .some(1250), "parse thousands separator")
        check(ScoreParser.parse("") == .some(nil), "empty text clears the cell")
        check(ScoreParser.parse("abc") == nil && ScoreParser.parse("1.5") == nil, "reject non scores")

        // Ordinals.
        check([1, 2, 3, 4, 11, 12, 13, 21, 22].map(ordinal) == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd"],
              "ordinals")

        // Model, undo and redo.
        let model = ScoreModel()
        let undo = UndoManager()
        undo.groupsByEvent = false
        model.undoManager = undo
        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        step { model.start(Game(name: "  ", players: [Player(name: "", color: 0), b])) }
        check(model.games.count == 1 && model.current?.name == "Game 1", "start names an untitled game")
        check(model.current?.players[0].name == "Player 1", "start names an unnamed player")
        check(model.current?.rounds.count == 1, "start opens the first round")
        step { model.updateCurrent("Add") { $0.add(5, player: 1) } }
        step { model.updateCurrent("Add") { $0.add(5, player: 1) } }
        check(model.current?.total(1) == 10, "model applies quick adds")
        undo.undo()
        check(model.current?.total(1) == 5, "undo reverts the last change")
        undo.redo()
        check(model.current?.total(1) == 10, "redo reapplies it")
        let first = model.selection
        step { model.rematch() }
        check(model.games.count == 2 && model.selection != first, "rematch selects the new game")
        step { model.delete([model.selection!]) }
        check(model.games.count == 1 && model.selection == first, "delete falls back to another game")
        undo.undo()
        check(model.games.count == 2, "undo restores a deleted game")
        step { model.toggleEnded() }
        check(model.current?.isOver == true && model.history.count == 1 && model.inProgress.count == 1, "ending moves a game to history")
        check(model.current?.sidebarSubtitle.hasPrefix("No scores") == true, "history subtitle of an empty game")

        // Persistence round trip on a temporary file.
        let demo = ScoreModel.demo
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("score-selftest-\(UUID().uuidString).json")
        do {
            let data = try JSONEncoder().encode(Library(games: demo.games, selection: demo.selection))
            try data.write(to: url)
            let back = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
            check(back.games == demo.games && back.selection == demo.selection, "library survives a JSON round trip")
        } catch {
            check(false, "persistence: \(error)")
        }
        try? FileManager.default.removeItem(at: url)

        // Demo data sanity.
        check(demo.current?.name == "Rummy" && demo.current?.resultText == "Maria leads", "demo leader")
        let hearts2 = demo.games.first { $0.name == "Hearts" }
        check(hearts2?.isOver == true && hearts2?.resultText == "Eleni wins", "demo hearts winner under lowest wins")

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
