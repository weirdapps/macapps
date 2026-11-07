import Foundation

// MARK: - Cards

enum Suit: Int, CaseIterable, Codable, Sendable {
    case spades, hearts, diamonds, clubs

    var isRed: Bool { self == .hearts || self == .diamonds }
}

struct Card: Hashable, Codable, Identifiable, Sendable {
    let suit: Suit
    let rank: Int // 1 is the ace, 11 to 13 are the jack, queen and king.

    var id: Int { suit.rawValue * 13 + rank - 1 }
    var isRed: Bool { suit.isRed }

    var rankLabel: String {
        switch rank {
        case 1: "A"
        case 11: "J"
        case 12: "Q"
        case 13: "K"
        default: "\(rank)"
        }
    }

    static let deck: [Card] = Suit.allCases.flatMap { suit in (1...13).map { Card(suit: suit, rank: $0) } }
}

/// Where cards live on the table.
enum Spot: Hashable, Codable, Sendable {
    case stock, waste, foundation(Int), tableau(Int)
}

struct Move: Hashable, Sendable {
    var from: Spot
    var to: Spot
    var count = 1
}

enum Hint: Equatable, Sendable {
    case move(Move)
    case deal
}

enum DrawMode: Int, Codable, CaseIterable, Sendable {
    case one = 1, three = 3

    var title: String { self == .one ? "Draw 1" : "Draw 3" }
}

/// A small, fast generator with a fixed algorithm, so a game number always deals the same cards on every Mac.
struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Scoring

/// Standard (Windows) Klondike scoring.
enum Scoring {
    static let wasteToTableau = 5
    static let toFoundation = 10
    static let turnOver = 5
    static let foundationToTableau = -15
    static let recycleDrawOne = -100
    static let recycleDrawThree = -20 // Only after the third pass through the deck.

    /// Two points lost every ten seconds.
    static func timePenalty(seconds: Int) -> Int { 2 * (seconds / 10) }

    /// The bonus for a win that took at least thirty seconds.
    static func timeBonus(seconds: Int) -> Int { seconds >= 30 ? 700_000 / seconds : 0 }

    static func total(base: Int, seconds: Int, won: Bool) -> Int {
        max(0, base - timePenalty(seconds: seconds)) + (won ? timeBonus(seconds: seconds) : 0)
    }
}

// MARK: - Board

/// The whole table, as a value: rules and moves are pure functions over it, so undo is a stack of boards.
struct Board: Codable, Equatable, Sendable {
    var stock: [Card] = [] // `last` is the top card.
    var waste: [Card] = []
    var foundations: [[Card]] = Array(repeating: [], count: 4)
    var tableau: [[Card]] = Array(repeating: [], count: 7)
    var faceUpFrom: [Int] = Array(repeating: 0, count: 7) // Index of the first face up card in each column.
    var draw: DrawMode = .one
    var score = 0 // Before the time penalty.
    var moves = 0
    var recycles = 0

    static func shuffled(seed: UInt64) -> [Card] {
        var rng = SplitMix64(state: seed)
        var cards = Card.deck
        for i in stride(from: cards.count - 1, to: 0, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            cards.swapAt(i, j)
        }
        return cards
    }

    /// Deals game `number`: seven columns of one to seven cards, the last of each face up, the rest in the stock.
    static func deal(game number: Int, draw: DrawMode) -> Board {
        var deck = shuffled(seed: UInt64(number))
        var board = Board()
        board.draw = draw
        for row in 0..<7 {
            for column in row..<7 { board.tableau[column].append(deck.removeLast()) }
        }
        board.faceUpFrom = Array(0..<7)
        board.stock = deck
        return board
    }

    // MARK: Rules

    /// A card goes on a tableau card one rank higher of the other colour; only a king goes on an empty column.
    static func canStack(_ card: Card, on target: Card?) -> Bool {
        guard let target else { return card.rank == 13 }
        return target.isRed != card.isRed && target.rank == card.rank + 1
    }

    /// Foundations build up by suit from the ace.
    static func canFound(_ card: Card, on top: Card?) -> Bool {
        guard let top else { return card.rank == 1 }
        return top.suit == card.suit && card.rank == top.rank + 1
    }

    func isFaceUp(column: Int, index: Int) -> Bool { index >= faceUpFrom[column] }

    func cards(at spot: Spot) -> [Card] {
        switch spot {
        case .stock: stock
        case .waste: waste
        case .foundation(let i): foundations[i]
        case .tableau(let i): tableau[i]
        }
    }

