import AVKit
import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 1.0, green: 0x9A / 255, blue: 0x3C / 255)
    static let bottom = Color(red: 0xE0 / 255, green: 0x44 / 255, blue: 0x2B / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let stripHeight: CGFloat = 64
}

struct ContentView: View {
    @ObservedObject var model: TrimModel
    @State private var isTargeted = false

    var body: some View {
        Group {
            if model.hasClip {
                EditorView(model: model)
            } else if model.isLoading {
                ProgressView("Opening").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DropZone(symbol: "film.stack", title: "Drop a video or audio file",
                         message: "Set the in and out points, then export the range without re-encoding.",
                         button: "Open File", tint: Theme.bottom, isTargeted: isTargeted) { model.showOpenPanel() }
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.open(url)
            return true
        } isTargeted: { isTargeted = $0 }
        .navigationTitle(model.url?.deletingPathExtension().lastPathComponent ?? "Trim")
        .navigationSubtitle(model.info?.summary ?? "")
        .toolbar { TrimToolbar(model: model) }
        .alert("Can't open file", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }
}

struct TrimToolbar: ToolbarContent {
    @ObservedObject var model: TrimModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showOpenPanel() } label: { Label("Open", systemImage: "folder") }
                .help("Open a video or audio file (⌘O)")
            Toggle(isOn: $model.audioOnly) { Label("Audio Only", systemImage: "waveform") }
                .help("Export only the audio, without re-encoding (⇧⌘A)")
                .disabled(!model.hasClip || model.info?.hasAudio != true || model.info?.hasVideo != true || model.isExporting)
            Button { model.revealExport() } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                .help("Show the exported file in Finder (⇧⌘R)")
                .disabled(model.lastExport == nil)
            Button { model.export() } label: { Label("Export", systemImage: "scissors") }
                .help("Export the selection without re-encoding (⇧⌘E)")
                .disabled(!model.canExport)
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        VStack(spacing: 0) {
            PreviewView(model: model)
                .padding([.horizontal, .top], 16)
            TransportBar(model: model)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            TimelineView(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            Divider().opacity(0.6)
            InfoBar(model: model)
        }
        .focusEffectDisabled()
    }
}

struct PreviewView: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        ZStack {
            Color.black
            if model.isDemo {
                DemoScene(phase: model.currentTime / max(1, model.duration))
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else if model.info?.hasVideo == true, let player = model.player {
                PlayerLayerView(player: player)
            } else {
                AudioArtwork(name: model.url?.lastPathComponent ?? "")
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isPlaying && model.rate != 1 {
                Text(model.rate < 0 ? "\(Int(-model.rate))× reverse" : "\(Int(model.rate))×")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.12)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 200)
        .animation(.snappy(duration: 0.2), value: model.rate)
    }
}

/// AVKit's player view without its own controls: Trim's transport and timeline drive it.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct AudioArtwork: View {
    let name: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Theme.gradient)
            Text(name)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Timecode.string(model.currentTime))
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("of \(Timecode.string(model.duration))")
                    .font(.system(size: 12, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                TransportButton(symbol: "backward.end.fill", help: "Go to In Point (⇧I)") { model.goToIn() }
                TransportButton(symbol: "backward.fill", help: "Play Backward (J)") { model.playBackward() }
                TransportButton(symbol: "backward.frame.fill", help: "Previous Frame (←)") { model.step(-1) }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Theme.gradient))
                        .shadow(color: Theme.bottom.opacity(0.35), radius: 5, y: 2)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(model.isPlaying ? "Pause (Space)" : "Play (Space)")
                .padding(.horizontal, 6)
                TransportButton(symbol: "forward.frame.fill", help: "Next Frame (→)") { model.step(1) }
                TransportButton(symbol: "forward.fill", help: "Play Forward (L)") { model.playForward() }
                TransportButton(symbol: "forward.end.fill", help: "Go to Out Point (⇧O)") { model.goToOut() }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                MarkButton(title: "In", key: "I", help: "Set the in point at the playhead") { model.setIn() }
                MarkButton(title: "Out", key: "O", help: "Set the out point at the playhead") { model.setOut() }
                Button { model.playSelection() } label: {
                    Image(systemName: "play.square").font(.system(size: 15, weight: .medium)).frame(width: 30, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Play Selection (/)")
            }
            .frame(width: 200, alignment: .trailing)
        }
    }
}

