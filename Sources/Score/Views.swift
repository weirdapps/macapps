import AppKit
import Kit
import SwiftUI

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: ScoreModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 320)
        } detail: {
            detail
                .navigationTitle(model.current?.name ?? "Score")
                .navigationSubtitle(model.current?.rulesText ?? "")
        }
        .toolbar { toolbar }
        .sheet(item: $model.draft) { draft in
            NewGameSheet(draft: draft, onCancel: { model.draft = nil }, onStart: { game in
                model.draft = nil
                model.start(game)
            })
        }
        .frame(minWidth: 780, minHeight: 500)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }

    @ViewBuilder private var detail: some View {
        if let game = model.current {
            if model.showTotals {
                BigTotalsView(model: model, game: game)
            } else {
                GameView(model: model, game: game)
            }
        } else if model.games.isEmpty {
            ContentUnavailableView {
                Label("No Games Yet", systemImage: "trophy")
            } description: {
                Text("Start a game, add the players, and Score keeps the totals round by round.")
            } actions: {
                Button("New Game") { model.newGame() }.buttonStyle(.borderedProminent).tint(Theme.blue).controlSize(.large)
            }
        } else {
            ContentUnavailableView("No Game Selected", systemImage: "list.number",
                                   description: Text("Pick a game in the sidebar, or start a new one."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.showTotals) {
                Label("Score Table", systemImage: "tablecells").tag(false)
                Label("Big Totals", systemImage: "square.grid.2x2").tag(true)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Switch between the score table and big totals for the table")
            .disabled(model.current == nil)

            Button { model.addRound() } label: { Label("New Round", systemImage: "plus.rectangle.on.rectangle") }
                .help("Add a round (⌘R)")
                .disabled(model.current == nil)
            Button { model.rematch() } label: { Label("Rematch", systemImage: "arrow.triangle.2.circlepath") }
                .help("New game with the same players (⇧⌘N)")
                .disabled(model.current == nil)
            Button { model.newGame() } label: { Label("New Game", systemImage: "plus") }
                .help("Start a new game (⌘N)")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: ScoreModel

    var body: some View {
        List(selection: $model.selection) {
            if !model.inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(model.inProgress) { GameRow(game: $0).tag($0.id) }
                }
            }
            if !model.history.isEmpty {
                Section("History") {
                    ForEach(model.history) { GameRow(game: $0).tag($0.id) }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1 {
                Button("Rematch") {
                    model.selection = ids.first
                    model.rematch()
                }
            }
            Button(ids.count > 1 ? "Delete Games" : "Delete Game", role: .destructive) { model.delete(ids) }
        }
        .onDeleteCommand { if let id = model.selection { model.delete([id]) } }
        .overlay {
            if model.games.isEmpty {
                Text("Your games appear here").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

struct GameRow: View {
    let game: Game

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(game.isOver ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(LinearGradient(colors: Theme.accent, startPoint: .top, endPoint: .bottom)))
                Image(systemName: game.isOver ? "crown.fill" : "list.number")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(game.sidebarSubtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            PlayerDots(players: game.players)
        }
        .padding(.vertical, 3)
    }
}

struct PlayerDots: View {
    let players: [Player]

    var body: some View {
        HStack(spacing: -4) {
            ForEach(players.prefix(5)) { p in
                Circle().fill(PlayerColor.color(p.color))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
            }
        }
    }
}

// MARK: - Game

struct GameView: View {
    @ObservedObject var model: ScoreModel
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if game.isOver { WinnerBanner(model: model, game: game) }
            PlayerStrip(model: model, game: game)
            ScoreTable(model: model, game: game)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct WinnerBanner: View {
    @ObservedObject var model: ScoreModel
    let game: Game

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "crown.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.goldGradient))
                .shadow(color: Theme.gold.opacity(0.4), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(game.resultText ?? "Game over").font(.system(size: 17, weight: .bold, design: .rounded))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !game.endedByTarget {
                Button("Resume") { model.toggleEnded() }.controlSize(.large)
            }
            Button { model.rematch() } label: { Label("Rematch", systemImage: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderedProminent).tint(Theme.blue).controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gold.opacity(0.13)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.gold.opacity(0.45)))
    }

    private var detail: String {
        let best = game.leaders.first.map { game.total($0) }
        var parts: [String] = []
        if let best { parts.append("\(best) points") }
        parts.append(game.rounds.count == 1 ? "1 round" : "\(game.rounds.count) rounds")
        if let ended = game.ended { parts.append(ended.formatted(date: .abbreviated, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Player cards

struct PlayerStrip: View {
    @ObservedObject var model: ScoreModel
    let game: Game

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { cards(width: nil) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { cards(width: 150) }.padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private func cards(width: CGFloat?) -> some View {
        ForEach(Array(game.players.enumerated()), id: \.element.id) { i, player in
            PlayerCard(model: model, game: game, index: i)
                .frame(minWidth: width ?? 128, maxWidth: width ?? .infinity)
                .frame(width: width)
        }
    }
}

struct PlayerCard: View {
    @ObservedObject var model: ScoreModel
    let game: Game
    let index: Int

    private var player: Player { game.players[index] }
    private var leads: Bool { game.leaders.contains(index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ColorMenu(color: player.color) { c in model.update(game.id, "Change Colour") { $0.players[index].color = c } }
                NameField(name: player.name) { name in model.update(game.id, "Rename Player") { $0.players[index].name = name } }
                Spacer(minLength: 0)
                if leads {
                    Image(systemName: "crown.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.goldGradient)
                        .transition(.scale.combined(with: .opacity))
                        .help(game.isOver ? "Winner" : "In the lead")
                }
            }
            Text("\(game.total(index))")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(game.total(index))))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 6) {
                QuickButton(label: "\u{2212}1", help: "Take 1 point off this round") { add(-1) }
                QuickButton(label: "+1", help: "Add 1 point to this round") { add(1) }
                QuickButton(label: "+5", help: "Add 5 points to this round") { add(5) }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(leads ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.quaternary), lineWidth: leads ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
        .animation(.snappy, value: game.totals)
    }

    private func add(_ n: Int) {
        withAnimation(.snappy) { model.update(game.id, n < 0 ? "Remove Point" : "Add Points") { $0.add(n, player: index) } }
    }
}

struct QuickButton: View {
    let label: String
    let help: String
    var large = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: large ? 20 : 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .frame(height: large ? 44 : 24)
                .background(RoundedRectangle(cornerRadius: large ? 11 : 7, style: .continuous)
                    .fill(Theme.blue.opacity(hovering ? 0.2 : 0.1)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.blue)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A colour swatch that opens a menu of player colours.
struct ColorMenu: View {
    let color: Int
    let pick: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(PlayerColor.all.indices, id: \.self) { i in
                Button { pick(i) } label: {
                    Label { Text(PlayerColor.name(i)) } icon: {
                        Image(nsImage: Self.swatch(i))
                    }
                }
            }
        } label: {
            Circle().fill(PlayerColor.color(color)).frame(width: 12, height: 12)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Player colour")
    }

    /// Menus draw images, not shapes, so each colour gets a small round swatch image.
    static func swatch(_ i: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            rgb(PlayerColor.all[i].hex).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        return image
    }
}

/// A player name you can click to rename.
struct NameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .focused($focused)
            .onAppear { text = name }
            .onChange(of: name) { _, value in if !focused { text = value } }
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { text = name } else if trimmed != name { commit(trimmed) }
    }
}

// MARK: - Score table

struct ScoreTable: View {
    @ObservedObject var model: ScoreModel
    let game: Game

    var body: some View {
        VStack(spacing: 0) {
            row(label: Text("Round").foregroundStyle(.secondary)) { i in
                HStack(spacing: 5) {
                    Circle().fill(PlayerColor.color(game.players[i].color)).frame(width: 7, height: 7)
                    Text(game.players[i].name).lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 9)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(game.rounds.indices, id: \.self) { r in
                            row(label: roundLabel(r)) { p in
                                ScoreCell(value: game.rounds[r][p], isCurrent: r == game.rounds.count - 1) { value in
                                    model.update(game.id, "Edit Score") { $0.setScore(value, round: r, player: p) }
                                }
                            }
                            .id(r)
                        }
                        HStack {
                            Button { model.addRound() } label: {
                                Label("New Round", systemImage: "plus").font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Theme.blue)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: game.rounds.count) { old, new in
                    if new > old { withAnimation(.snappy) { proxy.scrollTo(new - 1, anchor: .bottom) } }
                }
            }
            Divider()
            row(label: Text("Total").font(.system(size: 12, weight: .bold))) { p in
                let leads = game.leaders.contains(p)
                HStack(spacing: 4) {
                    if leads { Image(systemName: "crown.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.goldGradient) }
                    Text("\(game.total(p))")
                        .contentTransition(.numericText(value: Double(game.total(p))))
                }
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(leads ? Theme.gold.opacity(0.16) : .clear))
            }
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.snappy, value: game.totals)
    }

    private func roundLabel(_ r: Int) -> some View {
        Text("\(r + 1)")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Delete Round \(r + 1)", role: .destructive) { model.update(game.id, "Delete Round") { $0.removeRound(r) } }
            }
    }

    private func row<Label: View, Cell: View>(label: Label, @ViewBuilder cell: @escaping (Int) -> Cell) -> some View {
        HStack(spacing: 8) {
            label.frame(width: 52, alignment: .leading)
            ForEach(game.players.indices, id: \.self) { p in
                cell(p).frame(minWidth: 56, maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
    }
}

/// One editable score. Commits on Return or when focus leaves; accepts "+5", "-3", or empty to clear.
struct ScoreCell: View {
    let value: Int?
    let isCurrent: Bool
    let commit: (Int?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text("0"))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .monospacedDigit()
            .focused($focused)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(focused ? AnyShapeStyle(Theme.blue.opacity(0.12)) : isCurrent ? AnyShapeStyle(Theme.blue.opacity(0.06))
                    : AnyShapeStyle(.quaternary.opacity(0.35))))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.blue.opacity(0.6) : .clear, lineWidth: 1.5))
            .onAppear { text = value.map(String.init) ?? "" }
            .onChange(of: value) { _, v in if !focused { text = v.map(String.init) ?? "" } }
            .onSubmit(save)
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
    }

    private func save() {
        guard let parsed = ScoreParser.parse(text) else {
            text = value.map(String.init) ?? ""
            NSSound.beep()
            return
        }
        text = parsed.map(String.init) ?? ""
        if parsed != value { commit(parsed) }
    }
}

// MARK: - Big totals

struct BigTotalsView: View {
    @ObservedObject var model: ScoreModel
    let game: Game

    private var rows: [[Int]] {
        let n = game.players.count
        let perRow = n <= 4 ? n : Int((Double(n) / 2).rounded(.up))
        return stride(from: 0, to: n, by: max(perRow, 1)).map { Array($0..<min($0 + perRow, n)) }
    }

    var body: some View {
        VStack(spacing: 16) {
            if game.isOver { WinnerBanner(model: model, game: game) }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { BigTile(model: model, game: game, index: $0) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct BigTile: View {
    @ObservedObject var model: ScoreModel
    let game: Game
    let index: Int

    private var player: Player { game.players[index] }
    private var leads: Bool { game.leaders.contains(index) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(ordinal(game.hasScores ? game.rank(of: index) : 1))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(leads ? .white : .secondary)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Capsule().fill(leads ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.quaternary.opacity(0.6))))
                    .opacity(game.hasScores ? 1 : 0)
                Spacer()
                if leads { Image(systemName: "crown.fill").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.goldGradient) }
            }
            Spacer(minLength: 0)
            Text(player.name)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(PlayerColor.color(player.color))
                .lineLimit(1)
            Capsule().fill(PlayerColor.color(player.color).gradient).frame(width: 40, height: 4)
            Text("\(game.total(index))")
                .font(.system(size: 150, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(game.total(index))))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .padding(.vertical, 4)
            Text(game.standingText(index) ?? " ")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                QuickButton(label: "\u{2212}1", help: "Take 1 point off this round", large: true) { add(-1) }
                QuickButton(label: "+1", help: "Add 1 point to this round", large: true) { add(1) }
                QuickButton(label: "+5", help: "Add 5 points to this round", large: true) { add(5) }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(leads ? AnyShapeStyle(Theme.goldGradient) : AnyShapeStyle(.quaternary), lineWidth: leads ? 3 : 1))
        .shadow(color: .black.opacity(0.07), radius: 5, y: 2)
        .animation(.snappy, value: game.totals)
    }

    private func add(_ n: Int) {
        withAnimation(.snappy) { model.update(game.id, n < 0 ? "Remove Point" : "Add Points") { $0.add(n, player: index) } }
    }
}

func ordinal(_ n: Int) -> String {
    let suffix: String
    switch (n % 10, n % 100) {
    case (_, 11...13): suffix = "th"
    case (1, _): suffix = "st"
    case (2, _): suffix = "nd"
    case (3, _): suffix = "rd"
    default: suffix = "th"
    }
    return "\(n)\(suffix)"
}

// MARK: - New game

struct NewGameSheet: View {
    @State var draft: Game
    let onCancel: () -> Void
    let onStart: (Game) -> Void
    @State private var useTarget: Bool
    @State private var target: Int

    init(draft: Game, onCancel: @escaping () -> Void, onStart: @escaping (Game) -> Void) {
        _draft = State(initialValue: draft)
        self.onCancel = onCancel
        self.onStart = onStart
        _useTarget = State(initialValue: draft.target != nil)
        _target = State(initialValue: draft.target ?? 100)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Game", text: $draft.name, prompt: Text("Rummy, Hearts, Catan"))
                }
                Section("Players") {
                    ForEach($draft.players) { $player in
                        HStack(spacing: 8) {
                            ColorMenu(color: player.color) { player.color = $0 }
                            TextField("Name", text: $player.name, prompt: Text("Name")).labelsHidden()
                            Button {
                                draft.players.removeAll { $0.id == player.id }
                            } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                                .disabled(draft.players.count <= 1)
                                .help("Remove player")
                        }
                    }
                    Button {
                        let used = Set(draft.players.map(\.color))
                        let color = PlayerColor.all.indices.first { !used.contains($0) } ?? draft.players.count
                        draft.players.append(Player(name: "", color: color))
                    } label: { Label("Add Player", systemImage: "plus") }
                        .disabled(draft.players.count >= Theme.maxPlayers)
                }
                Section("Rules") {
                    Picker("Winner", selection: $draft.rule) {
                        ForEach(WinRule.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("End at a target score", isOn: $useTarget)
                    if useTarget {
                        HStack {
                            TextField("Target", value: $target, format: .number)
                            Stepper("Target", value: $target, in: 1...1_000_000, step: 10).labelsHidden()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start Game") {
                    var game = draft
                    game.target = useTarget ? max(target, 1) : nil
                    onStart(game)
                }
                .keyboardShortcut(.defaultAction)
                .tint(Theme.blue)
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
    }
}
