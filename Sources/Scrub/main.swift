import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
if Desktop.isSnapshot { MainActor.assumeIsolated { Demo.prefetchMap() } }
Desktop.handleSnapshot(title: "Scrub", size: CGSize(width: 1080, height: 700)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
ScrubApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single window utility: quitting when it closes, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Photos dropped on the Dock icon or opened with Scrub from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ScrubModel.shared.add(urls) }
    }
}

struct ScrubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = ScrubModel.shared

    var body: some Scene {
        Window("Scrub", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 1080, height: 700)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Scrub")
            ScrubCommands(model: model)
        }
        Settings { SettingsView() }
    }
}

struct ScrubCommands: Commands {
    @ObservedObject var model: ScrubModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Photos\u{2026}") { model.showImporter = true }.keyboardShortcut("o")
        }
        CommandMenu("Photo") {
            Button("Remove Location") { model.clean(.location) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!model.canClean(.location, all: false))
            Button("Remove All Metadata") { model.clean(.all) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.canClean(.all, all: false))
            Divider()
            Button("Remove Location from All Photos") { model.clean(.location, all: true) }
                .keyboardShortcut("l", modifiers: [.command, .shift, .option])
                .disabled(!model.canClean(.location, all: true))
            Button("Remove All Metadata from All Photos") { model.clean(.all, all: true) }
                .keyboardShortcut("m", modifiers: [.command, .shift, .option])
                .disabled(!model.canClean(.all, all: true))
            Button("Stop") { model.cancel() }
                .keyboardShortcut(".")
                .disabled(!model.isBusy)
            Divider()
            Button("Reveal Cleaned Copies in Finder") { model.revealOutputs() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.cleanedOutputs.isEmpty)
            Button("Show Original in Finder") { revealInFinder(model.selected.map(\.url)) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selected.isEmpty)
            Divider()
            Button("Remove from List") { model.remove(model.selection) }
                .keyboardShortcut(.delete)
                .disabled(model.selection.isEmpty)
            Button("Clear List") { model.removeAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
                .disabled(model.photos.isEmpty)
        }
    }
}

// MARK: - Icon

//: a photo with a location pin, half wiped away by a soft eraser sweep

