import Foundation

// The Sudoku engine: board geometry, a bitmask backtracking solver, a human-style grader and the generator.
// A grid is 81 Ints in row-major order, 0 for an empty cell. Candidate masks use bits 1...9.

enum Sudoku {
    static let allDigits: UInt16 = 0x3FE

    static func row(_ i: Int) -> Int { i / 9 }
    static func col(_ i: Int) -> Int { i % 9 }
    static func box(_ i: Int) -> Int { (i / 27) * 3 + (i % 9) / 3 }

    /// The 27 units: nine rows, nine columns, nine boxes.
    static let units: [[Int]] = {
        let rows = (0..<9).map { r in (0..<9).map { r * 9 + $0 } }
        let cols = (0..<9).map { c in (0..<9).map { $0 * 9 + c } }
        let boxes = (0..<9).map { b in (0..<9).map { k in ((b / 3) * 3 + k / 3) * 9 + (b % 3) * 3 + k % 3 } }
        return rows + cols + boxes
    }()

    /// The 20 cells that share a row, column or box with each cell.
    static let peers: [[Int]] = (0..<81).map { i in
        (0..<81).filter { j in j != i && (row(j) == row(i) || col(j) == col(i) || box(j) == box(i)) }
    }

    static func isPeer(_ a: Int, _ b: Int) -> Bool {
        a != b && (row(a) == row(b) || col(a) == col(b) || box(a) == box(b))
    }

    /// Filled cells whose digit repeats somewhere in their row, column or box.
    static func conflicts(_ grid: [Int]) -> Set<Int> {
        var out = Set<Int>()
        for i in 0..<81 where grid[i] != 0 {
            if peers[i].contains(where: { grid[$0] == grid[i] }) { out.insert(i) }
        }
        return out
    }

    /// True for a complete grid that obeys every rule.
    static func isValidSolution(_ grid: [Int]) -> Bool {
        guard grid.count == 81, grid.allSatisfy({ (1...9).contains($0) }) else { return false }
        return units.allSatisfy { unit in Set(unit.map { grid[$0] }).count == 9 }
    }

    /// Digits still possible in an empty cell, given the filled cells.
    static func candidates(_ grid: [Int], _ i: Int) -> UInt16 {
        guard grid[i] == 0 else { return 0 }
        var used: UInt16 = 0
        for p in peers[i] where grid[p] != 0 { used |= 1 << grid[p] }
        return allDigits & ~used
    }

    /// Parses 81 characters, digits for clues and `.` or `0` for empty cells.
    static func parse(_ text: String) -> [Int] {
        text.compactMap { ch -> Int? in
            if let d = ch.wholeNumberValue { return d }
            return ch == "." ? 0 : nil
        }
    }

    static func digits(of mask: UInt16) -> [Int] { (1...9).filter { mask & (1 << $0) != 0 } }
}

// MARK: - Solver

enum Solver {
    private struct State {
        var grid: [Int]
        var rows = [UInt16](repeating: 0, count: 9)
        var cols = [UInt16](repeating: 0, count: 9)
        var boxes = [UInt16](repeating: 0, count: 9)

        /// Nil when the givens already break a rule.
        init?(_ grid: [Int]) {
            guard grid.count == 81 else { return nil }
            self.grid = grid
            for i in 0..<81 where grid[i] != 0 {
                let d = grid[i]
                guard (1...9).contains(d) else { return nil }
                let bit: UInt16 = 1 << d
                let r = Sudoku.row(i), c = Sudoku.col(i), b = Sudoku.box(i)
                if (rows[r] | cols[c] | boxes[b]) & bit != 0 { return nil }
                rows[r] |= bit; cols[c] |= bit; boxes[b] |= bit
            }
        }

        func free(_ i: Int) -> UInt16 {
            Sudoku.allDigits & ~(rows[Sudoku.row(i)] | cols[Sudoku.col(i)] | boxes[Sudoku.box(i)])
        }

