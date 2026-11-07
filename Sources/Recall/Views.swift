import AppKit
import Charts
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 1.0, green: 0.784, blue: 0.239)      // 0xFFC83D
    static let bottom = Color(red: 0.898, green: 0.541, blue: 0.0)   // 0xE58A00
    static let deep = Color(red: 0.80, green: 0.45, blue: 0.0)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let pill = [Color(red: 0.97, green: 0.66, blue: 0.13), Color(red: 0.86, green: 0.48, blue: 0.0)]
    static let card = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: RecallModel
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            Group {
                if let session = model.session {
                    StudyView(model: model, session: session)
                } else if let deck = model.deck {
                    DeckView(model: model, deck: deck)
                } else {
                    EmptyLibrary(model: model, targeted: dropTargeted)
                }
            }
            .frame(minWidth: 540, minHeight: 440)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openImportPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import cards from a CSV or TSV file")
                    .disabled(model.session != nil)
                Button { model.exportDeck() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export this deck as CSV")
                    .disabled(model.deck == nil || model.session != nil)
                Button { model.addCard() } label: { Label("New Card", systemImage: "plus") }
                    .help("Add a card to this deck")
                    .disabled(model.deck == nil || model.session != nil)
                if model.session == nil {
                    Button { model.startStudy() } label: { Label("Study", systemImage: "play.fill") }
                        .help("Study the cards due today")
                        .disabled(!model.canStudy)
                } else {
                    Button { model.endSession() } label: { Label("End Session", systemImage: "xmark") }
                        .help("End this study session")
                }
            }
        }
        .navigationTitle("Recall")
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { ["csv", "tsv", "tab", "txt"].contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty, model.session == nil else { return false }
            model.importFiles(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .sheet(item: $model.editing) { draft in CardEditor(model: model, draft: draft) }
        .sheet(item: $model.renaming) { deck in RenameSheet(model: model, deck: deck) }
        .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
               presenting: model.notice) { notice in
            if let url = notice.reveal { Button("Reveal in Finder") { revealInFinder([url]) } }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmationDialog("Delete \u{201C}\(model.deckToDelete?.name ?? "")\u{201D}?",
                            isPresented: Binding(get: { model.deckToDelete != nil }, set: { if !$0 { model.deckToDelete = nil } }),
                            presenting: model.deckToDelete) { deck in
            Button("Delete Deck", role: .destructive) { model.deleteDeck(deck.id) }
        } message: { deck in
            Text("Its \(deck.cards.count) cards and their review history go too. You can undo this.")
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .onChange(of: model.selection) { _, id in
            model.selectedCards = []
            if let s = model.session, s.deckID != id { model.endSession() }
        }
    }

    private var subtitle: String {
        guard let deck = model.deck else { return "" }
        if let s = model.session, !s.finished { return "\(deck.name), \(s.queue.count) left" }
        return deck.name
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Decks") {
                ForEach(model.library.decks) { deck in
                    DeckRow(deck: deck, due: model.stats(deck).dueToday)
                        .tag(deck.id)
                        .contextMenu {
                            Button("Rename\u{2026}") { model.renaming = deck }
                            Button("Export as CSV\u{2026}") { model.selection = deck.id; model.exportDeck() }
                            Divider()
                            Button("Delete Deck\u{2026}", role: .destructive) { model.deckToDelete = deck }
                        }
                }
                .onMove { from, to in model.change("Move Deck") { model.library.decks.move(fromOffsets: from, toOffset: to) } }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    Button { model.newDeck() } label: { Image(systemName: "plus").font(.system(size: 13, weight: .medium)) }
                        .buttonStyle(.borderless)
                        .help("New deck")
                    Spacer()
                    let due = model.totalDue
                    Text(due == 0 ? "Nothing due" : "\(due) due today")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }
}

struct DeckRow: View {
    let deck: Deck
    let due: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 14))
                .foregroundStyle(Theme.gradient)
            VStack(alignment: .leading, spacing: 1) {
                Text(deck.name).lineLimit(1)
                Text("\(deck.cards.count) card\(deck.cards.count == 1 ? "" : "s")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if due > 0 {
                Text("\(due)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.gradient))
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Deck overview

struct DeckView: View {
    @ObservedObject var model: RecallModel
    let deck: Deck
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\CardRow.position)]

    var body: some View {
        let stats = model.stats(deck)
        VStack(spacing: 0) {
            header(stats)
            HStack(spacing: 12) {
                StatTile(title: "Due today", value: "\(stats.dueToday)",
                         detail: "\(stats.dueReviews) review\(stats.dueReviews == 1 ? "" : "s"), \(stats.newToday) new", symbol: "clock.fill")
                StatTile(title: "Learned", value: "\(stats.learned)",
                         detail: "of \(stats.total), \(stats.mature) mature", symbol: "brain.head.profile.fill")
                StatTile(title: "Retention", value: Format.percent(stats.retention),
                         detail: "last 30 days", symbol: "checkmark.seal.fill")
                ForecastTile(counts: DeckStats.forecast(deck, days: 14, now: model.now))
                    .frame(minWidth: 180)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            Divider()
            if deck.cards.isEmpty {
                ContentUnavailableView {
                    Label("No cards yet", systemImage: "rectangle.on.rectangle.angled")
                } description: {
                    Text("Add a card with \u{2318}N, or drop a CSV file with a front and a back column.")
                } actions: {
                    Button("New Card") { model.addCard() }.buttonStyle(.borderedProminent).tint(Theme.deep)
                    Button("Import\u{2026}") { model.openImportPanel() }
                }
                .frame(maxHeight: .infinity)
            } else {
                table
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search cards")
    }

    private func header(_ stats: DeckStats) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(deck.name).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(1)
                Text(stats.dueToday == 0
                     ? (deck.cards.isEmpty ? "An empty deck." : "All caught up. Come back tomorrow.")
                     : "\(stats.dueToday) card\(stats.dueToday == 1 ? "" : "s") waiting, about \(max(1, stats.dueToday * 8 / 60)) min.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.startStudy() } label: {
                Label("Study Now", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(Theme.pill))
            .disabled(stats.dueToday == 0)
            .opacity(stats.dueToday == 0 ? 0.5 : 1)
            .help("Study the cards due today (\u{2318}Return)")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    private var rows: [CardRow] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return deck.cards.enumerated().compactMap { i, card in
            let row = CardRow(card: card, position: i)
            if q.isEmpty || row.front.localizedCaseInsensitiveContains(q) || row.back.localizedCaseInsensitiveContains(q) { return row }
            return nil
        }.sorted(using: sortOrder)
    }

    private var table: some View {
        Table(rows, selection: $model.selectedCards, sortOrder: $sortOrder) {
            TableColumn("#", value: \.position) { Text("\($0.position + 1)").foregroundStyle(.tertiary).monospacedDigit() }
                .width(34)
            TableColumn("Front", value: \.front) { Text($0.front).lineLimit(1) }
                .width(min: 120, ideal: 200)
            TableColumn("Back", value: \.back) { Text($0.back).lineLimit(1).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 220)
            TableColumn("Due", value: \.dueSort) { row in
                let label = Format.due(row.card, now: model.now)
                Text(label).foregroundStyle(label == "Today" || label == "Overdue" ? AnyShapeStyle(Theme.deep) : AnyShapeStyle(.secondary))
            }
            .width(min: 70, ideal: 84)
            TableColumn("Interval", value: \.card.interval) { row in
                Text(row.card.isNew || row.card.interval == 0 ? "" : Scheduler.label(days: row.card.interval)).monospacedDigit()
            }
            .width(min: 50, ideal: 58)
            TableColumn("Ease", value: \.card.ease) { row in
                Text(row.card.isNew ? "" : "\(Int((row.card.ease * 100).rounded()))%").monospacedDigit()
            }
            .width(min: 44, ideal: 50)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first { Button("Edit Card\u{2026}") { model.edit(id) } }
            if !ids.isEmpty {
                Button("Reset Progress") { model.reset(ids) }
                Divider()
                Button(ids.count == 1 ? "Delete Card" : "Delete \(ids.count) Cards", role: .destructive) { model.delete(ids) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.edit(id) }
        }
        .onDeleteCommand { model.delete(model.selectedCards) }
        .overlay {
            if rows.isEmpty { ContentUnavailableView.search(text: search) }
        }
    }
}

struct CardRow: Identifiable {
    let card: Card
    let position: Int
    let front: String
    let back: String
    var id: UUID { card.id }
    /// New cards sort after everything scheduled.
    var dueSort: Date { card.isNew ? .distantFuture.addingTimeInterval(card.created.timeIntervalSinceReferenceDate) : card.due }

    init(card: Card, position: Int) {
        self.card = card
        self.position = position
        front = Format.plain(card.front)
        back = Format.plain(card.back)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel())
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Theme.gradient)
            configuration.title
        }
    }
}

struct ForecastTile: View {
    let counts: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next 14 days", systemImage: "chart.bar.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel())
            Chart(Array(counts.enumerated()), id: \.offset) { day, count in
                BarMark(x: .value("Day", String(day)), y: .value("Cards", count), width: .ratio(0.68))
                    .foregroundStyle(day == 0 ? Theme.bottom : Theme.top.opacity(0.7))
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel().font(.system(size: 9))
                }
            }
            .frame(height: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

// MARK: - Studying

struct StudyView: View {
    @ObservedObject var model: RecallModel
    let session: Session
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if session.finished {
                SessionSummary(model: model, session: session)
            } else {
                progressBar
                Spacer(minLength: 16)
                if let card = model.card(session.current, in: session.deckID) {
                    CardFace(card: card, revealed: session.revealed)
                        .id(card.id)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .leading).combined(with: .opacity)))
                        .padding(.horizontal, 32)
                    Spacer(minLength: 16)
                    controls(card)
                        .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.space) {
            guard !session.finished else { return .ignored }
            model.reveal()
            return .handled
        }
        .onKeyPress(.return) {
            if session.finished { model.endSession(); return .handled }
            model.reveal()
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard session.revealed, let n = Int(press.characters), let grade = Grade(rawValue: n) else { return .ignored }
            model.answer(grade)
            return .handled
        }
        .onKeyPress(.escape) {
            model.endSession()
            return .handled
        }
    }

    private var progressBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach(Grade.allCases) { g in
                    HStack(spacing: 4) {
                        Circle().fill(g.color).frame(width: 7, height: 7)
                        Text("\(session.tally[g] ?? 0)").monospacedDigit().contentTransition(.numericText())
                    }
                    .help(g.title)
                }
                Spacer()
                Text("\(session.answered) done, \(session.queue.count) left")
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule().fill(Theme.gradient).frame(width: max(6, geo.size.width * session.progress))
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
    }

    @ViewBuilder
    private func controls(_ card: Card) -> some View {
        if session.revealed {
            HStack(spacing: 10) {
                ForEach(Grade.allCases) { g in
                    GradeButton(grade: g, label: Scheduler.label(days: Scheduler.interval(for: card, g))) { model.answer(g) }
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 32)
        } else {
            Button { model.reveal() } label: {
                HStack(spacing: 8) {
                    Text("Show Answer")
                    Text("Space")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.25)))
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(PillButtonStyle(Theme.pill))
            .frame(height: 64)
        }
    }
}

