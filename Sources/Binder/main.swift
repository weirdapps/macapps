import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Binder", size: CGSize(width: 1040, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
BinderApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Files dropped on the Dock icon or opened with Open With are added to the window.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { BinderModel.shared.add(urls) }
    }
}

struct BinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = BinderModel.shared

    var body: some Scene {
        Window("Binder", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Binder")
            BinderCommands(model: model)
        }
    }
}

struct BinderCommands: Commands {
    @ObservedObject var model: BinderModel

    private var empty: Bool { model.pages.isEmpty }
    private var editing: Bool { model.showingSplit }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files…") { model.openPanel() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export PDF…") { model.exportPanel() }.keyboardShortcut("s").disabled(empty || model.isBusy)
            Button("Split into PDFs…") { model.showingSplit = true }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(empty || model.isBusy)
        }
        // Select All picks every page unless a text field has focus.
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { send(#selector(NSText.cut(_:))) }.keyboardShortcut("x")
            Button("Copy") { send(#selector(NSText.copy(_:))) }.keyboardShortcut("c")
            Button("Paste") { send(#selector(NSText.paste(_:))) }.keyboardShortcut("v")
            Button("Select All") {
                if NSApp.keyWindow?.firstResponder is NSText { send(#selector(NSText.selectAll(_:))) } else { model.selectAll() }
            }
            .keyboardShortcut("a")
            Button("Select None") { model.selectNone() }.keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!model.hasSelection || editing)
        }
        CommandMenu("Page") {
            Button("Rotate Left") { model.rotate(-90) }.keyboardShortcut("l").disabled(empty || editing)
            Button("Rotate Right") { model.rotate(90) }.keyboardShortcut("r").disabled(empty || editing)
            Divider()
            Button("Move Earlier") { model.nudge(-1) }.keyboardShortcut("[").disabled(!model.hasSelection || editing)
            Button("Move Later") { model.nudge(1) }.keyboardShortcut("]").disabled(!model.hasSelection || editing)
            Button("Reverse Order") { model.reverse() }.disabled(model.pages.count < 2 || editing)
            Divider()
            Button("Delete") { model.delete() }.keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.hasSelection || editing)
            Button("Remove All") { model.clear() }.keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.sources.isEmpty || editing)
        }
        CommandGroup(after: .toolbar) {
            Button("Larger Thumbnails") { zoom(30) }.keyboardShortcut("+")
            Button("Smaller Thumbnails") { zoom(-30) }.keyboardShortcut("-")
            Divider()
        }
    }

    private func send(_ action: Selector) { NSApp.sendAction(action, to: nil, from: nil) }

    private func zoom(_ delta: Double) {
        let r = BinderModel.tileRange
        withAnimation(.snappy) { model.tileSize = min(r.upperBound, max(r.lowerBound, model.tileSize + delta)) }
    }
}

// MARK: - Icon

/// Three fanned PDF pages held by a chrome binder ring through their corner holes, on crimson.
func appIcon() -> NSBitmapImageRep {
    render(0xE8455A, 0x8E1D3B) { ctx in
        let pivot = CGPoint(x: 330, y: 650)
        let page = CGRect(x: -80, y: -480, width: 400, height: 540)
        let hole = CGRect(x: -30, y: -30, width: 60, height: 60)

        func drawPage(angle: CGFloat, shade: CGFloat, content: (CGContext) -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle * .pi / 180)
            ctx.saveGState()
            shadow(ctx, y: -14, blur: 30, alpha: 0.35)
            ctx.addPath(roundedRect(page, 28))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(page, 28))
            ctx.clip()
            gradient([NSColor(white: 1, alpha: 1), NSColor(white: shade, alpha: 1)],
                     from: CGPoint(x: 0, y: page.maxY), to: CGPoint(x: 0, y: page.minY), in: ctx)
            content(ctx)
            ctx.restoreGState()
            // The punched hole, showing the crimson behind with an inner shadow.
            ctx.saveGState()
            ctx.addEllipse(in: hole)
            ctx.clip()
            ctx.setFillColor(rgb(0x7A1830).cgColor)
            ctx.fill(hole)
            ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 8, color: NSColor.black.withAlphaComponent(0.6).cgColor)
            ctx.addRect(hole.insetBy(dx: -30, dy: -30))
            ctx.addEllipse(in: hole)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
            ctx.restoreGState()
        }

        func lines(_ ctx: CGContext, from y: CGFloat, count: Int, color: NSColor) {
            for i in 0..<count {
                let w: CGFloat = i % 3 == 2 ? 170 : 250
                ctx.addPath(roundedRect(CGRect(x: -10, y: y - CGFloat(i) * 44, width: w, height: 18), 9))
            }
            ctx.setFillColor(color.cgColor)
            ctx.fillPath()
        }

        let center = CGPoint(x: pivot.x - 56, y: pivot.y + 56)
        let radius: CGFloat = 79
        func ring(from start: CGFloat, to end: CGFloat, glow: Bool) {
            let a0 = start * .pi / 180, a1 = end * .pi / 180
            ctx.saveGState()
            shadow(ctx, y: -8, blur: 14, alpha: 0.45)
            ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.setLineWidth(30)
            ctx.setStrokeColor(rgb(0x8C929C).cgColor)
            ctx.strokePath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.setLineWidth(30)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            // Chrome: bright on the outer rim, dark inside, like a round wire.
            radial([rgb(0x5E646E), rgb(0x5E646E), rgb(0xF4F6F9), rgb(0xA9AEB7), rgb(0x6F7580)],
                   center: center, radius: radius + 16, in: ctx)
            ctx.restoreGState()
            if glow {
                ctx.addArc(center: center, radius: radius + 4, startAngle: .pi * 0.58, endAngle: .pi * 0.92, clockwise: false)
                ctx.setLineWidth(6)
                ctx.setLineCap(.round)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                ctx.strokePath()
            }
        }

        drawPage(angle: 32, shade: 0.84) { ctx in lines(ctx, from: -140, count: 7, color: NSColor(white: 0.8, alpha: 1)) }
        drawPage(angle: 16, shade: 0.88) { ctx in lines(ctx, from: -140, count: 7, color: NSColor(white: 0.78, alpha: 1)) }
        // The part of the ring behind the front page.
        ring(from: -45, to: 315, glow: true)
        drawPage(angle: 0, shade: 0.92) { ctx in
            // A crimson header band, a picture and lines of text.
            ctx.addPath(roundedRect(CGRect(x: -10, y: -120, width: 250, height: 42), 12))
            ctx.setFillColor(rgb(0xD7384F).cgColor)
            ctx.fillPath()
            ctx.addPath(roundedRect(CGRect(x: -10, y: -268, width: 250, height: 120), 14))
            ctx.setFillColor(rgb(0xF6CDD3).cgColor)
            ctx.fillPath()
            ctx.move(to: CGPoint(x: 8, y: -252))
            ctx.addLine(to: CGPoint(x: 84, y: -186))
            ctx.addLine(to: CGPoint(x: 134, y: -226))
            ctx.addLine(to: CGPoint(x: 180, y: -196))
            ctx.addLine(to: CGPoint(x: 224, y: -252))
            ctx.closePath()
            ctx.setFillColor(rgb(0xE8455A).cgColor)
            ctx.fillPath()
            ctx.fillEllipse(in: CGRect(x: 176, y: -186, width: 28, height: 28))
            lines(ctx, from: -310, count: 4, color: NSColor(white: 0.74, alpha: 1))
        }
        // The part in front: out of the hole and over the top edge.
        ring(from: -45, to: 20, glow: false)
    }
}
