import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Arrow", size: CGSize(width: 1060, height: 700)) {
    MainActor.assumeIsolated { ContentView(board: Demo.board()) }
}
ArrowApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Images dropped on the Dock icon or opened with Arrow from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Board.shared.load(url: url) }
    }
}

struct ArrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var board = Board.shared

    var body: some Scene {
        Window("Arrow", id: "main") {
            ContentView(board: board)
        }
        .defaultSize(width: 1060, height: 700)
        .windowToolbarStyle(.unified)
        .commands { ArrowCommands(board: board) }
    }
}

struct ArrowCommands: Commands {
    @ObservedObject var board: Board

    private var hasImage: Bool { board.image != nil }
    private var editing: Bool { board.editingID != nil }

    var body: some Commands {
        AppHelpCommands(name: "Arrow")
        CommandGroup(replacing: .newItem) {
            Button("Open…") { board.openPanel() }.keyboardShortcut("o")
            Button("New from Clipboard") { board.pasteImage() }.keyboardShortcut("n")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export PNG…") { board.exportPanel() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!hasImage)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy") {
                if editing { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { board.copyImage() }
            }
            .keyboardShortcut("c")
            .disabled(!hasImage)
            Button("Paste") {
                if editing { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { board.pasteImage() }
            }
            .keyboardShortcut("v")
            Button("Delete") { board.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(board.selection == nil || editing)
            Button("Select All Text") { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
                .keyboardShortcut("a")
                .disabled(!editing)
            Divider()
            Button("Remove All Marks") { board.removeAll() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(board.annotations.isEmpty || editing)
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Toggle(tool.title, isOn: Binding(get: { board.tool == tool }, set: { if $0 { board.tool = tool } }))
                    .keyboardShortcut(KeyEquivalent(tool.key), modifiers: [])
                    .disabled(!hasImage || editing)
            }
            Divider()
            Button("Apply Crop") { board.applyCrop() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(board.tool != .crop)
            Button("Reset Crop") { board.resetCrop() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(board.crop == nil)
            Button(board.tool == .crop ? "Cancel Crop" : "Deselect") { board.escape() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(editing || (board.tool != .crop && board.selection == nil))
        }
    }
}

// MARK: - Icon

//: a bold curved red arrow pointing at a circled spot on a screenshot card

func appIcon() -> NSBitmapImageRep {
    render(0xFF4D4D, 0xB3122E) { ctx in
        // The screenshot card, tilted a little.
        ctx.saveGState()
        ctx.translateBy(x: 540, y: 560)
        ctx.rotate(by: 5 * .pi / 180)
        let card = CGRect(x: -300, y: -230, width: 600, height: 460)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 40, alpha: 0.35)
        ctx.addPath(roundedRect(card, 46))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(card, 46))
        ctx.clip()
        // Title bar with traffic lights.
        ctx.setFillColor(rgb(0xF1F1F4).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 78, width: card.width, height: 78))
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(hex).cgColor)
            ctx.fillEllipse(in: CGRect(x: card.minX + 36 + CGFloat(i) * 42, y: card.maxY - 52, width: 26, height: 26))
        }
        // Sidebar and content lines.
        ctx.setFillColor(rgb(0xF6F6F8).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.minY, width: 150, height: card.height - 78))
        ctx.setLineCap(.round)
        for i in 0..<4 {
            ctx.setStrokeColor(rgb(0xD9D9DE).cgColor)
            ctx.setLineWidth(18)
            let y = card.maxY - 130 - CGFloat(i) * 56
            ctx.move(to: CGPoint(x: card.minX + 36, y: y))
            ctx.addLine(to: CGPoint(x: card.minX + 112, y: y))
            ctx.strokePath()
        }
        for (i, len) in [CGFloat(300), 220, 260].enumerated() {
            ctx.setStrokeColor(rgb(i == 0 ? 0xB8B8C0 : 0xDEDEE3).cgColor)
            ctx.setLineWidth(i == 0 ? 26 : 18)
            let y = card.maxY - 136 - CGFloat(i) * 58
            ctx.move(to: CGPoint(x: card.minX + 196, y: y))
            ctx.addLine(to: CGPoint(x: card.minX + 196 + len, y: y))
            ctx.strokePath()
        }
        // The spot: a blue button.
        ctx.addPath(roundedRect(CGRect(x: 40, y: -150, width: 180, height: 70), 22))
        ctx.setFillColor(rgb(0x0A84FF).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // The red ring around the spot.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 10, alpha: 0.25)
        ctx.addEllipse(in: CGRect(x: -10, y: -205, width: 280, height: 180))
        ctx.setStrokeColor(rgb(0xE0182F).cgColor)
        ctx.setLineWidth(24)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.restoreGState()

        // The bold curved arrow, white edged so it reads on the card and the tile.
        let tail = CGPoint(x: 210, y: 200)
        let control = CGPoint(x: 230, y: 470)
        let neck = CGPoint(x: 470, y: 445)
        let dx = neck.x - control.x, dy = neck.y - control.y
        let len = hypot(dx, dy)
        let ux = dx / len, uy = dy / len
        let tip = CGPoint(x: neck.x + ux * 120, y: neck.y + uy * 120)
        let base = CGPoint(x: neck.x - ux * 10, y: neck.y - uy * 10)
        let curve = CGMutablePath()
        curve.move(to: tail)
        curve.addQuadCurve(to: base, control: control)
        let head = CGMutablePath()
        head.move(to: tip)
        head.addLine(to: CGPoint(x: neck.x - uy * 92, y: neck.y + ux * 92))
        head.addLine(to: CGPoint(x: neck.x + uy * 92, y: neck.y - ux * 92))
        head.closeSubpath()
        let shaft = curve.copy(strokingWithWidth: 62, lineCap: .round, lineJoin: .round, miterLimit: 10)
        func arrowShape() {
            ctx.addPath(shaft)
            ctx.addPath(head)
        }
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.4)
        arrowShape()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(30)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        arrowShape()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(30)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        for part in [shaft, head as CGPath] {
            ctx.saveGState()
            ctx.addPath(part)
            ctx.clip()
            gradient([rgb(0xFF3B3B), rgb(0xC8102E)], from: CGPoint(x: 0, y: 600), to: CGPoint(x: 0, y: 180), in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }
}
