import AppKit
import Kit
import SwiftUI

// MARK: - Data

enum Grade: Int, Codable, CaseIterable, Identifiable {
    case again = 1, hard, good, easy

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
    var color: Color {
        switch self {
        case .again: Color(red: 0.90, green: 0.27, blue: 0.24)
        case .hard: Color(red: 0.93, green: 0.55, blue: 0.10)
        case .good: Color(red: 0.20, green: 0.66, blue: 0.33)
        case .easy: Color(red: 0.18, green: 0.48, blue: 0.92)
        }
    }
    var key: KeyEquivalent { KeyEquivalent(Character(String(rawValue))) }
}

struct Card: Codable, Identifiable, Hashable {
    var id = UUID()
    var front: String
    var back: String
    var created: Date
    /// SM-2 easiness factor, never below `Scheduler.minEase`.
    var ease: Double = Scheduler.startEase
    /// Days until the next review once the card is answered correctly.
    var interval: Int = 0
    /// Correct answers in a row; an Again resets it.
    var reps: Int = 0
    var lapses: Int = 0
    var due: Date
    var reviewed: Date?

    init(front: String, back: String, created: Date = Date()) {
        self.front = front
        self.back = back
        self.created = created
        self.due = created
    }

    var isNew: Bool { reviewed == nil }
    /// Seen at least once and answered correctly last time.
    var isLearned: Bool { !isNew && reps > 0 }
    var isMature: Bool { interval >= 21 }
}

struct Deck: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
}

struct Review: Codable, Hashable {
    var cardID: UUID
    var deckID: UUID
    var date: Date
    var grade: Grade
    var wasNew: Bool
}

struct Library: Codable, Equatable {
    var decks: [Deck] = []
    var reviews: [Review] = []
    static let reviewLimit = 20_000
}

// MARK: - Scheduler

/// SM-2 (Wozniak 1990) with four answer buttons, the way most flashcard apps adapt it.
enum Scheduler {
    static let startEase = 2.5
    static let minEase = 1.3
    static let maxInterval = 36_500
    /// An Again brings the card back in the same session after this many seconds.
    static let relearnDelay: TimeInterval = 60

    /// The interval in days a grade would give, or 0 for Again (shown again in minutes).
    static func interval(for card: Card, _ grade: Grade) -> Int {
        let last = card.interval
        let days: Int
        switch (card.reps, grade) {
        case (_, .again): return 0
        case (0, .hard), (0, .good): days = 1
        case (0, .easy): days = 4
        case (1, .hard): days = max(3, last + 1)
        case (1, .good): days = max(6, last + 1)
        case (1, .easy): days = max(8, Int((Double(max(6, last + 1)) * 1.3).rounded()))
        case (_, .hard): days = max(last + 1, Int((Double(last) * 1.2).rounded()))
        case (_, .good): days = max(last + 1, Int((Double(last) * card.ease).rounded()))
        case (_, .easy):
            let good = max(last + 1, Int((Double(last) * card.ease).rounded()))
            days = max(good + 1, Int((Double(last) * card.ease * 1.3).rounded()))
        }
        return min(days, maxInterval)
    }

    static func answer(_ card: Card, _ grade: Grade, now: Date, calendar: Calendar = .current) -> Card {
        var c = card
        switch grade {
        case .again:
            if c.reps > 0 { c.lapses += 1 }
            c.ease = max(minEase, c.ease - 0.2)
            c.reps = 0
            c.interval = 0
            c.due = now.addingTimeInterval(relearnDelay)
        case .hard, .good, .easy:
            c.interval = interval(for: card, grade)
            c.reps += 1
            let delta = grade == .hard ? -0.15 : grade == .easy ? 0.15 : 0
            c.ease = max(minEase, c.ease + delta)
            let start = calendar.startOfDay(for: now)
            c.due = calendar.date(byAdding: .day, value: c.interval, to: start) ?? now
        }
        c.reviewed = now
        return c
    }

