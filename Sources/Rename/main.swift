import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Rename", size: CGSize(width: 1080, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
RenameApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RenameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RenameModel()

    var body: some Scene {
        Window("Rename", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Rename")
            RenameCommands(model: model)
        }
    }
}

struct RenameCommands: Commands {
    @ObservedObject var model: RenameModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files\u{2026}") { NotificationCenter.default.post(name: .renameOpen, object: nil) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button(model.renameCount > 0 ? "Rename \(model.renameCount) \(model.renameCount == 1 ? "File" : "Files")" : "Rename Files") {
                model.apply()
            }
            .keyboardShortcut("r")
            .disabled(model.renameCount == 0)
            Button("Undo Last Rename") { model.undoLastBatch() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(model.lastBatch.isEmpty)
            Divider()
            Button("Reveal in Finder") { model.revealSelected() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.items.isEmpty)
            Button("Remove from List") { model.removeSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selection.isEmpty)
            Button("Clear List") { model.clear() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(model.items.isEmpty)
        }
        CommandMenu("List") {
            ForEach(Array(SortKey.allCases.enumerated()), id: \.element) { i, key in
                Button("Sort by \(key.title)") { model.sort(by: key) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
            }
            Button("Reverse Order") { model.reverse() }
            Divider()
            Button("Move Up") { model.moveSelection(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!model.canMoveUp)
            Button("Move Down") { model.moveSelection(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!model.canMoveDown)
        }
        CommandMenu("Rules") {
            ForEach(Array(RuleKind.allCases.enumerated()), id: \.element) { i, kind in
                Button("Add \(kind.title)") { model.addRule(kind) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button("Reset Rules") { model.resetRules() }
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x56CCF2, 0x2F80ED) { ctx in
        let c = CGPoint(x: tile.midX, y: tile.midY)

        // Two arrows chasing each other around the tag.
        let radius: CGFloat = 300
        func arrow(from a: CGFloat, to b: CGFloat) {
            let start = a * .pi / 180, end = b * .pi / 180
            ctx.saveGState()
            shadow(ctx, y: -6, blur: 14, alpha: 0.18)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.setStrokeColor(rgb(0xF4F9FF).cgColor)
            ctx.setLineWidth(46)
            ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: end - 0.16, clockwise: false)
            ctx.strokePath()
            let p = CGPoint(x: c.x + radius * cos(end - 0.2), y: c.y + radius * sin(end - 0.2))
            let t = CGPoint(x: -sin(end), y: cos(end)) // Tangent, counter clockwise.
            let n = CGPoint(x: cos(end), y: sin(end))
            ctx.move(to: CGPoint(x: p.x + t.x * 104, y: p.y + t.y * 104))
            ctx.addLine(to: CGPoint(x: p.x + n.x * 72, y: p.y + n.y * 72))
            ctx.addLine(to: CGPoint(x: p.x - n.x * 72, y: p.y - n.y * 72))
            ctx.closePath()
            ctx.setFillColor(rgb(0xF4F9FF).cgColor)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(10)
            ctx.drawPath(using: .fillStroke)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        arrow(from: 28, to: 162)
        arrow(from: 208, to: 342)

        // The name tag, tilted, with a hole by its point.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: 10 * .pi / 180)
        let w: CGFloat = 520, h: CGFloat = 250, point: CGFloat = 110, r: CGFloat = 34
        let left = -w / 2, right = w / 2, top = h / 2, bottom = -h / 2
        let tag = CGMutablePath()
        tag.move(to: CGPoint(x: left + 6, y: 0))
        tag.addLine(to: CGPoint(x: left + point, y: top))
        tag.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: bottom), radius: r)
        tag.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left + point, y: bottom), radius: r)
        tag.addLine(to: CGPoint(x: left + point, y: bottom))
        tag.closeSubpath()

        ctx.saveGState()
        shadow(ctx, y: -18, blur: 34, alpha: 0.35)
        ctx.addPath(tag)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(28)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(tag)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE4EEFB)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bottom), in: ctx)
        ctx.restoreGState()

        // Eyelet.
        let hole = CGRect(x: left + 52, y: -24, width: 48, height: 48)
        ctx.setFillColor(rgb(0x3E9BEF).cgColor)
        ctx.fillEllipse(in: hole)
        ctx.setFillColor(rgb(0x2A6FCF, 0.5).cgColor)
        ctx.fillEllipse(in: hole.insetBy(dx: 10, dy: 10).offsetBy(dx: 0, dy: 3))

        // A name being typed: two words and a blinking cursor.
        ctx.setFillColor(rgb(0x1E3A66, 0.85).cgColor)
        ctx.addPath(roundedRect(CGRect(x: left + 150, y: -22, width: 112, height: 44), 22))
        ctx.fillPath()
        ctx.setFillColor(rgb(0x1E3A66, 0.45).cgColor)
        ctx.addPath(roundedRect(CGRect(x: left + 280, y: -22, width: 78, height: 44), 22))
        ctx.fillPath()

        let cx = left + 392
        ctx.setFillColor(rgb(0x2F80ED).cgColor)
        ctx.addPath(roundedRect(CGRect(x: cx - 9, y: -70, width: 18, height: 140), 9))
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: cx - 34, y: 58, width: 68, height: 18), 9))
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: cx - 34, y: -76, width: 68, height: 18), 9))
        ctx.fillPath()
        ctx.restoreGState()
    }
}
