import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Diary", size: CGSize(width: 980, height: 640)) { ContentView(model: .demo) }
DiaryApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // One diary, one window: closing it quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct DiaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = DiaryStore()

    var body: some Scene {
        Window("Diary", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Diary")
            DiaryCommands(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

struct DiaryCommands: Commands {
    @ObservedObject var model: DiaryStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Today\u{2019}s Entry") { model.goToday() }
                .keyboardShortcut("n")
                .disabled(model.locked)
            Divider()
            Button("Export All to Markdown\u{2026}") { model.exportAll() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.locked || !model.hasEntries)
            Divider()
            Button("Lock Diary") { model.lock() }
                .keyboardShortcut("l", modifiers: [.command, .control])
                .disabled(model.locked)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete Entry\u{2026}") { model.confirmDelete() }
                .disabled(model.locked || model.current == nil)
        }
        CommandMenu("Go") {
            Button("Today") { model.goToday() }
                .keyboardShortcut("t")
            Divider()
            Button("Previous Day") { model.step(days: -1) }
                .keyboardShortcut("[")
            Button("Next Day") { model.step(days: 1) }
                .keyboardShortcut("]")
            Button("Previous Month") { model.step(months: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Next Month") { model.step(months: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Divider()
            Button("Search Entries") { model.searchFocusRequest += 1 }
                .keyboardShortcut("f")
        }
    }
}

// MARK: - Demo

extension DiaryStore {
    /// Fixed entries for the website screenshot; never the user's own.
    static var demo: DiaryStore {
        let today = Day(year: 2026, month: 11, day: 26)
        let calendar = Calendar.diary
        let lines: [(Int, String, Mood?, [String])] = [
            (0, """
            A slow morning off. Coffee on the balcony before anyone else was up, the light coming in low and gold over the rooftops.

            Walked down to the harbour with Anna and watched the fishing boats come in. We bought sardines from the old man with the blue cap, who remembered us from the summer and threw in a lemon.

            Finally finished the book I started in September. The last chapter was worth the wait. I keep thinking about the line about how we are all just a collection of the places we have loved.

            Tomorrow: call Mum, water the basil, and do nothing else on purpose.
            """, .good, ["family", "walk", "books"]),
            (1, "Long week finally over. Pizza night and a terrible film we laughed at all the way through.", .good, ["family"]),
            (2, "Presentation went better than I feared. Two good questions and one I will think about all weekend.", .great, ["work"]),
            (3, "Rain all day. Stayed in, wrote letters, made soup. Quietly content.", .okay, ["home"]),
            (4, "Tired. Too many meetings and not enough thinking. Early night.", .low, ["work"]),
            (5, "First run in three weeks. Legs heavy, head clear.", .good, ["running"]),
            (6, "Sunday market. Bought far too many tomatoes and a small cactus.", .great, ["walk"]),
            (7, "Read in the park until the light went.", .good, ["books"]),
            (8, "Dentist, then groceries, then nothing much.", .okay, []),
            (9, "Started planning the spring trip. Lisbon or Porto? Both, maybe.", .great, ["travel"]),
            (10, "Hard conversation with Sam. Glad we had it.", .low, ["friends"]),
            (11, "Bread came out perfect for once.", .good, ["home"]),
            (12, "Quiet day. Nothing to report, and that is fine.", .okay, []),
            (13, "Caught the sunrise on the way to the airport.", .great, ["travel"]),
            (16, "Lunch with the old team. Same jokes, more grey hair.", .good, ["friends", "work"]),
            (18, "Sick and grumpy. Tea and blankets.", .rough, []),
            (20, "Swam in the sea, probably the last time this year. Freezing and wonderful.", .great, ["sea"]),
            (23, "Wrote three pages of nonsense and one good sentence.", .okay, ["writing"]),
            (26, "Long dinner on the terrace, talking until midnight.", .good, ["friends"]),
            (365, "Our first autumn in the new flat. Boxes still everywhere, but the kitchen finally feels like ours. Anna hung the little lemon tree painting by the window.", .great, ["home", "family"]),
            (731, "Walked the whole coast road at dawn. Promised myself I would start writing things down. So here we are.", .good, ["walk", "writing"]),
        ]
        let entries = lines.map { offset, text, mood, tags in
            let day = offset == 365 ? Day(year: 2025, month: 11, day: 26)
                : offset == 731 ? Day(year: 2024, month: 11, day: 26)
                : today.adding(days: -offset)
            let edited = day.date(calendar).addingTimeInterval(9 * 3600)
            return Entry(day: day, text: text, mood: mood, tags: tags, created: edited, modified: edited)
        }
        return DiaryStore(entries: entries, today: today, calendar: calendar)
    }
}

// MARK: - Icon

//: a leather-bound journal with a ribbon bookmark and a small brass lock

func appIcon() -> NSBitmapImageRep {
    render(0xE97A9A, 0xA93A62) { ctx in
        ctx.saveGState()
        ctx.translateBy(x: 500, y: 520)
        ctx.rotate(by: -5 * .pi / 180)
        let cover = CGRect(x: -235, y: -300, width: 450, height: 600)

        // Page block peeking out on the right and bottom.
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.35)
        ctx.addPath(roundedRect(CGRect(x: cover.minX + 30, y: cover.minY + 10, width: cover.width - 2, height: cover.height - 22), 26))
        ctx.setFillColor(rgb(0xF6EBDD).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(rgb(0xD8C6AE).cgColor)
        ctx.setLineWidth(3)
        for i in 0..<7 {
            let x = cover.maxX + 4 + CGFloat(i) * 3.2
            ctx.move(to: CGPoint(x: x, y: cover.minY + 34)); ctx.addLine(to: CGPoint(x: x, y: cover.maxY - 34))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Ribbon bookmark hanging from the bottom edge.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 10, alpha: 0.3)
        let rx: CGFloat = 40
        ctx.move(to: CGPoint(x: rx, y: cover.minY + 30))
        ctx.addLine(to: CGPoint(x: rx + 56, y: cover.minY + 30))
        ctx.addLine(to: CGPoint(x: rx + 60, y: cover.minY - 96))
        ctx.addLine(to: CGPoint(x: rx + 32, y: cover.minY - 66))
        ctx.addLine(to: CGPoint(x: rx + 4, y: cover.minY - 94))
        ctx.closePath()
        ctx.clip()
        gradient([rgb(0xFFD36B), rgb(0xE79A27)], from: CGPoint(x: rx, y: 0), to: CGPoint(x: rx + 62, y: 0), in: ctx)
        ctx.restoreGState()

        // Leather cover.
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.4)
        ctx.addPath(roundedRect(cover, 34))
        ctx.setFillColor(rgb(0x6E3226).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(cover, 34))
        ctx.clip()
        gradient([rgb(0x9A4C36), rgb(0x6A2E22), rgb(0x4E1F17)], from: CGPoint(x: cover.minX, y: cover.maxY),
                 to: CGPoint(x: cover.maxX, y: cover.minY), in: ctx)
        radial([NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: cover.minX + 150, y: cover.maxY - 130), radius: 340, in: ctx)
        // Spine band with raised ribs.
        ctx.setFillColor(rgb(0x2E110C, 0.42).cgColor)
        ctx.fill(CGRect(x: cover.minX, y: cover.minY, width: 64, height: cover.height))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.fill(CGRect(x: cover.minX + 64, y: cover.minY, width: 4, height: cover.height))
        for y in [cover.maxY - 110, cover.minY + 96] {
            ctx.setFillColor(rgb(0x2E110C, 0.5).cgColor)
            ctx.fill(CGRect(x: cover.minX, y: y - 9, width: 64, height: 18))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.fill(CGRect(x: cover.minX, y: y + 6, width: 64, height: 4))
        }
        ctx.restoreGState()

        // Stitching around the cover.
        ctx.saveGState()
        ctx.addPath(roundedRect(CGRect(x: cover.minX + 90, y: cover.minY + 28, width: cover.width - 118, height: cover.height - 56), 18))
        ctx.setStrokeColor(rgb(0xF1C9A0, 0.75).cgColor)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [16, 13])
        ctx.strokePath()
        ctx.restoreGState()

        // Debossed heart in the middle of the cover.
        ctx.saveGState()
        let c = CGPoint(x: cover.midX + 24, y: cover.midY + 58)
        let heart = CGMutablePath()
        heart.move(to: CGPoint(x: c.x, y: c.y - 62))
        heart.addCurve(to: CGPoint(x: c.x - 72, y: c.y + 22), control1: CGPoint(x: c.x - 34, y: c.y - 30), control2: CGPoint(x: c.x - 72, y: c.y - 10))
        heart.addCurve(to: CGPoint(x: c.x, y: c.y + 34), control1: CGPoint(x: c.x - 72, y: c.y + 62), control2: CGPoint(x: c.x - 18, y: c.y + 70))
        heart.addCurve(to: CGPoint(x: c.x + 72, y: c.y + 22), control1: CGPoint(x: c.x + 18, y: c.y + 70), control2: CGPoint(x: c.x + 72, y: c.y + 62))
        heart.addCurve(to: CGPoint(x: c.x, y: c.y - 62), control1: CGPoint(x: c.x + 72, y: c.y - 10), control2: CGPoint(x: c.x + 34, y: c.y - 30))
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 2, color: NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.addPath(heart)
        ctx.setFillColor(rgb(0x3E170F, 0.55).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Strap across the right edge, with a brass lock.
        let strap = CGRect(x: cover.maxX - 120, y: -200, width: 168, height: 92)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 14, alpha: 0.35)
        ctx.addPath(roundedRect(strap, 20))
        ctx.setFillColor(rgb(0x4A1C14).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(strap.insetBy(dx: 10, dy: 12), 12))
        ctx.setStrokeColor(rgb(0xF1C9A0, 0.55).cgColor)
        ctx.setLineWidth(4)
        ctx.setLineDash(phase: 0, lengths: [11, 9])
        ctx.strokePath()
        ctx.restoreGState()

        let lock = CGRect(x: strap.midX - 54, y: strap.midY - 62, width: 108, height: 96)
        // Shackle.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 10, alpha: 0.35)
        let shackle = CGMutablePath()
        shackle.move(to: CGPoint(x: lock.minX + 24, y: lock.maxY - 6))
        shackle.addLine(to: CGPoint(x: lock.minX + 24, y: lock.maxY + 22))
        shackle.addArc(center: CGPoint(x: lock.midX, y: lock.maxY + 22), radius: lock.width / 2 - 24, startAngle: .pi, endAngle: 0, clockwise: true)
        shackle.addLine(to: CGPoint(x: lock.maxX - 24, y: lock.maxY - 6))
        ctx.addPath(shackle)
        ctx.setStrokeColor(rgb(0xC9CDD4).cgColor)
        ctx.setLineWidth(17)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shackle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(5)
        ctx.translateBy(x: -3, y: 2)
        ctx.strokePath()
        ctx.restoreGState()
        // Body.
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 14, alpha: 0.4)
        ctx.addPath(roundedRect(lock, 22))
        ctx.setFillColor(rgb(0xD9A233).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(lock, 22))
        ctx.clip()
        gradient([rgb(0xFFE08A), rgb(0xE5A93A), rgb(0xB57A1C)], from: CGPoint(x: 0, y: lock.maxY), to: CGPoint(x: 0, y: lock.minY), in: ctx)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.fill(CGRect(x: lock.minX, y: lock.maxY - 10, width: lock.width, height: 4))
        ctx.restoreGState()
        // Keyhole.
        ctx.setFillColor(rgb(0x5A3A0E).cgColor)
        ctx.fillEllipse(in: CGRect(x: lock.midX - 13, y: lock.midY - 2, width: 26, height: 26))
        ctx.move(to: CGPoint(x: lock.midX - 7, y: lock.midY + 4))
        ctx.addLine(to: CGPoint(x: lock.midX - 11, y: lock.midY - 30))
        ctx.addLine(to: CGPoint(x: lock.midX + 11, y: lock.midY - 30))
        ctx.addLine(to: CGPoint(x: lock.midX + 7, y: lock.midY + 4))
        ctx.closePath()
        ctx.fillPath()

        ctx.restoreGState()
    }
}
