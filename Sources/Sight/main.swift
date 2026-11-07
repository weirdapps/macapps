import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Sight", size: CGSize(width: 1080, height: 640)) { DemoRoot() }
SightApp.main()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SightModel()

    // A single-window utility quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Images dropped on the Dock icon or opened with Sight from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { model.load(url) }
    }
}

struct SightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Sight", id: "main") {
            ContentView(model: delegate.model)
        }
        .defaultSize(width: 1080, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            SightCommands(model: delegate.model)
            AppHelpCommands(name: "Sight")
        }
    }
}

struct SightCommands: Commands {
    @ObservedObject var model: SightModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.openPanel() }.keyboardShortcut("o")
            Button("Open Sample Design") { model.loadSample() }
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Simulated Image…") { model.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.hasImage)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Simulated Image") { model.copy() }.keyboardShortcut("c").disabled(!model.hasImage)
            Button("Paste Image") { model.paste() }.keyboardShortcut("v")
        }
        CommandGroup(before: .toolbar) {
            Picker("View", selection: $model.layout) {
                Text("Single").keyboardShortcut("1").tag(Layout.single)
                Text("Split Comparison").keyboardShortcut("2").tag(Layout.split)
                Text("Grid of All").keyboardShortcut("3").tag(Layout.grid)
            }
            .pickerStyle(.inline)
            .disabled(!model.hasImage)
            Divider()
            Button("Previous Simulation") { model.step(-1) }.keyboardShortcut("[")
            Button("Next Simulation") { model.step(1) }.keyboardShortcut("]")
            Divider()
            Button("Increase Severity") { model.nudgeSeverity(0.1) }.keyboardShortcut("=")
                .disabled(model.severity >= 1)
            Button("Decrease Severity") { model.nudgeSeverity(-0.1) }.keyboardShortcut("-")
                .disabled(model.severity <= 0.1)
            Divider()
        }
    }
}

// MARK: - Icon

//: an eye whose iris is split into red, green and blue quadrants and one gone grey

func appIcon() -> NSBitmapImageRep {
    render(0x00C2A8, 0x6B4CE6) { ctx in
        let c = CGPoint(x: 512, y: 500)
        let half: CGFloat = 352, lift: CGFloat = 225
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: c.x - half, y: c.y))
        eye.addQuadCurve(to: CGPoint(x: c.x + half, y: c.y), control: CGPoint(x: c.x, y: c.y + lift * 2))
        eye.addQuadCurve(to: CGPoint(x: c.x - half, y: c.y), control: CGPoint(x: c.x, y: c.y - lift * 2))
        eye.closeSubpath()

        // The white of the eye, lifted off the tile.
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.35)
        ctx.addPath(eye)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(eye)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE4E8F2)], from: CGPoint(x: 0, y: c.y + lift), to: CGPoint(x: 0, y: c.y - lift), in: ctx)

        // Iris quadrants: red, green, blue, and one drained of colour.
        let r: CGFloat = 178
        let quads: [(UInt32, UInt32, CGFloat)] = [
            (0xFF6B6B, 0xD62F3C, 0), (0x5BE08A, 0x1E9E52, .pi / 2), (0x9AA3AE, 0x5E6670, .pi), (0x5C9DFF, 0x2357D9, 3 * .pi / 2),
        ]
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 18, alpha: 0.3)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.setFillColor(rgb(0x1F2430).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        for (light, dark, start) in quads {
            ctx.saveGState()
            let wedge = CGMutablePath()
            wedge.move(to: c)
            wedge.addArc(center: c, radius: r - 8, startAngle: start, endAngle: start + .pi / 2, clockwise: false)
            wedge.closeSubpath()
            ctx.addPath(wedge)
            ctx.clip()
            radial([rgb(light), rgb(dark)], center: CGPoint(x: c.x, y: c.y), radius: r, in: ctx)
            ctx.restoreGState()
        }
        // Gaps between the quadrants.
        ctx.setStrokeColor(rgb(0x1F2430).cgColor)
        ctx.setLineWidth(12)
        ctx.move(to: CGPoint(x: c.x - r, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + r, y: c.y))
        ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r))
        ctx.strokePath()

        // Pupil and catchlight.
        ctx.setFillColor(rgb(0x10131A).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 68, y: c.y - 68, width: 136, height: 136))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x + 10, y: c.y + 12, width: 42, height: 42))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 58, y: c.y - 50, width: 22, height: 22))

        // Upper lid shade.
        gradient([NSColor.black.withAlphaComponent(0.12), NSColor.black.withAlphaComponent(0)],
                 from: CGPoint(x: 0, y: c.y + lift), to: CGPoint(x: 0, y: c.y + lift - 90), in: ctx)
        ctx.restoreGState()

        // Lid outline.
        ctx.addPath(eye)
        ctx.setStrokeColor(rgb(0x2A1F6B, 0.35).cgColor)
        ctx.setLineWidth(6)
        ctx.strokePath()
    }
}
