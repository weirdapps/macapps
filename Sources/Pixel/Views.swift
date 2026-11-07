import AppKit
import Kit
import SwiftUI

enum Theme {
    static let colors = [Color(nsColor: rgb(0xF04BB3)), Color(nsColor: rgb(0x8A1FB0))]
    static let accent = LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = Color(nsColor: rgb(0xC233B4))
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var document: PixelDocument
    @StateObject private var editor: EditorState
    let title: String
    @Environment(\.undoManager) private var undoManager

    init(document: PixelDocument, editor: EditorState? = nil, title: String = "Untitled") {
        self.document = document
        self.title = title
        _editor = StateObject(wrappedValue: editor ?? EditorState(document: document))
    }

    var body: some View {
        HStack(spacing: 0) {
            ToolRail(editor: editor)
            Divider()
            VStack(spacing: 0) {
                CanvasArea(document: document, editor: editor)
                Divider()
                StatusBar(document: document, editor: editor)
            }
            Divider()
            Inspector(document: document, editor: editor)
                .frame(width: 240)
        }
        .frame(minWidth: 780, minHeight: 520)
        .toolbar {
            ToolbarItemGroup {
                ControlGroup {
                    Button { editor.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .help("Zoom out (⌘-)")
                    Button { editor.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                        .help("Zoom in (⌘+)")
                }
                Button { editor.importPNG() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Import a small PNG (⇧⌘I)")
                Button { editor.showingExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export a PNG at any scale (⇧⌘E)")
            }
        }
        .focusedSceneObject(editor)
        .onAppear { editor.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in editor.undoManager = new }
        .sheet(isPresented: $editor.showingExport) {
            ExportSheet(document: document, editor: editor, title: title)
        }
    }

    static var demo: ContentView {
        let document = PixelDocument(image: .demoCat)
        let editor = EditorState(document: document, persists: false)
        editor.color = Palette.presets[9]
        editor.recents = [0xFFA300, 0x2B1B3A, 0xFF77A8, 0xFFF1E8, 0xAB5236, 0x29ADFF].map { RGBA($0) }
        editor.mirror = true
        editor.zoom = 28
        editor.hover = Point(x: 2, y: 14)
        return ContentView(document: document, editor: editor, title: "Tabby")
    }
}

// MARK: - Tools

struct ToolRail: View {
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Tool.allCases) { tool in
                RailButton(symbol: tool.symbol, isOn: editor.tool == tool,
                           help: "\(tool.name) (\(String(tool.key).uppercased()))") {
                    withAnimation(.snappy(duration: 0.18)) { editor.select(tool) }
                }
            }
            Divider().frame(width: 28).padding(.vertical, 6)
            RailButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", isOn: editor.mirror, isToggle: true,
                       help: "Mirror drawing across the middle (M)") {
                withAnimation(.snappy(duration: 0.18)) { editor.mirror.toggle() }
            }
            RailButton(symbol: "grid", isOn: editor.showGrid, isToggle: true, help: "Show grid (⌘')") {
                withAnimation(.snappy(duration: 0.18)) { editor.showGrid.toggle() }
            }
            Spacer()
        }
        .padding(.vertical, 12)
        .frame(width: 56)
        .background(.background.opacity(0.6))
    }
}

struct RailButton: View {
    let symbol: String
    let isOn: Bool
    var isToggle = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 36, height: 36)
                .foregroundStyle(foreground)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(background)
                        .shadow(color: isOn && !isToggle ? Theme.colors[1].opacity(0.35) : .clear, radius: 3, y: 1.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// A selected tool is filled with the accent; a switched-on toggle is only tinted, so the two never look alike.
    private var foreground: AnyShapeStyle {
        if isOn { return isToggle ? AnyShapeStyle(Theme.tint) : AnyShapeStyle(.white) }
        return AnyShapeStyle(.secondary)
    }

    private var background: AnyShapeStyle {
        if isOn { return isToggle ? AnyShapeStyle(Theme.tint.opacity(hovering ? 0.2 : 0.13)) : AnyShapeStyle(Theme.accent) }
        return AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0))
    }
}

// MARK: - Canvas

struct CanvasArea: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var editor: EditorState
    @State private var targeted = false
    @State private var pinchBase: CGFloat?

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                PixelCanvas(document: document, editor: editor)
                    .padding(32)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .onAppear { editor.fitZoom = EditorState.fit(document.image, in: geo.size) }
            .onChange(of: geo.size) { _, size in editor.fitZoom = EditorState.fit(document.image, in: size) }
            .onChange(of: document.image.width * 100 + document.image.height) { _, _ in
                editor.fitZoom = EditorState.fit(document.image, in: geo.size)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            editor.importImage(at: url)
            return true
        } isTargeted: { targeted = $0 }
        .simultaneousGesture(MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? editor.pixelSize
                pinchBase = base
                editor.zoom = max(2, min(64, (base * value.magnification).rounded()))
            }
            .onEnded { _ in pinchBase = nil })
    }
}

