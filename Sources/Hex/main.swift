import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Hex", size: CGSize(width: 1040, height: 660)) { MainActor.assumeIsolated { ViewerContent(model: .demo) } }
HexApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A viewer of the user's files, like Preview: it stays open with no windows.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files named on the command line (`Hex.app/Contents/MacOS/Hex file.bin`) open like files from Finder.
        let files = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
        if !files.isEmpty { MainActor.assumeIsolated { OpenRouter.shared.open(files.map { URL(fileURLWithPath: $0) }) } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { OpenRouter.shared.open(urls) }
    }
}

struct HexApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Hex", id: "viewer", for: URL.self) { $url in
            ViewerWindow(url: $url)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands { HexCommands() }
    }
}

struct HexCommands: Commands {
    @FocusedObject private var model: HexModel?
    @Environment(\.openWindow) private var openWindow

    private var ready: Bool { model?.hasBytes ?? false }

    var body: some Commands {
        AppHelpCommands(name: "Hex")
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") {
                OpenRouter.shared.openWindow = openWindow
                OpenRouter.shared.choose()
            }
            .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Button("Show in Finder") { if let url = model?.url { revealInFinder([url]) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model?.source == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as Hex") { model?.copy(as: .hex) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("Copy as Text") { model?.copy(as: .text) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!ready)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find\u{2026}") { model?.beginFind() }.keyboardShortcut("f")
                Button("Find Next") { model?.find() }.keyboardShortcut("g")
                    .disabled(model?.needle == nil)
                Button("Find Previous") { model?.find(backwards: true) }.keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model?.needle == nil)
                Button("Use Selection for Find") { model?.useSelectionForFind() }.keyboardShortcut("e")
            }
            .disabled(!ready)
        }
        CommandGroup(after: .toolbar) {
            Button(model?.showInspector ?? true ? "Hide Inspector" : "Show Inspector") { model?.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(model?.url == nil)
            Divider()
        }
        CommandMenu("Go") {
            Button("Jump to Offset\u{2026}") { model?.showJump = true }.keyboardShortcut("l")
                .disabled(!ready)
            Divider()
            Button("Add Bookmark") { model?.addBookmark() }.keyboardShortcut("d")
                .disabled(!ready)
            Button("Next Bookmark") { model?.goToBookmark(next: true) }.keyboardShortcut("]", modifiers: [.command, .option])
                .disabled(model?.bookmarks.isEmpty ?? true)
            Button("Previous Bookmark") { model?.goToBookmark(next: false) }.keyboardShortcut("[", modifiers: [.command, .option])
                .disabled(model?.bookmarks.isEmpty ?? true)
        }
    }
}

// MARK: - Demo

extension HexModel {
    /// A small PNG-like file for the website screenshot: signature, header, a text chunk and compressed-looking data.
    static var demo: HexModel {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        func chunk(_ type: String, _ body: [UInt8]) {
            let n = UInt32(body.count)
            bytes += [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            bytes += Array(type.utf8) + body
            bytes += [0x7A, 0x3C, 0x91, 0xE4]
        }
        chunk("IHDR", [0, 0, 4, 0, 0, 0, 3, 0, 8, 6, 0, 0, 0])
        chunk("tEXt", Array("Software".utf8) + [0] + Array("Hex for macOS, a viewer for every byte".utf8))
        chunk("pHYs", [0, 0, 0x16, 0x25, 0, 0, 0x16, 0x25, 1])
        var seed: UInt32 = 0x2F6B_A11C
        var body: [UInt8] = [0x78, 0x9C]
        for i in 0..<1400 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            body.append(i % 37 < 3 ? 0 : UInt8(seed >> 24))
        }
        chunk("IDAT", body)
        chunk("IEND", [])
        let model = HexModel(demo: bytes, name: "sunrise.png", cursor: 0x10, length: 8, bookmarks: [
            Bookmark(offset: 0, length: 8, name: "PNG signature"),
            Bookmark(offset: 0x10, length: 8, name: "Image size"),
            Bookmark(offset: 0x29, length: 8, name: "Software tag"),
            Bookmark(offset: 0x7C, length: 4, name: "First IDAT chunk"),
        ])
        model.showFind = true
        model.findText = "IDAT"
        return model
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x0F4C5C, 0x05222B) { ctx in
        /// A pointy-top hexagon.
        func hexagon(_ c: CGPoint, _ r: CGFloat) -> CGPath {
            let path = CGMutablePath()
            for k in 0..<6 {
                let a = CGFloat.pi / 2 + CGFloat(k) * .pi / 3
                let p = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
                k == 0 ? path.move(to: p) : path.addLine(to: p)
            }
            path.closeSubpath()
            return path
        }
        let r: CGFloat = 132
        let w = sqrt(3) * r, h = 1.5 * r
        let center = CGPoint(x: 512, y: 500)

        // A faint honeycomb across the whole tile.
        ctx.setStrokeColor(rgb(0x5EEAD4, 0.09).cgColor)
        ctx.setLineWidth(5)
        for row in -4...4 {
            for col in -4...4 {
                let c = CGPoint(x: center.x + CGFloat(col) * w + (row % 2 == 0 ? 0 : w / 2), y: center.y + CGFloat(row) * h)
                ctx.addPath(hexagon(c, r - 10))
            }
        }
        ctx.strokePath()

        // A soft amber glow behind the cluster.
        radial([rgb(0xF59E0B, 0.34), rgb(0xF59E0B, 0)], center: center, radius: 430, in: ctx)

        // Seven cells: the centre and its ring. Two are unlit, like bytes not yet read.
        var cells = [(center, true)]
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            cells.append((CGPoint(x: center.x + w * cos(a), y: center.y + w * sin(a)), k != 2 && k != 4))
        }
        for (c, lit) in cells {
            let path = hexagon(c, r - 13)
            ctx.saveGState()
            if lit {
                ctx.setShadow(offset: .zero, blur: 46, color: rgb(0xFBBF24, 0.75).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(rgb(0xF59E0B).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(path)
                ctx.clip()
                gradient([rgb(0xFEF3C7), rgb(0xFBBF24), rgb(0xD97706)],
                         from: CGPoint(x: c.x, y: c.y + r), to: CGPoint(x: c.x, y: c.y - r), in: ctx)
                // A glassy highlight across the top of each cell.
                ctx.addEllipse(in: CGRect(x: c.x - r * 0.75, y: c.y + r * 0.12, width: r * 1.5, height: r * 0.9))
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.addPath(path)
                ctx.setStrokeColor(rgb(0xFFFBEB, 0.55).cgColor)
                ctx.setLineWidth(4)
                ctx.strokePath()
            } else {
                shadow(ctx, y: -6, blur: 16, alpha: 0.35)
                ctx.addPath(path)
                ctx.setFillColor(rgb(0x0A3440).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.addPath(hexagon(c, r - 17))
                ctx.setStrokeColor(rgb(0xF59E0B, 0.55).cgColor)
                ctx.setLineWidth(7)
                ctx.strokePath()
            }
        }
    }
}
