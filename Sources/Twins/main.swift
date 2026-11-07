import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Twins", size: CGSize(width: 1020, height: 620)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
TwinsApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct TwinsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = TwinsModel()

    var body: some Scene {
        Window("Twins", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1020, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Twins")
            CommandGroup(replacing: .newItem) {
                Button("Choose Folders…") { model.chooseFolders() }
                    .keyboardShortcut("o")
                    .disabled(model.isScanning)
                Button("Add Folder…") { model.chooseFolders(adding: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.isScanning || model.roots.isEmpty)
                Divider()
                Button("Scan Again") { model.scan() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning || model.roots.isEmpty)
                Button("Stop Scan") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Divider()
                Button("Quick Look") { model.quickLookSelected() }
                    .keyboardShortcut("y")
                    .disabled(model.selectedGroup == nil)
                Button("Show in Finder") { if let g = model.selectedGroup { revealInFinder(g.files.map(\.url)) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.selectedGroup == nil)
                Divider()
                Button("Move Selected to Trash…") { model.requestTrash() }
                    .keyboardShortcut(.delete)
                    .disabled(model.marked.isEmpty || model.isScanning)
            }
            CommandMenu("Select") {
                ForEach(Array(KeepRule.allCases.enumerated()), id: \.1) { i, rule in
                    Button(rule.title) { model.apply(rule: rule) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                        .disabled(model.groups.isEmpty)
                }
                Divider()
                Button("Deselect All") { model.deselectAll() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.marked.isEmpty)
            }
            CommandGroup(before: .toolbar) {
                Picker("Sort Groups By", selection: $model.sort) {
                    ForEach(GroupSort.allCases) { Text($0.title).tag($0) }
                }
                Divider()
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

// MARK: - Demo

extension TwinsModel {
    /// Fixed sample results for the website snapshot.
    static var demo: TwinsModel {
        let m = TwinsModel()
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
        func g(_ id: String, _ size: Int64, _ copies: [(String, Double)]) -> DuplicateGroup {
            DuplicateGroup(id: id, size: size, files: copies.map { path, days in
                FileItem(url: home.appendingPathComponent(path), size: size, modified: now.addingTimeInterval(-days * 86_400))
            })
        }
        m.groups = [
            g("9f3c1a7e5b2d4086c1e9a7f3b5d20c4e8a6f1b3d", 3_412_000_000, [
                ("Downloads/ubuntu-26.04-desktop-arm64.iso", 12), ("Developer/VMs/ubuntu-26.04-desktop-arm64.iso", 40)]),
            g("4b7e2c9a1f0d3e5b8c6a2f4d7e9b1c3a5f8d0e2b", 1_486_000_000, [
                ("Movies/Sailing Trip 2026.mov", 70), ("Downloads/AirDrop/Sailing Trip 2026.mov", 69)]),
            g("c81d4e7a9b2f5c0e3a6d8b1f4c7e0a2d5b9f3c6e", 4_820_000, [
                ("Pictures/Export/IMG_4821.HEIC", 1), ("Desktop/IMG_4821.HEIC", 3), ("Downloads/IMG_4821 copy.HEIC", 21),
                ("Pictures/Shared Album/IMG_4821.HEIC", 20)]),
            g("2e6a9c3f7b1d5e8a0c4f6b9d2e7a1c5f8b3d0e6a", 241_500_000, [
                ("Documents/Brand Assets.zip", 120), ("Downloads/Brand Assets.zip", 118), ("Desktop/Old/Brand Assets.zip", 300)]),
            g("7d0b3e6a9c2f5b8e1a4d7c0f3b6e9a2d5c8f1b4e", 58_300_000, [
                ("Music/Podcast Episode 42.m4a", 9), ("Downloads/Podcast Episode 42.m4a", 9)]),
            g("a5c8e1b4d7f0a3c6e9b2d5f8a1c4e7b0d3f6a9c2", 18_640_000, [
                ("Documents/Annual Report 2025.pdf", 150), ("Downloads/Annual Report 2025.pdf", 151),
                ("Desktop/Annual Report 2025.pdf", 149)]),
            g("e3f6a9c2d5b8e1f4a7c0d3b6e9f2a5c8b1d4e7f0", 6_210_000, [
                ("Pictures/Sailing/DSC_0193.jpg", 72), ("Desktop/DSC_0193.jpg", 60)]),
            g("b9d2f5a8c1e4b7d0f3a6c9e2b5d8f1a4c7e0b3d6", 412_000, [
                ("Documents/Invoices/Invoice-2026-031.pdf", 33), ("Downloads/Invoice-2026-031.pdf", 34),
                ("Downloads/Invoice-2026-031 (1).pdf", 30), ("Desktop/Invoice-2026-031.pdf", 31)]),
        ]
        m.roots = [home.appendingPathComponent("Downloads"), home.appendingPathComponent("Pictures")]
        m.filesScanned = 18_406
        m.duration = 6.4
        m.marked = Scanner.autoSelect(m.groups, rule: .newest)
        m.selection = m.groups[2].id
        m.stage = .results
        return m
    }
}

// MARK: - Icon

//: two identical documents overlapping, each carrying the same picture and the same sparkle

func appIcon() -> NSBitmapImageRep {
    render(0x2BD9C6, 0x0B8F9C) { ctx in
        func document(at origin: CGPoint, front: Bool) {
            let w: CGFloat = 400, h: CGFloat = 500, fold: CGFloat = 110
            let r = CGRect(x: origin.x, y: origin.y, width: w, height: h)
            let body = CGMutablePath()
            body.move(to: CGPoint(x: r.minX + 40, y: r.minY))
            body.addLine(to: CGPoint(x: r.maxX - 40, y: r.minY))
            body.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + 40), control: CGPoint(x: r.maxX, y: r.minY))
            body.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
            body.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
            body.addLine(to: CGPoint(x: r.minX + 40, y: r.maxY))
            body.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - 40), control: CGPoint(x: r.minX, y: r.maxY))
            body.addLine(to: CGPoint(x: r.minX, y: r.minY + 40))
            body.addQuadCurve(to: CGPoint(x: r.minX + 40, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
            body.closeSubpath()

            ctx.saveGState()
            shadow(ctx, y: -18, blur: front ? 40 : 30, alpha: front ? 0.32 : 0.22)
            ctx.addPath(body)
            ctx.setFillColor(rgb(front ? 0xFFFFFF : 0xF2FBFB).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            // Folded corner.
            ctx.saveGState()
            let corner = CGMutablePath()
            corner.move(to: CGPoint(x: r.maxX - fold, y: r.maxY))
            corner.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY - fold + 18))
            corner.addQuadCurve(to: CGPoint(x: r.maxX - fold + 18, y: r.maxY - fold), control: CGPoint(x: r.maxX - fold, y: r.maxY - fold))
            corner.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
            corner.closeSubpath()
            shadow(ctx, y: -4, blur: 10, alpha: 0.16)
            ctx.addPath(corner)
            ctx.clip()
            gradient([rgb(0xDDF3F2), rgb(0xB5E3E2)], from: CGPoint(x: r.maxX - fold, y: r.maxY - fold),
                     to: CGPoint(x: r.maxX - fold / 2, y: r.maxY - fold / 2), in: ctx)
            ctx.restoreGState()

            // The shared picture: a teal panel with a gold sparkle.
            let pic = CGRect(x: r.minX + 52, y: r.minY + 200, width: w - 104 - 40, height: 190)
            ctx.saveGState()
            ctx.addPath(roundedRect(pic, 26))
            ctx.clip()
            gradient([rgb(0x5EEAD4), rgb(0x0E9AA7)], from: CGPoint(x: pic.minX, y: pic.maxY), to: CGPoint(x: pic.maxX, y: pic.minY), in: ctx)
            ctx.restoreGState()
            sparkle(ctx, at: CGPoint(x: pic.midX, y: pic.midY), size: 70, color: rgb(0xFFE08A))
            sparkle(ctx, at: CGPoint(x: pic.maxX - 44, y: pic.maxY - 40), size: 24, color: NSColor.white.withAlphaComponent(0.9))

            // Two text lines.
            ctx.setLineCap(.round)
            ctx.setLineWidth(26)
            ctx.setStrokeColor(rgb(0xBFE6E6).cgColor)
            for (i, length) in [CGFloat(256), 176].enumerated() {
                let y = r.minY + 140 - CGFloat(i) * 60
                ctx.move(to: CGPoint(x: r.minX + 64, y: y))
                ctx.addLine(to: CGPoint(x: r.minX + 64 + length, y: y))
                ctx.strokePath()
            }
        }
        document(at: CGPoint(x: 190, y: 330), front: false)
        document(at: CGPoint(x: 360, y: 190), front: true)
        // A sparkle in the open corner, for the match.
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: rgb(0xFFF3C4, 0.8).cgColor)
        sparkle(ctx, at: CGPoint(x: 780, y: 790), size: 62, color: .white)
        ctx.restoreGState()
        sparkle(ctx, at: CGPoint(x: 852, y: 700), size: 26, color: NSColor.white.withAlphaComponent(0.85))
    }
}
