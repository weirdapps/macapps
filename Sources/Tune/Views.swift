import AppKit
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0x7B / 255, green: 0xE4 / 255, blue: 0x95 / 255)
    static let deep = Color(red: 0x2B / 255, green: 0x9C / 255, blue: 0x6B / 255)
    static let accent = LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let off = Color.orange
    static let span = 50.0 // Cents from the centre to either end of the dial.
    static let sweep = 72.0 // Degrees from the centre to either end of the dial.

    static func tint(_ cents: Double) -> Color { abs(cents) <= 5 ? deep : off }
}

struct ContentView: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        Group {
            switch model.access {
            case .denied:
                Unavailable(symbol: "mic.slash", title: "Tune can't hear you",
                            message: "Tune listens to your instrument through the microphone. Turn on Tune in Privacy & Security, then open it again.",
                            button: "Open Privacy Settings", action: model.openPrivacySettings)
            case .noDevice:
                Unavailable(symbol: "mic.badge.xmark", title: "No microphone",
                            message: "Connect a microphone or an audio interface, then try again.",
                            button: "Try Again", action: model.retry)
            case .unknown, .granted:
                TunerView(model: model)
            }
        }
        .frame(minWidth: 680, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Instrument", selection: $model.instrument) {
                    ForEach(Instrument.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Choose the instrument whose strings to show")
            }
            ToolbarItem(placement: .primaryAction) {
                ReferenceControl(reference: $model.reference)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: model.toggleListening) {
                    Label(model.isListening ? "Pause" : "Listen", systemImage: model.isListening ? "pause.fill" : "mic.fill")
                }
                .help(model.isListening ? "Stop listening (⌘L)" : "Listen through the microphone (⌘L)")
                .disabled(model.access == .denied || model.access == .noDevice)
            }
        }
        .onAppear { model.start() }
    }
}

struct Unavailable: View {
    let symbol: String
    let title: String
    let message: String
    let button: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(button, action: action).controlSize(.large).buttonStyle(.borderedProminent).tint(Theme.deep)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReferenceControl: View {
    @Binding var reference: Double

    var body: some View {
        HStack(spacing: 6) {
            Text("A4").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text("\(Int(reference)) Hz")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .contentTransition(.numericText(value: reference))
                .frame(width: 48, alignment: .leading)
            Stepper("Reference pitch", value: $reference, in: Music.referenceRange, step: 1)
                .labelsHidden()
        }
        .padding(.leading, 8)
        .help("Reference pitch for A4, from 430 to 450 Hz (⌘[ and ⌘])")
        .animation(.snappy(duration: 0.2), value: reference)
    }
}

// MARK: - Tuner

struct TunerView: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        VStack(spacing: 0) {
            Dial(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 14)
            Readouts(model: model)
                .padding(.horizontal, 32)
                .padding(.top, 10)
            StringsStrip(model: model)
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 16)
            Divider()
            StatusBar(model: model)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Dial: View {
    @ObservedObject var model: TuneModel

    private var cents: Double { model.display?.cents ?? 0 }
    private var live: Bool { model.display != nil && !model.isHolding && model.isListening }

    var body: some View {
        GeometryReader { geo in
            // The dial and the note under it, centred vertically: about 0.72 r of arc plus 120 pt of note and status.
            let radius = max(120, min(geo.size.width * 0.43, (geo.size.height - 130) / 0.72))
            let used = radius * 0.72 + 130
            let center = CGPoint(x: geo.size.width / 2, y: max(0, (geo.size.height - used) / 2) + 10 + radius)
            ZStack {
                DialFace(center: center, radius: radius)
                if model.display != nil {
                    Pointer(angle: Self.angle(cents), center: center, radius: radius)
                        .fill(Theme.tint(cents).gradient)
                        .shadow(color: Theme.tint(cents).opacity(live ? 0.45 : 0), radius: 8)
                        .opacity(live ? 1 : 0.35)
                        .animation(.interpolatingSpring(stiffness: 170, damping: 22), value: cents)
                }
                NoteLabel(model: model)
                    .position(x: center.x, y: center.y - radius * 0.26)
            }
        }
    }

    static func angle(_ cents: Double) -> Double {
        max(-1.08, min(1.08, cents / Theme.span)) * Theme.sweep
    }
}

/// The scale: a track, the in-tune zone and tick marks every 5 cents, labelled every 10.
struct DialFace: View {
    let center: CGPoint
    let radius: CGFloat

