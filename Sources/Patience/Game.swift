import AppKit
import Kit
import SwiftUI

enum Felt: String, CaseIterable, Codable, Identifiable {
    case green, blue, burgundy, slate

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Centre and edge colours of the table.
    var colors: (Color, Color) {
        switch self {
        case .green: (Color(hex: 0x2F9E5E), Color(hex: 0x145A35))
        case .blue: (Color(hex: 0x2F78A8), Color(hex: 0x14395E))
        case .burgundy: (Color(hex: 0x9E3048), Color(hex: 0x561526))
        case .slate: (Color(hex: 0x56616C), Color(hex: 0x23292F))
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The live game: a board, its undo stack, the clock, statistics and preferences.
@MainActor
final class GameModel: ObservableObject {
    @Published private(set) var board: Board
    @Published private(set) var number: Int
    @Published private(set) var seconds = 0
    @Published private(set) var started = false
    @Published private(set) var won = false
    @Published private(set) var finalScore = 0
    @Published private(set) var stats = Stats()
    @Published private(set) var hint: Hint?
    @Published private(set) var noHint = false
    @Published private(set) var autoCompleting = false
    @Published private(set) var celebration: Date?
    /// Cards that just moved, drawn above the rest while they fly to their new place.
    @Published private(set) var lifted: Set<Int> = []
    @Published var showStats = false
    @Published var showChooser = false
    @Published var felt: Felt { didSet { savePrefs() } }
    @Published var drawMode: DrawMode {
        didSet {
            savePrefs()
            // A fresh deal takes the new mode at once; a game in progress keeps its own until the next deal.
            if !started && board.draw != drawMode { deal(number, countLoss: false) }
        }
    }

    private var undoStack: [Board] = []
    private var timer: Timer?
    private var hintTask: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private let persists: Bool
    var isActive = true

    init(persists: Bool = true) {
        self.persists = persists
        let defaults = UserDefaults.standard
        let startFelt = persists ? Felt(rawValue: defaults.string(forKey: "felt") ?? "") ?? .green : .green
        let startDraw = persists ? DrawMode(rawValue: defaults.integer(forKey: "draw")) ?? .one : .one
        felt = startFelt
        drawMode = startDraw
        if persists, let saved = Storage.load(SavedGame.self, app: "Patience", file: "game.json"), saved.board.isValid,
           (1...999_999).contains(saved.number), saved.seconds >= 0 {
            board = saved.board
            number = saved.number
            seconds = saved.seconds
            started = saved.started
            won = saved.won
        } else {
            let fresh = GameModel.randomNumber()
            number = fresh
            board = Board.deal(game: fresh, draw: startDraw)
        }
        if persists { stats = Storage.load(Stats.self, app: "Patience", file: "stats.json") ?? Stats() }
        if won { finalScore = Scoring.total(base: board.score, seconds: seconds, won: true) }
        if persists {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Common modes, so the clock keeps going while a menu is open or the window is resized.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// A game part way through, for the website screenshot.
    static var demo: GameModel {
        let model = GameModel(persists: false)
        model.felt = .green
        model.drawMode = .three
        model.deal(4217, countLoss: false)
        var steps = 0
        while steps < 46, let hint = model.board.hint() {
            switch hint {
            case .deal: model.board.dealFromStock()
            case .move(let move): model.board.apply(move)
            }
            steps += 1
        }
        model.started = true
        model.seconds = 263
        return model
    }

    /// Puts an arbitrary table in play, for the self-test.
    func setUp(_ board: Board, started: Bool = true) {
        self.board = board
        self.started = started
        undoStack = []
    }

    static func randomNumber() -> Int { Int.random(in: 1...999_999) }

    var score: Int { won ? finalScore : Scoring.total(base: board.score, seconds: seconds, won: false) }
    var canUndo: Bool { !undoStack.isEmpty && !won && !autoCompleting }
    var canAutoComplete: Bool { board.canAutoComplete && !autoCompleting }

    // MARK: Actions

    func newGame() { deal(GameModel.randomNumber(), countLoss: true) }
    func restart() { deal(number, countLoss: true) }

    func deal(_ number: Int, countLoss: Bool) {
        if countLoss && started && !won {
            stats.recordLoss()
            saveStats()
        }
        // A new deal stops an auto-complete that is still moving cards, so it never plays on the fresh table.
        autoTask?.cancel()
        autoTask = nil
        autoCompleting = false
        self.number = number
        board = Board.deal(game: number, draw: drawMode)
        undoStack = []
        seconds = 0
        started = false
        won = false
        finalScore = 0
        celebration = nil
        lifted = []
        clearHint()
        save()
    }

    func dealFromStock() {
        guard !won, !autoCompleting else { return }
        var next = board
        guard next.dealFromStock() else { return }
        lifted = Set(next.waste.suffix(board.draw.rawValue).map(\.id))
        commit(next)
    }

    @discardableResult
    func perform(_ move: Move) -> Bool {
        guard !won, !autoCompleting else { return false }
        var next = board
        let moving = board.cards(at: move.from).suffix(move.count).map(\.id)
        guard next.apply(move) else { return false }
        lifted = Set(moving)
        commit(next)
        return true
    }

    /// Double-click: send the card up, or the run to the best column.
    func smartMove(from spot: Spot, index: Int) {
        guard let move = board.smartMove(from: spot, index: index) else { NSSound.beep(); return }
        perform(move)
    }

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        board = previous
        lifted = []
        clearHint()
        save()
    }

    func showHint() {
        guard !won else { return }
        hintTask?.cancel()
        hint = board.hint()
        noHint = hint == nil
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.clearHint() }
        }
    }

    func autoComplete() {
        guard canAutoComplete else { return }
        undoStack.append(board)
        autoCompleting = true
        autoTask = Task { [weak self] in
            while !Task.isCancelled, let self, let move = self.board.autoStep() {
                var next = self.board
                next.apply(move)
                withAnimation(.snappy(duration: 0.18)) {
                    self.lifted = Set(self.board.cards(at: move.from).suffix(1).map(\.id))
                    self.board = next
                }
                try? await Task.sleep(for: .milliseconds(70))
            }
            guard !Task.isCancelled else { return }
            self?.autoCompleting = false
            self?.finishIfWon()
            self?.save()
        }
    }

    func resetStats() {
        stats = Stats()
        saveStats()
    }

    func endCelebration() { celebration = nil }

    // MARK: Internals

    private func commit(_ next: Board) {
        undoStack.append(board)
        if undoStack.count > 500 { undoStack.removeFirst() }
        if !started {
            started = true
            stats.recordStart()
            saveStats()
        }
        board = next
        clearHint()
        finishIfWon()
        save()
    }

    private func finishIfWon() {
        guard board.isWon, !won else { return }
        won = true
        finalScore = Scoring.total(base: board.score, seconds: seconds, won: true)
        stats.recordWin(seconds: seconds, score: finalScore)
        saveStats()
        celebration = Date()
    }

    private func clearHint() {
        hint = nil
        noHint = false
    }

    private func tick() {
        guard started, !won, isActive else { return }
        seconds += 1
        if seconds % 5 == 0 { save() }
    }

    func save() {
        guard persists else { return }
        Storage.save(SavedGame(board: board, number: number, seconds: seconds, started: started, won: won),
                     app: "Patience", file: "game.json")
    }

    private func saveStats() {
        guard persists else { return }
        Storage.save(stats, app: "Patience", file: "stats.json")
    }

    private func savePrefs() {
        guard persists else { return }
        UserDefaults.standard.set(felt.rawValue, forKey: "felt")
        UserDefaults.standard.set(drawMode.rawValue, forKey: "draw")
    }
}
