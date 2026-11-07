import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Cue", size: CGSize(width: 1100, height: 700)) { DemoRoot() }
CueApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CueModel()
    var body: some Scene {
        Window("Cue", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Cue")
            CueCommands(model: model)
        }
    }
}

struct CueCommands: Commands {
    @ObservedObject var model: CueModel
    @ObservedObject var prompter = PromptController.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Script") { model.newScript() }.keyboardShortcut("n")
            Button("Import Text…") { model.isImporting = true }.keyboardShortcut("o")
            Divider()
            Button("Duplicate Script") { if let id = model.selection { model.duplicate(id) } }
                .keyboardShortcut("d")
                .disabled(model.selection == nil)
            Button("Export as Text…") { if let id = model.selection { model.export(id) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            DeleteScriptButton(model: model)
        }
        CommandMenu("Prompt") {
            if prompter.isActive {
                Button("Stop Prompting") { prompter.stop() }.keyboardShortcut(.return, modifiers: .command)
            } else {
                Button("Start Prompting") { if let script = model.selected { prompter.start(script, model: model) } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.selected == nil)
            }
            Divider()
            Button("Faster") { model.settings.changeSpeed(by: 0.5) }.keyboardShortcut("]")
            Button("Slower") { model.settings.changeSpeed(by: -0.5) }.keyboardShortcut("[")
            Divider()
            Button("Larger Text") { model.settings.changeFont(by: 8) }.keyboardShortcut("+")
            Button("Smaller Text") { model.settings.changeFont(by: -8) }.keyboardShortcut("-")
            Divider()
            Toggle("Mirror Horizontally", isOn: $model.settings.mirror).keyboardShortcut("m", modifiers: [.command, .shift])
            Toggle("Show Reading Line", isOn: $model.settings.showReadingLine).keyboardShortcut("l", modifiers: [.command, .shift])
            Toggle("Count Down Before Start", isOn: $model.settings.countdown)
            Divider()
            Picker("Display", selection: model.pickerDisplay) {
                Text("Main Display").tag(UInt32(0))
                ForEach(NSScreen.screens.dropFirst(), id: \.displayID) { screen in
                    Text(screen.localizedName).tag(screen.displayID)
                }
            }
        }
    }
}

/// Edit > Delete Script, with undo through the focused window's undo manager.
struct DeleteScriptButton: View {
    @ObservedObject var model: CueModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Button("Delete Script") { if let id = model.selection { model.delete(id, undo: undoManager) } }
            .keyboardShortcut(.delete, modifiers: [.command, .option])
            .disabled(model.selection == nil)
    }
}

// MARK: - Icon

//: a camera lens on dark glass, lines of script gliding across it and one lit cyan reading line

