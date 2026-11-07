import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Curve", size: CGSize(width: 1040, height: 660)) {
    MainActor.assumeIsolated { ContentView(model: .demo) }
}
CurveApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CurveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CurveModel()

    var body: some Scene {
        Window("Curve", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Curve")
            CommandGroup(replacing: .newItem) {
                Button("New Function") {
                    let id = model.addFunction()
                    NotificationCenter.default.post(name: .curveFocusFunction, object: id)
                }
                .keyboardShortcut("n")
            }
            CommandGroup(replacing: .importExport) {
                Button("Export PNG\u{2026}") { model.exportPNG() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Graph as Image") { model.copyImage() }
                    .keyboardShortcut("c", modifiers: [.command, .option])
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom In") { model.zoom(by: 2) }.keyboardShortcut("=")
                Button("Zoom Out") { model.zoom(by: 0.5) }.keyboardShortcut("-")
                Button("Reset View") { model.resetView() }.keyboardShortcut("0")
                Divider()
                Toggle("Show Grid", isOn: $model.showGrid).keyboardShortcut("g", modifiers: [.command, .option])
                Toggle("Show Roots and Intersections", isOn: $model.showPoints)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
            }
        }
    }
}

// MARK: - Icon

//: a neon pink sine wave glowing across graph axes on a midnight tile

func appIcon() -> NSBitmapImageRep {
    render(0x2B2D6E, 0x111237) { ctx in
        let originX: CGFloat = 270, originY: CGFloat = 500

        // Faint ticks along both axes.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.045).cgColor)
        ctx.setLineWidth(4)
        for i in stride(from: 170.0, through: 860.0, by: 115.0) {
            ctx.move(to: CGPoint(x: i, y: 120))
            ctx.addLine(to: CGPoint(x: i, y: 904))
            ctx.move(to: CGPoint(x: 120, y: i + 15))
            ctx.addLine(to: CGPoint(x: 904, y: i + 15))
        }
        ctx.strokePath()

        // Axes with arrowheads.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 10, alpha: 0.35)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 170, y: originY))
        ctx.addLine(to: CGPoint(x: 810, y: originY))
        ctx.move(to: CGPoint(x: originX, y: 200))
        ctx.addLine(to: CGPoint(x: originX, y: 800))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 860, y: originY))
        ctx.addLine(to: CGPoint(x: 796, y: originY + 38))
        ctx.addLine(to: CGPoint(x: 796, y: originY - 38))
        ctx.closePath()
        ctx.move(to: CGPoint(x: originX, y: 850))
        ctx.addLine(to: CGPoint(x: originX - 38, y: 786))
        ctx.addLine(to: CGPoint(x: originX + 38, y: 786))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()

        // The sine curve: one and a half periods, rising through the origin.
        let wave = CGMutablePath()
        let start: CGFloat = 40, end: CGFloat = 990, period: CGFloat = 420, amplitude: CGFloat = 190
        for i in 0...200 {
            let x = start + (end - start) * CGFloat(i) / 200
            let y = originY + amplitude * sin((x - originX) / period * 2 * .pi)
            if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (width, alpha, blur) in [(90.0, 0.22, 60.0), (54.0, 0.5, 30.0)] {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: blur, color: rgb(0xFF2E9A, 1).cgColor)
            ctx.addPath(wave)
            ctx.setStrokeColor(rgb(0xFF2E9A, alpha).cgColor)
            ctx.setLineWidth(width)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.addPath(wave)
        ctx.setStrokeColor(rgb(0xFF3EA5).cgColor)
        ctx.setLineWidth(38)
        ctx.strokePath()
        ctx.addPath(wave)
        ctx.setStrokeColor(rgb(0xFFD1EA).cgColor)
        ctx.setLineWidth(12)
        ctx.strokePath()

        // A marked root where the curve crosses the axis.
        let root = CGPoint(x: originX + period / 2, y: originY)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFF2E9A).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: root.x - 34, y: root.y - 34, width: 68, height: 68))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xFF3EA5).cgColor)
        ctx.fillEllipse(in: CGRect(x: root.x - 17, y: root.y - 17, width: 34, height: 34))
    }
}
