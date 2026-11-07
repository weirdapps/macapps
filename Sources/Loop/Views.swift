import AVKit
import AppKit
import Kit
import SwiftUI

enum Theme {
    static let lime = Color(nsColor: rgb(0xA6E22E))
    static let green = Color(nsColor: rgb(0x2FA84F))
    static let deep = Color(nsColor: rgb(0x23913F))
    static let gradient = LinearGradient(colors: [lime, green], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    static func seconds(_ value: Double) -> String { String(format: "%.2f s", value) }
}

struct ContentView: View {
    @ObservedObject var model: LoopModel
    @Environment(\.undoManager) private var undoManager
    @State private var targeted = false

    var body: some View {
        Group {
            switch model.mode {
            case .empty:
                DropZone(symbol: "infinity", title: "Drop a video or images",
                         message: "Loop turns a clip (MOV, MP4) or a handful of pictures into an animated GIF.",
                         button: "Choose Files…", tint: Theme.green, isTargeted: targeted) { model.showOpenPanel() }
            case .video, .images:
                HStack(spacing: 0) {
                    Group {
                        if model.mode == .video { VideoEditor(model: model) } else { ImageEditor(model: model) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .center) {
                        if targeted {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.green, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    Divider()
                    Inspector(model: model).frame(width: 300)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .focusEffectDisabled(Desktop.isSnapshot)
        .navigationTitle(model.mode == .empty ? "Loop" : model.sourceName)
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls)
            return true
        } isTargeted: { targeted = $0 }
        .toolbar { toolbar }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .alert("Loop", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { model.isExporting }, set: { _ in })) {
            ExportSheet(model: model)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.showOpenPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a video or images (⌘O)")
            if model.mode == .images {
                Button { model.showAddImagesPanel() } label: { Label("Add Images", systemImage: "plus.rectangle.on.rectangle") }
                    .help("Add images to the end (⇧⌘O)")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode != .empty {
                Button { model.reset() } label: { Label("Start Over", systemImage: "arrow.counterclockwise") }
                    .help("Close this source and start over (⌘N)")
            }
            Button { model.beginExport() } label: { Label("Export GIF", systemImage: "square.and.arrow.up") }
                .help("Export the animated GIF (⌘E)")
                .disabled(!model.canExport)
        }
    }
}

// MARK: - Video

struct VideoEditor: View {
    @ObservedObject var model: LoopModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black)
                Group {
                    if let player = model.player, !Desktop.isSnapshot {
                        PlayerView(player: player)
                    } else if let poster = model.poster {
                        Image(decorative: poster, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                if model.isLoading { ProgressView().controlSize(.large).tint(.white) }
            }
            .aspectRatio(model.sourceSize.width > 0 ? model.sourceSize : CGSize(width: 16, height: 9), contentMode: .fit)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.gradient))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "Pause (Space)" : "Play the selected range (Space)")
                HStack(spacing: 4) {
                    Text(Timing.timecode(model.currentTime)).foregroundStyle(.primary)
                    Text("/").foregroundStyle(.tertiary)
                    Text(Timing.timecode(model.duration)).foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                Spacer()
                Button("Set In") { model.setInAtPlayhead() }.help("Start the GIF at the playhead (I)")
                Button("Set Out") { model.setOutAtPlayhead() }.help("End the GIF at the playhead (O)")
                Button("Whole Clip") { model.useWholeClip() }.help("Use the whole video (⌥⌘A)")
            }
            .controlSize(.regular)

            RangeTimeline(model: model)

            HStack {
                Label(Timing.timecode(model.inPoint), systemImage: "arrow.right.to.line")
                Spacer()
                Text("\(Theme.seconds(model.outPoint - model.inPoint)) selected")
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Label(Timing.timecode(model.outPoint), systemImage: "arrow.left.to.line")
                    .labelStyle(TrailingIconLabelStyle())
            }
            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
            .animation(.snappy, value: model.outPoint - model.inPoint)
        }
        .padding(20)
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.title; configuration.icon }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// Thumbnails of the whole clip with a trim range on top: drag the handles to set in and out, click to move the playhead.
struct RangeTimeline: View {
    @ObservedObject var model: LoopModel
    private let height: CGFloat = 56
    private let handle: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - handle * 2
            let duration = max(model.duration, 0.001)
            let xIn = handle + w * model.inPoint / duration
            let xOut = handle + w * model.outPoint / duration
            let time = { (x: CGFloat) in Double((x - handle) / w) * duration }

