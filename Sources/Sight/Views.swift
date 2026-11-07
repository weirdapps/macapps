import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let teal = Color(red: 0x00 / 255, green: 0xC2 / 255, blue: 0xA8 / 255)
    static let violet = Color(red: 0x6B / 255, green: 0x4C / 255, blue: 0xE6 / 255)
    static let accent = LinearGradient(colors: [teal, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tint = Color(red: 0x3B / 255, green: 0x86 / 255, blue: 0xC7 / 255)
    /// The colours each sidebar row runs through its simulation, so the list itself shows what each mode does.
    static let spectrum: [(UInt8, UInt8, UInt8)] = [(0xE5, 0x48, 0x4D), (0xF5, 0xA5, 0x24), (0x30, 0xA4, 0x6C),
                                                    (0x3E, 0x63, 0xDD), (0x8E, 0x4E, 0xC6)]
}

struct ContentView: View {
    @ObservedObject var model: SightModel
    @State private var targeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            Detail(model: model, targeted: targeted)
        }
        .navigationTitle(model.hasImage ? model.name : "Sight")
        .navigationSubtitle(model.hasImage ? model.mode.name : "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openPanel() } label: { Label("Open", systemImage: "photo.badge.plus") }
                    .help("Open an image (⌘O)")
                Picker("View", selection: $model.layout) {
                    ForEach(Layout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .help("Single, split comparison or grid of all (⌘1, ⌘2, ⌘3)")
                .disabled(!model.hasImage)
                Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export the simulated image (⇧⌘E)")
                    .disabled(!model.hasImage)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $targeted) { model.drop($0) }
        .tint(Theme.tint)
        .frame(minWidth: 780, minHeight: 500)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: SightModel

    var body: some View {
        List(selection: Binding<Simulation?>(get: { model.mode }, set: { if let m = $0 { model.mode = m } })) {
            ForEach(Simulation.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(Simulation.allCases.filter { $0.group == group }) { mode in
                        SidebarRow(mode: mode, severity: model.severity).tag(mode)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SidebarRow: View {
    let mode: Simulation
    let severity: Double

    var body: some View {
        HStack(spacing: 10) {
            SpectrumChip(mode: mode, severity: severity)
            VStack(alignment: .leading, spacing: 1) {
                Text(mode.name).font(.system(size: 13, weight: .medium))
                Text("\(mode.cones), \(mode.prevalence.lowercased(with: nil))")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Five reference colours as this mode sees them.
struct SpectrumChip: View {
    let mode: Simulation
    let severity: Double

    var body: some View {
        let matrix = mode.matrix(severity: severity)
        HStack(spacing: 0) {
            ForEach(0..<Theme.spectrum.count, id: \.self) { i in
                let c = SRGB.simulate(Theme.spectrum[i], matrix)
                Rectangle().fill(Color(red: Double(c.0) / 255, green: Double(c.1) / 255, blue: Double(c.2) / 255))
            }
        }
        .frame(width: 30, height: 18)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Detail

struct Detail: View {
    @ObservedObject var model: SightModel
    let targeted: Bool

    var body: some View {
        if model.hasImage {
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    Group {
                        switch model.layout {
                        case .single: SingleView(model: model)
                        case .split: SplitView(model: model)
                        case .grid: GridView(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if let saved = model.saved {
                        SavedToast(url: saved) { model.dismissSaved() }
                            .padding(.bottom, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if model.busy {
                        ProgressView().controlSize(.small).padding(10)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                }
                .background(Color(nsColor: .underPageBackgroundColor))
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 3).padding(8)
                    }
                }
                Divider()
                BottomBar(model: model)
            }
        } else {
            ZStack(alignment: .bottom) {
                DropZone(symbol: "eye", title: "Drop a design here",
                         message: "Drop, paste or open an image or a screenshot to see it as people with colour blindness do.",
                         button: "Open Image…", tint: Theme.tint, isTargeted: targeted) { model.openPanel() }
                Button("Try the sample design") { model.loadSample() }
                    .buttonStyle(.link)
                    .padding(.bottom, 44)
            }
        }
    }
}

/// A small label laid over an image.
struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.55)))
    }
}

struct FramedImage: View {
    let image: CGImage?
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

struct SingleView: View {
    @ObservedObject var model: SightModel
    @State private var peeking = false

    var body: some View {
        GeometryReader { geo in
            let size = fitted(model.pixelSize, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 48))
            FramedImage(image: peeking ? model.original : model.previews[model.mode])
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .overlay(alignment: .topLeading) { Chip(text: peeking ? "Original" : model.mode.name).padding(10) }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in peeking = true }
                    .onEnded { _ in peeking = false })
                .help("Press and hold to see the original")
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct SplitView: View {
    @ObservedObject var model: SightModel

    var body: some View {
        GeometryReader { geo in
            let size = fitted(model.pixelSize, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 48))
            let x = size.width * model.split
            ZStack(alignment: .topLeading) {
                FramedImage(image: model.original)
                FramedImage(image: model.previews[model.mode])
                    .mask(alignment: .trailing) { Rectangle().frame(width: max(0, size.width - x)) }
                Chip(text: "Original").padding(10).opacity(model.split > 0.12 ? 1 : 0)
                Chip(text: model.mode.name).padding(10)
                    .frame(width: size.width, alignment: .trailing)
                    .opacity(model.split < 0.88 ? 1 : 0)
                SplitHandle(height: size.height).offset(x: x - 16)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                model.split = min(max(value.location.x / max(size.width, 1), 0), 1)
            })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .animation(.snappy(duration: 0.15), value: model.split > 0.12)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}

struct SplitHandle: View {
    let height: CGFloat
    var body: some View {
        ZStack {
            Rectangle().fill(.white).frame(width: 2.5).shadow(color: .black.opacity(0.35), radius: 2)
            Circle()
                .fill(Theme.accent)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
                .frame(width: 32, height: 32)
                .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
        }
        .frame(width: 32, height: height)
    }
}

struct GridView: View {
    @ObservedObject var model: SightModel

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 14, pad: CGFloat = 20
            let width = (geo.size.width - pad * 2 - spacing * 3) / 4
            let aspect = model.pixelSize.width > 0 ? model.pixelSize.height / model.pixelSize.width : 1
            // Rows only as tall as their content, so the grid sits together in the middle.
            let tile = CGSize(width: width, height: min((geo.size.height - pad * 2 - spacing) / 2, (width - 16) * aspect + 44))
            let cells: [Simulation?] = [nil] + Simulation.allCases
            VStack(spacing: spacing) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: spacing) {
                        ForEach(0..<4, id: \.self) { col in
                            GridTile(model: model, mode: cells[row * 4 + col], size: tile)
                        }
                    }
                }
            }
            .padding(pad)
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct GridTile: View {
    @ObservedObject var model: SightModel
    let mode: Simulation?
    let size: CGSize
    @State private var hovering = false

    var body: some View {
        let selected = mode == model.mode
        let image = fitted(model.pixelSize, in: CGSize(width: size.width - 16, height: size.height - 44))
        VStack(spacing: 8) {
            FramedImage(image: mode.map { model.previews[$0] } ?? model.original)
                .frame(width: image.width, height: image.height)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            HStack(spacing: 5) {
                Text(mode?.name ?? "Original").font(.system(size: 12, weight: .semibold))
                if let mode, mode.isAnomalous {
                    Text("\(Int((model.severity * 100).rounded()))%")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(selected ? 0.6 : hovering ? 0.3 : 0))
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let mode { model.mode = mode; withAnimation(.snappy) { model.layout = .single } } }
        .onTapGesture { if let mode { withAnimation(.snappy) { model.mode = mode } } }
        .onHover { hovering = $0 }
        .help(mode.map { "\($0.cones). Double-click to view it alone." } ?? "The image as it is")
        .animation(.snappy(duration: 0.15), value: selected)
        .frame(width: size.width, height: size.height)
    }
}

struct BottomBar: View {
    @ObservedObject var model: SightModel

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.layout == .grid ? "All simulations" : model.mode.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(caption).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            if model.layout == .grid || model.mode.isAnomalous {
                HStack(spacing: 8) {
                    Text("Severity").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
                    Slider(value: $model.severity, in: 0.1...1)
                        .controlSize(.small)
                        .frame(width: 150)
                    Text("\(Int((model.severity * 100).rounded()))%")
                        .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.severity)
                }
                .help("How weak the affected cones are (⌘+ and ⌘-)")
            } else {
                Text("Full strength").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider().frame(height: 18)
            Text("\(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(.bar)
    }

    private var caption: String {
        switch model.layout {
        case .grid: "Click a tile to pick it, double-click to view it alone"
        case .split: "\(model.mode.cones), \(model.mode.prevalence.lowercased(with: nil)). Drag to compare with the original"
        case .single: "\(model.mode.cones), \(model.mode.prevalence.lowercased(with: nil)). Hold the image to see the original"
        }
    }
}

struct SavedToast: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text("Saved \(url.lastPathComponent)").font(.system(size: 12, weight: .medium)).lineLimit(1)
            Button("Show in Finder") { revealInFinder([url]); dismiss() }.controlSize(.small)
            Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

/// The window the website shows: the sample design, split against deuteranopia.
struct DemoRoot: View {
    @StateObject private var model = SightModel.demo
    var body: some View { ContentView(model: model) }
}
