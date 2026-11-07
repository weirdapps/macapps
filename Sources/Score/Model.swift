import AppKit
import Kit
import SwiftUI

// MARK: - Game

struct Player: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var color: Int // Index into `PlayerColor.all`.
}

enum WinRule: String, Codable, CaseIterable, Identifiable {
    case highest, lowest
    var id: String { rawValue }
    var label: String { self == .highest ? "Highest score wins" : "Lowest score wins" }
    var short: String { self == .highest ? "Highest" : "Lowest" }
}

struct Game: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var players: [Player]
    /// `rounds[r][p]` is player p's points in round r; nil until entered.
    var rounds: [[Int?]] = []
    var rule: WinRule = .highest
    /// When any total reaches this, the game ends.
    var target: Int?
    var created = Date()
    var ended: Date?
    /// True when `ended` was set by reaching the target, so a correction below it reopens the game.
    var endedByTarget = false

    var isOver: Bool { ended != nil }

    func total(_ p: Int) -> Int { rounds.reduce(0) { $0 + (p < $1.count ? ($1[p] ?? 0) : 0) } }
    var totals: [Int] { players.indices.map(total) }
    var hasScores: Bool { rounds.contains { $0.contains { $0 != nil } } }

    /// Indices of the players in the lead (several on a tie); empty before anyone scores.
    var leaders: [Int] {
        guard hasScores, !players.isEmpty else { return [] }
        let t = totals
        let best = rule == .highest ? t.max()! : t.min()!
        return t.indices.filter { t[$0] == best }
    }

    /// Standard competition ranking: 1, 2, 2, 4.
    func rank(of p: Int) -> Int {
        let t = totals
        return 1 + t.filter { rule == .highest ? $0 > t[p] : $0 < t[p] }.count
    }

    /// "Ahead by 30", "30 behind" or "Tied for the lead"; nil before anyone scores or with one player.
    func standingText(_ p: Int) -> String? {
        guard players.count > 1, hasScores, players.indices.contains(p) else { return nil }
        let t = totals, lead = leaders
        if lead.contains(p) {
            if lead.count > 1 { return "Tied for the lead" }
            let others = t.indices.filter { $0 != p }.map { t[$0] }
            let next = rule == .highest ? others.max()! : others.min()!
            return "Ahead by \(abs(t[p] - next))"
        }
        return "\(abs(t[p] - t[lead[0]])) behind"
    }

    var reachedTarget: Bool {
        guard let target else { return false }
        return totals.contains { $0 >= target }
    }

    /// Ends the game when the target is reached, and reopens it when a correction takes everyone back below.
    mutating func settle(now: Date = Date()) {
        if reachedTarget, ended == nil {
            ended = now
            endedByTarget = true
        } else if !reachedTarget, endedByTarget {
            ended = nil
            endedByTarget = false
        }
    }

    mutating func setScore(_ value: Int?, round r: Int, player p: Int) {
        guard rounds.indices.contains(r), players.indices.contains(p) else { return }
        rounds[r][p] = value
        settle()
    }

    /// Adds points to the current (last) round, starting one if there is none.
    mutating func add(_ points: Int, player p: Int) {
        guard players.indices.contains(p) else { return }
        if rounds.isEmpty { addRound() }
        rounds[rounds.count - 1][p] = (rounds[rounds.count - 1][p] ?? 0) + points
        settle()
    }

    mutating func addRound() {
        rounds.append(Array(repeating: nil, count: players.count))
    }

    mutating func removeRound(_ r: Int) {
        guard rounds.indices.contains(r) else { return }
        rounds.remove(at: r)
        settle()
    }

    mutating func end(now: Date = Date()) {
        ended = now
        endedByTarget = false
    }

    mutating func resume() {
        ended = nil
        endedByTarget = false
    }

    /// A fresh game with the same players and rules.
    func rematch(now: Date = Date()) -> Game {
        var game = Game(name: name, players: players.map { Player(name: $0.name, color: $0.color) }, rule: rule, target: target,
                        created: now)
        game.addRound()
        return game
    }

    var rulesText: String {
        var parts = [rule.label]
        if let target { parts.append("first to \(target)") }
        return parts.joined(separator: " · ")
    }

    /// "Maria wins", "Maria and Nikos tie", or nil before anyone scores.
    var resultText: String? {
        let lead = leaders
        guard !lead.isEmpty else { return nil }
        let names = lead.map { players[$0].name }
        if names.count == 1 { return "\(names[0]) \(isOver ? "wins" : "leads")" }
        let list = names.count == 2 ? "\(names[0]) and \(names[1])" : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "\(list) \(isOver ? "tie" : "are tied")"
    }

    var sidebarSubtitle: String {
        if isOver, let ended {
            let who = leaders.count == 1 ? "\(players[leaders[0]].name) won" : leaders.isEmpty ? "No scores" : "Tie"
            return "\(who) · \(ended.formatted(.dateTime.day().month(.abbreviated)))"
        }
        let round = "Round \(max(rounds.count, 1))"
        guard let result = resultText else { return round }
        return "\(round) · \(result)"
    }
}