        mutating func set(_ i: Int, _ d: Int, on: Bool) {
            let bit: UInt16 = 1 << d
            grid[i] = on ? d : 0
            if on {
                rows[Sudoku.row(i)] |= bit; cols[Sudoku.col(i)] |= bit; boxes[Sudoku.box(i)] |= bit
            } else {
                rows[Sudoku.row(i)] &= ~bit; cols[Sudoku.col(i)] &= ~bit; boxes[Sudoku.box(i)] &= ~bit
            }
        }
    }

    /// The first solution found, or nil when there is none.
    static func solve(_ grid: [Int]) -> [Int]? {
        guard var state = State(grid) else { return nil }
        var count = 0
        var first: [Int]?
        _ = search(&state, orders: nil, limit: 1, count: &count, first: &first)
        return first
    }

    /// Counts solutions, stopping at `limit`. A proper puzzle returns 1 with the default limit of 2.
    static func countSolutions(_ grid: [Int], limit: Int = 2) -> Int {
        guard var state = State(grid) else { return 0 }
        var count = 0
        var first: [Int]?
        _ = search(&state, orders: nil, limit: limit, count: &count, first: &first)
        return count
    }

    /// A random complete grid: the empty grid solved with a shuffled digit order per cell.
    static func randomSolution(using rng: inout some RandomNumberGenerator) -> [Int] {
        let orders = (0..<81).map { _ in Array(1...9).shuffled(using: &rng) }
        var state = State([Int](repeating: 0, count: 81))!
        var count = 0
        var first: [Int]?
        _ = search(&state, orders: orders, limit: 1, count: &count, first: &first)
        return first!
    }

    /// Depth first, always branching on the empty cell with the fewest candidates. Returns true to stop.
    private static func search(_ s: inout State, orders: [[Int]]?, limit: Int, count: inout Int, first: inout [Int]?) -> Bool {
        var best = -1, bestMask: UInt16 = 0, bestCount = 10
        for i in 0..<81 where s.grid[i] == 0 {
            let mask = s.free(i)
            let n = mask.nonzeroBitCount
            if n == 0 { return false }
            if n < bestCount {
                best = i; bestMask = mask; bestCount = n
                if n == 1 { break }
            }
        }
        if best < 0 {
            count += 1
            if first == nil { first = s.grid }
            return count >= limit
        }
        for d in orders?[best] ?? Array(1...9) where bestMask & (1 << d) != 0 {
            s.set(best, d, on: true)
            if search(&s, orders: orders, limit: limit, count: &count, first: &first) { return true }
            s.set(best, d, on: false)
        }
        return false
    }
}

// MARK: - Grader

/// Solves like a person, one technique tier at a time, and reports the hardest tier a puzzle needed:
/// 1 singles, 2 locked candidates and pairs, 3 triples, X-Wing, Swordfish and XY-Wing, 4 beyond these (chains or trial).
enum Grader {
    static func grade(_ puzzle: [Int]) -> Int { logicalSolve(puzzle).level }

    /// The grid as far as the techniques reach, and the hardest tier used (4 when they get stuck).
    static func logicalSolve(_ puzzle: [Int]) -> (level: Int, grid: [Int]) {
        guard puzzle.count == 81 else { return (4, puzzle) }
        var grid = puzzle
        var cands = (0..<81).map { Sudoku.candidates(puzzle, $0) }
        var level = 1
        while grid.contains(0) {
            if singles(&grid, &cands) { continue }
            if lockedCandidates(&cands) || subsets(&cands, size: 2) { level = max(level, 2); continue }
            if subsets(&cands, size: 3) || fish(&cands, size: 2) || fish(&cands, size: 3) || xyWing(&cands) { level = max(level, 3); continue }
            return (4, grid)
        }
        return (level, grid)
    }

    private static func place(_ i: Int, _ d: Int, _ grid: inout [Int], _ cands: inout [UInt16]) {
        grid[i] = d
        cands[i] = 0
        for p in Sudoku.peers[i] { cands[p] &= ~(1 << d) }
    }

    /// Naked singles, then hidden singles. Places one digit per call.
    private static func singles(_ grid: inout [Int], _ cands: inout [UInt16]) -> Bool {
        for i in 0..<81 where grid[i] == 0 && cands[i].nonzeroBitCount == 1 {
            place(i, cands[i].trailingZeroBitCount, &grid, &cands)
            return true
        }
        for unit in Sudoku.units {
            for d in 1...9 {
                let spots = unit.filter { cands[$0] & (1 << d) != 0 }
                if spots.count == 1 {
                    place(spots[0], d, &grid, &cands)
                    return true
                }
            }
        }
        return false
    }

