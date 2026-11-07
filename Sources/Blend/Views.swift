import AppKit
import Kit
import SwiftUI

enum Theme {
    static let pink = Color(red: 1, green: 0x8F / 255, blue: 0xB1 / 255)
    static let violet = Color(red: 0x7A / 255, green: 0x6C / 255, blue: 1)
    static let accent = LinearGradient(colors: [pink, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.1)
}

/// Routes Edit menu commands to a focused text field, which would otherwise lose them to the gradient.
@MainActor
enum TextEditing {
    static var active: Bool { (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true }

    /// Sends a standard responder action (`undo:`, `redo:`, `deleteToBeginningOfLine:`) to the focused field.
    static func send(_ action: String) {
        NSApp.sendAction(Selector(action), to: nil, from: nil)
    }
}

// MARK: - Rendering

/// Fills its frame with the gradient, the same way the CSS output draws it.
struct GradientFill: View {
    let gradient: BlendGradient

    var body: some View {
        GeometryReader { geo in
            let stops = gradient.swiftUIStops
            let center = UnitPoint(x: gradient.centerX, y: gradient.centerY)
            switch gradient.kind {
            case .linear:
                let (start, end) = gradient.linearPoints(size: geo.size)
                Rectangle().fill(LinearGradient(stops: stops, startPoint: start, endPoint: end))
            case .radial:
                Rectangle().fill(EllipticalGradient(stops: stops, center: center, startRadiusFraction: 0,
                                                    endRadiusFraction: gradient.radialFraction))
            case .conic:
                Rectangle().fill(AngularGradient(stops: stops, center: center, angle: .degrees(gradient.angle - 90)))
            }
        }
    }
}

/// A transparency checkerboard, shown under gradients with translucent stops.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 10
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0...Int(size.height / cell) {
                for col in 0...Int(size.width / cell) where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                             with: .color(Color(white: 0.88)))
                }
            }
        }
    }
}

struct Swatch: View {
    let gradient: BlendGradient
    var radius: CGFloat = 6

    var body: some View {
        ZStack {
            if gradient.stops.contains(where: { $0.color.a < 0.999 }) { Checkerboard() }
            GradientFill(gradient: gradient)
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.black.opacity(0.1)))
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: BlendModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Editor(model: model)
        }
        .frame(minWidth: 860, minHeight: 600)
        .toolbar { BlendToolbar(model: model) }
        .sheet(isPresented: $model.showingExport) { ExportSheet(model: model) }
        .navigationTitle(model.current.name.isEmpty ? "Untitled" : model.current.name)
    }
}

struct BlendToolbar: ToolbarContent {
    @ObservedObject var model: BlendModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Type", selection: Binding(get: { model.current.kind }, set: { k in model.edit { $0.kind = k } })) {
                ForEach(GradientKind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleOnly)
            .fixedSize()
            .help("Gradient type")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.randomize() } label: { Label("Random", systemImage: "dice") }
                .help("Random gradient (⌘R)")
            Button { model.saveToLibrary() } label: { Label("Save to Library", systemImage: "square.and.arrow.down.on.square") }
                .help("Save to library (⌘S)")
                .disabled(model.isInLibrary)
            Button { model.copy(.css) } label: { Label("Copy CSS", systemImage: "curlybraces") }
                .help("Copy CSS (⇧⌘C)")
            Button { model.showingExport = true } label: { Label("Export PNG", systemImage: "photo.badge.arrow.down") }
                .help("Export PNG (⇧⌘E)")
                .disabled(model.exporting)
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: BlendModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("Library") {
                if model.library.isEmpty {
                    Label("Press ⌘S to keep the gradient you are editing", systemImage: "tray")
                        .font(.callout).foregroundStyle(.secondary)
                        .selectionDisabled()
                }
                ForEach(model.library) { g in
                    SidebarRow(gradient: g).tag(SidebarItem.library(g.id))
                        .contextMenu {
                            Button("Duplicate") { model.duplicate(g.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(g.id) }
                        }
                }
            }
            Section("Presets") {
                ForEach(Presets.all) { g in
                    SidebarRow(gradient: g).tag(SidebarItem.preset(g.id))
                        .contextMenu { Button("Copy to Library") { model.duplicate(g.id) } }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .library(let id) = model.selection { model.delete(id) }
        }
    }
}

struct SidebarRow: View {
    let gradient: BlendGradient

