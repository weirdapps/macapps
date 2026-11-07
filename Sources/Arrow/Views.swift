import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(red: 1, green: 0x4D / 255, blue: 0x4D / 255)
    static let bottom = Color(red: 0xB3 / 255, green: 0x12 / 255, blue: 0x2E / 255)
    static let accent = Color(red: 0xE8 / 255, green: 0x2A / 255, blue: 0x3C / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let selection = NSColor(srgbRed: 0x0A / 255, green: 0x84 / 255, blue: 1, alpha: 1)
}

struct ContentView: View {
    @ObservedObject var board: Board
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if board.image != nil {
                    CanvasView(board: board)
                } else {
                    DropZone(symbol: "photo.badge.arrow.down", title: "Drop a screenshot",
                             message: "Drop or paste an image to mark it up with arrows, boxes, text and numbered steps.",
                             button: "Open Image…", tint: Theme.accent, isTargeted: dropTargeted) { board.openPanel() }
                }
                if let toast = board.toast {
                    VStack {
                        Spacer()
                        ToastView(toast: toast)
                    }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            StyleBar(board: board)
        }
        .frame(minWidth: 780, minHeight: 480)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { board.handleDrop($0) }
        .toolbar { ArrowToolbar(board: board) }
        .navigationSubtitle(board.image == nil ? "" : board.imageName)
        .onAppear { board.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in board.undoManager = manager }
    }
}

struct ArrowToolbar: ToolbarContent {
    @ObservedObject var board: Board

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { board.openPanel() } label: { Label("Open", systemImage: "photo.badge.plus") }
                .help("Open an image (⌘O)")
        }
        ToolbarItem(placement: .principal) {
            Picker("Tool", selection: $board.tool) {
                ForEach(Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol).labelStyle(.iconOnly)
                        .help("\(tool.title) (\(String(tool.key).uppercased()))")
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .disabled(board.image == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { board.copyImage() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy the marked up image (⌘C)")
                .disabled(board.image == nil)
            Button { board.exportPanel() } label: { Label("Export PNG", systemImage: "square.and.arrow.up") }
                .help("Export as PNG (⇧⌘E)")
                .disabled(board.image == nil)
        }
    }
}

// MARK: - Canvas

/// Maps between image pixels and the view: the visible region, fitted and centred with a margin.
struct CanvasLayout {
    let region: CGRect
    let scale: CGFloat
    let origin: CGPoint

    init(region: CGRect, size: CGSize, pixelScale: CGFloat, margin: CGFloat = 28) {
        self.region = region
        let fit = min((size.width - margin * 2) / max(region.width, 1), (size.height - margin * 2) / max(region.height, 1))
        scale = max(0.01, min(fit, 1 / pixelScale))
        origin = CGPoint(x: ((size.width - region.width * scale) / 2).rounded(), y: ((size.height - region.height * scale) / 2).rounded())
    }

    var imageRect: CGRect { CGRect(x: origin.x, y: origin.y, width: region.width * scale, height: region.height * scale) }

    func toImage(_ v: CGPoint) -> CGPoint {
        CGPoint(x: (v.x - origin.x) / scale + region.minX, y: (v.y - origin.y) / scale + region.minY)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - region.minX) * scale + origin.x, y: (p.y - region.minY) * scale + origin.y)
    }

    func toView(_ r: CGRect) -> CGRect {
        let a = toView(r.origin)
        return CGRect(x: a.x, y: a.y, width: r.width * scale, height: r.height * scale)
    }
}

