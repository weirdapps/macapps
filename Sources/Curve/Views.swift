import AppKit
import Kit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CurveModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 380)
        } detail: {
            GraphPane(model: model)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { model.zoom(by: 0.5) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                            .help("Zoom out")
                        Button { model.zoom(by: 2) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                            .help("Zoom in")
                        Button { model.resetView() } label: { Label("Reset View", systemImage: "scope") }
                            .help("Centre the origin and show x from -10 to 10")
                        Button { model.exportPNG() } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                            .help("Export the graph as a PNG image")
                    }
                }
        }
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: CurveModel
    @FocusState private var focused: UUID?

    var body: some View {
        List {
            Section("Functions") {
                ForEach($model.functions) { $f in
                    FunctionRow(function: $f, model: model, focused: $focused)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                }
                Button {
                    focused = model.addFunction()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                        Text("Add Function").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.pink)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                .padding(.leading, 6)
                .listRowSeparator(.hidden)
            }
            Section("Sliders") {
                let used = model.usedParameters
                if used.isEmpty {
                    Text("Use a, b or c in a function to get a slider for it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(used) { p in
                        ParameterRow(name: p.rawValue, value: Binding(
                            get: { model.parameters[p] ?? 1 },
                            set: { model.parameters[p] = $0 }))
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Drag to pan, scroll or pinch to zoom", systemImage: "hand.draw")
                Label("Hover a curve to trace it", systemImage: "scope")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .curveFocusFunction)) { note in
            if let id = note.object as? UUID { focused = id }
        }
        .toolbar {
            ToolbarItem {
                Button { focused = model.addFunction() } label: { Label("Add Function", systemImage: "plus") }
                    .help("Add a function")
            }
        }
    }
}

extension Notification.Name {
    static let curveFocusFunction = Notification.Name("CurveFocusFunction")
}

struct FunctionRow: View {
    @Binding var function: GraphFunction
    @ObservedObject var model: CurveModel
    var focused: FocusState<UUID?>.Binding
    @State private var hovering = false

    var body: some View {
        let color = Palette.color(function.color)
        let error = model.error(for: function)
        HStack(alignment: .top, spacing: 10) {
            Button { model.toggleVisibility(function.id) } label: {
                ZStack {
                    Circle().strokeBorder(color, lineWidth: 2.5)
                    if function.isVisible { Circle().fill(color.gradient).padding(1) }
                }
                .frame(width: 16, height: 16)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .help(function.isVisible ? "Hide this curve" : "Show this curve")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("y =")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("", text: $function.expression, prompt: Text("x^2 + 1"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .focused(focused, equals: function.id)
                        .opacity(function.isVisible ? 1 : 0.5)
                }
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
            Button { model.remove(function.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 3)
            .opacity(hovering ? 1 : 0)
            .help("Delete this function")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(hovering ? 0.55 : 0.3))
            if error != nil {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.red.opacity(0.35))
            }
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: error)
        .contextMenu {
            Picker("Colour", selection: Binding(get: { function.color }, set: { model.setColor($0, for: function.id) })) {
                ForEach(Palette.names.indices, id: \.self) { i in
                    Text(Palette.names[i]).tag(i)
                }
            }
            Button(function.isVisible ? "Hide" : "Show") { model.toggleVisibility(function.id) }
            Divider()
            Button("Delete", role: .destructive) { model.remove(function.id) }
        }
    }
}

struct ParameterRow: View {
    let name: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .frame(width: 16)
            Slider(value: $value, in: CurveModel.parameterRange)
                .controlSize(.small)
                .tint(Theme.pink)
            TextField("", value: $value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: 54)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
    }
}

// MARK: - Graph pane

struct GraphPane: View {
    @ObservedObject var model: CurveModel
    @State private var hover: CGPoint?

    init(model: CurveModel) {
        self.model = model
        _hover = State(initialValue: model.demoHover)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let curves = model.curves
            let points = model.keyPoints(for: curves)
            let highlighted = hover.flatMap { nearest(points, to: $0, size: size) }
            ZStack(alignment: .topLeading) {
                GraphCanvas(viewport: model.viewport, curves: curves, vars: model.variables, points: points,
                            showGrid: model.showGrid, hover: hover, highlighted: highlighted)
                InteractionView(
                    onHover: { if !Desktop.isSnapshot { hover = $0 } },
                    onDrag: { model.viewport.pan(by: $0) },
                    onZoom: { model.zoom(by: $0, at: $1) },
                    onDoubleClick: { model.zoom(by: 2, at: $0) })
                if let hover, !curves.isEmpty {
                    TraceCard(x: model.viewport.worldX(hover.x, width: size.width), curves: curves,
                              functions: model.functions, vars: model.variables)
                        .padding(14)
                        .allowsHitTesting(false)
                }
                if let p = highlighted {
                    PointLabel(point: p, functions: model.functions)
                        .position(x: min(max(model.viewport.screenX(p.x, width: size.width), 90), size.width - 90),
                                  y: max(model.viewport.screenY(p.y, height: size.height) - 24, 16))
                        .allowsHitTesting(false)
                }
                if !curves.isEmpty {
                    // Uses the points already found for this frame rather than searching again.
                    Text(summary(points))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            .onAppear { model.canvasSize = size }
            .onChange(of: size) { _, value in model.canvasSize = value }
        }
        .overlay(alignment: .bottom) {
            if let url = model.exported {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Exported \(url.lastPathComponent)").font(.system(size: 12, weight: .medium))
                    Button("Show in Finder") { revealInFinder([url]) }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if model.functions.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to plot", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                } description: {
                    Text("Add a function like sin(x) or x^2 - 2 and it appears here.")
                } actions: {
                    Button("Add Function") {
                        let id = model.addFunction()
                        NotificationCenter.default.post(name: .curveFocusFunction, object: id)
                    }
                }
                .padding(30)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .fixedSize()
            }
        }
    }

    private func summary(_ points: [KeyPoint]) -> String {
        guard model.showPoints else { return "Drag to pan, scroll or pinch to zoom" }
        let roots = points.filter { $0.kind == .root }.count
        let hits = points.count - roots
        return "\(roots) \(roots == 1 ? "root" : "roots") and \(hits) \(hits == 1 ? "intersection" : "intersections") in view"
    }

    private func nearest(_ points: [KeyPoint], to hover: CGPoint, size: CGSize) -> KeyPoint? {
        let v = model.viewport
        return points
            .map { p in (p, hypot(v.screenX(p.x, width: size.width) - hover.x, v.screenY(p.y, height: size.height) - hover.y)) }
            .filter { $0.1 < 12 }
            .min { $0.1 < $1.1 }?.0
    }
}

struct TraceCard: View {
    let x: Double
    let curves: [Curve]
    let functions: [GraphFunction]
    let vars: Variables

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("x").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text(Format.value(x)).font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            }
            Divider().opacity(0.6)
            ForEach(curves, id: \.index) { c in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(c.color).frame(width: 10, height: 3)
                    Text(functions[c.index].expression)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 10)
                    Text(Format.value(value(c)))
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                }
            }
        }
        .padding(12)
        .frame(width: 230)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private func value(_ c: Curve) -> Double {
        var v = vars
        v.x = x
        return c.node.evaluate(v)
    }
}