    var body: some View {
        HStack(spacing: 10) {
            Swatch(gradient: gradient, radius: 6).frame(width: 38, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(gradient.name.isEmpty ? "Untitled" : gradient.name).lineLimit(1)
                Text("\(gradient.kind.title), \(gradient.stops.count) stops")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Editor

struct Editor: View {
    @ObservedObject var model: BlendModel

    var body: some View {
        VStack(spacing: 14) {
            PreviewCanvas(model: model)
                .frame(minHeight: 200)
            StopsBar(model: model)
                .frame(height: 58)
            HStack(alignment: .top, spacing: 14) {
                Inspector(model: model).frame(width: 336)
                CodeCard(model: model)
            }
            .frame(height: 184)
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct PreviewCanvas: View {
    @ObservedObject var model: BlendModel
    @State private var hovering = false

    private var hint: String {
        switch model.current.kind {
        case .linear: "Drag to set the angle"
        case .radial: "Drag to move the center"
        case .conic: "Drag to move the center"
        }
    }

    var body: some View {
        GeometryReader { geo in
            let g = model.current
            ZStack {
                if g.stops.contains(where: { $0.color.a < 0.999 }) { Checkerboard() }
                GradientFill(gradient: g)
                if g.kind != .linear {
                    CenterHandle()
                        .position(x: g.centerX * geo.size.width, y: g.centerY * geo.size.height)
                } else if hovering && !Desktop.isSnapshot {
                    DirectionArrow(angle: g.angle, length: min(geo.size.width, geo.size.height) * 0.32)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .overlay(alignment: .bottomLeading) {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    .opacity(hovering && !Desktop.isSnapshot ? 1 : 0)
            }
            .overlay(alignment: .bottom) { NoticeBanner(model: model).padding(14) }
            .contentShape(Rectangle())
            .onHover { inside in withAnimation(.snappy(duration: 0.2)) { hovering = inside } }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                drag(to: value.location, in: geo.size)
            })
        }
    }

    private func drag(to p: CGPoint, in size: CGSize) {
        let snap = NSEvent.modifierFlags.contains(.shift)
        switch model.current.kind {
        case .linear:
            let dx = p.x - size.width / 2, dy = p.y - size.height / 2
            guard dx * dx + dy * dy > 64 else { return }
            var a = atan2(dx, -dy) * 180 / .pi
            if a < 0 { a += 360 }
            a = snap ? (a / 15).rounded() * 15 : a.rounded()
            model.edit("angle") { $0.angle = Export.degrees(a) }
        case .radial, .conic:
            var x = min(max(p.x / size.width, 0), 1), y = min(max(p.y / size.height, 0), 1)
            if snap { x = (x * 20).rounded() / 20; y = (y * 20).rounded() / 20 }
            model.edit("center") { $0.centerX = (x * 1000).rounded() / 1000; $0.centerY = (y * 1000).rounded() / 1000 }
        }
    }
}

struct CenterHandle: View {
    var body: some View {
        Circle()
            .strokeBorder(.white, lineWidth: 3)
            .background(Circle().fill(.black.opacity(0.12)))
            .frame(width: 20, height: 20)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

struct DirectionArrow: View {
    let angle: Double
    let length: CGFloat

    var body: some View {
        ZStack {
            Capsule().fill(.white).frame(width: 3, height: length)
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .offset(y: -length / 2)
            Circle().fill(.white).frame(width: 9, height: 9)
        }
        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        .rotationEffect(.degrees(angle))
        .allowsHitTesting(false)
    }
}

struct NoticeBanner: View {
    @ObservedObject var model: BlendModel

    var body: some View {
        Group {
            if let notice = model.notice {
                let deleted = notice.hasPrefix("Deleted ") && model.recentlyDeleted != nil
                let file = notice.hasPrefix("Saved ") && notice != "Saved to library" ? model.lastExport : nil
                HStack(spacing: 10) {
                    if model.exporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: deleted ? "trash.fill" : "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                    Text(notice).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let file {
                        Button("Show in Finder") { revealInFinder([file]) }
                            .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                    }
                    if deleted {
                        Button("Undo") { model.undoDelete() }
                            .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                    }
                    if model.exporting {
                        Button("Cancel") { model.cancelExport() }
                            .buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: notice) {
                    if model.exporting { return }
                    let lingers = (notice.hasPrefix("Saved ") && notice != "Saved to library") || notice.hasPrefix("Deleted ")
                    try? await Task.sleep(for: .seconds(lingers ? 5 : 1.6))
                    withAnimation(.snappy) { model.notice = nil }
                }
            }
        }
        .animation(.snappy, value: model.notice)
    }
}

// MARK: - Stops bar

struct StopsBar: View {
    @ObservedObject var model: BlendModel
    @State private var dragging: UUID?
    @State private var grabOffset: CGFloat = 0
    @State private var tearing = false

    static let inset: CGFloat = 12
    static let barHeight: CGFloat = 26

    /// The same stops, laid out left to right.
    private var barGradient: BlendGradient {
        var g = model.current
        g.kind = .linear
        g.angle = 90
        return g
    }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width - Self.inset * 2, 1)
            let bar = barGradient
            ZStack(alignment: .topLeading) {
                ZStack {
                    Checkerboard()
                    GradientFill(gradient: bar)
                }
                .frame(width: width, height: Self.barHeight)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
                .offset(x: Self.inset)
                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                    model.addStop(at: Double(p.x / width))
                }
                .help("Click to add a stop")

                ForEach(model.current.stops) { stop in
                    let x = Self.inset + CGFloat(stop.location) * width
                    StopHandle(color: stop.color, selected: stop.id == model.selectedStop,
                               fading: tearing && dragging == stop.id)
                        .position(x: x, y: Self.barHeight + 17)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stops"))
                            .onChanged { value in
                                if dragging != stop.id {
                                    dragging = stop.id
                                    grabOffset = value.startLocation.x - x
                                    model.selectedStop = stop.id
                                }
                                tearing = model.current.stops.count > 2 && value.translation.height > 40
                                let loc = (value.location.x - grabOffset - Self.inset) / width
                                let snapped = NSEvent.modifierFlags.contains(.shift) ? (loc * 20).rounded() / 20 : loc
                                model.setStop(stop.id, location: (Double(snapped) * 1000).rounded() / 1000)
                            }
                            .onEnded { _ in
                                if tearing { model.deleteSelectedStop() }
                                dragging = nil
                                tearing = false
                            })
                        .help("Drag to move, drag down to remove")
                }
            }
            .coordinateSpace(name: "stops")
        }
    }
}

struct StopHandle: View {
    let color: RGBA
    let selected: Bool
    let fading: Bool

    var body: some View {
        VStack(spacing: -1) {
            Triangle()
                .fill(selected ? AnyShapeStyle(Theme.violet) : AnyShapeStyle(Color.white))
                .frame(width: 10, height: 6)
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white)
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.color).padding(3)
            }
            .frame(width: 22, height: 22)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.black.opacity(0.18)),
                                  lineWidth: selected ? 2.5 : 0.5)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
        .scaleEffect(selected ? 1.1 : 1)
        .opacity(fading ? 0.35 : 1)
        .animation(.snappy(duration: 0.18), value: selected)
        .contentShape(Rectangle())
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Inspector

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct Inspector: View {
    @ObservedObject var model: BlendModel
    @State private var hexText = ""
    @FocusState private var focus: Field?

    enum Field { case name, hex, position, angle }

    private var stopColor: Binding<Color> {
        Binding(get: { model.selectedStopValue?.color.color ?? .clear },
                set: { c in if let id = model.selectedStop { model.setStop(id, color: RGBA(c)) } })
    }

    private var stopLocation: Binding<Double> {
        Binding(get: { ((model.selectedStopValue?.location ?? 0) * 1000).rounded() / 10 },
                set: { v in if let id = model.selectedStop { model.setStop(id, location: v / 100, key: "field") } })
    }

    private var angle: Binding<Double> {
        Binding(get: { model.current.angle }, set: { v in model.edit("angle") { $0.angle = Export.degrees(v) } })
    }

    var body: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 11) {
                GridRow {
                    label("Name")
                    TextField("Name", text: Binding(get: { model.current.name }, set: { model.rename($0) }))
                        .textFieldStyle(.roundedBorder)
                        .focused($focus, equals: .name)
                }
                GridRow {
                    label("Stop")
                    HStack(spacing: 8) {
                        ColorPicker("Stop color", selection: stopColor, supportsOpacity: true)
                            .labelsHidden()
                        TextField("Hex", text: $hexText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 88)
                            .focused($focus, equals: .hex)
                            .onSubmit(applyHex)
                        TextField("Position", value: stopLocation, format: .number.precision(.fractionLength(0...1)))
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 50)
                            .focused($focus, equals: .position)
                        Text("%").foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { model.deleteSelectedStop() } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(!model.canDeleteStop)
                            .help("Delete stop (⌘⌫)")
                    }
                }
                GridRow(alignment: .center) {
                    label(model.current.kind == .radial ? "Center" : "Angle")
                    if model.current.kind == .radial {
                        centerRow
                    } else {
                        HStack(spacing: 12) {
                            AngleDial(angle: angle).frame(width: 44, height: 44)
                            TextField("Angle", value: angle, format: .number.precision(.fractionLength(0...1)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 56)
                                .focused($focus, equals: .angle)
                            Text("°").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            if model.current.kind == .conic {
                                Button("Center") { model.edit { $0.centerX = 0.5; $0.centerY = 0.5 } }
                                    .controlSize(.small)
                                    .disabled(model.current.isCentered)
                                    .help("Move the center back to the middle")
                            }
                        }
                    }
                }
                GridRow {
                    label("Blend")
                    Picker("Blend", selection: Binding(get: { model.current.interpolation },
                                                       set: { v in model.edit { $0.interpolation = v } })) {
                        ForEach(Interpolation.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .padding(14)
        }
        .onAppear { hexText = model.selectedStopValue?.color.hex ?? "" }
        .onChange(of: model.selectedStopValue?.color) { _, c in hexText = c?.hex ?? "" }
        .onChange(of: focus) { old, new in
            if old == .hex, new != .hex { applyHex() }
            model.textFocused = new != nil
        }
    }

    private var centerRow: some View {
        HStack(spacing: 8) {
            Text("\(Export.number(model.current.centerX * 100))%, \(Export.number(model.current.centerY * 100))%")
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 0)
            Button("Center") { model.edit { $0.centerX = 0.5; $0.centerY = 0.5 } }
                .controlSize(.small)
                .disabled(model.current.isCentered)
                .help("Move the center back to the middle")
        }
        .frame(height: 44)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func applyHex() {
        guard let id = model.selectedStop, var c = RGBA(hex: hexText) else {
            hexText = model.selectedStopValue?.color.hex ?? ""
            return
        }
        if hexText.filter(\.isHexDigit).count != 8 { c.a = model.selectedStopValue?.color.a ?? 1 }
        model.setStop(id, color: c)
        hexText = c.hex
    }
}

/// A round dial: drag anywhere on it to point the gradient; hold Shift to snap to 15 degrees.
struct AngleDial: View {
    @Binding var angle: Double

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                Circle().fill(Color.primary.opacity(0.06))
                Circle().strokeBorder(Color.primary.opacity(0.15))
                ForEach(0..<8) { i in
                    Capsule().fill(Color.primary.opacity(0.25)).frame(width: 1.5, height: 4)
                        .offset(y: -r + 4).rotationEffect(.degrees(Double(i) * 45))
                }
                Capsule().fill(Theme.accent).frame(width: 3, height: r - 6)
                    .offset(y: -(r - 6) / 2).rotationEffect(.degrees(angle))
                Circle().fill(Theme.violet).frame(width: 7, height: 7)
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - r, dy = value.location.y - r
                guard dx * dx + dy * dy > 9 else { return }
                var a = atan2(dx, -dy) * 180 / .pi
                if a < 0 { a += 360 }
                angle = NSEvent.modifierFlags.contains(.shift) ? (a / 15).rounded() * 15 : a.rounded()
            })
        }
        .help("Drag to set the angle; hold Shift to snap")
    }
}

