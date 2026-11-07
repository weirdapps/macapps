import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Request", size: CGSize(width: 1100, height: 700)) { MainActor.assumeIsolated { ContentView(model: Samples.demo) } }
RequestApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RequestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Store.load()

    var body: some Scene {
        Window("Request", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Request")
            RequestCommands(model: model)
        }
    }
}

struct RequestCommands: Commands {
    @ObservedObject var model: Store

    private var hasResponse: Bool {
        if case .done = model.currentResponse { return true }
        return false
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Request") { model.newRequest() }.keyboardShortcut("n")
            Button("New Collection") { model.newCollection() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Duplicate Request") { model.duplicate() }.keyboardShortcut("d").disabled(model.current == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Response\u{2026}") { model.saveResponse() }.keyboardShortcut("s").disabled(!hasResponse)
            Button("Save to Collection") { model.saveToCollection() }.keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.currentHistory == nil)
        }
        CommandMenu("Request") {
            Button("Send") { model.send() }.keyboardShortcut(.return).disabled(model.current == nil || model.isSending)
            Button("Cancel") { model.cancel() }.keyboardShortcut(".").disabled(!model.isSending)
            Divider()
            Button("Copy as curl") { model.copyCurl() }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.current == nil)
            Button("Copy Response Body") { model.copyBody() }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(!hasResponse)
            Button("Format JSON Body") { model.formatBody() }.keyboardShortcut("i", modifiers: .control).disabled(!model.canFormatBody)
            Divider()
            Picker("Environment", selection: $model.workspace.activeEnvironment) {
                Text("No Environment").tag(UUID?.none)
                ForEach(model.workspace.environments) { Text($0.name).tag(Optional($0.id)) }
            }
            Button("Manage Environments\u{2026}") { model.showEnvironments = true }.keyboardShortcut("e")
            Divider()
            Button("Clear History") { model.clearHistory() }.disabled(model.history.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button("Params") { model.editorTab = .params }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Headers") { model.editorTab = .headers }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Body") { model.editorTab = .body }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            Button("Pretty Response") { model.responseTab = .pretty }.keyboardShortcut("1")
            Button("Raw Response") { model.responseTab = .raw }.keyboardShortcut("2")
            Button("Response Headers") { model.responseTab = .headers }.keyboardShortcut("3")
            Divider()
        }
    }
}

// MARK: - Icon

/// A paper plane leaving a pair of braces, with motion streaks, on electric purple.
func appIcon() -> NSBitmapImageRep {
    render(0x7A5CFF, 0x3B22C9) { ctx in
        // A soft glow behind the plane.
        radial([NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: 640, y: 620), radius: 420, in: ctx)

        // Braces, lower left.
        func brace(x: CGFloat, mirror: Bool) -> CGPath {
            let top: CGFloat = 520, bottom: CGFloat = 230, mid = (top + bottom) / 2, w: CGFloat = 72, h = top - bottom
            let s: CGFloat = mirror ? -1 : 1
            let p = CGMutablePath()
            let stem = x + s * w * 0.42
            p.move(to: CGPoint(x: x + s * w, y: top))
            p.addQuadCurve(to: CGPoint(x: stem, y: top - h * 0.11), control: CGPoint(x: stem, y: top))
            p.addLine(to: CGPoint(x: stem, y: mid + h * 0.12))
            p.addQuadCurve(to: CGPoint(x: x, y: mid), control: CGPoint(x: stem, y: mid))
            p.addQuadCurve(to: CGPoint(x: stem, y: mid - h * 0.12), control: CGPoint(x: stem, y: mid))
            p.addLine(to: CGPoint(x: stem, y: bottom + h * 0.11))
            p.addQuadCurve(to: CGPoint(x: x + s * w, y: bottom), control: CGPoint(x: stem, y: bottom))
            return p
        }
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 22, alpha: 0.28)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(38)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.94).cgColor)
        ctx.addPath(brace(x: 170, mirror: false))
        ctx.addPath(brace(x: 410, mirror: true))
        ctx.strokePath()
        ctx.restoreGState()

        // Motion streaks from between the braces towards the plane.
        let angle: CGFloat = 0.62
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let streaks: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
            (CGPoint(x: 455, y: 415), 150, 26, 0.8), (CGPoint(x: 490, y: 345), 120, 20, 0.55), (CGPoint(x: 440, y: 500), 80, 16, 0.4),
        ]
        ctx.setLineCap(.round)
        for (start, length, width, alpha) in streaks {
            ctx.setLineWidth(width)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.move(to: start)
            ctx.addLine(to: CGPoint(x: start.x + dir.x * length, y: start.y + dir.y * length))
            ctx.strokePath()
        }

        // The paper plane, nose up and to the right.
        let centre = CGPoint(x: 668, y: 648), scale: CGFloat = 236
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + scale * (x * dir.x - y * dir.y), y: centre.y + scale * (x * dir.y + y * dir.x))
        }
        let nose = pt(1, 0), upper = pt(-0.8, 0.62), notch = pt(-0.42, 0.02), lower = pt(-0.62, -0.5), keel = pt(-0.2, -0.2)
        func poly(_ points: [CGPoint], _ color: NSColor) {
            ctx.move(to: points[0])
            for p in points.dropFirst() { ctx.addLine(to: p) }
            ctx.closePath()
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 30, alpha: 0.35)
        poly([nose, upper, notch, lower], .white)
        ctx.restoreGState()
        poly([nose, upper, notch], .white)
        ctx.saveGState()
        ctx.move(to: nose); ctx.addLine(to: notch); ctx.addLine(to: lower); ctx.closePath()
        ctx.clip()
        gradient([rgb(0xE2DBFF), rgb(0xB8A8FF)], from: nose, to: lower, in: ctx)
        ctx.restoreGState()
        poly([nose, notch, keel], rgb(0x9C88FF))
    }
}