struct PointLabel: View {
    let point: KeyPoint
    let functions: [GraphFunction]

    var body: some View {
        HStack(spacing: 6) {
            Text(point.kind == .root ? "Root" : "Intersection").font(.system(size: 11, weight: .semibold))
            Text("(\(Format.value(point.x)), \(Format.value(point.y)))")
                .font(.system(size: 11, design: .monospaced))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .fixedSize()
    }
}

// MARK: - Canvas

/// Grid, axes, labels, curves, roots and intersections, plus the trace when hovering. Also renders the PNG export.
struct GraphCanvas: View {
    let viewport: Viewport
    let curves: [Curve]
    let vars: Variables
    let points: [KeyPoint]
    let showGrid: Bool
    let hover: CGPoint?
    let highlighted: KeyPoint?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let dark = scheme == .dark
            let ink = dark ? Color.white : Color.black
            let background = dark ? Color(white: 0.105) : Color.white
            let w = Double(size.width), h = Double(size.height)
            let v = viewport
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

            let step = Format.gridStep(scale: v.scale, minPoints: 90)
            let mantissa = (step / pow(10, floor(log10(step)))).rounded()
            let minor = step / (mantissa == 2 ? 4 : 5)
            let x0 = v.worldX(0, width: w), x1 = v.worldX(w, width: w)
            let y0 = v.worldY(h, height: h), y1 = v.worldY(0, height: h)