// MARK: - Parsing

enum ScoreParser {
    /// Parses what someone typed in a score cell. `.some(nil)` clears the cell, nil means the text is not a score.
    static func parse(_ text: String) -> Int?? {
        var s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2212}", with: "-")
        if s.isEmpty { return .some(nil) }
        if s.hasPrefix("+") { s.removeFirst() }
        s = s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let n = Int(s), abs(n) < 100_000_000 else { return nil }
        return .some(n)
    }
}

// MARK: - Colours

enum PlayerColor {
    static let all: [(name: String, hex: UInt32)] = [
        ("Blue", 0x3F6CF5), ("Red", 0xE5484D), ("Green", 0x2FA36B), ("Orange", 0xF27A1A),
        ("Purple", 0x8E4EC6), ("Pink", 0xD6409F), ("Teal", 0x12A594), ("Brown", 0xA0703C),
    ]
    static func color(_ i: Int) -> Color { Color(nsColor: rgb(all[((i % all.count) + all.count) % all.count].hex)) }
    static func name(_ i: Int) -> String { all[((i % all.count) + all.count) % all.count].name }
}

enum Theme {
    static let accent = [Color(nsColor: rgb(0x3F6CF5)), Color(nsColor: rgb(0x1D2F9E))]
    static let blue = Color(nsColor: rgb(0x3F6CF5))
    static let gold = Color(nsColor: rgb(0xE8B02C))
    static let goldGradient = LinearGradient(colors: [Color(nsColor: rgb(0xF9D65C)), Color(nsColor: rgb(0xDE9F1E))],
                                             startPoint: .top, endPoint: .bottom)
    static let maxPlayers = 8
}

// MARK: - Model

struct Library: Codable {
    var games: [Game]
    var selection: UUID?
}

@MainActor
final class ScoreModel: ObservableObject {
    @Published var games: [Game] { didSet { save() } }
    @Published var selection: UUID? { didSet { save() } }
    @Published var showTotals = false
    @Published var draft: Game?
    weak var undoManager: UndoManager?
    private let persists: Bool

    static let file = "games.json"

    init(games: [Game] = [], selection: UUID? = nil, persists: Bool = false) {
        self.games = games
        self.selection = selection ?? games.first?.id
        self.persists = persists
    }

    /// The user's library from Application Support.
    static func load() -> ScoreModel {
        let library = Storage.load(Library.self, app: "Score", file: file)
        return ScoreModel(games: library?.games ?? [], selection: library?.selection, persists: true)
    }

    private func save() {
        guard persists, !Desktop.isSnapshot else { return }
        Storage.save(Library(games: games, selection: selection), app: "Score", file: Self.file)
    }

    var current: Game? { games.first { $0.id == selection } }
    var inProgress: [Game] { games.filter { !$0.isOver }.sorted { $0.created > $1.created } }
    var history: [Game] { games.filter(\.isOver).sorted { ($0.ended ?? $0.created) > ($1.ended ?? $1.created) } }

    // MARK: Undoable changes

    /// Runs `body` and registers an undo step that restores the library as it was.
    private func change(_ name: String, _ body: () -> Void) {
        let before = games, beforeSelection = selection
        body()
        guard games != before || selection != beforeSelection else { return }
        registerUndo(name, games: before, selection: beforeSelection)
    }

