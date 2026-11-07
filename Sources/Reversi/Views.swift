import AppKit
import Kit
import SwiftUI

enum Theme {
    static let jadeTop = Color(rgb(0x1F9D72))
    static let jadeBottom = Color(rgb(0x0B4D3A))
    static let accent = LinearGradient(colors: [jadeTop, jadeBottom], startPoint: .top, endPoint: .bottom)
    static let marker = Color(rgb(0xFF6B4A))
}

struct ContentView: View {
    @ObservedObject var model: GameModel

    var body: some View {
        HStack(spacing: 0) {
            BoardView(model: model)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
            Divider()
            Sidebar(model: model)
                .frame(width: 280)
        }
        .frame(minWidth: 780, minHeight: 540)
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Opponent", selection: $model.opponent) {
                ForEach(Opponent.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Who you play against")
        }
        ToolbarItem(placement: .navigation) {
            Picker("Play As", selection: $model.humanSide) {
                Text("Black").tag(Disc.black)
                Text("White").tag(Disc.white)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(model.opponent == .human)
            .help("The colour you play; Black moves first")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.showHints) {
                Label("Show Legal Moves", systemImage: model.showHints ? "lightbulb.fill" : "lightbulb")
            }
            .help("Show legal moves (\u{21E7}\u{2318}L)")
            Button { model.undo() } label: { Label("Undo Move", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Take back your last move (\u{2318}Z)")
            Button { model.newGame() } label: { Label("New Game", systemImage: "arrow.counterclockwise") }
                .help("Start a new game (\u{2318}N)")
        }
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var model: GameModel
    @State private var hovered: Int?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let rim = side * 0.06
            let cell = (side - rim * 2) / 8
            ZStack {
                frame(side: side, rim: rim, cell: cell)
                felt(cell: cell)
                    .frame(width: cell * 8, height: cell * 8)
                discs(cell: cell)
                    .frame(width: cell * 8, height: cell * 8)
                overlays
                    .frame(width: cell * 8, height: cell * 8)
            }
            .frame(width: side, height: side)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func frame(side: CGFloat, rim: CGFloat, cell: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.035, style: .continuous)
                .fill(LinearGradient(colors: [Color(rgb(0x1E4636)), Color(rgb(0x0A2119))], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: side * 0.035, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top,
                                                 endPoint: .bottom), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            // Coordinates in the rim, like a real tournament board.
            ForEach(0..<8, id: \.self) { i in
                let offset = (CGFloat(i) - 3.5) * cell
                Text(String(Array("abcdefgh")[i]))
                    .offset(x: offset, y: -(side / 2 - rim / 2))
                Text(String(Array("abcdefgh")[i]))
                    .offset(x: offset, y: side / 2 - rim / 2)
                Text("\(i + 1)")
                    .offset(x: -(side / 2 - rim / 2), y: offset)
                Text("\(i + 1)")
                    .offset(x: side / 2 - rim / 2, y: offset)
            }
            .font(.system(size: max(9, rim * 0.36), weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func felt(cell: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(LinearGradient(colors: [Color(rgb(0x23A479)), Color(rgb(0x137A58))], startPoint: .top,
                                            endPoint: .bottom))
            // Soft light from the top left, a gentle vignette towards the edges.
            Rectangle().fill(RadialGradient(colors: [.white.opacity(0.20), .clear], center: UnitPoint(x: 0.3, y: 0.2),
                                            startRadius: 0, endRadius: cell * 7))
            Rectangle().fill(RadialGradient(colors: [.clear, .black.opacity(0.22)], center: .center,
                                            startRadius: cell * 3.2, endRadius: cell * 6.2))
            Path { p in
                for i in 1..<8 {
                    let x = CGFloat(i) * cell
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: cell * 8))
                    p.move(to: CGPoint(x: 0, y: x)); p.addLine(to: CGPoint(x: cell * 8, y: x))
                }
            }
            .stroke(Color.black.opacity(0.3), lineWidth: 1)
            ForEach(0..<4, id: \.self) { i in
                Circle().fill(Color.black.opacity(0.45))
                    .frame(width: cell * 0.1, height: cell * 0.1)
                    .position(x: (i % 2 == 0 ? 2 : 6) * cell, y: (i < 2 ? 2 : 6) * cell)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cell * 0.08, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cell * 0.08, style: .continuous)
            .strokeBorder(Color.black.opacity(0.45), lineWidth: 1.5))
    }

    private func discs(cell: CGFloat) -> some View {
        let pos = model.position
        let hints = model.hints
        let last = model.game.lastMove
        return VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { c in
                        let sq = r * 8 + c
                        CellView(disc: pos.disc(at: sq), isHint: hints & (1 << UInt64(sq)) != 0,
                                 isHovered: hovered == sq, isLast: last == sq, mover: pos.toMove,
                                 delay: delay(sq), size: cell)
                            .frame(width: cell, height: cell)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = sq } else if hovered == sq { hovered = nil }
                            }
                            .onTapGesture { model.tap(sq) }
                    }
                }
            }
        }
    }

    /// Flips ripple outwards from the square just played.
    private func delay(_ sq: Int) -> Double {
        guard let o = model.flipOrigin else { return 0 }
        let d = max(abs(sq / 8 - o / 8), abs(sq % 8 - o % 8))
        return Double(max(0, d - 1)) * 0.07
    }

    @ViewBuilder private var overlays: some View {
        ZStack {
            if let notice = model.notice, !model.isOver {
                Text(notice)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if model.isOver {
                GameOverCard(model: model)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: model.notice)
        .animation(.snappy(duration: 0.35), value: model.isOver)
    }
}

struct CellView: View {
    let disc: Disc?
    let isHint: Bool
    let isHovered: Bool
    let isLast: Bool
    let mover: Disc
    let delay: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            if let disc {
                DiscFace(progress: disc == .white ? 1 : 0, diameter: size * 0.8)
                    .animation(.easeInOut(duration: 0.42).delay(delay), value: disc)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                if isLast {
                    Circle().fill(Theme.marker)
                        .frame(width: size * 0.13, height: size * 0.13)
                        .shadow(color: Theme.marker.opacity(0.6), radius: 3)
                        .transition(.opacity)
                }
            } else if isHint {
                if isHovered {
                    DiscFace(progress: mover == .white ? 1 : 0, diameter: size * 0.8, flat: true)
                        .opacity(0.55)
                } else {
                    Circle()
                        .fill(mover == .black ? Color.black.opacity(0.28) : Color.white.opacity(0.5))
                        .frame(width: size * 0.2, height: size * 0.2)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: disc == nil)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A glossy disc. `progress` 0 is black face up, 1 is white; in between it turns over, lifting off the board.
struct DiscFace: View, Animatable {
    var progress: Double
    let diameter: CGFloat
    var flat = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let angle = progress * .pi
        let squash = max(0.04, abs(cos(angle)))
        let lift = sin(angle)
        let white = progress > 0.5
        ZStack {
            // The rim, so the disc reads as a thick piece rather than a sticker.
            Circle()
                .fill(white ? Color(rgb(0x9C9C92)) : Color(rgb(0x000000)))
                .offset(y: diameter * 0.035)
            Circle()
                .fill(RadialGradient(colors: white
                    ? [Color(rgb(0xFFFFFF)), Color(rgb(0xF0F0EA)), Color(rgb(0xC4C4BA))]
                    : [Color(rgb(0x5E5E5E)), Color(rgb(0x1C1C1C)), Color(rgb(0x050505))],
                    center: UnitPoint(x: 0.36, y: 0.3), startRadius: 0, endRadius: diameter * 0.72))
            Ellipse()
                .fill(LinearGradient(colors: [.white.opacity(white ? 0.9 : 0.42), .white.opacity(0)], startPoint: .top,
                                     endPoint: .bottom))
                .frame(width: diameter * 0.56, height: diameter * 0.3)
                .offset(x: -diameter * 0.06, y: -diameter * 0.22)
            Circle().strokeBorder(Color.black.opacity(white ? 0.18 : 0.5), lineWidth: 0.6)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(x: squash, y: 1)
        .scaleEffect(1 + 0.16 * lift)
        .shadow(color: .black.opacity(flat ? 0 : 0.38 - 0.1 * lift), radius: 1.5 + 6 * lift, x: 0, y: 1.5 + 6 * lift)
    }
}

struct GameOverCard: View {
    @ObservedObject var model: GameModel

    var body: some View {
        VStack(spacing: 12) {
            Text(model.resultTitle)
                .font(.system(size: 26, weight: .bold, design: .rounded))
            HStack(spacing: 18) {
                score(.black)
                Text("to").foregroundStyle(.secondary)
                score(.white)
            }
            Button("New Game") { model.newGame() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.jadeBottom)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 34).padding(.vertical, 24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
    }

    private func score(_ side: Disc) -> some View {
        HStack(spacing: 8) {
            DiscFace(progress: side == .white ? 1 : 0, diameter: 22)
            Text("\(model.position.count(side))")
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: GameModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerCard(model: model, side: .black)
            PlayerCard(model: model, side: .white)
            HStack(spacing: 8) {
                if model.thinking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.isOver ? "flag.checkered" : "circle.fill")
                        .font(.system(size: model.isOver ? 12 : 7))
                        .foregroundStyle(model.isOver ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accent))
                }
                Text(model.status)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(height: 20)
            .padding(.horizontal, 4)
            .animation(.snappy, value: model.status)

            Divider().opacity(0.6)

            HStack {
                Text("Moves").font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text("\(model.game.squares.count) played, \(model.position.empty.nonzeroBitCount) empty")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            MoveList(records: model.game.records)

            HStack(spacing: 10) {
                Button { model.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
                }
                .disabled(!model.canUndo)
                Button { model.newGame() } label: {
                    Label("New Game", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.jadeBottom)
            }
            .controlSize(.large)
            .focusable(false)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PlayerCard: View {
    @ObservedObject var model: GameModel
    let side: Disc

    var body: some View {
        let active = !model.isOver && model.position.toMove == side
        HStack(spacing: 12) {
            DiscFace(progress: side == .white ? 1 : 0, diameter: 30)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.playerName(side)).font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(model.playerDetail(side)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.position.count(side))")
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: model.position.count(side))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(active ? AnyShapeStyle(Theme.jadeTop.opacity(0.1)) : AnyShapeStyle(.quaternary.opacity(0.35))))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear), lineWidth: 2))
        .animation(.snappy(duration: 0.25), value: active)
    }
}

struct MoveList: View {
    let records: [Record]

    /// Records strictly alternate, Black first, because a pass is recorded too: pair them into turns.
    private var turns: [(number: Int, black: Record?, white: Record?)] {
        stride(from: 0, to: records.count, by: 2).map { i in
            (i / 2 + 1, records[i], i + 1 < records.count ? records[i + 1] : nil)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if records.isEmpty {
                        Text("Black moves first. Pick a highlighted square.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(turns, id: \.number) { turn in
                        HStack(spacing: 0) {
                            Text("\(turn.number).").foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing)
                            cell(turn.black)
                            cell(turn.white)
                        }
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(height: 22)
                        .background(turn.number % 2 == 0 ? Color.primary.opacity(0.035) : .clear)
                        .id(turn.number)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: records.count) { _, _ in
                withAnimation(.snappy) { proxy.scrollTo(turns.count, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(turns.count, anchor: .bottom) }
        }
    }

    private func cell(_ record: Record?) -> some View {
        Text(record?.label ?? "")
            .fontWeight(record != nil && record == records.last ? .bold : .regular)
            .foregroundStyle(record?.square == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
    }
}
