import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Tabby", size: CGSize(width: 980, height: 660)) { ContentView.demo }
PixelApp.main()

struct PixelApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PixelDocument() }) { file in
            ContentView(document: file.document,
                        title: file.fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
        }
        .defaultSize(width: 980, height: 660)
        .windowToolbarStyle(.unified)
        .commands { PixelCommands() }
    }
}

struct PixelCommands: Commands {
    @FocusedObject private var editor: EditorState?

    var body: some Commands {
        AppHelpCommands(name: "Pixel")

        CommandGroup(replacing: .importExport) {
            Button("Import Image…") { editor?.importPNG() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Export PNG…") { editor?.showingExport = true }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Toggle("Show Grid", isOn: binding(\.showGrid))
                .keyboardShortcut("'", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Button("Zoom In") { editor?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom to Fit") { editor?.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editor == nil)
            Divider()
        }

        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Toggle(tool.name, isOn: Binding(get: { editor?.tool == tool }, set: { _ in editor?.select(tool) }))
                    .keyboardShortcut(KeyEquivalent(tool.key), modifiers: [])
                    .disabled(editor == nil)
            }
            Divider()
            Toggle("Mirror Drawing", isOn: binding(\.mirror))
                .keyboardShortcut("m", modifiers: [])
                .disabled(editor == nil)
        }

        CommandMenu("Image") {
            Menu("Canvas Size") {
                ForEach(PixelImage.presetSizes, id: \.self) { s in
                    Toggle("\(s) × \(s)", isOn: Binding(get: { editor?.image.width == s && editor?.image.height == s },
                                                         set: { _ in editor?.resize(to: s) }))
                }
            }
            .disabled(editor == nil)
            Divider()
            Button("Clear Canvas") { editor?.clear() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(editor == nil)
        }
    }

    private func binding(_ key: ReferenceWritableKeyPath<EditorState, Bool>) -> Binding<Bool> {
        Binding(get: { editor?[keyPath: key] ?? false }, set: { editor?[keyPath: key] = $0 })
    }
}

// MARK: - Icon

/// A tabby cat face in chunky pixels on a sheet of grid paper.
func appIcon() -> NSBitmapImageRep {
    render(0xF04BB3, 0x8A1FB0) { ctx in
        // Grid paper card.
        let card = CGRect(x: 512 - 290, y: 512 - 290, width: 580, height: 580)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.35)
        ctx.addPath(roundedRect(card, 64))
        ctx.setFillColor(rgb(0xFFF7FB).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        let cols = 12, rows = 12
        let cell: CGFloat = 42
        let origin = CGPoint(x: 512 - cell * CGFloat(cols) / 2, y: 512 - cell * CGFloat(rows) / 2)

        ctx.saveGState()
        ctx.addPath(roundedRect(card, 64))
        ctx.clip()
        ctx.setStrokeColor(rgb(0xE7C6E0).cgColor)
        ctx.setLineWidth(3)
        for i in -2...(cols + 2) {
            let x = origin.x + CGFloat(i) * cell
            ctx.move(to: CGPoint(x: x, y: card.minY)); ctx.addLine(to: CGPoint(x: x, y: card.maxY))
            let y = origin.y + CGFloat(i) * cell
            ctx.move(to: CGPoint(x: card.minX, y: y)); ctx.addLine(to: CGPoint(x: card.maxX, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // The cat, top row first. k outline, o fur, d stripe, p pink, w white.
        let art = [
            ".k........k.",
            ".kk......kk.",
            ".kpk....kpk.",
            ".kpokkkkopk.",
            "koooddoddook",
            "kooooooooook",
            "kowkoooowkok",
            "kokkooookkok",
            "kooooppooook",
            "kpooowwooopk",
            ".kooooooook.",
            "..kkkkkkkk..",
        ]
        let colors: [Character: UInt32] = ["k": 0x2B1B3A, "o": 0xFFA31A, "d": 0xC2602E, "p": 0xFF7FB0, "w": 0xFFFFFF]
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 10, alpha: 0.25)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (r, line) in art.enumerated() {
            for (c, ch) in line.enumerated() {
                guard let hex = colors[ch] else { continue }
                let rect = CGRect(x: origin.x + CGFloat(c) * cell, y: origin.y + CGFloat(rows - 1 - r) * cell, width: cell, height: cell)
                ctx.setFillColor(rgb(hex).cgColor)
                ctx.fill(rect.insetBy(dx: -0.5, dy: -0.5))
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // The grid shows faintly through the pixels, as in the editor.
        ctx.saveGState()
        ctx.addPath(roundedRect(card, 64))
        ctx.clip()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(2)
        for i in 1..<cols {
            let x = origin.x + CGFloat(i) * cell, y = origin.y + CGFloat(i) * cell
            ctx.move(to: CGPoint(x: x, y: origin.y)); ctx.addLine(to: CGPoint(x: x, y: origin.y + cell * CGFloat(rows)))
            ctx.move(to: CGPoint(x: origin.x, y: y)); ctx.addLine(to: CGPoint(x: origin.x + cell * CGFloat(cols), y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
