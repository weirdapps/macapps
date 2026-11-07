import Foundation

// MARK: - Rules

enum Disc: Int, Codable, Sendable {
    case black, white

    var opponent: Disc { self == .black ? .white : .black }
    var name: String { self == .black ? "Black" : "White" }
}

/// An 8x8 position as two bitboards. Square `i` is row `i / 8` (0 is the top, "1"), column `i % 8` (0 is "a").
struct Position: Equatable, Codable, Sendable {
    var black: UInt64
    var white: UInt64
    var toMove: Disc

    static let start = Position(black: bit(3, 4) | bit(4, 3), white: bit(3, 3) | bit(4, 4), toMove: .black)

    static func bit(_ row: Int, _ col: Int) -> UInt64 { 1 << UInt64(row * 8 + col) }

    var mine: UInt64 { toMove == .black ? black : white }
    var theirs: UInt64 { toMove == .black ? white : black }
    var empty: UInt64 { ~(black | white) }

    func disc(at square: Int) -> Disc? {
        let b: UInt64 = 1 << UInt64(square)
        if black & b != 0 { return .black }
        if white & b != 0 { return .white }
        return nil
    }

    func count(_ disc: Disc) -> Int { (disc == .black ? black : white).nonzeroBitCount }

    /// Bitboard of the squares the side to move may play.
    var legalMoves: UInt64 { Bits.moves(mine, theirs) }

    var canMove: Bool { legalMoves != 0 }
    var opponentCanMove: Bool { Bits.moves(theirs, mine) != 0 }
    var isOver: Bool { !canMove && !opponentCanMove }

    /// Discs flipped if the side to move plays `square` (0 when the move is illegal).
    func flips(_ square: Int) -> UInt64 { Bits.flips(1 << UInt64(square), mine, theirs) }

    /// The position after the side to move plays `square`. The caller checks legality.
    func playing(_ square: Int) -> Position {
        let m: UInt64 = 1 << UInt64(square)
        let f = Bits.flips(m, mine, theirs)
        let newMine = mine | m | f, newTheirs = theirs & ~f
        return toMove == .black
            ? Position(black: newMine, white: newTheirs, toMove: .white)
            : Position(black: newTheirs, white: newMine, toMove: .black)
    }

    /// The same discs with the other side to move.
    var passing: Position { Position(black: black, white: white, toMove: toMove.opponent) }

    /// Builds a position from eight strings of `X` (black), `O` (white) and `.` (empty), top row first.
    init(rows: [String], toMove: Disc) {
        var b: UInt64 = 0, w: UInt64 = 0
        for (r, line) in rows.enumerated() {
            for (c, ch) in line.enumerated() where r < 8 && c < 8 {
                if ch == "X" { b |= Position.bit(r, c) }
                if ch == "O" { w |= Position.bit(r, c) }
            }
        }
        self.init(black: b, white: w, toMove: toMove)
    }

    init(black: UInt64, white: UInt64, toMove: Disc) {
        self.black = black
        self.white = white
        self.toMove = toMove
    }

    static func name(of square: Int) -> String {
        let letters = Array("abcdefgh")
        return "\(letters[square % 8])\(square / 8 + 1)"
    }
}

enum Bits {
    static let notA: UInt64 = 0xFEFE_FEFE_FEFE_FEFE
    static let notH: UInt64 = 0x7F7F_7F7F_7F7F_7F7F

    /// Eight directions as (shift amount, left shift?, mask applied after the shift).
    static let directions: [(Int, Bool, UInt64)] = [
        (1, true, notA), (1, false, notH), (8, true, ~0), (8, false, ~0),
        (9, true, notA), (7, true, notH), (7, false, notA), (9, false, notH),
    ]

    @inline(__always) static func shift(_ b: UInt64, _ d: (Int, Bool, UInt64)) -> UInt64 {
        (d.1 ? b << UInt64(d.0) : b >> UInt64(d.0)) & d.2
    }

