import AppKit
import Kit
import SwiftUI

// MARK: - Layout

/// Where every slot and card sits for a given window size. Cards scale with the window.
struct TableLayout {
    let size: CGSize
    let cardW: CGFloat
    let cardH: CGFloat
    let gap: CGFloat
    let originX: CGFloat
    let top: CGFloat
    let tableauY: CGFloat
    let bottom: CGFloat

    static let statusBar: CGFloat = 52

    init(size: CGSize) {
        self.size = size
        let margin: CGFloat = 20
        let byWidth = (size.width - 2 * margin) / (7 + 6 * 0.24)
        let byHeight = (size.height - margin - TableLayout.statusBar) / (1.4 * 3.25)
        cardW = max(40, min(byWidth, byHeight, 128))
        cardH = cardW * 1.4
        gap = cardW * 0.24
        originX = (size.width - 7 * cardW - 6 * gap) / 2
        top = margin
        tableauY = margin + cardH + gap * 0.9
        bottom = size.height - TableLayout.statusBar
    }

    func x(_ column: Int) -> CGFloat { originX + CGFloat(column) * (cardW + gap) }

    func slot(_ spot: Spot) -> CGRect {
        let origin: CGPoint = switch spot {
        case .stock: CGPoint(x: x(0), y: top)
        case .waste: CGPoint(x: x(1), y: top)
        case .foundation(let i): CGPoint(x: x(3 + i), y: top)
        case .tableau(let c): CGPoint(x: x(c), y: tableauY)
        }
        return CGRect(origin: origin, size: CGSize(width: cardW, height: cardH))
    }

    /// Vertical steps for face down and face up cards in a column, squeezed when the column would run off the table.
    func steps(count: Int, faceUpFrom: Int) -> (down: CGFloat, up: CGFloat) {
        var down = cardH * 0.1, up = cardH * 0.3
        let downs = CGFloat(min(faceUpFrom, count)), ups = CGFloat(max(0, count - faceUpFrom - 1))
        let room = bottom - tableauY - cardH
        let need = downs * down + ups * up
        if need > room, need > 0 {
            let scale = max(0.3, room / need)
            down *= scale
            up *= scale
        }
        return (down, up)
    }

    struct Placed: Identifiable {
        let card: Card
        let spot: Spot
        let index: Int
        let faceUp: Bool
        let origin: CGPoint
        let z: Double
        var id: Int { card.id }
    }

