import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Beat", size: CGSize(width: 1000, height: 670)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
BeatApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single window utility: closing it quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BeatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BeatModel()

    var body: some Scene {
        Window("Beat", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1000, height: 670)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Beat")
            PresetCommands(model: model)
            MetronomeCommands(model: model)
        }
    }
}

/// The window's undo manager, for menu commands that live outside the view tree.
@MainActor private func windowUndo() -> UndoManager? { NSApp.keyWindow?.undoManager ?? NSApp.mainWindow?.undoManager }

struct PresetCommands: Commands {
    @ObservedObject var model: BeatModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Preset…") { model.requestNewPreset() }
                .keyboardShortcut("n")
                .disabled(model.naming != nil)
            Button("Update Preset") { if let id = model.selection { model.updatePreset(id, undo: windowUndo()) } }
                .keyboardShortcut("s")
                .disabled(model.selection == nil || model.naming != nil)
            Button("Revert to Preset") { model.revertToPreset() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(!model.isEdited || model.naming != nil)
            Button("Rename Preset…") { if let id = model.selection { model.requestRename(id) } }
                .keyboardShortcut("r")
                .disabled(model.selection == nil || model.naming != nil)
            Divider()
            Button("Delete Preset") { if let id = model.selection { model.deletePreset(id, undo: windowUndo()) } }
                .keyboardShortcut(.delete)
                .disabled(model.selection == nil || model.naming != nil)
        }
    }
}

struct MetronomeCommands: Commands {
    @ObservedObject var model: BeatModel

