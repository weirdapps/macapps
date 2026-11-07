import AppKit
import SwiftUI

enum Theme {
    static let top = Color(red: 0x6A / 255, green: 0x7B / 255, blue: 0xD9 / 255)
    static let bottom = Color(red: 0x2C / 255, green: 0x34 / 255, blue: 0x70 / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let tileGradient = LinearGradient(colors: [top, Color(red: 0x45 / 255, green: 0x52 / 255, blue: 0xA8 / 255)],
                                             startPoint: .top, endPoint: .bottom)
}

struct ContentView: View {
    @ObservedObject var model: HumModel
    @Environment(\.undoManager) private var undoManager
    @State private var draftName = ""
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
        } detail: {
            VStack(spacing: 16) {
                HeroCard(model: model, meter: model.meter)
                SoundGrid(model: model)
                MasterBar(model: model)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                SleepMenu(model: model, compact: true)
                Button { model.showingSave = true } label: { Label("Save Mix", systemImage: "square.and.arrow.down") }
                    .help("Save the current sounds as a mix (⌘S)")
                    .disabled(model.activeCount == 0)
                Button { model.togglePlay() } label: {
                    Label(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                }
                .help(model.isPlaying ? "Fade out and pause (Space)" : "Fade in and play (Space)")
            }
        }
        .navigationTitle("Hum")
        .alert("Save Mix", isPresented: $model.showingSave) {
            TextField("Name", text: $draftName)
            Button("Save") { model.saveCurrent(as: draftName, undo: undoManager) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps these volumes in the sidebar so you can come back to them.")
        }
        .onChange(of: model.showingSave) { _, showing in if showing { draftName = model.nextMixName() } }
        .alert("Rename Mix", isPresented: Binding(get: { model.renaming != nil }, set: { if !$0 { model.renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let mix = model.renaming { model.rename(mix, to: renameText, undo: undoManager) } }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: model.renaming) { _, mix in if let mix { renameText = mix.name } }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: HumModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: $model.selection) {
            Section("Presets") {
                ForEach(Mix.presets) { mix in
                    MixRow(mix: mix).tag(mix.id)
                }
            }
            Section("My Mixes") {
                if model.mixes.isEmpty {
                    Text("Set the sliders you like, then choose Save Mix (⌘S).")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .selectionDisabled()
                }
                ForEach(model.mixes) { mix in
                    MixRow(mix: mix).tag(mix.id)
                        .contextMenu {
                            Button("Rename…") { model.renaming = mix }
                            Button("Update with Current Sounds") { model.update(mix) }
                                .disabled(model.activeCount == 0)
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(mix, undo: undoManager) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.selection) { _, id in
            guard let id, let mix = model.allSounds.first(where: { $0.id == id }), !mix.matches(model.volumes) else { return }
            withAnimation(.snappy) { model.apply(mix) }
        }
        .onDeleteCommand {
            if let id = model.selection, let mix = model.mixes.first(where: { $0.id == id }) { model.delete(mix, undo: undoManager) }
        }
    }
}

struct MixRow: View {
    let mix: Mix

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: mix.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.tileGradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(mix.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(mix.summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Hero

struct HeroCard: View {
    @ObservedObject var model: HumModel
    @ObservedObject var meter: Meter
    @State private var hoveringPlay = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.gradient)
            Moon().frame(width: 34, height: 34).padding(.top, 26).padding(.trailing, 150)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Dunes(level: meter.level, playing: model.isPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            HStack(alignment: .top, spacing: 18) {
                Button { withAnimation(.snappy) { model.togglePlay() } } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Theme.bottom)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 62, height: 62)
                        .background(Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: hoveringPlay ? 10 : 6, y: 3))
                        .scaleEffect(hoveringPlay ? 1.05 : 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoveringPlay = $0 }
                .animation(.snappy(duration: 0.18), value: hoveringPlay)
                .help(model.isPlaying ? "Fade out and pause" : "Fade in and play")

                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.opacity)
                    Text(model.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    if let remaining = model.sleepRemaining {
                        Label("Sleeps in \(Sleep.format(remaining))", systemImage: "moon.zzz.fill")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .padding(.top, 4)
                            .contentTransition(.numericText())
                    }
                }
                .padding(.top, 2)
                Spacer(minLength: 12)
                LevelReadout(meter: meter, playing: model.isPlaying)
            }
            .padding(24)
        }
        .frame(height: 206)
        .animation(.snappy, value: model.sleepEnd)
    }
}

struct LevelReadout: View {
    @ObservedObject var meter: Meter
    let playing: Bool
    static let segments = 14

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(playing && meter.decibels > -60 ? String(format: "%.0f", meter.decibels) : "Off")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                if playing && meter.decibels > -60 {
                    Text("dB").font(.system(size: 12, weight: .semibold, design: .rounded)).opacity(0.75)
                }
            }
            .foregroundStyle(.white)
            HStack(spacing: 3) {
                ForEach(0..<Self.segments, id: \.self) { i in
                    let lit = Double(i) < meter.level * Double(Self.segments)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(lit ? (i >= Self.segments - 2 ? 1 : 0.85) : 0.2))
                        .frame(width: 5, height: 14)
                }
            }
            Text("Output level").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// Layered dunes of sound that rise with the output level and drift slowly while playing.
struct Dunes: View {
    let level: Double
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
            Canvas { ctx, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let energy = playing ? 0.25 + level * 0.75 : 0.12
                let layers: [(base: Double, amp: Double, freq: Double, speed: Double, alpha: Double)] = [
                    (0.56, 30, 1.3, 0.22, 0.10),
                    (0.68, 24, 1.9, -0.31, 0.13),
                    (0.80, 18, 2.6, 0.43, 0.18),
                ]
                for layer in layers {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: size.height))
                    let steps = 80
                    for s in 0...steps {
                        let x = Double(s) / Double(steps)
                        let a = x * .pi * 2 * layer.freq + t * layer.speed
                        let wave = 0.6 * sin(a) + 0.4 * sin(a * 2.3 + 1.1 + t * layer.speed * 0.7)
                        let y = size.height * layer.base - layer.amp * energy * (0.5 + 0.5 * wave)
                        path.addLine(to: CGPoint(x: x * size.width, y: y))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.white.opacity(layer.alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct Moon: View {
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.drawLayer { layer in
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white.opacity(0.9)))
                layer.blendMode = .destinationOut
                layer.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.45, y: c.y - r * 1.25, width: 2 * r, height: 2 * r)), with: .color(.black))
            }
        }
        .shadow(color: .white.opacity(0.45), radius: 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Sounds

struct SoundGrid: View {
    @ObservedObject var model: HumModel

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                ForEach(Sound.allCases.prefix(3)) { SoundTile(sound: $0, model: model) }
            }
            GridRow {
                ForEach(Sound.allCases.suffix(3)) { SoundTile(sound: $0, model: model) }
            }
        }
    }
}