    func place(_ board: Board) -> [Placed] {
        var out: [Placed] = []
        let stock = slot(.stock).origin
        for (i, card) in board.stock.enumerated() {
            let nudge = CGFloat(i / 8) * 0.8
            out.append(Placed(card: card, spot: .stock, index: i, faceUp: false,
                              origin: CGPoint(x: stock.x - nudge, y: stock.y - nudge), z: Double(i)))
        }
        let waste = slot(.waste).origin
        let fanned = board.draw == .three ? min(3, board.waste.count) : 0
        for (i, card) in board.waste.enumerated() {
            let fanIndex = i - (board.waste.count - fanned)
            let dx = fanIndex > 0 ? CGFloat(fanIndex) * cardW * 0.26 : 0
            out.append(Placed(card: card, spot: .waste, index: i, faceUp: true,
                              origin: CGPoint(x: waste.x + dx, y: waste.y), z: 100 + Double(i)))
        }
        for (f, pile) in board.foundations.enumerated() {
            for (i, card) in pile.enumerated() {
                out.append(Placed(card: card, spot: .foundation(f), index: i, faceUp: true, origin: slot(.foundation(f)).origin,
                                  z: 200 + Double(i)))
            }
        }
        for (c, column) in board.tableau.enumerated() {
            let step = steps(count: column.count, faceUpFrom: board.faceUpFrom[c])
            var y = tableauY
            for (i, card) in column.enumerated() {
                let up = board.isFaceUp(column: c, index: i)
                out.append(Placed(card: card, spot: .tableau(c), index: i, faceUp: up, origin: CGPoint(x: x(c), y: y),
                                  z: 300 + Double(i)))
                y += up ? step.up : step.down
            }
        }
        return out
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: GameModel

    var body: some View {
        ZStack {
            FeltBackground(felt: model.felt)
            BoardView(model: model)
            if model.won { WinOverlay(model: model) }
        }
        .frame(minWidth: 720, minHeight: 520)
        .toolbar { toolbar }
        .navigationSubtitle("Game \(String(model.number))")
        .sheet(isPresented: $model.showStats) { StatsView(model: model) }
        .sheet(isPresented: $model.showChooser) { ChooserView(model: model) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.isActive = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.isActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.save() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Draw", selection: $model.drawMode) {
                ForEach(DrawMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Turn over one or three cards from the stock. Applies to the next deal once a game has started.")
            Button { withAnimation(.snappy) { model.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo the last move (⌘Z)")
            Button { withAnimation(.snappy) { model.showHint() } } label: { Label("Hint", systemImage: "lightbulb") }
                .disabled(model.won)
                .help("Show a possible move (⇧⌘H)")
            Button { model.autoComplete() } label: { Label("Auto Complete", systemImage: "wand.and.stars") }
                .disabled(!model.canAutoComplete)
                .help("Move every card to the foundations (⇧⌘A)")
            Button { model.showStats = true } label: { Label("Statistics", systemImage: "chart.bar.xaxis") }
                .help("Games, wins and streaks (⌘I)")
            Button { withAnimation(.snappy) { model.newGame() } } label: { Label("New Game", systemImage: "plus.rectangle.on.rectangle") }
                .help("Deal a new game (⌘N)")
        }
    }
}

struct FeltBackground: View {
    let felt: Felt

    var body: some View {
        let (centre, edge) = felt.colors
        GeometryReader { geo in
            RadialGradient(colors: [centre, edge], center: .init(x: 0.5, y: 0.35),
                           startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.8)
                .overlay { FeltWeave().opacity(0.06) }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.35), value: felt)
    }
}

/// A faint diagonal weave so the table reads as cloth rather than a flat fill.
struct FeltWeave: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += 5
            }
            ctx.stroke(path, with: .color(.black), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Board

struct BoardView: View {
    @ObservedObject var model: GameModel
    @State private var drag: DragState?

    struct DragState {
        var spot: Spot
        var index: Int
        var offset: CGSize
    }

    var body: some View {
        GeometryReader { geo in
            let layout = TableLayout(size: geo.size)
            let placed = layout.place(model.board)
            ZStack(alignment: .topLeading) {
                slots(layout)
                ForEach(placed) { item in cardView(item, layout: layout, placed: placed) }
                hintGlow(layout: layout, placed: placed)
                StatusBar(model: model)
                    .frame(width: geo.size.width, height: TableLayout.statusBar)
                    .offset(y: geo.size.height - TableLayout.statusBar)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "table")
        }
    }

    // Empty places: the stock (click to turn the waste back over), foundations and columns.
    private func slots(_ layout: TableLayout) -> some View {
        ZStack(alignment: .topLeading) {
            SlotView(symbol: model.board.waste.isEmpty ? nil : "arrow.counterclockwise", label: nil, width: layout.cardW)
                .offset(x: layout.slot(.stock).minX, y: layout.slot(.stock).minY)
                .onTapGesture { withAnimation(.snappy(duration: 0.3)) { model.dealFromStock() } }
                .help("Click to turn the waste back over")
            SlotView(symbol: nil, label: nil, width: layout.cardW, faint: true)
                .offset(x: layout.slot(.waste).minX, y: layout.slot(.waste).minY)
            ForEach(0..<4, id: \.self) { f in
                SlotView(symbol: nil, label: "A", width: layout.cardW)
                    .offset(x: layout.slot(.foundation(f)).minX, y: layout.slot(.foundation(f)).minY)
            }
            ForEach(0..<7, id: \.self) { c in
                SlotView(symbol: nil, label: "K", width: layout.cardW, faint: true)
                    .offset(x: layout.slot(.tableau(c)).minX, y: layout.slot(.tableau(c)).minY)
            }
        }
    }

    private func isDragged(_ item: TableLayout.Placed) -> Bool {
        guard let drag, drag.spot == item.spot else { return false }
        return item.index >= drag.index
    }

    private func cardView(_ item: TableLayout.Placed, layout: TableLayout, placed: [TableLayout.Placed]) -> some View {
        let dragged = isDragged(item)
        let offset = dragged ? drag?.offset ?? .zero : .zero
        let z = dragged ? 2000 + item.z : (model.lifted.contains(item.card.id) ? 1000 + item.z : item.z)
        return CardView(card: item.card, faceUp: item.faceUp, width: layout.cardW)
            .shadow(color: .black.opacity(dragged ? 0.35 : 0.22), radius: dragged ? 10 : 1.5, y: dragged ? 8 : 1)
            .scaleEffect(dragged ? 1.03 : 1)
            .position(x: item.origin.x + layout.cardW / 2 + offset.width, y: item.origin.y + layout.cardH / 2 + offset.height)
            .zIndex(z)
            .gesture(dragGesture(item, layout: layout, placed: placed), including: canPickUp(item) ? .all : .subviews)
            .onTapGesture(count: item.spot == .stock ? 1 : 2) {
                withAnimation(.snappy(duration: 0.3)) {
                    if item.spot == .stock { model.dealFromStock() } else if item.faceUp { model.smartMove(from: item.spot, index: item.index) }
                }
            }
    }

    private func canPickUp(_ item: TableLayout.Placed) -> Bool {
        guard item.faceUp, !model.won, !model.autoCompleting else { return false }
        switch item.spot {
        case .stock: return false
        case .waste, .foundation: return item.index == model.board.cards(at: item.spot).count - 1
        case .tableau: return model.board.movable(from: item.spot, count: model.board.cards(at: item.spot).count - item.index) != nil
        }
    }

    private func dragGesture(_ item: TableLayout.Placed, layout: TableLayout, placed: [TableLayout.Placed]) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("table"))
            .onChanged { value in
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { drag = DragState(spot: item.spot, index: item.index, offset: value.translation) }
            }
            .onEnded { value in
                let count = model.board.cards(at: item.spot).count - item.index
                let rect = CGRect(origin: item.origin, size: CGSize(width: layout.cardW, height: layout.cardH))
                    .offsetBy(dx: value.translation.width, dy: value.translation.height)
                withAnimation(.snappy(duration: 0.28)) {
                    if let target = dropTarget(for: rect, from: item.spot, count: count, layout: layout, placed: placed) {
                        model.perform(Move(from: item.spot, to: target, count: count))
                    }
                    drag = nil
                }
            }
    }

    /// The legal pile the dragged card overlaps most.
    private func dropTarget(for rect: CGRect, from: Spot, count: Int, layout: TableLayout, placed: [TableLayout.Placed]) -> Spot? {
        var best: (Spot, CGFloat)?
        let targets = (0..<4).map { Spot.foundation($0) } + (0..<7).map { Spot.tableau($0) }
        for spot in targets where model.board.isLegal(Move(from: from, to: spot, count: count)) {
            var area = layout.slot(spot)
            if case .tableau = spot, let last = placed.last(where: { $0.spot == spot }) {
                area = area.union(CGRect(origin: last.origin, size: area.size))
            }
            let overlap = area.intersection(rect)
            guard !overlap.isNull else { continue }
            let value = overlap.width * overlap.height
            if value > (best?.1 ?? 0) { best = (spot, value) }
        }
        return best?.0
    }

    @ViewBuilder
    private func hintGlow(layout: TableLayout, placed: [TableLayout.Placed]) -> some View {
        if let hint = model.hint {
            let rects: [CGRect] = {
                switch hint {
                case .deal:
                    return [layout.slot(.stock)]
                case .move(let move):
                    let from = placed.filter { $0.spot == move.from }.suffix(move.count)
                    let source = from.reduce(CGRect.null) { $0.union(CGRect(origin: $1.origin, size: layout.slot(.stock).size)) }
                    let target = placed.last { $0.spot == move.to }.map { CGRect(origin: $0.origin, size: layout.slot(.stock).size) }
                    return [source, target ?? layout.slot(move.to)]
                }
            }()
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: layout.cardW * 0.09, style: .continuous)
                    .strokeBorder(Color(hex: 0xFFE27A), lineWidth: 3)
                    .shadow(color: Color(hex: 0xFFD54A).opacity(0.9), radius: 8)
                    .frame(width: rect.width + 6, height: rect.height + 6)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            .zIndex(3000)
        }
    }
}

