import AppKit
import Combine
import Kit
import SwiftUI

// MARK: - Game

/// One game in progress: the puzzle, what the player has entered, pencil marks, time and history.
/// Pure value type, so the self-test can play it without a window.
struct Game: Codable, Equatable {
    var difficulty: Difficulty
    var givens: [Int]
    var solution: [Int]
    var values: [Int]
    var notes: [UInt16]
    var elapsed: TimeInterval = 0
    var hints = 0
    var completed = false

    struct Snapshot: Equatable {
        var values: [Int]
        var notes: [UInt16]
    }

    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []

    enum CodingKeys: String, CodingKey {
        case difficulty, givens, solution, values, notes, elapsed, hints, completed
    }

    init(puzzle: Puzzle, difficulty: Difficulty) {
        self.difficulty = difficulty
        givens = puzzle.givens
        solution = puzzle.solution
        values = puzzle.givens
        notes = [UInt16](repeating: 0, count: 81)
    }

    func isGiven(_ i: Int) -> Bool { givens[i] != 0 }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var conflicts: Set<Int> { Sudoku.conflicts(values) }
    var filled: Int { values.filter { $0 != 0 }.count }

    /// How many of `digit` are still to place.
    func remaining(_ digit: Int) -> Int { max(0, 9 - values.filter { $0 == digit }.count) }

    private mutating func record() {
        undoStack.append(Snapshot(values: values, notes: notes))
        if undoStack.count > 500 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Writes a digit, or clears it when the cell already holds that digit. Clears the cell's notes and
    /// removes the digit from the notes of every peer. Returns false when nothing changed.
    @discardableResult
    mutating func enter(_ digit: Int, at i: Int) -> Bool {
        guard !completed, !isGiven(i), (1...9).contains(digit) else { return false }
        record()
        if values[i] == digit {
            values[i] = 0
        } else {
            values[i] = digit
            notes[i] = 0
            for p in Sudoku.peers[i] { notes[p] &= ~(1 << digit) }
        }
        completed = values == solution
        return true
    }

    /// Toggles a pencil mark in an empty cell.
    @discardableResult
    mutating func toggleNote(_ digit: Int, at i: Int) -> Bool {
        guard !completed, !isGiven(i), values[i] == 0, (1...9).contains(digit) else { return false }
        record()
        notes[i] ^= 1 << digit
        return true
    }

    /// Clears the digit, or the notes when the cell has no digit.
    @discardableResult
    mutating func erase(at i: Int) -> Bool {
        guard !completed, !isGiven(i), values[i] != 0 || notes[i] != 0 else { return false }
        record()
        if values[i] != 0 { values[i] = 0 } else { notes[i] = 0 }
        return true
    }

    /// Fills one cell with its answer: the preferred cell if it is empty or wrong, otherwise a wrong cell,
    /// otherwise the empty cell with the fewest candidates. Returns the cell it filled.
    @discardableResult
    mutating func hint(preferring preferred: Int?) -> Int? {
        guard !completed else { return nil }
        let open = (0..<81).filter { values[$0] != solution[$0] }
        guard !open.isEmpty else { return nil }
        let target: Int
        if let preferred, open.contains(preferred) {
            target = preferred
        } else if let wrong = open.first(where: { values[$0] != 0 }) {
            target = wrong
        } else {
            let correct = (0..<81).map { values[$0] == solution[$0] ? values[$0] : 0 }
            target = open.min { Sudoku.candidates(correct, $0).nonzeroBitCount < Sudoku.candidates(correct, $1).nonzeroBitCount }!
        }
        record()
        let digit = solution[target]
        values[target] = digit
        notes[target] = 0
        for p in Sudoku.peers[target] { notes[p] &= ~(1 << digit) }
        hints += 1
        completed = values == solution
        return target
    }

    mutating func undo() {
        guard !completed, let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(values: values, notes: notes))
        values = last.values
        notes = last.notes
    }

