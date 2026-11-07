import AppKit
import Kit
import SwiftUI

enum Theme {
    static let mint = Color(red: 0.43, green: 0.97, blue: 0.75)
    static let green = Color(red: 0.08, green: 0.55, blue: 0.41)
    static let accent = LinearGradient(colors: [mint, green], startPoint: .top, endPoint: .bottom)
    /// The frame around the board and the board itself, dark in both appearances like a lit display.
    static let frame = Color(red: 0.027, green: 0.075, blue: 0.059)
    static let field = Color(red: 0.047, green: 0.122, blue: 0.098)
    static let line = Color(red: 0.42, green: 1, blue: 0.78).opacity(0.07)
}

struct ContentView: View {
    @Bindable var model: LifeModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 340)
        } detail: {
            VStack(spacing: 0) {
                BoardView(model: model)
                    .padding([.horizontal, .top], 14)
                    .padding(.bottom, 4)
                StatusBar(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .toolbar { toolbar }
        }
        .frame(minWidth: 780, minHeight: 500)
        .onExitCommand { model.cancelPlacing() }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleRunning()
            } label: {
                Label(model.isRunning ? "Pause" : "Play", systemImage: model.isRunning ? "pause.fill" : "play.fill")
            }
            .help(model.isRunning ? "Pause (Space)" : "Play (Space)")
            Button { model.step() } label: { Label("Step", systemImage: "forward.frame.fill") }
                .help("Advance one generation (Right Arrow)")
                .disabled(model.isRunning)
            Menu {
                Picker("Density", selection: $model.density) {
                    ForEach(LifeModel.densities, id: \.self) { Text("\(Int($0 * 100))% alive").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Random Fill", systemImage: "dice")
            } primaryAction: {
                model.randomize()
            }
            .help("Fill the board with random cells (\u{2318}R); hold for density")
            Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                .help("Clear the board (\u{2318}\u{232B})")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(selection: Binding(get: { model.size }, set: { model.resize(to: $0) })) {
                ForEach(GridSize.all) { Text($0.label).tag($0) }
            } label: {
                Label("Board Size", systemImage: "square.grid.3x3")
            }
            .pickerStyle(.menu)
            .help("Board size")
            Toggle(isOn: $model.wrap) {
                Label("Wrap Around Edges", systemImage: "arrow.triangle.2.circlepath")
            }
            .help(model.wrap ? "Edges wrap around, like a torus (\u{2325}\u{2318}E)" : "Edges are walls (\u{2325}\u{2318}E)")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Bindable var model: LifeModel

    var body: some View {
        List(selection: $model.selectedPattern) {
            ForEach(Library.categories, id: \.self) { category in
                Section(category) {
                    ForEach(Library.entries.filter { $0.category == category }) { entry in
                        PatternRow(entry: entry).tag(entry.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct PatternRow: View {
    let entry: LibraryEntry

    var body: some View {
        HStack(spacing: 10) {
            PatternThumbnail(pattern: entry.pattern)
                .frame(width: 44, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.pattern.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(entry.note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PatternThumbnail: View {
    let pattern: Pattern

    var body: some View {
        Canvas { ctx, size in
            let inset: CGFloat = 4
            let c = min((size.width - inset * 2) / CGFloat(pattern.width), (size.height - inset * 2) / CGFloat(pattern.height), 5)
            let ox = (size.width - c * CGFloat(pattern.width)) / 2, oy = (size.height - c * CGFloat(pattern.height)) / 2
            var path = Path()
            for cell in pattern.cells {
                let r = CGRect(x: ox + CGFloat(cell.x) * c, y: oy + CGFloat(cell.y) * c, width: c, height: c)
                path.addRect(c >= 3 ? r.insetBy(dx: 0.4, dy: 0.4) : r)
            }
            ctx.fill(path, with: .color(Theme.mint))
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }
}

// MARK: - Board

struct BoardLayout {
    let rect: CGRect
    let cell: CGFloat
    let columns: Int
    let rows: Int

    init(size: CGSize, columns: Int, rows: Int, scale: CGFloat) {
        self.columns = columns
        self.rows = rows
        let inset: CGFloat = 12
        let w = max(1, size.width - inset * 2), h = max(1, size.height - inset * 2)
        var c = min(w / CGFloat(columns), h / CGFloat(rows))
        // Whole device pixels per cell keep every cell the same size.
        if c * scale >= 2 { c = (c * scale).rounded(.down) / scale }
        cell = c
        let bw = c * CGFloat(columns), bh = c * CGFloat(rows)
        rect = CGRect(x: ((size.width - bw) / 2 * scale).rounded() / scale, y: ((size.height - bh) / 2 * scale).rounded() / scale,
                      width: bw, height: bh)
    }

    func cell(at p: CGPoint) -> Cell? {
        guard rect.contains(p) else { return nil }
        return Cell(x: min(columns - 1, Int((p.x - rect.minX) / cell)), y: min(rows - 1, Int((p.y - rect.minY) / cell)))
    }

    func frame(of c: Cell) -> CGRect {
        CGRect(x: rect.minX + CGFloat(c.x) * cell, y: rect.minY + CGFloat(c.y) * cell, width: cell, height: cell)
    }
}

struct BoardView: View {
    @Bindable var model: LifeModel
    @Environment(\.displayScale) private var scale
    @State private var paintValue: Bool?
    @State private var lastCell: Cell?

    var body: some View {
        GeometryReader { geo in
            let layout = BoardLayout(size: geo.size, columns: model.board.grid.width, rows: model.board.grid.height, scale: scale)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.frame)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: layout.rect.width + 20, height: layout.rect.height + 20)
                    .offset(x: layout.rect.minX - 10, y: layout.rect.minY - 10)
                Rectangle().fill(Theme.field)
                    .frame(width: layout.rect.width, height: layout.rect.height)
                    .offset(x: layout.rect.minX, y: layout.rect.minY)
                if model.showGrid && layout.cell * scale >= 8 {
                    GridLines(layout: layout, scale: scale)
                }
                if let image = model.image {
                    let cells = Image(decorative: image, scale: 1).interpolation(.none).resizable()
                        .frame(width: layout.rect.width, height: layout.rect.height)
                        .offset(x: layout.rect.minX, y: layout.rect.minY)
                    cells.blur(radius: max(1.5, layout.cell * 0.9)).opacity(0.75).blendMode(.plusLighter)
                    cells
                }
                if let pattern = model.placing, let hover = model.hover {
                    Ghost(pattern: pattern, origin: model.placementOrigin(for: pattern, at: hover), layout: layout)
                }
                Color.clear
                    .frame(width: layout.rect.width, height: layout.rect.height)
                    .overlay(alignment: .top) {
                        if let pattern = model.placing { PlacingHint(name: pattern.name).padding(.top, 12).transition(.opacity) }
                    }
                    .overlay {
                        if model.population == 0 && model.placing == nil { EmptyBoard().allowsHitTesting(false).transition(.opacity) }
                    }
                    .overlay(alignment: .bottom) {
                        if let notice = model.notice {
                            NoticeView(notice: notice).padding(.bottom, 14).transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .offset(x: layout.rect.minX, y: layout.rect.minY)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(layout))
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): if model.placing != nil && !Desktop.isSnapshot { model.hover = layout.cell(at: p) }
                case .ended: if !Desktop.isSnapshot { model.hover = nil }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.placing == nil)
        .animation(.snappy(duration: 0.25), value: model.notice)
        .animation(.snappy(duration: 0.25), value: model.population == 0)
    }

    private func drag(_ layout: BoardLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let cell = layout.cell(at: value.location) else { return }
                if model.placing != nil {
                    model.hover = cell
                    return
                }
                if let paint = paintValue, let last = lastCell {
                    guard cell != last else { return }
                    model.paint(line(from: last, to: cell), alive: paint)
                } else {
                    let paint = !model.board.grid[cell.x, cell.y]
                    paintValue = paint
                    model.checkpoint(paint ? "Draw" : "Erase")
                    model.paint([cell], alive: paint)
                }
                lastCell = cell
            }
            .onEnded { value in
                if model.placing != nil, let cell = layout.cell(at: value.location) { model.stamp(at: cell) }
                paintValue = nil
                lastCell = nil
            }
    }

    /// Every cell on the segment from `a` to `b` (Bresenham), so a fast stroke leaves no gaps.
    private func line(from a: Cell, to b: Cell) -> [Cell] {
        var cells: [Cell] = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y), sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            cells.append(Cell(x: x, y: y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return cells
    }
}

struct GridLines: View {
    let layout: BoardLayout
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            let r = layout.rect
            for i in 1..<layout.columns {
                let x = r.minX + CGFloat(i) * layout.cell
                path.move(to: CGPoint(x: x, y: r.minY))
                path.addLine(to: CGPoint(x: x, y: r.maxY))
            }
            for j in 1..<layout.rows {
                let y = r.minY + CGFloat(j) * layout.cell
                path.move(to: CGPoint(x: r.minX, y: y))
                path.addLine(to: CGPoint(x: r.maxX, y: y))
            }
            ctx.stroke(path, with: .color(Theme.line), lineWidth: 1 / scale)
        }
        .allowsHitTesting(false)
    }
}

struct Ghost: View {
    let pattern: Pattern
    let origin: Cell
    let layout: BoardLayout

    var body: some View {
        Canvas { ctx, _ in
            var cells = Path()
            for c in pattern.cells {
                let f = layout.frame(of: Cell(x: origin.x + c.x, y: origin.y + c.y))
                cells.addRect(f.insetBy(dx: layout.cell * 0.08, dy: layout.cell * 0.08))
            }
            let box = layout.frame(of: origin).union(layout.frame(of: Cell(x: origin.x + pattern.width - 1, y: origin.y + pattern.height - 1)))
                .insetBy(dx: -layout.cell * 0.5, dy: -layout.cell * 0.5)
            ctx.fill(Path(roundedRect: box, cornerRadius: max(3, layout.cell * 0.6)), with: .color(.white.opacity(0.05)))
            ctx.stroke(Path(roundedRect: box, cornerRadius: max(3, layout.cell * 0.6)), with: .color(.white.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.fill(cells, with: .color(Theme.mint.opacity(0.6)))
        }
        .allowsHitTesting(false)
    }
}

struct PlacingHint: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow.click").foregroundStyle(Theme.mint)
            Text("Click to place \(name)").fontWeight(.medium)
            Divider().frame(height: 12).overlay(.white.opacity(0.3))
            key("R")
            Text("rotate").foregroundStyle(.white.opacity(0.6))
            key("esc")
            Text("done").foregroundStyle(.white.opacity(0.6))
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .allowsHitTesting(false)
    }

    private func key(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.white.opacity(0.16)))
    }
}

struct EmptyBoard: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.3x3.fill")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("An empty world")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Draw cells with the mouse, pick a pattern from the sidebar, or press \u{2318}R for a random soup.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(30)
    }
}

struct NoticeView: View {
    let notice: Notice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Color.orange : Theme.mint)
            Text(notice.text).lineLimit(2)
            if let url = notice.url {
                Button("Show in Finder") { revealInFinder([url]) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.mint)
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.7)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxWidth: 520)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Bindable var model: LifeModel

    var body: some View {
        HStack(spacing: 22) {
            stat("Generation", model.board.generation)
            stat("Population", model.population)
            Sparkline(values: model.history)
                .frame(width: 130, height: 28)
                .help("Population over the last \(model.history.count) generations")
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Image(systemName: "tortoise.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Slider(value: $model.speed, in: 1...60)
                    .controlSize(.small)
                    .tint(Theme.green)
                    .frame(width: 110)
                Image(systemName: "hare.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("\(Int(model.speed))/s")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .leading)
            }
            .help("Speed in generations per second (\u{2318}[ and \u{2318}])")
            Menu {
                Picker("Rule", selection: $model.rule) {
                    ForEach(Rule.presets, id: \.rule) { Text("\($0.name)  \($0.rule.notation)").tag($0.rule) }
                }
                .pickerStyle(.inline)
            } label: {
                chip("function", model.rule.notation)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rule: \(model.rule.name)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value.formatted())
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(minWidth: 86, alignment: .leading)
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
            .fixedSize()
    }
}

struct Sparkline: View {
    let values: [Int]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let maxV = values.max(), maxV > 0 else {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: size.height - 1))
                base.addLine(to: CGPoint(x: size.width, y: size.height - 1))
                ctx.stroke(base, with: .color(.secondary.opacity(0.4)), lineWidth: 1)
                return
            }
            let minV = values.min() ?? 0
            let span = max(1, Double(maxV - minV))
            func point(_ i: Int) -> CGPoint {
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: 2 + (size.height - 4) * (1 - CGFloat(Double(values[i] - minV) / span)))
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [Theme.green.opacity(0.28), Theme.green.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(Theme.green), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
