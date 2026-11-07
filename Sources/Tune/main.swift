import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Tune", size: CGSize(width: 880, height: 600)) { ContentView(model: MainActor.assumeIsolated { TuneModel.demo }) }
TuneApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window tool: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TuneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = TuneModel()

    var body: some Scene {
        Window("Tune", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 880, height: 600)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Tune")
            CommandGroup(replacing: .newItem) {}
            TunerCommands(model: model)
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

struct TunerCommands: Commands {
    @ObservedObject var model: TuneModel

    var body: some Commands {
        CommandMenu("Tuner") {
            Button(model.isListening ? "Pause Listening" : "Start Listening", action: model.toggleListening)
                .keyboardShortcut("l")
                .disabled(model.access == .denied || model.access == .noDevice)
            Divider()
            ForEach(Array(Instrument.allCases.enumerated()), id: \.element) { index, instrument in
                Toggle(instrument.title, isOn: Binding(get: { model.instrument == instrument },
                                                       set: { _ in model.instrument = instrument }))
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("Pick Strings Automatically", action: model.unlock)
                .keyboardShortcut("u")
                .disabled(model.lockedString == nil)
            Divider()
            Button("Raise Reference Pitch") { model.reference += 1 }
                .keyboardShortcut("]")
                .disabled(model.reference >= Music.referenceRange.upperBound)
            Button("Lower Reference Pitch") { model.reference -= 1 }
                .keyboardShortcut("[")
                .disabled(model.reference <= Music.referenceRange.lowerBound)
            Button("Reset Reference to 440 Hz") { model.reference = 440 }
                .keyboardShortcut("0")
                .disabled(model.reference == 440)
        }
    }
}

// MARK: - Icon

// A tuning fork ringing, with sound rings spreading out from its tines.

func appIcon() -> NSBitmapImageRep {
    render(0x7BE495, 0x2B9C6B) { ctx in
        let focus = CGPoint(x: 512, y: 640)

        // Sound rings on both sides of the tines.
        for (i, radius) in [210.0, 290.0, 370.0].enumerated() {
            let alpha = [0.62, 0.42, 0.24][i]
            for side in [0.0, .pi] {
                ctx.addArc(center: focus, radius: radius, startAngle: side - 0.62, endAngle: side + 0.62, clockwise: false)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(30 - CGFloat(i) * 4)
                ctx.setLineCap(.round)
                ctx.strokePath()
            }
        }

        // The fork: two tines joined in a U, a stem and a ball foot.
        let tines = CGMutablePath()
        tines.move(to: CGPoint(x: 438, y: 820))
        tines.addLine(to: CGPoint(x: 438, y: 520))
        tines.addArc(center: CGPoint(x: 512, y: 520), radius: 74, startAngle: .pi, endAngle: 0, clockwise: false)
        tines.addLine(to: CGPoint(x: 586, y: 820))
        let fork = tines.copy(strokingWithWidth: 62, lineCap: .round, lineJoin: .round, miterLimit: 10)
            .union(roundedRect(CGRect(x: 487, y: 250, width: 50, height: 200), 22))
            .union(CGPath(ellipseIn: CGRect(x: 470, y: 196, width: 84, height: 84), transform: nil))

        ctx.saveGState()
        shadow(ctx, y: -18, blur: 34, alpha: 0.32)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(fork)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // Brushed steel: a cool gradient across, then a bright edge highlight on the left of each part.
        ctx.saveGState()
        ctx.addPath(fork)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE4F3EA), rgb(0xB9D3C4)], from: CGPoint(x: 400, y: 0), to: CGPoint(x: 640, y: 0), in: ctx)
        gradient([NSColor.white.withAlphaComponent(0), rgb(0x1F6B4C, 0.18)], from: CGPoint(x: 0, y: 820), to: CGPoint(x: 0, y: 200), in: ctx)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        for x in [419.0, 567.0] { ctx.fill(CGRect(x: x, y: 520, width: 9, height: 330)) }
        ctx.fill(CGRect(x: 494, y: 236, width: 8, height: 168))
        ctx.restoreGState()
    }
}
