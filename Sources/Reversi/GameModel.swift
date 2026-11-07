import Foundation
import Kit
import SwiftUI

enum Opponent: String, CaseIterable, Codable, Identifiable {
    case easy, medium, hard, human
    var id: String { rawValue }

    var level: Level? { Level(rawValue: rawValue) }
    var title: String { self == .human ? "Two Players" : "\(rawValue.capitalized) Computer" }
}

/// What is kept between launches: the game in progress and the table settings.
struct SavedState: Codable {
    var squares: [Int]
    var opponent: Opponent
    var humanSide: Disc
    var showHints: Bool
}

@MainActor
final class GameModel: ObservableObject {
    @Published private(set) var game = Game()
    @Published private(set) var thinking = false
    /// The square the last flip ripple started from, so discs further away turn a little later.
    @Published private(set) var flipOrigin: Int?
    @Published private(set) var notice: String?
    @Published var opponent: Opponent = .medium { didSet { settingsChanged() } }
    @Published var humanSide: Disc = .black { didSet { settingsChanged() } }
    @Published var showHints = true { didSet { save() } }

    private let persists: Bool
    private var generation = 0
    private var loading = false

    init(persists: Bool = !Desktop.isSnapshot) {
        self.persists = persists
        guard persists, let saved = Storage.load(SavedState.self, app: "Reversi", file: "game.json") else { return }
        loading = true
        game = Game.replay(saved.squares)
        opponent = saved.opponent
        humanSide = saved.humanSide
        showHints = saved.showHints
        loading = false
        flipOrigin = game.lastMove
        DispatchQueue.main.async { self.scheduleComputer() }
    }

    /// A game in the middle of play, for the website screenshot: both sides played by the greedy engine.
    static var demo: GameModel {
        let model = GameModel(persists: false)
        var g = Game()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<19 {
            guard let m = Engine.choose(g.position, level: .medium, random: &rng) else { break }
            g.play(m)
        }
        model.game = g
        model.flipOrigin = g.lastMove
        model.humanSide = g.position.toMove
        return model
    }

    // MARK: State

    var position: Position { game.position }
    var isOver: Bool { game.isOver }

    func isComputer(_ side: Disc) -> Bool { opponent != .human && side != humanSide }

    var humanCanPlay: Bool { !thinking && !isOver && !isComputer(position.toMove) }

    var hints: UInt64 { showHints && humanCanPlay ? position.legalMoves : 0 }

    var canUndo: Bool {
        opponent == .human ? !game.squares.isEmpty : game.records.contains { $0.square != nil && $0.player == humanSide }
    }

    func playerName(_ side: Disc) -> String {
        if opponent == .human { return side.name }
        return isComputer(side) ? "Computer" : "You"
    }

    func playerDetail(_ side: Disc) -> String {
        if opponent == .human { return "Player \(side == .black ? 1 : 2)" }
        return isComputer(side) ? "\(opponent.level?.title ?? "") \u{00B7} \(side.name)" : side.name
    }

    var status: String {
        if isOver {
            let b = position.count(.black), w = position.count(.white)
            if b == w { return "A draw, \(b) all" }
            let winner: Disc = b > w ? .black : .white
            return "\(winnerTitle(winner)) \(max(b, w)) to \(min(b, w))"
        }
        if thinking { return "Computer is thinking" }
        if let notice { return notice }
        if opponent != .human { return isComputer(position.toMove) ? "Computer to move" : "Your move" }
        return "\(position.toMove.name) to move"
    }

    var resultTitle: String {
        let b = position.count(.black), w = position.count(.white)
        if b == w { return "It's a draw" }
        return winnerTitle(b > w ? .black : .white)
    }

    /// The banner shown when `passer` has no legal move, worded for whoever is reading the board.
    func passNotice(_ passer: Disc) -> String {
        if opponent == .human { return "\(passer.name) has no move and passes" }
        return isComputer(passer) ? "Computer has no move and passes. Your move again" : "You have no move, so you pass"
    }

    private func winnerTitle(_ winner: Disc) -> String {
        if opponent == .human { return "\(winner.name) wins" }
        return isComputer(winner) ? "Computer wins" : "You win"
    }

    // MARK: Actions

    func tap(_ square: Int) {
        guard humanCanPlay, position.legalMoves & (1 << UInt64(square)) != 0 else { return }
        apply(square)
    }

    func newGame() {
        generation += 1
        thinking = false
        notice = nil
        flipOrigin = nil
        game = Game()
        save()
        scheduleComputer()
    }

    func undo() {
        guard canUndo else { return }
        generation += 1
        thinking = false
        notice = nil
        if opponent == .human {
            flipOrigin = game.undo()
        } else {
            // Take back the computer's replies too, back to the last position where it was your turn.
            while let square = game.undo() {
                flipOrigin = square
                if position.toMove == humanSide { break }
            }
        }
        save()
        scheduleComputer()
    }

    private func apply(_ square: Int) {
        let before = game.records.count
        let mover = position.toMove
        guard game.play(square) else { return }
        flipOrigin = square
        if game.records.count > before + 1 {
            notice = passNotice(mover.opponent)
        } else if !isComputer(mover) {
            // Your pass notice stays up through the computer's extra move, until you play again.
            notice = nil
        }
        save()
        scheduleComputer()
    }

    private func settingsChanged() {
        guard !loading else { return }
        generation += 1
        thinking = false
        save()
        scheduleComputer()
    }

    /// Runs the engine off the main thread when it is the computer's turn. A newer action cancels the result.
    private func scheduleComputer() {
        guard !isOver, isComputer(position.toMove), let level = opponent.level, !Desktop.isSnapshot else { return }
        generation += 1
        let token = generation
        let pos = position
        thinking = true
        Task { @MainActor in
            let started = Date()
            let move = await Task.detached(priority: .userInitiated) { () -> Int? in
                var rng = SystemRandomNumberGenerator()
                return Engine.choose(pos, level: level, random: &rng)
            }.value
            // A short pause so a reply never lands before the flips of your own move have settled.
            let wait = 0.7 - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            guard token == self.generation else { return }
            self.thinking = false
            if let move { self.apply(move) }
        }
    }

    private func save() {
        guard persists, !loading else { return }
        Storage.save(SavedState(squares: game.squares, opponent: opponent, humanSide: humanSide, showHints: showHints),
                     app: "Reversi", file: "game.json")
    }
}
