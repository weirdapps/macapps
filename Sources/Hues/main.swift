import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Hues", size: CGSize(width: 1040, height: 680)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
HuesApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: it quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Finder's Open With and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { HuesModel.shared.open(url) }
    }
}

struct HuesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = HuesModel.shared

    var body: some Scene {
        Window("Hues", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Hues")
            SidebarCommands()
            HuesCommands(model: model)
        }
    }
}

struct HuesCommands: Commands {
    @ObservedObject var model: HuesModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Image\u{2026}") { model.open() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .importExport) {
            Menu("Export Palette") {
                ForEach(ExportFormat.allCases) { f in
                    if f == .css {
                        Button("\(f.title)\u{2026}") { model.export(f) }.keyboardShortcut("e", modifiers: [.command, .shift])
                    } else {
                        Button("\(f.title)\u{2026}") { model.export(f) }
                    }
                }
            }
            .disabled(model.swatches.isEmpty)
            Divider()
            Button("Clear History\u{2026}") { model.confirmClear = true }.disabled(model.history.isEmpty)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Hex") { if let s = model.target { model.copy(s) } }
                .keyboardShortcut("c")
                .disabled(model.swatches.isEmpty)
            Menu("Copy Palette As") {
                Button("CSS Variables") { model.copyPalette(.css) }.keyboardShortcut("c", modifiers: [.command, .option])
                Button("Swift Code") { model.copyPalette(.swift) }
                Button("JSON") { model.copyPalette(.json) }
            }
            .disabled(model.swatches.isEmpty)
            Button("Paste Image") { model.paste() }.keyboardShortcut("v")
            Divider()
            Button("Remove Colour") { model.remove(model.selected) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(model.selected == nil)
        }
        CommandGroup(before: .sidebar) {
            Button(model.picking ? "Stop Picking" : "Pick Colours") { model.picking.toggle() }
                .keyboardShortcut("p", modifiers: [])
                .disabled(model.bitmap == nil)
            Button("More Colours") { model.moreColours() }
                .keyboardShortcut("=")
                .disabled(model.bitmap == nil || model.count >= Extractor.range.upperBound)
            Button("Fewer Colours") { model.fewerColours() }
                .keyboardShortcut("-")
                .disabled(model.bitmap == nil || model.count <= Extractor.range.lowerBound)
            Divider()
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0xF6C177, 0xE07A3F) { ctx in
        let out = CGPoint(x: 565, y: 515)
        let chips: [UInt32] = [0x7B5BD6, 0x3E8EF0, 0x3DBE8B, 0xFFD25A, 0xF58A3A, 0xE5484D]

        // White beam from the photo into the prism.
        ctx.saveGState()
        ctx.move(to: CGPoint(x: 300, y: 650))
        ctx.addLine(to: CGPoint(x: 330, y: 690))
        ctx.addLine(to: CGPoint(x: 418, y: 580))
        ctx.addLine(to: CGPoint(x: 398, y: 540))
        ctx.closePath()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Photo card, tilted, upper left.
        ctx.saveGState()
        ctx.translateBy(x: 250, y: 700)
        ctx.rotate(by: 0.16)
        let card = CGRect(x: -115, y: -92, width: 230, height: 184)
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 22, alpha: 0.28)
        ctx.addPath(roundedRect(card, 30))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        let photo = card.insetBy(dx: 16, dy: 16)
        ctx.saveGState()
        ctx.addPath(roundedRect(photo, 18))
        ctx.clip()
        gradient([rgb(0x3B2A6B), rgb(0xE86A4A), rgb(0xFBC86A)], from: CGPoint(x: 0, y: photo.maxY), to: CGPoint(x: 0, y: photo.minY + 50), in: ctx)
        ctx.setFillColor(rgb(0xFFF1C8).cgColor)
        ctx.fillEllipse(in: CGRect(x: 18, y: -10, width: 54, height: 54))
        ctx.move(to: CGPoint(x: photo.minX, y: photo.minY + 40))
        ctx.addLine(to: CGPoint(x: -50, y: 20))
        ctx.addLine(to: CGPoint(x: 0, y: -20))
        ctx.addLine(to: CGPoint(x: 60, y: 10))
        ctx.addLine(to: CGPoint(x: photo.maxX, y: -30))
        ctx.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        ctx.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
        ctx.closePath()
        ctx.setFillColor(rgb(0x2A1D4A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.restoreGState()

        // Coloured rays fanning out to the chips.
        let angles: [CGFloat] = [30, 14, -2, -18, -34, -50].map { $0 * .pi / 180 }
        let reach: CGFloat = 245
        for (i, a) in angles.enumerated() {
            let end = CGPoint(x: out.x + cos(a) * reach, y: out.y + sin(a) * reach)
            let spread: CGFloat = 0.05
            let e1 = CGPoint(x: out.x + cos(a + spread) * reach, y: out.y + sin(a + spread) * reach)
            let e2 = CGPoint(x: out.x + cos(a - spread) * reach, y: out.y + sin(a - spread) * reach)
            ctx.saveGState()
            ctx.move(to: out)
            ctx.addLine(to: e1)
            ctx.addLine(to: e2)
            ctx.closePath()
            ctx.clip()
            gradient([rgb(chips[i], 0.15), rgb(chips[i], 0.75)], from: out, to: end, in: ctx)
            ctx.restoreGState()
        }

        // Prism: a glass triangle.
        let apex = CGPoint(x: 480, y: 700), left = CGPoint(x: 300, y: 350), right = CGPoint(x: 660, y: 350)
        let prism = CGMutablePath()
        prism.move(to: apex)
        prism.addLine(to: right)
        prism.addLine(to: left)
        prism.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.3)
        ctx.addPath(prism)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(prism)
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0.65), NSColor.white.withAlphaComponent(0.12)], from: left, to: right, in: ctx)
        // Inner facet highlight.
        ctx.move(to: apex)
        ctx.addLine(to: CGPoint(x: 400, y: 350))
        ctx.addLine(to: CGPoint(x: 335, y: 350))
        ctx.closePath()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(prism)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(14)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.strokePath()

        // Colour chips at the ends of the rays.
        for (i, a) in angles.enumerated() {
            let c = CGPoint(x: out.x + cos(a) * (reach + 15), y: out.y + sin(a) * (reach + 15))
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: a)
            let r = CGRect(x: -46, y: -46, width: 92, height: 92)
            ctx.saveGState()
            shadow(ctx, y: -6, blur: 14, alpha: 0.3)
            ctx.addPath(roundedRect(r, 24))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(roundedRect(r.insetBy(dx: 9, dy: 9), 16))
            ctx.clip()
            gradient([rgb(chips[i]).blended(withFraction: 0.25, of: .white)!, rgb(chips[i])], from: CGPoint(x: 0, y: 40), to: CGPoint(x: 0, y: -40), in: ctx)
            ctx.restoreGState()
        }
    }
}
