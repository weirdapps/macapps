import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(nsColor: rgb(0x48D1B5))
    static let bottom = Color(nsColor: rgb(0x1B7F8C))
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// The player's digits: deep teal on light, bright seafoam on dark.
    static let ink = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0x62E3C7) : rgb(0x167482)
    })
    static let board = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0x1F2324) : rgb(0xFFFFFF)
    })
    static let clash = Color(nsColor: .systemRed)
}

struct ContentView: View {
    @ObservedObject var model: NineModel
    @FocusState private var focused: Bool
    static let panelWidth: CGFloat = 256

    var body: some View {
        GeometryReader { geo in
            // The board takes the largest square that fits; the panel matches its height so their edges line up.
            let side = max(300, min(geo.size.height, geo.size.width - Self.panelWidth - 30))
            HStack(spacing: 30) {
                BoardView(model: model)
                    .frame(width: side, height: side)
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(phases: [.down, .repeat]) { model.handle($0) }
                    .simultaneousGesture(TapGesture().onEnded { focused = true })
                SidePanel(model: model)
                    .frame(width: Self.panelWidth, height: side)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Nine")
        .navigationSubtitle(model.game.map { $0.difficulty.title } ?? "")
        .toolbar { toolbar }
        .onAppear { focused = true }
        .confirmationDialog("Start a new game?", isPresented: Binding(get: { model.pendingNewGame != nil },
                                                                     set: { if !$0 { model.pendingNewGame = nil } }),
                            presenting: model.pendingNewGame) { level in
            Button("New \(level.title) Game") { model.newGame(level) }
            Button("Keep Playing", role: .cancel) { model.pendingNewGame = nil }
        } message: { _ in
            Text("The puzzle you are playing will be lost.")
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in model.tick() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Menu {
                ForEach(Difficulty.allCases) { level in
                    Button(level.title) { model.requestNewGame(level) }
                }
            } label: {
                Label("New Game", systemImage: "plus.square.on.square")
            } primaryAction: {
                model.requestNewGame()
            }
            .help("New game (click and hold to pick a difficulty)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .help("Undo").disabled(!(model.game?.canUndo ?? false) || !model.isPlaying)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .help("Redo").disabled(!(model.game?.canRedo ?? false) || !model.isPlaying)
            Toggle(isOn: Binding(get: { model.notesMode }, set: { _ in model.toggleNotesMode() })) {
                Label("Notes", systemImage: "pencil")
            }
            .help("Notes mode (N)")
            Button { model.hint() } label: { Label("Hint", systemImage: "lightbulb") }
                .help("Fill one cell (Shift Command H)").disabled(!model.isPlaying)
            Button { model.togglePause() } label: {
                Label(model.paused ? "Resume" : "Pause", systemImage: model.paused ? "play.fill" : "pause.fill")
            }
            .help(model.paused ? "Resume (Command P)" : "Pause (Command P)")
            .disabled(model.game?.completed ?? true)
        }
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var model: NineModel

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / 9
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.board)
                    .shadow(color: .black.opacity(0.10), radius: 14, y: 6)
                if let game = model.game {
                    cells(game, cell: cell)
                        .blur(radius: model.paused ? 18 : 0)
                        .opacity(model.paused ? 0 : 1)
                }
                GridLines()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
                overlay
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cells(_ game: Game, cell: CGFloat) -> some View {
        let conflicts = model.showConflicts ? game.conflicts : []
        let focus = model.selected
        let focusDigit = focus.map { game.values[$0] } ?? 0
        return VStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { c in
                        let i = r * 9 + c
                        CellView(game: game, index: i, size: cell,
                                 selected: focus == i,
                                 related: focus.map { Sudoku.isPeer($0, i) } ?? false,
                                 sameDigit: focusDigit != 0 && game.values[i] == focusDigit && focus != i,
                                 focusDigit: focusDigit,
                                 conflict: conflicts.contains(i),
                                 hinted: model.hinted == i,
                                 celebration: model.celebration)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(i) }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder private var overlay: some View {
        if model.generating {
            BoardMessage(symbol: nil, title: "Making a new puzzle", detail: "Checking it has exactly one solution.")
        } else if model.paused {
            BoardMessage(symbol: "pause.circle.fill", title: "Paused", detail: "The board is hidden while the clock is stopped.") {
                Button("Resume") { model.togglePause() }.buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
            }
        } else if let game = model.game, game.completed {
            SolvedCard(model: model, game: game)
        }
    }
}

struct CellView: View {
    let game: Game
    let index: Int
    let size: CGFloat
    let selected: Bool
    let related: Bool
    let sameDigit: Bool
    let focusDigit: Int
    let conflict: Bool
    let hinted: Bool
    let celebration: Int

    var body: some View {
        let value = game.values[index]
        ZStack {
            Rectangle().fill(background)
            if value != 0 {
                Text("\(value)")
                    .font(.system(size: size * 0.54, weight: game.isGiven(index) ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(foreground)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if game.notes[index] != 0 {
                notes
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if hinted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.gradient, lineWidth: 2.5)
                    .padding(3)
                    .shadow(color: Theme.top.opacity(0.8), radius: 6)
                    .transition(.opacity)
            }
        }
        .phaseAnimator([0.0, 1.0, 0.0], trigger: celebration) { view, phase in
            view.scaleEffect(1 + 0.16 * phase).brightness(0.08 * phase)
        } animation: { phase in
            phase == 1 ? .spring(duration: 0.32, bounce: 0.4).delay(wave) : .spring(duration: 0.4)
        }
    }

    /// The celebration runs as a diagonal wave from the top left corner.
    private var wave: Double { Double(Sudoku.row(index) + Sudoku.col(index)) * 0.035 }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Theme.top.opacity(0.42)) }
        if conflict { return AnyShapeStyle(Theme.clash.opacity(0.14)) }
        if game.completed { return AnyShapeStyle(Theme.top.opacity(0.10)) }
        if sameDigit { return AnyShapeStyle(Theme.top.opacity(0.24)) }
        if related { return AnyShapeStyle(Theme.top.opacity(0.08)) }
        return AnyShapeStyle(.clear)
    }

    private var foreground: Color {
        if conflict && !game.isGiven(index) { return Theme.clash }
        return game.isGiven(index) ? .primary : Theme.ink
    }

    private var notes: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(1...3, id: \.self) { c in
                        let d = r * 3 + c
                        let on = game.notes[index] & (1 << d) != 0
                        Text(on ? "\(d)" : " ")
                            .font(.system(size: size * 0.2, weight: d == focusDigit ? .bold : .medium, design: .rounded))
                            .foregroundStyle(d == focusDigit ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(size * 0.07)
    }
}

/// Thin cell lines, heavier box lines, a crisp outer edge.
struct GridLines: View {
    var body: some View {
        Canvas { ctx, size in
            let step = size.width / 9
            var thin = Path(), thick = Path()
            for k in 1..<9 {
                let x = CGFloat(k) * step
                var p = Path()
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: x)); p.addLine(to: CGPoint(x: size.width, y: x))
                if k % 3 == 0 { thick.addPath(p) } else { thin.addPath(p) }
            }
            ctx.stroke(thin, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            ctx.stroke(thick, with: .color(.primary.opacity(0.42)), lineWidth: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.42), lineWidth: 2))
    }
}

struct BoardMessage<Actions: View>: View {
    let symbol: String?
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 44, weight: .light)).foregroundStyle(Theme.gradient)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
            actions.padding(.top, 6)
        }
        .padding(30)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

