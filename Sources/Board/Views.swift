import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(red: 0x2E / 255, green: 0x9B / 255, blue: 0xFF / 255)
    static let bottom = Color(red: 0x16 / 255, green: 0x58 / 255, blue: 0xC7 / 255)
    static let blue = Color(red: 0x22 / 255, green: 0x7A / 255, blue: 0xE6 / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let columnWidth: CGFloat = 256
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var store: BoardStore
    @Environment(\.undoManager) private var undoManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } detail: {
            detail
        }
        .tint(Theme.blue)
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { store.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in store.undoManager = value }
        .onChange(of: store.searchRequest) { _, _ in searchFocused = true }
        .sheet(isPresented: $store.showArchive) { ArchiveSheet(store: store) }
    }

    @ViewBuilder private var detail: some View {
        if let board = store.current {
            BoardView(store: store, board: board)
                .navigationTitle(board.name)
                .navigationSubtitle(subtitle(board))
                .searchable(text: $store.search, placement: .toolbar, prompt: "Search cards")
                .modifier(SearchFocus(focused: $searchFocused))
                .toolbar { BoardToolbar(store: store, board: board) }
        } else {
            ContentUnavailableView {
                Label("No Boards", systemImage: "rectangle.split.3x1")
            } description: {
                Text("Make a board for a project, then add cards to its columns.")
            } actions: {
                Button("New Board") { store.addBoard() }.buttonStyle(.borderedProminent)
            }
            .navigationTitle("Board")
        }
    }

    private func subtitle(_ board: Board) -> String {
        let n = board.cardCount
        return n == 1 ? "1 card" : "\(n) cards"
    }
}

/// `searchFocused` arrived in macOS 15; on 14 the search field is still one click away.
struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) { content.searchFocused(focused) } else { content }
    }
}