    /// The cards a player may pick up from `spot`: the top of the waste or a foundation, or a face up run in a column.
    func movable(from spot: Spot, count: Int) -> [Card]? {
        guard count >= 1 else { return nil }
        switch spot {
        case .stock:
            return nil
        case .waste:
            return count == 1 ? waste.last.map { [$0] } : nil
        case .foundation(let i):
            return count == 1 ? foundations[i].last.map { [$0] } : nil
        case .tableau(let c):
            let column = tableau[c]
            guard count <= column.count - faceUpFrom[c] else { return nil }
            let run = Array(column.suffix(count))
            for k in 1..<max(run.count, 1) where !Board.canStack(run[k], on: run[k - 1]) { return nil }
            return run
        }
    }

    func isLegal(_ move: Move) -> Bool {
        guard move.from != move.to, let cards = movable(from: move.from, count: move.count), let lead = cards.first else { return false }
        switch move.to {
        case .foundation(let i):
            if case .foundation = move.from { return false }
            return cards.count == 1 && Board.canFound(lead, on: foundations[i].last)
        case .tableau(let c):
            return Board.canStack(lead, on: tableau[c].last)
        case .stock, .waste:
            return false
        }
    }

    /// Applies a legal move, turns over the card it uncovers and scores it. Returns false and changes nothing otherwise.
    @discardableResult
    mutating func apply(_ move: Move) -> Bool {
        guard isLegal(move), let cards = movable(from: move.from, count: move.count) else { return false }
        switch move.from {
        case .waste: waste.removeLast()
        case .foundation(let i): foundations[i].removeLast()
        case .tableau(let c): tableau[c].removeLast(move.count)
        case .stock: return false
        }
        switch move.to {
        case .foundation(let i): foundations[i] += cards
        case .tableau(let c): tableau[c] += cards
        default: break
        }
        switch (move.from, move.to) {
        case (.waste, .tableau): score += Scoring.wasteToTableau
        case (_, .foundation): score += Scoring.toFoundation
        case (.foundation, .tableau): score += Scoring.foundationToTableau
        default: break
        }
        if case .tableau(let c) = move.from, !tableau[c].isEmpty, faceUpFrom[c] >= tableau[c].count {
            faceUpFrom[c] = tableau[c].count - 1
            score += Scoring.turnOver
        }
        if case .tableau(let c) = move.from, tableau[c].isEmpty { faceUpFrom[c] = 0 }
        score = max(0, score)
        moves += 1
        return true
    }

    /// Clicking the stock: turns over one or three cards, or turns the waste back over when the stock is empty.
    @discardableResult
    mutating func dealFromStock() -> Bool {
        if !stock.isEmpty {
            for _ in 0..<min(draw.rawValue, stock.count) { waste.append(stock.removeLast()) }
        } else if !waste.isEmpty {
            stock = waste.reversed()
            waste = []
            recycles += 1
            if draw == .one { score += Scoring.recycleDrawOne } else if recycles > 3 { score += Scoring.recycleDrawThree }
            score = max(0, score)
        } else {
            return false
        }
        moves += 1
        return true
    }

    var isWon: Bool { foundations.allSatisfy { $0.count == 13 } }

    /// Every card is face up and out of the stock, so the rest is mechanical.
    var canAutoComplete: Bool {
        !isWon && stock.isEmpty && waste.isEmpty && faceUpFrom.allSatisfy { $0 == 0 }
    }

    /// The foundation a single card at the top of `spot` could go to.
    func foundationTarget(for card: Card) -> Int? {
        if card.rank == 1 { return foundations.firstIndex { $0.isEmpty } }
        return foundations.firstIndex { Board.canFound(card, on: $0.last) && !$0.isEmpty }
    }

    /// The next card for auto-complete: the lowest card that can go up.
    func autoStep() -> Move? {
        var best: (Move, Int)?
        let sources: [Spot] = [.waste] + (0..<7).map { Spot.tableau($0) }
        for spot in sources {
            guard let card = cards(at: spot).last, let f = foundationTarget(for: card) else { continue }
            if best == nil || card.rank < best!.1 { best = (Move(from: spot, to: .foundation(f)), card.rank) }
        }
        return best?.0
    }