struct SoundTile: View {
    let sound: Sound
    @ObservedObject var model: HumModel
    @State private var hovering = false

    private var volume: Double { model.volume(sound) }
    private var on: Bool { volume > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Button { withAnimation(.snappy) { model.toggle(sound) } } label: {
                    Image(systemName: sound.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(on ? AnyShapeStyle(Theme.tileGradient) : AnyShapeStyle(.quaternary.opacity(0.7))))
                        .shadow(color: on ? Theme.bottom.opacity(0.3) : .clear, radius: 4, y: 2)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(on ? "Turn off \(sound.name)" : "Turn on \(sound.name)")

                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.name).font(.system(size: 14, weight: .semibold))
                    Text(sound.blurb).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Slider(value: model.binding(sound), in: 0...1)
                    .tint(Theme.top)
                    .controlSize(.small)
                    .accessibilityLabel("\(sound.name) volume")
                Text(on ? "\(Int((volume * 100).rounded()))%" : "Off")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(on ? AnyShapeStyle(Theme.top) : AnyShapeStyle(.tertiary))
                    .frame(width: 34, alignment: .trailing)
                    .contentTransition(.numericText())
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.05), radius: hovering ? 8 : 4, y: 2)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(on ? AnyShapeStyle(Theme.top.opacity(0.55)) : AnyShapeStyle(.quaternary.opacity(0.8)), lineWidth: on ? 1.5 : 1)
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: on)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Master and sleep

struct MasterBar: View {
    @ObservedObject var model: HumModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary).frame(width: 16)
            Slider(value: $model.master, in: 0...1)
                .tint(Theme.top)
                .accessibilityLabel("Master volume")
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            Text("\(Int((model.master * 100).rounded()))%")
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .contentTransition(.numericText())
            Divider().frame(height: 22).padding(.horizontal, 4)
            SleepMenu(model: model, compact: false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 4, y: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary.opacity(0.8)))
    }
}

struct SleepMenu: View {
    @ObservedObject var model: HumModel
    let compact: Bool

    var body: some View {
        Menu {
            SleepItems(model: model)
        } label: {
            if compact {
                Label("Sleep Timer", systemImage: model.sleepMinutes == nil ? "moon" : "moon.zzz.fill")
            } else {
                Label(model.sleepMinutes.map { "Sleep in \(Sleep.label(minutes: $0))" } ?? "Sleep timer off",
                      systemImage: model.sleepMinutes == nil ? "moon" : "moon.zzz.fill")
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Fade out and stop after a while; the last minutes fade gently")
    }
}

struct SleepItems: View {
    @ObservedObject var model: HumModel

    var body: some View {
        Toggle("Off", isOn: Binding(get: { model.sleepMinutes == nil }, set: { _ in model.setSleep(minutes: nil) }))
        Divider()
        ForEach(Sleep.choices, id: \.self) { m in
            Toggle(Sleep.label(minutes: m), isOn: Binding(get: { model.sleepMinutes == m }, set: { _ in model.setSleep(minutes: m) }))
        }
    }
}