            func lines(every s: Double, color: Color) {
                var path = Path()
                for x in Format.multiples(of: s, from: x0, to: x1) {
                    let sx = v.screenX(x, width: w).rounded() + 0.5
                    path.move(to: CGPoint(x: sx, y: 0))
                    path.addLine(to: CGPoint(x: sx, y: h))
                }
                for y in Format.multiples(of: s, from: y0, to: y1) {
                    let sy = v.screenY(y, height: h).rounded() + 0.5
                    path.move(to: CGPoint(x: 0, y: sy))
                    path.addLine(to: CGPoint(x: w, y: sy))
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1)
            }
            if showGrid {
                lines(every: minor, color: ink.opacity(dark ? 0.05 : 0.035))
                lines(every: step, color: ink.opacity(dark ? 0.11 : 0.085))
            }

            // Axes, and where they sit (pinned to an edge when off screen) for the labels.
            let axisX = v.screenX(0, width: w), axisY = v.screenY(0, height: h)
            var axes = Path()
            if axisY >= 0 && axisY <= h {
                axes.move(to: CGPoint(x: 0, y: axisY.rounded() + 0.5))
                axes.addLine(to: CGPoint(x: w, y: axisY.rounded() + 0.5))
            }
            if axisX >= 0 && axisX <= w {
                axes.move(to: CGPoint(x: axisX.rounded() + 0.5, y: 0))
                axes.addLine(to: CGPoint(x: axisX.rounded() + 0.5, y: h))
            }
            ctx.stroke(axes, with: .color(ink.opacity(0.42)), lineWidth: 1)

            let labelColor = ink.opacity(0.5)
            let font = Font.system(size: 10.5, weight: .medium).monospacedDigit()
            let labelY = min(max(axisY + 5, 4), h - 18)
            for x in Format.multiples(of: step, from: x0, to: x1) {
                if abs(x) > step * 1e-6 {
                    let sx = v.screenX(x, width: w)
                    if sx > 14 && sx < w - 14 {
                        ctx.draw(Text(Format.tick(x, step: step)).font(font).foregroundColor(labelColor),
                                 at: CGPoint(x: sx, y: labelY), anchor: .top)
                    }
                }
            }
            let labelX = min(max(axisX - 6, 34), w - 4)
            for y in Format.multiples(of: step, from: y0, to: y1) {
                if abs(y) > step * 1e-6 {
                    let sy = v.screenY(y, height: h)
                    if sy > 10 && sy < h - 10 {
                        ctx.draw(Text(Format.tick(y, step: step)).font(font).foregroundColor(labelColor),
                                 at: CGPoint(x: labelX, y: sy), anchor: .trailing)
                    }
                }
            }
            if axisX > 10 && axisX < w - 10 && axisY > 4 && axisY < h - 18 {
                ctx.draw(Text("0").font(font).foregroundColor(labelColor), at: CGPoint(x: axisX - 6, y: axisY + 5),
                         anchor: .topTrailing)
            }