    /// The short label on a grade button: "1m", "4d", "3w", "2mo", "1.5y".
    static func label(days: Int) -> String {
        switch days {
        case 0: return "1m"
        case 1..<14: return "\(days)d"
        case 14..<60: return "\(Int((Double(days) / 7).rounded()))w"
        case 60..<365: return "\(Int((Double(days) / 30).rounded()))mo"
        default:
            let years = (Double(days) / 365 * 10).rounded() / 10
            return years == years.rounded() ? "\(Int(years))y" : "\(years)y"
        }
    }
}

// MARK: - Study session

struct Session: Equatable {
    var deckID: UUID
    var queue: [UUID]
    var total: Int
    var revealed = false
    var tally: [Grade: Int] = [:]
    var started: Date
    var finished = false

    init(deckID: UUID, queue: [UUID], started: Date) {
        self.deckID = deckID
        self.queue = queue
        self.total = queue.count
        self.started = started
        self.finished = queue.isEmpty
    }

    var current: UUID? { queue.first }
    var answered: Int { tally.values.reduce(0, +) }
    /// Answers given over answers still needed; an Again adds one more to the end.
    var progress: Double { answered + queue.count == 0 ? 1 : Double(answered) / Double(answered + queue.count) }
    /// Share of answers that were not Again.
    var correct: Double? { answered == 0 ? nil : Double(answered - (tally[.again] ?? 0)) / Double(answered) }

    /// Records an answer for the current card; an Again puts it back a few cards later.
    mutating func record(_ grade: Grade) {
        guard let id = queue.first else { return }
        queue.removeFirst()
        tally[grade, default: 0] += 1
        if grade == .again { queue.insert(id, at: min(3, queue.count)) }
        revealed = false
        finished = queue.isEmpty
    }
}

// MARK: - Stats

struct DeckStats: Equatable {
    var total = 0
    var newCards = 0
    var dueReviews = 0
    var newToday = 0
    var learned = 0
    var mature = 0
    var retention: Double?
    var dueToday: Int { dueReviews + newToday }

    init() {}

    init(deck: Deck, reviews: [Review], newPerDay: Int, now: Date, calendar: Calendar = .current) {
        total = deck.cards.count
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        for card in deck.cards {
            if card.isNew { newCards += 1; continue }
            if card.due < endOfToday { dueReviews += 1 }
            if card.isLearned { learned += 1 }
            if card.isMature { mature += 1 }
        }
        let start = calendar.startOfDay(for: now)
        let mine = reviews.filter { $0.deckID == deck.id }
        let seenToday = mine.filter { $0.wasNew && $0.date >= start }.count
        newToday = min(newCards, max(0, newPerDay - seenToday))
        retention = Self.retention(mine, now: now)
    }

    /// Share of reviews of already seen cards in the last 30 days that were not Again.
    static func retention(_ reviews: [Review], now: Date) -> Double? {
        let since = now.addingTimeInterval(-30 * 86_400)
        let recent = reviews.filter { !$0.wasNew && $0.date >= since && $0.date <= now }
        guard !recent.isEmpty else { return nil }
        return Double(recent.filter { $0.grade != .again }.count) / Double(recent.count)
    }

    /// Cards due on each of the next `days` days; today includes everything overdue.
    static func forecast(_ deck: Deck, days: Int, now: Date, calendar: Calendar = .current) -> [Int] {
        var counts = [Int](repeating: 0, count: days)
        let start = calendar.startOfDay(for: now)
        for card in deck.cards where !card.isNew {
            let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: card.due)).day ?? 0
            if day < days { counts[max(0, day)] += 1 }
        }
        return counts
    }
}