    /// What a double-click on the card at `index` in `spot` does: up to a foundation, or else the run to a column.
    func smartMove(from spot: Spot, index: Int) -> Move? {
        let pile = cards(at: spot)
        guard index < pile.count else { return nil }
        let count = pile.count - index
        if case .foundation = spot { return nil }
        if count == 1, let f = foundationTarget(for: pile[index]) { return Move(from: spot, to: .foundation(f)) }
        let targets = (0..<7).map { Spot.tableau($0) }.filter { $0 != spot }
        let candidates = targets.map { Move(from: spot, to: $0, count: count) }.filter(isLegal)
        // Prefer building on a card over filling an empty column, and never shuffle a lone king between empty columns.
        if let onCard = candidates.first(where: { !cards(at: $0.to).isEmpty }) { return onCard }
        if case .tableau = spot, index == 0 { return nil }
        return candidates.first
    }

    /// A helpful next move, or a deal, or nil when nothing is left to try.
    func hint() -> Hint? {
        let columns = (0..<7).map { Spot.tableau($0) }
        // 1. Anything that can go up.
        for spot in [Spot.waste] + columns {
            if let card = cards(at: spot).last, let f = foundationTarget(for: card) { return .move(Move(from: spot, to: .foundation(f))) }
        }
        // 2. Moving a whole face up run that uncovers a face down card.
        for c in 0..<7 where faceUpFrom[c] > 0 {
            let count = tableau[c].count - faceUpFrom[c]
            for t in columns where t != .tableau(c) {
                let move = Move(from: .tableau(c), to: t, count: count)
                if isLegal(move) { return .move(move) }
            }
        }
        // 3. The waste card onto a column.
        if !waste.isEmpty {
            if let move = columns.map({ Move(from: .waste, to: $0) }).first(where: isLegal) { return .move(move) }
        }
        // 4. Part of a run, when that frees a card for a foundation.
        for c in 0..<7 {
            let column = tableau[c]
            guard column.count >= faceUpFrom[c] + 2 else { continue }
            for i in (faceUpFrom[c] + 1)..<column.count where foundationTarget(for: column[i - 1]) != nil {
                for t in columns where t != .tableau(c) {
                    let move = Move(from: .tableau(c), to: t, count: column.count - i)
                    if isLegal(move) { return .move(move) }
                }
            }
        }
        return stockHasPlay() ? .deal : nil
    }

    /// Whether going round the stock ever turns up a card that can be played, so the hint never deals forever.
    func stockHasPlay() -> Bool {
        let total = stock.count + waste.count
        guard total > 0 else { return false }
        var probe = self
        // Each click turns over at least one card, so total + 2 clicks covers the rest of this pass, the recycle and a full pass.
        for _ in 0..<(total + 2) {
            guard probe.dealFromStock() else { return false }
            guard let card = probe.waste.last else { continue }
            if probe.foundationTarget(for: card) != nil { return true }
            if (0..<7).contains(where: { Board.canStack(card, on: probe.tableau[$0].last) }) { return true }
        }
        return false
    }

    /// A table that could have come from real play: every card once, the right number of piles, sane face up marks.
    var isValid: Bool {
        guard foundations.count == 4, tableau.count == 7, faceUpFrom.count == 7 else { return false }
        let cards = allCards
        guard cards.count == 52, Set(cards) == Set(Card.deck) else { return false }
        for c in 0..<7 {
            let count = tableau[c].count
            if count == 0 { if faceUpFrom[c] != 0 { return false } } else if faceUpFrom[c] < 0 || faceUpFrom[c] >= count { return false }
        }
        for pile in foundations where pile.enumerated().contains(where: { $0.element.rank != $0.offset + 1 || $0.element.suit != pile[0].suit }) {
            return false
        }
        return score >= 0 && moves >= 0 && recycles >= 0
    }

    var allCards: [Card] { stock + waste + foundations.flatMap { $0 } + tableau.flatMap { $0 } }
}

// MARK: - Statistics

struct Stats: Codable, Equatable, Sendable {
    var played = 0
    var won = 0
    var streak = 0
    var bestStreak = 0
    var bestTime: Int?
    var bestScore = 0

    var winRate: Double { played == 0 ? 0 : Double(won) / Double(played) }

    mutating func recordStart() { played += 1 }

    mutating func recordWin(seconds: Int, score: Int) {
        won += 1
        streak += 1
        bestStreak = max(bestStreak, streak)
        bestTime = min(bestTime ?? seconds, seconds)
        bestScore = max(bestScore, score)
    }

    mutating func recordLoss() { streak = 0 }
}

/// The game in progress, saved so quitting never loses it.
struct SavedGame: Codable, Equatable, Sendable {
    var board: Board
    var number: Int
    var seconds: Int
    var started: Bool
    var won: Bool
}

extension Int {
    /// 3:07, or 1:02:07 past an hour.
    var clock: String {
        let h = self / 3600, m = self / 60 % 60, s = self % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