    static func moves(_ p: UInt64, _ o: UInt64) -> UInt64 {
        let empty = ~(p | o)
        var result: UInt64 = 0
        for d in directions {
            var x = shift(p, d) & o
            for _ in 0..<5 { x |= shift(x, d) & o }
            result |= shift(x, d) & empty
        }
        return result
    }

    static func flips(_ m: UInt64, _ p: UInt64, _ o: UInt64) -> UInt64 {
        guard m & (p | o) == 0 else { return 0 }
        var result: UInt64 = 0
        for d in directions {
            var line: UInt64 = 0
            var x = shift(m, d)
            while x & o != 0 { line |= x; x = shift(x, d) }
            if x & p != 0 { result |= line }
        }
        return result
    }

    /// Square indices of the set bits, lowest first.
    static func squares(_ b: UInt64) -> [Int] {
        var b = b, out: [Int] = []
        while b != 0 {
            out.append(b.trailingZeroBitCount)
            b &= b - 1
        }
        return out
    }
}

// MARK: - Computer player

enum Level: String, CaseIterable, Codable, Identifiable, Sendable {
    case easy, medium, hard
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Engine {
    /// The classic square weights: corners are gold, the squares next to them give corners away.
    static let weights: [Int] = [
        100, -20, 10, 5, 5, 10, -20, 100,
        -20, -50, -2, -2, -2, -2, -50, -20,
        10, -2, 1, 1, 1, 1, -2, 10,
        5, -2, 1, 0, 0, 1, -2, 5,
        5, -2, 1, 0, 0, 1, -2, 5,
        10, -2, 1, 1, 1, 1, -2, 10,
        -20, -50, -2, -2, -2, -2, -50, -20,
        100, -20, 10, 5, 5, 10, -20, 100,
    ]

    static let corners: UInt64 = 0x8100_0000_0000_0081

    static func positional(_ b: UInt64) -> Int {
        Bits.squares(b).reduce(0) { $0 + weights[$1] }
    }

    /// A move for the side to move, or nil when it must pass.
    static func choose(_ pos: Position, level: Level, random: inout some RandomNumberGenerator) -> Int? {
        let moves = Bits.squares(pos.legalMoves)
        guard !moves.isEmpty else { return nil }
        switch level {
        case .easy:
            // Mostly random, nudged a little towards squares that flip more and away from the worst ones.
            let scored = moves.map { m in (m, max(1, 4 + pos.flips(m).nonzeroBitCount + weights[m] / 25)) }
            var pick = Int.random(in: 0..<scored.reduce(0) { $0 + $1.1 }, using: &random)
            for (m, w) in scored {
                if pick < w { return m }
                pick -= w
            }
            return scored.last?.0
        case .medium:
            return moves.max { a, b in greedy(pos, a) < greedy(pos, b) }
        case .hard:
            return search(pos).move
        }
    }

    /// One ply: the square weights of the position after the move, for the mover. Ties go to the lower square.
    static func greedy(_ pos: Position, _ m: Int) -> Int {
        let next = pos.playing(m)
        let mine = pos.toMove == .black ? next.black : next.white
        let theirs = pos.toMove == .black ? next.white : next.black
        return (positional(mine) - positional(theirs)) * 100 - m
    }

    static let depth = 7
    static let solveEmpties = 14

    /// Alpha-beta negamax: a fixed depth in the middle game, an exact solve near the end.
    static func search(_ pos: Position) -> (move: Int?, score: Int) {
        let empties = pos.empty.nonzeroBitCount
        let exact = empties <= solveEmpties
        var nodes = 0
        let r = negamax(pos.mine, pos.theirs, depth: exact ? empties + 2 : depth, alpha: -100_000, beta: 100_000,
                        passed: false, exact: exact, nodes: &nodes)
        return (r.move, r.score)
    }

    /// Exact final disc difference for the side to move, with perfect play by both sides.
    static func solve(_ pos: Position) -> Int {
        var nodes = 0
        return negamax(pos.mine, pos.theirs, depth: 64, alpha: -100_000, beta: 100_000, passed: false, exact: true,
                       nodes: &nodes).score
    }

    private static func negamax(_ p: UInt64, _ o: UInt64, depth: Int, alpha: Int, beta: Int, passed: Bool, exact: Bool,
                                nodes: inout Int) -> (move: Int?, score: Int) {
        nodes += 1
        let moves = Bits.moves(p, o)
        if moves == 0 {
            if passed || Bits.moves(o, p) == 0 {
                return (nil, final(p, o) * (exact ? 1 : 1000))
            }
            let r = negamax(o, p, depth: depth, alpha: -beta, beta: -alpha, passed: true, exact: exact, nodes: &nodes)
            return (nil, -r.score)
        }
        if depth == 0 { return (nil, evaluate(p, o)) }
        // Try corners first, then by square weight: better ordering, more cut-offs.
        let ordered = Bits.squares(moves).sorted { weights[$0] > weights[$1] }
        var alpha = alpha
        var best: (move: Int?, score: Int) = (ordered[0], -1_000_000)
        for m in ordered {
            let mb: UInt64 = 1 << UInt64(m)
            let f = Bits.flips(mb, p, o)
            let r = negamax(o & ~f, p | mb | f, depth: depth - 1, alpha: -beta, beta: -alpha, passed: false, exact: exact,
                            nodes: &nodes)
            let score = -r.score
            if score > best.score { best = (m, score) }
            alpha = max(alpha, score)
            if alpha >= beta { break }
        }
        return best
    }

    /// Final disc difference; empty squares go to the winner, as in tournament rules.
    static func final(_ p: UInt64, _ o: UInt64) -> Int {
        let a = p.nonzeroBitCount, b = o.nonzeroBitCount, e = 64 - a - b
        if a > b { return a - b + e }
        if b > a { return a - b - e }
        return 0
    }

    /// Middle-game estimate for the side to move: square weights, mobility and corners.
    static func evaluate(_ p: UInt64, _ o: UInt64) -> Int {
        let mobility = Bits.moves(p, o).nonzeroBitCount - Bits.moves(o, p).nonzeroBitCount
        let corner = (p & corners).nonzeroBitCount - (o & corners).nonzeroBitCount
        return positional(p) - positional(o) + mobility * 8 + corner * 30
    }
}

// MARK: - Game record

/// One entry of the move list: who moved and where, or a pass.
struct Record: Equatable, Codable, Sendable {
    var player: Disc
    var square: Int? // nil is a pass.
    var before: Position

