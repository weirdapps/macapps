import AppKit
import Kit
import SwiftUI

// MARK: - Data

enum CardLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, red, orange, yellow, green, teal, blue, purple

    var id: String { rawValue }
    var name: String { self == .none ? "No Label" : rawValue.capitalized }

    var color: Color? {
        switch self {
        case .none: nil
        case .red: Color(red: 0.96, green: 0.33, blue: 0.33)
        case .orange: Color(red: 1.0, green: 0.58, blue: 0.2)
        case .yellow: Color(red: 0.98, green: 0.78, blue: 0.16)
        case .green: Color(red: 0.25, green: 0.78, blue: 0.42)
        case .teal: Color(red: 0.18, green: 0.74, blue: 0.78)
        case .blue: Color(red: 0.18, green: 0.55, blue: 1.0)
        case .purple: Color(red: 0.66, green: 0.42, blue: 0.95)
        }
    }
}

struct Card: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var notes = ""
    var label: CardLabel = .none
    var due: Date?
}

struct Column: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
}

struct Board: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var columns: [Column]
    /// Archived cards, newest first. Restoring puts a card back in the last column.
    var archived: [Card] = []

    static let defaultColumns = ["To do", "Doing", "Done"]

    static func new(_ name: String) -> Board {
        Board(name: name, columns: defaultColumns.map { Column(name: $0) })
    }

    var cardCount: Int { columns.reduce(0) { $0 + $1.cards.count } }

    func columnIndex(_ id: UUID) -> Int? { columns.firstIndex { $0.id == id } }

    func location(of card: UUID) -> (column: Int, index: Int)? {
        for (c, column) in columns.enumerated() {
            if let i = column.cards.firstIndex(where: { $0.id == card }) { return (c, i) }
        }
        return nil
    }

    func card(_ id: UUID) -> Card? {
        location(of: id).map { columns[$0.column].cards[$0.index] } ?? archived.first { $0.id == id }
    }

    // MARK: Cards

    mutating func addCard(_ card: Card, to column: UUID) {
        guard let c = columnIndex(column) else { return }
        columns[c].cards.append(card)
    }

    /// Moves a card next to `target` (before it, or after it), or to the end of the column when `target` is nil.
    @discardableResult
    mutating func moveCard(_ id: UUID, to column: UUID, near target: UUID?, after: Bool = false) -> Bool {
        guard id != target, let from = location(of: id), columnIndex(column) != nil else { return false }
        let before = columns
        let card = columns[from.column].cards.remove(at: from.index)
        let c = columnIndex(column)!
        var index = columns[c].cards.count
        if let target, let t = columns[c].cards.firstIndex(where: { $0.id == target }) { index = after ? t + 1 : t }
        columns[c].cards.insert(card, at: index)
        return columns != before
    }

    mutating func updateCard(_ id: UUID, _ change: (inout Card) -> Void) {
        if let l = location(of: id) { change(&columns[l.column].cards[l.index]) }
        else if let i = archived.firstIndex(where: { $0.id == id }) { change(&archived[i]) }
    }

    mutating func deleteCard(_ id: UUID) {
        if let l = location(of: id) { columns[l.column].cards.remove(at: l.index) }
        archived.removeAll { $0.id == id }
    }

    mutating func archiveCard(_ id: UUID) {
        guard let l = location(of: id) else { return }
        archived.insert(columns[l.column].cards.remove(at: l.index), at: 0)
    }

    /// Archives every card in the last column. Returns how many.
    @discardableResult
    mutating func archiveDone() -> Int {
        guard let last = columns.indices.last else { return 0 }
        let done = columns[last].cards
        archived.insert(contentsOf: done, at: 0)
        columns[last].cards = []
        return done.count
    }

    mutating func restore(_ id: UUID) {
        guard let last = columns.indices.last, let i = archived.firstIndex(where: { $0.id == id }) else { return }
        columns[last].cards.append(archived.remove(at: i))
    }

    // MARK: Columns

    @discardableResult
    mutating func addColumn(_ name: String) -> UUID {
        let column = Column(name: name)
        columns.append(column)
        return column.id
    }

    mutating func renameColumn(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let c = columnIndex(id) else { return }
        columns[c].name = name
    }

    /// Moves a column to `index`, clamped to the board.
    mutating func moveColumn(_ id: UUID, to index: Int) {
        guard let c = columnIndex(id) else { return }
        let column = columns.remove(at: c)
        columns.insert(column, at: max(0, min(index, columns.count)))
    }

    mutating func moveColumn(_ id: UUID, by offset: Int) {
        guard let c = columnIndex(id) else { return }
        moveColumn(id, to: c + offset)
    }

    mutating func deleteColumn(_ id: UUID) {
        columns.removeAll { $0.id == id }
    }
}

