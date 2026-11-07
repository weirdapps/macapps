import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Tail", size: CGSize(width: 1040, height: 640)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
TailApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Console.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Finder's Open With and drops on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { TailModel.shared.open(urls) }
    }
}

struct TailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = TailModel.shared

    var body: some Scene {
        Window("Tail", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1040, height: 640)
        .windowToolbarStyle(.unified)
        .commands { TailCommands(model: model) }

        Settings { SettingsView(model: model) }
    }
}

struct TailCommands: Commands {
    @ObservedObject var model: TailModel

    var body: some Commands {
        AppHelpCommands(name: "Tail")
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.presentOpenPanel() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Log") { if let source = model.selected { model.close(source) } }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
            Button("Reveal in Finder") { if let source = model.selected { revealInFinder([source.url]) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selected == nil)
        }
        CommandGroup(before: .toolbar) {
            LogMenuItems(model: model)
        }
        CommandGroup(after: .textEditing) {
            Toggle("Filter with Regular Expression", isOn: $model.isRegex)
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
    }
}

/// The View menu's log items; a view so it can watch the selected log's pause and auto-scroll state.
struct LogMenuItems: View {
    @ObservedObject var model: TailModel

    var body: some View {
        if let source = model.selected {
            SourceMenuItems(source: source, model: model)
        } else {
            Button("Pause") {}.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(true)
            Button("Auto-Scroll") {}.keyboardShortcut("j", modifiers: [.command, .shift]).disabled(true)
            Button("Jump to Bottom") {}.keyboardShortcut("j").disabled(true)
            Button("Clear") {}.keyboardShortcut("k").disabled(true)
        }
        Toggle("Wrap Lines", isOn: $model.wrap).keyboardShortcut("l", modifiers: [.command, .shift])
        Divider()
        Button("Bigger") { model.fontSize = min(model.fontSize + 1, TailModel.fontRange.upperBound) }.keyboardShortcut("+")
        Button("Smaller") { model.fontSize = max(model.fontSize - 1, TailModel.fontRange.lowerBound) }.keyboardShortcut("-")
        Button("Actual Size") { model.fontSize = 12 }.keyboardShortcut("0")
        Divider()
        Button("Next Log") { model.selectNeighbour(1) }
            .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(model.sources.count < 2)
        Button("Previous Log") { model.selectNeighbour(-1) }
            .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(model.sources.count < 2)
        Divider()
    }
}

struct SourceMenuItems: View {
    @ObservedObject var source: LogSource
    @ObservedObject var model: TailModel

