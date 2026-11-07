import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Plot", size: CGSize(width: 1100, height: 700)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
PlotApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PlotModel.shared.saveNow() }
    }

    /// CSV and TSV files opened from Finder become new charts.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { PlotModel.shared.importFiles(urls) }
    }
}

struct PlotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlotModel.shared

    var body: some Scene {
        Window("Plot", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1100, height: 700)
        .windowToolbarStyle(.unified)
        .commands { PlotCommands(model: model) }
    }
}

struct PlotCommands: Commands {
    @ObservedObject var model: PlotModel

    var body: some Commands {
        AppHelpCommands(name: "Plot")
        CommandGroup(replacing: .newItem) {
            Button("New Chart") { model.newChart() }.keyboardShortcut("n")
            Button("Duplicate Chart") { model.duplicate(model.selection) }.keyboardShortcut("d").disabled(model.selected == nil)
            Divider()
            Button("Import CSV…") { importCSV() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .importExport) {
            Button("Export PNG…") { if let c = model.selected { Exporter.export(c, pdf: false, model: model) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selected?.isPlottable != true)
            Button("Export PDF…") { if let c = model.selected { Exporter.export(c, pdf: true, model: model) } }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option])
                .disabled(model.selected?.isPlottable != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Chart Image") { copyChart(model) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.selected?.isPlottable != true)
            Button("Paste Data") { model.pasteFromClipboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Edit Data as Text…") { model.editingText = true }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(model.selected == nil)
            Divider()
            Button("Add Row") { model.update(model.selection, action: "Add Row") { $0.table.addRow() } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(model.selected == nil)
            Button("Add Series") { model.update(model.selection, action: "Add Series") { $0.table.addColumn() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(model.selected == nil)
            Divider()
            Button("Delete Chart") { model.delete(model.selection) }.disabled(model.selected == nil)
        }
        CommandMenu("Chart") {
            ForEach(ChartKind.allCases) { kind in
                Toggle(kind.menuName, isOn: Binding(
                    get: { model.selected?.kind == kind },
                    set: { _ in model.update(model.selection, action: "Change Chart Type") { $0.kind = kind } }
                ))
                .keyboardShortcut(kind.shortcut)
            }
            Divider()
            Picker("Colours", selection: Binding(
                get: { model.selected?.palette ?? .plot },
                set: { p in model.update(model.selection, action: "Change Colours") { $0.palette = p } }
            )) {
                ForEach(PaletteName.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Show Legend", isOn: Binding(
                get: { model.selected?.showLegend ?? true },
                set: { v in model.update(model.selection, action: "Toggle Legend") { $0.showLegend = v } }
            ))
            .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Show Value Labels", isOn: Binding(
                get: { model.selected?.showValues ?? false },
                set: { v in model.update(model.selection, action: "Toggle Value Labels") { $0.showValues = v } }
            ))
            .keyboardShortcut("v", modifiers: [.command, .option])
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                withAnimation(.snappy) { model.showInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    @MainActor
    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        panel.message = "Choose CSV or TSV files to chart"
        guard panel.runModal() == .OK else { return }
        model.importFiles(panel.urls)
    }
}

// MARK: - Icon

//: a rising bar chart with a smooth amber line arcing over it, on an azure tile

func appIcon() -> NSBitmapImageRep {
    render(0x4FC3F7, 0x1E6FD9) { ctx in
        let base: CGFloat = 236
        let width: CGFloat = 122, gap: CGFloat = 46
        let heights: [CGFloat] = [180, 290, 392, 520]
        let x0 = tile.midX - (4 * width + 3 * gap) / 2

        // Baseline.
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.addPath(roundedRect(CGRect(x: x0 - 30, y: base - 22, width: 4 * width + 3 * gap + 60, height: 14), 7))
        ctx.fillPath()
        ctx.restoreGState()

        // Bars: white columns with a cool gradient and soft drop shadows.
        for (i, h) in heights.enumerated() {
            let rect = CGRect(x: x0 + CGFloat(i) * (width + gap), y: base, width: width, height: h)
            let path = CGPath(roundedRect: rect, cornerWidth: 30, cornerHeight: 30, transform: nil)
            ctx.saveGState()
            shadow(ctx, y: -14, blur: 26, alpha: 0.28)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xD6ECFF)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            ctx.setFillColor(rgb(0x1E6FD9, 0.08).cgColor)
            ctx.fill(CGRect(x: rect.maxX - 26, y: rect.minY, width: 26, height: rect.height))
            ctx.restoreGState()
        }

        // The line: a smooth curve arcing over the bar tops, ending in a dot.
        let start = CGPoint(x: x0 - 6, y: base + 250)
        let end = CGPoint(x: x0 + 4 * width + 3 * gap - 70, y: base + 590)
        let line = CGMutablePath()
        line.move(to: start)
        line.addCurve(to: end, control1: CGPoint(x: x0 + 200, y: base + 320), control2: CGPoint(x: x0 + 340, y: base + 610))
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        shadow(ctx, y: -10, blur: 22, alpha: 0.3)
        ctx.addPath(line)
        ctx.setStrokeColor(rgb(0xFFB020).cgColor)
        ctx.setLineWidth(40)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(line)
        ctx.setLineCap(.round)
        ctx.setLineWidth(40)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        gradient([rgb(0xFFD966), rgb(0xFF9A1F)], from: CGPoint(x: start.x, y: end.y), to: CGPoint(x: end.x, y: start.y), in: ctx)
        ctx.restoreGState()

        ctx.saveGState()
        shadow(ctx, y: -8, blur: 18, alpha: 0.3)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: end.x - 50, y: end.y - 50, width: 100, height: 100))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xFF9A1F).cgColor)
        ctx.fillEllipse(in: CGRect(x: end.x - 28, y: end.y - 28, width: 56, height: 56))
    }
}