extension BoardMessage where Actions == EmptyView {
    init(symbol: String?, title: String, detail: String) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

struct SolvedCard: View {
    @ObservedObject var model: NineModel
    let game: Game
    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.gradient)
                .symbolEffect(.bounce, value: shown)
            Text("Solved").font(.system(size: 26, weight: .bold, design: .rounded))
            Text("\(game.difficulty.title) in \(Clock.format(game.elapsed))" + (game.hints > 0 ? ", \(game.hints) hint\(game.hints == 1 ? "" : "s")" : ""))
                .font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            if model.newRecord {
                Label("New best time", systemImage: "star.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.top.opacity(0.18)))
            }
            Button("New \(game.difficulty.title) Game") { model.newGame(game.difficulty) }
                .buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
                .padding(.top, 8)
        }
        .padding(.horizontal, 36).padding(.vertical, 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 10)
        .scaleEffect(shown ? 1 : 0.85)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.35).delay(0.75)) { shown = true }
        }
    }
}

// MARK: - Side panel

struct SidePanel: View {
    @ObservedObject var model: NineModel

    var body: some View {
        let game = model.game
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(game?.difficulty.title ?? model.difficulty.title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(Theme.gradient))
                Spacer()
                if let best = model.records.best[(game?.difficulty ?? model.difficulty).rawValue] {
                    Label("Best \(Clock.format(best))", systemImage: "trophy")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text(Clock.format(game?.elapsed ?? 0))
                .font(.system(size: 50, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: game?.elapsed)
                .foregroundStyle(model.paused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.top, 14)
            progress(game).padding(.top, 6)

            NumberPad(model: model).padding(.top, 22)

            HStack(spacing: 8) {
                ActionButton(symbol: model.notesMode ? "pencil.circle.fill" : "pencil", title: "Notes", key: "N",
                             active: model.notesMode) { model.toggleNotesMode() }
                ActionButton(symbol: "delete.left", title: "Erase", key: "⌫", active: false) { model.erase() }
                ActionButton(symbol: "lightbulb", title: "Hint", key: "⇧⌘H", active: false) { model.hint() }
            }
            .padding(.top, 12)
            .disabled(!model.isPlaying)

            Spacer(minLength: 16)
            HStack(spacing: 6) {
                KeyCap("← → ↑ ↓")
                Text("move").foregroundStyle(.secondary)
                KeyCap("1 to 9")
                Text("place").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
    }

    private func progress(_ game: Game?) -> some View {
        let clues = game?.givens.filter { $0 != 0 }.count ?? 0
        let filled = game?.filled ?? 0
        let open = max(1, 81 - clues)
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(filled - clues), total: Double(open))
                .tint(Theme.bottom)
            HStack {
                Text("\(81 - filled) cells to go").contentTransition(.numericText())
                Spacer()
                if let hints = game?.hints, hints > 0 { Text("\(hints) hint\(hints == 1 ? "" : "s")") }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct NumberPad: View {
    @ObservedObject var model: NineModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { c in
                        let d = r * 3 + c
                        DigitKey(digit: d, remaining: model.game?.remaining(d) ?? 9, notes: model.notesMode,
                                 highlighted: model.selected.flatMap { model.game?.values[$0] } == d) { model.input(d) }
                    }
                }
            }
        }
        .disabled(!model.isPlaying)
    }
}

struct DigitKey: View {
    let digit: Int
    let remaining: Int
    let notes: Bool
    let highlighted: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text("\(digit)")
                    .font(.system(size: notes ? 22 : 30, weight: notes ? .medium : .semibold, design: .rounded))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : remaining == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.ink))
                Text(remaining == 0 ? "done" : "\(remaining) left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .aspectRatio(1, contentMode: .fit)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(highlighted ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.75 : 0.4)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = Desktop.isSnapshot ? false : $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(notes ? "Toggle the \(digit) note" : "Place \(digit)")
    }
}

struct ActionButton: View {
    let symbol: String
    let title: String
    let key: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(0.8)))
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.75 : 0.4)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = Desktop.isSnapshot ? false : $0 }
        .help("\(title) (\(key))")
    }
}
