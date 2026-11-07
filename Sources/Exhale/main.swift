import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Exhale", size: CGSize(width: 1100, height: 680)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
ExhaleApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: it quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ExhaleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ExhaleModel()

    var body: some Scene {
        Window("Exhale", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 500)
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Exhale")
            CommandGroup(replacing: .newItem) {}
            ExhaleCommands(model: model)
        }
    }
}

struct ExhaleCommands: Commands {
    @ObservedObject var model: ExhaleModel

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.showHistory ? "Hide History" : "Show History") { withAnimation(.snappy) { model.showHistory.toggle() } }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Session") {
            Button(startTitle) { model.toggle() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Stop") { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.canEdit)
            Divider()
            Button("Longer Session") { model.nudgeMinutes(1) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!model.canEdit || model.settings.minutes >= Settings.minutesRange.upperBound)
            Button("Shorter Session") { model.nudgeMinutes(-1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canEdit || model.settings.minutes <= Settings.minutesRange.lowerBound)
            Divider()
            Picker("Sound", selection: $model.settings.sound) {
                ForEach(SoundStyle.allCases) { Text($0.name).tag($0) }
            }
            Divider()
            Button("Clear History…") { confirmClear() }
                .disabled(model.sessions.isEmpty)
        }
        CommandMenu("Pattern") {
            ForEach(PatternID.allCases) { id in
                Toggle(id.name, isOn: Binding(get: { model.settings.pattern == id }, set: { if $0 { model.settings.pattern = id } }))
                    .keyboardShortcut(KeyEquivalent(id.key), modifiers: .command)
                    .disabled(!model.canEdit)
            }
        }
    }

    private var startTitle: String {
        switch model.runState {
        case .idle: "Start Session"
        case .running: "Pause"
        case .paused: "Resume"
        case .finished: "Start Again"
        }
    }

    @MainActor private func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear all session history?"
        alert.informativeText = "Your weekly minutes start again from zero. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.clearHistory() }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0xB9A7FF, 0x6E5BC9) { ctx in
        let c = CGPoint(x: tile.midX, y: tile.midY + 6)

        // A soft halo the breath expands into.
        radial([NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0)], center: c, radius: 380, in: ctx)

        // Ripples, like the edge of a breath moving outward.
        for (i, r) in [330.0, 372.0].enumerated() {
            ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(i == 0 ? 0.22 : 0.11).cgColor)
            ctx.setLineWidth(i == 0 ? 7 : 5)
            ctx.strokePath()
        }

        // Six petals: overlapping translucent discs with a light top edge.
        let petal: CGFloat = 156, spread: CGFloat = 128
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 34, alpha: 0.22)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3 + .pi / 2
            let p = CGPoint(x: c.x + cos(a) * spread, y: c.y + sin(a) * spread)
            let rect = CGRect(x: p.x - petal, y: p.y - petal, width: petal * 2, height: petal * 2)
            ctx.saveGState()
            ctx.addEllipse(in: rect)
            ctx.clip()
            ctx.setAlpha(0.46)
            gradient([rgb(0xFFFFFF), rgb(0xE3DAFF), rgb(0xA595F2)], from: CGPoint(x: p.x - petal * 0.6, y: p.y + petal),
                     to: CGPoint(x: p.x + petal * 0.6, y: p.y - petal), in: ctx)
            ctx.restoreGState()
            ctx.addEllipse(in: rect.insetBy(dx: 2, dy: 2))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(3)
            ctx.strokePath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // The glowing core.
        radial([NSColor.white, NSColor.white.withAlphaComponent(0.85), NSColor.white.withAlphaComponent(0)],
               center: c, radius: 120, in: ctx)
        ctx.addEllipse(in: CGRect(x: c.x - 46, y: c.y - 46, width: 92, height: 92))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
    }
}
