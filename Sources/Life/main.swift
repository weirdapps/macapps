import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Life", size: CGSize(width: 1060, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo()) } }
LifeApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: it quits when its window closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// RLE files opened from Finder load onto the board.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { LifeModel.shared.open(url) }
    }
}

struct LifeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = LifeModel.shared

    var body: some Scene {
        Window("Life", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1060, height: 640)
        .windowToolbarStyle(.unified)
        .commands { LifeCommands(model: model) }
    }
}

struct LifeCommands: Commands {
    @Bindable var model: LifeModel

    var body: some Commands {
        AppHelpCommands(name: "Life")
        CommandGroup(replacing: .newItem) {
            Button("Open Pattern\u{2026}") { model.openPanel() }.keyboardShortcut("o")
            Button("Export Pattern\u{2026}") { model.exportPanel() }.keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy as RLE") { model.copyRLE() }.keyboardShortcut("c")
            Button("Paste Pattern") { model.pasteRLE() }.keyboardShortcut("v")
            Divider()
            Button("Rotate Pattern") { model.rotatePlacing() }.keyboardShortcut("r", modifiers: []).disabled(model.placing == nil)
            Button("Stop Placing") { model.cancelPlacing() }.keyboardShortcut(.escape, modifiers: []).disabled(model.placing == nil)
        }
        CommandMenu("Simulation") {
            Button(model.isRunning ? "Pause" : "Play") { model.toggleRunning() }.keyboardShortcut(.space, modifiers: [])
            Button("Step") { model.step() }.keyboardShortcut(.rightArrow, modifiers: []).disabled(model.isRunning)
            Divider()
            Button("Faster") { model.faster() }.keyboardShortcut("]").disabled(model.speed >= 60)
            Button("Slower") { model.slower() }.keyboardShortcut("[").disabled(model.speed <= 1)
            Divider()
            Button("Random Fill") { model.randomize() }.keyboardShortcut("r")
            Picker("Random Fill Density", selection: $model.density) {
                ForEach(LifeModel.densities, id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
            }
            Button("Clear") { model.clear() }.keyboardShortcut(.delete)
            Divider()
            Picker("Rule", selection: $model.rule) {
                ForEach(Rule.presets, id: \.rule) { Text("\($0.name)  \($0.rule.notation)").tag($0.rule) }
            }
        }
        CommandGroup(before: .toolbar) {
            Picker("Board Size", selection: Binding(get: { model.size }, set: { model.resize(to: $0) })) {
                ForEach(GridSize.all) { Text($0.label).tag($0) }
            }
            Toggle("Wrap Around Edges", isOn: $model.wrap).keyboardShortcut("e", modifiers: [.command, .option])
            Toggle("Show Grid Lines", isOn: $model.showGrid).keyboardShortcut("g", modifiers: [.command, .option])
            Divider()
        }
    }
}

// MARK: - Icon

//: a glider of glowing mint cells crossing a dark green grid, its last positions fading behind it

func appIcon() -> NSBitmapImageRep {
    render(0x0E3B2E, 0x041611) { ctx in
        let n = 7
        let cell: CGFloat = 104
        let origin = CGPoint(x: tile.midX - cell * CGFloat(n) / 2, y: tile.midY - cell * CGFloat(n) / 2)
        // Grid coordinates have y going down, like the board.
        func rect(_ x: Int, _ y: Int, inset: CGFloat = 9) -> CGRect {
            CGRect(x: origin.x + CGFloat(x) * cell, y: origin.y + CGFloat(n - 1 - y) * cell, width: cell, height: cell).insetBy(dx: inset, dy: inset)
        }

        // Faint grid of empty cells.
        for y in 0..<n {
            for x in 0..<n {
                ctx.addPath(roundedRect(rect(x, y), 16))
                ctx.setFillColor(rgb(0x6EF7BE, 0.055).cgColor)
                ctx.fillPath()
            }
        }

        // Trails: where the glider was, dimmer the older.
        let trail: [(Int, Int, CGFloat)] = [(1, 0, 0.14), (2, 1, 0.2), (0, 2, 0.12), (1, 2, 0.17), (2, 2, 0.24)]
        for (x, y, a) in trail {
            ctx.addPath(roundedRect(rect(x, y), 16))
            ctx.setFillColor(rgb(0x2BC08C, a).cgColor)
            ctx.fillPath()
        }

        // The glider, in its classic phase, moving down and to the right.
        let glider = [(3, 2), (4, 3), (2, 4), (3, 4), (4, 4)]
        let glowCenter = CGPoint(x: rect(3, 3).midX, y: rect(3, 3).midY)
        radial([rgb(0x6EF7BE, 0.42), rgb(0x6EF7BE, 0)], center: glowCenter, radius: 360, in: ctx)
        for (x, y) in glider {
            let r = rect(x, y, inset: 7)
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 46, color: rgb(0x7DFFC8, 0.95).cgColor)
            ctx.addPath(roundedRect(r, 20))
            ctx.setFillColor(rgb(0x5EF0B4).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(r, 20))
            ctx.clip()
            gradient([rgb(0xE9FFF6), rgb(0x8BFFD0), rgb(0x34D49A)], from: CGPoint(x: r.minX, y: r.maxY), to: CGPoint(x: r.maxX, y: r.minY), in: ctx)
            // Glassy highlight along the top edge.
            ctx.addPath(roundedRect(CGRect(x: r.minX + 10, y: r.maxY - 30, width: r.width - 20, height: 20), 10))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.45).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