    mutating func redo() {
        guard !completed, let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(values: values, notes: notes))
        values = next.values
        notes = next.notes
        completed = values == solution
    }

    /// Back to the givens, keeping the clock.
    mutating func restart() {
        guard !completed else { return }
        record()
        values = givens
        notes = [UInt16](repeating: 0, count: 81)
    }
}

/// Best times and solved counts per difficulty.
struct Records: Codable, Equatable {
    var best: [String: TimeInterval] = [:]
    var solved: [String: Int] = [:]

    mutating func add(_ difficulty: Difficulty, time: TimeInterval) -> Bool {
        solved[difficulty.rawValue, default: 0] += 1
        if let old = best[difficulty.rawValue], old <= time { return false }
        best[difficulty.rawValue] = time
        return true
    }
}

enum Clock {
    /// 4:27 or 1:02:09.
    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Model

@MainActor
final class NineModel: ObservableObject {
    @Published var game: Game?
    @Published var selected: Int? = 40
    @Published var notesMode = false
    @Published var paused = false
    @Published var generating = false
    @Published var records = Records()
    @Published var newRecord = false
    /// The cell a hint just filled, for a brief glow.
    @Published var hinted: Int?
    /// Bumped on every completion to run the celebration wave.
    @Published var celebration = 0
    /// A new game waiting for the player to confirm abandoning the one in progress.
    @Published var pendingNewGame: Difficulty?
    @Published var showConflicts = true {
        didSet { if persists { UserDefaults.standard.set(showConflicts, forKey: "showConflicts") } }
    }
    @Published var difficulty: Difficulty = .medium {
        didSet { if persists { UserDefaults.standard.set(difficulty.rawValue, forKey: "difficulty") } }
    }

    private let persists: Bool
    private var observers: [NSObjectProtocol] = []
    private var ticks = 0
    private var token = 0