/// An empty place on the table: a soft outline, with a letter or a symbol.
struct SlotView: View {
    let symbol: String?
    let label: String?
    let width: CGFloat
    var faint = false

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
            .fill(.black.opacity(faint ? 0.06 : 0.1))
            .overlay {
                RoundedRectangle(cornerRadius: width * 0.08, style: .continuous)
                    .strokeBorder(.white.opacity(faint ? 0.14 : 0.24), lineWidth: 1.5)
            }
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: width * 0.3, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                } else if let label {
                    Text(label).font(.system(size: width * 0.34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(faint ? 0.12 : 0.22))
                }
            }
            .frame(width: width, height: width * 1.4)
            .contentShape(Rectangle())
    }
}

// MARK: - Status

struct StatusBar: View {
    @ObservedObject var model: GameModel

    var body: some View {
        HStack(spacing: 10) {
            StatusPill(title: "Score", value: "\(model.score)")
            StatusPill(title: "Time", value: model.seconds.clock)
            StatusPill(title: "Moves", value: "\(model.board.moves)")
            Spacer()
            if model.noHint {
                Label("No moves left. Undo, or deal a new game.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.black.opacity(0.3)))
                    .transition(.opacity)
            } else if model.drawMode != model.board.draw {
                Text("\(model.drawMode.title) starts with the next game")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
            StatusPill(title: model.board.draw.title, value: nil)
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .animation(.snappy, value: model.noHint)
    }
}

struct StatusPill: View {
    let title: String
    let value: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.white.opacity(value == nil ? 0.9 : 0.62))
            if let value {
                Text(value).foregroundStyle(.white).monospacedDigit().contentTransition(.numericText())
            }
        }
        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .animation(.snappy, value: value)
    }
}

