import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 0xC0 / 255, green: 0x39 / 255, blue: 0x2B / 255)
    static let bottom = Color(red: 0x6E / 255, green: 0x14 / 255, blue: 0x23 / 255)
    static let accent = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let woodLight = Color(red: 0xD9 / 255, green: 0xA4 / 255, blue: 0x6C / 255)
    static let woodDark = Color(red: 0x8A / 255, green: 0x55 / 255, blue: 0x2A / 255)
}

struct ContentView: View {
    @ObservedObject var model: BeatModel

    var body: some View {
        NavigationSplitView {
            PresetList(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 300)
        } detail: {
            MetronomeView(model: model)
        }
        .frame(minWidth: 840, minHeight: 650)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.tap() } label: { Label("Tap Tempo", systemImage: "hand.tap") }
                    .help("Tap tempo (T)")
                Button { model.toggle() } label: {
                    Label(model.isPlaying ? "Stop" : "Start", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                }
                .help(model.isPlaying ? "Stop (Space)" : "Start (Space)")
            }
        }
        .sheet(item: $model.naming) { request in
            NameSheet(request: request) { model.naming = nil }
                .environmentObject(model)
        }
    }
}

// MARK: - Presets

struct PresetList: View {
    @ObservedObject var model: BeatModel
    @Environment(\.undoManager) private var undo

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("Presets") {
                ForEach(model.presets) { preset in
                    PresetRow(preset: preset, isLive: model.isPlaying && preset.id == model.selection,
                              isEdited: preset.id == model.selection && model.isEdited)
                        .tag(preset.id)
                        .contextMenu {
                            Button("Update with Current Settings") { model.updatePreset(preset.id, undo: undo) }
                            if preset.id == model.selection && model.isEdited {
                                Button("Revert to Preset") { model.revertToPreset() }
                            }
                            Button("Rename…") { model.requestRename(preset.id) }
                            Divider()
                            Button("Delete") { model.deletePreset(preset.id, undo: undo) }
                        }
                }
                .onMove { model.movePresets(from: $0, to: $1, undo: undo) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.presets.isEmpty {
                ContentUnavailableView {
                    Label("No Presets", systemImage: "metronome")
                } description: {
                    Text("Save the tempo and meter you use most with New Preset.")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.requestNewPreset() } label: {
                    Label("New Preset", systemImage: "plus").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .help("Save the current settings as a preset (⌘N)")
                Spacer()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

struct PresetRow: View {
    let preset: Preset
    let isLive: Bool
    var isEdited = false

    var body: some View {
        HStack(spacing: 9) {
            Text(preset.signature.rawValue)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 32, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text("\(preset.bpm) BPM, \(preset.subdivision == .none ? "quarters" : preset.subdivision.label.lowercased())")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 0)
            if isEdited {
                Circle().fill(Theme.top).frame(width: 6, height: 6).help("Edited since the preset was chosen")
            }
            if isLive {
                Image(systemName: "waveform").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
        }
        .padding(.vertical, 3)
    }
}

struct NameSheet: View {
    @State var request: NameRequest
    let cancel: () -> Void
    @Environment(\.undoManager) private var undo
    @EnvironmentObject private var model: BeatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Preset" : "Rename Preset").font(.system(size: 15, weight: .semibold, design: .rounded))
            if isNew {
                Text("Saves \(model.config.bpm) BPM in \(model.config.signature.rawValue) with the current subdivision and sound.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Name", text: $request.text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.finishNaming(request, undo: undo) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(isNew ? "Save" : "Rename") { model.finishNaming(request, undo: undo) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(request.text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var isNew: Bool { if case .new = request.kind { true } else { false } }
}

// MARK: - Metronome

struct MetronomeView: View {
    @ObservedObject var model: BeatModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .center, spacing: 24) {
                TempoPanel(model: model).frame(maxWidth: .infinity)
                PendulumView(model: model).frame(width: 240, height: 300)
            }
            BeatStrip(model: model)
            ControlsCard(model: model)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space, phases: .down) { _ in model.toggle(); return .handled }
        .onKeyPress("t", phases: .down) { _ in model.tap(); return .handled }
        .onAppear { focused = true }
        .navigationTitle("Beat")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        guard let preset = model.selectedPreset else { return Tempo.marking(model.config.bpm) }
        return model.isEdited ? "\(preset.name), edited" : preset.name
    }
}

struct TempoPanel: View {
    @ObservedObject var model: BeatModel
    @State private var dragStart: Int?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 14) {
            Text(Tempo.marking(model.config.bpm).uppercased())
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(2.4)
                .foregroundStyle(Theme.top)
                .contentTransition(.opacity)
            HStack(spacing: 18) {
                RoundButton(symbol: "minus", help: "Slower (⌘↓)") { model.nudge(-1) }
                VStack(spacing: 0) {
                    Text("\(model.config.bpm)")
                        .font(.system(size: 112, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.config.bpm)))
                        .frame(width: 220)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("BEATS PER MINUTE")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .gesture(drag)
                .onHover { inside in
                    if inside != hovering { inside ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
                    hovering = inside
                }
                .help("Drag up or down to change the tempo")
                RoundButton(symbol: "plus", help: "Faster (⌘↑)") { model.nudge(1) }
            }
            Slider(value: Binding(get: { Double(model.config.bpm) }, set: { model.setBPM(Int($0.rounded())) }),
                   in: Double(Tempo.range.lowerBound)...Double(Tempo.range.upperBound)) {
                Text("Tempo")
            } minimumValueLabel: {
                Text("30").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("300").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            .labelsHidden()
            .tint(Theme.top)
            .frame(maxWidth: 380)
            HStack(spacing: 12) {
                Button { model.tap() } label: {
                    Label("Tap", systemImage: "hand.tap.fill").frame(minWidth: 70)
                }
                .controlSize(.large)
                .help("Tap at least twice to set the tempo (T)")
                Button { model.toggle() } label: {
                    Label(model.isPlaying ? "Stop" : "Start", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
                        .frame(minWidth: 96)
                }
                .buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
                .help("Start or stop (Space)")
            }
            .padding(.top, 2)
            if let error = model.audioError {
                Label(error, systemImage: "speaker.slash").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.18), value: model.config.bpm)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStart ?? model.config.bpm
                dragStart = start
                model.setBPM(start + Int((-value.translation.height / 3).rounded()))
            }
            .onEnded { _ in dragStart = nil }
    }
}

struct RoundButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.quaternary.opacity(hovering ? 0.95 : 0.55)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Beat strip

struct BeatStrip: View {
    @ObservedObject var model: BeatModel

    var body: some View {
        TimelineView(.animation(paused: !model.isPlaying)) { context in
            let phase = model.phase(at: context.date)
            let sig = model.config.signature
            HStack(spacing: 10) {
                ForEach(0..<sig.beats, id: \.self) { i in
                    BeatCell(number: i + 1, isDownbeat: i == 0 && model.config.accent,
                             isGroup: i != 0 && model.config.accent && sig.groupStarts.contains(i),
                             ticks: model.config.subdivision.ticks,
                             lit: phase.flatMap { $0.beatInBar == i ? $0 : nil })
                }
            }
        }
        .frame(height: 88)
        .animation(.snappy(duration: 0.22), value: model.config.signature)
    }
}

struct BeatCell: View {
    let number: Int
    let isDownbeat: Bool
    let isGroup: Bool
    let ticks: Int
    let lit: BeatPhase?

    var body: some View {
        let glow = lit.map { 1 - 0.55 * $0.fraction } ?? 0
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.35))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDownbeat ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.top.opacity(0.78).gradient))
                .opacity(glow)
                .shadow(color: Theme.top.opacity(0.45 * glow), radius: 10, y: 3)
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("\(number)")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if isDownbeat || isGroup {
                        Image(systemName: isDownbeat ? "chevron.up.2" : "chevron.up")
                            .font(.system(size: 9, weight: .heavy))
                            .opacity(0.8)
                    }
                }
                .foregroundStyle(lit != nil ? AnyShapeStyle(.white) : isDownbeat ? AnyShapeStyle(Theme.top) : AnyShapeStyle(.secondary))
                HStack(spacing: 5) {
                    ForEach(0..<ticks, id: \.self) { t in
                        Circle()
                            .fill(lit != nil ? AnyShapeStyle(.white.opacity(lit?.tick == t ? 1 : 0.4))
                                             : AnyShapeStyle(.secondary.opacity(0.35)))
                            .frame(width: 6, height: 6)
                    }
                }
                .opacity(ticks > 1 ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Pendulum

/// A pyramid metronome. The rod swings from one side to the other each beat, and the weight sits higher
/// on the rod for slower tempos, like the real thing.
struct PendulumView: View {
    @ObservedObject var model: BeatModel

    var body: some View {
        TimelineView(.animation(paused: !model.isPlaying)) { context in
            let position = model.phase(at: context.date)?.position
            Canvas { ctx, size in
                draw(in: &ctx, size: size, position: position)
            }
            .shadow(color: .black.opacity(0.22), radius: 12, y: 7)
        }
        .accessibilityLabel("Pendulum")
    }

    static func angle(at position: Double?) -> Double {
        guard let position else { return 0 }
        return 0.3 * cos(.pi * position)
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, position: Double?) {
        let w = size.width, h = size.height
        let baseY = h - 8, apexY: CGFloat = 8
        let half = w * 0.40, topHalf = w * 0.11
        let cx = w / 2

        // Body: a tapered case in the app's wine red.
        var body = Path()
        body.move(to: CGPoint(x: cx - topHalf, y: apexY))
        body.addLine(to: CGPoint(x: cx + topHalf, y: apexY))
        body.addLine(to: CGPoint(x: cx + half, y: baseY - 26))
        body.addLine(to: CGPoint(x: cx - half, y: baseY - 26))
        body.closeSubpath()
        ctx.fill(body, with: .linearGradient(Gradient(colors: [Theme.top, Theme.bottom]),
                                                  startPoint: CGPoint(x: 0, y: apexY), endPoint: CGPoint(x: 0, y: baseY)))
        // Plinth.
        let plinth = Path(roundedRect: CGRect(x: cx - half - 10, y: baseY - 30, width: (half + 10) * 2, height: 30), cornerRadius: 7)
        ctx.fill(plinth, with: .linearGradient(Gradient(colors: [Theme.woodLight, Theme.woodDark]),
                                                    startPoint: CGPoint(x: 0, y: baseY - 30), endPoint: CGPoint(x: 0, y: baseY)))
        // Wooden face behind the rod with a tempo scale.
        let faceTop = apexY + 22, faceBottom = baseY - 46
        var face = Path()
        let faceHalfTop = topHalf * 0.55, faceHalfBottom = half * 0.34
        face.move(to: CGPoint(x: cx - faceHalfTop, y: faceTop))
        face.addLine(to: CGPoint(x: cx + faceHalfTop, y: faceTop))
        face.addLine(to: CGPoint(x: cx + faceHalfBottom, y: faceBottom))
        face.addLine(to: CGPoint(x: cx - faceHalfBottom, y: faceBottom))
        face.closeSubpath()
        ctx.fill(face, with: .linearGradient(Gradient(colors: [Theme.woodLight, Theme.woodDark]),
                                             startPoint: CGPoint(x: cx - faceHalfBottom, y: 0), endPoint: CGPoint(x: cx + faceHalfBottom, y: 0)))
        for i in 0..<12 {
            let y = faceTop + 10 + CGFloat(i) * (faceBottom - faceTop - 24) / 11
            let len: CGFloat = i % 3 == 0 ? 9 : 5
            ctx.fill(Path(CGRect(x: cx - len / 2, y: y, width: len, height: 1.4)), with: .color(.black.opacity(0.35)))
        }
        // Edge highlight on the case.
        var edge = Path()
        edge.move(to: CGPoint(x: cx - topHalf + 2, y: apexY + 3))
        edge.addLine(to: CGPoint(x: cx - half + 5, y: baseY - 29))
        ctx.stroke(edge, with: .color(.white.opacity(0.22)), lineWidth: 2)

        // Rod and weight, pivoting near the base.
        let pivot = CGPoint(x: cx, y: faceBottom - 4)
        let length = pivot.y - apexY + 6
        let angle = Self.angle(at: position)
        let bpm = Double(model.config.bpm)
        let weightAt = 0.28 + 0.52 * (1 - (bpm - 30) / 270) // Fraction of the rod above the pivot.
        var rodCtx = ctx
        rodCtx.translateBy(x: pivot.x, y: pivot.y)
        rodCtx.rotate(by: .radians(angle))
        rodCtx.fill(Path(roundedRect: CGRect(x: -1.5, y: -length + 3, width: 7, height: length + 10), cornerRadius: 3.5),
                    with: .color(.black.opacity(0.22)))
        rodCtx.fill(Path(roundedRect: CGRect(x: -2.5, y: -length, width: 5, height: length + 10), cornerRadius: 2.5),
                    with: .linearGradient(Gradient(colors: [Color(white: 0.97), Color(white: 0.72)]),
                                          startPoint: CGPoint(x: -2.5, y: 0), endPoint: CGPoint(x: 2.5, y: 0)))
        let wy = -length * weightAt
        var weight = Path()
        weight.move(to: CGPoint(x: -11, y: wy - 12))
        weight.addLine(to: CGPoint(x: 11, y: wy - 12))
        weight.addLine(to: CGPoint(x: 17, y: wy + 12))
        weight.addLine(to: CGPoint(x: -17, y: wy + 12))
        weight.closeSubpath()
        rodCtx.fill(weight, with: .linearGradient(Gradient(colors: [Color(white: 0.98), Color(white: 0.66)]),
                                                  startPoint: CGPoint(x: -17, y: 0), endPoint: CGPoint(x: 17, y: 0)))
        // Pivot cap.
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 7, y: pivot.y - 7, width: 14, height: 14)), with: .color(Color(white: 0.9)))
        ctx.fill(Path(ellipseIn: CGRect(x: pivot.x - 3, y: pivot.y - 3, width: 6, height: 6)), with: .color(Theme.bottom))
    }
}

// MARK: - Controls

struct ControlsCard: View {
    @ObservedObject var model: BeatModel

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                label("Time signature")
                Picker("Time signature", selection: $model.config.signature) {
                    ForEach(TimeSignature.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                label("Subdivision")
                Picker("Subdivision", selection: $model.config.subdivision) {
                    ForEach(Subdivision.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                label("Sound")
                HStack(spacing: 18) {
                    Picker("Sound", selection: $model.config.sound) {
                        ForEach(Sound.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 220)
                    Toggle("Accent beat one", isOn: $model.config.accent).toggleStyle(.checkbox)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        Slider(value: $model.config.volume, in: 0...1).frame(width: 110).tint(Theme.top)
                        Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .help("Volume")
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.3)))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}