            ZStack(alignment: .topLeading) {
                strip
                    .frame(width: w, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .offset(x: handle)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                        .onChanged { model.seek(to: time($0.location.x)) })
                // Dim what falls outside the range.
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, xIn - handle), height: height)
                    .offset(x: handle)
                    .allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.5))
                    .frame(width: max(0, handle + w - xOut), height: height)
                    .offset(x: xOut)
                    .allowsHitTesting(false)
                // The selected range.
                Rectangle()
                    .strokeBorder(Theme.gradient, lineWidth: 3)
                    .frame(width: max(0, xOut - xIn), height: height)
                    .offset(x: xIn)
                    .allowsHitTesting(false)
                // Playhead.
                Capsule().fill(.white)
                    .frame(width: 3, height: height + 10)
                    .shadow(color: .black.opacity(0.45), radius: 2)
                    .offset(x: handle + w * model.currentTime / duration - 1.5, y: -5)
                    .allowsHitTesting(false)
                TrimHandle(edge: .leading)
                    .frame(width: handle, height: height)
                    .offset(x: xIn - handle)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged {
                        model.setIn(time($0.location.x + handle / 2))
                        model.seek(to: model.inPoint)
                    })
                TrimHandle(edge: .trailing)
                    .frame(width: handle, height: height)
                    .offset(x: xOut)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged {
                        model.setOut(time($0.location.x - handle / 2))
                        model.seek(to: model.outPoint)
                    })
            }
            .coordinateSpace(name: "timeline")
        }
        .frame(height: height)
        .padding(.top, 5)
    }

    private var strip: some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                Rectangle().fill(.quaternary)
            } else {
                ForEach(model.thumbnails.indices, id: \.self) { i in
                    Color.clear.overlay {
                        Image(decorative: model.thumbnails[i], scale: 1).resizable().aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                }
            }
        }
    }
}

struct TrimHandle: View {
    let edge: HorizontalEdge
    @State private var hovering = false

    var body: some View {
        UnevenRoundedRectangle(cornerRadii: edge == .leading ? .init(topLeading: 6, bottomLeading: 6) : .init(bottomTrailing: 6, topTrailing: 6),
                               style: .continuous)
            .fill(Theme.gradient)
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.9)).frame(width: 4, height: 2) }
                }
            }
            .brightness(hovering ? 0.06 : 0)
            .onHover { hovering = $0 }
            .help(edge == .leading ? "Drag to set where the GIF starts" : "Drag to set where the GIF ends")
    }
}

// MARK: - Images

struct ImageEditor: View {
    @ObservedObject var model: LoopModel
    @State private var dragging: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let frame = model.selectedFrame ?? model.frames.first {
                    Image(decorative: frame.image, scale: 1).resizable().interpolation(.high)
                        .background(Checkerboard())
                        .aspectRatio(CGSize(width: frame.image.width, height: frame.image.height), contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                } else if model.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)

            if let i = model.selectedIndex {
                Text("Frame \(i + 1) of \(model.frames.count) · \(model.frames[i].name) · \(Theme.seconds(model.frames[i].delay))")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.bottom, 10)
            }
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(Array(model.frames.enumerated()), id: \.element.id) { index, frame in
                        FrameCard(frame: frame, index: index, selected: frame.id == model.selection)
                            .opacity(dragging == frame.id ? 0.4 : 1)
                            .onTapGesture { model.selection = frame.id }
                            .onDrag {
                                dragging = frame.id
                                model.selection = frame.id
                                model.beginReorder()
                                return NSItemProvider(object: frame.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: FrameDropDelegate(target: frame.id, model: model, dragging: $dragging))
                            .contextMenu {
                                Button("Move Left") { model.selection = frame.id; model.moveSelectedFrame(by: -1) }.disabled(index == 0)
                                Button("Move Right") { model.selection = frame.id; model.moveSelectedFrame(by: 1) }
                                    .disabled(index == model.frames.count - 1)
                                Divider()
                                Button("Delete Frame") { model.selection = frame.id; model.deleteSelectedFrame() }
                            }
                    }
                    Button { model.showAddImagesPanel() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                            Text("Add").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(width: 72, height: 96)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add images to the end (⇧⌘O)")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .animation(.snappy(duration: 0.22), value: model.frames.map(\.id))
            }
            .frame(height: 140)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
    }
}

struct FrameCard: View {
    let frame: ImageFrame
    let index: Int
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topLeading) {
                Checkerboard()
                Color.clear.overlay {
                    Image(decorative: frame.image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                }
                .clipped()
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(5)
            }
            .frame(width: 104, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary), lineWidth: selected ? 3 : 1)
            }
            .scaleEffect(hovering && !selected ? 1.03 : 1)
            Text(Theme.seconds(frame.delay))
                .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(selected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.15), value: selected)
    }
}