    var body: some View {
        Button(source.isPaused ? "Resume" : "Pause") { source.togglePause() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        Toggle("Auto-Scroll", isOn: Binding(get: { source.follow }, set: { _ in model.toggleFollow(source) }))
            .keyboardShortcut("j", modifiers: [.command, .shift])
        Button("Jump to Bottom") { source.jumpToBottom() }.keyboardShortcut("j")
        Button("Clear") { source.clear() }.keyboardShortcut("k")
    }
}

// MARK: - Demo data for the website screenshot

extension TailModel {
    static var demo: TailModel {
        let model = TailModel(persistent: false)
        let app = LogSource(url: URL(fileURLWithPath: "/Users/demo/Projects/shop/logs/server.log"), maxLines: 10_000, highlighter: model.highlighter)
        app.handle(.loaded(lines: Demo.server, reachedStart: false, size: 1_284_000_000))
        let access = LogSource(url: URL(fileURLWithPath: "/usr/local/var/log/nginx/access.log"), maxLines: 10_000, highlighter: model.highlighter)
        access.handle(.loaded(lines: Demo.access, reachedStart: true, size: 48_200_000))
        let worker = LogSource(url: URL(fileURLWithPath: "/Users/demo/Projects/shop/logs/worker.log"), maxLines: 10_000, highlighter: model.highlighter)
        worker.handle(.loaded(lines: Demo.worker, reachedStart: true, size: 3_400_000))
        worker.togglePause()
        worker.ingest(["2026-11-07 09:42:10.004 INFO  job 8812 done"])
        let system = LogSource(url: URL(fileURLWithPath: "/var/log/system.log"), maxLines: 10_000, highlighter: model.highlighter)
        system.handle(.loaded(lines: ["Nov  7 09:40:01 mac syslogd[118]: ASL Sender Statistics"], reachedStart: true, size: 612_000))
        model.sources = [app, access, worker, system]
        model.selection = app.id
        return model
    }
}

enum Demo {
    static let server = [
        "2026-11-07 09:41:02.118 INFO  [http] GET /api/products 200 14ms",
        "2026-11-07 09:41:02.244 INFO  [http] GET /api/products/4411 200 9ms",
        "2026-11-07 09:41:02.731 DEBUG [cache] hit products:4411 (ttl 287s)",
        "2026-11-07 09:41:03.090 INFO  [auth] session refreshed for user 20931",
        "2026-11-07 09:41:03.512 INFO  [http] POST /api/cart 201 31ms",
        "2026-11-07 09:41:04.006 WARN  [db] slow query 812ms: SELECT * FROM orders WHERE customer_id = $1",
        "2026-11-07 09:41:04.377 INFO  [http] GET /api/cart 200 11ms",
        "2026-11-07 09:41:05.120 INFO  [payments] intent pi_3Q8x created, amount 84.90 EUR",
        "2026-11-07 09:41:05.881 DEBUG [queue] enqueued email.receipt (depth 3)",
        "2026-11-07 09:41:06.402 INFO  [http] POST /api/checkout 200 402ms",
        "2026-11-07 09:41:07.015 ERROR [payments] card declined: insufficient_funds (order 77120)",
        "2026-11-07 09:41:07.016 INFO  [http] POST /api/checkout/confirm 402 58ms",
        "2026-11-07 09:41:08.230 INFO  [http] GET /health 200 1ms",
        "2026-11-07 09:41:09.604 INFO  [http] GET /api/products?page=2 200 18ms",
        "2026-11-07 09:41:10.778 WARN  [http] rate limit at 80% for 85.74.12.9",
        "2026-11-07 09:41:11.140 INFO  [search] query \"linen shirt\" 42 results in 22ms",
        "2026-11-07 09:41:12.009 DEBUG [cache] miss search:linen shirt",
        "2026-11-07 09:41:12.552 INFO  [http] GET /api/search 200 26ms",
        "2026-11-07 09:41:13.905 ERROR [mail] SMTP timeout after 10s, retrying in 30s (attempt 2 of 5)",
        "2026-11-07 09:41:14.311 INFO  [http] GET /api/orders/77119 200 12ms",
        "2026-11-07 09:41:15.064 INFO  [auth] login ok for user 18822 (passkey)",
        "2026-11-07 09:41:15.890 INFO  [http] GET /api/account 200 8ms",
        "2026-11-07 09:41:16.442 DEBUG [db] pool 9 of 20 connections in use",
        "2026-11-07 09:41:17.218 INFO  [http] POST /api/cart 201 27ms",
        "2026-11-07 09:41:18.006 WARN  [inventory] SKU LS-204-M below reorder point (3 left)",
        "2026-11-07 09:41:18.731 INFO  [payments] intent pi_3Q8y succeeded, amount 129.00 EUR",
        "2026-11-07 09:41:19.120 INFO  [http] POST /api/checkout/confirm 200 96ms",
        "2026-11-07 09:41:19.402 INFO  [queue] email.receipt sent to order 77121",
        "2026-11-07 09:41:20.017 INFO  [http] GET /api/products/5120 200 10ms",
        "2026-11-07 09:41:20.633 INFO  [http] GET /api/recommendations 200 44ms",
        "2026-11-07 09:41:21.102 DEBUG [cache] evicted 120 keys (memory 71%)",
        "2026-11-07 09:41:21.540 INFO  [http] GET /api/products/5120/reviews 200 19ms",
        "2026-11-07 09:41:22.215 WARN  [auth] 3 failed logins for user 30417 in 60s",
        "2026-11-07 09:41:22.871 INFO  [http] POST /api/cart 201 24ms",
        "2026-11-07 09:41:23.390 INFO  [payments] intent pi_3Q8z created, amount 42.50 EUR",
        "2026-11-07 09:41:23.944 INFO  [http] GET /api/cart 200 9ms",
    ]

    static let access = (0..<40).map { i in
        "85.74.12.\(i % 9 + 2) - - [07/Nov/2026:09:41:\(String(format: "%02d", i)) +0200] \"GET /api/products/\(4400 + i) HTTP/2\" 200 \(812 + i * 17)"
    }