    var body: some View {
        Canvas { context, _ in
            func point(_ degrees: Double, _ r: CGFloat) -> CGPoint {
                let a = (degrees - 90) * .pi / 180
                return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
            }
            func arc(_ from: Double, _ to: Double, _ r: CGFloat) -> Path {
                Path { p in
                    p.addArc(center: center, radius: r, startAngle: .degrees(from - 90), endAngle: .degrees(to - 90), clockwise: false)
                }
            }
            let track = arc(-Theme.sweep, Theme.sweep, radius - 6)
            context.stroke(track, with: .color(.primary.opacity(0.07)), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            let zone = Dial.angle(5)
            context.stroke(arc(-zone, zone, radius - 6), with: .linearGradient(
                Gradient(colors: [Theme.light, Theme.deep]), startPoint: point(-zone, radius), endPoint: point(zone, radius)),
                style: StrokeStyle(lineWidth: 12, lineCap: .round))

            for step in stride(from: -50, through: 50, by: 5) {
                let a = Dial.angle(Double(step))
                let major = step % 10 == 0
                let length: CGFloat = step == 0 ? 30 : major ? 22 : 13
                var tick = Path()
                tick.move(to: point(a, radius - 20))
                tick.addLine(to: point(a, radius - 20 - length))
                let shade: Color = step == 0 ? Theme.deep : .primary.opacity(major ? 0.45 : 0.22)
                context.stroke(tick, with: .color(shade), style: StrokeStyle(lineWidth: step == 0 ? 3.5 : major ? 2.2 : 1.4, lineCap: .round))
                if major {
                    let text = step == 0 ? "0" : (step > 0 ? "+\(step)" : "\u{2212}\(-step)")
                    context.draw(Text(text).font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(step == 0 ? AnyShapeStyle(Theme.deep) : AnyShapeStyle(.secondary)),
                                 at: point(a, radius - 20 - length - 14))
                }
            }
            // Flat and sharp signs at the ends of the scale.
            context.draw(Text("♭").font(.system(size: 22, weight: .semibold)).foregroundStyle(.tertiary),
                         at: point(-Theme.sweep - 9, radius - 6))
            context.draw(Text("♯").font(.system(size: 20, weight: .semibold)).foregroundStyle(.tertiary),
                         at: point(Theme.sweep + 9, radius - 6))
        }
    }
}

/// A tapered pointer riding on the outer edge of the dial; animatable by angle.
struct Pointer: Shape {
    var angle: Double
    let center: CGPoint
    let radius: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let a = (angle - 90) * .pi / 180
        let dir = CGPoint(x: cos(a), y: sin(a)), side = CGPoint(x: -sin(a), y: cos(a))
        func at(_ r: CGFloat, _ s: CGFloat) -> CGPoint {
            CGPoint(x: center.x + dir.x * r + side.x * s, y: center.y + dir.y * r + side.y * s)
        }
        let inner = radius * 0.62, outer = radius - 16
        var p = Path()
        p.move(to: at(outer, -2.5))
        p.addLine(to: at(outer, 2.5))
        p.addLine(to: at(inner + 7, 5))
        p.addLine(to: at(inner + 7, -5))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: at(inner, 0).x - 8, y: at(inner, 0).y - 8, width: 16, height: 16))
        return p
    }
}

struct NoteLabel: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        VStack(spacing: 6) {
            if let display = model.display {
                let name = Music.name(display.target.midi)
                HStack(alignment: .top, spacing: 2) {
                    Text(String(name.prefix(1)))
                        .font(.system(size: 112, weight: .bold, design: .rounded))
                        .foregroundStyle(display.inTune && !model.isHolding ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name.count > 1 ? "♯" : " ")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .padding(.top, 14)
                        Spacer(minLength: 0)
                        Text("\(Music.octave(display.target.midi))")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 16)
                    }
                    .frame(width: 30, height: 118)
                }
                .frame(height: 118)
                .opacity(model.isHolding ? 0.4 : 1)
                .contentTransition(.opacity)
                StatusLine(display: display, holding: model.isHolding, listening: model.isListening)
            } else {
                Image(systemName: model.isListening ? "waveform" : "pause.circle")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolEffect(.variableColor.iterative, isActive: model.isListening)
                    .frame(height: 118)
                Text(model.isListening ? "Play a note" : (model.access == .unknown ? "Waiting for the microphone" : "Paused"))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(height: 26)
            }
        }
        .animation(.snappy(duration: 0.2), value: model.display?.target)
        .animation(.snappy(duration: 0.25), value: model.isHolding)
    }
}

struct StatusLine: View {
    let display: TuneModel.Display
    let holding: Bool
    let listening: Bool

    var body: some View {
        let (text, symbol, color): (String, String, Color) = {
            if !listening { return ("Paused", "pause.fill", .secondary) }
            if holding { return ("Play a note", "waveform", .secondary) }
            if display.inTune { return ("In tune", "checkmark.circle.fill", Theme.deep) }
            return display.cents < 0 ? ("Tune up", "arrow.up.circle.fill", Theme.off) : ("Tune down", "arrow.down.circle.fill", Theme.off)
        }()
        Label(text, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(color.opacity(0.12)))
            .contentTransition(.opacity)
            .animation(.snappy(duration: 0.2), value: text)
    }
}

