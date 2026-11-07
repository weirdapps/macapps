import Foundation

/// `Patience --selftest`: the rules, the deal, scoring, hints, auto-complete and statistics.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func c(_ rank: Int, _ suit: Suit) -> Card { Card(suit: suit, rank: rank) }

    /// An empty table, for building positions by hand.
    private static func empty(_ draw: DrawMode = .one) -> Board {
        var b = Board()
        b.draw = draw
        return b
    }

    static func run() -> Int32 {
        deck()
        deal()
        rules()
        moves()
        stock()
        scoring()
        helpers()
        play()
        statistics()
        review()
        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    private static func deck() {
        check(Set(Card.deck).count == 52 && Set(Card.deck.map(\.id)) == Set(0..<52), "deck has 52 distinct cards with ids 0 to 51")
        let a = Board.shuffled(seed: 4217), b = Board.shuffled(seed: 4217), other = Board.shuffled(seed: 4218)
        check(a == b, "the same seed shuffles the same way")
        check(a != other, "a different seed shuffles differently")
        check(Set(a).count == 52, "shuffle keeps every card")
        // Pin the algorithm: a game number must deal the same cards forever, on every Mac.
        var rng = SplitMix64(state: 0)
        check(rng.next() == 0xE220_A839_7B1D_CDAF, "SplitMix64 matches its reference output")
    }

    private static func deal() {
        let board = Board.deal(game: 1, draw: .three)
        check(board.tableau.map(\.count) == [1, 2, 3, 4, 5, 6, 7], "columns hold one to seven cards")
        check(board.stock.count == 24 && board.waste.isEmpty, "24 cards in the stock")
        check(board.faceUpFrom == Array(0..<7), "only the last card of each column is face up")
        check(Set(board.allCards).count == 52, "the deal uses every card once")
        check(board.draw == .three && board.score == 0 && board.moves == 0, "a deal starts at zero")
        check(Board.deal(game: 99, draw: .one).tableau == Board.deal(game: 99, draw: .three).tableau, "draw mode does not change the deal")
    }

    private static func rules() {
        check(Board.canStack(c(6, .hearts), on: c(7, .spades)), "red six on black seven")
        check(Board.canStack(c(6, .clubs), on: c(7, .diamonds)), "black six on red seven")
        check(!Board.canStack(c(6, .hearts), on: c(7, .diamonds)), "not red on red")
        check(!Board.canStack(c(5, .hearts), on: c(7, .spades)), "not two ranks down")
        check(!Board.canStack(c(8, .hearts), on: c(7, .spades)), "not one rank up")
        check(Board.canStack(c(13, .hearts), on: nil), "a king fills an empty column")
        check(!Board.canStack(c(12, .spades), on: nil), "a queen does not")
        check(Board.canFound(c(1, .clubs), on: nil), "an ace starts a foundation")
        check(!Board.canFound(c(2, .clubs), on: nil), "a two does not")
        check(Board.canFound(c(2, .clubs), on: c(1, .clubs)), "a foundation builds up by suit")
        check(!Board.canFound(c(2, .spades), on: c(1, .clubs)), "not in another suit")
        check(!Board.canFound(c(3, .clubs), on: c(1, .clubs)), "not skipping a rank")
    }

    private static func moves() {
        var b = empty()
        b.tableau[0] = [c(9, .spades), c(8, .hearts), c(7, .clubs)]
        b.faceUpFrom[0] = 1
        b.tableau[1] = [c(9, .diamonds)]
        b.tableau[2] = [c(5, .hearts)]
        check(b.movable(from: .tableau(0), count: 2) == [c(8, .hearts), c(7, .clubs)], "a face up run can be picked up")
        check(b.movable(from: .tableau(0), count: 3) == nil, "a face down card cannot")
        check(b.isLegal(Move(from: .tableau(0), to: .tableau(1), count: 2)) == false, "eight of hearts does not go on a red nine")
        b.tableau[1] = [c(9, .clubs)]
        let run = Move(from: .tableau(0), to: .tableau(1), count: 2)
        check(b.isLegal(run), "the run goes on the black nine")
        check(!b.isLegal(Move(from: .tableau(0), to: .tableau(0), count: 1)), "a pile cannot move onto itself")
        check(!b.isLegal(Move(from: .tableau(0), to: .waste)), "nothing moves to the waste")
        check(!b.isLegal(Move(from: .tableau(0), to: .foundation(0), count: 2)), "only one card at a time goes up")
        let before = b
        check(b.apply(run) && b.tableau[1].count == 3 && b.tableau[0] == [c(9, .spades)], "applying a run moves it")
        check(b.faceUpFrom[0] == 0 && b.score == Scoring.turnOver, "the uncovered card turns over and scores 5")
        var illegal = before
        check(!illegal.apply(Move(from: .tableau(2), to: .tableau(1))) && illegal == before, "an illegal move changes nothing")

        // A broken run (not alternating) cannot be picked up as one.
        var broken = empty()
        broken.tableau[0] = [c(8, .hearts), c(7, .diamonds)]
        check(broken.movable(from: .tableau(0), count: 2) == nil, "a run must alternate colours")
    }

    private static func stock() {
        var b = empty(.three)
        b.stock = [c(1, .spades), c(2, .spades), c(3, .spades), c(4, .spades)]
        b.dealFromStock()
        check(b.waste == [c(4, .spades), c(3, .spades), c(2, .spades)] && b.stock == [c(1, .spades)], "draw three turns over three")
        b.dealFromStock()
        check(b.stock.isEmpty && b.waste.count == 4 && b.waste.last == c(1, .spades), "the last card comes alone")
        b.dealFromStock()
        check(b.waste.isEmpty && b.stock == [c(1, .spades), c(2, .spades), c(3, .spades), c(4, .spades)],
              "recycling restores the original stock order")
        check(b.recycles == 1 && b.moves == 3, "recycles and moves are counted")
        var none = empty()
        check(!none.dealFromStock(), "an empty stock and waste deal nothing")
    }

    private static func scoring() {
        var b = empty()
        b.waste = [c(1, .hearts)]
        b.apply(Move(from: .waste, to: .foundation(2)))
        check(b.score == 10, "waste to foundation scores 10")
        b.waste = [c(13, .spades)]
        b.apply(Move(from: .waste, to: .tableau(0)))
        check(b.score == 15, "waste to tableau scores 5")
        b.foundations[1] = [c(1, .diamonds), c(2, .diamonds), c(3, .diamonds)]
        b.tableau[1] = [c(4, .spades)]
        b.apply(Move(from: .foundation(1), to: .tableau(1)))
        check(b.score == 0, "foundation to tableau costs 15")
        var d1 = empty(.one)
        d1.score = 250
        d1.waste = [c(5, .clubs)]
        d1.dealFromStock()
        check(d1.score == 150, "recycling in draw one costs 100")
        var d3 = empty(.three)
        d3.score = 100
        for _ in 0..<4 {
            d3.waste = [c(5, .clubs)]
            d3.stock = []
            d3.dealFromStock()
        }
        check(d3.score == 80, "draw three is free for three passes, then costs 20")
        check(Scoring.timePenalty(seconds: 59) == 10, "two points every ten seconds")
        check(Scoring.timeBonus(seconds: 20) == 0 && Scoring.timeBonus(seconds: 140) == 5000, "time bonus is 700000 over seconds past 30")
        check(Scoring.total(base: 5, seconds: 100, won: false) == 0, "the score never goes below zero")
    }

    private static func helpers() {
        var b = empty()
        b.foundations[0] = [c(1, .hearts)]
        b.tableau[0] = [c(2, .hearts)]
        b.tableau[1] = [c(1, .spades)]
        check(b.foundationTarget(for: c(1, .spades)) == 1, "an ace goes to the first empty foundation")
        check(b.foundationTarget(for: c(2, .hearts)) == 0, "a two finds its ace")
        check(b.hint() == .move(Move(from: .tableau(0), to: .foundation(0))), "the hint sends a card up first")
        check(b.smartMove(from: .tableau(1), index: 0) == Move(from: .tableau(1), to: .foundation(1)), "double-click sends an ace up")
        var run = empty()
        run.tableau[0] = [c(3, .clubs), c(8, .hearts)]
        run.faceUpFrom[0] = 1
        run.tableau[3] = [c(9, .spades)]
        check(run.smartMove(from: .tableau(0), index: 1) == Move(from: .tableau(0), to: .tableau(3)), "double-click moves a card to a column")
        check(run.hint() == .move(Move(from: .tableau(0), to: .tableau(3))), "the hint uncovers a face down card")
        var stuck = empty()
        stuck.tableau[0] = [c(5, .clubs)]
        check(stuck.hint() == nil, "no hint when nothing can move")
        stuck.stock = [c(4, .hearts)]
        check(stuck.hint() == .deal, "the hint deals when only the stock is left")
    }

    private static func play() {
        // Auto-complete a position with every card face up.
        var b = empty()
        for suit in Suit.allCases { b.tableau[suit.rawValue] = (1...13).reversed().map { c($0, suit) } }
        check(b.canAutoComplete, "auto-complete is offered when every card is face up")
        var steps = 0
        while let move = b.autoStep(), steps < 100 {
            b.apply(move)
            steps += 1
        }
        check(b.isWon && steps == 52 && !b.canAutoComplete, "auto-complete wins in 52 moves")
        check(b.foundations.allSatisfy { Set($0.map(\.suit)).count == 1 }, "each foundation holds one suit")
        check(!Board.deal(game: 5, draw: .one).canAutoComplete, "not offered on a fresh deal")

        // Play many games by following hints; every position must stay a valid table.
        var valid = true
        for game in 1...40 {
            var board = Board.deal(game: game, draw: game % 2 == 0 ? .one : .three)
            for _ in 0..<400 {
                guard let hint = board.hint() else { break }
                switch hint {
                case .deal: board.dealFromStock()
                case .move(let move): if !board.apply(move) { valid = false }
                }
                let cards = board.allCards
                if cards.count != 52 || Set(cards).count != 52 { valid = false }
                for col in 0..<7 where !board.tableau[col].isEmpty && board.faceUpFrom[col] >= board.tableau[col].count { valid = false }
                if board.foundations.contains(where: { pile in pile.enumerated().contains { $0.element.rank != $0.offset + 1 } }) { valid = false }
            }
        }
        check(valid, "hint-driven play keeps every position legal")

        let saved = SavedGame(board: Board.deal(game: 77, draw: .three), number: 77, seconds: 12, started: true, won: false)
        let round = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(SavedGame.self, from: $0) }
        check(round == saved, "a saved game survives a JSON round trip")
    }

    /// Checks added in review, for bugs the first build had.
    private static func review() {
        // A corrupt or hand-edited game.json must never be loaded: it would crash on a missing pile.
        let fresh = Board.deal(game: 12, draw: .one)
        check(fresh.isValid, "a fresh deal is a valid table")
        var short = fresh
        short.foundations.removeLast()
        check(!short.isValid, "a table with three foundations is rejected")
        var twice = fresh
        twice.stock[0] = twice.stock[1]
        check(!twice.isValid, "a table with a card twice is rejected")
        var mark = fresh
        mark.faceUpFrom[2] = 9
        check(!mark.isValid, "a face up mark past the column is rejected")
        var mixed = empty()
        mixed.foundations[0] = [c(1, .hearts), c(2, .spades)]
        check(!mixed.isValid, "a foundation of mixed suits is rejected")
        let junk = try? JSONDecoder().decode(SavedGame.self, from: Data("{\"board\":{}}".utf8))
        check(junk == nil, "a broken saved game does not decode")

        // The hint used to say Deal forever when no stock card could ever be played.
        var dead = empty()
        dead.tableau[0] = [c(5, .clubs)]
        dead.stock = [c(9, .hearts), c(10, .clubs)]
        dead.waste = [c(8, .clubs)]
        check(!dead.stockHasPlay() && dead.hint() == nil, "no hint when the stock holds nothing playable")
        dead.stock.insert(c(4, .hearts), at: 0)
        check(dead.stockHasPlay() && dead.hint() == .deal, "the hint deals when a stock card will play")
        var three = empty(.three)
        three.tableau[0] = [c(5, .clubs)]
        three.stock = [c(10, .clubs), c(9, .hearts), c(4, .hearts), c(8, .clubs)] // The four is always under the nine.
        check(three.hint() == nil, "draw three only counts the cards that come to the top")
        let probeStart = dead
        _ = dead.stockHasPlay()
        check(dead == probeStart, "looking at the stock changes nothing")

        // New Game during auto-complete used to keep moving cards on the fresh table.
        MainActor.assumeIsolated {
            var ready = empty()
            for suit in Suit.allCases { ready.tableau[suit.rawValue] = (1...13).reversed().map { c($0, suit) } }
            let model = GameModel(persists: false)
            model.setUp(ready)
            model.autoComplete()
            check(model.autoCompleting, "auto-complete starts")
            model.deal(31, countLoss: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            check(!model.autoCompleting && model.board == Board.deal(game: 31, draw: model.drawMode),
                  "a new deal stops auto-complete and leaves the fresh table alone")

            let done = GameModel(persists: false)
            done.setUp(ready)
            done.autoComplete()
            let deadline = Date().addingTimeInterval(10)
            while done.autoCompleting, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(done.won && done.board.isWon && done.board.moves == 52, "auto-complete plays out to a win")
        }
    }

    private static func statistics() {
        var s = Stats()
        s.recordStart()
        s.recordWin(seconds: 200, score: 4000)
        s.recordStart()
        s.recordWin(seconds: 150, score: 3000)
        check(s.played == 2 && s.won == 2 && s.streak == 2 && s.bestStreak == 2, "wins build a streak")
        check(s.bestTime == 150 && s.bestScore == 4000, "best time and score are kept")
        s.recordStart()
        s.recordLoss()
        check(s.streak == 0 && s.bestStreak == 2 && abs(s.winRate - 2.0 / 3) < 0.0001, "a loss ends the streak")
        check(105.clock == "1:45" && 3725.clock == "1:02:05", "clock formatting")
    }
}
