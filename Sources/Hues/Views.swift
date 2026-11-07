import AppKit
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0xF6 / 255, green: 0xC1 / 255, blue: 0x77 / 255)
    static let deep = Color(red: 0xE0 / 255, green: 0x7A / 255, blue: 0x3F / 255)
    static let gradient = LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: HuesModel
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            HistorySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            detail
                .frame(minWidth: 620, minHeight: 440)
        }
        .toolbar { toolbar }
        .navigationTitle(model.hasContent ? model.displayName : "Hues")
        .navigationSubtitle(subtitle)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay(alignment: .bottom) { ToastView(model: model) }
        .confirmationDialog("Clear all recent palettes?", isPresented: $model.confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: {
            Text("Their saved images are deleted too. This cannot be undone.")
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
        .tint(Theme.deep)
    }

    private var subtitle: String {
        guard model.hasContent else { return "" }
        let picked = model.pickedCount
        return "\(model.extractedCount) colours" + (picked > 0 ? ", \(picked) picked" : "")
    }

    @ViewBuilder private var detail: some View {
        if model.hasContent {
            Workspace(model: model)
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Theme.deep, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.deep.opacity(0.06)))
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }
        } else if model.isWorking {
            ProgressView("Finding colours\u{2026}").controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DropZone(symbol: "photo.on.rectangle.angled", title: "Drop an image",
                     message: "Drop a photo or screenshot here, or paste one with \u{2318}V, to pull its colours.",
                     button: "Open Image\u{2026}", tint: Theme.deep, isTargeted: dropTargeted) { model.open() }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.open() } label: { Label("Open", systemImage: "folder") }
                .help("Open an image (\u{2318}O)")
            Toggle(isOn: $model.picking) { Label("Pick", systemImage: "eyedropper") }
                .help("Pick colours from the image with a loupe (P)")
                .disabled(model.bitmap == nil)
            Menu {
                Section("Export") {
                    ForEach(ExportFormat.allCases) { f in
                        Button("\(f.title)\u{2026}") { model.export(f) }
                    }
                }
                Section("Copy") {
                    ForEach(ExportFormat.allCases.filter { $0 != .png }) { f in
                        Button("Copy as \(f.title)") { model.copyPalette(f) }
                    }
                }
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export or copy the palette (\u{21E7}\u{2318}E)")
                .disabled(model.swatches.isEmpty)
        }
    }
}

struct Workspace: View {
    @ObservedObject var model: HuesModel

    var body: some View {
        HStack(spacing: 0) {
            ImagePane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PalettePane(model: model)
                .frame(width: 330)
        }
    }
}

// MARK: - Image

struct ImagePane: View {
    @ObservedObject var model: HuesModel
    @State private var hover: CGPoint?
    @State private var crosshair = false

    var body: some View {
        GeometryReader { geo in
            if let bitmap = model.bitmap {
                let rect = Self.fit(CGSize(width: bitmap.width, height: bitmap.height), in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 28, dy: 28))
                ZStack(alignment: .topLeading) {
                    picture(bitmap, rect.size)
                        .position(x: rect.midX, y: rect.midY)
                    if model.picking, let p = loupePoint(rect) {
                        let unit = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
                        LoupeView(bitmap: bitmap, unit: unit, color: model.color(atUnit: unit))
                            .position(Self.loupeCentre(p, in: geo.size))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard !Desktop.isSnapshot else { return }
                    switch phase {
                    case .active(let p): hover = p
                    case .ended: hover = nil
                    }
                    updateCursor(rect)
                }
                .onChange(of: model.picking) { _, _ in updateCursor(rect) }
                .onTapGesture(coordinateSpace: .local) { p in
                    guard model.picking, rect.contains(p) else { return }
                    model.addPick(atUnit: CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height))
                }
            } else {
                ContentUnavailableView("Image not available", systemImage: "photo.badge.exclamationmark",
                                       description: Text("The saved copy of this image is gone. Its colours are still here."))
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) { hint }
        .onDisappear { if crosshair { NSCursor.pop(); crosshair = false } }
    }