struct CardFace: View {
    let card: Card
    let revealed: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(Format.rich(card.front))
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, revealed ? 26 : 0)
            if revealed {
                Divider().padding(.horizontal, 40)
                Text(Format.rich(card.back))
                    .font(.system(size: 21))
                    .foregroundStyle(.primary.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 36)
        .padding(.vertical, 20)
        .frame(maxWidth: 660, minHeight: 300)
        .background {
            ZStack {
                // A second card peeking out behind, so it reads as a deck.
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                    .rotationEffect(.degrees(-2.2))
                    .offset(x: -6, y: 8)
                    .opacity(0.9)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.8), lineWidth: 0.5)
                VStack {
                    Capsule().fill(Theme.gradient).frame(width: 46, height: 4).padding(.top, 12)
                    Spacer()
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: revealed)
    }
}

struct GradeButton: View {
    let grade: Grade
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(grade.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text("\(grade.rawValue)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.7)))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(grade.color.opacity(hovering ? 0.22 : 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(grade.color.opacity(0.45), lineWidth: 1))
            .foregroundStyle(grade.color)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("\(grade.title), next review in \(label) (\(grade.rawValue))")
    }
}

struct SessionSummary: View {
    @ObservedObject var model: RecallModel
    let session: Session

    var body: some View {
        let minutes = max(1, Int((Date().timeIntervalSince(session.started) / 60).rounded()))
        let next = model.library.decks.first { $0.id == session.deckID }.map { DeckStats.forecast($0, days: 2, now: Date())[1] } ?? 0
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 58))
                .foregroundStyle(Theme.gradient)
                .symbolEffect(.bounce, value: session.finished)
            VStack(spacing: 4) {
                Text("Session complete").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("\(session.answered) answers in \(minutes) min, \(Format.percent(session.correct)) correct.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ForEach(Grade.allCases) { g in
                    VStack(spacing: 2) {
                        Text("\(session.tally[g] ?? 0)").font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(g.color)
                        Text(g.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    .frame(width: 76)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(g.color.opacity(0.1)))
                }
            }
            Text(next == 0 ? "Nothing scheduled for tomorrow yet." : "\(next) card\(next == 1 ? "" : "s") due tomorrow.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Done") { model.endSession() }
                .buttonStyle(PillButtonStyle(Theme.pill))
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty state

struct EmptyLibrary: View {
    @ObservedObject var model: RecallModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            DropZone(symbol: "rectangle.on.rectangle.angled", title: "No decks yet",
                     message: "Create a deck, or drop a CSV or TSV file with a front and a back column to import one.",
                     button: "New Deck", tint: Theme.deep, isTargeted: targeted) { model.newDeck() }
        }
    }
}

