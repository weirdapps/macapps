import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Shrink", size: CGSize(width: 1060, height: 700)) {
    MainActor.assumeIsolated { ContentView(model: Demo.model()) }
}
ShrinkApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Images and folders dropped on the Dock icon or opened with Shrink from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ShrinkModel.shared.add(urls) }
    }
}

struct ShrinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ShrinkModel.shared

    var body: some Scene {
        Window("Shrink", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1060, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Shrink")
            ShrinkCommands(model: model)
        }
    }
}

struct ShrinkCommands: Commands {
    @ObservedObject var model: ShrinkModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Images\u{2026}") { model.openImages() }
                .keyboardShortcut("o")
                .disabled(model.isRunning)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Shrink All") { model.shrinkAll() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isRunning || model.processable.isEmpty)
            Button("Stop") { model.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isRunning)
            Divider()
            Button("Reveal in Finder") { model.reveal(model.selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.hasOutputs)
            Button("Choose Output Folder\u{2026}") { model.chooseOutputFolder() }
                .disabled(model.isRunning)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Remove from List") { model.remove(model.selection) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.isRunning || model.selection.isEmpty)
            Button("Clear List") { model.clear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.isRunning || model.items.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button(model.showSettings ? "Hide Settings" : "Show Settings") {
                withAnimation(.snappy) { model.showSettings.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Picker("Format", selection: $model.settings.format) {
                ForEach(OutputFormat.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.isRunning)
            Divider()
        }
    }
}

// MARK: - Demo data for the website snapshot

enum Demo {
    @MainActor
    static func model() -> ShrinkModel {
        var settings = ShrinkSettings()
        settings.format = .jpeg
        settings.quality = 0.75
        settings.resize = .fit
        settings.maxWidth = 2048
        settings.maxHeight = 2048
        // (name, source type, width, height, bytes, palette, out width, out height, out bytes)
        let rows: [(String, String, Int, Int, Int64, Int, Int, Int, Int64)] = [
            ("IMG_2041.HEIC", "public.heic", 4032, 3024, 3_412_118, 0, 2048, 1536, 618_204),
            ("Lisbon tram.jpg", "public.jpeg", 6000, 4000, 11_402_560, 1, 2048, 1365, 845_311),
            ("Harbour at dusk.jpg", "public.jpeg", 4608, 3456, 7_812_004, 2, 2048, 1536, 702_955),
            ("Screenshot 2026-11-04.png", "public.png", 3024, 1964, 4_118_330, 3, 2048, 1330, 388_142),
            ("Olive grove.tiff", "public.tiff", 5472, 3648, 59_904_512, 4, 2048, 1365, 921_660),
            ("Product shot 03.webp", "org.webmproject.webp", 2400, 2400, 1_604_221, 5, 2048, 2048, 541_870),
            ("Sunrise, Naxos.HEIC", "public.heic", 4032, 3024, 2_906_775, 6, 2048, 1536, 702_118),
            ("Banner.png", "public.png", 1600, 400, 381_447, 7, 1600, 400, 142_305),
            ("Snow on Parnitha.jpg", "public.jpeg", 5184, 3456, 6_204_881, 8, 2048, 1365, 498_330),
            ("Market stall.HEIC", "public.heic", 4032, 3024, 2_652_090, 9, 2048, 1536, 655_472),
        ]
        let items = rows.map { r in
            let url = URL(fileURLWithPath: "/Users/demo/Pictures/Trip/\(r.0)")
            let out = URL(fileURLWithPath: "/Users/demo/Pictures/Trip/\((r.0 as NSString).deletingPathExtension)-small.jpg")
            return ImageItem(url: url, info: ImageInfo(width: r.2, height: r.3, type: r.1, hasAlpha: false, bytes: r.4),
                             thumbnail: picture(r.5), state: .done,
                             output: ShrinkOutput(url: out, type: "public.jpeg", bytes: r.8, width: r.6, height: r.7))
        }
        let model = ShrinkModel(items: items, settings: settings)
        model.selection = [items[1].id]
        return model
    }

    /// A small painted landscape, so the snapshot has believable thumbnails without shipping photos.
    static func picture(_ palette: Int) -> NSImage {
        let skies: [(UInt32, UInt32, UInt32, UInt32)] = [ // Sky top, sky bottom, far hills, near hills.
            (0x6FB7F0, 0xCFE9FF, 0x7A9CC0, 0x3E6E5A),
            (0xF6C27A, 0xFFE9C6, 0xD9843E, 0x8A4B2A),
            (0x3A2F6B, 0xF08A5D, 0x5B3A6E, 0x23203F),
            (0xE9EEF5, 0xF8FAFC, 0xC9D3E0, 0x9AA8BA),
            (0x9ED0E6, 0xEAF6E4, 0x8FB46A, 0x4F7A3A),
            (0xF3E6F0, 0xFFFFFF, 0xE3C2D6, 0xB07AA1),
            (0xFF9E6B, 0xFFE0A8, 0xC9665A, 0x5A2E4A),
            (0x1FC8B0, 0x9FF0E2, 0x0E7C86, 0x0A5560),
            (0x8DB6D9, 0xE8F1F8, 0xFFFFFF, 0x6C8197),
            (0xFFD36B, 0xFFF3CF, 0xE0603C, 0x2F7A4C),
        ]
        let p = skies[palette % skies.count]
        let size = NSSize(width: 120, height: 96)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            gradient([rgb(p.0), rgb(p.1)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            if palette == 3 {
                // A screenshot: a window with a sidebar.
                ctx.setFillColor(rgb(0xFFFFFF).cgColor)
                ctx.addPath(roundedRect(CGRect(x: 14, y: 12, width: 92, height: 70), 6)); ctx.fillPath()
                ctx.setFillColor(rgb(0xDCE3EC).cgColor)
                ctx.fill(CGRect(x: 14, y: 12, width: 28, height: 62))
                ctx.setFillColor(rgb(0x14A29C).cgColor)
                ctx.fill(CGRect(x: 50, y: 56, width: 44, height: 6))
                ctx.setFillColor(rgb(0xC9D3E0).cgColor)
                for y in stride(from: 22, through: 46, by: 8) { ctx.fill(CGRect(x: 50, y: CGFloat(y), width: 48, height: 4)) }
                return true
            }
            if palette == 5 {
                // A product on a seamless backdrop.
                ctx.setFillColor(rgb(0xD8B4CB, 0.5).cgColor)
                ctx.fillEllipse(in: CGRect(x: 34, y: 14, width: 52, height: 10))
                ctx.setFillColor(rgb(0xB07AA1).cgColor)
                ctx.addPath(roundedRect(CGRect(x: 44, y: 20, width: 32, height: 50), 8)); ctx.fillPath()
                ctx.setFillColor(rgb(0x7E4B72).cgColor)
                ctx.fill(CGRect(x: 52, y: 70, width: 16, height: 10))
                return true
            }
            ctx.setFillColor(rgb(0xFFF4C9, palette == 2 ? 0.95 : 0.9).cgColor)
            ctx.fillEllipse(in: CGRect(x: palette % 2 == 0 ? 76 : 22, y: 56, width: 20, height: 20))
            let far = CGMutablePath()
            far.move(to: CGPoint(x: 0, y: 0))
            far.addLine(to: CGPoint(x: 0, y: 40))
            far.addCurve(to: CGPoint(x: 120, y: 44), control1: CGPoint(x: 34, y: 66), control2: CGPoint(x: 70, y: 28))
            far.addLine(to: CGPoint(x: 120, y: 0))
            ctx.addPath(far); ctx.setFillColor(rgb(p.2).cgColor); ctx.fillPath()
            let near = CGMutablePath()
            near.move(to: CGPoint(x: 0, y: 0))
            near.addLine(to: CGPoint(x: 0, y: 20))
            near.addCurve(to: CGPoint(x: 120, y: 26), control1: CGPoint(x: 40, y: 8), control2: CGPoint(x: 80, y: 44))
            near.addLine(to: CGPoint(x: 120, y: 0))
            ctx.addPath(near); ctx.setFillColor(rgb(p.3).cgColor); ctx.fillPath()
            return true
        }
    }
}

// MARK: - Icon

/// An image card squeezed by two arrows into a smaller card, over the ghost of its old size.
func appIcon() -> NSBitmapImageRep {
    render(0x1FC8B0, 0x0E7C86) { ctx in
        // The ghost of the original, larger card.
        let big = CGRect(x: 190, y: 256, width: 644, height: 512)
        ctx.saveGState()
        ctx.addPath(roundedRect(big, 70))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fillPath()
        ctx.addPath(roundedRect(big.insetBy(dx: 6, dy: 6), 64))
        ctx.setLineDash(phase: 0, lengths: [40, 26])
        ctx.setLineCap(.round)
        ctx.setLineWidth(12)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
        ctx.strokePath()
        ctx.restoreGState()

        // The smaller card, a photo on white.
        let card = CGRect(x: 342, y: 382, width: 340, height: 260)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.34)
        ctx.addPath(roundedRect(card, 38))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let photo = card.insetBy(dx: 22, dy: 22)
        ctx.saveGState()
        ctx.addPath(roundedRect(photo, 20))
        ctx.clip()
        gradient([rgb(0x8FE6D8), rgb(0xD9FBF4)], from: CGPoint(x: 0, y: photo.maxY), to: CGPoint(x: 0, y: photo.minY), in: ctx)
        ctx.setFillColor(rgb(0xFFD25A).cgColor)
        ctx.fillEllipse(in: CGRect(x: photo.maxX - 96, y: photo.maxY - 84, width: 54, height: 54))
        let far = CGMutablePath()
        far.move(to: CGPoint(x: photo.minX, y: photo.minY))
        far.addLine(to: CGPoint(x: photo.minX, y: photo.minY + 70))
        far.addLine(to: CGPoint(x: photo.minX + 92, y: photo.minY + 140))
        far.addLine(to: CGPoint(x: photo.minX + 170, y: photo.minY + 72))
        far.addLine(to: CGPoint(x: photo.minX + 220, y: photo.minY + 112))
        far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY + 50))
        far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        ctx.addPath(far)
        ctx.setFillColor(rgb(0x1AA597).cgColor)
        ctx.fillPath()
        let near = CGMutablePath()
        near.move(to: CGPoint(x: photo.minX, y: photo.minY))
        near.addLine(to: CGPoint(x: photo.minX, y: photo.minY + 34))
        near.addCurve(to: CGPoint(x: photo.maxX, y: photo.minY + 40),
                      control1: CGPoint(x: photo.minX + 110, y: photo.minY + 10), control2: CGPoint(x: photo.minX + 190, y: photo.minY + 80))
        near.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
        ctx.addPath(near)
        ctx.setFillColor(rgb(0x0B5F69).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Two arrows pushing the corners in.
        arrow(ctx, from: CGPoint(x: 194, y: 816), to: CGPoint(x: 326, y: 662))
        arrow(ctx, from: CGPoint(x: 830, y: 208), to: CGPoint(x: 698, y: 362))
    }
}

private func arrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint) {
    let length = hypot(b.x - a.x, b.y - a.y)
    let shaft: CGFloat = 54, head: CGFloat = 104, wide: CGFloat = 150
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: -shaft / 2))
    p.addLine(to: CGPoint(x: length - head, y: -shaft / 2))
    p.addLine(to: CGPoint(x: length - head, y: -wide / 2))
    p.addLine(to: CGPoint(x: length, y: 0))
    p.addLine(to: CGPoint(x: length - head, y: wide / 2))
    p.addLine(to: CGPoint(x: length - head, y: shaft / 2))
    p.addLine(to: CGPoint(x: 0, y: shaft / 2))
    p.closeSubpath()
    var t = CGAffineTransform(translationX: a.x, y: a.y).rotated(by: atan2(b.y - a.y, b.x - a.x))
    guard let path = p.copy(using: &t) else { return }

    ctx.saveGState()
    shadow(ctx, y: -10, blur: 22, alpha: 0.3)
    ctx.addPath(path)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(18)
    ctx.setStrokeColor(rgb(0xFFFFFF).cgColor)
    ctx.setFillColor(rgb(0xFFFFFF).cgColor)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    gradient([rgb(0xFFFFFF), rgb(0xD5F7F1)], from: CGPoint(x: 0, y: max(a.y, b.y) + 60), to: CGPoint(x: 0, y: min(a.y, b.y) - 60), in: ctx)
    ctx.restoreGState()
}
