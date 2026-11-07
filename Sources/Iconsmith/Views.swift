import AppKit
import Kit
import SwiftUI

enum Theme {
    static let goldLight = Color(red: 0.98, green: 0.82, blue: 0.42)
    static let gold = Color(red: 0.86, green: 0.62, blue: 0.16)
    static let goldDeep = Color(red: 0.70, green: 0.47, blue: 0.08)
    static let accent = LinearGradient(colors: [goldLight, gold], startPoint: .top, endPoint: .bottom)
    static let inspectorWidth: CGFloat = 300

    /// View settings. The snapshot reads an empty suite, so the website picture never depends on how the user left the window.
    static var defaults: UserDefaults {
        Desktop.isSnapshot ? UserDefaults(suiteName: "com.weirdapps.iconsmith.snapshot") ?? .standard : .standard
    }
}

struct ContentView: View {
    @ObservedObject var model: IconModel
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false
    @AppStorage("showInspector", store: Theme.defaults) private var showInspector = true

    var body: some View {
        Group {
            if model.hasImage {
                VStack(spacing: 0) {
                    EditorCanvas(model: model)
                    Divider()
                    PreviewStrip(model: model)
                }
                .inspector(isPresented: $showInspector) {
                    Inspector(model: model)
                        .inspectorColumnWidth(min: 280, ideal: Theme.inspectorWidth, max: 360)
                }
            } else {
                DropZone(symbol: "photo.badge.plus", title: "Drop an image",
                         message: "PNG, JPEG, HEIC, TIFF, PDF or SVG, any size. You can crop it to a square and zoom in.",
                         button: "Open Image…", tint: Theme.gold, isTargeted: dropTargeted) { model.showOpenPanel() }
            }
        }
        .overlay {
            if model.isLoading {
                ProgressView("Opening…")
                    .controlSize(.large)
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("Iconsmith")
        .navigationSubtitle(model.hasImage ? model.name : "")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .toolbar { toolbar }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear {
            model.undoManager = undoManager
            if !Desktop.isSnapshot { FileInbox.shared.attach(model) }
        }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.showOpenPanel() } label: { Label("Open", systemImage: "photo.badge.plus") }
                .help("Open an image (⌘O)")
        }
        ToolbarItem(placement: .principal) {
            Picker("Shape", selection: Binding(get: { model.options.shape },
                                               set: { s in model.update("Change Shape") { $0.shape = s } })) {
                ForEach(IconShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!model.hasImage)
            .help("Rounded macOS tile or full square (⌘1, ⌘2)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.revealLastExport() } label: { Label("Reveal in Finder", systemImage: "folder") }
                .help("Reveal the last export in Finder (⇧⌘R)")
                .disabled(model.lastExport == nil)
            Menu {
                ForEach(ExportKind.allCases, id: \.self) { kind in
                    Button(kind.menuTitle) { model.export(kind) }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.export(.icns)
            }
            .help("Export .icns (⌘E); hold for iconset and Xcode app icon")
            .disabled(!model.hasImage || model.isExporting)
            Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .help("Show or hide the inspector (⌥⌘I)")
                .disabled(!model.hasImage)
        }
    }
}

// MARK: - Editor

struct EditorCanvas: View {
    @ObservedObject var model: IconModel
    @AppStorage("showGrid", store: Theme.defaults) private var showGrid = false
    @State private var dragStart: CGPoint?
    @State private var zoomStart: Double?

    var body: some View {
        GeometryReader { geo in
            let side = max(120, min(geo.size.width - 64, geo.size.height - 76))
            VStack(spacing: 12) {
                ZStack {
                    Checkerboard()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.08)))
                    if let image = model.renders[1024] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    }
                    if showGrid { GridOverlay(options: model.options) }
                }
                .frame(width: side, height: side)
                .contentShape(Rectangle())
                .gesture(drag(side: side))
                .simultaneousGesture(magnify)
                .onTapGesture(count: 2) { withAnimation(.snappy) { model.resetCrop() } }

                Text("Drag to reposition. Pinch to zoom. Double click to reset.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
        .overlay(alignment: .top) {
            if let banner = model.banner {
                ExportBanner(text: banner, canReveal: model.lastExport != nil && banner.hasPrefix("Exported")) { model.revealLastExport() }
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.banner)
    }

    private func drag(side: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? model.options.center
                if dragStart == nil { dragStart = start }
                model.pan(from: start, translation: value.translation, canvasSide: side)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomStart ?? model.options.zoom
                if zoomStart == nil { zoomStart = start }
                model.update("Zoom") { $0.zoom = start * value.magnification }
            }
            .onEnded { _ in zoomStart = nil }
    }
}

/// A transparency checkerboard drawn from a tiled pattern image.
struct Checkerboard: View {
    static let tileImage: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor(white: 1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 20, height: 20).fill()
        NSColor(white: 0.9, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 10, height: 10).fill()
        NSRect(x: 10, y: 10, width: 10, height: 10).fill()
        image.unlockFocus()
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tileImage).resizable(resizingMode: .tile)
    }
}