struct TransportButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(.quaternary.opacity(hovering ? 0.8 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct MarkButton: View {
    let title: String
    let key: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: .medium))
                KeyCap(key)
            }
        }
        .controlSize(.regular)
        .help("\(help) (\(key))")
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @ObservedObject var model: TrimModel
    @State private var drag: DragTarget?
    @State private var dragStart = TrimRange(duration: 0)
    @State private var hoverHandle = false

    enum DragTarget { case start, end, playhead }
    static let handle: CGFloat = 13

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                let inX = x(model.range.start, width), outX = x(model.range.end, width)
                ZStack(alignment: .topLeading) {
                    strip(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    // Dim what will be cut.
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, inX), height: Theme.stripHeight)
                        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, style: .continuous))
                    Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, width - outX), height: Theme.stripHeight).offset(x: outX)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8, style: .continuous))
                    SelectionFrame(isActive: drag == .start || drag == .end || hoverHandle)
                        .frame(width: max(Self.handle * 2, outX - inX), height: Theme.stripHeight)
                        .offset(x: min(inX, width - Self.handle * 2))
                    Playhead()
                        .offset(x: x(model.currentTime, width) - 6, y: -6)
                        .allowsHitTesting(false)
                }
                .frame(height: Theme.stripHeight)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    dragChanged(value, width: width)
                }.onEnded { _ in dragEnded() })
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        let near = abs(p.x - inX - Self.handle / 2) < Self.handle || abs(p.x - outX + Self.handle / 2) < Self.handle
                        if near != hoverHandle {
                            hoverHandle = near
                            near ? NSCursor.resizeLeftRight.push() : NSCursor.pop()
                        }
                    case .ended:
                        if hoverHandle { hoverHandle = false; NSCursor.pop() }
                    }
                }
            }
            .frame(height: Theme.stripHeight)
            Ruler(duration: model.duration)
                .frame(height: 14)
        }
    }

    @ViewBuilder
    private func strip(width: CGFloat) -> some View {
        let count = TrimModel.thumbnailCount
        let cell = width / CGFloat(count)
        if model.isDemo {
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    DemoScene(phase: (Double(i) + 0.5) / Double(count))
                        .frame(width: cell, height: Theme.stripHeight)
                        .clipped()
                }
            }
        } else if model.info?.hasVideo == true {
            HStack(spacing: 0) {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 2)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: cell, height: Theme.stripHeight)
                        .clipped()
                }
            }
            .frame(width: width, height: Theme.stripHeight, alignment: .leading)
            .background(Color.black.opacity(0.85))
            .overlay { if model.thumbnails.isEmpty { ProgressView().controlSize(.small).tint(.white) } }
        } else {
            Waveform(peaks: model.waveform)
                .frame(width: width, height: Theme.stripHeight)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.quaternary))
                .overlay { if model.waveform.isEmpty { ProgressView().controlSize(.small) } }
        }
    }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        model.duration > 0 ? CGFloat(t / model.duration) * width : 0
    }

    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        width > 0 ? model.range.clamp(Double(x / width) * model.duration) : 0
    }

    private func dragChanged(_ value: DragGesture.Value, width: CGFloat) {
        guard model.hasClip else { return }
        if drag == nil {
            let inX = x(model.range.start, width), outX = x(model.range.end, width)
            let p = value.startLocation.x
            let dIn = abs(p - (inX + Self.handle / 2)), dOut = abs(p - (outX - Self.handle / 2))
            if min(dIn, dOut) < Self.handle {
                drag = dIn < dOut || (dIn == dOut && p < inX) ? .start : .end
            } else {
                drag = .playhead
            }
            dragStart = model.range
            model.pause()
        }
        let t = time(value.location.x, width)
        switch drag {
        case .start:
            model.range.setStart(t)
            model.seek(to: model.range.start)
        case .end:
            model.range.setEnd(t)
            model.seek(to: model.range.end)
        default:
            model.seek(to: t)
        }
    }

    private func dragEnded() {
        if drag == .start || drag == .end {
            model.commit(from: dragStart, to: model.range, name: drag == .start ? "Move In Point" : "Move Out Point")
        }
        drag = nil
    }
}

