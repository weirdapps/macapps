import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Harbour at dusk", size: CGSize(width: 1060, height: 660)) {
    ContentView(model: MainActor.assumeIsolated { LoopModel.demo() })
}
LoopApp.main()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LoopModel()

    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Open With from Finder, or files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls, replacing: true)
    }
}

struct LoopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Loop", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 1060, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Loop")
            LoopCommands(model: delegate.model)
        }
    }
}

struct LoopCommands: Commands {
    @ObservedObject var model: LoopModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.showOpenPanel() }.keyboardShortcut("o")
            Button("Add Images…") { model.showAddImagesPanel() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(model.mode != .images || model.isExporting)
            Divider()
            Button("Start Over") { model.reset() }
                .keyboardShortcut("n")
                .disabled(model.mode == .empty || model.isExporting)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export GIF…") { model.beginExport() }
                .keyboardShortcut("e")
                .disabled(!model.canExport)
            Button("Show Last Export in Finder") { model.revealLastExport() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.lastExport == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Frame") { model.deleteSelectedFrame() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.mode != .images || model.selectedFrame == nil)
            Button("Move Frame Left") { model.moveSelectedFrame(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(model.mode != .images || (model.selectedIndex ?? 0) == 0)
            Button("Move Frame Right") { model.moveSelectedFrame(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.mode != .images || (model.selectedIndex ?? model.frames.count) >= model.frames.count - 1)
            Button("Use Frame Delay for All Frames") { model.applySelectedDelayToAll() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.mode != .images || model.selectedFrame == nil)
        }
        CommandMenu("Playback") {
            Button(model.isPlaying ? "Pause Video" : "Play Video") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.mode != .video || model.player == nil)
            Button("Set In Point") { model.setInAtPlayhead() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(model.mode != .video)
            Button("Set Out Point") { model.setOutAtPlayhead() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(model.mode != .video)
            Button("Use Whole Clip") { model.useWholeClip() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(model.mode != .video)
            Divider()
            Button(model.previewPaused ? "Play Preview" : "Pause Preview") { model.previewPaused.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.mode == .empty)
        }
    }
}

// MARK: - Icon

//: an infinity ribbon of film, with frames and sprocket holes, on lime

func appIcon() -> NSBitmapImageRep {
    render(0xA6E22E, 0x2FA84F) { ctx in
        let center = CGPoint(x: 512, y: 500)
        let a: CGFloat = 318
        // Lemniscate of Bernoulli, slightly tilted.
        let tilt: CGFloat = -0.14
        func point(_ t: CGFloat) -> CGPoint {
            let d = 1 + sin(t) * sin(t)
            let x = a * cos(t) / d, y = a * sin(t) * cos(t) / d * 1.25
            return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
        }
        let steps = 720
        // Start at the strand that passes under the crossing, so the seam where the ribbon closes stays hidden.
        let all = (0...steps).map { point(1.5 * .pi + CGFloat($0) / CGFloat(steps) * 2 * .pi) }
        // Arc length at each sample, so frames and holes sit evenly along the ribbon.
        var lengths: [CGFloat] = [0]
        for i in 1..<all.count { lengths.append(lengths[i - 1] + hypot(all[i].x - all[i - 1].x, all[i].y - all[i - 1].y)) }

        let band: CGFloat = 132, window: CGFloat = 84
        func film(_ range: Range<Int>, shadowed: Bool, closed: Bool = false, bandOnly: Bool = false) {
            let pts = Array(all[range.lowerBound...min(range.upperBound, all.count - 1)])
            let path = CGMutablePath()
            path.addLines(between: pts)
            if closed { path.closeSubpath() }
            ctx.saveGState()
            if shadowed { shadow(ctx, y: -14, blur: 30, alpha: 0.38) }
            // Filled outline rather than a stroke: stroking a dense polyline leaves hairline cracks on tight curves.
            ctx.addPath(path.copy(strokingWithWidth: band, lineCap: .butt, lineJoin: .round, miterLimit: 10))
            ctx.setFillColor(rgb(0x1C2420).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            if bandOnly { return }
            // Picture frames: a dashed, lighter inner band.
            ctx.saveGState()
            ctx.addPath(path)
            ctx.setLineWidth(window)
            ctx.setLineDash(phase: lengths[range.lowerBound], lengths: [62, 14])
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            gradient([rgb(0xF7FFE6), rgb(0xC9F07A)], from: CGPoint(x: 0, y: 760), to: CGPoint(x: 0, y: 260), in: ctx)
            ctx.restoreGState()
            // Sprocket holes along both edges.
            var next = (lengths[range.lowerBound] / 30).rounded(.up) * 30
            for i in range.lowerBound..<min(range.upperBound, all.count - 1) where lengths[i] >= next {
                next += 30
                let p = all[i], q = all[i + 1]
                let len = max(hypot(q.x - p.x, q.y - p.y), 0.001)
                let nx = -(q.y - p.y) / len, ny = (q.x - p.x) / len
                let angle = atan2(q.y - p.y, q.x - p.x)
                for side: CGFloat in [-1, 1] {
                    let c = CGPoint(x: p.x + nx * side * 54, y: p.y + ny * side * 54)
                    ctx.saveGState()
                    ctx.translateBy(x: c.x, y: c.y)
                    ctx.rotate(by: angle)
                    ctx.addPath(roundedRect(CGRect(x: -6.5, y: -5, width: 13, height: 10), 3))
                    ctx.setFillColor(rgb(0xEFFFD6, 0.92).cgColor)
                    ctx.fillPath()
                    ctx.restoreGState()
                }
            }
        }
        // The whole ribbon, then the strand through the crossing again on top so it reads as over and under.
        film(0..<steps, shadowed: true, closed: true)
        // A soft round mask, so the second shadow fades out instead of ending in a visible edge.
        let gray = CGColorSpaceCreateDeviceGray()
        let maskCtx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: gray,
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let fade = CGGradient(colorsSpace: gray, colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                              locations: [0, 0.55, 1])!
        maskCtx.drawRadialGradient(fade, startCenter: center, startRadius: 0, endCenter: center, endRadius: 170, options: [])
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: 1024), mask: maskCtx.makeImage()!)
        film((steps / 2 - 80)..<(steps / 2 + 80), shadowed: true, bandOnly: true)
        ctx.restoreGState()
        // Then the strand itself, crisp, over its own shadow. Its ends sit in the dark gaps between frames, so no seam shows.
        func gap(_ i: Int) -> Int {
            var j = i
            while j < steps, !(64...74).contains(lengths[j].truncatingRemainder(dividingBy: 76)) { j += 1 }
            return j
        }
        film(gap(steps / 2 - 90)..<gap(steps / 2 + 80), shadowed: false)
        // A glint, for the shine of a fresh GIF.
        sparkle(ctx, at: CGPoint(x: 770, y: 712), size: 34, color: NSColor.white.withAlphaComponent(0.9))
    }
}
