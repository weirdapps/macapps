import AppKit
import Carbon.HIToolbox
import Kit
import SwiftUI

enum Theme {
    static let accent = [color(0xF6CF7A), color(0xD5873A)]
    static let cabinetTop = color(0x2A2A30)
    static let cabinetBottom = color(0x0B0B0E)
    static let felt = [color(0x9A2433), color(0x5E111C)]
    static let ivory = [color(0xFFFDF8), color(0xF1EBDD)]
    static let ivoryPressed = [color(0xFCEBC6), color(0xF1CB86)]
    static let ebony = [color(0x45454D), color(0x16161A)]
    static let ebonyPressed = [color(0xC98A3E), color(0x7A4A18)]
    static let ink = color(0x6E6656)

    static func color(_ hex: UInt32) -> Color { Color(nsColor: rgb(hex)) }
    static var accentGradient: LinearGradient { LinearGradient(colors: accent, startPoint: .topLeading, endPoint: .bottomTrailing) }
}

// MARK: - Window content

struct ContentView: View {
    @ObservedObject var model: PianoModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
            ControlDeck(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)
            LinearGradient(colors: Theme.felt, startPoint: .top, endPoint: .bottom)
                .frame(height: 6)
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.5)).frame(height: 1) }
            PianoView(model: model)
                .padding(.horizontal, 10)
            HintBar()
                .padding(.vertical, 9)
        }
        .background {
            ZStack {
                LinearGradient(colors: [Theme.cabinetTop, Theme.cabinetBottom], startPoint: .top, endPoint: .bottom)
                // A soft reflection across the lacquer.
                RadialGradient(colors: [.white.opacity(0.07), .clear], center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 520)
            }
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            if let url = model.exportedURL {
                ExportToast(url: url) { model.dismissExport() }
                    .padding(.bottom, 40)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.exportedURL)
        .background(KeyCatcher(model: model))
        .toolbar { toolbar }
        .navigationSubtitle("\(model.sound.title), \(model.rangeText)")
        .frame(minWidth: 860, minHeight: 480)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.toggleRecording(); model.requestFocus() } label: {
                Label(model.isRecording ? "Stop Recording" : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
            }
            .help(model.isRecording ? "Stop recording (⌘R)" : "Record a take (⌘R)")

            Button { model.togglePlayback(); model.requestFocus() } label: {
                Label(model.isPlaying ? "Stop" : "Play Take", systemImage: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .help(model.isPlaying ? "Stop playback (⌘↩)" : "Play the take (⌘↩)")
            .disabled(model.take == nil || model.isRecording)

            Button { model.export() } label: { Label("Export MIDI", systemImage: "square.and.arrow.up") }
                .help("Export the take as a MIDI file (⇧⌘E)")
                .disabled(model.take == nil || model.isRecording)
        }
    }
}

// MARK: - Controls

struct Module<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.42))
            content
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
    }
}

struct ControlDeck: View {
    @ObservedObject var model: PianoModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Module(title: "Sound") {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow { sound(.piano); sound(.electric) }
                    GridRow { sound(.organ); sound(.pad) }
                }
            }
            Module(title: "Octave") { OctaveControl(model: model) }
            Module(title: "Volume") { VolumeControl(model: model) }
            Module(title: "Sustain") { SustainControl(model: model) }
            Module(title: "Take") { TakePanel(model: model) }
        }
        .frame(height: 126)
    }

    private func sound(_ s: Sound) -> some View {
        SoundButton(sound: s, selected: model.sound == s) {
            model.sound = s
            model.requestFocus()
        }
    }
}

struct SoundButton: View {
    let sound: Sound
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: sound.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.white.opacity(0.6)))
                    .frame(width: 16)
                Text(sound.shortTitle)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.white.opacity(selected ? 0.95 : 0.72))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(width: 102, height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.accent[1].opacity(0.2)) : AnyShapeStyle(.white.opacity(hovering ? 0.09 : 0.04)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.white.opacity(0.06)),
                                          lineWidth: selected ? 1.2 : 1)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(sound.title)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: selected)
    }
}