struct FrameDropDelegate: DropDelegate {
    let target: UUID
    let model: LoopModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.snappy(duration: 0.22)) { model.liveMove(dragging, to: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        model.endReorder()
        return true
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 10
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.97)))
            for row in 0...Int(size.height / s) {
                for col in 0...Int(size.width / s) where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)), with: .color(Color(white: 0.9)))
                }
            }
        }
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: LoopModel

    private var tooLarge: Bool { (model.estimatedBytes ?? 0) > 15_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    AnimationPreview(frames: model.previewFrames, delays: model.previewDelays, paused: model.previewPaused)
                        .aspectRatio(model.outputSize.width > 0 ? model.outputSize : CGSize(width: 16, height: 9), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 190)
                        .overlay(alignment: .topTrailing) {
                            if model.isRenderingPreview && !model.previewFrames.isEmpty {
                                ProgressView().controlSize(.small).padding(8)
                            }
                        }
                    HStack {
                        Text("\(model.frameCount) frames · \(Theme.seconds(model.outputDuration))")
                            .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                        Spacer()
                        Button { model.previewPaused.toggle() } label: {
                            Image(systemName: model.previewPaused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.borderless)
                        .help(model.previewPaused ? "Play the preview (⌥⌘P)" : "Pause the preview (⌥⌘P)")
                    }
                } header: {
                    Text("Preview")
                }

                Section("Output") {
                    if model.mode == .video {
                        LabeledContent("Frame rate") {
                            SliderRow(value: $model.fps, range: Timing.fpsRange, step: 1, label: "\(Int(model.fps)) fps")
                        }
                    }
                    LabeledContent("Width") {
                        SliderRow(value: $model.width, range: model.widthRange, step: 10, label: "\(Int(model.outputSize.width)) px")
                    }
                    Picker("Repeat", selection: $model.repeatMode) {
                        ForEach(Repeat.allCases) { Text($0.title).tag($0) }
                    }
                }

                if model.mode == .images, let frame = model.selectedFrame, let index = model.selectedIndex {
                    Section("Frame \(index + 1)") {
                        LabeledContent("Delay") {
                            Stepper(value: Binding(get: { frame.delay }, set: { model.setDelay($0, for: frame.id) }),
                                    in: 0.02...10, step: 0.05) {
                                Text(Theme.seconds(frame.delay)).monospacedDigit()
                            }
                        }
                        Button("Use This Delay for All Frames") { model.applySelectedDelayToAll() }
                            .disabled(model.frames.allSatisfy { $0.delay == frame.delay })
                    }
                }

            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(Theme.green)

            Divider()
            VStack(spacing: 12) {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Estimated size").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        Text(model.estimatedBytes.map(Theme.bytes) ?? "…")
                            .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tooLarge ? AnyShapeStyle(.orange) : AnyShapeStyle(Theme.gradient))
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text(tooLarge ? "Large: try a smaller width" : "Approximate")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
                .animation(.snappy, value: model.estimatedBytes)
                if let url = model.lastExport {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("Saved, \(Theme.bytes(model.lastExportBytes))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show in Finder") { model.revealLastExport() }.controlSize(.small)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                Button { model.beginExport() } label: {
                    Label("Export GIF…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ExportButtonStyle())
                .disabled(!model.canExport)
                .help("Export the animated GIF (⌘E)")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .animation(.snappy, value: model.lastExport)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The primary action: a full-width button in the app's gradient.
struct ExportButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: rgb(0x5CC93F)), Theme.deep], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.18)))
            .shadow(color: Theme.deep.opacity(isEnabled ? 0.35 : 0), radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
            .opacity(isEnabled ? 1 : 0.45)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// A slider without tick marks, snapped to `step`, with its value on the right.
struct SliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .labelsHidden().frame(width: 104)
            Text(label)
                .font(.body.monospacedDigit())
                .frame(width: 54, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }
}

/// Plays the rendered frames with their own delays, like the GIF will.
struct AnimationPreview: View {
    let frames: [CGImage]
    let delays: [Double]
    let paused: Bool

    var body: some View {
        ZStack {
            Checkerboard()
            if frames.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                TimelineView(.animation(paused: paused)) { context in
                    Image(decorative: frames[index(at: context.date)], scale: 1)
                        .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
    }

    private func index(at date: Date) -> Int {
        let total = delays.prefix(frames.count).reduce(0, +)
        guard total > 0 else { return 0 }
        var t = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
        for (i, delay) in delays.prefix(frames.count).enumerated() {
            if t < delay { return i }
            t -= delay
        }
        return frames.count - 1
    }
}

struct ExportSheet: View {
    @ObservedObject var model: LoopModel

    var body: some View {
        let progress = model.exportProgress ?? 0
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "infinity")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exporting \(model.sourceName).gif").font(.headline).lineLimit(1)
                    Text("Frame \(min(model.frameCount, Int((progress * Double(model.frameCount)).rounded()))) of \(model.frameCount)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: progress).tint(Theme.green)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelExport() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
