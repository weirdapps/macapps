import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Ivory", size: CGSize(width: 1000, height: 580)) {
    MainActor.assumeIsolated { ContentView(model: .demo) }
}
IvoryApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window instrument quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct IvoryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PianoModel.live()

    var body: some Scene {
        Window("Ivory", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1000, height: 580)
        .windowToolbarStyle(.unified)
        .commands { IvoryCommands(model: model) }
    }
}

struct IvoryCommands: Commands {
    @ObservedObject var model: PianoModel

    var body: some Commands {
        AppHelpCommands(name: "Ivory")
        CommandGroup(replacing: .newItem) {
            Button("Export MIDI File…") { model.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.take == nil || model.isRecording)
        }
        CommandGroup(before: .toolbar) {
            Button("Octave Down") { model.shiftOctave(-1) }
                .keyboardShortcut("[")
                .disabled(model.baseOctave <= PianoModel.octaves.lowerBound)
            Button("Octave Up") { model.shiftOctave(1) }
                .keyboardShortcut("]")
                .disabled(model.baseOctave >= PianoModel.octaves.upperBound)
            Divider()
            Toggle("Show Note Names", isOn: $model.showNoteNames).keyboardShortcut("n", modifiers: [.command, .option])
            Toggle("Show Key Labels", isOn: $model.showKeyLabels).keyboardShortcut("k", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Sound") {
            ForEach(Array(Sound.allCases.enumerated()), id: \.element) { index, sound in
                Toggle(sound.title, isOn: Binding(get: { model.sound == sound }, set: { if $0 { model.sound = sound } }))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Volume Up") { model.volume = min(1, model.volume + 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { model.volume = max(0, model.volume - 0.1) }
                .keyboardShortcut(.downArrow)
            Divider()
            Toggle("Latch Sustain", isOn: $model.sustainLatched).keyboardShortcut("l")
        }
        CommandMenu("Take") {
            Button(model.isRecording ? "Stop Recording" : "Record") { model.toggleRecording() }
                .keyboardShortcut("r")
            Button(model.isPlaying ? "Stop Playing" : "Play Take") { model.togglePlayback() }
                .keyboardShortcut(.return)
                .disabled(model.take == nil || model.isRecording)
            Divider()
            Button("Clear Take") { model.clearTake() }
                .keyboardShortcut(.delete)
                .disabled(model.take == nil || model.isRecording)
        }
    }
}

// MARK: - Icon

/// A fan of glossy ivory and ebony keys spreading from a pivot, on black lacquer.
func appIcon() -> NSBitmapImageRep {
    render(0x2A2A30, 0x0B0B0E) { ctx in
        let pivot = CGPoint(x: 512, y: 212)
        let inner: CGFloat = 60, outer: CGFloat = 640, blackInner: CGFloat = 372, blackOuter: CGFloat = 632
        let step: CGFloat = 10.8 * .pi / 180, gap: CGFloat = 1.1 * .pi / 180
        let whites = 7

        // A warm glow behind the fan.
        radial([rgb(0xF6CF7A, 0.2), rgb(0xF6CF7A, 0)], center: CGPoint(x: 512, y: 620), radius: 440, in: ctx)

        func wedge(from a0: CGFloat, to a1: CGFloat, r0: CGFloat, r1: CGFloat, tip: CGFloat) -> CGPath {
            // Angles measured from straight up, clockwise positive. The outer end is rounded.
            func point(_ a: CGFloat, _ r: CGFloat) -> CGPoint { CGPoint(x: pivot.x + r * sin(a), y: pivot.y + r * cos(a)) }
            let p = CGMutablePath()
            p.move(to: point(a0, r0))
            p.addLine(to: point(a0, r1 - tip))
            p.addQuadCurve(to: point(a0 + (a1 - a0) * 0.28, r1), control: point(a0, r1))
            p.addLine(to: point(a1 - (a1 - a0) * 0.28, r1))
            p.addQuadCurve(to: point(a1, r1 - tip), control: point(a1, r1))
            p.addLine(to: point(a1, r0))
            p.closeSubpath()
            return p
        }

        let start = -CGFloat(whites) * step / 2
        // Ivory keys.
        for i in 0..<whites {
            let a0 = start + CGFloat(i) * step + gap / 2, a1 = a0 + step - gap
            let path = wedge(from: a0, to: a1, r0: inner, r1: outer, tip: 26)
            ctx.saveGState()
            shadow(ctx, y: -8, blur: 18, alpha: 0.55)
            ctx.addPath(path)
            ctx.setFillColor(rgb(0xEDE5D3).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let mid = (a0 + a1) / 2
            let far = CGPoint(x: pivot.x + outer * sin(mid), y: pivot.y + outer * cos(mid))
            let near = CGPoint(x: pivot.x + inner * sin(mid), y: pivot.y + inner * cos(mid))
            gradient([rgb(0xFFFEFA), rgb(0xF4EEE1), rgb(0xC9BFA9)], from: far, to: near, in: ctx)
            // Gloss along the left edge of each key.
            let left = CGPoint(x: pivot.x + outer * sin(a0), y: pivot.y + outer * cos(a0))
            let right = CGPoint(x: pivot.x + outer * sin(a1), y: pivot.y + outer * cos(a1))
            gradient([NSColor.white.withAlphaComponent(0.75), NSColor.white.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.08)],
                     from: left, to: right, in: ctx)
            ctx.restoreGState()
        }

        // Ebony keys sit over the far ends of the joins, except between E and F.
        for join in [1, 2, 4, 5, 6] {
            let center = start + CGFloat(join) * step
            let half = step * 0.31
            let path = wedge(from: center - half, to: center + half, r0: blackInner, r1: blackOuter, tip: 14)
            ctx.saveGState()
            shadow(ctx, y: -12, blur: 16, alpha: 0.7)
            ctx.addPath(path)
            ctx.setFillColor(rgb(0x0A0A0D).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let far = CGPoint(x: pivot.x + blackOuter * sin(center), y: pivot.y + blackOuter * cos(center))
            let near = CGPoint(x: pivot.x + blackInner * sin(center), y: pivot.y + blackInner * cos(center))
            gradient([rgb(0x2C2C33), rgb(0x101013), rgb(0x1E1E24)], from: far, to: near, in: ctx)
            let l = CGPoint(x: pivot.x + blackOuter * sin(center - half), y: pivot.y + blackOuter * cos(center - half))
            let r = CGPoint(x: pivot.x + blackOuter * sin(center + half), y: pivot.y + blackOuter * cos(center + half))
            gradient([NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.06)],
                     from: l, to: r, in: ctx)
            ctx.restoreGState()
        }

        // The brass hub that holds the fan together.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 14, alpha: 0.6)
        let hub = CGRect(x: pivot.x - 70, y: pivot.y - 70, width: 140, height: 140)
        ctx.addEllipse(in: hub)
        ctx.setFillColor(rgb(0xD5873A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: hub)
        ctx.clip()
        gradient([rgb(0xFFE2A0), rgb(0xE9A54E), rgb(0x9A5A1E)], from: CGPoint(x: hub.minX, y: hub.maxY),
                 to: CGPoint(x: hub.maxX, y: hub.minY), in: ctx)
        ctx.restoreGState()
        ctx.addEllipse(in: hub.insetBy(dx: 27, dy: 27))
        ctx.setFillColor(rgb(0x2A1A0C, 0.55).cgColor)
        ctx.fillPath()
        ctx.addEllipse(in: hub.insetBy(dx: 36, dy: 36))
        ctx.setFillColor(rgb(0xF6CF7A).cgColor)
        ctx.fillPath()
    }
}