struct OctaveControl: View {
    @ObservedObject var model: PianoModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                stepButton("chevron.left", delta: -1, enabled: model.baseOctave > PianoModel.octaves.lowerBound)
                VStack(spacing: 0) {
                    Text(Note.fullName(model.lowestNote))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("to \(Note.fullName(model.lowestNote + PianoLayout.span))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(width: 58)
                stepButton("chevron.right", delta: 1, enabled: model.baseOctave < PianoModel.octaves.upperBound)
            }
            HStack(spacing: 5) {
                KeyCap("Z")
                KeyCap("X")
                Text("shift").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .animation(.snappy, value: model.baseOctave)
    }

    private func stepButton(_ symbol: String, delta: Int, enabled: Bool) -> some View {
        GlassIconButton(symbol, help: delta < 0 ? "Octave down (Z)" : "Octave up (X)") {
            model.shiftOctave(delta)
            model.requestFocus()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

struct VolumeControl: View {
    @ObservedObject var model: PianoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                Slider(value: $model.volume, in: 0...1)
                    .controlSize(.small)
                    .tint(Theme.accent[1])
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(width: 140)
        .animation(.snappy, value: model.volume)
    }
}

struct SustainControl: View {
    @ObservedObject var model: PianoModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                model.sustainLatched.toggle()
                model.requestFocus()
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(model.sustain ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(.white.opacity(0.12)))
                        .frame(width: 12, height: 12)
                        .shadow(color: model.sustain ? Theme.accent[0].opacity(0.9) : .clear, radius: 6)
                    Text(model.sustain ? "On" : "Off")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(model.sustain ? 1 : 0.6))
                }
                .padding(.horizontal, 10)
                .frame(width: 96, height: 36, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovering ? 0.09 : 0.05)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(model.sustainLatched ? "Sustain is latched. Click to release." : "Hold Space for sustain, or click to latch it (⌘L)")
            HStack(spacing: 5) {
                KeyCap("Space")
                Text(model.sustainLatched ? "latched" : "hold").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .animation(.snappy(duration: 0.15), value: model.sustain)
    }
}

struct TakePanel: View {
    @ObservedObject var model: PianoModel

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !(model.isRecording || model.isPlaying))) { context in
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = model.elapsed(at: now)
            VStack(alignment: .leading, spacing: 8) {
                header(elapsed: elapsed)
                if model.isRecording {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 18)).foregroundStyle(.red.opacity(0.85))
                            .symbolEffect(.variableColor.iterative, isActive: true)
                        Text("Recording everything you play. Press ⌘R to stop.")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else if let take = model.take {
                    TakeRoll(take: take, playhead: model.isPlaying ? elapsed : nil, lowest: model.lowestNote)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle").font(.system(size: 18)).foregroundStyle(.white.opacity(0.35))
                        Text("Press Record, then play. Takes export as MIDI.")
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func header(elapsed: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if model.isRecording {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(TimeText.format(elapsed)).foregroundStyle(.white)
            } else if let take = model.take {
                if model.isPlaying {
                    Text(TimeText.format(min(elapsed, take.duration))).foregroundStyle(.white)
                    Text("of \(TimeText.format(take.duration))").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                } else {
                    Text(TimeText.format(take.duration)).foregroundStyle(.white)
                }
                Spacer(minLength: 4)
                Text("\(take.noteCount) notes").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            } else {
                Text("No take yet").foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .monospacedDigit()
    }
}

/// A miniature piano roll of the take, with the notes on screen drawn brighter.
struct TakeRoll: View {
    let take: Take
    let playhead: Double?
    let lowest: Int

    var body: some View {
        Canvas { ctx, size in
            let bars = take.bars
            guard !bars.isEmpty, take.duration > 0 else { return }
            let low = (bars.map(\.note).min() ?? 60) - 1, high = (bars.map(\.note).max() ?? 72) + 1
            let rowHeight = size.height / CGFloat(max(1, high - low + 1))
            let barHeight = max(2, min(5, rowHeight - 0.5))
            for bar in bars {
                let x = CGFloat(bar.start / take.duration) * size.width
                let w = max(2, CGFloat((bar.end - bar.start) / take.duration) * size.width - 1)
                let y = size.height - CGFloat(bar.note - low + 1) * rowHeight + (rowHeight - barHeight) / 2
                let rect = CGRect(x: x, y: y, width: w, height: barHeight)
                let onScreen = bar.note >= lowest && bar.note <= lowest + PianoLayout.span
                let passed = playhead.map { bar.start <= $0 } ?? true
                ctx.fill(Path(roundedRect: rect, cornerRadius: barHeight / 2),
                         with: .linearGradient(Gradient(colors: Theme.accent), startPoint: rect.origin,
                                               endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                if !onScreen || !passed {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barHeight / 2), with: .color(Theme.cabinetBottom.opacity(onScreen ? 0.45 : 0.55)))
                }
            }
            if let playhead {
                let x = CGFloat(min(1, playhead / take.duration)) * size.width
                ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white.opacity(0.9)))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black.opacity(0.28)))
    }
}

struct HintBar: View {
    var body: some View {
        HStack(spacing: 20) {
            hint(["A", "S", "D", "…", "'"], "white keys")
            hint(["W", "E", "T", "…", "]"], "black keys")
            hint(["Z", "X"], "octave")
            hint(["Space"], "sustain")
            HStack(spacing: 5) {
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 11))
                Text("click or drag to play")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity)
    }

    private func hint(_ keys: [String], _ text: String) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                if key == "…" { Text("…") } else { KeyCap(key) }
            }
            Text(text).padding(.leading, 3)
        }
    }
}

struct ExportToast: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentGradient)
            Text("Exported \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
            Button("Show in Finder") { revealInFinder([url]) }.buttonStyle(.link)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .frame(maxWidth: 520)
    }
}

// MARK: - Piano

struct PianoView: View {
    @ObservedObject var model: PianoModel

