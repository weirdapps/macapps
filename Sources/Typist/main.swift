import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Typist", size: CGSize(width: 1000, height: 700)) { ContentView(model: .demo) }
TypistApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { TypistModel.flushSaves() }
}

struct TypistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = TypistModel()

    var body: some Scene {
        Window("Typist", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1000, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Typist")
            CommandGroup(replacing: .newItem) {
                Button("New Test") { model.newTest() }.keyboardShortcut("n")
                Button("Restart Test") { model.restart() }.keyboardShortcut("r")
                Divider()
                Button("Export History…") { model.exporting = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.history.isEmpty)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Clear History…") { model.confirmingClear = true }.disabled(model.history.isEmpty)
            }
            CommandMenu("Test") {
                ForEach(Array(TestMode.allCases.enumerated()), id: \.element) { i, mode in
                    Toggle(mode.title, isOn: Binding(get: { model.config.mode == mode }, set: { if $0 { model.config.mode = mode } }))
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Menu("Time Limit") {
                    Picker("Time Limit", selection: $model.config.seconds) {
                        ForEach(TestConfig.secondOptions, id: \.self) { Text("\($0) Seconds").tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Menu("Word Count") {
                    Picker("Word Count", selection: $model.config.wordCount) {
                        ForEach(TestConfig.wordOptions, id: \.self) { Text("\($0) Words").tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                Divider()
                Toggle("Punctuation", isOn: $model.config.punctuation)
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(model.config.mode == .quote)
                Toggle("Numbers", isOn: $model.config.numbers)
                    .keyboardShortcut("n", modifiers: [.command, .option])
                    .disabled(model.config.mode == .quote)
            }
        }
    }
}

// MARK: - Icon

/// A bold keycap racing forward: motion streaks behind it and a speed gauge arc above, on a flamingo tile.
func appIcon() -> NSBitmapImageRep {
    render(0xFF6FA5, 0xD63384) { ctx in
        let center = CGPoint(x: 512, y: 420)

        // Speed gauge over the key: a faint track, a bright sweep with a glowing tip, and ticks.
        let radius: CGFloat = 316
        let start = CGFloat.pi * 0.93, end = CGFloat.pi * 0.07
        let reach = start - (start - end) * 0.74
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(40)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
        shadow(ctx, y: -4, blur: 14, alpha: 0.2)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: reach, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
        let tip = CGPoint(x: center.x + cos(reach) * radius, y: center.y + sin(reach) * radius)
        radial([NSColor.white.withAlphaComponent(0.75), NSColor.white.withAlphaComponent(0)], center: tip, radius: 70, in: ctx)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(11)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        for i in 0...6 {
            let a = start - (start - end) * CGFloat(i) / 6
            let inner = radius - 62, outer = radius - 40
            ctx.move(to: CGPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Motion streaks trailing to the left of the key.
        for (y, x, length, alpha) in [(420.0, 214.0, 124.0, 0.9), (340.0, 166.0, 172.0, 0.72), (260.0, 222.0, 116.0, 0.55)] {
            ctx.addPath(roundedRect(CGRect(x: x, y: y - 15, width: length, height: 30), 15))
            ctx.setFillColor(NSColor.white.withAlphaComponent(alpha).cgColor)
            ctx.fillPath()
        }

        // The keycap: a deep skirt seen from the front, then the top face set back and lit from above.
        let skirt = CGRect(x: 372, y: 214, width: 316, height: 316)
        ctx.saveGState()
        shadow(ctx, y: -24, blur: 44, alpha: 0.42)
        ctx.addPath(roundedRect(skirt, 62))
        ctx.setFillColor(rgb(0xF2B9D2).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(skirt, 62))
        ctx.clip()
        gradient([rgb(0xFCE3EE), rgb(0xE48DB4)], from: CGPoint(x: 0, y: skirt.maxY), to: CGPoint(x: 0, y: skirt.minY), in: ctx)
        ctx.restoreGState()

        let face = CGRect(x: 402, y: 282, width: 256, height: 234)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 14, alpha: 0.2)
        ctx.addPath(roundedRect(face, 44))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(face, 44))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xFBE4EE)], from: CGPoint(x: 0, y: face.maxY), to: CGPoint(x: 0, y: face.minY), in: ctx)
        // A shallow dish: darker towards the rim, bright in the middle.
        radial([NSColor.white, NSColor.white.withAlphaComponent(0)], center: CGPoint(x: face.midX, y: face.midY + 18), radius: 120, in: ctx)
        ctx.restoreGState()
    }
}