    var body: some Commands {
        CommandMenu("Metronome") {
            // Single keys, so they step aside while the naming sheet has a text field.
            // A held key repeats; acting on every repeat would flicker start and stop.
            Button(model.isPlaying ? "Stop" : "Start") { if !BeatModel.isKeyRepeat { model.toggle() } }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.naming != nil)
            Button("Tap Tempo") { if !BeatModel.isKeyRepeat { model.tap() } }
                .keyboardShortcut("t", modifiers: [])
                .disabled(model.naming != nil)
            Divider()
            Button("Faster") { model.nudge(1) }.keyboardShortcut(.upArrow)
            Button("Slower") { model.nudge(-1) }.keyboardShortcut(.downArrow)
            Button("Much Faster") { model.nudge(10) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Much Slower") { model.nudge(-10) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Divider()
            Menu("Time Signature") {
                ForEach(Array(TimeSignature.allCases.enumerated()), id: \.element) { i, sig in
                    Toggle(sig.rawValue, isOn: binding(\.signature, sig))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
            Menu("Subdivision") {
                ForEach(Array(Subdivision.allCases.enumerated()), id: \.element) { i, sub in
                    Toggle(sub.label, isOn: binding(\.subdivision, sub))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
            Menu("Sound") {
                ForEach(Sound.allCases) { sound in
                    Toggle(sound.label, isOn: binding(\.sound, sound))
                }
            }
            Toggle("Accent Beat One", isOn: $model.config.accent)
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }

    private func binding<T: Equatable>(_ key: WritableKeyPath<MeterConfig, T>, _ value: T) -> Binding<Bool> {
        Binding(get: { model.config[keyPath: key] == value }, set: { if $0 { model.config[keyPath: key] = value } })
    }
}

// MARK: - Icon

//: a pyramid metronome in warm wood, its pendulum caught mid swing

func appIcon() -> NSBitmapImageRep {
    render(0xC0392B, 0x6E1423) { ctx in
        let cx: CGFloat = 512
        let baseY: CGFloat = 214, topY: CGFloat = 800
        let halfBase: CGFloat = 238, halfTop: CGFloat = 62

        // Soft floor glow so the case lifts off the tile.
        radial([rgb(0xFF8A6A, 0.32), rgb(0xFF8A6A, 0)], center: CGPoint(x: cx, y: 230), radius: 360, in: ctx)

        // Plinth.
        let plinth = CGRect(x: cx - halfBase - 34, y: baseY - 58, width: (halfBase + 34) * 2, height: 72)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.45)
        ctx.addPath(roundedRect(plinth, 22))
        ctx.setFillColor(rgb(0x5A3216).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(plinth, 22))
        ctx.clip()
        gradient([rgb(0xC98A4E), rgb(0x7A4520)], from: CGPoint(x: 0, y: plinth.maxY), to: CGPoint(x: 0, y: plinth.minY), in: ctx)
        ctx.restoreGState()

        // Case: a tapered pyramid with a lit left face and a shaded right face.
        let caseShape = CGMutablePath()
        caseShape.move(to: CGPoint(x: cx - halfBase, y: baseY))
        caseShape.addLine(to: CGPoint(x: cx + halfBase, y: baseY))
        caseShape.addLine(to: CGPoint(x: cx + halfTop, y: topY))
        caseShape.addQuadCurve(to: CGPoint(x: cx - halfTop, y: topY), control: CGPoint(x: cx, y: topY + 34))
        caseShape.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.5)
        ctx.addPath(caseShape)
        ctx.setFillColor(rgb(0x8A5126).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(caseShape)
        ctx.clip()
        gradient([rgb(0xF0B878), rgb(0xC07A3C), rgb(0x7E4520)], from: CGPoint(x: cx - halfBase, y: 0),
                 to: CGPoint(x: cx + halfBase, y: 0), in: ctx)
        // Wood grain.
        ctx.setStrokeColor(rgb(0x6B3A18, 0.16).cgColor)
        ctx.setLineWidth(5)
        for i in 0..<9 {
            let x = cx - 200 + CGFloat(i) * 50
            ctx.move(to: CGPoint(x: x, y: baseY))
            ctx.addCurve(to: CGPoint(x: cx + (x - cx) * 0.28, y: topY), control1: CGPoint(x: x + 22, y: 420),
                         control2: CGPoint(x: x - 18, y: 620))
        }
        ctx.strokePath()
        // Top sheen.
        gradient([NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)],
                 from: CGPoint(x: 0, y: topY), to: CGPoint(x: 0, y: 560), in: ctx)
        ctx.restoreGState()

        // Recessed face behind the pendulum.
        let face = CGMutablePath()
        let faceBottom: CGFloat = 300, faceTop: CGFloat = 742
        face.move(to: CGPoint(x: cx - 112, y: faceBottom))
        face.addLine(to: CGPoint(x: cx + 112, y: faceBottom))
        face.addLine(to: CGPoint(x: cx + 34, y: faceTop))
        face.addLine(to: CGPoint(x: cx - 34, y: faceTop))
        face.closeSubpath()
        ctx.saveGState()
        ctx.addPath(face)
        ctx.clip()
        gradient([rgb(0x4A2410), rgb(0x2E140A)], from: CGPoint(x: 0, y: faceTop), to: CGPoint(x: 0, y: faceBottom), in: ctx)
        // Scale ticks.
        ctx.setFillColor(rgb(0xF6D9A8, 0.75).cgColor)
        for i in 0..<9 {
            let y = faceBottom + 70 + CGFloat(i) * 42
            let w: CGFloat = i % 2 == 0 ? 34 : 18
            ctx.fill(CGRect(x: cx - w / 2, y: y, width: w, height: 7))
        }
        ctx.restoreGState()

        // Pendulum, mid swing to the right.
        let pivot = CGPoint(x: cx, y: 300)
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: -0.27)
        shadow(ctx, y: -8, blur: 18, alpha: 0.45)
        let rod = CGRect(x: -13, y: -10, width: 26, height: 540)
        ctx.addPath(roundedRect(rod, 13))
        ctx.setFillColor(rgb(0xEDEDED).cgColor)
        ctx.fillPath()
        // Weight.
        let weight = CGMutablePath()
        weight.move(to: CGPoint(x: -62, y: 330))
        weight.addLine(to: CGPoint(x: 62, y: 330))
        weight.addLine(to: CGPoint(x: 46, y: 416))
        weight.addLine(to: CGPoint(x: -46, y: 416))
        weight.closeSubpath()
        ctx.addPath(weight)
        ctx.setFillColor(rgb(0xD9A23A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Metal shading on rod and weight, drawn again without the shadow.
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y)
        ctx.rotate(by: -0.27)
        ctx.saveGState()
        ctx.addPath(roundedRect(rod, 13))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xB9B9B9)], from: CGPoint(x: -13, y: 0), to: CGPoint(x: 13, y: 0), in: ctx)
        ctx.restoreGState()
        ctx.addPath(weight)
        ctx.clip()
        gradient([rgb(0xFFE29A), rgb(0xE0A93E), rgb(0x9C6A1C)], from: CGPoint(x: -62, y: 0), to: CGPoint(x: 62, y: 0), in: ctx)
        ctx.restoreGState()

        // Pivot cap.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 10, alpha: 0.4)
        ctx.setFillColor(rgb(0xF2F2F2).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 30, y: pivot.y - 30, width: 60, height: 60))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x8E1C26).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 13, y: pivot.y - 13, width: 26, height: 26))

        // Motion arcs beside the swing.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(14)
        ctx.addArc(center: pivot, radius: 545, startAngle: 0.9, endAngle: 1.08, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.addArc(center: pivot, radius: 470, startAngle: 0.86, endAngle: 1.0, clockwise: false)
        ctx.strokePath()
    }
}
