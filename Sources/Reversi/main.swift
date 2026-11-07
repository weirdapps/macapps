import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Reversi", size: CGSize(width: 940, height: 660)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
ReversiApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // One board, one window: closing it ends the game, like Chess.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ReversiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = GameModel()

    var body: some Scene {
        Window("Reversi", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 940, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Reversi")
            CommandGroup(replacing: .newItem) {
                Button("New Game") { model.newGame() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
            }
            CommandMenu("Game") {
                ForEach(Array(Opponent.allCases.enumerated()), id: \.element) { i, o in
                    Toggle(o.title, isOn: Binding(
                        get: { model.opponent == o }, set: { if $0 { model.opponent = o } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Toggle("Play as Black", isOn: Binding(get: { model.humanSide == .black }, set: { if $0 { model.humanSide = .black } }))
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(model.opponent == .human)
                Toggle("Play as White", isOn: Binding(get: { model.humanSide == .white }, set: { if $0 { model.humanSide = .white } }))
                    .keyboardShortcut("w", modifiers: [.command, .option])
                    .disabled(model.opponent == .human)
                Divider()
                Toggle("Show Legal Moves", isOn: $model.showHints)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x1F9D72, 0x0B4D3A) { ctx in
        let cx = tile.midX
        // The board: a felt square in perspective-free top view with a grid, tilted slightly for life.
        ctx.saveGState()
        ctx.translateBy(x: cx, y: tile.midY - 40)
        ctx.rotate(by: -0.08)
        let board = CGRect(x: -300, y: -300, width: 600, height: 600)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.45)
        ctx.addPath(roundedRect(board.insetBy(dx: -26, dy: -26), 54))
        ctx.setFillColor(rgb(0x0A2A1F).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(board, 26))
        ctx.clip()
        gradient([rgb(0x2BB585), rgb(0x12704F)], from: CGPoint(x: 0, y: 300), to: CGPoint(x: 0, y: -300), in: ctx)
        radial([NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: -120, y: 160), radius: 420, in: ctx)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.setLineWidth(7)
        for i in 1..<4 {
            let v = -300 + CGFloat(i) * 150
            ctx.move(to: CGPoint(x: v, y: -300)); ctx.addLine(to: CGPoint(x: v, y: 300))
            ctx.move(to: CGPoint(x: -300, y: v)); ctx.addLine(to: CGPoint(x: 300, y: v))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Discs resting on the board, and the soft shadow of the one in the air.
        iconDisc(ctx, at: CGPoint(x: -75, y: -75), r: 62, white: false)
        iconDisc(ctx, at: CGPoint(x: 75, y: -75), r: 62, white: true)
        iconDisc(ctx, at: CGPoint(x: -75, y: 75), r: 62, white: true)
        iconDisc(ctx, at: CGPoint(x: -225, y: -225), r: 62, white: false)
        ctx.saveGState()
        ctx.translateBy(x: 160, y: 120)
        ctx.scaleBy(x: 1, y: 0.45)
        radial([NSColor.black.withAlphaComponent(0.34), NSColor.black.withAlphaComponent(0)], center: .zero, radius: 120, in: ctx)
        ctx.restoreGState()
        ctx.restoreGState()

        // One disc flipping mid-air: tilted, so its two-tone edge shows, white face up turning to black.
        let air = CGPoint(x: cx + 150, y: tile.midY + 230)
        func tilted(_ body: () -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: air.x, y: air.y)
            ctx.rotate(by: 0.5)
            ctx.scaleBy(x: 1, y: 0.5)
            body()
            ctx.restoreGState()
        }
        let r: CGFloat = 124
        tilted {
            shadow(ctx, y: -24, blur: 30, alpha: 0.45)
            ctx.addEllipse(in: CGRect(x: -r, y: -r - 74, width: r * 2, height: r * 2))
            ctx.setFillColor(rgb(0x050505).cgColor)
            ctx.fillPath()
        }
        tilted {
            // The black lower layer of the edge, then the white upper layer.
            for i in stride(from: 74, through: 0, by: -2) {
                ctx.addEllipse(in: CGRect(x: -r, y: -r - CGFloat(i), width: r * 2, height: r * 2))
                ctx.setFillColor((i > 28 ? rgb(0x111111) : rgb(0xB9B9AF)).cgColor)
                ctx.fillPath()
            }
            ctx.addEllipse(in: CGRect(x: -r, y: -r - 31, width: r * 2, height: r * 2))
            ctx.addEllipse(in: CGRect(x: -r, y: -r - 28, width: r * 2, height: r * 2))
            ctx.setFillColor(rgb(0x3A3A3A).cgColor)
            ctx.fillPath(using: .evenOdd)
        }
        tilted {
            ctx.addEllipse(in: CGRect(x: -r, y: -r, width: r * 2, height: r * 2))
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xE6E6DE), rgb(0xC9C9C0)], from: CGPoint(x: -60, y: r), to: CGPoint(x: 60, y: -r), in: ctx)
            ctx.addEllipse(in: CGRect(x: -r * 0.7, y: r * 0.05, width: r * 1.1, height: r * 0.62))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            ctx.fillPath()
        }

        sparkle(ctx, at: CGPoint(x: air.x - 170, y: air.y + 40), size: 30, color: NSColor.white.withAlphaComponent(0.9))
        sparkle(ctx, at: CGPoint(x: air.x + 95, y: air.y - 120), size: 18, color: NSColor.white.withAlphaComponent(0.7))
    }
}

/// A glossy disc seen from above, with a dark rim for thickness and a soft specular highlight.
func iconDisc(_ ctx: CGContext, at p: CGPoint, r: CGFloat, white: Bool) {
    ctx.saveGState()
    shadow(ctx, y: -10, blur: 14, alpha: 0.5)
    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r - 8, width: r * 2, height: r * 2))
    ctx.setFillColor((white ? rgb(0x9C9C92) : rgb(0x000000)).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.clip()
    radial(white ? [rgb(0xFFFFFF), rgb(0xEDEDE6), rgb(0xBDBDB3)] : [rgb(0x606060), rgb(0x1C1C1C), rgb(0x040404)],
           center: CGPoint(x: p.x - r * 0.3, y: p.y + r * 0.35), radius: r * 1.5, in: ctx)
    ctx.addEllipse(in: CGRect(x: p.x - r * 0.55, y: p.y + r * 0.15, width: r * 1.0, height: r * 0.6))
    ctx.setFillColor(NSColor.white.withAlphaComponent(white ? 0.7 : 0.3).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
}