struct BoardFile: Codable {
    var boards: [Board]
    var selection: UUID?
}

// MARK: - Search and dates

enum Search {
    /// True when every word of `query` appears in the card's title or notes, ignoring case and accents.
    static func matches(_ card: Card, _ query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let haystack = card.title + "\n" + card.notes
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

enum DueStatus: Equatable {
    case overdue, today, soon, later

    static func of(_ due: Date, now: Date = Date(), calendar: Calendar = .current) -> DueStatus {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        return days < 0 ? .overdue : days == 0 ? .today : days <= 2 ? .soon : .later
    }

    static func text(_ due: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            let sameYear = calendar.component(.year, from: due) == calendar.component(.year, from: now)
            f.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
            return f.string(from: due)
        }
    }

    var color: Color {
        switch self {
        case .overdue: .red
        case .today: .orange
        case .soon: Theme.blue
        case .later: .secondary
        }
    }
}

// MARK: - Store

/// All boards, with undo for every structural change and JSON persistence through `Storage`.
@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var boards: [Board]
    @Published var selection: UUID? { didSet { if selection != oldValue { save() } } }
    @Published var search = ""
    /// The column whose quick add field is open.
    @Published var quickAdd: UUID?
    /// The column whose name is being edited in place.
    @Published var renamingColumn: UUID?
    @Published var renamingBoard: UUID?
    @Published var showArchive = false
    @Published var searchRequest = 0
    /// What is being dragged, so drop targets can act on it without decoding pasteboard data.
    var draggingCard: UUID?
    var draggingColumn: UUID?

    weak var undoManager: UndoManager?
    private let persists: Bool

    init(boards: [Board]? = nil, selection: UUID? = nil, persists: Bool = !Desktop.isSnapshot) {
        self.persists = persists
        if let boards {
            self.boards = boards
            self.selection = selection ?? boards.first?.id
        } else if persists, let file = Storage.load(BoardFile.self, app: "Board", file: "boards.json") {
            self.boards = file.boards
            self.selection = file.selection.flatMap { id in file.boards.contains { $0.id == id } ? id : nil } ?? file.boards.first?.id
        } else {
            let first = Demo.welcome
            self.boards = [first]
            self.selection = first.id
        }
    }

    static var demo: BoardStore {
        let store = BoardStore(boards: Demo.boards, persists: false)
        return store
    }

    var current: Board? { boards.first { $0.id == selection } }

    func card(_ id: UUID, in board: UUID) -> Card? {
        boards.first { $0.id == board }?.card(id)
    }

    // MARK: Changes

