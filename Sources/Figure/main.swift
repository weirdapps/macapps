import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Figure", size: CGSize(width: 960, height: 600)) { MainActor.assumeIsolated { ContentView(model: FigureModel.demo) } }
FigureApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window notepad: closing the window quits, like Calculator. Sheets are saved as you type.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct FigureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FigureModel()
    @AppStorage("fontSize") private var fontSize = Theme.defaultFontSize

    var body: some Scene {
        Window("Figure", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 960, height: 600)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Figure")
            CommandGroup(replacing: .newItem) {
                Button("New Sheet") { model.newSheet() }.keyboardShortcut("n")
                Button("Duplicate Sheet") { model.duplicate() }.keyboardShortcut("d")
                Divider()
                Button("Export with Results…") { model.export() }.keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Delete Sheet…") { model.requestDelete() }.keyboardShortcut(.delete, modifiers: [.command, .option])
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Last Result") { model.copyLastResult() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy Sheet with Results") { model.copyWithResults() }.keyboardShortcut("c", modifiers: [.command, .option, .shift])
            }
            CommandGroup(before: .toolbar) {
                Button("Show Reference") { model.showReference.toggle() }.keyboardShortcut("/")
                Divider()
                Button("Bigger Text") { fontSize = min(28, fontSize + 1) }.keyboardShortcut("+")
                Button("Smaller Text") { fontSize = max(11, fontSize - 1) }.keyboardShortcut("-")
                Button("Actual Size") { fontSize = Theme.defaultFontSize }.keyboardShortcut("0")
                Divider()
            }
        }
    }
}

// MARK: - Icon

/// A ruled page with a big, glowing equals sign forming at its right margin.
func appIcon() -> NSBitmapImageRep {
    render(0xFFB86B, 0xF2683C) { ctx in
        // Warm glow where the answer lands.
        radial([rgb(0xFFF3C4, 0.75), rgb(0xFFE0A0, 0.25), rgb(0xFFD08A, 0)], center: CGPoint(x: 690, y: 470), radius: 330, in: ctx)

        // The page.
        let page = CGRect(x: 190, y: 190, width: 470, height: 640)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.28)
        ctx.addPath(roundedRect(page, 44))
        ctx.setFillColor(rgb(0xFFFDF8).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(page, 44))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xFBEFE2)], from: CGPoint(x: 0, y: page.maxY), to: CGPoint(x: 0, y: page.minY), in: ctx)
        // Ruled lines.
        ctx.setFillColor(rgb(0x9DB7D6, 0.55).cgColor)
        for k in 0..<7 {
            let y = page.maxY - 120 - CGFloat(k) * 74
            ctx.fill(CGRect(x: page.minX, y: y, width: page.width, height: 5))
        }
        // The margin rule on the left.
        ctx.setFillColor(rgb(0xF2683C, 0.55).cgColor)
        ctx.fill(CGRect(x: page.minX + 74, y: page.minY, width: 5, height: page.height))
        // Handwritten figures sitting on the lines.
        let strokes: [CGFloat] = [250, 200, 150, 110, 160, 0]
        ctx.setFillColor(rgb(0x5B4A42, 0.78).cgColor)
        for (k, w) in strokes.enumerated() where w > 0 {
            let y = page.maxY - 120 - CGFloat(k) * 74 + 16
            ctx.addPath(roundedRect(CGRect(x: page.minX + 108, y: y, width: w, height: 22), 11))
            ctx.fillPath()
        }
        ctx.restoreGState()

        // The equals sign, two glowing bars breaking out past the page edge.
        for y in [CGFloat(508), 392] {
            let bar = CGRect(x: 480, y: y, width: 360, height: 84)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xFFF1B8, 0.95).cgColor)
            ctx.addPath(roundedRect(bar, 42))
            ctx.setFillColor(rgb(0xFFF6E0).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            shadow(ctx, y: -10, blur: 22, alpha: 0.22)
            ctx.addPath(roundedRect(bar, 42))
            ctx.setFillColor(rgb(0xC9481F).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(bar, 42))
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xFFE7C2)], from: CGPoint(x: 0, y: bar.maxY), to: CGPoint(x: 0, y: bar.minY), in: ctx)
            // Highlight along the top edge of each bar.
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
            ctx.addPath(roundedRect(CGRect(x: bar.minX + 30, y: bar.maxY - 26, width: bar.width - 60, height: 12), 6))
            ctx.fillPath()
            ctx.restoreGState()
            // A warm rim so the bars read against the white page as well as the tile.
            ctx.addPath(roundedRect(bar.insetBy(dx: 2, dy: 2), 40))
            ctx.setStrokeColor(rgb(0xF08A4B, 0.7).cgColor)
            ctx.setLineWidth(4)
            ctx.strokePath()
        }
        sparkle(ctx, at: CGPoint(x: 800, y: 680), size: 46, color: NSColor.white.withAlphaComponent(0.95))
        sparkle(ctx, at: CGPoint(x: 735, y: 300), size: 24, color: NSColor.white.withAlphaComponent(0.8))
    }
}
