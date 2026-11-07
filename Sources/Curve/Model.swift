import AppKit
import Kit
import SwiftUI

// MARK: - Viewport

/// What part of the plane the canvas shows: a centre and one scale (units per point) for both axes, so circles stay round.
struct Viewport: Codable, Equatable {
    var centerX: Double = 0
    var centerY: Double = 0
    var scale: Double = 20.0 / 700

    static let minScale = 1e-9
    static let maxScale = 1e7

    func worldX(_ sx: Double, width: Double) -> Double { centerX + (sx - width / 2) * scale }
    func worldY(_ sy: Double, height: Double) -> Double { centerY + (height / 2 - sy) * scale }
    func screenX(_ x: Double, width: Double) -> Double { (x - centerX) / scale + width / 2 }
    func screenY(_ y: Double, height: Double) -> Double { height / 2 - (y - centerY) / scale }

    /// Zooms by `factor` (above 1 zooms in) keeping the world point under `anchor` fixed.
    mutating func zoom(by factor: Double, at anchor: CGPoint, in size: CGSize) {
        let wx = worldX(anchor.x, width: size.width), wy = worldY(anchor.y, height: size.height)
        scale = min(max(scale / factor, Viewport.minScale), Viewport.maxScale)
        centerX = wx - (anchor.x - size.width / 2) * scale
        centerY = wy - (size.height / 2 - anchor.y) * scale
    }

    mutating func pan(by delta: CGSize) {
        centerX -= delta.width * scale
        centerY += delta.height * scale
    }

    /// The default view: the origin in the middle and x from -10 to 10.
    static func standard(width: Double) -> Viewport {
        Viewport(centerX: 0, centerY: 0, scale: 20 / max(width, 100))
    }
}

// MARK: - Plotting

enum Plotter {
    static let maxDepth = 10

    /// The curve as screen polylines, sampled every point and refined where it turns steep.
    /// Undefined stretches and jumps (tan at pi/2, 1/x at 0, floor) break the line instead of joining it.
    static func polylines(_ node: Node, vars: Variables, viewport: Viewport, size: CGSize) -> [[CGPoint]] {
        let w = Double(size.width), h = Double(size.height)
        guard w > 1, h > 1 else { return [] }
        var vars = vars
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []

        func sample(_ sx: Double) -> Double? {
            vars.x = viewport.worldX(sx, width: w)
            let y = node.evaluate(vars)
            guard y.isFinite else { return nil }
            return min(max(viewport.screenY(y, height: h), -1e5), 1e5)
        }
        func flush() {
            if current.count > 1 { lines.append(current) }
            current = []
        }
        func start(_ x: Double, _ y: Double) {
            flush()
            current = [CGPoint(x: x, y: y)]
        }
        // On entry the current line ends at (x0, y0) whenever y0 exists; on exit it ends at (x1, y1) whenever y1 does.
        func connect(_ x0: Double, _ y0: Double?, _ x1: Double, _ y1: Double?, _ depth: Int) {
            switch (y0, y1) {
            case (nil, nil):
                return
            case (let a?, let b?):
                let offSameSide = (a < -2 && b < -2) || (a > h + 2 && b > h + 2)
                if abs(b - a) <= 2 || offSameSide {
                    current.append(CGPoint(x: x1, y: b))
                } else if depth >= maxDepth {
                    if abs(b - a) > 8 { start(x1, b) } else { current.append(CGPoint(x: x1, y: b)) }
                } else {
                    let xm = (x0 + x1) / 2, ym = sample(xm)
                    connect(x0, y0, xm, ym, depth + 1)
                    connect(xm, ym, x1, y1, depth + 1)
                }
            default:
                if depth >= maxDepth {
                    if let b = y1 { start(x1, b) } else { flush() }
                } else {
                    let xm = (x0 + x1) / 2, ym = sample(xm)
                    connect(x0, y0, xm, ym, depth + 1)
                    connect(xm, ym, x1, y1, depth + 1)
                }
            }
        }

        var x0 = -1.0
        var y0 = sample(x0)
        if let y0 { current = [CGPoint(x: x0, y: y0)] }
        while x0 < w + 1 {
            let x1 = x0 + 1
            let y1 = sample(x1)
            connect(x0, y0, x1, y1, 0)
            x0 = x1
            y0 = y1
        }
        flush()
        return lines
    }
}

// MARK: - Roots and intersections

