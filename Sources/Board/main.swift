import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Board", size: CGSize(width: 1100, height: 640)) { MainActor.assumeIsolated { ContentView(store: .demo) } }
BoardApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct BoardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = BoardStore()

    var body: some Scene {
        Window("Board", id: "main") {
            ContentView(store: store)
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Board")
            SidebarCommands()
            BoardCommands(store: store)
        }
    }
}

struct BoardCommands: Commands {
    @ObservedObject var store: BoardStore

    var body: some Commands {
        let board = store.current
        CommandGroup(replacing: .newItem) {
            Button("New Card") {
                if let column = board?.columns.first { store.search = ""; store.quickAdd = column.id }
            }
            .keyboardShortcut("n")
            .disabled(board?.columns.isEmpty ?? true)
            Button("New Column") { if let board { store.addColumn(in: board.id) } }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(board == nil)
            Button("New Board") { store.addBoard() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Find Cards") { store.searchRequest += 1 }
                .keyboardShortcut("f")
                .disabled(board == nil)
        }
        CommandMenu("Board") {
            Button("Archive Cards in “\(board?.columns.last?.name ?? "Done")”") {
                if let board { store.change("Archive Cards", board: board.id) { $0.archiveDone() } }
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(board?.columns.last?.cards.isEmpty ?? true)
            Button("Show Archive") { store.showArchive = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(board == nil)
            Divider()
            Button("Previous Board") { step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(store.boards.count < 2)
            Button("Next Board") { step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(store.boards.count < 2)
            Divider()
            Button("Rename Board…") { store.renamingBoard = board?.id }
                .disabled(board == nil)
            Button("Delete Board…") { store.confirmingDeleteBoard = board?.id }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
                .disabled(board == nil)
        }
    }

    private func step(_ offset: Int) {
        guard let i = store.boards.firstIndex(where: { $0.id == store.selection }) else {
            store.selection = store.boards.first?.id
            return
        }
        store.selection = store.boards[(i + offset + store.boards.count) % store.boards.count].id
    }
}

// MARK: - Icon

//: three columns of sticky cards, one of them lifted mid-move

func appIcon() -> NSBitmapImageRep {
    render(0x2E9BFF, 0x1658C7) { ctx in
        let laneWidth: CGFloat = 196, gap: CGFloat = 38
        let left: CGFloat = (iconSize - (laneWidth * 3 + gap * 2)) / 2
        let laneBottom: CGFloat = 228, laneTop: CGFloat = 770

        // Lanes: frosted columns on the board.
        for i in 0..<3 {
            let lane = CGRect(x: left + CGFloat(i) * (laneWidth + gap), y: laneBottom, width: laneWidth, height: laneTop - laneBottom)
            ctx.addPath(roundedRect(lane, 44))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.17).cgColor)
            ctx.fillPath()
            ctx.addPath(roundedRect(lane.insetBy(dx: 1.5, dy: 1.5), 42))
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(3)
            ctx.strokePath()
        }

        func sticky(_ rect: CGRect, _ color: UInt32, _ shade: UInt32, lifted: Bool = false) {
            ctx.saveGState()
            if lifted { shadow(ctx, y: -26, blur: 44, alpha: 0.42) } else { shadow(ctx, y: -6, blur: 12, alpha: 0.22) }
            ctx.addPath(roundedRect(rect, 24))
            ctx.setFillColor(rgb(color).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(rect, 24))
            ctx.clip()
            gradient([rgb(0xFFFFFF, 0.35), rgb(shade, 0.0)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.midY), in: ctx)
            gradient([rgb(shade, 0), rgb(shade, 0.55)], from: CGPoint(x: 0, y: rect.midY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            // Two text lines.
            ctx.setFillColor(rgb(shade, 0.55).cgColor)
            ctx.addPath(roundedRect(CGRect(x: rect.minX + 24, y: rect.maxY - 46, width: rect.width - 56, height: 16), 8))
            ctx.addPath(roundedRect(CGRect(x: rect.minX + 24, y: rect.maxY - 76, width: rect.width - 92, height: 16), 8))
            ctx.fillPath()
            ctx.restoreGState()
        }

        let cardW: CGFloat = laneWidth - 32, cardH: CGFloat = 116, step: CGFloat = 134
        func slot(_ lane: Int, _ row: Int) -> CGRect {
            CGRect(x: left + CGFloat(lane) * (laneWidth + gap) + 16, y: laneTop - 18 - cardH - CGFloat(row) * step, width: cardW, height: cardH)
        }
        sticky(slot(0, 0), 0xFFE26A, 0xE0A818)
        sticky(slot(0, 1), 0xFF9C8A, 0xE0563E)
        sticky(slot(0, 2), 0xFFE26A, 0xE0A818)
        sticky(slot(1, 0), 0x8EEBC0, 0x2FA874)
        // The empty slot the moving card is heading for.
        let target = slot(1, 1)
        ctx.addPath(roundedRect(target, 24))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(5)
        ctx.setLineDash(phase: 0, lengths: [18, 12])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        sticky(slot(2, 0), 0xFFFFFF, 0x9DB8DA)

        // The card in flight, lifted and tilted between the first two columns.
        ctx.saveGState()
        let moving = slot(0, 3)
        ctx.translateBy(x: moving.midX + 128, y: moving.midY + 60)
        ctx.rotate(by: 0.16)
        ctx.scaleBy(x: 1.08, y: 1.08)
        sticky(CGRect(x: -cardW / 2, y: -cardH / 2, width: cardW, height: cardH), 0xFFFFFF, 0x9DB8DA, lifted: true)
        ctx.restoreGState()
    }
}