struct Readouts: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        let d = model.display
        HStack(spacing: 0) {
            Readout(title: "Frequency", value: d.map { String(format: "%.2f", $0.frequency) } ?? "0.00", unit: "Hz",
                    number: d?.frequency ?? 0)
            Divider().frame(height: 34)
            Readout(title: "Deviation", value: d.map { Music.centsText($0.cents) } ?? "0.0", unit: "cents",
                    number: d?.cents ?? 0, tint: d.map { Theme.tint($0.cents) })
            Divider().frame(height: 34)
            Readout(title: "Target", value: d.map { String(format: "%.2f", $0.targetFrequency) } ?? "0.00",
                    unit: d.map { "Hz  \(Music.label($0.target.midi))" } ?? "Hz", number: d?.targetFrequency ?? 0)
        }
        .opacity(d == nil || model.isHolding ? 0.45 : 1)
        .frame(maxWidth: 640)
    }
}

struct Readout: View {
    let title: String
    let value: String
    let unit: String
    let number: Double
    var tint: Color?

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint ?? .primary)
                    .contentTransition(.numericText(value: number))
                Text(unit).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Strings

struct StringsStrip: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        VStack(spacing: 9) {
            if model.instrument == .chromatic {
                HStack(spacing: 6) {
                    ForEach(0..<12, id: \.self) { pitch in
                        let current = model.display.map { (($0.target.midi % 12) + 12) % 12 == pitch } ?? false
                        StringChip(name: Music.names[pitch], detail: nil, active: current && !model.isHolding,
                                   inTune: model.display?.inTune ?? false, locked: false, action: nil)
                    }
                }
                .frame(maxWidth: 660)
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(model.instrument.strings.enumerated()), id: \.offset) { index, midi in
                        let current = model.display?.target.string == index
                        StringChip(name: Music.label(midi),
                                   detail: String(format: "%.1f Hz", Music.frequency(midi: midi, a4: model.reference)),
                                   active: current && !model.isHolding, inTune: model.display?.inTune ?? false,
                                   locked: model.lockedString == index) { model.toggleLock(index) }
                    }
                }
                .frame(maxWidth: CGFloat(model.instrument.strings.count) * 118)
            }
            Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .animation(.snappy(duration: 0.2), value: model.instrument)
        .animation(.snappy(duration: 0.2), value: model.display?.target)
        .animation(.snappy(duration: 0.2), value: model.lockedString)
    }

    private var hint: String {
        if model.instrument == .chromatic { return "Tune shows the nearest note of the twelve, in any octave." }
        if let locked = model.lockedString {
            return "Locked to \(Music.label(model.instrument.strings[locked])). Click it again to pick strings automatically."
        }
        return "\(model.instrument.tuningName). Tune picks the nearest string; click one to lock it."
    }
}

struct StringChip: View {
    let name: String
    let detail: String?
    let active: Bool
    let inTune: Bool
    let locked: Bool
    let action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let fill: AnyShapeStyle = active
            ? (inTune ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.off.gradient))
            : AnyShapeStyle(.quaternary.opacity(hovering && action != nil ? 0.8 : 0.45))
        Button { action?() } label: {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(name).font(.system(size: detail == nil ? 14 : 17, weight: .bold, design: .rounded))
                    if locked { Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)) }
                }
                if let detail {
                    Text(detail).font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(active ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .frame(height: detail == nil ? 36 : 50)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
            .overlay {
                if locked {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.deep, lineWidth: 2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .allowsHitTesting(action != nil)
        .onHover { hovering = $0 }
        .help(action == nil ? "" : (locked ? "Unlock this string" : "Lock to this string"))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.isListening ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.isListening ? AnyShapeStyle(Theme.deep) : AnyShapeStyle(.secondary))
            Text(model.isListening ? model.deviceName : "Not listening")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            LevelMeter(level: model.isListening ? model.level : 0)
                .help("Input level")
            Spacer()
            Text("A4 = \(Int(model.reference)) Hz")
            Text("·")
            Text(String(format: "%g kHz", (model.sampleRate / 100).rounded() / 10))
        }
        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.quaternary.opacity(0.3))
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<14, id: \.self) { i in
                let on = Double(i) / 14 < level
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(on ? AnyShapeStyle(i < 11 ? Theme.deep : Theme.off) : AnyShapeStyle(.quaternary))
                    .frame(width: 4, height: 10)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: TuneModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Reference pitch") {
                    ReferenceControl(reference: $model.reference)
                }
                Button("Reset to 440 Hz") { model.reference = 440 }
                    .disabled(model.reference == 440)
            } footer: {
                Text("Most music tunes A4 to 440 Hz. Some orchestras use 442 or 443 Hz.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Noise gate") {
                    HStack {
                        Slider(value: $model.gate, in: -75 ... -30, step: 1) {
                            Text("Noise gate")
                        } minimumValueLabel: {
                            Text("Quiet").font(.system(size: 11))
                        } maximumValueLabel: {
                            Text("Loud").font(.system(size: 11))
                        }
                        .labelsHidden()
                        Text("\(Int(model.gate)) dB").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Sounds quieter than the gate are ignored. Raise it in a noisy room.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