    private func picture(_ bitmap: Bitmap, _ size: CGSize) -> some View {
        Image(decorative: bitmap.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: size.width, height: size.height)
            .overlay {
                if let mask = model.hoverMask {
                    Image(decorative: mask, scale: 1).resizable().interpolation(.high).transition(.opacity)
                }
            }
            .overlay {
                // Markers where colours were picked by hand.
                ForEach(model.swatches.filter(\.isPicked)) { s in
                    if let p = s.point {
                        PickMarker(color: s.color.color, highlighted: model.hovered == s.id || model.selected == s.id)
                            .position(x: p.x * size.width, y: p.y * size.height)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.15), value: model.hovered)
    }

    private var hint: some View {
        let text = model.picking ? "Click to add the colour under the loupe. Press P to stop picking."
            : "Hover a colour to see where it occurs. Press P to pick your own."
        return Label(text, systemImage: model.picking ? "eyedropper" : "hand.point.up.left")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(.black.opacity(0.06)))
            .padding(.bottom, 8)
            .opacity(model.bitmap == nil ? 0 : 1)
            .allowsHitTesting(false)
    }

    private func loupePoint(_ rect: CGRect) -> CGPoint? {
        if let demo = model.demoLoupe {
            return CGPoint(x: rect.minX + demo.x * rect.width, y: rect.minY + demo.y * rect.height)
        }
        guard let hover, rect.contains(hover) else { return nil }
        return hover
    }

    private func updateCursor(_ rect: CGRect) {
        let want = model.picking && hover.map(rect.contains) == true
        if want && !crosshair { NSCursor.crosshair.push(); crosshair = true }
        if !want && crosshair { NSCursor.pop(); crosshair = false }
    }

    static func fit(_ image: CGSize, in area: CGRect) -> CGRect {
        guard image.width > 0, image.height > 0, area.width > 0, area.height > 0 else { return .zero }
        let scale = min(area.width / image.width, area.height / image.height)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Up and to the right of the pointer, flipped when that would leave the pane.
    static func loupeCentre(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let offset: CGFloat = 92
        var x = p.x + offset, y = p.y - offset
        if x + 70 > size.width { x = p.x - offset }
        if y - 70 < 0 { y = p.y + offset }
        return CGPoint(x: x, y: y)
    }
}

struct PickMarker: View {
    let color: Color
    let highlighted: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: highlighted ? 20 : 15, height: highlighted ? 20 : 15)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .animation(.snappy, value: highlighted)
    }
}

struct LoupeView: View {
    let bitmap: Bitmap
    let unit: CGPoint
    let color: RGB?
    static let cells = 11
    static let diameter: CGFloat = 132

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let patch {
                    Image(decorative: patch, scale: 1).resizable().interpolation(.none)
                }
                grid
                let cell = Self.diameter / CGFloat(Self.cells)
                Rectangle().strokeBorder(.white, lineWidth: 1.5)
                    .frame(width: cell + 2, height: cell + 2)
                    .shadow(color: .black.opacity(0.6), radius: 1)
            }
            .frame(width: Self.diameter, height: Self.diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 4))
            .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            if let color {
                HStack(spacing: 6) {
                    Circle().fill(color.color).frame(width: 10, height: 10).overlay(Circle().strokeBorder(.white.opacity(0.6)))
                    Text(color.hex).font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.72)))
            }
        }
    }

    private var grid: some View {
        Canvas { ctx, size in
            let step = size.width / CGFloat(Self.cells)
            var path = Path()
            for i in 1..<Self.cells {
                let v = CGFloat(i) * step
                path.move(to: CGPoint(x: v, y: 0)); path.addLine(to: CGPoint(x: v, y: size.height))
                path.move(to: CGPoint(x: 0, y: v)); path.addLine(to: CGPoint(x: size.width, y: v))
            }
            ctx.stroke(path, with: .color(.black.opacity(0.12)), lineWidth: 0.5)
        }
    }

    /// The pixels around the pointer, transparent past the edges.
    private var patch: CGImage? {
        let n = Self.cells, half = n / 2
        let cx = min(Int(unit.x * CGFloat(bitmap.width)), bitmap.width - 1), cy = min(Int(unit.y * CGFloat(bitmap.height)), bitmap.height - 1)
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for j in 0..<n {
            for i in 0..<n {
                let x = cx - half + i, y = cy - half + j
                guard x >= 0, y >= 0, x < bitmap.width, y < bitmap.height else { continue }
                let src = (y * bitmap.width + x) * 4, dst = (j * n + i) * 4
                for k in 0..<4 { bytes[dst + k] = bitmap.data[src + k] }
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

// MARK: - Palette

struct PalettePane: View {
    @ObservedObject var model: HuesModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Palette").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(model.count) colours")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.count)
                    Stepper("Colours", value: $model.count, in: Extractor.range)
                        .labelsHidden()
                        .help("Number of colours to extract (\u{2318}= and \u{2318}\u{2212})")
                        .disabled(model.bitmap == nil)
                }
                ProportionStrip(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            Divider().opacity(0.6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.swatches) { s in
                        SwatchRow(model: model, swatch: s)
                    }
                }
                .padding(10)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ProportionStrip: View {
    @ObservedObject var model: HuesModel

    var body: some View {
        let extracted = model.swatches.filter { !$0.isPicked }
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(extracted) { s in
                    Rectangle()
                        .fill(s.color.color)
                        .frame(width: max(2, geo.size.width * (s.share ?? 0)))
                        .overlay(alignment: .bottom) {
                            if model.hovered == s.id {
                                Rectangle().fill(.white.opacity(0.9)).frame(height: 3)
                            }
                        }
                        .onHover { inside in
                            guard !Desktop.isSnapshot else { return }
                            model.hovered = inside ? s.id : (model.hovered == s.id ? nil : model.hovered) }
                        .onTapGesture { model.copy(s) }
                        .help("\(s.color.hex), \(Exporter.percent(s))")
                }
            }
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
        .animation(.snappy, value: extracted.map(\.id))
    }
}