// MARK: - Win

struct WinOverlay: View {
    @ObservedObject var model: GameModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let start = model.celebration, !reduceMotion {
                Cascade(start: start, pileOfSuit: Suit.allCases.map { suit in
                    model.board.foundations.firstIndex { $0.first?.suit == suit } ?? suit.rawValue
                })
            }
            Color.black.opacity(0.12).allowsHitTesting(false)
            WinPanel(model: model)
        }
        .transition(.opacity)
    }
}

/// Every card bounces off the foundations and across the table, leaving a short trail.
struct Cascade: View {
    let start: Date
    let pileOfSuit: [Int] // The foundation each suit finished on.

    static let launchGap = 0.16
    static let duration = Double(Card.deck.count) * launchGap + 4

    var body: some View {
        GeometryReader { geo in
            let layout = TableLayout(size: geo.size)
            TimelineView(.animation(paused: Date().timeIntervalSince(start) > Cascade.duration)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas { ctx, size in
                    for (k, card) in Cascade.order.enumerated() {
                        let from = layout.slot(.foundation(pileOfSuit[card.suit.rawValue])).origin
                        for ghost in stride(from: 5, through: 0, by: -1) {
                            let tk = t - Double(k) * Cascade.launchGap - Double(ghost) * 0.05
                            guard tk >= 0, let p = Cascade.position(card: card, from: from, time: tk, size: size, cardH: layout.cardH),
                                  let symbol = ctx.resolveSymbol(id: card.id) else { continue }
                            var c = ctx
                            c.opacity = ghost == 0 ? 1 : 0.42 - Double(ghost) * 0.06
                            c.draw(symbol, at: CGPoint(x: p.x + layout.cardW / 2, y: p.y + layout.cardH / 2))
                        }
                    }
                } symbols: {
                    ForEach(Card.deck) { card in CardFace(card: card, width: layout.cardW).tag(card.id) }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Kings first, one from each foundation in turn, down to the aces.
    static let order: [Card] = (1...13).reversed().flatMap { rank in Suit.allCases.map { Card(suit: $0, rank: rank) } }

    /// Simple physics from a fixed, per-card launch, so the same win always looks the same.
    static func position(card: Card, from: CGPoint, time: Double, size: CGSize, cardH: CGFloat) -> CGPoint? {
        var rng = SplitMix64(state: UInt64(card.id + 1) &* 7919)
        let speed = 150 + Double(rng.next() % 220)
        let vx0 = (rng.next() % 3 == 0 ? 1 : -1) * speed
        var p = CGPoint(x: from.x, y: from.y)
        var v = CGVector(dx: vx0, dy: -Double(rng.next() % 300))
        let dt = 1.0 / 60, floor = size.height - cardH
        var elapsed = 0.0
        while elapsed < time {
            p.x += v.dx * dt
            v.dy += 2200 * dt
            p.y += v.dy * dt
            if p.y > floor {
                p.y = floor
                v.dy = -v.dy * 0.72
            }
            elapsed += dt
        }
        return p.x < -cardH || p.x > size.width + cardH ? nil : p
    }
}

struct WinPanel: View {
    @ObservedObject var model: GameModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "crown.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0xF5CF62), Color(hex: 0xC8902B)], startPoint: .top, endPoint: .bottom))
            VStack(spacing: 4) {
                Text("You won").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Game \(model.number), \(model.board.draw.title.lowercased())").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                figure("Score", "\(model.finalScore)")
                Divider().frame(height: 34)
                figure("Time", model.seconds.clock)
                Divider().frame(height: 34)
                figure("Moves", "\(model.board.moves)")
                Divider().frame(height: 34)
                figure("Streak", "\(model.stats.streak)")
            }
            HStack(spacing: 10) {
                Button("Replay Deal") { withAnimation(.snappy) { model.restart() } }
                    .controlSize(.large)
                Button("New Game") { withAnimation(.snappy) { model.newGame() } }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0x23824C))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 26)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sheets

struct StatsView: View {
    @ObservedObject var model: GameModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 18) {
            Text("Statistics").font(.system(size: 20, weight: .bold, design: .rounded))
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tile("Played", "\(s.played)")
                    tile("Won", "\(s.won)")
                    tile("Win rate", s.played == 0 ? "None" : "\(Int((s.winRate * 100).rounded()))%")
                }
                GridRow {
                    tile("Current streak", "\(s.streak)")
                    tile("Best streak", "\(s.bestStreak)")
                    tile("Best time", s.bestTime?.clock ?? "None")
                }
            }
            HStack {
                Text("Best score \(s.bestScore)").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset…") { confirmReset = true }.disabled(s == Stats())
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .confirmationDialog("Reset all statistics?", isPresented: $confirmReset) {
            Button("Reset Statistics", role: .destructive) { model.resetStats() }
        } message: {
            Text("Games, wins, streaks and best results go back to zero. The game in progress is not affected.")
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
    }
}

struct ChooserView: View {
    @ObservedObject var model: GameModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var number: Int? { Int(text.trimmingCharacters(in: .whitespaces)).flatMap { (1...999_999).contains($0) ? $0 : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a game").font(.system(size: 18, weight: .bold, design: .rounded))
            Text("Every number from 1 to 999999 deals the same cards every time, so you can replay a game or share it.")
                .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Game number", text: $text).textFieldStyle(.roundedBorder).font(.system(size: 14).monospacedDigit())
                .onSubmit(deal)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Deal", action: deal).keyboardShortcut(.defaultAction).disabled(number == nil)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear { text = "\(model.number)" }
    }

    private func deal() {
        guard let number else { return }
        withAnimation(.snappy) { model.deal(number, countLoss: true) }
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject var model: GameModel

    var body: some View {
        Form {
            Picker("Table", selection: $model.felt) {
                ForEach(Felt.allCases) { felt in
                    Label {
                        Text(felt.title)
                    } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(felt.colors.0)
                    }
                    .tag(felt)
                }
            }
            Picker("Stock", selection: $model.drawMode) {
                ForEach(DrawMode.allCases, id: \.self) { Text($0 == .one ? "Draw one card" : "Draw three cards").tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
    }
}
