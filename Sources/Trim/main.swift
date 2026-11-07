import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Trim", size: CGSize(width: 980, height: 660)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
TrimApp.main()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = TrimModel()

    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened with Open With.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.open(url) }
    }
}

struct TrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Trim", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 980, height: 660)
        .windowToolbarStyle(.unified)
        .commands { TrimCommands(model: delegate.model) }
    }
}

struct TrimCommands: Commands {
    @ObservedObject var model: TrimModel

    var body: some Commands {
        AppHelpCommands(name: "Trim")
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }.keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(model.exportsAudioOnly ? "Export Audio" : "Export Selection") { model.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.canExport)
            Toggle("Audio Only", isOn: $model.audioOnly)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.hasClip || model.info?.hasAudio != true || model.info?.hasVideo != true || model.isExporting)
            Button("Cancel Export") { model.cancelExport() }
                .keyboardShortcut(".")
                .disabled(!model.isExporting)
            Divider()
            Button("Reveal in Finder") { model.revealExport() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.lastExport == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.undoManager.canUndo ? "Undo \(model.undoManager.undoActionName)" : "Undo") { model.undoManager.undo() }
                .keyboardShortcut("z")
                .disabled(!model.undoManager.canUndo)
            Button(model.undoManager.canRedo ? "Redo \(model.undoManager.redoActionName)" : "Redo") { model.undoManager.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.undoManager.canRedo)
        }
        CommandMenu("Playback") {
            Group {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Play Selection") { model.playSelection() }.keyboardShortcut("/", modifiers: [])
                Divider()
                Button("Play Backward") { model.playBackward() }.keyboardShortcut("j", modifiers: [])
                Button("Stop") { model.pause() }.keyboardShortcut("k", modifiers: [])
                Button("Play Forward") { model.playForward() }.keyboardShortcut("l", modifiers: [])
                Divider()
                Button("Previous Frame") { model.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("Next Frame") { model.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("Back One Second") { model.jump(-1) }.keyboardShortcut(.leftArrow, modifiers: [.shift])
                Button("Forward One Second") { model.jump(1) }.keyboardShortcut(.rightArrow, modifiers: [.shift])
            }
            .disabled(!model.hasClip)
            Divider()
            Group {
                Button("Set In Point") { model.setIn() }.keyboardShortcut("i", modifiers: [])
                Button("Set Out Point") { model.setOut() }.keyboardShortcut("o", modifiers: [])
                Button("Go to In Point") { model.goToIn() }.keyboardShortcut("i", modifiers: [.shift])
                Button("Go to Out Point") { model.goToOut() }.keyboardShortcut("o", modifiers: [.shift])
                Button("Clear In and Out") { model.clearRange() }.keyboardShortcut("x", modifiers: [.option])
            }
            .disabled(!model.hasClip)
        }
    }
}

// MARK: - Icon

//: a film strip cut clean in two, a pair of sleek open scissors in the gap, on tangerine

