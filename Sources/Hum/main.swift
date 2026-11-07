import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Hum", size: CGSize(width: 960, height: 590)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
HumApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct HumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HumModel()

    var body: some Scene {
        Window("Hum", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 960, height: 590)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Hum")
            HumCommands(model: model)
        }
    }
}

struct HumCommands: Commands {
    @ObservedObject var model: HumModel

    private var dialogOpen: Bool { model.showingSave || model.renaming != nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Save Mix…") { model.showingSave = true }
                .keyboardShortcut("s")
                .disabled(model.activeCount == 0 || dialogOpen)
        }
        CommandMenu("Controls") {
            Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(dialogOpen)
            Divider()
            Button("Volume Up") { model.adjustMaster(by: 0.1) }
                .keyboardShortcut(.upArrow)
            Button("Volume Down") { model.adjustMaster(by: -0.1) }
                .keyboardShortcut(.downArrow)
            Divider()
            Menu("Sleep Timer") { SleepItems(model: model) }
            Divider()
            ForEach(Array(Sound.allCases.enumerated()), id: \.element) { i, sound in
                Toggle(sound.name, isOn: Binding(get: { model.volume(sound) > 0 }, set: { _ in model.toggle(sound) }))
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
            Button("Turn Off All Sounds") { model.clearMix() }
                .keyboardShortcut("0")
                .disabled(model.activeCount == 0)
        }
    }
}

// MARK: - Icon

//: soft layered sound waves rising like dunes under a crescent moon

func appIcon() -> NSBitmapImageRep {
    render(0x6A7BD9, 0x2C3470) { ctx in
        // Moon glow and a crescent.
        let moon = CGPoint(x: 680, y: 718), r: CGFloat = 92
        radial([NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)], center: moon, radius: 250, in: ctx)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        shadow(ctx, y: 0, blur: 30, alpha: 0)
        ctx.setFillColor(rgb(0xFDF8E8).cgColor)
        ctx.fillEllipse(in: CGRect(x: moon.x - r, y: moon.y - r, width: r * 2, height: r * 2))
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: moon.x - r + 52, y: moon.y - r + 34, width: r * 2, height: r * 2))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // A few stars.
        for (p, s) in [(CGPoint(x: 300, y: 790), CGFloat(18)), (CGPoint(x: 430, y: 700), 11), (CGPoint(x: 820, y: 840), 10), (CGPoint(x: 230, y: 650), 8)] {
            sparkle(ctx, at: p, size: s, color: NSColor.white.withAlphaComponent(0.8))
        }

        // Dunes of sound, back to front, each lighter and brighter as it comes closer.
        struct Dune { let base: CGFloat; let amp: CGFloat; let freq: CGFloat; let phase: CGFloat; let top: NSColor; let bottom: NSColor }
        let dunes = [
            Dune(base: 530, amp: 56, freq: 1.25, phase: 0.6, top: rgb(0x8E9CEB, 0.55), bottom: rgb(0x5D6BC8, 0.55)),
            Dune(base: 430, amp: 64, freq: 1.05, phase: 2.4, top: rgb(0xA9B4F3, 0.8), bottom: rgb(0x6E7CD6, 0.8)),
            Dune(base: 320, amp: 70, freq: 0.9, phase: 4.1, top: rgb(0xD3D9FF), bottom: rgb(0x93A0EE)),
            Dune(base: 205, amp: 62, freq: 0.8, phase: 1.3, top: rgb(0xFFFFFF), bottom: rgb(0xC9D0FB)),
        ]
        for d in dunes {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 80, y: 80))
            var crest: [CGPoint] = []
            for s in 0...120 {
                let x = 80 + CGFloat(s) / 120 * 864
                let a = (x - 100) / 824 * 2 * .pi * d.freq + d.phase
                let y = d.base + d.amp * (0.65 * sin(a) + 0.35 * sin(a * 2.1 + 0.7))
                crest.append(CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: 944, y: 80))
            path.closeSubpath()
            ctx.saveGState()
            shadow(ctx, y: 14, blur: 34, alpha: 0.28)
            ctx.addPath(path)
            ctx.setFillColor(d.bottom.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            gradient([d.top, d.bottom], from: CGPoint(x: 0, y: d.base + d.amp), to: CGPoint(x: 0, y: d.base - 220), in: ctx)
            ctx.restoreGState()
            // A thin bright crest line.
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(5)
            ctx.setLineCap(.round)
            ctx.addLines(between: crest)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
