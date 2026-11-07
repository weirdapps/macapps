import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "orders-2026.csv", size: CGSize(width: 1080, height: 660)) { DemoWindow() }
GridApp.main()

/// The snapshot's root: the real window content, fed with the demo model.
struct DemoWindow: View {
    @StateObject private var model = GridModel.demo
    var body: some View { GridView(model: model) }
}

struct GridApp: App {
    var body: some Scene {
        DocumentGroup(viewing: CSVFile.self) { file in
            DocumentWindow(file: file.document, url: file.fileURL)
        }
        .defaultSize(width: 1080, height: 660)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Grid")
            GridCommands()
        }
    }
}

struct GridCommands: Commands {
    @FocusedObject private var model: GridModel?

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Export as CSV…") { model?.export() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(model?.canExport ?? false))
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { model?.findRequest += 1 }
                .keyboardShortcut("f")
                .disabled(model?.phase != .ready)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as CSV") { model?.copy(format: .csv) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(!(model?.canCopy ?? false))
            Button("Copy as TSV") { model?.copy(format: .tsv) }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(!(model?.canCopy ?? false))
            Button("Copy as Markdown") { model?.copy(format: .markdown) }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!(model?.canCopy ?? false))
        }
        CommandGroup(before: .toolbar) {
            if let model {
                Toggle("Use First Row as Header", isOn: Binding(get: { model.hasHeader }, set: { model.setHeader($0) }))
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.phase != .ready)
                Picker("Delimiter", selection: Binding(get: { model.delimiter }, set: { model.setDelimiter($0) })) {
                    ForEach(Delimiter.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.phase != .ready)
                Picker("Text Encoding", selection: Binding(get: { model.encoding }, set: { model.setEncoding($0) })) {
                    ForEach(TextEncoding.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.phase != .ready)
                Menu("Search In") { SearchScopePicker(model: model) }
                    .disabled(model.phase != .ready)
                Button("Original Order") { model.setSort(nil) }
                    .keyboardShortcut("0", modifiers: [.command])
                    .disabled(model.sort == nil)
                Divider()
                Button(model.showInspector ? "Hide Inspector" : "Show Inspector") {
                    withAnimation(.snappy) { model.showInspector.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Divider()
            }
        }
    }
}

// MARK: - Icon

//: a spreadsheet tilted back in perspective, one column lifted out of it in green

func appIcon() -> NSBitmapImageRep {
    render(0x34C759, 0x177A3A) { ctx in
        // The sheet's corners; every grid line is a straight line between matching points on opposite edges.
        let bl = CGPoint(x: 168, y: 214), br = CGPoint(x: 846, y: 270)
        let tl = CGPoint(x: 286, y: 790), tr = CGPoint(x: 778, y: 812)
        func p(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            let bottom = CGPoint(x: bl.x + (br.x - bl.x) * u, y: bl.y + (br.y - bl.y) * u)
            let top = CGPoint(x: tl.x + (tr.x - tl.x) * u, y: tl.y + (tr.y - tl.y) * u)
            // Rows bunch up toward the far edge, as they would in perspective.
            let w = v >= 0 && v <= 1 ? 1 - pow(1 - v, 1.28) : v
            return CGPoint(x: bottom.x + (top.x - bottom.x) * w, y: bottom.y + (top.y - bottom.y) * w)
        }
        func quad(_ u0: CGFloat, _ u1: CGFloat, _ v0: CGFloat, _ v1: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: p(u0, v0))
            path.addLine(to: p(u1, v0))
            path.addLine(to: p(u1, v1))
            path.addLine(to: p(u0, v1))
            path.closeSubpath()
            return path
        }
        let cols: CGFloat = 4, rows: CGFloat = 6
        let headerV: CGFloat = 1 - 1 / rows

        // Sheet with a soft shadow.
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 44, alpha: 0.35)
        ctx.addPath(quad(0, 1, 0, 1))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(quad(0, 1, 0, 1))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xEAF3EC)], from: p(0.5, 1), to: p(0.5, 0), in: ctx)
        // Header row band.
        ctx.addPath(quad(0, 1, headerV, 1))
        ctx.setFillColor(rgb(0xD5E9DA).cgColor)
        ctx.fillPath()
        // Cell text as short dashes.
        for c in 0..<Int(cols) {
            for r in 0..<Int(rows) {
                let u0 = CGFloat(c) / cols + 0.045, v = (CGFloat(r) + 0.5) / rows
                let len: CGFloat = [0.14, 0.11, 0.16, 0.09, 0.13, 0.12][(r + c * 2) % 6]
                ctx.setStrokeColor(rgb(r == Int(rows) - 1 ? 0x4B7F5A : 0xB9CDBE).cgColor)
                ctx.setLineWidth(r == Int(rows) - 1 ? 15 : 13)
                ctx.setLineCap(.round)
                ctx.move(to: p(u0, v))
                ctx.addLine(to: p(u0 + len, v))
                ctx.strokePath()
            }
        }
        // Grid lines.
        ctx.setStrokeColor(rgb(0xC6D9CB).cgColor)
        ctx.setLineWidth(5)
        for c in 1..<Int(cols) {
            ctx.move(to: p(CGFloat(c) / cols, 0))
            ctx.addLine(to: p(CGFloat(c) / cols, 1))
        }
        for r in 1..<Int(rows) {
            ctx.move(to: p(0, CGFloat(r) / rows))
            ctx.addLine(to: p(1, CGFloat(r) / rows))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // The highlighted column, lifted off the sheet.
        let u0: CGFloat = 0.5, u1: CGFloat = 0.75
        ctx.saveGState()
        ctx.translateBy(x: -6, y: 26)
        let column = quad(u0 - 0.012, u1 + 0.012, -0.02, 1.02)
        ctx.saveGState()
        shadow(ctx, y: -26, blur: 40, alpha: 0.42)
        ctx.addPath(column)
        ctx.setFillColor(rgb(0x177A3A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(column)
        ctx.clip()
        gradient([rgb(0x5BE07F), rgb(0x1E9A47)], from: p(0.6, 1), to: p(0.6, 0), in: ctx)
        ctx.addPath(quad(u0 - 0.02, u1 + 0.02, headerV, 1.03))
        ctx.setFillColor(rgb(0x0F6B30, 0.35).cgColor)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(5)
        for r in 1..<Int(rows) {
            ctx.move(to: p(u0 - 0.02, CGFloat(r) / rows))
            ctx.addLine(to: p(u1 + 0.02, CGFloat(r) / rows))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineCap(.round)
        for r in 0..<Int(rows) {
            let v = (CGFloat(r) + 0.5) / rows
            let len: CGFloat = [0.15, 0.12, 0.17, 0.1, 0.14, 0.12][r]
            ctx.setLineWidth(r == Int(rows) - 1 ? 16 : 14)
            ctx.move(to: p(u1 - 0.035 - len, v))
            ctx.addLine(to: p(u1 - 0.035, v))
            ctx.strokePath()
        }
        // A thin highlight along the column's left edge.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(4)
        ctx.move(to: p(u0 - 0.012, -0.02))
        ctx.addLine(to: p(u0 - 0.012, 1.02))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()
    }
}