            // Curves, each over a soft glow of its own colour.
            for c in curves {
                var path = Path()
                for line in Plotter.polylines(c.node, vars: vars, viewport: v, size: size) {
                    path.addLines(line)
                }
                ctx.stroke(path, with: .color(c.color.opacity(0.16)),
                           style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(c.color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }

            // Trace line and the point on every curve under the pointer.
            if let hover, !curves.isEmpty {
                var line = Path()
                line.move(to: CGPoint(x: hover.x, y: 0))
                line.addLine(to: CGPoint(x: hover.x, y: h))
                ctx.stroke(line, with: .color(ink.opacity(0.3)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                var tv = vars
                tv.x = v.worldX(hover.x, width: w)
                for c in curves {
                    let value = c.node.evaluate(tv)
                    guard value.isFinite else { continue }
                    let sy = v.screenY(value, height: h)
                    guard sy > -10 && sy < h + 10 else { continue }
                    let dot = CGRect(x: hover.x - 5.5, y: sy - 5.5, width: 11, height: 11)
                    ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(background))
                    ctx.fill(Path(ellipseIn: dot), with: .color(c.color))
                }
            }

            // Roots and intersections.
            for p in points {
                let sx = v.screenX(p.x, width: w), sy = v.screenY(p.y, height: h)
                guard sx > -6, sx < w + 6, sy > -6, sy < h + 6 else { continue }
                let big = p == highlighted
                let r = big ? 6.5 : 4.5
                let rect = CGRect(x: sx - r, y: sy - r, width: r * 2, height: r * 2)
                let color = curves.first { $0.index == p.curves[0] }?.color ?? ink
                if p.kind == .root {
                    ctx.fill(Path(ellipseIn: rect), with: .color(background))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 2.2)
                } else {
                    ctx.fill(Path(ellipseIn: rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(background))
                    ctx.fill(Path(ellipseIn: rect), with: .color(ink.opacity(0.78)))
                }
            }
        }
    }
}

// MARK: - Mouse and trackpad

/// A transparent AppKit view over the canvas for what SwiftUI does not offer on the Mac:
/// hover tracking, drag to pan, scroll wheel and pinch to zoom around the pointer.
struct InteractionView: NSViewRepresentable {
    var onHover: (CGPoint?) -> Void
    var onDrag: (CGSize) -> Void
    var onZoom: (Double, CGPoint) -> Void
    var onDoubleClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        update(view)
        return view
    }

    func updateNSView(_ view: InputView, context: Context) { update(view) }

    private func update(_ view: InputView) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onZoom = onZoom
        view.onDoubleClick = onDoubleClick
    }

    final class InputView: NSView {
        var onHover: (CGPoint?) -> Void = { _ in }
        var onDrag: (CGSize) -> Void = { _ in }
        var onZoom: (Double, CGPoint) -> Void = { _, _ in }
        var onDoubleClick: (CGPoint) -> Void = { _ in }
        private var dragging = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                                                  .inVisibleRect, .cursorUpdate], owner: self))
        }

        private func location(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func cursorUpdate(with event: NSEvent) { (dragging ? NSCursor.closedHand : NSCursor.crosshair).set() }
        override func mouseMoved(with event: NSEvent) { onHover(location(event)) }
        override func mouseEntered(with event: NSEvent) { onHover(location(event)) }
        override func mouseExited(with event: NSEvent) { if !dragging { onHover(nil) } }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 { onDoubleClick(location(event)); return }
            dragging = true
            NSCursor.closedHand.set()
        }

        override func mouseDragged(with event: NSEvent) {
            onDrag(CGSize(width: event.deltaX, height: event.deltaY))
            onHover(location(event))
        }

        override func mouseUp(with event: NSEvent) {
            dragging = false
            NSCursor.crosshair.set()
            if !bounds.contains(location(event)) { onHover(nil) }
        }

        override func scrollWheel(with event: NSEvent) {
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return }
            let factor = exp(dy * (event.hasPreciseScrollingDeltas ? 0.006 : 0.08))
            onZoom(factor, location(event))
            onHover(location(event))
        }

        override func magnify(with event: NSEvent) {
            onZoom(1 + event.magnification, location(event))
        }
    }
}