// MARK: - Code

struct CodeCard: View {
    @ObservedObject var model: BlendModel

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack {
                    Picker("Format", selection: $model.codeFormat) {
                        ForEach(CodeFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    Spacer()
                    Button { model.copy(model.codeFormat) } label: {
                        Label(model.codeFormat == .hex ? "Copy Hex List" : "Copy \(model.codeFormat.title)",
                              systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.violet)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Divider()
                if model.codeFormat == .hex {
                    ScrollView { hexRows }
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(highlighted(model.code))
                            .font(.system(size: 12, design: .monospaced))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    /// Colours the hex values and numbers so the stops stand out in the code.
    private func highlighted(_ code: String) -> AttributedString {
        var out = AttributedString(code)
        let patterns: [(String, Color)] = [
            ("#[0-9A-F]{6,8}\\b", Theme.violet),
            ("(?<![#\\w.])-?[0-9]+(\\.[0-9]+)?(%|deg)?(?![\\w])", Color(red: 0.78, green: 0.27, blue: 0.47)),
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = code as NSString
            for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(match.range, in: code), let a = Range(r, in: out) else { continue }
                out[a].foregroundColor = color
            }
        }
        return out
    }

    private var hexRows: some View {
        VStack(spacing: 6) {
            ForEach(model.current.sortedStops) { stop in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(stop.color.color)
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black.opacity(0.12)))
                        .frame(width: 18, height: 18)
                    Text(stop.color.hex).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text("\(Export.number(stop.location * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(stop.id == model.selectedStop ? Theme.violet.opacity(0.1) : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.selectedStop = stop.id }
            }
        }
        .padding(10)
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    @ObservedObject var model: BlendModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export PNG").font(.system(size: 15, weight: .semibold, design: .rounded))
            HStack(alignment: .top, spacing: 18) {
                let w = CGFloat(max(model.exportWidth, 1)), h = CGFloat(max(model.exportHeight, 1))
                let scale = min(150 / w, 110 / h)
                Swatch(gradient: model.current, radius: 6)
                    .frame(width: w * scale, height: h * scale)
                    .frame(width: 150, height: 110)
                Form {
                    Picker("Size", selection: Binding(
                        get: { PNGSize.presets.first { $0.width == model.exportWidth && $0.height == model.exportHeight } },
                        set: { if let s = $0 { model.exportWidth = s.width; model.exportHeight = s.height } })) {
                        ForEach(PNGSize.presets, id: \.self) { s in
                            Text("\(s.name)  \(s.width) × \(s.height)").tag(Optional(s))
                        }
                        if !PNGSize.presets.contains(where: { $0.width == model.exportWidth && $0.height == model.exportHeight }) {
                            Text("Custom").tag(PNGSize?.none)
                        }
                    }
                    TextField("Width", value: $model.exportWidth, format: .number.grouping(.never))
                    TextField("Height", value: $model.exportHeight, format: .number.grouping(.never))
                }
                .frame(width: 270)
            }
            Text("Pixels, up to 8192 on each side.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    DispatchQueue.main.async { model.exportPNG() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.exportWidth < 1 || model.exportHeight < 1)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - Menus

struct BlendCommands: Commands {
    @ObservedObject var model: BlendModel

    /// A text field (in the window or the export sheet) may have focus: keep the text commands available.
    private var typing: Bool { model.textFocused || model.showingExport }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Gradient") { model.newGradient() }.keyboardShortcut("n")
            Button("Random Gradient") { model.randomize() }.keyboardShortcut("r")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save to Library") { model.saveToLibrary() }.keyboardShortcut("s").disabled(model.isInLibrary)
            Button("Duplicate") { model.duplicate(model.current.id) }.keyboardShortcut("d").disabled(!model.isInLibrary)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export PNG…") { model.showingExport = true }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.exporting)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { TextEditing.active ? TextEditing.send("undo:") : model.undo() }
                .keyboardShortcut("z").disabled(!(model.canUndo || typing))
            Button("Redo") { TextEditing.active ? TextEditing.send("redo:") : model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!(model.canRedo || typing))
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy CSS") { model.copy(.css) }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy SwiftUI Code") { model.copy(.swiftUI) }.keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy Hex List") { model.copy(.hex) }.keyboardShortcut("c", modifiers: [.command, .control])
        }
        CommandMenu("Gradient") {
            Picker("Type", selection: Binding(get: { model.current.kind }, set: { k in model.edit { $0.kind = k } })) {
                Text("Linear").tag(GradientKind.linear).keyboardShortcut("1")
                Text("Radial").tag(GradientKind.radial).keyboardShortcut("2")
                Text("Conic").tag(GradientKind.conic).keyboardShortcut("3")
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Smooth Blending (OKLab)", isOn: Binding(get: { model.current.interpolation == .oklab },
                                                            set: { on in model.edit { $0.interpolation = on ? .oklab : .srgb } }))
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Button("Add Stop") { model.addStopInWidestGap() }.keyboardShortcut("=")
            Button("Delete Stop") {
                TextEditing.active ? TextEditing.send("deleteToBeginningOfLine:") : model.deleteSelectedStop()
            }
            .keyboardShortcut(.delete).disabled(!(model.canDeleteStop || typing))
            Button("Select Previous Stop") { model.selectNeighbourStop(-1) }.keyboardShortcut("[")
            Button("Select Next Stop") { model.selectNeighbourStop(1) }.keyboardShortcut("]")
            Divider()
            Button("Rotate 45° Clockwise") { model.edit { $0.angle = Export.degrees($0.angle + 45) } }
                .keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model.current.kind == .radial)
            Button("Reverse Stops") { model.reverse() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Distribute Stops Evenly") { model.distribute() }.keyboardShortcut("d", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Divider()
            Picker("Code", selection: $model.codeFormat) {
                Text("Show CSS").tag(CodeFormat.css).keyboardShortcut("1", modifiers: [.command, .option])
                Text("Show SwiftUI").tag(CodeFormat.swiftUI).keyboardShortcut("2", modifiers: [.command, .option])
                Text("Show Hex List").tag(CodeFormat.hex).keyboardShortcut("3", modifiers: [.command, .option])
            }
            .pickerStyle(.inline)
            Divider()
        }
    }
}
