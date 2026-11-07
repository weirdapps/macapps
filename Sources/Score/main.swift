import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Score", size: CGSize(width: 1000, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
ScoreApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ScoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ScoreModel.load()

    var body: some Scene {
        Window("Score", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1000, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Score")
            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Game\u{2026}") { model.newGame() }.keyboardShortcut("n")
                Button("Rematch") { model.rematch() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.current == nil)
            }
            CommandMenu("Game") {
                Button("New Round") { model.addRound() }
                    .keyboardShortcut("r")
                    .disabled(model.current == nil)
                Button("Delete Last Round") { model.removeLastRound() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled((model.current?.rounds.isEmpty ?? true))
                Button("Add Player") { model.addPlayer() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.canAddPlayer)
                Divider()
                Button(model.current?.isOver == true ? "Resume Game" : "End Game") { model.toggleEnded() }
                    .keyboardShortcut("e")
                    .disabled(model.current == nil)
                Divider()
                Button("Delete Game") { if let id = model.selection { model.delete([id]) } }
                    .disabled(model.current == nil)
            }
            CommandGroup(before: .sidebar) {
                Button("Score Table") { model.showTotals = false }.keyboardShortcut("1")
                Button("Big Totals") { model.showTotals = true }.keyboardShortcut("2")
                Divider()
            }
        }
    }
}

// MARK: - Icon

//: a three step podium of score cards with tally marks, a gold crown over the winner

func appIcon() -> NSBitmapImageRep {
    render(0x3F6CF5, 0x1D2F9E) { ctx in
        // Soft glow behind the winner.
        radial([rgb(0x8FB0FF, 0.45), rgb(0x8FB0FF, 0)], center: CGPoint(x: 512, y: 620), radius: 380, in: ctx)

        let base: CGFloat = 214
        // The floor the podium stands on.
        ctx.saveGState()
        ctx.translateBy(x: 512, y: base)
        ctx.scaleBy(x: 1, y: 0.1)
        radial([rgb(0x0A1458, 0.55), rgb(0x0A1458, 0)], center: .zero, radius: 420, in: ctx)
        ctx.restoreGState()
        let steps: [(rect: CGRect, marks: Int)] = [
            (CGRect(x: 178, y: base, width: 214, height: 300), 3),
            (CGRect(x: 405, y: base, width: 214, height: 420), 5),
            (CGRect(x: 632, y: base, width: 214, height: 220), 2),
        ]
        for step in steps {
            let r = step.rect
            let path = CGMutablePath()
            let radius: CGFloat = 34
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + radius, y: r.maxY), radius: radius)
            path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY - radius), radius: radius)
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.closeSubpath()

            ctx.saveGState()
            shadow(ctx, y: -16, blur: 30, alpha: 0.35)
            ctx.addPath(path)
            ctx.setFillColor(rgb(0xF7F9FF).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xD3DDFB)], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY), in: ctx)
            // A lit top edge.
            ctx.setFillColor(rgb(0xFFFFFF, 0.9).cgColor)
            ctx.fill(CGRect(x: r.minX, y: r.maxY - 10, width: r.width, height: 10))
            ctx.restoreGState()

            // Tally marks, the fifth struck across in gold.
            let markTop = min(r.maxY - 70, r.minY + 250), markBottom = r.minY + 60
            let verticals = min(step.marks, 4)
            let spacing: CGFloat = 36
            let startX = r.midX - CGFloat(verticals - 1) * spacing / 2
            ctx.setLineCap(.round)
            ctx.setLineWidth(20)
            ctx.setStrokeColor(rgb(0x2C46C9).cgColor)
            for i in 0..<verticals {
                let x = startX + CGFloat(i) * spacing
                ctx.move(to: CGPoint(x: x, y: markBottom))
                ctx.addLine(to: CGPoint(x: x, y: markTop))
            }
            ctx.strokePath()
            if step.marks == 5 {
                ctx.saveGState()
                shadow(ctx, y: -4, blur: 8, alpha: 0.2)
                ctx.setLineWidth(22)
                ctx.setStrokeColor(rgb(0xE3A21F).cgColor)
                ctx.move(to: CGPoint(x: startX - 40, y: markBottom + 30))
                ctx.addLine(to: CGPoint(x: startX + 3 * spacing + 40, y: markTop - 30))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        // The crown over the tallest step.
        let cx: CGFloat = 512, cb: CGFloat = 676, w: CGFloat = 230, h: CGFloat = 150
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: cx - w / 2 + 14, y: cb))
        crown.addLine(to: CGPoint(x: cx - w / 2, y: cb + h))
        crown.addLine(to: CGPoint(x: cx - w / 4, y: cb + h * 0.52))
        crown.addLine(to: CGPoint(x: cx, y: cb + h * 1.08))
        crown.addLine(to: CGPoint(x: cx + w / 4, y: cb + h * 0.52))
        crown.addLine(to: CGPoint(x: cx + w / 2, y: cb + h))
        crown.addLine(to: CGPoint(x: cx + w / 2 - 14, y: cb))
        crown.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 20, alpha: 0.35)
        ctx.addPath(crown)
        ctx.setFillColor(rgb(0xF2BE36).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(crown)
        ctx.clip()
        gradient([rgb(0xFFE27A), rgb(0xE09A1C)], from: CGPoint(x: 0, y: cb + h), to: CGPoint(x: 0, y: cb), in: ctx)
        ctx.setFillColor(rgb(0xC9850F, 0.55).cgColor)
        ctx.fill(CGRect(x: cx - w / 2, y: cb, width: w, height: 22))
        ctx.restoreGState()
        // Jewels on the points.
        for (x, y) in [(cx - w / 2, cb + h), (cx, cb + h * 1.08), (cx + w / 2, cb + h)] {
            let jewel = CGRect(x: x - 17, y: y - 17, width: 34, height: 34)
            ctx.saveGState()
            shadow(ctx, y: -3, blur: 6, alpha: 0.25)
            ctx.setFillColor(rgb(0xFFE895).cgColor)
            ctx.fillEllipse(in: jewel)
            ctx.restoreGState()
        }
        sparkle(ctx, at: CGPoint(x: 700, y: 820), size: 30, color: rgb(0xFFFFFF, 0.85))
    }
}