struct PixelCanvas: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var editor: EditorState
    @State private var cursorPushed = false

    var body: some View {
        let image = document.image
        let z = editor.pixelSize
        Canvas(rendersAsynchronously: false) { ctx, _ in
            draw(image, z: z, in: &ctx)
        }
        .frame(width: CGFloat(image.width) * z, height: CGFloat(image.height) * z)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = point(value.location, z: z)
                editor.hover = image.contains(p) ? p : nil
                if editor.isStroking {
                    editor.move(to: p)
                } else {
                    editor.begin(at: p, option: NSEvent.modifierFlags.contains(.option))
                }
            }
            .onEnded { _ in editor.end() })
        .onContinuousHover { phase in
            guard !Desktop.isSnapshot else { return }
            switch phase {
            case .active(let location):
                let p = point(location, z: z)
                editor.hover = image.contains(p) ? p : nil
                if !cursorPushed { NSCursor.crosshair.push(); cursorPushed = true }
            case .ended:
                editor.hover = nil
                if cursorPushed { NSCursor.pop(); cursorPushed = false }
            }
        }
        .accessibilityLabel("Canvas, \(image.width) by \(image.height) pixels")
    }

    private func point(_ location: CGPoint, z: CGFloat) -> Point {
        Point(x: Int((location.x / z).rounded(.down)), y: Int((location.y / z).rounded(.down)))
    }

    private func draw(_ image: PixelImage, z: CGFloat, in ctx: inout GraphicsContext) {
        let full = CGRect(x: 0, y: 0, width: CGFloat(image.width) * z, height: CGFloat(image.height) * z)

        // Transparency checkerboard.
        ctx.fill(Path(full), with: .color(.white))
        let check: CGFloat = z >= 16 ? z / 2 : max(4, z)
        var checks = Path()
        var y: CGFloat = 0, row = 0
        while y < full.height {
            var x: CGFloat = row % 2 == 0 ? 0 : check
            while x < full.width {
                checks.addRect(CGRect(x: x, y: y, width: min(check, full.width - x), height: min(check, full.height - y)))
                x += check * 2
            }
            y += check
            row += 1
        }
        ctx.fill(checks, with: .color(Color(white: 0.9)))

        // Pixels, one path per colour.
        var byColor: [RGBA: Path] = [:]
        for py in 0..<image.height {
            for px in 0..<image.width {
                let c = image[px, py]
                guard !c.isClear else { continue }
                byColor[c, default: Path()].addRect(CGRect(x: CGFloat(px) * z, y: CGFloat(py) * z, width: z, height: z))
            }
        }
        for (c, path) in byColor { ctx.fill(path, with: .color(c.color)) }

        if editor.showGrid && z >= 6 {
            var grid = Path()
            for i in 1..<image.width { grid.addRect(CGRect(x: CGFloat(i) * z - 0.25, y: 0, width: 0.5, height: full.height)) }
            for i in 1..<image.height { grid.addRect(CGRect(x: 0, y: CGFloat(i) * z - 0.25, width: full.width, height: 0.5)) }
            ctx.fill(grid, with: .color(Color(white: 0.35, opacity: 0.35)))
        }

        if editor.mirror {
            var axis = Path()
            axis.move(to: CGPoint(x: full.midX, y: 0))
            axis.addLine(to: CGPoint(x: full.midX, y: full.height))
            ctx.stroke(axis, with: .color(Theme.tint.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }

        if let hover = editor.hover, !editor.isStroking || editor.tool == .eyedropper {
            var spots = [hover]
            if editor.mirror && editor.tool != .eyedropper { spots.append(image.mirrored(hover)) }
            for p in spots {
                let r = CGRect(x: CGFloat(p.x) * z, y: CGFloat(p.y) * z, width: z, height: z)
                if [.pencil, .line, .rectangle].contains(editor.tool) {
                    ctx.fill(Path(r), with: .color(editor.color.color.opacity(0.55)))
                }
                ctx.stroke(Path(r.insetBy(dx: 0.75, dy: 0.75)), with: .color(Theme.tint), lineWidth: 1.5)
            }
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var editor: EditorState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Colour") {
                HStack(spacing: 12) {
                    Swatch(color: editor.color, size: 44, radius: 10, selected: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editor.color.display)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                            .contentTransition(.numericText())
                        Text("Current colour").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    ColorPicker("Custom colour", selection: editor.colorBinding, supportsOpacity: true)
                        .labelsHidden()
                        .focusable(false)
                        .help("Pick any colour")
                }
            }

            section("Palette") {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<4, id: \.self) { row in
                        GridRow {
                            ForEach(0..<4, id: \.self) { col in
                                let c = Palette.presets[row * 4 + col]
                                swatchButton(c, size: 46)
                            }
                        }
                    }
                }
            }

            section("Recent") {
                if editor.recents.isEmpty {
                    Text("Colours you draw with collect here.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(height: 22, alignment: .leading)
                } else {
                    HStack(spacing: 4) {
                        ForEach(editor.recents, id: \.self) { c in swatchButton(c, size: 22) }
                    }
                }
            }

            section("Preview") {
                HStack(alignment: .center, spacing: 12) {
                    PreviewImage(image: document.image, scale: max(1, 96 / max(document.image.width, document.image.height)))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(document.image.width) × \(document.image.height) px")
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        Menu("Canvas size") {
                            ForEach(PixelImage.presetSizes, id: \.self) { s in
                                Button("\(s) × \(s)") { editor.resize(to: s) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .focusable(false)
                        .fixedSize()
                        .font(.system(size: 12))
                    }
                }
            }

            Spacer(minLength: 0)

            Button { editor.showingExport = true } label: {
                Label("Export PNG", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(Theme.colors))
            .focusable(false)
            .help("Export a PNG at any scale (⇧⌘E)")
        }
        .padding(16)
    }

    private func swatchButton(_ c: RGBA, size: CGFloat) -> some View {
        Button { withAnimation(.snappy(duration: 0.15)) { editor.pick(c) } } label: {
            Swatch(color: c, size: size, radius: size > 30 ? 8 : 5, selected: c == editor.color)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(c.display)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct Swatch: View {
    let color: RGBA
    let size: CGFloat
    let radius: CGFloat
    let selected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.color)
            .background(Checker(cell: size / 4).clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 1))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2.5)
                        .padding(-4)
                }
            }
            .frame(width: size, height: size)
    }
}