struct KeyPoint: Equatable, Identifiable {
    enum Kind: Equatable { case root, intersection }
    let kind: Kind
    let x: Double
    let y: Double
    /// Indexes into the plotted curves: one for a root, two for an intersection.
    let curves: [Int]
    var id: String { "\(kind)-\(curves)-\(x)" }
}

enum Analysis {
    static let samples = 600
    static let limitPerCurve = 40

    /// Approximate zeros of `g` on [lo, hi]: sign changes refined by bisection, plus touching zeros (like x^2 at 0)
    /// found as small local minima of |g|. Jumps through zero (tan, floor) are rejected because |g| stays large there.
    static func zeros(of g: (Double) -> Double, from lo: Double, to hi: Double, tolerance: Double) -> [Double] {
        guard hi > lo else { return [] }
        let n = samples
        let dx = (hi - lo) / Double(n)
        var xs = [Double](repeating: 0, count: n + 1)
        var ys = [Double](repeating: .nan, count: n + 1)
        for i in 0...n {
            xs[i] = lo + Double(i) * dx
            ys[i] = g(xs[i])
        }
        var found: [Double] = []
        for i in 0..<n {
            let a = ys[i], b = ys[i + 1]
            guard a.isFinite, b.isFinite else { continue }
            if a == 0 {
                found.append(xs[i])
            } else if a * b < 0 {
                var l = xs[i], r = xs[i + 1], gl = a
                for _ in 0..<80 {
                    let m = (l + r) / 2
                    guard m != l, m != r else { break }
                    let gm = g(m)
                    if !gm.isFinite { break }
                    if (gm < 0) == (gl < 0) { l = m; gl = gm } else { r = m }
                }
                let root = (l + r) / 2
                let value = g(root)
                if value.isFinite, abs(value) <= tolerance { found.append(root) }
            } else if i > 0, ys[i - 1].isFinite, abs(a) <= abs(ys[i - 1]), abs(a) <= abs(b), abs(a) < tolerance * 50,
                      (ys[i - 1] > 0) == (a > 0) {
                // Golden section search for the minimum of |g| around a touching point.
                var l = xs[i - 1], r = xs[i + 1]
                let ratio = (sqrt(5.0) - 1) / 2
                for _ in 0..<90 {
                    let m1 = r - ratio * (r - l), m2 = l + ratio * (r - l)
                    if abs(g(m1)) < abs(g(m2)) { r = m2 } else { l = m1 }
                }
                let x = (l + r) / 2
                let value = g(x)
                if value.isFinite, abs(value) < 1e-9 * max(1, tolerance) { found.append(x) }
            }
        }
        if abs(ys[n]) == 0 { found.append(xs[n]) }
        // Merge near duplicates, which appear when a zero sits on a sample.
        var merged: [Double] = []
        for x in found.sorted() where merged.last.map({ abs(x - $0) > dx * 0.5 }) ?? true {
            merged.append(x)
        }
        return merged
    }

    static func keyPoints(_ nodes: [Node], vars: Variables, from lo: Double, to hi: Double, tolerance: Double) -> [KeyPoint] {
        var points: [KeyPoint] = []
        func value(_ node: Node, _ x: Double) -> Double {
            var v = vars
            v.x = x
            return node.evaluate(v)
        }
        for (i, f) in nodes.enumerated() {
            let roots = zeros(of: { value(f, $0) }, from: lo, to: hi, tolerance: tolerance)
            if roots.count <= limitPerCurve {
                points += roots.map { KeyPoint(kind: .root, x: $0, y: 0, curves: [i]) }
            }
        }
        for i in nodes.indices {
            for j in nodes.indices where j > i {
                let f = nodes[i], g = nodes[j]
                // Identical curves meet everywhere; there is nothing to mark.
                if f == g { continue }
                let hits = zeros(of: { value(f, $0) - value(g, $0) }, from: lo, to: hi, tolerance: tolerance)
                if hits.count <= limitPerCurve {
                    points += hits.map { KeyPoint(kind: .intersection, x: $0, y: value(f, $0), curves: [i, j]) }
                }
            }
        }
        return points
    }
}

// MARK: - Formatting

