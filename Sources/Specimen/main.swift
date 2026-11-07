import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Specimen", size: CGSize(width: 1040, height: 660)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
SpecimenApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SpecimenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = FontModel()

    var body: some Scene {
        Window("Specimen", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Specimen")
            CommandGroup(replacing: .newItem) {}
            SpecimenCommands(model: model)
        }
    }
}

struct SpecimenCommands: Commands {
    @ObservedObject var model: FontModel

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Font Name") { if let name = model.selection { model.copy(name) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.selection == nil)
            Button("Copy PostScript Name") {
                if let name = model.selection, let style = model.currentStyle(of: name) { model.copy(style.postScriptName) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift, .option])
            .disabled(model.selection == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find Font") { model.focusSearch += 1 }
                .keyboardShortcut("f")
        }
        CommandMenu("Font") {
            let name = model.selection
            Button(name.map { model.favourites.contains($0) } == true ? "Remove from Favourites" : "Add to Favourites") {
                if let name { model.toggleFavourite(name) }
            }
            .keyboardShortcut("d")
            .disabled(name == nil)
            Button(name.map { model.pinned.contains($0) } == true ? "Unpin from Comparison" : "Pin for Comparison") {
                if let name { model.togglePin(name) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(name == nil)
            Button("Clear Comparison") { model.pinned.removeAll() }
                .disabled(model.pinned.isEmpty)
            Divider()
            Button("Bigger") { model.adjustSize(by: model.size >= 48 ? 8 : 2) }
                .keyboardShortcut("+")
            Button("Smaller") { model.adjustSize(by: model.size > 48 ? -8 : -2) }
                .keyboardShortcut("-")
            Button("Default Size") { model.size = SpecimenPrefs().size }
                .keyboardShortcut("0")
            Divider()
            Button("Reset Sample Text") { model.sampleText = FontCatalog.defaultSample }
        }
        CommandGroup(before: .toolbar) {
            ForEach(Array(DetailMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.mode = mode }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Picker("Show", selection: $model.filter) {
                ForEach(FontFilter.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Dark Sample Background", isOn: $model.darkSample)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x8E5BD9, 0x4B2A8C) { ctx in
        // The specimen card, slightly tilted, with a soft shadow.
        let card = CGRect(x: 232, y: 196, width: 560, height: 650)
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 520)
        ctx.rotate(by: -0.06)
        ctx.translateBy(x: -512, y: -520)
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 44, alpha: 0.38)
        ctx.addPath(roundedRect(card, 54))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(card, 54))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xEFE8FA)], from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY), in: ctx)
        // Baseline and cap height guides.
        ctx.setStrokeColor(rgb(0x8E5BD9, 0.22).cgColor)
        ctx.setLineWidth(5)
        for y in [card.minY + 168, card.minY + 560] {
            ctx.move(to: CGPoint(x: card.minX + 48, y: y))
            ctx.addLine(to: CGPoint(x: card.maxX - 48, y: y))
        }
        ctx.strokePath()
        // Text lines under the letterform.
        ctx.setFillColor(rgb(0x4B2A8C, 0.16).cgColor)
        for (i, w) in [CGFloat(380), 300].enumerated() {
            ctx.addPath(roundedRect(CGRect(x: card.minX + 66, y: card.minY + 104 - CGFloat(i) * 42, width: w, height: 20), 10))
        }
        ctx.fillPath()
        ctx.restoreGState()

        // An ampersand drawn as one calligraphic stroke: a broad nib dragged along a bezier path.
        let box = CGRect(x: 312, y: 360, width: 400, height: 420)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }
        let curve = CGMutablePath()
        curve.move(to: p(0.90, 0.46))
        curve.addCurve(to: p(0.44, 0.02), control1: p(0.84, 0.18), control2: p(0.66, 0.02))
        curve.addCurve(to: p(0.06, 0.26), control1: p(0.22, 0.02), control2: p(0.06, 0.10))
        curve.addCurve(to: p(0.48, 0.62), control1: p(0.06, 0.44), control2: p(0.30, 0.52))
        curve.addCurve(to: p(0.64, 0.86), control1: p(0.60, 0.69), control2: p(0.66, 0.77))
        curve.addCurve(to: p(0.42, 1.00), control1: p(0.62, 0.95), control2: p(0.52, 1.00))
        curve.addCurve(to: p(0.24, 0.84), control1: p(0.31, 1.00), control2: p(0.24, 0.93))
        curve.addCurve(to: p(0.98, 0.00), control1: p(0.24, 0.62), control2: p(0.72, 0.22))
        let ink = CGMutablePath()
        let steps = 26
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps) - 0.5
            ink.addPath(curve, transform: CGAffineTransform(translationX: t * 40, y: t * 40))
        }
        let stroke = ink.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 16, alpha: 0.3)
        ctx.addPath(stroke)
        ctx.setFillColor(rgb(0x4B2A8C).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(stroke)
        ctx.clip()
        gradient([rgb(0xA57AE8), rgb(0x5A2F9E), rgb(0x3A1E70)], from: CGPoint(x: box.minX, y: box.maxY), to: CGPoint(x: box.maxX, y: box.minY), in: ctx)
        ctx.restoreGState()
        ctx.restoreGState()

        sparkle(ctx, at: CGPoint(x: 760, y: 790), size: 46, color: NSColor.white.withAlphaComponent(0.9))
    }
}