    /// Pointing (a box confines a digit to one line) and claiming (a line confines it to one box).
    private static func lockedCandidates(_ cands: inout [UInt16]) -> Bool {
        var changed = false
        let boxes = Array(Sudoku.units[18..<27]), lines = Array(Sudoku.units[0..<18])
        for d in 1...9 {
            let bit: UInt16 = 1 << d
            for box in boxes {
                let spots = box.filter { cands[$0] & bit != 0 }
                guard spots.count > 1 else { continue }
                for line in lines where spots.allSatisfy({ line.contains($0) }) {
                    for j in line where !box.contains(j) && cands[j] & bit != 0 { cands[j] &= ~bit; changed = true }
                }
            }
            for line in lines {
                let spots = line.filter { cands[$0] & bit != 0 }
                guard spots.count > 1 else { continue }
                for box in boxes where spots.allSatisfy({ box.contains($0) }) {
                    for j in box where !line.contains(j) && cands[j] & bit != 0 { cands[j] &= ~bit; changed = true }
                }
            }
        }
        return changed
    }

    /// Naked and hidden subsets of `size` cells in a unit.
    private static func subsets(_ cands: inout [UInt16], size: Int) -> Bool {
        var changed = false
        for unit in Sudoku.units {
            let open = unit.filter { cands[$0] != 0 }
            guard open.count > size else { continue }
            // Naked: `size` cells whose candidates together span exactly `size` digits.
            for combo in combinations(open, size) {
                let union = combo.reduce(UInt16(0)) { $0 | cands[$1] }
                guard union.nonzeroBitCount == size else { continue }
                for j in open where !combo.contains(j) && cands[j] & union != 0 { cands[j] &= ~union; changed = true }
            }
            // Hidden: `size` digits that only fit in the same `size` cells.
            let digits = (1...9).filter { d in open.contains { cands[$0] & (1 << d) != 0 } }
            for combo in combinations(digits, size) {
                let mask = combo.reduce(UInt16(0)) { $0 | (1 << $1) }
                let spots = open.filter { cands[$0] & mask != 0 }
                guard spots.count == size, combo.allSatisfy({ d in spots.contains { cands[$0] & (1 << d) != 0 } }) else { continue }
                for j in spots where cands[j] & ~mask != 0 { cands[j] &= mask; changed = true }
            }
        }
        return changed
    }

    /// X-Wing (size 2) and Swordfish (size 3), on rows and on columns: when a digit sits in only `size`
    /// positions across `size` lines, it can be removed from those positions in every other line.
    private static func fish(_ cands: inout [UInt16], size: Int) -> Bool {
        var changed = false
        for d in 1...9 {
            let bit: UInt16 = 1 << d
            for byRow in [true, false] {
                func cell(_ line: Int, _ k: Int) -> Int { byRow ? line * 9 + k : k * 9 + line }
                let spots = (0..<9).map { line in (0..<9).filter { cands[cell(line, $0)] & bit != 0 } }
                let lines = (0..<9).filter { (2...size).contains(spots[$0].count) }
                for combo in combinations(lines, size) {
                    let cover = Set(combo.flatMap { spots[$0] })
                    guard cover.count == size else { continue }
                    for line in 0..<9 where !combo.contains(line) {
                        for k in cover where cands[cell(line, k)] & bit != 0 { cands[cell(line, k)] &= ~bit; changed = true }
                    }
                }
            }
        }
        return changed
    }