    /// An undoable change to one board, registered under `action` ("Move Card").
    func change(_ action: String, board id: UUID, _ body: (inout Board) -> Void) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        var board = boards[i]
        body(&board)
        guard board != boards[i] else { return }
        var next = boards
        next[i] = board
        apply(next, selection: selection, action: action)
    }

    /// A change that is not registered for undo on its own: typing in the card popover, committed by `commitEdit`.
    func edit(board id: UUID, _ body: (inout Board) -> Void) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        body(&boards[i])
        save()
    }

    /// Registers one undo step for everything edited since `snapshot` was taken, if anything changed.
    func commitEdit(since snapshot: [Board], action: String = "Edit Card") {
        guard snapshot != boards else { return }
        registerUndo(restoring: snapshot, selection: selection, action: action)
    }

    func addBoard() {
        var board = Board.new("Untitled Board")
        if boards.contains(where: { $0.name == board.name }) { board.name = "Untitled Board \(boards.count + 1)" }
        apply(boards + [board], selection: board.id, action: "New Board")
        renamingBoard = board.id
    }

    func deleteBoard(_ id: UUID) {
        guard let i = boards.firstIndex(where: { $0.id == id }) else { return }
        var next = boards
        next.remove(at: i)
        let sel = selection == id ? (next.indices.contains(i) ? next[i].id : next.last?.id) : selection
        apply(next, selection: sel, action: "Delete Board")
    }

    func renameBoard(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        change("Rename Board", board: id) { $0.name = name }
    }

    func moveBoards(from source: IndexSet, to destination: Int) {
        var next = boards
        next.move(fromOffsets: source, toOffset: destination)
        apply(next, selection: selection, action: "Move Board")
    }

    func addCard(_ title: String, to column: UUID, in board: UUID) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        change("New Card", board: board) { $0.addCard(Card(title: title), to: column) }
    }

    func moveCard(_ id: UUID, in board: UUID, to column: UUID, near target: UUID?, after: Bool = false) {
        change("Move Card", board: board) { $0.moveCard(id, to: column, near: target, after: after) }
    }

    func addColumn(in board: UUID) {
        var new: UUID?
        change("New Column", board: board) { new = $0.addColumn("New Column") }
        renamingColumn = new
    }

    func beginDrag(card: UUID) { draggingCard = card; draggingColumn = nil }
    func beginDrag(column: UUID) { draggingColumn = column; draggingCard = nil }

    // MARK: Undo and saving

    private func apply(_ next: [Board], selection sel: UUID?, action: String) {
        let old = boards, oldSelection = selection
        withAnimation(.snappy(duration: 0.28)) {
            boards = next
            selection = sel
        }
        save()
        registerUndo(restoring: old, selection: oldSelection, action: action)
    }

    private func registerUndo(restoring old: [Board], selection oldSelection: UUID?, action: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.apply(old, selection: oldSelection, action: action) }
        }
        undoManager.setActionName(action)
    }

    func save() {
        guard persists else { return }
        Storage.save(BoardFile(boards: boards, selection: selection), app: "Board", file: "boards.json")
    }
}

// MARK: - Demo data

enum Demo {
    static func day(_ offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date()))!
    }

    /// What a first launch shows: one board that explains itself.
    static var welcome: Board {
        var board = Board.new("My Board")
        board.columns[0].cards = [
            Card(title: "Drag this card to Doing", notes: "Cards move between and within columns.", label: .blue),
            Card(title: "Click a card to add notes, a label or a due date", label: .yellow),
        ]
        board.columns[2].cards = [Card(title: "Open Board", label: .green)]
        return board
    }

    static var boards: [Board] {
        let launch = Board(name: "Website relaunch", columns: [
            Column(name: "To do", cards: [
                Card(title: "Write the pricing page copy", notes: "Three tiers, one sentence each. Keep the FAQ short.", label: .purple, due: day(4)),
                Card(title: "Collect customer quotes", label: .yellow),
                Card(title: "Pick a photo for the hero", notes: "Something warm, people at work.", label: .orange, due: day(6)),
                Card(title: "Set up redirects for old URLs", label: .teal),
            ]),
            Column(name: "Doing", cards: [
                Card(title: "Design the new navigation", notes: "Five items at most. Search on the right.", label: .blue, due: day(0)),
                Card(title: "Migrate the blog posts", notes: "142 of 210 done.", label: .green, due: day(2)),
                Card(title: "Fix contrast on dark buttons", label: .red, due: day(-1)),
                Card(title: "Write alt text for the product shots", label: .yellow),
            ]),
            Column(name: "Done", cards: [
                Card(title: "Choose the typeface", label: .purple),
                Card(title: "Audit the current site", notes: "Notes in the shared folder.", label: .green),
                Card(title: "Kick-off with the team"),
                Card(title: "Agree on the launch date", notes: "Tuesday, before the newsletter.", label: .red),
            ]),
        ])
        var home = Board.new("Home")
        home.columns[0].cards = [Card(title: "Book the boiler service", label: .orange, due: day(3)), Card(title: "Return the library books")]
        home.columns[1].cards = [Card(title: "Paint the hallway", label: .teal)]
        var reading = Board(name: "Reading list", columns: ["Want to read", "Reading", "Finished"].map { Column(name: $0) })
        reading.columns[0].cards = [Card(title: "The Design of Everyday Things"), Card(title: "Shape Up")]
        reading.columns[1].cards = [Card(title: "Working in Public", label: .blue)]
        var trip = Board.new("Summer trip")
        trip.columns[0].cards = [Card(title: "Book the ferry", label: .red, due: day(10))]
        return [launch, home, reading, trip]
    }
}
