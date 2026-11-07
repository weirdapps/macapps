import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Nine", size: CGSize(width: 900, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
NineApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window game: closing the window quits, like Chess. The game is saved on the way out.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct NineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = NineModel()

    var body: some Scene {
        Window("Nine", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 900, height: 640)
        .windowToolbarStyle(.unified)
        .commands { NineCommands(model: model) }
    }
}

struct NineCommands: Commands {
    @ObservedObject var model: NineModel

    var body: some Commands {
        AppHelpCommands(name: "Nine")
        CommandGroup(replacing: .newItem) {
            Button("New Game") { model.requestNewGame() }.keyboardShortcut("n")
            Menu("New Game With Difficulty") {
                ForEach(Array(Difficulty.allCases.enumerated()), id: \.element) { n, level in
                    Button(level.title) { model.requestNewGame(level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")), modifiers: [.command, .option])
                }
            }
            Divider()
            Button("Restart Game") { model.restart() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.isPlaying)
        }
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }.keyboardShortcut("z")
                .disabled(!(model.game?.canUndo ?? false) || !model.isPlaying)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model.game?.canRedo ?? false) || !model.isPlaying)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Clear Cell") { model.erase() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!model.isPlaying)
        }
        CommandGroup(before: .toolbar) {
            Toggle("Highlight Conflicts", isOn: $model.showConflicts)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("Game") {
            Button(model.paused ? "Resume" : "Pause") { model.togglePause() }
                .keyboardShortcut("p")
                .disabled(model.game?.completed ?? true)
            Divider()
            Button(model.notesMode ? "Stop Taking Notes" : "Take Notes") { model.toggleNotesMode() }
                .keyboardShortcut("n", modifiers: [])
            Button("Hint") { model.hint() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!model.isPlaying)
        }
    }
}

// MARK: - Icon

//: a 3x3 block of rounded tiles on seafoam, the centre tile lifted off the block and glowing

func appIcon() -> NSBitmapImageRep {
    render(0x48D1B5, 0x1B7F8C) { ctx in
        let size: CGFloat = 168, gap: CGFloat = 26
        let span = size * 3 + gap * 2
        let origin = CGPoint(x: tile.midX - span / 2, y: tile.midY - span / 2 - 6)
        func rect(_ r: Int, _ c: Int) -> CGRect {
            CGRect(x: origin.x + CGFloat(c) * (size + gap), y: origin.y + CGFloat(2 - r) * (size + gap), width: size, height: size)
        }

        // A recessed plate under the block.
        let plate = CGRect(x: origin.x - 34, y: origin.y - 34, width: span + 68, height: span + 68)
        ctx.addPath(roundedRect(plate, 70))
        ctx.setFillColor(rgb(0x0E4F5A, 0.22).cgColor)
        ctx.fillPath()

        // Eight resting tiles: soft frosted white with a top highlight.
        for r in 0..<3 {
            for c in 0..<3 where !(r == 1 && c == 1) {
                let t = rect(r, c)
                ctx.saveGState()
                shadow(ctx, y: -6, blur: 14, alpha: 0.22)
                ctx.addPath(roundedRect(t, 38))
                ctx.setFillColor(rgb(0xE6FBF6, 0.78).cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(roundedRect(t, 38))
                ctx.clip()
                gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)], from: CGPoint(x: 0, y: t.maxY), to: CGPoint(x: 0, y: t.midY), in: ctx)
                ctx.restoreGState()
            }
        }

        // The lifted tile: its shadow stays in the empty slot, the tile floats up and glows.
        let slot = rect(1, 1)
        ctx.addPath(roundedRect(slot.insetBy(dx: 6, dy: 6), 34))
        ctx.setFillColor(rgb(0x0B3F48, 0.30).cgColor)
        ctx.fillPath()

        let lifted = slot.insetBy(dx: -20, dy: -20).offsetBy(dx: 0, dy: 34)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xC8FFF1, 0.95).cgColor)
        ctx.addPath(roundedRect(lifted, 46))
        ctx.setFillColor(rgb(0xFFFFFF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        shadow(ctx, y: -30, blur: 40, alpha: 0.35)
        ctx.addPath(roundedRect(lifted, 46))
        ctx.setFillColor(rgb(0xFFFFFF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(lifted, 46))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xD5F7EF)], from: CGPoint(x: 0, y: lifted.maxY), to: CGPoint(x: 0, y: lifted.minY), in: ctx)
        radial([rgb(0x7FE8D2, 0.55), rgb(0x7FE8D2, 0)], center: CGPoint(x: lifted.midX, y: lifted.midY), radius: lifted.width * 0.42, in: ctx)
        ctx.restoreGState()
        sparkle(ctx, at: CGPoint(x: lifted.maxX - 6, y: lifted.maxY - 4), size: 34, color: rgb(0xFFFFFF, 0.95))
    }
}