    private func registerUndo(_ name: String, games old: [Game], selection oldSelection: UUID?) {
        guard let undoManager else { return }
        let now = games, nowSelection = selection
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.games = old
                model.selection = old.contains { $0.id == oldSelection } ? oldSelection : old.first?.id
                model.registerUndo(name, games: now, selection: nowSelection)
            }
        }
        undoManager.setActionName(name)
    }

    func update(_ id: UUID?, _ name: String, _ body: (inout Game) -> Void) {
        guard let i = games.firstIndex(where: { $0.id == id }) else { return }
        change(name) { body(&games[i]) }
    }

    func updateCurrent(_ name: String, _ body: (inout Game) -> Void) { update(selection, name, body) }

    // MARK: Actions

    /// Opens the New Game sheet, seeded with the most recent game's players.
    func newGame() {
        let recent = games.max { $0.created < $1.created }
        let players = recent?.players.map { Player(name: $0.name, color: $0.color) }
            ?? [Player(name: "Player 1", color: 0), Player(name: "Player 2", color: 1)]
        draft = Game(name: recent?.name ?? "", players: players, rule: recent?.rule ?? .highest, target: recent?.target)
    }

    func start(_ draft: Game) {
        var game = draft
        game.name = game.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Game \(games.count + 1)" : game.name
            .trimmingCharacters(in: .whitespaces)
        for i in game.players.indices where game.players[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            game.players[i].name = "Player \(i + 1)"
        }
        game.created = Date()
        game.rounds = []
        game.addRound()
        change("New Game") {
            games.append(game)
            selection = game.id
        }
        showTotals = false
    }

    func rematch() {
        guard let game = current else { return }
        let next = game.rematch()
        change("Rematch") {
            games.append(next)
            selection = next.id
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Game" : "Delete Games") {
            let fallback = selection.map(ids.contains) == true
            games.removeAll { ids.contains($0.id) }
            if fallback { selection = inProgress.first?.id ?? history.first?.id }
        }
    }

    func addRound() { updateCurrent("New Round") { $0.addRound() } }
    func removeLastRound() { updateCurrent("Delete Round") { $0.removeRound($0.rounds.count - 1) } }
    func toggleEnded() {
        guard let game = current else { return }
        updateCurrent(game.isOver ? "Resume Game" : "End Game") { game.isOver ? $0.resume() : $0.end() }
    }

    // MARK: Demo

    static var demo: ScoreModel {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let day: TimeInterval = 86_400
        let family = [Player(name: "Maria", color: 1), Player(name: "Dimitris", color: 0), Player(name: "Eleni", color: 2),
                      Player(name: "Nikos", color: 3)]
        var rummy = Game(name: "Rummy", players: family, rule: .highest, target: 500, created: now)
        rummy.rounds = [[45, 60, 20, 35], [80, 15, 55, 40], [30, 70, 65, 10], [95, 40, 25, 60], [50, 85, 40, 45],
                        [60, 45, 70, 30], [35, 55, 20, 65], [40, 30, 45, 50], [15, 20, nil, nil]]

        var hearts = Game(name: "Hearts", players: Array(family.prefix(4)), rule: .lowest, target: 100, created: now - 2 * day)
        hearts.rounds = [[6, 13, 0, 7], [26, 0, 0, 0], [3, 9, 8, 6], [14, 4, 2, 6], [20, 11, 0, 21], [8, 12, 26, 0],
                         [26, 0, 0, 0]]
        hearts.ended = now - 2 * day + 5400
        hearts.endedByTarget = true

        var catan = Game(name: "Catan", players: [family[0], family[1], family[2]], rule: .highest, target: 10,
                         created: now - 5 * day)
        catan.rounds = [[4, 6, 10]]
        catan.ended = now - 5 * day + 7200
        catan.endedByTarget = true

        var scrabble = Game(name: "Scrabble", players: [family[1], family[0]], rule: .highest, created: now - 9 * day)
        scrabble.rounds = [[24, 31], [18, 12], [40, 22], [9, 35], [27, 30], [33, 14]]
        scrabble.ended = now - 9 * day + 4000

        var darts = Game(name: "Darts", players: [family[3], family[1]], rule: .lowest, created: now - 1 * day)
        darts.rounds = [[60, 45], [41, 85]]

        return ScoreModel(games: [rummy, darts, hearts, catan, scrabble], selection: rummy.id)
    }
}
