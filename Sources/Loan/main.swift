import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Loan", size: CGSize(width: 1080, height: 700)) {
    MainActor.assumeIsolated { ContentView(model: CommandLine.arguments.contains("--savings") ? .demoSavings : .demo) }
}
LoanApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window calculator: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LoanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LoanModel()

    var body: some Scene {
        Window("Loan", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Loan")
            CommandGroup(replacing: .newItem) {
                Button("New Calculation") { model.reset() }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .importExport) {
                Button(model.mode == .loan ? "Export Schedule as CSV…" : "Export Savings Plan as CSV…") { model.export() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!model.canExport)
            }
            CommandMenu("Calculator") {
                Toggle("Loan", isOn: modeBinding(.loan)).keyboardShortcut("1")
                Toggle("Savings", isOn: modeBinding(.savings)).keyboardShortcut("2")
                Divider()
                Toggle("Schedule by Year", isOn: $model.byYear)
                    .keyboardShortcut("y")
                    .disabled(model.mode != .loan)
            }
        }
    }

    /// A checkmarked menu item that switches to `mode`.
    private func modeBinding(_ mode: Mode) -> Binding<Bool> {
        Binding(get: { model.mode == mode }, set: { if $0 { model.mode = mode } })
    }
}

// MARK: - Icon

//: a house on a gold coin, with a gently rising curve

func appIcon() -> NSBitmapImageRep {
    render(0xF7C548, 0xC98A12) { ctx in
        let c = CGPoint(x: 512, y: 540), r: CGFloat = 300

        // Rising curve behind the coin, from lower left to upper right.
        func curve(_ path: CGMutablePath) {
            path.move(to: CGPoint(x: 170, y: 250))
            path.addCurve(to: CGPoint(x: 862, y: 600), control1: CGPoint(x: 450, y: 256), control2: CGPoint(x: 660, y: 360))
        }

        // Coin: drop shadow, rim, face.
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 40, alpha: 0.35)
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.setFillColor(rgb(0xA86E08).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        gradient([rgb(0xFFE7A0), rgb(0xD99A1C), rgb(0xA86E08)], from: CGPoint(x: 0, y: c.y + r), to: CGPoint(x: 0, y: c.y - r), in: ctx)
        ctx.restoreGState()

        let face: CGFloat = r - 36
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - face, y: c.y - face, width: 2 * face, height: 2 * face))
        ctx.clip()
        gradient([rgb(0xFFF4D2), rgb(0xF6D277)], from: CGPoint(x: 0, y: c.y + face), to: CGPoint(x: 0, y: c.y - face), in: ctx)
        // Inner bevel: a darker band at the top edge of the face.
        ctx.addEllipse(in: CGRect(x: c.x - face, y: c.y - face, width: 2 * face, height: 2 * face))
        ctx.setStrokeColor(rgb(0xC98A12, 0.45).cgColor)
        ctx.setLineWidth(14)
        ctx.strokePath()

        // House silhouette.
        let house = CGMutablePath()
        let baseY: CGFloat = 452, left: CGFloat = 397, right: CGFloat = 627, eave: CGFloat = 600, apex: CGFloat = 722
        house.move(to: CGPoint(x: left, y: baseY))
        house.addLine(to: CGPoint(x: left, y: eave))
        house.addLine(to: CGPoint(x: left - 42, y: eave))
        house.addLine(to: CGPoint(x: 512, y: apex))
        house.addLine(to: CGPoint(x: 572, y: apex - 46))
        house.addLine(to: CGPoint(x: 572, y: apex - 8))
        house.addLine(to: CGPoint(x: 612, y: apex - 8))
        house.addLine(to: CGPoint(x: 612, y: apex - 78))
        house.addLine(to: CGPoint(x: right + 42, y: eave))
        house.addLine(to: CGPoint(x: right, y: eave))
        house.addLine(to: CGPoint(x: right, y: baseY))
        house.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 10, color: rgb(0x7A4E04, 0.35).cgColor)
        ctx.addPath(house)
        ctx.clip()
        gradient([rgb(0xB57A0C), rgb(0x7E5104)], from: CGPoint(x: 0, y: apex), to: CGPoint(x: 0, y: baseY), in: ctx)
        ctx.restoreGState()
        // Door.
        ctx.addPath(roundedRect(CGRect(x: 487, y: baseY, width: 50, height: 92), 12))
        ctx.setFillColor(rgb(0xF9DE95).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Coin highlight along the upper rim.
        ctx.saveGState()
        ctx.addArc(center: c, radius: r - 10, startAngle: .pi * 0.62, endAngle: .pi * 0.92, clockwise: false)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // The curve in front, white with a soft shadow, ending in a dot.
        let path = CGMutablePath()
        curve(path)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 18, alpha: 0.3)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(30)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.addEllipse(in: CGRect(x: 862 - 38, y: 600 - 38, width: 76, height: 76))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addEllipse(in: CGRect(x: 862 - 18, y: 600 - 18, width: 36, height: 36))
        ctx.setFillColor(rgb(0xD99A1C).cgColor)
        ctx.fillPath()
    }
}