/// Guides of the macOS icon grid: the 824 tile, the artwork box, centre lines and the keyline circle.
struct GridOverlay: View {
    let options: IconOptions

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / Geometry.canvas
            let tile = Geometry.tileRect, content = Geometry.contentRect(options)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: geo.size.width / 2, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width / 2, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                }
                .stroke(Theme.gold.opacity(0.45), lineWidth: 0.5)
                RoundedRectangle(cornerRadius: Geometry.tileRadius * k, style: .continuous)
                    .stroke(Theme.gold.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(width: tile.width * k, height: tile.height * k)
                    .offset(x: tile.minX * k, y: tile.minY * k)
                Circle()
                    .stroke(Theme.gold.opacity(0.5), lineWidth: 0.75)
                    .frame(width: 0.68 * tile.width * k, height: 0.68 * tile.width * k)
                    .offset(x: (Geometry.canvas - 0.68 * tile.width) / 2 * k, y: (Geometry.canvas - 0.68 * tile.width) / 2 * k)
                if options.padding > 0 {
                    Rectangle()
                        .stroke(Theme.gold.opacity(0.6), lineWidth: 0.75)
                        .frame(width: content.width * k, height: content.height * k)
                        .offset(x: content.minX * k, y: (Geometry.canvas - content.maxY) * k)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ExportBanner: View {
    let text: String
    let canReveal: Bool
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if canReveal {
                Button("Reveal in Finder", action: reveal)
                    .buttonStyle(.link)
                    .font(.system(size: 12.5, weight: .medium))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

// MARK: - Preview strip

struct PreviewStrip: View {
    @ObservedObject var model: IconModel
    @AppStorage("darkPreview", store: Theme.defaults) private var dark = false
    static let maxDisplay: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Every size").font(.system(size: 12, weight: .semibold))
                Text("as the Finder and Dock draw them").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Picker("Background", selection: $dark) {
                    Image(systemName: "sun.max").tag(false).help("Light background")
                    Image(systemName: "moon").tag(true).help("Dark background")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Preview on a light or dark desktop (⇧⌘D)")
            }
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Geometry.sizes, id: \.self) { size in
                    VStack(spacing: 8) {
                        if let image = model.renders[size] {
                            let display = min(CGFloat(size), Self.maxDisplay)
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(CGFloat(size) <= display ? .none : .high)
                                .frame(width: display, height: display)
                        }
                        Text(size < 1024 ? "\(size)" : "1024")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(dark ? Color.white.opacity(0.6) : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(dark ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.92)], startPoint: .top, endPoint: .bottom)))
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.07)))
            .animation(.snappy, value: dark)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: IconModel

    private func binding<T>(_ path: WritableKeyPath<IconOptions, T>, _ label: String) -> Binding<T> {
        Binding(get: { model.options[keyPath: path] }, set: { value in model.update(label) { $0[keyPath: path] = value } })
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    if let preview = model.preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.1)))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "\(Int(model.sourceSize.width)) × \(Int(model.sourceSize.height)) px")
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if model.isLowResolution {
                    Label("The crop is \(Int(model.cropRect.width)) px wide; the 1024 icon needs \(Int(Geometry.contentRect(model.options).width)). Large sizes will look soft.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.multicolor)
                }
            }

            Section("Framing") {
                Picker("Framing", selection: binding(\.framing, "Change Framing")) {
                    Text("Crop").tag(Framing.crop)
                    Text("Fit").tag(Framing.fit)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                LabeledContent("Zoom") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.zoom, "Zoom"), in: IconOptions.zoomRange)
                        Text("\(Int((model.options.zoom * 100).rounded()))%")
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                            .contentTransition(.numericText())
                    }
                }
            }

            Section("Shape") {
                Picker("Shape", selection: binding(\.shape, "Change Shape")) {
                    Text("macOS tile").tag(IconShape.tile)
                    Text("Full bleed").tag(IconShape.fullBleed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Drop shadow", isOn: binding(\.shadow, "Toggle Shadow"))
                    .disabled(model.options.shape != .tile)
                LabeledContent("Padding") {
                    HStack(spacing: 8) {
                        Slider(value: binding(\.padding, "Padding"), in: IconOptions.paddingRange)
                        Text("\(Int((model.options.padding * 100).rounded()))%")
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            Section("Background") {
                Toggle("Fill transparent areas", isOn: binding(\.fillBackground, "Toggle Background"))
                ColorPicker("Color", selection: Binding(
                    get: { Color(nsColor: model.options.background.nsColor) },
                    set: { c in model.update("Change Background") { $0.background = RGBA(NSColor(c)); $0.fillBackground = true } }))
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ExportPanel(model: model)
        }
    }
}

struct ExportPanel: View {
    @ObservedObject var model: IconModel

    var body: some View {
        VStack(spacing: 10) {
            Button { model.export(.icns) } label: {
                HStack(spacing: 7) {
                    if model.isExporting {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Text(model.isExporting ? "Exporting…" : "Export .icns…")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GoldButtonStyle())
            .disabled(model.isExporting)
            HStack(spacing: 8) {
                Button { model.export(.iconset) } label: { Text("Iconset…").frame(maxWidth: .infinity) }
                    .help("Export an .iconset folder (⇧⌘E)")
                Button { model.export(.appIconSet) } label: { Text("Xcode App Icon…").frame(maxWidth: .infinity) }
                    .help("Export AppIcon.appiconset with Contents.json (⌥⌘E)")
            }
            .controlSize(.large)
            .disabled(model.isExporting)
        }
        .padding(16)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
    }
}

struct GoldButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color(red: 0.25, green: 0.16, blue: 0.02))
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.goldDeep.opacity(0.45)))
            .shadow(color: Theme.goldDeep.opacity(configuration.isPressed ? 0.15 : 0.3), radius: configuration.isPressed ? 1 : 4, y: configuration.isPressed ? 0 : 2)
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