    init(persists: Bool = !Desktop.isSnapshot) {
        self.persists = persists
        guard persists else { return }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showConflicts") != nil { showConflicts = defaults.bool(forKey: "showConflicts") }
        if let raw = defaults.string(forKey: "difficulty"), let d = Difficulty(rawValue: raw) { difficulty = d }
        records = Storage.load(Records.self, app: "Nine", file: "records.json") ?? Records()
        if let saved = Storage.load(Game.self, app: "Nine", file: "game.json"), saved.values.count == 81 {
            game = saved
        } else {
            newGame(difficulty)
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autoPause() }
        })
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        })
    }

    var isPlaying: Bool { game.map { !$0.completed } ?? false && !paused && !generating }

    // MARK: Game flow

    func newGame(_ level: Difficulty? = nil) {
        let level = level ?? difficulty
        difficulty = level
        pendingNewGame = nil
        generating = true
        paused = false
        notesMode = false
        token += 1
        let token = token
        Task.detached(priority: .userInitiated) {
            var rng = SystemRandomNumberGenerator()
            let puzzle = Generator.generate(level, using: &rng)
            await MainActor.run {
                guard token == self.token else { return }
                self.game = Game(puzzle: puzzle, difficulty: level)
                self.selected = 40
                self.hinted = nil
                self.newRecord = false
                self.generating = false
                self.save()
            }
        }
    }

    /// Starts a new game, asking first when the current one has progress that would be lost.
    func requestNewGame(_ level: Difficulty? = nil) {
        let level = level ?? difficulty
        if let game, !game.completed, game.values != game.givens, !generating {
            pendingNewGame = level
        } else {
            newGame(level)
        }
    }

    func restart() { mutate { $0.restart() } }

    func togglePause() {
        guard let game, !game.completed, !generating else { return }
        withAnimation(.snappy) { paused.toggle() }
    }

    private func autoPause() {
        if isPlaying { withAnimation(.snappy) { paused = true } }
        save()
    }

    func tick() {
        guard persists, isPlaying else { return }
        game?.elapsed += 1
        ticks += 1
        if ticks % 10 == 0 { save() }
    }

    // MARK: Input

    func select(_ i: Int) {
        guard (0..<81).contains(i) else { return }
        selected = i
    }

    func move(dx: Int, dy: Int) {
        let i = selected ?? 40
        let r = (Sudoku.row(i) + dy + 9) % 9, c = (Sudoku.col(i) + dx + 9) % 9
        selected = r * 9 + c
    }

    /// A digit from the keyboard or the number pad: a note in notes mode, otherwise the answer.
    func input(_ digit: Int) {
        guard let i = selected else { return }
        mutate { _ = notesMode ? $0.toggleNote(digit, at: i) : $0.enter(digit, at: i) }
    }

    func erase() {
        guard let i = selected else { return }
        mutate { $0.erase(at: i) }
    }

    func hint() {
        var filled: Int?
        mutate { filled = $0.hint(preferring: selected) }
        guard let filled else { return }
        selected = filled
        hinted = filled
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.hinted == filled { withAnimation(.easeOut(duration: 0.4)) { self?.hinted = nil } }
        }
    }

    func undo() { mutate { $0.undo() } }
    func redo() { mutate { $0.redo() } }
    func toggleNotesMode() { withAnimation(.snappy(duration: 0.2)) { notesMode.toggle() } }

    /// Applies a change while playing, then saves and celebrates a finish.
    private func mutate(_ change: (inout Game) -> Void) {
        guard var game, isPlaying else { return }
        let was = game.completed
        withAnimation(.snappy(duration: 0.18)) {
            change(&game)
            self.game = game
        }
        if game.completed && !was { finish(game) }
        save()
    }

    private func finish(_ game: Game) {
        selected = nil
        newRecord = records.add(game.difficulty, time: game.elapsed)
        celebration += 1
        if persists { Storage.save(records, app: "Nine", file: "records.json") }
    }

    func save() {
        guard persists, let game else { return }
        Storage.save(game, app: "Nine", file: "game.json")
    }

    /// Handles a key press on the board. Command shortcuts are left to the menus.
    func handle(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) || press.modifiers.contains(.control) { return .ignored }
        switch press.key {
        case .upArrow: move(dx: 0, dy: -1)
        case .downArrow: move(dx: 0, dy: 1)
        case .leftArrow: move(dx: -1, dy: 0)
        case .rightArrow: move(dx: 1, dy: 0)
        case .delete, .deleteForward: erase()
        case .space where paused: togglePause()
        default:
            let ch = press.characters.lowercased()
            if let d = Int(ch), (1...9).contains(d) {
                input(d)
            } else if ch == "0" {
                erase()
            } else if ch == "n" {
                toggleNotesMode()
            } else {
                return .ignored
            }
        }
        return .handled
    }

    // MARK: Demo

    /// A game part way through, for the website screenshot.
    static var demo: NineModel {
        let model = NineModel(persists: false)
        let givens = Sudoku.parse("..3.2.6..9..3.5..1..18.64....81.29..7.......8..67.82....26.95..8..2.3..9..5.1.3..")
        let solution = Solver.solve(givens)!
        var game = Game(puzzle: Puzzle(givens: givens, solution: solution, level: 1), difficulty: .medium)
        for i in [0, 1, 3, 5, 9, 11, 13, 21, 22, 23, 29, 30, 31, 34, 36, 37, 39, 40, 42, 44, 47, 48, 51, 57, 66, 70, 76] {
            game.enter(solution[i], at: i)
        }
        for i in 0..<81 where game.values[i] == 0 && [7, 8, 16, 17, 25, 26, 33, 35, 45, 46, 53, 63, 64, 72, 73, 79, 80].contains(i) {
            for d in Sudoku.digits(of: Sudoku.candidates(game.values, i)) { game.toggleNote(d, at: i) }
        }
        game.elapsed = 267
        game.hints = 1
        model.game = game
        model.difficulty = .medium
        model.selected = 40
        model.records = Records(best: ["medium": 371], solved: ["medium": 12])
        return model
    }
}