struct BoardToolbar: ToolbarContent {
    @ObservedObject var store: BoardStore
    let board: Board

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.addColumn(in: board.id) } label: { Label("New Column", systemImage: "rectangle.stack.badge.plus") }
                .help("Add a column (⌥⌘N)")
            Button { store.change("Archive Cards", board: board.id) { $0.archiveDone() } } label: {
                Label("Archive Done", systemImage: "archivebox")
            }
            .help("Archive every card in “\(board.columns.last?.name ?? "Done")” (⌥⌘A)")
            .disabled(board.columns.last?.cards.isEmpty ?? true)
            Button { store.showArchive = true } label: { Label("Show Archive", systemImage: "tray.full") }
                .help("Show archived cards (⇧⌘A)")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var store: BoardStore
    @State private var renameText = ""
    private var confirmDelete: Board? { store.boards.first { $0.id == store.confirmingDeleteBoard } }

    var body: some View {
        List(selection: $store.selection) {
            Section("Boards") {
                ForEach(store.boards) { board in
                    Label(board.name, systemImage: "rectangle.split.3x1")
                        .badge(board.cardCount)
                        .tag(board.id)
                        .contextMenu {
                            Button("Rename…") { store.renamingBoard = board.id }
                            Button("Delete Board…", role: .destructive) { store.confirmingDeleteBoard = board.id }
                        }
                }
                .onMove { store.moveBoards(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button { store.addBoard() } label: {
                Label("New Board", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .help("Make a new board (⇧⌘N)")
        }
        .alert("Rename Board", isPresented: Binding(get: { store.renamingBoard != nil }, set: { if !$0 { store.renamingBoard = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let id = store.renamingBoard { store.renameBoard(id, to: renameText) }
                store.renamingBoard = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { store.renamingBoard = nil }
        }
        .onChange(of: store.renamingBoard) { _, id in
            renameText = store.boards.first { $0.id == id }?.name ?? ""
        }
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { store.confirmingDeleteBoard = nil } })) {
            Button("Delete Board", role: .destructive) {
                if let board = confirmDelete { store.deleteBoard(board.id) }
                store.confirmingDeleteBoard = nil
            }
        } message: {
            Text("Its columns and cards go with it. You can undo this.")
        }
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var store: BoardStore
    let board: Board

    var body: some View {
        if board.columns.isEmpty {
            ContentUnavailableView {
                Label("No Columns", systemImage: "rectangle.split.3x1")
            } description: {
                Text("Add a column to start putting cards on this board.")
            } actions: {
                Button("New Column") { store.addColumn(in: board.id) }.buttonStyle(.borderedProminent)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(board.columns) { column in
                            ColumnView(store: store, board: board, column: column).id(column.id)
                        }
                        AddColumnTile { store.addColumn(in: board.id) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .onChange(of: store.renamingColumn) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .trailing) } }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

struct AddColumnTile: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.blue) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(hovering ? AnyShapeStyle(Theme.blue.opacity(0.6)) : AnyShapeStyle(.quaternary))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Add a column (⌥⌘N)")
        .accessibilityLabel("Add Column")
    }
}

// MARK: - Column

struct ColumnView: View {
    @ObservedObject var store: BoardStore
    let board: Board
    let column: Column
    @State private var name = ""
    @State private var draft = ""
    @State private var dropTargeted = false
    @State private var confirmDelete = false
    @FocusState private var nameFocused: Bool
    @FocusState private var draftFocused: Bool

    private var visible: [Card] { column.cards.filter { Search.matches($0, store.search) } }
    private var index: Int { board.columnIndex(column.id) ?? 0 }
    private var isLast: Bool { index == board.columns.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(visible) { card in
                        CardView(store: store, board: board, column: column, card: card)
                    }
                    if visible.isEmpty { emptyCards }
                    quickAdd
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .padding(.top, 2)
            }
            .scrollIndicators(.never)
        }
        .frame(width: Theme.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.blue.opacity(dropTargeted ? 0.7 : 0), lineWidth: 2)
        }
        .onDrop(of: [.text], delegate: ColumnDropDelegate(store: store, board: board.id, column: column.id, index: index, targeted: $dropTargeted))
        .animation(.snappy(duration: 0.2), value: dropTargeted)
        .confirmationDialog("Delete “\(column.name)”?", isPresented: $confirmDelete) {
            Button("Delete Column", role: .destructive) { deleteColumn() }
        } message: {
            Text(column.cards.count == 1 ? "Its card goes with it. You can undo this." : "Its \(column.cards.count) cards go with it. You can undo this.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if store.renamingColumn == column.id {
                TextField("Column name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .focused($nameFocused)
                    .onSubmit(commitName)
                    .onExitCommand { store.renamingColumn = nil }
                    .onAppear {
                        name = column.name
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName() } }
            } else {
                Text(column.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { store.renamingColumn = column.id }
                Text("\(visible.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            Menu {
                Button("Rename Column") { store.renamingColumn = column.id }
                Button("Add Card") { openQuickAdd() }
                Divider()
                Button("Move Left") { store.change("Move Column", board: board.id) { $0.moveColumn(column.id, by: -1) } }
                    .disabled(index == 0)
                Button("Move Right") { store.change("Move Column", board: board.id) { $0.moveColumn(column.id, by: 1) } }
                    .disabled(isLast)
                if isLast {
                    Divider()
                    Button("Archive All Cards") { store.change("Archive Cards", board: board.id) { $0.archiveDone() } }
                        .disabled(column.cards.isEmpty)
                }
                Divider()
                Button("Delete Column…", role: .destructive) {
                    if column.cards.isEmpty { deleteColumn() } else { confirmDelete = true }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
            .help("Column actions")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .contentShape(Rectangle())
        .onDrag { store.beginDrag(.column(column.id), text: column.name) }
    }

    private func commitName() {
        guard store.renamingColumn == column.id else { return }
        store.change("Rename Column", board: board.id) { $0.renameColumn(column.id, to: name) }
        store.renamingColumn = nil
    }

    private func deleteColumn() {
        store.change("Delete Column", board: board.id) { $0.deleteColumn(column.id) }
    }

    // MARK: Empty and quick add

    @ViewBuilder private var emptyCards: some View {
        Text(store.search.isEmpty ? "Drop cards here" : "No matches")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.quaternary)
            }
    }

    @ViewBuilder private var quickAdd: some View {
        if store.quickAdd == column.id {
            TextField("Card title", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($draftFocused)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.blue.opacity(0.8), lineWidth: 1.5))
                .onSubmit(submitDraft)
                .onExitCommand { draft = ""; closeQuickAdd() }
                .onAppear { DispatchQueue.main.async { draftFocused = true } }
                .onChange(of: draftFocused) { _, focused in if !focused { closeQuickAdd() } }
        } else {
            QuickAddButton { openQuickAdd() }
        }
    }

    private func openQuickAdd() {
        store.search = ""
        draft = ""
        store.quickAdd = column.id
    }

    private func submitDraft() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { closeQuickAdd(); return }
        store.addCard(title, to: column.id, in: board.id)
        draft = ""
        DispatchQueue.main.async { draftFocused = true }
    }

    private func closeQuickAdd() {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { store.addCard(title, to: column.id, in: board.id) }
        draft = ""
        if store.quickAdd == column.id { store.quickAdd = nil }
    }
}

struct QuickAddButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Add a card", systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(Theme.blue) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Card

struct CardView: View {
    @ObservedObject var store: BoardStore
    let board: Board
    let column: Column
    let card: Card
    @State private var hovering = false
    @State private var showDetail = false
    @State private var height: CGFloat = 60
    @State private var dropEdge: VerticalEdge?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let color = card.label.color {
                Capsule().fill(color).frame(width: 34, height: 5)
            }
            Text(card.title.isEmpty ? "Untitled" : card.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(card.title.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if !card.notes.isEmpty {
                Text(card.notes)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let due = card.due { DueBadge(due: due) }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.cardBackground)
                .shadow(color: .black.opacity(hovering ? 0.14 : 0.07), radius: hovering ? 5 : 1.5, y: hovering ? 2 : 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(showDetail ? Theme.blue : Color.primary.opacity(0.08), lineWidth: showDetail ? 1.5 : 0.5)
        }
        .overlay(alignment: dropEdge == .bottom ? .bottom : .top) {
            if dropEdge != nil {
                Capsule().fill(Theme.blue).frame(height: 3).offset(y: dropEdge == .bottom ? 5.5 : -5.5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { showDetail = true }
        .popover(isPresented: $showDetail, arrowEdge: .trailing) {
            CardDetail(store: store, board: board.id, cardID: card.id) { showDetail = false }
        }
        .contextMenu { menu }
        .background(GeometryReader { geo in Color.clear.onAppear { height = geo.size.height }.onChange(of: geo.size.height) { _, h in height = h } })
        .onDrag { store.beginDrag(.card(card.id), text: card.title) }
        .onDrop(of: [.text], delegate: CardDropDelegate(store: store, board: board.id, column: column.id,
                                                        card: card.id, columnIndex: board.columnIndex(column.id) ?? 0,
                                                        height: height, edge: $dropEdge))
        .help(card.title)
    }

    @ViewBuilder private var menu: some View {
        Button("Open Card") { showDetail = true }
        Menu("Move To") {
            ForEach(board.columns) { target in
                Button(target.name) { store.moveCard(card.id, in: board.id, to: target.id, near: nil) }
                    .disabled(target.id == column.id)
            }
        }
        Menu("Label") {
            ForEach(CardLabel.allCases) { label in
                Toggle(label.name, isOn: Binding(get: { card.label == label }, set: { _ in
                    store.change("Change Label", board: board.id) { $0.updateCard(card.id) { $0.label = label } }
                }))
            }
        }
        Divider()
        Button("Archive Card") { store.change("Archive Card", board: board.id) { $0.archiveCard(card.id) } }
        Button("Delete Card", role: .destructive) { store.change("Delete Card", board: board.id) { $0.deleteCard(card.id) } }
    }
}

struct DueBadge: View {
    let due: Date

    var body: some View {
        let status = DueStatus.of(due)
        HStack(spacing: 4) {
            Image(systemName: status == .overdue ? "exclamationmark.circle.fill" : "calendar")
            Text(DueStatus.text(due))
        }
        .font(.system(size: 11, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(status == .later ? AnyShapeStyle(.secondary) : AnyShapeStyle(status.color))
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(status == .later ? Color.primary.opacity(0.06) : status.color.opacity(0.13)))
    }
}

// MARK: - Card detail

struct CardDetail: View {
    @ObservedObject var store: BoardStore
    let board: UUID
    let cardID: UUID
    let close: () -> Void
    @State private var snapshot: [Board]?
    @State private var committed = false

    private var card: Card? { store.card(cardID, in: board) }
    private var columns: [Column] { store.boards.first { $0.id == board }?.columns ?? [] }

    var body: some View {
        if let card {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Title", text: field(\.title), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1...4)

                TextField("Add notes", text: field(\.notes), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(3...10)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Label").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        ForEach(CardLabel.allCases) { label in
                            LabelSwatch(label: label, selected: card.label == label) {
                                store.edit(board: board) { $0.updateCard(cardID) { $0.label = label } }
                            }
                        }
                    }
                }

                HStack {
                    Toggle("Due date", isOn: Binding(get: { card.due != nil }, set: { on in
                        store.edit(board: board) { $0.updateCard(cardID) { $0.due = on ? Demo.day(1) : nil } }
                    }))
                    .toggleStyle(.checkbox)
                    Spacer()
                    if card.due != nil {
                        DatePicker("Due", selection: Binding(get: { card.due ?? Date() }, set: { d in
                            store.edit(board: board) { $0.updateCard(cardID) { $0.due = Calendar.current.startOfDay(for: d) } }
                        }), displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Menu("Move To") {
                        ForEach(columns) { column in
                            Button(column.name) { act("Move Card") { $0.moveCard(cardID, to: column.id, near: nil) } }
                                .disabled(column.cards.contains { $0.id == cardID })
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button { act("Archive Card") { $0.archiveCard(cardID) } } label: { Image(systemName: "archivebox") }
                        .help("Archive this card")
                    Button(role: .destructive) { act("Delete Card") { $0.deleteCard(cardID) } } label: { Image(systemName: "trash") }
                        .help("Delete this card")
                }
                .controlSize(.small)
            }
            .padding(16)
            .frame(width: 330)
            .onAppear { snapshot = store.boards }
            .onDisappear(perform: commit)
        }
    }

    private func field(_ key: WritableKeyPath<Card, String>) -> Binding<String> {
        Binding(get: { card?[keyPath: key] ?? "" }, set: { value in
            store.edit(board: board) { $0.updateCard(cardID) { $0[keyPath: key] = value } }
        })
    }

    private func commit() {
        guard !committed, let snapshot else { return }
        committed = true
        store.commitEdit(since: snapshot)
    }

    /// Commits the edits so far as their own undo step, then performs an undoable action and closes.
    private func act(_ action: String, _ body: @escaping (inout Board) -> Void) {
        commit()
        close()
        DispatchQueue.main.async { store.change(action, board: board, body) }
    }
}

struct LabelSwatch: View {
    let label: CardLabel
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = label.color {
                    Circle().fill(color)
                } else {
                    Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                    Image(systemName: "line.diagonal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                if selected && label.color != nil {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                }
            }
            .frame(width: 22, height: 22)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Theme.blue : .clear, lineWidth: 2))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label.name)
    }
}

// MARK: - Archive

struct ArchiveSheet: View {
    @ObservedObject var store: BoardStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let board = store.current
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Archive").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(board?.name ?? "").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()
            if let board, !board.archived.isEmpty {
                List {
                    ForEach(board.archived) { card in
                        HStack(spacing: 10) {
                            Circle().fill(card.label.color ?? Color.secondary.opacity(0.3)).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(card.title.isEmpty ? "Untitled" : card.title).lineLimit(1)
                                if !card.notes.isEmpty {
                                    Text(card.notes).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Button("Restore") { store.change("Restore Card", board: board.id) { $0.restore(card.id) } }
                                .help("Put it back in “\(board.columns.last?.name ?? "")”")
                                .disabled(board.columns.isEmpty)
                            Button { store.change("Delete Card", board: board.id) { $0.deleteCard(card.id) } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete for good")
                        }
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView("Nothing Archived", systemImage: "archivebox",
                                       description: Text("Archive finished cards to clear the last column."))
            }
            Divider()
            HStack {
                if let board, !board.archived.isEmpty {
                    Button("Delete All", role: .destructive) {
                        store.change("Delete Archived Cards", board: board.id) { $0.archived = [] }
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 440, height: 420)
    }
}

// MARK: - Drag and drop

/// A drop on a card puts the dragged card above or below it, depending on which half the pointer is over.
struct CardDropDelegate: DropDelegate {
    let store: BoardStore
    let board: UUID
    let column: UUID
    let card: UUID
    let columnIndex: Int
    let height: CGFloat
    @Binding var edge: VerticalEdge?

    func validateDrop(info: DropInfo) -> Bool { store.draggingCard != nil || store.draggingColumn != nil }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let dragged = store.draggingCard, dragged != card {
            edge = info.location.y < height / 2 ? .top : .bottom
        } else {
            edge = nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { edge = nil }

    func performDrop(info: DropInfo) -> Bool {
        let after = edge == .bottom
        edge = nil
        let (store, board, column, card, columnIndex) = (store, board, column, card, columnIndex)
        return store.acceptDrop(info.itemProviders(for: [.text])) { drag in
            switch drag {
            case .card(let dragged): store.moveCard(dragged, in: board, to: column, near: card, after: after)
            case .column(let dragged): store.change("Move Column", board: board) { $0.moveColumn(dragged, to: columnIndex) }
            }
        }
    }
}

/// A drop on a column's empty space puts a card at its end, or moves a dragged column to this position.
struct ColumnDropDelegate: DropDelegate {
    let store: BoardStore
    let board: UUID
    let column: UUID
    let index: Int
    @Binding var targeted: Bool

    func validateDrop(info: DropInfo) -> Bool { store.draggingCard != nil || store.draggingColumn != nil }

    func dropEntered(info: DropInfo) { targeted = store.draggingColumn != column }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        let (store, board, column, index) = (store, board, column, index)
        return store.acceptDrop(info.itemProviders(for: [.text])) { drag in
            switch drag {
            case .card(let dragged): store.moveCard(dragged, in: board, to: column, near: nil)
            case .column(let dragged): store.change("Move Column", board: board) { $0.moveColumn(dragged, to: index) }
            }
        }
    }
}