struct CanvasView: View {
    @ObservedObject var board: Board
    @State private var moved = false
    @State private var pressed = false
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let layout = CanvasLayout(region: board.region, size: geo.size, pixelScale: board.pixelScale)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, layout) }
                    .contentShape(Rectangle())
                    .gesture(drag(layout))
                    .onContinuousHover { phase in
                        if case .active(let v) = phase { cursor(at: layout.toImage(v), layout).set() } else { NSCursor.arrow.set() }
                    }
                if let a = board.annotation(board.editingID) {
                    TextEditorOverlay(board: board, annotation: a, layout: layout)
                }
                if board.tool == .crop {
                    CropBar(board: board).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 16)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
            guard board.selection != nil, board.editingID == nil else { return .ignored }
            let step: CGFloat = (press.modifiers.contains(.shift) ? 10 : 1) * board.pixelScale
            switch press.key {
            case .upArrow: board.nudge(0, -step)
            case .downArrow: board.nudge(0, step)
            case .leftArrow: board.nudge(-step, 0)
            default: board.nudge(step, 0)
            }
            return .handled
        }
    }

    private func drag(_ layout: CanvasLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let shift = NSEvent.modifierFlags.contains(.shift)
                if !pressed {
                    pressed = true
                    moved = false
                    focused = true
                    board.pointerDown(layout.toImage(value.startLocation), tolerance: 6 / layout.scale)
                }
                if hypot(value.translation.width, value.translation.height) > 2 { moved = true }
                if moved { board.pointerDragged(layout.toImage(value.location), shift: shift) }
            }
            .onEnded { _ in
                pressed = false
                board.pointerUp(moved: moved)
            }
    }

    private func cursor(at p: CGPoint, _ layout: CanvasLayout) -> NSCursor {
        let t = 6 / layout.scale
        if board.tool == .crop { return .crosshair }
        if let a = board.selected, Geometry.handleHit(a, p, t * 1.5) != nil { return .crosshair }
        if board.hitTest(p, tolerance: t) != nil { return .openHand }
        switch board.tool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return layout.imageRect.contains(layout.toView(p)) ? .crosshair : .arrow
        }
    }

    private func draw(_ ctx: GraphicsContext, _ layout: CanvasLayout) {
        guard let image = board.image else { return }
        let frame = layout.imageRect
        // Paper shadow under the image.
        var plate = ctx
        plate.addFilter(.shadow(color: .black.opacity(0.28), radius: 14, y: 5))
        plate.fill(Path(frame), with: .color(.white))
        ctx.withCGContext { cg in
            cg.saveGState()
            cg.clip(to: frame)
            cg.translateBy(x: layout.origin.x, y: layout.origin.y)
            cg.scaleBy(x: layout.scale, y: layout.scale)
            cg.translateBy(x: -layout.region.minX, y: -layout.region.minY)
            Renderer.draw(image: image, annotations: board.annotations, effects: board.effects, numbers: board.stepNumbers,
                          hiding: board.editingID, shadowScale: layout.scale * 2, in: cg)
            cg.restoreGState()
        }
        if board.tool == .crop {
            drawCrop(ctx, layout)
        } else if let a = board.selected, a.id != board.editingID {
            drawSelection(ctx, a, layout)
        }
    }

    private func drawSelection(_ ctx: GraphicsContext, _ a: Annotation, _ layout: CanvasLayout) {
        let blue = Color(nsColor: Theme.selection)
        let handles = Geometry.handles(a)
        if handles.isEmpty || a.kind == .redact {
            let r = layout.toView(Geometry.bounds(a)).insetBy(dx: -5, dy: -5)
            ctx.stroke(Path(roundedRect: r, cornerRadius: 4), with: .color(blue), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        for (_, p) in handles {
            let v = layout.toView(p)
            let dot = Path(ellipseIn: CGRect(x: v.x - 6, y: v.y - 6, width: 12, height: 12))
            var lifted = ctx
            lifted.addFilter(.shadow(color: .black.opacity(0.3), radius: 2, y: 1))
            lifted.fill(dot, with: .color(.white))
            ctx.stroke(dot, with: .color(blue), lineWidth: 2)
        }
    }

    private func drawCrop(_ ctx: GraphicsContext, _ layout: CanvasLayout) {
        let r = layout.toView(board.pendingCrop ?? board.fullRect)
        var dim = Path(layout.imageRect)
        dim.addRect(r)
        ctx.fill(dim, with: .color(.black.opacity(0.5)), style: FillStyle(eoFill: true))
        var grid = Path()
        for i in 1...2 {
            let f = CGFloat(i) / 3
            grid.move(to: CGPoint(x: r.minX + r.width * f, y: r.minY))
            grid.addLine(to: CGPoint(x: r.minX + r.width * f, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: r.minY + r.height * f))
            grid.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * f))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.45)), lineWidth: 0.75)
        ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
        let arm = min(22, r.width / 2, r.height / 2)
        var corners = Path()
        for (c, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                            (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
            corners.move(to: CGPoint(x: c.x + arm * sx, y: c.y))
            corners.addLine(to: c)
            corners.addLine(to: CGPoint(x: c.x, y: c.y + arm * sy))
        }
        ctx.stroke(corners, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
}

/// Live text entry, laid exactly over the mark it edits.
struct TextEditorOverlay: View {
    @ObservedObject var board: Board
    let annotation: Annotation
    let layout: CanvasLayout
    @FocusState private var focused: Bool

    var body: some View {
        let size = Geometry.fontSize(annotation.width) * layout.scale
        let origin = layout.toView(annotation.start)
        TextField("Text", text: Binding(get: { annotation.text }, set: { board.setText($0) }))
            .textFieldStyle(.plain)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(annotation.color.color)
            .shadow(color: Color(nsColor: annotation.color.contrast.ns), radius: 1.5)
            .frame(minWidth: max(80, size * 3), alignment: .leading)
            .fixedSize()
            .focused($focused)
            .onSubmit { board.endEditing() }
            .onExitCommand { board.endEditing() }
            .offset(x: origin.x - 2, y: origin.y)
            .onAppear { focused = true }
    }
}

struct CropBar: View {
    @ObservedObject var board: Board

    var body: some View {
        let r = board.pendingCrop ?? board.fullRect
        HStack(spacing: 12) {
            Image(systemName: "crop").foregroundStyle(.secondary)
            Text("\(Int(r.width.rounded())) × \(Int(r.height.rounded())) px")
                .font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                .contentTransition(.numericText())
            if board.crop != nil {
                Button("Reset") { board.resetCrop() }.help("Show the whole image again")
            }
            Button("Cancel") { board.escape() }.help("Leave the crop as it was (Esc)")
            Button("Crop") { board.applyCrop() }.buttonStyle(.borderedProminent).tint(Theme.accent).help("Apply the crop (Return)")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.reveal == nil ? "checkmark.circle.fill" : "square.and.arrow.down.fill").foregroundStyle(Theme.gradient)
            Text(toast.message).font(.system(size: 12.5, weight: .medium))
            if let url = toast.reveal {
                Button("Reveal in Finder") { revealInFinder([url]) }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

// MARK: - Style bar

struct StyleBar: View {
    @ObservedObject var board: Board

    private var showsRedaction: Bool { board.tool == .redact || board.selected?.kind == .redact }

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(RGBA.palette, id: \.self) { c in
                    Swatch(color: c, selected: board.color == c) { board.setColor(c) }
                }
                ColorPicker("Custom color", selection: Binding(get: { board.color.color }, set: { board.setColor(RGBA(NSColor($0))) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .help("Pick any color")
            }
            Divider().frame(height: 18)
            HStack(spacing: 8) {
                Image(systemName: "lineweight").foregroundStyle(.secondary).help("Stroke width")
                Slider(value: Binding(get: { board.width }, set: { board.setWidth($0.rounded()) }), in: 1...10) { editing in
                    if editing { board.beginChange() } else { board.commitChange("Change Width") }
                }
                .controlSize(.small)
                .frame(width: 110)
                Text("\(Int(board.width))").font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
            }
            if showsRedaction {
                Divider().frame(height: 18)
                Picker("Redaction", selection: Binding(get: { board.redactStyle }, set: { board.setRedactStyle($0) })) {
                    ForEach(RedactStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
            }
            Spacer(minLength: 8)
            Text(info).font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .disabled(board.image == nil)
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: showsRedaction)
    }

    private var info: String {
        guard board.image != nil else { return "No image" }
        let r = board.crop ?? board.fullRect
        let marks = board.annotations.count
        let size = "\(Int(r.width)) × \(Int(r.height)) px"
        return (board.crop != nil ? "Cropped to " + size : size) + " · \(marks) mark" + (marks == 1 ? "" : "s")
    }
}

struct Swatch: View {
    let color: RGBA
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color.gradient)
                .overlay(Circle().strokeBorder(.black.opacity(color.luminance > 0.85 ? 0.22 : 0.08), lineWidth: 1))
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.55) : .clear, lineWidth: 2))
                .scaleEffect(hovering && !selected ? 1.12 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.15), value: selected)
        .help(Self.name(color))
    }

    static func name(_ c: RGBA) -> String {
        ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"][RGBA.palette.firstIndex(of: c) ?? 0]
    }
}