    var body: some View {
        GeometryReader { geo in
            let layout = PianoLayout(lowest: model.lowestNote, size: geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.whiteKeys) { key in
                    WhiteKey(model: model, note: key.note, offset: key.note - layout.lowest)
                        .frame(width: key.rect.width - 2, height: key.rect.height)
                        .offset(x: key.rect.minX + 1)
                }
                ForEach(layout.blackKeys) { key in
                    BlackKey(model: model, note: key.note, offset: key.note - layout.lowest)
                        .frame(width: key.rect.width, height: key.rect.height)
                        .offset(x: key.rect.minX)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if let key = layout.key(at: drag.location) {
                            model.mouseDown(note: key.note, velocity: layout.velocity(for: key, at: drag.location))
                        } else {
                            model.mouseUp()
                        }
                    }
                    .onEnded { _ in
                        model.mouseUp()
                        model.requestFocus()
                    }
            )
        }
        .animation(.snappy(duration: 0.08), value: model.pressed)
    }
}

struct WhiteKey: View {
    @ObservedObject var model: PianoModel
    let note: Int
    let offset: Int

    var body: some View {
        let down = model.isDown(note)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 7, bottomTrailingRadius: 7, style: .continuous)
        ZStack(alignment: .bottom) {
            // The front edge of the key, which shows less when it is pressed down.
            shape.fill(down ? Theme.color(0xD9A75A) : Theme.color(0xCFC6B3))
            shape
                .fill(LinearGradient(colors: down ? Theme.ivoryPressed : Theme.ivory, startPoint: .top, endPoint: .bottom))
                .padding(.bottom, down ? 3 : 8)
            VStack(spacing: 5) {
                if model.showKeyLabels, let label = KeyMap.label(forOffset: offset) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(down ? Theme.color(0x7A4A18) : Theme.ink.opacity(0.85))
                        .frame(width: 20, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(down ? Theme.color(0x7A4A18).opacity(0.35) : Theme.ink.opacity(0.28), lineWidth: 1))
                }
                if model.showNoteNames {
                    Text(note % 12 == 0 ? Note.fullName(note) : Note.name(note))
                        .font(.system(size: 11, weight: note % 12 == 0 ? .bold : .medium, design: .rounded))
                        .foregroundStyle(down ? Theme.color(0x7A4A18) : Theme.ink.opacity(note % 12 == 0 ? 1 : 0.7))
                }
            }
            .padding(.bottom, down ? 12 : 17)
        }
        .overlay(alignment: .top) {
            // Shadow cast by the felt and the cabinet lip.
            LinearGradient(colors: [.black.opacity(down ? 0.34 : 0.24), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: down ? 22 : 14)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
    }
}

struct BlackKey: View {
    @ObservedObject var model: PianoModel
    let note: Int
    let offset: Int

    var body: some View {
        let down = model.isDown(note)
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 4, bottomTrailingRadius: 4, style: .continuous)
        ZStack(alignment: .bottom) {
            shape.fill(down ? Theme.color(0x5A3410) : Theme.color(0x060608))
            // The top face, lit from above.
            UnevenRoundedRectangle(bottomLeadingRadius: 3, bottomTrailingRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: down ? Theme.ebonyPressed : Theme.ebony, startPoint: .top, endPoint: .bottom))
                .padding(.horizontal, 3)
                .padding(.bottom, down ? 5 : 11)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(down ? 0.0 : 0.14), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 5)
                        .padding(.leading, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 14)
                }
            VStack(spacing: 4) {
                if model.showKeyLabels, let label = KeyMap.label(forOffset: offset) {
                    Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(down ? 0.95 : 0.6))
                }
                if model.showNoteNames {
                    Text(Note.name(note)).font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(down ? 0.85 : 0.42))
                }
            }
            .padding(.bottom, down ? 11 : 17)
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.55), radius: 3, x: 1, y: 3)
    }
}

// MARK: - Keyboard input

/// Receives key down and key up in the window (no global monitoring), so the piano plays while the window is key.
struct KeyCatcher: NSViewRepresentable {
    let model: PianoModel

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.model = model
        return view
    }

    func updateNSView(_ view: KeyCatcherView, context: Context) {
        view.model = model
        if view.focusRequest != model.focusRequest {
            view.focusRequest = model.focusRequest
            DispatchQueue.main.async { view.claimFocus() }
        }
    }
}

final class KeyCatcherView: NSView {
    weak var model: PianoModel?
    var focusRequest = 0
    private var observers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        claimFocus()
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model?.releaseHeldKeys() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.claimFocus() }
        })
    }

    func claimFocus() {
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    private func isPlain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    override func keyDown(with event: NSEvent) {
        // Tab and Shift-Tab still move keyboard focus to the controls.
        guard isPlain(event), event.keyCode != UInt16(kVK_Tab), let model else { return super.keyDown(with: event) }
        // Unused plain keys are swallowed too, so typing a wrong letter does not beep.
        model.keyDown(event.keyCode, isRepeat: event.isARepeat)
    }

    override func keyUp(with event: NSEvent) {
        guard let model else { return super.keyUp(with: event) }
        model.keyUp(event.keyCode)
    }
}
