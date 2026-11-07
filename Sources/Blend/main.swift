import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Blend", size: CGSize(width: 1080, height: 700)) { DemoWindow() }
BlendApp.main()

/// The window as the website shows it, with fixed demo gradients.
struct DemoWindow: View {
    @StateObject private var model = BlendModel.demo
    var body: some View { ContentView(model: model) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BlendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BlendModel()

    var body: some Scene {
        Window("Blend", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Blend")
            SidebarCommands()
            BlendCommands(model: model)
        }
    }
}

// MARK: - Icon

//: a smooth multi-colour orb with a glossy highlight

func appIcon() -> NSBitmapImageRep {
    render(0xFF8FB1, 0x7A6CFF) { ctx in
        let orb = CGRect(x: 512 - 280, y: 500 - 280, width: 560, height: 560)

        // Soft contact shadow under the orb.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: orb.minX + 90, y: orb.minY - 52, width: orb.width - 180, height: 70))
        ctx.clip()
        radial([NSColor.black.withAlphaComponent(0.28), NSColor.black.withAlphaComponent(0)],
               center: CGPoint(x: orb.midX, y: orb.minY - 17), radius: 200, in: ctx)
        ctx.restoreGState()

        // Body, with a drop shadow.
        ctx.saveGState()
        shadow(ctx, y: -26, blur: 50, alpha: 0.35)
        ctx.setFillColor(rgb(0x8A5BFF).cgColor)
        ctx.fillEllipse(in: orb)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: orb)
        ctx.clip()
        // Base sweep: warm top left to deep blue bottom right.
        gradient([rgb(0xFFE07A), rgb(0xFF7C8E), rgb(0xE05BD8), rgb(0x5B5CFF), rgb(0x2D3FD6)],
                 from: CGPoint(x: orb.minX + 40, y: orb.maxY - 40), to: CGPoint(x: orb.maxX - 40, y: orb.minY + 40), in: ctx)
        // Colour blobs that melt into the sweep.
        radial([rgb(0x37E6D0, 0.95), rgb(0x37E6D0, 0)], center: CGPoint(x: orb.minX + 120, y: orb.minY + 140),
               radius: 300, in: ctx)
        radial([rgb(0xFFB347, 0.85), rgb(0xFFB347, 0)], center: CGPoint(x: orb.maxX - 100, y: orb.maxY - 110),
               radius: 250, in: ctx)
        radial([rgb(0xFF5FA2, 0.7), rgb(0xFF5FA2, 0)], center: CGPoint(x: orb.midX + 30, y: orb.midY - 10),
               radius: 210, in: ctx)
        // Rim shading for roundness.
        let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [NSColor.black.withAlphaComponent(0).cgColor,
                                        NSColor.black.withAlphaComponent(0).cgColor,
                                        rgb(0x1A1050, 0.45).cgColor] as CFArray,
                               locations: [0, 0.62, 1])!
        ctx.drawRadialGradient(shade, startCenter: CGPoint(x: orb.midX - 60, y: orb.midY + 70), startRadius: 0,
                               endCenter: CGPoint(x: orb.midX, y: orb.midY), endRadius: orb.width / 2, options: [])
        // Reflected light along the lower edge.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: orb.minX + 70, y: orb.minY + 14, width: orb.width - 140, height: 150))
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.22)],
                 from: CGPoint(x: 0, y: orb.minY + 160), to: CGPoint(x: 0, y: orb.minY + 14), in: ctx)
        ctx.restoreGState()
        // Glossy highlight across the top.
        let gloss = CGRect(x: orb.minX + 78, y: orb.midY + 40, width: orb.width - 156, height: 220)
        ctx.addEllipse(in: gloss)
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0.78), NSColor.white.withAlphaComponent(0.04)],
                 from: CGPoint(x: 0, y: gloss.maxY), to: CGPoint(x: 0, y: gloss.minY), in: ctx)
        ctx.restoreGState()

        // Hairline rim.
        ctx.addEllipse(in: orb.insetBy(dx: 1.5, dy: 1.5))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(3)
        ctx.strokePath()

        // Specular sparkle.
        sparkle(ctx, at: CGPoint(x: orb.minX + 150, y: orb.maxY - 128), size: 34, color: NSColor.white.withAlphaComponent(0.95))
    }
}
