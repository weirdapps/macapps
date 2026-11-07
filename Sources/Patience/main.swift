import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Patience", size: CGSize(width: 1000, height: 700)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
PatienceApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // One table, like Chess: closing the window quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct PatienceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = GameModel()

    var body: some Scene {
        Window("Patience", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1000, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Patience")
            GameCommands(model: model)
        }
        Settings { SettingsView(model: model) }
    }
}

struct GameCommands: Commands {
    @ObservedObject var model: GameModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Game") { withAnimation(.snappy) { model.newGame() } }.keyboardShortcut("n")
            Button("Restart Game") { withAnimation(.snappy) { model.restart() } }.keyboardShortcut("r")
            Button("Choose Game…") { model.showChooser = true }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Move") { withAnimation(.snappy) { model.undo() } }.keyboardShortcut("z").disabled(!model.canUndo || model.showChooser || model.showStats)
        }
        CommandMenu("Game") {
            Button("Deal from Stock") { withAnimation(.snappy(duration: 0.3)) { model.dealFromStock() } }
                .keyboardShortcut("d").disabled(model.won)
            Button("Show Hint") { withAnimation(.snappy) { model.showHint() } }
                .keyboardShortcut("h", modifiers: [.command, .shift]).disabled(model.won)
            Button("Auto Complete") { model.autoComplete() }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!model.canAutoComplete)
            Divider()
            Picker("Stock", selection: $model.drawMode) {
                Text("Draw One").tag(DrawMode.one).keyboardShortcut("1")
                Text("Draw Three").tag(DrawMode.three).keyboardShortcut("3")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Statistics…") { model.showStats = true }.keyboardShortcut("i")
        }
        CommandGroup(after: .toolbar) {
            Picker("Table Colour", selection: $model.felt) {
                ForEach(Array(Felt.allCases.enumerated()), id: \.element) { i, felt in
                    Text(felt.title).tag(felt).keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
                }
            }
            Divider()
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x2F9E5E, 0x145A35) { ctx in
        // A soft spotlight on the felt.
        radial([rgb(0x5BC489, 0.55), rgb(0x2F9E5E, 0)], center: CGPoint(x: 512, y: 600), radius: 430, in: ctx)
        let pivot = CGPoint(x: 512, y: 150)
        let cards: [(Suit, CGFloat)] = [(.spades, 24), (.clubs, -24), (.hearts, 0)]
        for (suit, degrees) in cards { drawIconCard(ctx, suit: suit, pivot: pivot, angle: degrees * .pi / 180, hero: degrees == 0) }
    }
}

private func drawIconCard(_ ctx: CGContext, suit: Suit, pivot: CGPoint, angle: CGFloat, hero: Bool) {
    let w: CGFloat = 316, h: CGFloat = 442
    let ink = suit.isRed ? rgb(0xC6283B) : rgb(0x1D2229)
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: angle)
    ctx.translateBy(x: 0, y: 380)
    let card = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    let shape = roundedRect(card, 30)

    ctx.saveGState()
    shadow(ctx, y: -14, blur: 30, alpha: 0.38)
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xFFFFFF).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    gradient([rgb(0xFFFFFF), rgb(0xEEE9DE)], from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY), in: ctx)
    ctx.restoreGState()
    ctx.addPath(roundedRect(card.insetBy(dx: 1.5, dy: 1.5), 28.5))
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(3)
    ctx.strokePath()

    ctx.setFillColor(ink.cgColor)
    if hero {
        ctx.addPath(SuitPath.cgPath(suit, in: CGRect(x: card.minX + 34, y: card.maxY - 34 - 72, width: 72, height: 72), flipped: true))
        ctx.addPath(SuitPath.cgPath(suit, in: CGRect(x: -95, y: -110, width: 190, height: 190), flipped: true))
    } else {
        // A corner pip on the outer side, where it shows past the card on top.
        let x = angle > 0 ? card.minX + 34 : card.maxX - 34 - 76
        ctx.addPath(SuitPath.cgPath(suit, in: CGRect(x: x, y: card.maxY - 34 - 76, width: 76, height: 76), flipped: true))
    }
    ctx.fillPath()
    ctx.restoreGState()
}
