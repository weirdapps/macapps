import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Hours", size: CGSize(width: 1040, height: 700)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
HoursApp.main()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility, like Calculator. A running timer is saved with its start time, so it keeps counting after quit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { HoursModel.shared.dockMenu() }
}

struct HoursApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = HoursModel.shared

    var body: some Scene {
        Window("Hours", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 700)
        .windowToolbarStyle(.unified)
        .commands { HoursCommands(model: model) }
        Settings { SettingsView(model: model) }
    }
}

struct HoursCommands: Commands {
    @ObservedObject var model: HoursModel

    var body: some Commands {
        AppHelpCommands(name: "Hours")
        CommandGroup(replacing: .newItem) {
            Button("New Entry…") { model.newEntry() }
                .keyboardShortcut("n")
            Button("New Project…") { model.sheet = .project(model.newProjectDraft(), isNew: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Timesheet…") { model.exportCSV() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Timer") {
            Button("Start Timer") { model.toggleTimer() }
                .keyboardShortcut("t")
                .disabled(model.running != nil || model.projects.isEmpty)
            Button("Stop Timer") { model.stop() }
                .keyboardShortcut(".")
                .disabled(model.running == nil)
            Divider()
            Menu("Start Timer For") {
                ForEach(model.projects) { p in
                    Button(p.name) { model.start(p.id) }
                }
            }
            .disabled(model.projects.isEmpty)
        }
        CommandGroup(before: .toolbar) {
            Button("Week") { model.mode = .week }.keyboardShortcut("1")
            Button("Totals") { model.mode = .totals }.keyboardShortcut("2")
            Divider()
            Button("Previous Week") { model.mode = .week; model.moveWeek(-1) }.keyboardShortcut("[")
            Button("Next Week") { model.mode = .week; model.moveWeek(1) }.keyboardShortcut("]")
            Button("This Week") { model.goToToday() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
        }
    }
}

// MARK: - Icon

//: a stopwatch whose dial is split into coloured project wedges

func appIcon() -> NSBitmapImageRep {
    render(0x22B8CF, 0x1A6FA3) { ctx in
        let c = CGPoint(x: 512, y: 482), r: CGFloat = 268

        // Crown: a stem and a rounded button on top, plus a small side pusher.
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 22, alpha: 0.28)
        ctx.setFillColor(rgb(0xEAF6FA).cgColor)
        ctx.addPath(roundedRect(CGRect(x: c.x - 34, y: c.y + r - 10, width: 68, height: 70), 12))
        ctx.addPath(roundedRect(CGRect(x: c.x - 82, y: c.y + r + 46, width: 164, height: 60), 30))
        ctx.fillPath()
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -.pi / 4)
        ctx.addPath(roundedRect(CGRect(x: -30, y: r - 8, width: 60, height: 62), 16))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.restoreGState()

        // Case: a white ring with depth.
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 36, alpha: 0.35)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - r - 34, y: c.y - r - 34, width: (r + 34) * 2, height: (r + 34) * 2))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r - 34, y: c.y - r - 34, width: (r + 34) * 2, height: (r + 34) * 2))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xD5E9F1)], from: CGPoint(x: 0, y: c.y + r), to: CGPoint(x: 0, y: c.y - r), in: ctx)
        ctx.restoreGState()

        // Dial: deep navy face.
        let face = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        gradient([rgb(0x173A55), rgb(0x0C2236)], from: CGPoint(x: 0, y: face.maxY), to: CGPoint(x: 0, y: face.minY), in: ctx)
        ctx.restoreGState()

        // Project wedges, clockwise from twelve, leaving the last slice of the hour untracked.
        let wedges: [(UInt32, UInt32, CGFloat)] = [
            (0x3FE0D0, 0x22B8CF, 0.30), (0xFFB25C, 0xF2884A, 0.22), (0xFF7AA8, 0xE5507F, 0.17), (0x9C8CFF, 0x6B5CF0, 0.13),
        ]
        var angle = CGFloat.pi / 2
        let wr = r - 22
        for (light, dark, share) in wedges {
            let sweep = share * 2 * .pi
            ctx.saveGState()
            ctx.move(to: c)
            ctx.addArc(center: c, radius: wr, startAngle: angle, endAngle: angle - sweep, clockwise: true)
            ctx.closePath()
            ctx.clip()
            gradient([rgb(light), rgb(dark)], from: CGPoint(x: c.x, y: c.y + wr), to: CGPoint(x: c.x, y: c.y - wr), in: ctx)
            ctx.restoreGState()
            angle -= sweep
        }
        // Thin gaps between wedges, in the face colour.
        ctx.setStrokeColor(rgb(0x10293F).cgColor)
        ctx.setLineWidth(12)
        ctx.setLineCap(.round)
        var a = CGFloat.pi / 2
        for (_, _, share) in wedges + [(0, 0, 0)] {
            ctx.move(to: c)
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * (wr + 4), y: c.y + sin(a) * (wr + 4)))
            a -= share * 2 * .pi
        }
        ctx.strokePath()

        // Minute ticks around the rim.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        for i in 0..<12 {
            let t = CGFloat(i) / 12 * 2 * .pi
            ctx.setLineWidth(i % 3 == 0 ? 10 : 6)
            let inner = r - (i % 3 == 0 ? 2 : -2) - 16
            ctx.move(to: CGPoint(x: c.x + cos(t) * (inner - 14), y: c.y + sin(t) * (inner - 14)))
            ctx.addLine(to: CGPoint(x: c.x + cos(t) * (r - 6), y: c.y + sin(t) * (r - 6)))
            ctx.strokePath()
        }

        // Hand at the end of the last wedge, with a hub.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 14, alpha: 0.4)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(22)
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + cos(angle) * (r - 46), y: c.y + sin(angle) * (r - 46)))
        ctx.strokePath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x1A6FA3).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32))

        // Glass highlight across the top of the face.
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        ctx.addEllipse(in: CGRect(x: c.x - r * 1.1, y: c.y + r * 0.05, width: r * 2.2, height: r * 1.6))
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)],
                 from: CGPoint(x: 0, y: c.y + r), to: CGPoint(x: 0, y: c.y), in: ctx)
        ctx.restoreGState()
    }
}
