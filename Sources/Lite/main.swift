import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Lite", size: CGSize(width: 1040, height: 660)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
LiteApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A document viewer: closing the last window leaves the app running, like Preview.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // `Lite file.db` from Terminal opens the file too.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let files = CommandLine.arguments.dropFirst().filter { arg in
            var isDirectory: ObjCBool = false
            return !arg.hasPrefix("-") && FileManager.default.fileExists(atPath: arg, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        MainActor.assumeIsolated { Router.shared.open(files.map { URL(fileURLWithPath: $0).standardizedFileURL }) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Router.shared.open(urls) }
    }
}

struct LiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Lite", id: "browser", for: URL.self) { $url in
            DatabaseWindow(url: $url)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands { LiteCommands(recents: Recents.shared) }
    }
}

struct LiteCommands: Commands {
    @ObservedObject var recents: Recents
    @FocusedObject private var model: DatabaseModel?
    @Environment(\.openWindow) private var openWindow

    private func open(_ url: URL) {
        if let model, model.url == nil { model.open(url) } else { openWindow(value: url) }
    }

    var body: some Commands {
        AppHelpCommands(name: "Lite")
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "browser") }
                .keyboardShortcut("n")
            Button("Open…") { if let url = FileTypes.choose() { open(url) } }
                .keyboardShortcut("o")
            Menu("Open Recent") {
                ForEach(recents.urls, id: \.self) { url in
                    Button(url.lastPathComponent) { open(url) }
                }
                if !recents.urls.isEmpty { Divider() }
                Button("Clear Menu") { recents.clear() }.disabled(recents.urls.isEmpty)
            }
        }
        CommandGroup(replacing: .importExport) {
            Button("Export as CSV…") { model?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(model?.canExport ?? false))
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(DatabaseModel.Mode.allCases.enumerated()), id: \.offset) { i, mode in
                Button(mode == .sql ? "SQL Editor" : mode.rawValue) { model?.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))))
                    .disabled(!(model?.isOpen ?? false))
            }
            Divider()
            Button("Reload") { model?.reload() }
                .keyboardShortcut("r")
                .disabled(!(model?.isOpen ?? false))
            Divider()
        }
        CommandMenu("Database") {
            Button("Run Query") { model?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!(model?.isOpen ?? false) || (model?.running ?? false))
            Button("Stop Query") { model?.stop() }
                .keyboardShortcut(".")
                .disabled(!(model?.running ?? false))
            Menu("Recent Queries") {
                if let model, !model.history.entries.isEmpty {
                    ForEach(model.history.entries.prefix(15)) { entry in
                        Button(QueryHistory.title(entry.sql)) { model.useHistory(entry) }
                    }
                    Divider()
                    Button("Clear History") { model.clearHistory() }
                } else {
                    Text("No queries yet")
                }
            }
            Divider()
            Button("Previous Page") { model?.previousPage() }
                .keyboardShortcut("[")
                .disabled(!(model?.canGoBack ?? false))
            Button("Next Page") { model?.nextPage() }
                .keyboardShortcut("]")
                .disabled(!(model?.canGoForward ?? false))
            Divider()
            Button(model?.readOnly == false ? "Make Read Only" : "Allow Writing…") { model?.toggleReadOnly() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!(model?.isOpen ?? false))
        }
    }
}

// MARK: - Icon

/// A stack of glass discs, the classic database cylinder, with a white quill feather leaning across it.
func appIcon() -> NSBitmapImageRep {
    render(0x3D7BFF, 0x1D3FAF) { ctx in
        // Soft glow behind the stack.
        radial([rgb(0x8FB4FF, 0.55), rgb(0x3D7BFF, 0)], center: CGPoint(x: 470, y: 560), radius: 420, in: ctx)

        let cx: CGFloat = 468, rx: CGFloat = 220, ry: CGFloat = 66, thick: CGFloat = 104, gap: CGFloat = 26
        let bottomTop: CGFloat = 330
        // Ground shadow.
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: cx - rx - 10, y: bottomTop - thick - ry - 14, width: 2 * rx + 20, height: 2 * ry + 10))
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
        ctx.setShadow(offset: .zero, blur: 40, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        for level in 0..<3 {
            let top = bottomTop + CGFloat(level) * (thick + gap)
            disc(ctx, cx: cx, top: top, rx: rx, ry: ry, thick: thick, lit: CGFloat(level) / 2)
        }
        feather(ctx)
    }
}

