import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Heft", size: CGSize(width: 1080, height: 680)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
HeftApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct HeftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HeftModel()

    var body: some Scene {
        Window("Heft", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Heft")
            HeftCommands(model: model)
        }
    }
}

struct HeftCommands: Commands {
    @ObservedObject var model: HeftModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Folder\u{2026}") { model.chooseFolder() }.keyboardShortcut("o")
            Button("Rescan") { model.rescan() }.keyboardShortcut("r").disabled(!model.canRescan)
            Divider()
            Button("Reveal in Finder") { model.reveal() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.phase != .ready)
            Button("Move to Trash\u{2026}") { model.requestTrash() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canTrash)
        }
        CommandGroup(before: .toolbar) {
            Button("As Treemap") { model.viewMode = .treemap }.keyboardShortcut("1")
            Button("As List") { model.viewMode = .list }.keyboardShortcut("2")
            Divider()
            Button("Enclosing Folder") { model.goUp() }.keyboardShortcut(.upArrow).disabled(!model.canGoUp)
            Button("Open Selected Folder") { model.openSelected() }.keyboardShortcut(.downArrow).disabled(!model.canOpenSelected)
            Button("Back to Top") { model.goToTop() }.keyboardShortcut(.upArrow, modifiers: [.command, .shift]).disabled(!model.canGoUp)
            Divider()
        }
    }
}

// MARK: - Icon

//: a squarified treemap of coloured blocks on copper, the biggest block glowing

func appIcon() -> NSBitmapImageRep {
    render(0xF29B4B, 0xB04A1E) { ctx in
        let well = CGRect(x: 176, y: 176, width: 672, height: 672)
        // Dark recessed well.
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 26, alpha: 0.35)
        ctx.addPath(roundedRect(well, 92))
        ctx.setFillColor(rgb(0x3B1A0B).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(well, 92))
        ctx.clip()
        gradient([rgb(0x2A1107), rgb(0x4A2412)], from: CGPoint(x: 0, y: well.maxY), to: CGPoint(x: 0, y: well.minY), in: ctx)
        ctx.restoreGState()

        // Blocks in a 640 grid inside the well, y up.
        let inner = well.insetBy(dx: 30, dy: 30)
        let s = inner.width / 640
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: inner.minX + x * s, y: inner.minY + y * s, width: w * s, height: h * s)
        }
        let blocks: [(CGRect, UInt32, UInt32)] = [
            (r(0, 0, 384, 218), 0x3ED3C2, 0x0F8F84),
            (r(398, 384, 242, 256), 0xA78BFA, 0x6D3FE0),
            (r(398, 184, 140, 186), 0x60A5FA, 0x2563EB),
            (r(552, 184, 88, 186), 0xF472B6, 0xDB2777),
            (r(398, 0, 130, 170), 0x4ADE80, 0x16A34A),
            (r(542, 82, 98, 88), 0xFBBF24, 0xD97706),
            (r(542, 0, 98, 68), 0xCBD5E1, 0x94A3B8),
        ]
        for (rect, top, bottom) in blocks {
            let radius: CGFloat = min(rect.width, rect.height) < 120 ? 18 : 26
            ctx.saveGState()
            shadow(ctx, y: -6, blur: 12, alpha: 0.4)
            ctx.addPath(roundedRect(rect, radius))
            ctx.setFillColor(rgb(bottom).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(rect, radius))
            ctx.clip()
            gradient([rgb(top), rgb(bottom)], from: CGPoint(x: rect.minX, y: rect.maxY), to: CGPoint(x: rect.maxX, y: rect.minY), in: ctx)
            gradient([NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)],
                     from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.maxY - min(rect.height, 90)), in: ctx)
            ctx.restoreGState()
        }

        // The big block, glowing.
        let big = r(0, 232, 384, 408)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xFFC56B, 0.95).cgColor)
        ctx.addPath(roundedRect(big, 30))
        ctx.setFillColor(rgb(0xFFB547).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(big, 30))
        ctx.clip()
        gradient([rgb(0xFFF4CF), rgb(0xFFC15C), rgb(0xF2852E)], from: CGPoint(x: big.minX, y: big.maxY), to: CGPoint(x: big.maxX, y: big.minY), in: ctx)
        radial([NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: big.minX + big.width * 0.34, y: big.maxY - big.height * 0.3), radius: big.width * 0.62, in: ctx)
        ctx.restoreGState()
        ctx.addPath(roundedRect(big.insetBy(dx: 2, dy: 2), 28))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()
        sparkle(ctx, at: CGPoint(x: big.maxX - 74, y: big.maxY - 76), size: 34, color: NSColor.white.withAlphaComponent(0.95))
    }
}
