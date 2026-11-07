import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Iconsmith", size: CGSize(width: 1060, height: 700)) { ContentView(model: MainActor.assumeIsolated { IconModel.demo }) }
IconsmithApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder's Open With and drops on the Dock icon. The window picks the file up when it appears, or right away.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated { FileInbox.shared.receive(url) }
    }
}

/// Hands files opened from Finder to the window's model.
@MainActor
final class FileInbox {
    static let shared = FileInbox()
    var pending: URL?
    weak var model: IconModel?

    func receive(_ url: URL) {
        if let model { model.open(url) } else { pending = url }
    }

    func attach(_ model: IconModel) {
        self.model = model
        if let url = pending {
            pending = nil
            model.open(url)
        }
    }
}

struct IconsmithApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = IconModel()

    var body: some Scene {
        Window("Iconsmith", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1060, height: 700)
        .windowToolbarStyle(.unified)
        .commands { IconsmithCommands(model: model) }
    }
}

struct IconsmithCommands: Commands {
    @ObservedObject var model: IconModel
    @AppStorage("showGrid", store: Theme.defaults) private var showGrid = false
    @AppStorage("darkPreview", store: Theme.defaults) private var darkPreview = false
    @AppStorage("showInspector", store: Theme.defaults) private var showInspector = true