/// The selection: a tangerine frame with a grip at each end.
struct SelectionFrame: View {
    let isActive: Bool

    var body: some View {
        let h = TimelineView.handle
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.gradient, lineWidth: 3)
            HStack(spacing: 0) {
                grip(leading: true).frame(width: h)
                Spacer(minLength: 0)
                grip(leading: false).frame(width: h)
            }
        }
        .shadow(color: Theme.bottom.opacity(isActive ? 0.55 : 0.3), radius: isActive ? 6 : 3)
        .animation(.snappy(duration: 0.15), value: isActive)
    }

    private func grip(leading: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 8 : 0, bottomLeadingRadius: leading ? 8 : 0,
                               bottomTrailingRadius: leading ? 0 : 8, topTrailingRadius: leading ? 0 : 8, style: .continuous)
            .fill(Theme.gradient)
            .overlay {
                Image(systemName: leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.9))
            }
    }
}

struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(.white).frame(width: 12, height: 7)
            Rectangle().fill(.white).frame(width: 2, height: Theme.stripHeight + 4)
        }
        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

struct Waveform: View {
    let peaks: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            let mid = size.height / 2
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let h = max(1, CGFloat(p) * (size.height / 2 - 6))
                path.addRect(CGRect(x: CGFloat(i) * step, y: mid - h, width: max(1, step * 0.7), height: h * 2))
            }
            ctx.fill(path, with: .linearGradient(Gradient(colors: [Theme.top, Theme.bottom]),
                                                 startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
        }
    }
}

struct Ruler: View {
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0 else { return }
            let step = Timecode.rulerStep(duration: duration, count: max(2, Int(size.width / 90)))
            var t = 0.0
            while t <= duration + 0.001 {
                let x = CGFloat(t / duration) * size.width
                ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: 4)), with: .color(.secondary.opacity(0.6)))
                let label = ctx.resolve(Text(Timecode.short(t)).font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary))
                let w = label.measure(in: size).width
                ctx.draw(label, at: CGPoint(x: min(max(x, w / 2), size.width - w / 2), y: 9), anchor: .center)
                t += step
            }
        }
    }
}

// MARK: - Info bar

struct InfoBar: View {
    @ObservedObject var model: TrimModel

    var body: some View {
        HStack(spacing: 22) {
            Stat(label: "In", value: Timecode.string(model.range.start))
            Stat(label: "Out", value: Timecode.string(model.range.end))
            Stat(label: "Length", value: Timecode.string(model.range.length))
            Stat(label: model.exportsAudioOnly ? "Audio only" : "Output", value: "About \(SizeEstimate.string(model.estimatedBytes))")
            Spacer(minLength: 12)
            exportArea
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.3))
        .animation(.snappy(duration: 0.25), value: model.exportState)
    }

    @ViewBuilder
    private var exportArea: some View {
        switch model.exportState {
        case .exporting(let progress):
            HStack(spacing: 10) {
                ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.bottom).frame(width: 160)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
                    .contentTransition(.numericText())
                Button("Cancel") { model.cancelExport() }.keyboardShortcut(.cancelAction)
            }
        case .done(let url, let reencoded):
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 15))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(reencoded ? "Saved, audio converted to AAC" : "Saved without re-encoding")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 220, alignment: .leading)
                Button("Reveal in Finder") { model.revealExport() }
                exportButton
            }
        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: 260, alignment: .leading)
                exportButton
            }
        case .idle:
            exportButton
        }
    }

    private var exportButton: some View {
        Button { model.export() } label: {
            Label(model.exportsAudioOnly ? "Export Audio" : "Export", systemImage: "scissors")
        }
        .buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
        .disabled(!model.canExport)
        .opacity(model.canExport ? 1 : 0.5)
    }
}

