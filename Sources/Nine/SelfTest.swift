import Foundation

/// `Nine --selftest`: the solver, the grader, the generator at every difficulty, and the rules of play.
enum SelfTest {
    static let classic = "53..7....6..195....98....6.8...6...34..8.3..17...2...6.6....28....419..5....8..79"
    static let classicAnswer = "534678912672195348198342567859761423426853791713924856961537284287419635345286179"
    /// Arto Inkala's "world's hardest", which logic alone cannot crack.
    static let inkala = "8..........36......7..9.2...5...7.......457.....1...3...1....68..85...1..9....4.."

    static func run() -> Int32 {
        var failures = 0
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            checks += 1
            if !ok { failures += 1; print("FAIL: \(name)") }
        }

        // Geometry.
        check(Sudoku.units.count == 27 && Sudoku.units.allSatisfy { Set($0).count == 9 }, "27 units of nine distinct cells")
        check(Sudoku.peers.allSatisfy { $0.count == 20 }, "every cell has 20 peers")
        check(Sudoku.box(80) == 8 && Sudoku.box(30) == 4 && Sudoku.box(8) == 2, "box index")

        // Solver.
        let classic = Sudoku.parse(Self.classic)
        let answer = Sudoku.parse(Self.classicAnswer)
        check(classic.count == 81 && answer.count == 81, "parse 81 cells")
        check(Solver.solve(classic) == answer, "solver finds the known answer")
        check(Solver.countSolutions(classic) == 1, "known puzzle has one solution")
        check(Solver.countSolutions([Int](repeating: 0, count: 81)) == 2, "empty grid has many solutions")
        var broken = classic
        broken[2] = 5
        check(Solver.solve(broken) == nil && Solver.countSolutions(broken) == 0, "a repeated digit has no solution")
        let inkala = Sudoku.parse(Self.inkala)
        if let s = Solver.solve(inkala) {
            check(Sudoku.isValidSolution(s) && (0..<81).allSatisfy { inkala[$0] == 0 || inkala[$0] == s[$0] }, "solver cracks the hardest puzzle")
        } else {
            check(false, "solver cracks the hardest puzzle")
        }
        // No 16 clue Sudoku has a unique solution (McGuire 2012), so keeping 16 clues must leave several.
        var sixteen = classic
        var kept = 0
        for i in 0..<81 where sixteen[i] != 0 { kept += 1; if kept > 16 { sixteen[i] = 0 } }
        check(Solver.countSolutions(sixteen) == 2, "16 clues leave more than one solution")

        var rng = SplitMix64(seed: 9)
        let full = Solver.randomSolution(using: &rng)
        check(Sudoku.isValidSolution(full), "random solution is valid")
        check(Solver.randomSolution(using: &rng) != full, "random solutions differ")

        // Grader.
        check(Grader.grade(classic) == 1, "the classic puzzle needs only singles")
        check(Grader.grade(inkala) == 4, "the hardest puzzle is beyond the grader's logic")
        check(Grader.combinations([1, 2, 3, 4], 2).count == 6, "combinations")

        // Generator at every difficulty.
        for level in Difficulty.allCases {
            for _ in 0..<3 {
                let started = Date()
                let p = Generator.generate(level, using: &rng)
                let time = Date().timeIntervalSince(started)
                check(Solver.countSolutions(p.givens) == 1, "\(level.title): unique solution")
                check(Solver.solve(p.givens) == p.solution && Sudoku.isValidSolution(p.solution), "\(level.title): solution matches")
                check(level.accepts(level: p.level, clues: p.clues), "\(level.title): graded \(p.level) with \(p.clues) clues")
                check(time < level.budget + 1.5, "\(level.title): generated in \(String(format: "%.2f", time)) s")
                print("  \(level.title): \(p.clues) clues, tier \(p.level), \(String(format: "%.2f", time)) s")
            }
        }

        // Play.
        let puzzle = Puzzle(givens: classic, solution: answer, level: 1)
        var game = Game(puzzle: puzzle, difficulty: .easy)
        check(!game.enter(9, at: 0), "givens cannot be changed")
        check(game.toggleNote(4, at: 2) && game.toggleNote(1, at: 2) && game.notes[2] == (1 << 4 | 1 << 1), "notes toggle on")
        game.toggleNote(4, at: 21)
        game.enter(4, at: 3)
        check(game.notes[2] == 1 << 1 && game.notes[21] == 0, "placing a digit removes it from peer notes")
        game.undo()
        check(game.values[3] == 0 && game.notes[2] & (1 << 4) != 0, "undo restores the digit and the notes")
        game.redo()
        check(game.values[3] == 4 && game.notes[2] & (1 << 4) == 0, "redo reapplies")
        game.enter(4, at: 3)
        check(game.values[3] == 0, "entering the same digit clears it")
        game.enter(5, at: 2)
        check(game.conflicts == [0, 2], "a repeated 5 in the row is a conflict")
        check(game.hint(preferring: 2) == 2 && game.values[2] == 4 && game.hints == 1, "hint fixes the selected wrong cell")
        check(game.conflicts.isEmpty, "no conflicts after the fix")
        game.erase(at: 2)
        check(game.values[2] == 0, "erase clears a digit")
        game.restart()
        check(game.values == classic && game.notes.allSatisfy { $0 == 0 }, "restart returns to the givens")
        for i in 0..<81 where game.values[i] == 0 { game.enter(answer[i], at: i) }
        check(game.completed, "filling the answer completes the game")
        check(!game.enter(1, at: 2) && game.hint(preferring: nil) == nil, "a finished game takes no more input")

        // Persistence.
        game.elapsed = 312
        if let data = try? JSONEncoder().encode(game), let back = try? JSONDecoder().decode(Game.self, from: data) {
            check(back.values == game.values && back.elapsed == 312 && back.completed && back.difficulty == .easy, "save and load round trip")
            check(!back.canUndo, "history is not saved")
        } else {
            check(false, "save and load round trip")
        }
        var records = Records()
        check(records.add(.hard, time: 600) && !records.add(.hard, time: 700) && records.add(.hard, time: 500), "best times keep the fastest")
        check(records.solved["hard"] == 3 && records.best["hard"] == 500, "records count solves")
        check(Clock.format(267) == "4:27" && Clock.format(3729) == "1:02:09", "clock format")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