// MARK: - Sheets

struct CardEditor: View {
    @ObservedObject var model: RecallModel
    @State var draft: RecallModel.CardDraft
    @State private var added = 0
    @FocusState private var field: Field?
    @Environment(\.dismiss) private var dismiss

    enum Field { case front, back }

    private var isNew: Bool { draft.cardID == nil }
    private var canSave: Bool { !draft.front.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !draft.back.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(isNew ? "New Card" : "Edit Card").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if added > 0 {
                    Text("\(added) added").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            editor("Front", text: $draft.front, field: .front)
            editor("Back", text: $draft.back, field: .back)
            Text("Use **bold**, *italic* and `code`. \u{2318}Return saves.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(isNew ? "Done" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Card" : "Save") {
                    model.save(draft)
                    if isNew {
                        added += 1
                        draft.front = ""
                        draft.back = ""
                        field = .front
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(Theme.deep)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { field = .front }
    }

    private func editor(_ title: String, text: Binding<String>, field f: Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 78)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(field == f ? AnyShapeStyle(Theme.deep.opacity(0.7)) : AnyShapeStyle(.quaternary), lineWidth: 1))
                .focused($field, equals: f)
        }
    }
}

struct RenameSheet: View {
    @ObservedObject var model: RecallModel
    let deck: Deck
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deck Name").font(.system(size: 15, weight: .semibold, design: .rounded))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear { name = deck.name }
    }

    private func save() {
        model.rename(deck.id, to: name)
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject var model: RecallModel

    var body: some View {
        Form {
            Section {
                Stepper(value: $model.newPerDay, in: 0...500, step: 5) {
                    LabeledContent("New cards per day", value: "\(model.newPerDay)")
                }
            } footer: {
                Text("How many unseen cards each deck introduces a day. Reviews are never capped.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