struct Stat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
        }
    }
}

// MARK: - Demo scene

/// A painted dusk over hills and water, standing in for video frames in the website snapshot.
struct DemoScene: View {
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height, horizon = h * 0.64
            let dusk = phase
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: horizon + 1)), with: .linearGradient(
                Gradient(colors: [mix(0x312E81, 0x1E1B4B, dusk), mix(0xDB5A2C, 0x9F2D3A, dusk), mix(0xFFC371, 0xF08A4B, dusk)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: horizon)))
            // Sun, sinking as the clip goes on.
            let sun = CGPoint(x: w * (0.30 + 0.38 * dusk), y: horizon - h * (0.30 - 0.22 * dusk))
            let r = h * 0.075
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - r * 3, y: sun.y - r * 3, width: r * 6, height: r * 6)),
                     with: .radialGradient(Gradient(colors: [Color(hex: 0xFFE7A8, 0.55), Color(hex: 0xFFB866, 0)]),
                                           center: sun, startRadius: r, endRadius: r * 3))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2)), with: .color(Color(hex: 0xFFF4D6)))
            // Water and the sun's reflection.
            ctx.fill(Path(CGRect(x: 0, y: horizon, width: w, height: h - horizon)), with: .linearGradient(
                Gradient(colors: [mix(0xC2562F, 0x7A2E3A, dusk), mix(0x3B1D3A, 0x1A1230, dusk)]),
                startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: h)))
            for i in 0..<7 {
                let y = horizon + (h - horizon) * (0.08 + 0.13 * CGFloat(i))
                let len = r * (2.6 - 0.28 * CGFloat(i))
                ctx.fill(Path(roundedRect: CGRect(x: sun.x - len / 2, y: y, width: len, height: max(1, h * 0.012)), cornerRadius: h * 0.006),
                         with: .color(Color(hex: 0xFFD58A, 0.55 - 0.06 * Double(i))))
            }
            // Far hills, then the near hill with rooftops.
            ctx.fill(hill(w: w, base: horizon, height: h * 0.13, waves: 2.3, shift: 0.4), with: .color(mix(0xA8443A, 0x6B2A40, dusk).opacity(0.85)))
            var near = hill(w: w * 0.62, base: horizon, height: h * 0.22, waves: 1.1, shift: 1.2)
            for i in 0..<15 {
                let bx = w * (0.03 + 0.034 * CGFloat(i)), bw = w * (0.018 + 0.008 * CGFloat(i % 2))
                let ground = horizon - h * 0.22 * (0.55 + 0.45 * sin(Double(bx / (w * 0.62)) * .pi * 1.1 + 1.2))
                let bh = h * (0.035 + 0.03 * abs(sin(Double(i) * 2.3)))
                near.addRect(CGRect(x: bx, y: ground - bh, width: bw, height: bh + 2))
                if i == 6 { near.addRect(CGRect(x: bx + bw * 0.4, y: ground - bh - h * 0.06, width: bw * 0.2, height: h * 0.06)) }
            }
            ctx.fill(near, with: .color(mix(0x4A1D2E, 0x23122A, dusk)))
        }
    }

    private func hill(w: CGFloat, base: CGFloat, height: CGFloat, waves: Double, shift: Double) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: base))
            for i in 0...40 {
                let t = Double(i) / 40
                p.addLine(to: CGPoint(x: w * t, y: base - height * (0.55 + 0.45 * sin(t * .pi * waves + shift))))
            }
            p.addLine(to: CGPoint(x: w, y: base))
            p.closeSubpath()
        }
    }

    private func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func c(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) / 255 }
        let t = min(1, max(0, t))
        return Color(red: c(a, 16) * (1 - t) + c(b, 16) * t, green: c(a, 8) * (1 - t) + c(b, 8) * t, blue: c(a, 0) * (1 - t) + c(b, 0) * t)
    }
}

extension Color {
    init(hex: UInt32, _ opacity: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}