    /// True when a text field has focus, so the standard Copy and Paste keep working there.
    private var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    var body: some Commands {
        AppHelpCommands(name: "Iconsmith")
        CommandGroup(replacing: .newItem) {
            Button("Open Image…") { model.showOpenPanel() }.keyboardShortcut("o")
            Divider()
            Button(ExportKind.icns.menuTitle) { model.export(.icns) }.keyboardShortcut("e")
                .disabled(!model.hasImage || model.isExporting)
            Button(ExportKind.iconset.menuTitle) { model.export(.iconset) }.keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!model.hasImage || model.isExporting)
            Button(ExportKind.appIconSet.menuTitle) { model.export(.appIconSet) }.keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!model.hasImage || model.isExporting)
            Divider()
            Button("Reveal in Finder") { model.revealLastExport() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.lastExport == nil)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x")
            Button("Copy Icon") {
                if editingText { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { model.copyIcon() }
            }
            .keyboardShortcut("c")
            Button("Paste Image") {
                if editingText { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { model.paste() }
            }
            .keyboardShortcut("v")
            Button("Select All") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a")
        }
        CommandMenu("Icon") {
            Picker("Shape", selection: Binding(get: { model.options.shape }, set: { s in model.update("Change Shape") { $0.shape = s } })) {
                Text(IconShape.tile.title).tag(IconShape.tile).keyboardShortcut("1")
                Text(IconShape.fullBleed.title).tag(IconShape.fullBleed).keyboardShortcut("2")
            }
            .pickerStyle(.inline)
            Toggle("Drop Shadow", isOn: Binding(get: { model.options.shadow }, set: { v in model.update("Toggle Shadow") { $0.shadow = v } }))
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(model.options.shape != .tile)
            Toggle("Fill Background", isOn: Binding(get: { model.options.fillBackground },
                                                    set: { v in model.update("Toggle Background") { $0.fillBackground = v } }))
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
            Picker("Framing", selection: Binding(get: { model.options.framing }, set: { f in model.update("Change Framing") { $0.framing = f } })) {
                Text(Framing.crop.title).tag(Framing.crop).keyboardShortcut("3")
                Text(Framing.fit.title).tag(Framing.fit).keyboardShortcut("4")
            }
            .pickerStyle(.inline)
            Divider()
            Button("Zoom In") { model.zoom(by: 1.25) }.keyboardShortcut("=")
                .disabled(!model.hasImage || model.options.zoom >= IconOptions.zoomRange.upperBound)
            Button("Zoom Out") { model.zoom(by: 0.8) }.keyboardShortcut("-")
                .disabled(!model.hasImage || model.options.zoom <= IconOptions.zoomRange.lowerBound)
            Button("Reset Crop") { model.resetCrop() }.keyboardShortcut("0")
                .disabled(!model.hasImage)
        }
        CommandGroup(before: .toolbar) {
            Toggle("Show Icon Grid", isOn: $showGrid).keyboardShortcut("g", modifiers: [.command, .shift])
            Toggle("Dark Preview Background", isOn: $darkPreview).keyboardShortcut("d", modifiers: [.command, .shift])
            Toggle("Show Inspector", isOn: $showInspector).keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

// MARK: - Icon

//: an anvil with a glowing golden app tile rising above it, on graphite

func appIcon() -> NSBitmapImageRep {
    render(0x4A4F5C, 0x1C1E24) { ctx in
        // Warm glow behind the floating tile.
        radial([rgb(0xFFC94D, 0.55), rgb(0xF59E0B, 0.18), rgb(0xF59E0B, 0)], center: CGPoint(x: 512, y: 590), radius: 360, in: ctx)

        // The anvil: a wide face with a horn on the left, a waist and a stepped foot.
        let anvil = CGMutablePath()
        anvil.move(to: CGPoint(x: 330, y: 190))
        anvil.addLine(to: CGPoint(x: 694, y: 190))
        anvil.addLine(to: CGPoint(x: 694, y: 222))
        anvil.addQuadCurve(to: CGPoint(x: 616, y: 276), control: CGPoint(x: 616, y: 230))
        anvil.addLine(to: CGPoint(x: 604, y: 330))
        anvil.addQuadCurve(to: CGPoint(x: 744, y: 372), control: CGPoint(x: 630, y: 360))
        anvil.addLine(to: CGPoint(x: 776, y: 372))
        anvil.addLine(to: CGPoint(x: 776, y: 436))
        anvil.addLine(to: CGPoint(x: 360, y: 436))
        anvil.addQuadCurve(to: CGPoint(x: 196, y: 410), control: CGPoint(x: 262, y: 434))
        anvil.addQuadCurve(to: CGPoint(x: 410, y: 340), control: CGPoint(x: 300, y: 350))
        anvil.addLine(to: CGPoint(x: 420, y: 276))
        anvil.addQuadCurve(to: CGPoint(x: 330, y: 222), control: CGPoint(x: 408, y: 230))
        anvil.closeSubpath()

        ctx.saveGState()
        shadow(ctx, y: -14, blur: 26, alpha: 0.5)
        ctx.addPath(anvil)
        ctx.setFillColor(rgb(0x2A2D35).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(anvil)
        ctx.clip()
        gradient([rgb(0x8E95A3), rgb(0x5A606C), rgb(0x30333B)], from: CGPoint(x: 0, y: 400), to: CGPoint(x: 0, y: 190), in: ctx)
        // The polished face catches the glow, with a gold seam under it that follows the horn.
        ctx.clip(to: CGRect(x: 0, y: 404, width: 1024, height: 40))
        gradient([rgb(0xFFE7AE), rgb(0xD9A441)], from: CGPoint(x: 0, y: 436), to: CGPoint(x: 0, y: 404), in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(anvil)
        ctx.clip()
        ctx.setFillColor(rgb(0xF5C451).cgColor)
        ctx.fill(CGRect(x: 0, y: 400, width: 1024, height: 6))
        ctx.restoreGState()

        // The floating app tile, glowing gold, with a sheen and an inner bevel.
        let card = CGRect(x: 357, y: 478, width: 310, height: 310)
        let cardPath = roundedRect(card, 70)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 70, color: rgb(0xFFC94D, 0.85).cgColor)
        ctx.addPath(cardPath)
        ctx.setFillColor(rgb(0xF5C451).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        gradient([rgb(0xFFF1C2), rgb(0xF8C44A), rgb(0xC98A1B)], from: CGPoint(x: card.minX, y: card.maxY), to: CGPoint(x: card.maxX, y: card.minY), in: ctx)
        gradient([NSColor.white.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0)],
                 from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.midY + 20), in: ctx)
        ctx.restoreGState()
        ctx.addPath(roundedRect(card.insetBy(dx: 2, dy: 2), 68))
        ctx.setStrokeColor(rgb(0xFFF7DA, 0.8).cgColor)
        ctx.setLineWidth(4)
        ctx.strokePath()
        // A smaller tile inside, the icon within the icon.
        let inner = card.insetBy(dx: 92, dy: 92)
        ctx.addPath(roundedRect(inner, 30))
        ctx.setFillColor(rgb(0x8A5A0B, 0.55).cgColor)
        ctx.fillPath()
        ctx.addPath(roundedRect(inner.insetBy(dx: 6, dy: 6), 25))
        ctx.setFillColor(rgb(0xFFF3CC, 0.9).cgColor)
        ctx.fillPath()

        sparkle(ctx, at: CGPoint(x: 712, y: 790), size: 34, color: rgb(0xFFF1C2))
        sparkle(ctx, at: CGPoint(x: 300, y: 690), size: 22, color: rgb(0xFFE08A, 0.9))
        sparkle(ctx, at: CGPoint(x: 735, y: 560), size: 16, color: rgb(0xFFE08A, 0.8))
    }
}