enum Format {
    /// "New", "Overdue", "Today", "Tomorrow", "In 5 days", "In 3 months".
    static func due(_ card: Card, now: Date, calendar: Calendar = .current) -> String {
        if card.isNew { return "New" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: card.due)).day ?? 0
        switch days {
        case ..<0: return "Overdue"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2..<60: return "In \(days) days"
        case 60..<730: return "In \(days / 30) months"
        default: return "In \(days / 365) years"
        }
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "None yet" }
        return "\(Int((value * 100).rounded()))%"
    }

    /// Markdown-lite: **bold**, *italic*, `code` and [links]; line breaks kept.
    static func rich(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// One line of plain text for the table.
    static func plain(_ text: String) -> String {
        String(rich(text).characters)
            .split(whereSeparator: \.isNewline).joined(separator: " \u{00B7} ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - CSV

enum CSV {
    /// Tab for .tsv files or text whose first line has more tabs than commas, otherwise comma.
    static func delimiter(for text: String, pathExtension: String = "") -> Character {
        let ext = pathExtension.lowercased()
        if ext == "tsv" || ext == "tab" { return "\t" }
        let first = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let tabs = first.filter { $0 == "\t" }.count
        let commas = first.filter { $0 == "," }.count
        let semis = first.filter { $0 == ";" }.count
        if tabs > 0 && tabs >= commas { return "\t" }
        if semis > commas { return ";" }
        return ","
    }

    /// RFC 4180 rows: quoted fields may hold delimiters, line breaks and doubled quotes.
    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.hasPrefix("\u{FEFF}") ? Substring(text.dropFirst()) : Substring(text)
        func endRow() {
            row.append(field)
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
            field = ""
        }
        while let c = chars.first {
            chars.removeFirst()
            if quoted {
                if c == "\"" {
                    if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == delimiter {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                endRow()
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Front and back pairs, skipping a "front, back" style header and rows with an empty side.
    static func cards(from text: String, pathExtension: String = "") -> [(front: String, back: String)] {
        var rows = parse(text, delimiter: delimiter(for: text, pathExtension: pathExtension))
        if let head = rows.first, head.count >= 2 {
            let names = head.prefix(2).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let headers: Set<String> = ["front", "back", "question", "answer", "term", "definition"]
            if headers.contains(names[0]) && headers.contains(names[1]) { rows.removeFirst() }
        }
        return rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            let front = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let back = row[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return front.isEmpty || back.isEmpty ? nil : (front, back)
        }
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func export(_ cards: [Card]) -> String {
        (["front,back"] + cards.map { escape($0.front) + "," + escape($0.back) }).joined(separator: "\r\n") + "\r\n"
    }
}

// MARK: - Model

@MainActor
final class RecallModel: ObservableObject {
    @Published var library: Library { didSet { if library != oldValue { scheduleSave() } } }
    @Published var selection: UUID?
    @Published var session: Session?
    @Published var editing: CardDraft?
    @Published var renaming: Deck?
    @Published var deckToDelete: Deck?
    @Published var notice: Notice?
    @Published var now: Date

    weak var undoManager: UndoManager?
    private let persists: Bool
    private var saveWork: DispatchWorkItem?
    private var clock: Timer?

    struct CardDraft: Identifiable {
        var id = UUID()
        var cardID: UUID?
        var deckID: UUID
        var front = ""
        var back = ""
    }

    struct Notice: Identifiable {
        var id = UUID()
        var title: String
        var message: String
        var reveal: URL?
    }

    /// New cards introduced per deck per day.
    @Published var newPerDay: Int {
        didSet { if persists { UserDefaults.standard.set(newPerDay, forKey: "newPerDay") } }
    }
    @Published var selectedCards: Set<UUID> = []

    init(library: Library? = nil, persists: Bool = true, now: Date = Date()) {
        self.persists = persists
        self.now = now
        self.newPerDay = persists ? (UserDefaults.standard.object(forKey: "newPerDay") as? Int ?? 20) : 20
        self.library = library ?? (persists ? Storage.load(Library.self, app: "Recall", file: "library.json") : nil) ?? Library()
        selection = self.library.decks.first?.id
        guard persists else { return }
        Self.shared = self
        if !Self.pending.isEmpty {
            let urls = Self.pending
            Self.pending = []
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.importFiles(urls) } }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        // Keep "due" counts honest across midnight and relearning delays.
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.session == nil { self?.now = Date() } }
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        guard persists else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        guard persists else { return }
        saveWork?.cancel()
        Storage.save(library, app: "Recall", file: "library.json")
    }

    // MARK: Undo

    /// Applies a change and registers its undo (library and session together, so an answer can be taken back).
    func change(_ name: String, _ body: () -> Void) {
        let before = (library, session)
        body()
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring state: (Library, Session?)) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = (model.library, model.session)
                model.library = state.0
                model.session = state.1
                model.registerUndo(name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: Lookups

    var deck: Deck? { library.decks.first { $0.id == selection } }
    func deckIndex(_ id: UUID?) -> Int? { library.decks.firstIndex { $0.id == id } }
    func stats(_ deck: Deck) -> DeckStats { DeckStats(deck: deck, reviews: library.reviews, newPerDay: newPerDay, now: now) }
    var totalDue: Int { library.decks.reduce(0) { $0 + stats($1).dueToday } }

    func card(_ id: UUID?, in deckID: UUID) -> Card? {
        library.decks.first { $0.id == deckID }?.cards.first { $0.id == id }
    }

    // MARK: Decks

    func newDeck() {
        var name = "New Deck"
        var n = 2
        while library.decks.contains(where: { $0.name == name }) { name = "New Deck \(n)"; n += 1 }
        let deck = Deck(name: name)
        change("New Deck") { library.decks.append(deck) }
        selection = deck.id
        renaming = deck
    }

    func rename(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = deckIndex(id), !name.isEmpty, library.decks[i].name != name else { return }
        change("Rename Deck") { library.decks[i].name = name }
    }

    func deleteDeck(_ id: UUID) {
        guard let i = deckIndex(id) else { return }
        change("Delete Deck") {
            library.decks.remove(at: i)
            library.reviews.removeAll { $0.deckID == id }
            if session?.deckID == id { session = nil }
        }
        if selection == id { selection = library.decks[safe: min(i, library.decks.count - 1)]?.id }
    }

    // MARK: Cards

    func addCard() {
        guard let deck else { return }
        editing = CardDraft(deckID: deck.id)
    }

    func edit(_ cardID: UUID) {
        guard let deck, let card = deck.cards.first(where: { $0.id == cardID }) else { return }
        editing = CardDraft(cardID: card.id, deckID: deck.id, front: card.front, back: card.back)
    }

    /// Saves a draft: edits keep the card's schedule, new cards go to the end of the deck.
    func save(_ draft: CardDraft) {
        let front = draft.front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = draft.back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = deckIndex(draft.deckID), !front.isEmpty else { return }
        if let id = draft.cardID, let c = library.decks[d].cards.firstIndex(where: { $0.id == id }) {
            guard library.decks[d].cards[c].front != front || library.decks[d].cards[c].back != back else { return }
            change("Edit Card") {
                library.decks[d].cards[c].front = front
                library.decks[d].cards[c].back = back
            }
        } else {
            change("Add Card") { library.decks[d].cards.append(Card(front: front, back: back, created: Date())) }
            now = Date()
        }
    }

    func delete(_ ids: Set<UUID>) {
        guard let d = deckIndex(selection), !ids.isEmpty else { return }
        change(ids.count == 1 ? "Delete Card" : "Delete Cards") {
            library.decks[d].cards.removeAll { ids.contains($0.id) }
            if var s = session, s.deckID == library.decks[d].id {
                s.queue.removeAll { ids.contains($0) }
                s.finished = s.queue.isEmpty
                session = s
            }
        }
    }

    /// Forgets the schedule so the cards are new again.
    func reset(_ ids: Set<UUID>) {
        guard let d = deckIndex(selection), !ids.isEmpty else { return }
        change("Reset Progress") {
            for i in library.decks[d].cards.indices where ids.contains(library.decks[d].cards[i].id) {
                let c = library.decks[d].cards[i]
                var fresh = Card(front: c.front, back: c.back, created: c.created)
                fresh.id = c.id
                library.decks[d].cards[i] = fresh
            }
        }
    }

    // MARK: Studying

    static func queue(for deck: Deck, newAllowed: Int, now: Date, calendar: Calendar = .current) -> [UUID] {
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let due = deck.cards.filter { !$0.isNew && $0.due < endOfToday }.sorted { $0.due < $1.due }
        let fresh = deck.cards.filter(\.isNew).sorted { $0.created < $1.created }.prefix(max(0, newAllowed))
        // Mix new cards in among the reviews so a session does not end on a block of unknowns.
        var queue = due.map(\.id)
        for (n, card) in fresh.enumerated() {
            let at = min(queue.count, (n + 1) * 3 + n)
            queue.insert(card.id, at: at)
        }
        return queue
    }

    var canStudy: Bool { session == nil && deck.map { stats($0).dueToday > 0 } == true }

    func startStudy() {
        guard let deck, session == nil else { return }
        now = Date()
        let q = Self.queue(for: deck, newAllowed: stats(deck).newToday, now: now)
        guard !q.isEmpty else { return }
        session = Session(deckID: deck.id, queue: q, started: now)
    }

    func reveal() {
        guard var s = session, !s.finished, !s.revealed else { return }
        s.revealed = true
        withAnimation(.snappy(duration: 0.25)) { session = s }
    }

    func answer(_ grade: Grade) {
        guard var s = session, s.revealed, let id = s.current, let d = deckIndex(s.deckID),
              let c = library.decks[d].cards.firstIndex(where: { $0.id == id }) else { return }
        let date = Date()
        let card = library.decks[d].cards[c]
        change("Answer") {
            library.decks[d].cards[c] = Scheduler.answer(card, grade, now: date)
            library.reviews.append(Review(cardID: id, deckID: s.deckID, date: date, grade: grade, wasNew: card.isNew))
            if library.reviews.count > Library.reviewLimit { library.reviews.removeFirst(library.reviews.count - Library.reviewLimit) }
            s.record(grade)
            withAnimation(.snappy(duration: 0.25)) { session = s }
        }
    }

    func endSession() {
        session = nil
        now = Date()
        undoManager?.removeAllActions(withTarget: self)
    }

    // MARK: Import and export

    /// Files Finder asked us to open, kept until the model exists.
    private static var pending: [URL] = []
    private static weak var shared: RecallModel?

    static func receive(_ urls: [URL]) {
        if let shared { shared.importFiles(urls) } else { pending += urls }
    }

    func importFiles(_ urls: [URL]) {
        var lines: [String] = []
        var lastDeck: UUID?
        var total = 0
        for url in urls {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { lines.append("\(url.lastPathComponent) could not be read."); continue }
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
            let pairs = CSV.cards(from: text, pathExtension: url.pathExtension)
            guard !pairs.isEmpty else { lines.append("\(url.lastPathComponent) has no rows with a front and a back."); continue }
            let name = url.deletingPathExtension().lastPathComponent
            let base = Date()
            let cards = pairs.enumerated().map { Card(front: $1.front, back: $1.back, created: base.addingTimeInterval(Double($0) * 0.001)) }
            change("Import") {
                if let i = library.decks.firstIndex(where: { $0.name == name }) {
                    library.decks[i].cards += cards
                    lastDeck = library.decks[i].id
                } else {
                    let deck = Deck(name: name, cards: cards)
                    library.decks.append(deck)
                    lastDeck = deck.id
                }
            }
            total += cards.count
            lines.append("\(cards.count) cards into \u{201C}\(name)\u{201D}.")
        }
        now = Date()
        if let lastDeck, session == nil { selection = lastDeck }
        notice = Notice(title: total > 0 ? "Imported \(total) card\(total == 1 ? "" : "s")" : "Nothing to import",
                        message: lines.joined(separator: "\n") + (total > 0 ? "" : "\nEach row needs a front and a back, separated by a comma or a tab."))
    }

    func openImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose CSV or TSV files with the front in the first column and the back in the second."
        panel.prompt = "Import"
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func exportDeck() {
        guard let deck else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = deck.name + ".csv"
        panel.message = "Export \u{201C}\(deck.name)\u{201D} as CSV, front and back."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CSV.export(deck.cards).write(to: url, atomically: true, encoding: .utf8)
            notice = Notice(title: "Exported \(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")",
                            message: url.lastPathComponent, reveal: url)
        } catch {
            notice = Notice(title: "Could not export", message: error.localizedDescription)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