func appIcon() -> NSBitmapImageRep {
    render(0xFF9A3C, 0xE0442B) { ctx in
        let center = CGPoint(x: 512, y: 560)
        let angle: CGFloat = 20 * .pi / 180
        let band: CGFloat = 260

        // One piece of film: dark strip, sprocket holes, warm frames.
        func piece(from x0: CGFloat, to x1: CGFloat) {
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.rotate(by: angle)
            let rect = CGRect(x: x0, y: -band / 2, width: x1 - x0, height: band)
            ctx.saveGState()
            shadow(ctx, y: -14, blur: 30, alpha: 0.34)
            ctx.addPath(roundedRect(rect, 16))
            ctx.setFillColor(rgb(0x241A20).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(roundedRect(rect, 16))
            ctx.clip()
            gradient([rgb(0x3B2D35), rgb(0x1A1216)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            var x: CGFloat = -700
            while x < 700 {
                ctx.addPath(roundedRect(CGRect(x: x, y: rect.maxY - 40, width: 32, height: 24), 7))
                ctx.addPath(roundedRect(CGRect(x: x, y: rect.minY + 16, width: 32, height: 24), 7))
                x += 60
            }
            ctx.setFillColor(rgb(0xFFEBDA, 0.95).cgColor)
            ctx.fillPath()
            var fx: CGFloat = -700
            while fx < 700 {
                let frame = CGRect(x: fx + 12, y: -76, width: 156, height: 152)
                ctx.saveGState()
                ctx.addPath(roundedRect(frame, 12))
                ctx.clip()
                gradient([rgb(0xFFCB74), rgb(0xF2643C), rgb(0x7C2A4A)], from: CGPoint(x: 0, y: frame.maxY),
                         to: CGPoint(x: 0, y: frame.minY), in: ctx)
                ctx.setFillColor(rgb(0xFFF3CF).cgColor)
                ctx.fillEllipse(in: CGRect(x: frame.midX - 24, y: frame.midY - 2, width: 48, height: 48))
                ctx.setFillColor(rgb(0x4A1A30).cgColor)
                ctx.move(to: CGPoint(x: frame.minX, y: frame.minY + 54))
                ctx.addQuadCurve(to: CGPoint(x: frame.maxX, y: frame.minY + 42), control: CGPoint(x: frame.midX, y: frame.minY + 104))
                ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
                ctx.addLine(to: CGPoint(x: frame.minX, y: frame.minY))
                ctx.fillPath()
                ctx.restoreGState()
                fx += 180
            }
            gradient([NSColor.white.withAlphaComponent(0.13), NSColor.white.withAlphaComponent(0)],
                     from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.midY), in: ctx)
            ctx.restoreGState()
        }
        piece(from: -700, to: -46)
        piece(from: 46, to: 700)

        // Scissors along the gap: pivot just below the strip's centre line, blades opening over it.
        let normal = angle + .pi / 2
        let pivot = CGPoint(x: center.x - cos(normal) * 70, y: center.y - sin(normal) * 70)
        let open: CGFloat = 0.36

        func blade(_ side: CGFloat) {
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle + side * open)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: -24 * side, y: -6))
            path.addCurve(to: CGPoint(x: 2 * side, y: 370), control1: CGPoint(x: -36 * side, y: 150), control2: CGPoint(x: -14 * side, y: 300))
            path.addCurve(to: CGPoint(x: 30 * side, y: 0), control1: CGPoint(x: 20 * side, y: 270), control2: CGPoint(x: 32 * side, y: 120))
            path.closeSubpath()
            ctx.saveGState()
            shadow(ctx, y: -12, blur: 24, alpha: 0.38)
            ctx.addPath(path)
            ctx.setFillColor(rgb(0xD5DBE3).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(side > 0 ? 0xB8C0CC : 0xCDD3DC)], from: CGPoint(x: -30 * side, y: 0),
                     to: CGPoint(x: 30 * side, y: 0), in: ctx)
            ctx.restoreGState()

            // Handle: a stem and a rounded loop, punched through with even-odd fill.
            let ring = CGRect(x: -64, y: -330, width: 128, height: 168)
            let handle = CGMutablePath()
            handle.addPath(roundedRect(CGRect(x: -22, y: -190, width: 44, height: 200), 22))
            handle.addEllipse(in: ring)
            let hole = CGPath(ellipseIn: ring.insetBy(dx: 30, dy: 34), transform: nil)
            ctx.saveGState()
            shadow(ctx, y: -12, blur: 24, alpha: 0.38)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addPath(handle)
            ctx.setFillColor(rgb(0x1F2937).cgColor)
            ctx.fillPath()
            ctx.saveGState()
            ctx.addPath(handle)
            ctx.clip()
            gradient([rgb(0x5B6474), rgb(0x161D29)], from: CGPoint(x: 0, y: -150), to: CGPoint(x: 0, y: -330), in: ctx)
            ctx.restoreGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(hole)
            ctx.fillPath()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            ctx.restoreGState()
        }
        blade(-1)
        blade(1)

        // Pivot screw.
        ctx.saveGState()
        shadow(ctx, y: -3, blur: 8, alpha: 0.45)
        ctx.setFillColor(rgb(0xF8FAFC).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 26, y: pivot.y - 26, width: 52, height: 52))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x94A3B8).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 10, y: pivot.y - 10, width: 20, height: 20))
    }
}