/// One glass disc: a translucent band with a bright rim and a lit top face.
private func disc(_ ctx: CGContext, cx: CGFloat, top: CGFloat, rx: CGFloat, ry: CGFloat, thick: CGFloat, lit: CGFloat) {
    let bottom = top - thick
    let side = CGMutablePath()
    side.move(to: CGPoint(x: cx - rx, y: top))
    side.addLine(to: CGPoint(x: cx - rx, y: bottom))
    side.addArc(center: CGPoint(x: cx, y: bottom), radius: 1, startAngle: .pi, endAngle: 0, clockwise: false,
                transform: CGAffineTransform(translationX: cx, y: bottom).scaledBy(x: rx, y: ry).translatedBy(x: -cx, y: -bottom))
    side.addLine(to: CGPoint(x: cx + rx, y: top))
    side.addArc(center: CGPoint(x: cx, y: top), radius: 1, startAngle: 0, endAngle: .pi, clockwise: true,
                transform: CGAffineTransform(translationX: cx, y: top).scaledBy(x: rx, y: ry).translatedBy(x: -cx, y: -top))
    side.closeSubpath()

    // Side band: glass that is brighter at the edges, as light wraps around it.
    ctx.saveGState()
    shadow(ctx, y: -10, blur: 26, alpha: 0.28)
    ctx.addPath(side)
    ctx.setFillColor(rgb(0x2A55D8, 0.55).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(side)
    ctx.clip()
    gradient([rgb(0xFFFFFF, 0.62), rgb(0xBFD3FF, 0.22), rgb(0x9DB9FF, 0.14), rgb(0xBFD3FF, 0.3), rgb(0xFFFFFF, 0.55)],
             from: CGPoint(x: cx - rx, y: 0), to: CGPoint(x: cx + rx, y: 0), in: ctx)
    // A darker lower lip gives the band thickness.
    gradient([rgb(0x0E2A8A, 0), rgb(0x0E2A8A, 0.35)], from: CGPoint(x: 0, y: top - thick * 0.3), to: CGPoint(x: 0, y: bottom - ry), in: ctx)
    // Specular streak.
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.fill(CGRect(x: cx - rx * 0.72, y: bottom - ry * 0.7, width: 16, height: thick + ry * 0.4))
    ctx.restoreGState()

    ctx.addPath(side)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    // Top face.
    let face = CGRect(x: cx - rx, y: top - ry, width: 2 * rx, height: 2 * ry)
    ctx.saveGState()
    ctx.addEllipse(in: face)
    ctx.clip()
    gradient([rgb(0xFFFFFF, 0.78 + 0.12 * lit), rgb(0xD6E3FF, 0.5 + 0.1 * lit)],
             from: CGPoint(x: cx - rx, y: top + ry), to: CGPoint(x: cx + rx, y: top - ry), in: ctx)
    radial([rgb(0xFFFFFF, 0.7), rgb(0xFFFFFF, 0)], center: CGPoint(x: cx - rx * 0.3, y: top + ry * 0.2), radius: rx * 0.7, in: ctx)
    ctx.restoreGState()
    ctx.addEllipse(in: face.insetBy(dx: 1.5, dy: 1.5))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()
}

/// A quill feather leaning from bottom left to top right, in front of the stack.
private func feather(_ ctx: CGContext) {
    let length: CGFloat = 600, w: CGFloat = 92
    ctx.saveGState()
    ctx.translateBy(x: 395, y: 186)
    ctx.rotate(by: 0.98)

    // Vane: a long leaf, wider above the shaft, with two notches.
    let vane = CGMutablePath()
    let s = length * 0.2
    vane.move(to: CGPoint(x: s, y: 0))
    vane.addCurve(to: CGPoint(x: length * 0.5, y: w * 0.98), control1: CGPoint(x: s + 40, y: w * 0.7), control2: CGPoint(x: length * 0.36, y: w * 0.98))
    vane.addLine(to: CGPoint(x: length * 0.56, y: w * 0.72)) // notch
    vane.addCurve(to: CGPoint(x: length, y: 4), control1: CGPoint(x: length * 0.78, y: w * 1.02), control2: CGPoint(x: length * 0.95, y: w * 0.5))
    vane.addCurve(to: CGPoint(x: length * 0.62, y: -w * 0.74), control1: CGPoint(x: length * 0.94, y: -w * 0.36), control2: CGPoint(x: length * 0.8, y: -w * 0.72))
    vane.addLine(to: CGPoint(x: length * 0.56, y: -w * 0.5)) // notch
    vane.addCurve(to: CGPoint(x: s, y: 0), control1: CGPoint(x: length * 0.4, y: -w * 0.8), control2: CGPoint(x: s + 30, y: -w * 0.5))
    vane.closeSubpath()

    ctx.saveGState()
    shadow(ctx, y: -14, blur: 30, alpha: 0.35)
    ctx.addPath(vane)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(vane)
    ctx.clip()
    gradient([rgb(0xFFFFFF), rgb(0xE4ECFF)], from: CGPoint(x: 0, y: w), to: CGPoint(x: 0, y: -w), in: ctx)
    gradient([rgb(0xC9D8FF, 0.6), rgb(0xFFFFFF, 0)], from: CGPoint(x: s, y: 0), to: CGPoint(x: length * 0.6, y: 0), in: ctx)
    // Barbs: fine strokes sweeping out from the shaft toward the tip.
    ctx.setStrokeColor(rgb(0x6F8FE0, 0.28).cgColor)
    ctx.setLineWidth(2.2)
    var x = s + 18
    while x < length - 20 {
        ctx.move(to: CGPoint(x: x, y: 2))
        ctx.addQuadCurve(to: CGPoint(x: x + 70, y: w * 1.1), control: CGPoint(x: x + 22, y: w * 0.5))
        ctx.move(to: CGPoint(x: x, y: -2))
        ctx.addQuadCurve(to: CGPoint(x: x + 64, y: -w * 1.1), control: CGPoint(x: x + 20, y: -w * 0.5))
        x += 26
    }
    ctx.strokePath()
    ctx.restoreGState()

    // Shaft: tapering from the quill to the tip.
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: -40, y: -5))
    shaft.addLine(to: CGPoint(x: length - 6, y: -0.8))
    shaft.addLine(to: CGPoint(x: length - 6, y: 0.8))
    shaft.addLine(to: CGPoint(x: -40, y: 5))
    shaft.addArc(center: CGPoint(x: -40, y: 0), radius: 5, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: false)
    shaft.closeSubpath()
    ctx.addPath(shaft)
    ctx.setFillColor(rgb(0xA9BEF5).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}