struct Checker: View {
    let cell: CGFloat

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var p = Path()
            var y: CGFloat = 0, row = 0
            while y < size.height {
                var x: CGFloat = row % 2 == 0 ? 0 : cell
                while x < size.width {
                    p.addRect(CGRect(x: x, y: y, width: cell, height: cell))
                    x += cell * 2
                }
                y += cell
                row += 1
            }
            ctx.fill(p, with: .color(Color(white: 0.86)))
        }
    }
}

struct PreviewImage: View {
    let image: PixelImage
    let scale: Int

    var body: some View {
        Group {
            if let cg = image.cgImage() {
                Image(decorative: cg, scale: 1)
                    .resizable()
                    .interpolation(.none)
            }
        }
        .frame(width: CGFloat(image.width * scale), height: CGFloat(image.height * scale))
        .background(Checker(cell: 4))
        .overlay(Rectangle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var editor: EditorState

    var body: some View {
        HStack(spacing: 14) {
            Label(editor.tool.name, systemImage: editor.tool.symbol)
            if editor.mirror { Label("Mirror", systemImage: "arrow.left.and.right") }
            Text(editor.hover.map { "x \($0.x), y \($0.y)" } ?? "Off canvas")
                .monospacedDigit()
                .frame(minWidth: 80, alignment: .leading)
            Spacer()
            if let notice = editor.notice {
                HStack(spacing: 6) {
                    Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(Theme.tint))
                    Text(notice.text).lineLimit(1).truncationMode(.middle)
                    if let url = notice.url {
                        Button("Show in Finder") { revealInFinder([url]) }.buttonStyle(.link)
                    }
                    Button { editor.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text(verbatim: "\(Int(editor.pixelSize * 100))%").monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: editor.notice)
    }
}

// MARK: - Export

struct ExportSheet: View {
    @ObservedObject var document: PixelDocument
    @ObservedObject var editor: EditorState
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let image = document.image
        VStack(spacing: 18) {
            Text("Export PNG").font(.system(size: 17, weight: .semibold, design: .rounded))
            PreviewImage(image: image, scale: max(1, min(10, 160 / max(image.width, image.height))))
                .frame(height: 170)
            Picker("Scale", selection: $editor.exportScale) {
                ForEach(EditorState.exportScales, id: \.self) { Text("\($0)×").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("\(image.width * editor.exportScale) × \(image.height * editor.exportScale) pixels, transparent background")
                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { editor.export(named: title) }
                    .keyboardShortcut(.defaultAction)
                    .tint(Theme.tint)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}
