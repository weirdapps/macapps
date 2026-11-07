import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Product Launch", size: CGSize(width: 1040, height: 660)) {
    MindEditorView(document: MindDocument(map: .demo), selection: MindMap.demoSelection)
}
MindApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observer: NSObjectProtocol?

    // A document app stays open with no windows, like TextEdit.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI rebuilds the main menu now and then; put the Node menu back whenever it is missing.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { NodeMenu.install() }
        }
    }
}

struct MindApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        DocumentGroup(newDocument: { MindDocument() }) { file in
            MindEditorView(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1100, height: 680)
        .windowToolbarStyle(.unified)
        .commands { MindCommands() }
    }
}

struct MindCommands: Commands {
    @FocusedObject private var editor: Editor?
    @Environment(\.newDocument) private var newDocument

    var body: some Commands {
        AppHelpCommands(name: "Mind")

        CommandGroup(replacing: .importExport) {
            Button("Import Markdown Outline…") { Editor.importMarkdown(newDocument: newDocument) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Export as PNG…") { editor?.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button("Export as Markdown…") { editor?.exportMarkdown() }
                .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                .disabled(editor == nil)
        }

        CommandGroup(before: .toolbar) {
            Button("Zoom In") { editor?.zoom(by: 1.25) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom Out") { editor?.zoom(by: 1 / 1.25) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
            Button("Actual Size") { editor?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(editor == nil)
            Button("Zoom to Fit") { editor?.fit() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(editor == nil)
            Divider()
        }
    }
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(Theme.top, Theme.bottom) { ctx in
        let center = CGPoint(x: 512, y: 500)
        // Branches: end point, colour, thickness, and small twigs off the end node.
        let branches: [(CGPoint, UInt32, CGFloat, [CGPoint])] = [
            (CGPoint(x: 790, y: 720), 0xFF8A8A, 40, [CGPoint(x: 850, y: 840)]),
            (CGPoint(x: 815, y: 440), 0xFFC15E, 38, [CGPoint(x: 870, y: 300)]),
            (CGPoint(x: 700, y: 230), 0x4FE3A1, 34, []),
            (CGPoint(x: 220, y: 680), 0x6EC8FF, 38, [CGPoint(x: 170, y: 820)]),
            (CGPoint(x: 245, y: 330), 0xFF8FE0, 36, [CGPoint(x: 160, y: 220)]),
        ]
        func curve(_ a: CGPoint, _ b: CGPoint) {
            let mid = (a.x + b.x) / 2
            ctx.move(to: a)
            ctx.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
        }
        func dot(_ p: CGPoint, _ r: CGFloat, _ color: UInt32) {
            ctx.saveGState()
            shadow(ctx, y: -8, blur: 18, alpha: 0.3)
            ctx.setFillColor(rgb(color).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            ctx.clip()
            gradient([NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)],
                     from: CGPoint(x: p.x, y: p.y + r), to: CGPoint(x: p.x, y: p.y - r * 0.2), in: ctx)
            ctx.restoreGState()
        }

        ctx.setLineCap(.round)
        // Twigs first, so the branch nodes sit on top of them.
        for (end, color, width, twigs) in branches {
            for twig in twigs {
                ctx.setStrokeColor(rgb(color, 0.9).cgColor)
                ctx.setLineWidth(width * 0.45)
                curve(end, twig)
                ctx.strokePath()
            }
        }
        for (end, color, width, _) in branches {
            ctx.saveGState()
            shadow(ctx, y: -6, blur: 16, alpha: 0.22)
            ctx.setStrokeColor(rgb(color).cgColor)
            ctx.setLineWidth(width)
            curve(center, end)
            ctx.strokePath()
            ctx.restoreGState()
        }
        for (end, color, _, twigs) in branches {
            for twig in twigs { dot(twig, 30, color) }
            dot(end, 56, color)
        }

        // The glowing central node.
        radial([NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)], center: center, radius: 250, in: ctx)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xE9DDFF, 0.9).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - 112, y: center.y - 112, width: 224, height: 224))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE4D6FF)], from: CGPoint(x: center.x, y: center.y + 112),
                 to: CGPoint(x: center.x, y: center.y - 112), in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: center.x - 54, y: center.y - 54, width: 108, height: 108))
        ctx.clip()
        gradient([rgb(Theme.top), rgb(Theme.bottom)], from: CGPoint(x: center.x, y: center.y + 54),
                 to: CGPoint(x: center.x, y: center.y - 54), in: ctx)
        ctx.restoreGState()
    }
}
