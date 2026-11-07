import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Elements", size: CGSize(width: 1100, height: 720)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
ElementsApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ElementsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = TableModel()

    var body: some Scene {
        Window("Elements", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { ElementsCommands(model: model) }
    }
}

struct ElementsCommands: Commands {
    @ObservedObject var model: TableModel

    var body: some Commands {
        AppHelpCommands(name: "Elements")
        CommandGroup(replacing: .newItem) {}
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Element Details") { model.copySelected() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find Element") { NotificationCenter.default.post(name: .findElement, object: nil) }
                .keyboardShortcut("f")
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(ColorMode.allCases.enumerated()), id: \.element) { i, mode in
                Toggle("Colour by \(mode.title)", isOn: Binding(get: { model.mode == mode }, set: { if $0 { model.mode = mode } }))
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
            }
            Divider()
        }
        CommandMenu("Go") {
            Button("Next Element") { model.hovered = nil; model.selected = min(118, model.selected + 1) }
                .keyboardShortcut("]")
            Button("Previous Element") { model.hovered = nil; model.selected = max(1, model.selected - 1) }
                .keyboardShortcut("[")
            Divider()
            Button("First Element") { model.hovered = nil; model.selected = 1 }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Last Element") { model.hovered = nil; model.selected = 118 }
                .keyboardShortcut(.downArrow, modifiers: .command)
        }
    }
}

// MARK: - Icon

//: a white element tile with three electron orbits crossing it, on cyan

func appIcon() -> NSBitmapImageRep {
    render(0x2EE6E6, 0x1496B8) { ctx in
        let c = CGPoint(x: 512, y: 500)
        let angles: [CGFloat] = [28, -28, 90]
        func orbit(_ angle: CGFloat) -> CGPath {
            var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle * .pi / 180)
            return CGPath(ellipseIn: CGRect(x: -350, y: -118, width: 700, height: 236), transform: &t)
        }
        func point(_ angle: CGFloat, _ t: CGFloat) -> CGPoint {
            let a = angle * .pi / 180
            let x = 350 * cos(t), y = 118 * sin(t)
            return CGPoint(x: c.x + x * cos(a) - y * sin(a), y: c.y + x * sin(a) + y * cos(a))
        }

        // Rings behind the tile.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 14, alpha: 0.18)
        for a in angles {
            ctx.addPath(orbit(a))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(20)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // The element tile.
        let box = CGRect(x: c.x - 172, y: c.y - 172, width: 344, height: 344)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.35)
        ctx.addPath(roundedRect(box, 70))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(box, 70))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xD8F6FA)], from: CGPoint(x: 0, y: box.maxY), to: CGPoint(x: 0, y: box.minY), in: ctx)
        // The rings continue across the tile in deep teal.
        for a in angles {
            ctx.addPath(orbit(a))
            ctx.setStrokeColor(rgb(0x1496B8, 0.85).cgColor)
            ctx.setLineWidth(16)
            ctx.strokePath()
        }
        ctx.restoreGState()

        // Nucleus.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 10, alpha: 0.3)
        for (dx, dy, hex) in [(-28, 18, 0x1496B8), (28, 18, 0x2EC9DC), (0, -28, 0x0E6E8F)] as [(CGFloat, CGFloat, UInt32)] {
            let r = CGRect(x: c.x + dx - 46, y: c.y + dy - 46, width: 92, height: 92)
            ctx.saveGState()
            ctx.addEllipse(in: r)
            ctx.clip()
            radial([rgb(hex).blended(withFraction: 0.45, of: .white)!, rgb(hex)], center: CGPoint(x: r.midX - 12, y: r.midY + 14), radius: 66, in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Electrons, glowing where the rings leave the tile.
        for (a, t) in [(angles[0], CGFloat(0.12)), (angles[1], CGFloat.pi + 0.12), (angles[2], CGFloat(-0.1))] {
            let p = point(a, t)
            radial([NSColor.white.withAlphaComponent(0.7), NSColor.white.withAlphaComponent(0)], center: p, radius: 70, in: ctx)
            ctx.saveGState()
            shadow(ctx, y: -4, blur: 10, alpha: 0.25)
            ctx.addEllipse(in: CGRect(x: p.x - 30, y: p.y - 30, width: 60, height: 60))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
