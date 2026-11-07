import Foundation

/// `Reversi --selftest`: move generation, flipping, passes, the end of the game, the solver and the game record.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(what)")
        }
    }

    /// Seeded generator so the random positions are the same on every run.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func sq(_ name: String) -> Int {
        let c = Array(name)
        return Int(c[0].asciiValue! - 97) + (Int(String(c[1]))! - 1) * 8
    }

    static func perft(_ pos: Position, _ depth: Int) -> Int {
        if depth == 0 { return 1 }
        let moves = Bits.squares(pos.legalMoves)
        if moves.isEmpty { return pos.opponentCanMove ? perft(pos.passing, depth - 1) : 1 }
        return moves.reduce(0) { $0 + perft(pos.playing($1), depth - 1) }
    }

    /// Plain minimax to the end of the game, no pruning: the reference the solver must agree with.
    static func bruteForce(_ pos: Position) -> Int {
        let moves = Bits.squares(pos.legalMoves)
        if moves.isEmpty {
            if !pos.opponentCanMove { return Engine.final(pos.mine, pos.theirs) }
            return -bruteForce(pos.passing)
        }
        return moves.map { -bruteForce(pos.playing($0)) }.max()!
    }

    static func randomPosition(empties: Int, rng: inout SplitMix) -> Position {
        var pos = Position.start
        while pos.empty.nonzeroBitCount > empties, !pos.isOver {
            let moves = Bits.squares(pos.legalMoves)
            pos = moves.isEmpty ? pos.passing : pos.playing(moves[Int(rng.next() % UInt64(moves.count))])
        }
        if !pos.canMove && pos.opponentCanMove { pos = pos.passing }
        return pos
    }

    static func transpose(_ b: UInt64) -> UInt64 {
        Bits.squares(b).reduce(0) { $0 | (1 << UInt64(($1 % 8) * 8 + $1 / 8)) }
    }

    static func run() -> Int32 {
        var rng = SplitMix(state: 2026)

        // Opening.
        let start = Position.start
        check(Set(Bits.squares(start.legalMoves)) == Set(["d3", "c4", "f5", "e6"].map(sq)), "four opening moves d3 c4 f5 e6")
        check(start.disc(at: sq("d4")) == .white && start.disc(at: sq("e4")) == .black, "starting discs on d4 and e4")
        check(start.flips(sq("d3")) == 1 << UInt64(sq("d4")), "d3 flips exactly d4")
        let afterD3 = start.playing(sq("d3"))
        check(afterD3.count(.black) == 4 && afterD3.count(.white) == 1 && afterD3.toMove == .white, "counts after d3 are 4 to 1")
        check(start.flips(sq("a1")) == 0 && start.flips(sq("d4")) == 0, "no flips for a far or occupied square")
        var g = Game()
        check(!g.play(sq("a1")) && !g.play(sq("d4")) && g.records.isEmpty, "illegal moves are refused")

        // Move generation against the published perft counts.
        let expected = [1, 4, 12, 56, 244, 1396, 8200]
        for d in 1...6 { check(perft(start, d) == expected[d], "perft \(d) is \(expected[d])") }

        // Flips in every direction at once: a white ring around d4 with black discs beyond each one.
        let star = Position(rows: [
            "X..X..X.",
            ".O.O.O..",
            "..OOO...",
            "XOO.OOOX",
            "..OOO...",
            ".O.O.O..",
            "X..X..X.",
            "........",
        ], toMove: .black)
        check(star.flips(sq("d4")).nonzeroBitCount == 17, "a move flips lines in all eight directions")
        check(star.playing(sq("d4")).count(.white) == 0, "after the star move no white disc is left")

        // A known endgame: one empty corner, Black plays a1 and turns the six discs to h1.
        var rows = Array(repeating: "OOOOOOOO", count: 8)
        rows[0] = ".OOOOOOX"
        let last = Position(rows: rows, toMove: .black)
        check(Bits.squares(last.legalMoves) == [0], "the only move is a1")
        check(last.flips(0).nonzeroBitCount == 6, "a1 flips b1 to g1")
        let end = last.playing(0)
        check(end.isOver && end.count(.black) == 8 && end.count(.white) == 56, "the game ends 8 to 56")
        check(Engine.solve(last) == -48, "the solver scores it -48 for Black")
        check(Engine.search(last).move == 0, "hard search finds a1")

        // Passing and the end of the game.
        let stuck = Position(rows: ["OX......"] + Array(repeating: "........", count: 7), toMove: .black)
        check(!stuck.canMove && stuck.opponentCanMove, "Black is stuck while White can move")
        var pg = Game(position: stuck, records: [])
        pg.passIfForced()
        check(pg.position.toMove == .white && pg.records.count == 1 && pg.records[0].square == nil, "a forced pass is recorded")
        check(pg.play(sq("c1")) && pg.isOver && pg.position.count(.white) == 3, "White wipes out Black and the game is over")
        check(Engine.final(pg.position.white, pg.position.black) == 64, "a wipe-out scores the empty squares to the winner")
        check(pg.undo() == sq("c1") && pg.position == stuck.passing && pg.records.count == 1, "undo takes back the move, keeping the forced pass")

        // The exact solver agrees with plain minimax on random endgames.
        var agree = true
        for _ in 0..<12 {
            let p = randomPosition(empties: 7, rng: &rng)
            if !p.isOver, Engine.solve(p) != bruteForce(p) { agree = false }
        }
        check(agree, "alpha-beta solver matches plain minimax on 12 random endgames")

        // Move generation is symmetric under reflection along the diagonal.
        var symmetric = true
        for _ in 0..<40 {
            let p = randomPosition(empties: 20 + Int(rng.next() % 30), rng: &rng)
            let t = Position(black: transpose(p.black), white: transpose(p.white), toMove: p.toMove)
            if transpose(p.legalMoves) != t.legalMoves { symmetric = false }
        }
        check(symmetric, "legal moves mirror along the diagonal")

        // Every level only ever plays legal moves.
        var legal = true
        for _ in 0..<60 {
            let p = randomPosition(empties: 30 + Int(rng.next() % 28), rng: &rng)
            for level in [Level.easy, .medium] {
                if let m = Engine.choose(p, level: level, random: &rng), p.legalMoves & (1 << UInt64(m)) == 0 { legal = false }
            }
        }
        check(legal, "easy and medium only play legal moves")
        let corner = Position(rows: ["........", ".O......", "..X.....", "........", "........", "........", "........", "........"],
                              toMove: .black)
        check(Engine.choose(corner, level: .medium, random: &rng) == 0, "medium takes a free corner")

        let clock = Date()
        let mid = randomPosition(empties: 40, rng: &rng)
        let hard = Engine.search(mid).move
        check(hard.map { mid.legalMoves & (1 << UInt64($0)) != 0 } ?? false, "hard plays a legal middle-game move")
        check(Date().timeIntervalSince(clock) < 5, "hard answers within five seconds")

        // Hard beats easy.
        var wins = 0
        var slowest = 0.0
        for game in 0..<2 {
            var p = Position.start
            let hardSide: Disc = game == 0 ? .black : .white
            while !p.isOver {
                let t = Date()
                let choice = Engine.choose(p, level: p.toMove == hardSide ? .hard : .easy, random: &rng)
                slowest = max(slowest, Date().timeIntervalSince(t))
                guard let m = choice else {
                    p = p.passing
                    continue
                }
                p = p.playing(m)
            }
            if p.count(hardSide) > p.count(hardSide.opponent) { wins += 1 }
        }
        check(wins == 2, "hard beats easy as both colours")
        check(slowest < 3, "no hard move takes more than three seconds (slowest \(String(format: "%.2f", slowest)) s)")

        // The game record.
        var rec = Game()
        for s in ["d3", "c5", "f6", "f5"] { rec.play(sq(s)) }
        check(rec.records.map(\.label) == ["d3", "c5", "f6", "f5"], "the move list reads d3 c5 f6 f5")
        check(Game.replay(rec.squares) == rec, "replaying the squares rebuilds the same game")
        let saved = SavedState(squares: rec.squares, opponent: .hard, humanSide: .white, showHints: false)
        let decoded = (try? JSONEncoder().encode(saved)).flatMap { try? JSONDecoder().decode(SavedState.self, from: $0) }
        check(decoded?.squares == rec.squares && decoded?.opponent == .hard && decoded?.humanSide == .white,
              "the saved game survives a JSON round trip")
        rec.undo()
        check(rec.squares == ["d3", "c5", "f6"].map(sq) && rec.position.toMove == .white, "undo goes back one move")

        // The window's model: two players on one Mac.
        let model = GameModel(persists: false)
        model.opponent = .human
        check(!model.canUndo && model.status == "Black to move", "a new game waits for Black")
        model.tap(sq("a1"))
        check(model.game.records.isEmpty, "a tap on an illegal square does nothing")
        model.tap(sq("d3"))
        check(model.position.count(.black) == 4 && model.status == "White to move", "a tap plays the move")
        model.undo()
        check(model.position == .start && !model.canUndo, "undo in two-player mode goes back to the start")

        // A damaged save never crashes: out-of-range and illegal squares end the replay.
        check(Game.replay([-1, 64, 999]).records.isEmpty, "a save with out-of-range squares restores an empty board")
        check(Game.replay([sq("d3"), sq("a1"), sq("c5")]).squares == [sq("d3")], "replay stops at the first illegal square")
        check((try? JSONDecoder().decode(SavedState.self, from: Data("{}".utf8))) == nil, "an empty save file is refused, not trusted")

        // Pass banners speak to whoever is at the board.
        check(model.passNotice(.white) == "White has no move and passes", "two-player pass banner names the colour")
        let vs = GameModel(persists: false)
        vs.opponent = .medium
        vs.humanSide = .black
        check(vs.passNotice(.black) == "You have no move, so you pass" && vs.passNotice(.white).hasPrefix("Computer has no move"),
              "against the computer the pass banner says you or Computer")
        check(Opponent.allCases.map(\.title) == ["Easy Computer", "Medium Computer", "Hard Computer", "Two Players"],
              "opponent names read as menu items")

        // Against the computer: your move hands over, undo cancels the pending reply.
        vs.tap(sq("d3"))
        check(vs.thinking && !vs.humanCanPlay && vs.status == "Computer is thinking", "after your move the computer thinks")
        vs.tap(sq("c3"))
        check(vs.game.squares == [sq("d3")], "taps are ignored while the computer thinks")
        vs.undo()
        check(vs.position == .start && !vs.thinking && vs.humanCanPlay, "undo cancels the computer's reply and gives you the move")
        vs.humanSide = .white
        check(vs.thinking && vs.hints == 0, "switching to White hands the opening move to the computer")
        vs.opponent = .human
        check(!vs.thinking && vs.humanCanPlay, "switching to two players stops the computer")

        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }
}