enum Format {
    /// A value for the trace and point labels: up to four decimals, scientific when tiny or huge.
    static func value(_ v: Double) -> String {
        guard v.isFinite else { return "undefined" }
        let a = abs(v)
        if a != 0 && (a >= 1e7 || a < 1e-4) {
            return minus(String(format: "%.3e", v))
        }
        var s = String(format: "%.4f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" { s = "0" }
        return minus(s)
    }

    /// An axis label for a multiple of `step`, with as many decimals as the step needs.
    static func tick(_ v: Double, step: Double) -> String {
        if abs(v) < step * 1e-6 { return "0" }
        if step >= 1e6 || step < 1e-4 { return minus(String(format: "%.0e", v)) }
        let decimals = max(0, Int(-floor(log10(step) + 1e-9)))
        return minus(String(format: "%.\(decimals)f", v))
    }

    /// Typographic minus for negative numbers.
    static func minus(_ s: String) -> String { s.replacingOccurrences(of: "-", with: "\u{2212}") }

    /// Grid spacing in world units: 1, 2 or 5 times a power of ten, at least `minPoints` apart on screen.
    static func gridStep(scale: Double, minPoints: Double) -> Double {
        let raw = scale * minPoints
        let power = pow(10, floor(log10(raw)))
        for m in [1.0, 2, 5, 10] where m * power >= raw { return m * power }
        return 10 * power
    }
}

// MARK: - Model

struct GraphFunction: Identifiable, Codable, Equatable {
    var id = UUID()
    var expression: String
    var color: Int
    var isVisible = true
}

enum Palette {
    static let names = ["Pink", "Blue", "Green", "Orange", "Violet", "Teal", "Red", "Graphite"]
    static let hex: [UInt32] = [0xF0308F, 0x2F7CF6, 0x12A56E, 0xF08A0C, 0x8B5CF6, 0x0EA5C6, 0xE5383B, 0x6B7280]
    static func color(_ i: Int) -> Color { Color(nsColor: rgb(hex[((i % hex.count) + hex.count) % hex.count])) }
}

enum Theme {
    static let accent = LinearGradient(colors: [Color(nsColor: rgb(0xFF4FA3)), Color(nsColor: rgb(0x7C5CFF))],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    static let pink = Color(nsColor: rgb(0xF0308F))
}

struct SavedState: Codable {
    var functions: [GraphFunction]
    var parameters: [String: Double]
    var viewport: Viewport
    var showGrid: Bool
    var showPoints: Bool
}

/// One plotted curve, ready to draw.
struct Curve {
    let index: Int
    let node: Node
    let color: Color
}

@MainActor
final class CurveModel: ObservableObject {
    @Published var functions: [GraphFunction] { didSet { if functions != oldValue { compile(); save() } } }
    @Published var parameters: [Parameter: Double] = [.a: 1, .b: 1, .c: 1] { didSet { save() } }
    @Published var viewport = Viewport() { didSet { save() } }
    @Published var showGrid = true { didSet { save() } }
    @Published var showPoints = true { didSet { save() } }
    @Published private(set) var results: [UUID: Result<Node, ParseError>] = [:]
    @Published var exported: URL?
    @Published var canvasSize = CGSize(width: 700, height: 500)
    /// A fixed trace position for the website snapshot.
    var demoHover: CGPoint?
    weak var undoManager: UndoManager?
    private let persists: Bool

    static let parameterRange: ClosedRange<Double> = -5...5

    init(functions: [GraphFunction]? = nil, persists: Bool = !Desktop.isSnapshot) {
        self.persists = persists
        let saved = persists ? Storage.load(SavedState.self, app: "Curve", file: "graphs.json") : nil
        self.functions = functions ?? saved?.functions ?? [
            GraphFunction(expression: "sin(x)", color: 0),
            GraphFunction(expression: "x^2/4 - 1", color: 1),
        ]
        if let saved {
            for p in Parameter.allCases { parameters[p] = saved.parameters[p.rawValue] ?? 1 }
            viewport = saved.viewport
            showGrid = saved.showGrid
            showPoints = saved.showPoints
        }
        compile()
        if persists {
            // Flush a save still waiting when the app quits.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingSave, !pending.isCancelled else { return }
                    pending.cancel()
                    self.write()
                }
            }
        }
    }

    static var demo: CurveModel {
        let model = CurveModel(functions: [
            GraphFunction(expression: "2sin(x)", color: 0),
            GraphFunction(expression: "a x^2 - 3", color: 1),
            GraphFunction(expression: "tan(x/4) + b", color: 4),
        ], persists: false)
        model.parameters = [.a: 0.25, .b: 0.5, .c: 1]
        model.viewport = Viewport(centerX: 0, centerY: 0.2, scale: 16.0 / 760)
        model.canvasSize = CGSize(width: 760, height: 608)
        model.demoHover = CGPoint(x: 470, y: 200)
        return model
    }

    var variables: Variables {
        Variables(x: 0, a: parameters[.a] ?? 1, b: parameters[.b] ?? 1, c: parameters[.c] ?? 1)
    }