func appIcon() -> NSBitmapImageRep {
    render(0x5B5BF0, 0x2E2A8F) { ctx in
        // Soft glow behind the photo.
        radial([NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)], center: CGPoint(x: 500, y: 560), radius: 420, in: ctx)

        // The photo: a white bordered print, tilted.
        ctx.saveGState()
        ctx.translateBy(x: 500, y: 540)
        ctx.rotate(by: -7 * .pi / 180)
        let card = CGRect(x: -270, y: -215, width: 540, height: 430)
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 44, alpha: 0.4)
        ctx.addPath(roundedRect(card, 40))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let picture = card.insetBy(dx: 30, dy: 30)
        ctx.saveGState()
        ctx.addPath(roundedRect(picture, 18))
        ctx.clip()
        gradient([rgb(0xFDBA74), rgb(0xF472B6), rgb(0x8B5CF6)], from: CGPoint(x: 0, y: picture.minY),
                 to: CGPoint(x: 0, y: picture.maxY), in: ctx)
        // Sun.
        ctx.setFillColor(rgb(0xFFF7D6).cgColor)
        ctx.fillEllipse(in: CGRect(x: -200, y: 30, width: 110, height: 110))
        // Hills.
        func hill(_ points: [CGPoint], _ top: UInt32, _ bottom: UInt32) {
            ctx.saveGState()
            ctx.move(to: CGPoint(x: picture.minX, y: picture.minY))
            ctx.addLine(to: points[0])
            for i in stride(from: 1, to: points.count - 1, by: 2) { ctx.addQuadCurve(to: points[i + 1], control: points[i]) }
            ctx.addLine(to: CGPoint(x: picture.maxX, y: picture.minY))
            ctx.closePath()
            ctx.clip()
            gradient([rgb(top), rgb(bottom)], from: CGPoint(x: 0, y: picture.midY), to: CGPoint(x: 0, y: picture.minY), in: ctx)
            ctx.restoreGState()
        }
        hill([CGPoint(x: picture.minX, y: -20), CGPoint(x: -120, y: 120), CGPoint(x: 20, y: 0), CGPoint(x: 140, y: -90), CGPoint(x: picture.maxX, y: 30)],
             0x6D5BD0, 0x4338A0)
        hill([CGPoint(x: picture.minX, y: -110), CGPoint(x: -60, y: -20), CGPoint(x: 90, y: -120), CGPoint(x: 190, y: -190), CGPoint(x: picture.maxX, y: -120)],
             0x3B2F8F, 0x241C66)
        ctx.restoreGState()
        ctx.restoreGState()

        // The pin, its lower half already erased: faded out in a transparency layer.
        let tip = CGPoint(x: 660, y: 520), r: CGFloat = 96
        let head = CGPoint(x: tip.x, y: tip.y + 200)
        let pin = CGMutablePath()
        pin.move(to: tip)
        pin.addCurve(to: CGPoint(x: head.x - r, y: head.y), control1: CGPoint(x: tip.x - 30, y: tip.y + 60),
                     control2: CGPoint(x: head.x - r, y: head.y - 50))
        pin.addArc(center: head, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        pin.addCurve(to: tip, control1: CGPoint(x: head.x + r, y: head.y - 50), control2: CGPoint(x: tip.x + 30, y: tip.y + 60))
        pin.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -12, blur: 24, alpha: 0.3)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(pin)
        ctx.clip()
        gradient([rgb(0xFF8080), rgb(0xDC2626)], from: CGPoint(x: 0, y: head.y + r), to: CGPoint(x: 0, y: tip.y), in: ctx)
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: head.x - 38, y: head.y - 38, width: 76, height: 76))
        ctx.setBlendMode(.destinationOut)
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1024, height: head.y - 20))
        gradient([NSColor.black, NSColor.black.withAlphaComponent(0)], from: CGPoint(x: 0, y: tip.y + 30),
                 to: CGPoint(x: 0, y: head.y - 20), in: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // The sweep the eraser has left behind: a soft bright swathe that fades towards its start.
        ctx.saveGState()
        let sweep = CGMutablePath()
        sweep.move(to: CGPoint(x: 170, y: 250))
        sweep.addCurve(to: CGPoint(x: 600, y: 520), control1: CGPoint(x: 330, y: 260), control2: CGPoint(x: 470, y: 380))
        ctx.addPath(sweep.copy(strokingWithWidth: 140, lineCap: .round, lineJoin: .round, miterLimit: 10))
        ctx.clip()
        gradient([NSColor.white.withAlphaComponent(0), NSColor.white.withAlphaComponent(0.4), NSColor.white.withAlphaComponent(0.8)],
                 from: CGPoint(x: 170, y: 250), to: CGPoint(x: 600, y: 520), in: ctx)
        ctx.restoreGState()

        // The eraser, mid stroke, over the pin's point.
        ctx.saveGState()
        ctx.translateBy(x: 590, y: 500)
        ctx.rotate(by: 34 * .pi / 180)
        let body = CGRect(x: -140, y: -70, width: 280, height: 140)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.42)
        ctx.addPath(roundedRect(body, 34))
        ctx.setFillColor(rgb(0xF472B6).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(body, 34))
        ctx.clip()
        gradient([rgb(0xFBCFE8), rgb(0xEC4899)], from: CGPoint(x: 0, y: body.maxY), to: CGPoint(x: 0, y: body.minY), in: ctx)
        // The paper sleeve on the far end.
        ctx.saveGState()
        let sleeve = CGRect(x: body.minX + 130, y: body.minY, width: body.width - 130, height: body.height)
        ctx.clip(to: sleeve)
        gradient([rgb(0xA5B4FC), rgb(0x4F46E5)], from: CGPoint(x: 0, y: sleeve.maxY), to: CGPoint(x: 0, y: sleeve.minY), in: ctx)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        ctx.fill(CGRect(x: sleeve.minX, y: sleeve.minY, width: 7, height: sleeve.height))
        ctx.restoreGState()
        // Top highlight.
        gradient([NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)], from: CGPoint(x: 0, y: body.maxY),
                 to: CGPoint(x: 0, y: body.maxY - 46), in: ctx)
        ctx.restoreGState()

        sparkle(ctx, at: CGPoint(x: 790, y: 330), size: 34, color: NSColor.white.withAlphaComponent(0.9))
        sparkle(ctx, at: CGPoint(x: 845, y: 405), size: 18, color: NSColor.white.withAlphaComponent(0.7))
    }
}