    var label: String { square.map(Position.name) ?? "pass" }
}

/// A game: the current position and every move that led to it. Pure, so it can be tested without the UI.
struct Game: Equatable, Codable, Sendable {
    var position = Position.start
    var records: [Record] = []

    var isOver: Bool { position.isOver }

    /// Plays a legal move for the side to move, then records any forced pass that follows.
    @discardableResult
    mutating func play(_ square: Int) -> Bool {
        guard square >= 0, square < 64, position.legalMoves & (1 << UInt64(square)) != 0 else { return false }
        records.append(Record(player: position.toMove, square: square, before: position))
        position = position.playing(square)
        passIfForced()
        return true
    }

    /// When the side to move has no move but the other side does, it passes.
    mutating func passIfForced() {
        if !position.canMove && position.opponentCanMove {
            records.append(Record(player: position.toMove, square: nil, before: position))
            position = position.passing
        }
    }

    /// Takes back the last real move, along with any pass after it. Returns the square undone.
    @discardableResult
    mutating func undo() -> Int? {
        while let last = records.last, last.square == nil { records.removeLast(); position = last.before }
        guard let last = records.popLast() else { return nil }
        position = last.before
        return last.square
    }

    /// Replays a list of squares (passes are implied); stops at the first illegal one.
    static func replay(_ squares: [Int]) -> Game {
        var g = Game()
        for s in squares where !g.play(s) { break }
        return g
    }

    var squares: [Int] { records.compactMap(\.square) }
    var lastMove: Int? { records.last(where: { $0.square != nil })?.square }
}