    /// Visible, valid functions in list order.
    var curves: [Curve] {
        functions.enumerated().compactMap { i, f in
            guard f.isVisible, case .success(let node) = results[f.id] else { return nil }
            return Curve(index: i, node: node, color: Palette.color(f.color))
        }
    }

    /// Sliders appear for the parameters some function uses.
    var usedParameters: [Parameter] {
        let used = results.values.reduce(into: Set<Parameter>()) { set, result in
            if case .success(let node) = result { set.formUnion(node.parameters) }
        }
        return Parameter.allCases.filter(used.contains)
    }

    func error(for f: GraphFunction) -> String? {
        guard !f.expression.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if case .failure(let e) = results[f.id] { return e.message }
        return nil
    }

    private func compile() {
        var next: [UUID: Result<Node, ParseError>] = [:]
        for f in functions {
            do { next[f.id] = .success(try Parser.parse(f.expression)) } catch let e as ParseError {
                next[f.id] = .failure(e)
            } catch {
                next[f.id] = .failure(ParseError(message: "Cannot read this"))
            }
        }
        results = next
    }

    private var pendingSave: DispatchWorkItem?

    /// Writes at most twice a second, so dragging the view does not hit the disk on every frame.
    private func save() {
        guard persists else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.write() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func write() {
        let state = SavedState(functions: functions,
                               parameters: Dictionary(uniqueKeysWithValues: parameters.map { ($0.key.rawValue, $0.value) }),
                               viewport: viewport, showGrid: showGrid, showPoints: showPoints)
        Storage.save(state, app: "Curve", file: "graphs.json")
    }

    // MARK: Editing with undo

    private func change(_ name: String, _ body: () -> Void) {
        let before = functions
        body()
        registerUndo(name, restoring: before)
    }

    private func registerUndo(_ name: String, restoring old: [GraphFunction]) {
        guard let undoManager else { return }
        let current = functions
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.functions = old
                model.registerUndo(name, restoring: current)
            }
        }
        undoManager.setActionName(name)
    }

    @discardableResult
    func addFunction() -> UUID {
        let used = Set(functions.map(\.color))
        let color = (0..<Palette.hex.count).first { !used.contains($0) } ?? functions.count % Palette.hex.count
        let f = GraphFunction(expression: "", color: color)
        change("Add Function") { functions.append(f) }
        return f.id
    }

    func remove(_ id: UUID) {
        change("Delete Function") { functions.removeAll { $0.id == id } }
    }

    func toggleVisibility(_ id: UUID) {
        guard let i = functions.firstIndex(where: { $0.id == id }) else { return }
        change(functions[i].isVisible ? "Hide Function" : "Show Function") { functions[i].isVisible.toggle() }
    }

    func setColor(_ color: Int, for id: UUID) {
        guard let i = functions.firstIndex(where: { $0.id == id }) else { return }
        change("Change Colour") { functions[i].color = color }
    }

    // MARK: View

    func zoom(by factor: Double, at anchor: CGPoint? = nil) {
        let center = anchor ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        withAnimation(anchor == nil ? .snappy(duration: 0.25) : nil) {
            viewport.zoom(by: factor, at: center, in: canvasSize)
        }
    }

    func resetView() {
        withAnimation(.snappy(duration: 0.3)) { viewport = .standard(width: canvasSize.width) }
    }

    func keyPoints(for curves: [Curve]) -> [KeyPoint] {
        guard showPoints, !curves.isEmpty else { return [] }
        let lo = viewport.worldX(0, width: canvasSize.width), hi = viewport.worldX(canvasSize.width, width: canvasSize.width)
        return Analysis.keyPoints(curves.map(\.node), vars: variables, from: lo, to: hi, tolerance: viewport.scale * 0.5)
    }

    // MARK: Export

    func renderPNG() -> Data? {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colorScheme: ColorScheme = dark ? .dark : .light
        let curves = self.curves
        let view = GraphCanvas(viewport: viewport, curves: curves, vars: variables, points: keyPoints(for: curves),
                               showGrid: showGrid, hover: nil, highlighted: nil)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = canvasSize
        return rep.representation(using: .png, properties: [:])
    }

    func exportPNG() {
        guard !Desktop.isSnapshot, let data = renderPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Curve.png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            withAnimation(.snappy) { exported = url }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                if self?.exported == url { withAnimation(.snappy) { self?.exported = nil } }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func copyImage() {
        guard !Desktop.isSnapshot, let data = renderPNG() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
    }
}