func appIcon() -> NSBitmapImageRep {
    render(0x3A3F4B, 0x101217) { ctx in
        let c = CGPoint(x: 512, y: 500)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!

        // Cyan glow behind the lens.
        radial([rgb(0x22D3EE, 0.34), rgb(0x22D3EE, 0)], center: c, radius: 430, in: ctx)

        // Outer barrel: brushed metal ring.
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.55)
        ctx.addEllipse(in: CGRect(x: c.x - 330, y: c.y - 330, width: 660, height: 660))
        ctx.setFillColor(rgb(0x2A2E37).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 330, y: c.y - 330, width: 660, height: 660))
        ctx.clip()
        gradient([rgb(0x8A909C), rgb(0x3B404A), rgb(0x1A1D23)], from: CGPoint(x: c.x - 200, y: c.y + 330), to: CGPoint(x: c.x + 200, y: c.y - 330), in: ctx)
        ctx.restoreGState()
        // Grip ridges on the barrel.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        for i in 0..<72 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(i) / 72 * 2 * .pi)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.fill(CGRect(x: 300, y: -4, width: 26, height: 8))
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Inner rings.
        for (r, top, bottom) in [(292.0, 0x14161B, 0x050608), (262.0, 0x2C313B, 0x0B0C10)] as [(CGFloat, UInt32, UInt32)] {
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.clip()
            gradient([rgb(top), rgb(bottom)], from: CGPoint(x: c.x, y: c.y - r), to: CGPoint(x: c.x, y: c.y + r), in: ctx)
            ctx.restoreGState()
        }

        // The glass.
        let glassR: CGFloat = 238
        let glass = CGRect(x: c.x - glassR, y: c.y - glassR, width: 2 * glassR, height: 2 * glassR)
        ctx.saveGState()
        ctx.addEllipse(in: glass)
        ctx.clip()
        let g = CGGradient(colorsSpace: cs, colors: [rgb(0x15364A).cgColor, rgb(0x081620).cgColor, rgb(0x020406).cgColor] as CFArray,
                           locations: [0, 0.6, 1])!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: c.x + 40, y: c.y - 30), startRadius: 0, endCenter: c, endRadius: glassR,
                               options: [.drawsAfterEndLocation])

        // Script lines reflected on the glass, slightly curved by the lens.
        ctx.setLineCap(.round)
        let rows: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [ // y offset, start, length, alpha
            (170, -150, 230, 0.16), (110, -200, 330, 0.26), (50, -210, 290, 0.38),
            (-10, -215, 400, 1.0), (-70, -210, 260, 0.42), (-130, -190, 330, 0.28), (-190, -140, 200, 0.16),
        ]
        for (dy, x0, len, alpha) in rows {
            let lit = alpha == 1
            ctx.saveGState()
            if lit {
                ctx.setShadow(offset: .zero, blur: 28, color: rgb(0x22D3EE, 0.95).cgColor)
                ctx.setStrokeColor(rgb(0xA5F3FC).cgColor)
                ctx.setLineWidth(30)
            } else {
                ctx.setStrokeColor(rgb(0xBFEFFF, alpha * 0.85).cgColor)
                ctx.setLineWidth(24)
            }
            let y = c.y + dy
            let bow = (1 - abs(dy) / 240) * 14
            ctx.move(to: CGPoint(x: c.x + x0, y: y))
            ctx.addQuadCurve(to: CGPoint(x: c.x + x0 + len, y: y), control: CGPoint(x: c.x + x0 + len / 2, y: y - bow))
            ctx.strokePath()
            ctx.restoreGState()
        }
        // Reading line marker arrows on the lit line.
        ctx.setFillColor(rgb(0x22D3EE).cgColor)
        ctx.setShadow(offset: .zero, blur: 18, color: rgb(0x22D3EE, 0.9).cgColor)
        ctx.move(to: CGPoint(x: c.x - 236, y: c.y + 12))
        ctx.addLine(to: CGPoint(x: c.x - 200, y: c.y - 10))
        ctx.addLine(to: CGPoint(x: c.x - 236, y: c.y - 32))
        ctx.closePath()
        ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // Lens coating: a violet and green flare, and a big specular sweep.
        radial([rgb(0x7C3AED, 0.28), rgb(0x7C3AED, 0)], center: CGPoint(x: c.x + 120, y: c.y - 140), radius: 120, in: ctx)
        radial([rgb(0x34D399, 0.16), rgb(0x34D399, 0)], center: CGPoint(x: c.x - 120, y: c.y + 150), radius: 90, in: ctx)
        ctx.addEllipse(in: CGRect(x: c.x - 250, y: c.y + 20, width: 420, height: 300))
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0)],
                 from: CGPoint(x: c.x - 120, y: c.y + 260), to: CGPoint(x: c.x, y: c.y + 40), in: ctx)
        ctx.restoreGState()

        // Glass rim highlight.
        ctx.addEllipse(in: glass.insetBy(dx: 2, dy: 2))
        ctx.setStrokeColor(rgb(0x67E8F9, 0.35).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()

        sparkle(ctx, at: CGPoint(x: c.x - 120, y: c.y + 150), size: 26, color: NSColor.white.withAlphaComponent(0.9))
    }
}