    static let worker = [
        "2026-11-07 09:40:58.100 INFO  job 8809 started (resize-images)",
        "2026-11-07 09:41:01.420 ERROR job 8809 failed: image too large (48 MB)",
        "2026-11-07 09:41:01.421 WARN  job 8809 moved to the retry queue",
        "2026-11-07 09:41:05.300 INFO  job 8810 done",
        "2026-11-07 09:41:09.020 ERROR job 8811 failed: S3 403 Forbidden",
    ]
}

// MARK: - Icon

func appIcon() -> NSBitmapImageRep {
    render(0x1B2A4A, 0x0A1020) { ctx in
        // A faint grid of scan lines, like a terminal pane.
        ctx.saveGState()
        for i in 0..<16 {
            let y = tile.minY + 40 + CGFloat(i) * 50
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.025).cgColor)
            ctx.fill(CGRect(x: tile.minX, y: y, width: tile.width, height: 2))
        }
        ctx.restoreGState()

        // Log lines, fading in as they get newer towards the bottom.
        let lengths: [CGFloat] = [250, 380, 300, 430, 210, 350, 470]
        let indents: [CGFloat] = [0, 0, 60, 0, 60, 0, 0]
        let left: CGFloat = 214
        for (i, length) in lengths.enumerated() {
            let y = 720 - CGFloat(i) * 72
            let alpha = 0.22 + CGFloat(i) / CGFloat(lengths.count - 1) * 0.78
            let rect = CGRect(x: left + indents[i], y: y, width: length, height: 34)
            ctx.saveGState()
            if i == lengths.count - 1 {
                ctx.setShadow(offset: .zero, blur: 30, color: rgb(0x3DF08F, 0.8).cgColor)
            }
            ctx.addPath(roundedRect(rect, 17))
            ctx.clip()
            gradient([rgb(0x5CF5A4, alpha), rgb(0x22C46E, alpha)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            ctx.restoreGState()
            // A brighter timestamp stub at the start of each line.
            ctx.addPath(roundedRect(CGRect(x: left + indents[i], y: y, width: 34, height: 34), 17))
            ctx.setFillColor(rgb(0xC9FFE0, alpha * 0.9).cgColor)
            ctx.fillPath()
        }

        // The comet: a tapering tail streaming down to a glowing head beside the newest line.
        let head = CGPoint(x: 762, y: 305)
        let top = CGPoint(x: 884, y: 884)
        let tail = CGMutablePath()
        tail.move(to: top)
        tail.addQuadCurve(to: CGPoint(x: head.x + 44, y: head.y + 6), control: CGPoint(x: 846, y: 500))
        tail.addArc(center: head, radius: 44, startAngle: 0.14, endAngle: .pi - 0.14, clockwise: true)
        tail.addQuadCurve(to: top, control: CGPoint(x: 744, y: 600))
        tail.closeSubpath()
        ctx.saveGState()
        ctx.addPath(tail)
        ctx.clip()
        gradient([rgb(0x3DF08F, 0), rgb(0x3DF08F, 0.35), rgb(0xA8FFD0, 0.95)],
                 from: top, to: CGPoint(x: head.x, y: head.y - 40), in: ctx)
        ctx.restoreGState()

        ctx.saveGState()
        radial([rgb(0x3DF08F, 0.55), rgb(0x3DF08F, 0)], center: head, radius: 150, in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x5CF5A4, 1).cgColor)
        ctx.addEllipse(in: CGRect(x: head.x - 44, y: head.y - 44, width: 88, height: 88))
        ctx.clip()
        radial([NSColor.white, rgb(0xB8FFD8), rgb(0x2BD47A)], center: CGPoint(x: head.x - 10, y: head.y + 12), radius: 58, in: ctx)
        ctx.restoreGState()

        // Small sparks shed by the tail.
        sparkle(ctx, at: CGPoint(x: 716, y: 560), size: 14, color: rgb(0xA8FFD0, 0.7))
        sparkle(ctx, at: CGPoint(x: 872, y: 410), size: 10, color: rgb(0xA8FFD0, 0.55))
        sparkle(ctx, at: CGPoint(x: 770, y: 780), size: 9, color: rgb(0xA8FFD0, 0.4))
    }
}