    /// XY-Wing: a two-candidate pivot {a, b} sees pincers {a, c} and {b, c}; a cell that sees both pincers cannot be c.
    private static func xyWing(_ cands: inout [UInt16]) -> Bool {
        for pivot in 0..<81 where cands[pivot].nonzeroBitCount == 2 {
            let pincers = Sudoku.peers[pivot].filter { p in
                cands[p].nonzeroBitCount == 2 && cands[p] != cands[pivot] && (cands[p] & cands[pivot]).nonzeroBitCount == 1
            }
            for (n, p) in pincers.enumerated() {
                for q in pincers[(n + 1)...] {
                    let c = cands[p] & cands[q] & ~cands[pivot]
                    guard c.nonzeroBitCount == 1, (cands[p] | cands[q] | cands[pivot]).nonzeroBitCount == 3 else { continue }
                    var changed = false
                    for j in Sudoku.peers[p] where j != q && Sudoku.isPeer(j, q) && cands[j] & c != 0 { cands[j] &= ~c; changed = true }
                    if changed { return true }
                }
            }
        }
        return false
    }

    static func combinations<T>(_ items: [T], _ k: Int) -> [[T]] {
        guard k > 0 else { return [[]] }
        guard items.count >= k else { return [] }
        var out: [[T]] = []
        for (n, item) in items.enumerated() {
            for rest in combinations(Array(items[(n + 1)...]), k - 1) { out.append([item] + rest) }
        }
        return out
    }
}

// MARK: - Generator

enum Difficulty: String, Codable, CaseIterable, Identifiable {
    case easy, medium, hard, expert

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Digging stops once the clue count reaches this.
    var targetClues: Int {
        switch self {
        case .easy: 38
        case .medium: 30
        case .hard: 24
        case .expert: 17
        }
    }

    /// Easy and medium need only singles (medium with far fewer clues); hard needs pairs or locked candidates; expert needs more.
    func accepts(level: Int, clues: Int) -> Bool {
        switch self {
        case .easy: level == 1 && clues >= 36
        case .medium: level == 1 && clues <= 32
        case .hard: level == 2 && clues <= 28
        case .expert: level == 3 && clues <= 26
        }
    }

    /// How well an unaccepted puzzle fits, for the fallback when the time budget runs out. Higher is better.
    func fit(level: Int, clues: Int) -> Int {
        switch self {
        case .easy: (level == 1 ? 100 : 0) + clues
        case .medium: (level == 1 ? 100 : 0) - clues
        case .hard: (level == 2 ? 200 : level == 3 ? 100 : 0) - clues
        case .expert: (level == 3 ? 300 : level == 4 ? 200 : level * 50) - clues
        }
    }

    var budget: TimeInterval { self == .expert ? 4 : 2.5 }
}

struct Puzzle: Equatable {
    var givens: [Int]
    var solution: [Int]
    var level: Int
    var clues: Int { givens.filter { $0 != 0 }.count }
}

enum Generator {
    /// A puzzle with exactly one solution, graded to `difficulty`. Retries fresh grids until one fits or the budget runs out.
    static func generate(_ difficulty: Difficulty, using rng: inout some RandomNumberGenerator) -> Puzzle {
        let deadline = Date().addingTimeInterval(difficulty.budget)
        var best: Puzzle?
        var bestFit = Int.min
        repeat {
            let solution = Solver.randomSolution(using: &rng)
            for _ in 0..<3 {
                let givens = dig(solution, target: difficulty.targetClues, using: &rng)
                let puzzle = Puzzle(givens: givens, solution: solution, level: Grader.grade(givens))
                if difficulty.accepts(level: puzzle.level, clues: puzzle.clues) { return puzzle }
                let fit = difficulty.fit(level: puzzle.level, clues: puzzle.clues)
                if fit > bestFit { best = puzzle; bestFit = fit }
            }
        } while Date() < deadline
        return best!
    }

    /// Removes clues in symmetric pairs, in random order, keeping only removals that leave the solution unique.
    static func dig(_ solution: [Int], target: Int, using rng: inout some RandomNumberGenerator) -> [Int] {
        var grid = solution
        var clues = 81
        for i in Array(0...40).shuffled(using: &rng) {
            if clues <= target { break }
            let j = 80 - i
            let saved = (grid[i], grid[j])
            grid[i] = 0; grid[j] = 0
            if Solver.countSolutions(grid) == 1 {
                clues -= i == j ? 1 : 2
            } else {
                grid[i] = saved.0; grid[j] = saved.1
            }
        }
        return grid
    }
}

/// A small seeded generator, so the self-test is repeatable.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