struct SwatchRow: View {
    @ObservedObject var model: HuesModel
    let swatch: Swatch
    @State private var hovering = false

    private var isSelected: Bool { model.selected == swatch.id }
    private var isHot: Bool { hovering || model.hovered == swatch.id }

    var body: some View {
        HStack(spacing: 12) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(swatch.color.hex)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Spacer(minLength: 4)
                    if swatch.isPicked {
                        Label("Picked", systemImage: "eyedropper")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.deep)
                    } else {
                        Text(Exporter.percent(swatch))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("RGB \(ColorMath.rgbText(swatch.color))   HSL \(ColorMath.hslText(swatch.color))")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                ShareBar(share: swatch.share ?? 0, color: swatch.color.color, faded: swatch.isPicked)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHot ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear))
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.gradient, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard !Desktop.isSnapshot else { return }
            hovering = inside
            if inside { model.hovered = swatch.id } else if model.hovered == swatch.id { model.hovered = nil }
        }
        .onTapGesture { model.copy(swatch) }
        .help("Click to copy \(swatch.color.hex)")
        .contextMenu {
            Button("Copy Hex") { model.copy(swatch, as: .hex) }
            Button("Copy RGB") { model.copy(swatch, as: .rgb) }
            Button("Copy HSL") { model.copy(swatch, as: .hsl) }
            Divider()
            Button("Remove Colour") { model.remove(swatch.id) }
        }
        .animation(.easeOut(duration: 0.12), value: isHot)
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(swatch.color.color)
            .frame(width: 40, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.1)))
            .overlay {
                if model.copiedID == swatch.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(swatch.color.luminance > 0.4 ? Color.black.opacity(0.7) : .white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: swatch.color.color.opacity(0.4), radius: isHot ? 6 : 3, y: 2)
    }
}

struct ShareBar: View {
    let share: Double
    let color: Color
    let faded: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.6))
                if !faded {
                    Capsule().fill(color).frame(width: max(4, geo.size.width * min(1, share / 0.5)))
                }
            }
        }
        .frame(height: 4)
        .animation(.snappy, value: share)
    }
}

// MARK: - History

struct HistorySidebar: View {
    @ObservedObject var model: HuesModel

    var body: some View {
        List(selection: $model.historySelection) {
            Section("Recent") {
                ForEach(model.history) { item in
                    HistoryRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Delete from History") { model.deleteHistory(item.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.history.isEmpty {
                ContentUnavailableView("No palettes yet", systemImage: "swatchpalette",
                                       description: Text("Palettes you make appear here."))
            }
        }
        .onChange(of: model.historySelection) { _, id in
            if let id { model.restore(id) }
        }
    }
}

struct HistoryRow: View {
    let item: SavedPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                ForEach(item.swatches) { s in
                    Rectangle().fill(s.color.color)
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.08)))
            HStack {
                Text((item.name as NSString).deletingPathExtension)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.date, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Toast

struct ToastView: View {
    @ObservedObject var model: HuesModel

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 8) {
                Image(systemName: toast.symbol).foregroundStyle(Theme.deep)
                Text(toast.message).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let url = toast.reveal {
                    Button("Reveal in Finder") { revealInFinder([url]) }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 40)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
