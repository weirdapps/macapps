import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Streak", size: CGSize(width: 1040, height: 572)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
StreakApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct StreakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = StreakModel()

    var body: some Scene {
        Window("Streak", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Streak")
            StreakCommands(model: model)
        }
    }
}

struct StreakCommands: Commands {
    @ObservedObject var model: StreakModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Habit…") { model.editing = EditorState() }.keyboardShortcut("n")
        }
        CommandMenu("Habit") {
            let done = model.selected.map { $0.done.contains(model.today) } ?? false
            Button(done ? "Uncheck Today" : "Check Off Today") { model.toggleToday() }
                .keyboardShortcut("t")
                .disabled(model.selected == nil)
            Button("Go to Today") { model.selectedDay = model.today }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
            Divider()
            Button("Edit Habit…") { if let h = model.selected { model.editing = EditorState(h) } }
                .keyboardShortcut("e")
                .disabled(model.selected == nil)
            Button("Delete Habit…") { model.confirmingDelete = true }
                .keyboardShortcut(.delete)
                .disabled(model.selected == nil || model.editingNote)
        }
        CommandGroup(before: .sidebar) {
            Button("Past 12 Months") { model.range = .pastYear }.keyboardShortcut("0")
            Button("Previous Year") { model.shiftYear(-1) }.keyboardShortcut("[").disabled(!model.canGoBack)
            Button("Next Year") { model.shiftYear(1) }.keyboardShortcut("]").disabled(!model.canGoForward)
            Divider()
        }
    }
}

// MARK: - Icon

/// A flame built from small calendar squares: each square is a day, the core burns brighter.
func appIcon() -> NSBitmapImageRep {
    render(0xFFA41B, 0xF0541E) { ctx in
        func flame(scale s: CGFloat, dy: CGFloat) -> CGPath {
            let p = CGMutablePath()
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 512) * s, y: 150 + (y - 150) * s + dy) }
            p.move(to: pt(512, 150))
            p.addCurve(to: pt(286, 370), control1: pt(372, 150), control2: pt(286, 240))
            p.addCurve(to: pt(352, 600), control1: pt(286, 470), control2: pt(316, 550))
            p.addCurve(to: pt(420, 500), control1: pt(372, 560), control2: pt(396, 520))
            p.addCurve(to: pt(566, 910), control1: pt(430, 680), control2: pt(500, 800))
            p.addCurve(to: pt(742, 400), control1: pt(660, 780), control2: pt(742, 620))
            p.addCurve(to: pt(512, 150), control1: pt(742, 250), control2: pt(652, 150))
            p.closeSubpath()
            return p
        }
        let outer = flame(scale: 0.93, dy: 14)
        let warm = flame(scale: 0.7, dy: 30)
        let core = flame(scale: 0.44, dy: 44)

        // Warm glow behind the flame.
        radial([rgb(0xFFE7A3, 0.5), rgb(0xFFC04A, 0)], center: CGPoint(x: 512, y: 380), radius: 440, in: ctx)

        let pitch: CGFloat = 40, full: CGFloat = 33
        for row in 0..<20 {
            for col in 0..<15 {
                let cx = 512 + (CGFloat(col) - 7) * pitch, cy = 150 + pitch / 2 + CGFloat(row) * pitch
                // Coverage from a 4 by 4 sample grid: edge squares shrink, so the outline stays a flame.
                var inside = 0
                for i in 0..<4 {
                    for j in 0..<4 {
                        let p = CGPoint(x: cx - pitch / 2 + (CGFloat(i) + 0.5) * pitch / 4, y: cy - pitch / 2 + (CGFloat(j) + 0.5) * pitch / 4)
                        if outer.contains(p) { inside += 1 }
                    }
                }
                guard inside >= 6 else { continue }
                let coverage = CGFloat(inside) / 16
                let size = full * (0.5 + 0.5 * coverage)
                let rect = CGRect(x: cx - size / 2, y: cy - size / 2, width: size, height: size)
                let centre = CGPoint(x: cx, y: cy)
                let heat = core.contains(centre) ? 2 : warm.contains(centre) ? 1 : 0
                let r = size * 0.24

                ctx.saveGState()
                shadow(ctx, y: -4, blur: 9, alpha: 0.24)
                ctx.addPath(roundedRect(rect, r))
                ctx.setFillColor(rgb(0xFFFFFF).cgColor)
                ctx.fillPath()
                ctx.restoreGState()

                // A soft top light on each square, like a lit tile.
                ctx.saveGState()
                ctx.addPath(roundedRect(rect, r))
                ctx.clip()
                let tones = [[rgb(0xFFFFFF), rgb(0xFFE3CC)], [rgb(0xFFF8DA), rgb(0xFFDE85)], [rgb(0xFFEC8A), rgb(0xFFB521)]][heat]
                gradient(tones, from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
                ctx.restoreGState()
            }
        }
    }
}
