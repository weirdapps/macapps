import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "Split", size: CGSize(width: 1080, height: 680)) {
    MainActor.assumeIsolated { ContentView(model: .demo) }
}
SplitApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single-window utility: closing the window quits, like Calculator.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SplitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SplitModel.shared

    var body: some Scene {
        Window("Split", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Split")
            SplitCommands(model: model)
        }
    }
}

struct SplitCommands: Commands {
    @ObservedObject var model: SplitModel

    private var noGroup: Bool { model.current == nil }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Expense…") { model.sheet = .newExpense }.keyboardShortcut("n").disabled(noGroup)
            Button("New Group…") { model.sheet = .newGroup }.keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Edit Group…") { if let id = model.selection { model.sheet = .editGroup(id) } }
                .keyboardShortcut("i").disabled(noGroup)
            Button("Delete Group…") { model.confirmingDelete = true }.disabled(noGroup)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Export Summary as Text…") { model.export(csv: false) }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(noGroup)
            Button("Export as CSV…") { model.export(csv: true) }
                .keyboardShortcut("e", modifiers: [.command, .shift, .option]).disabled(noGroup)
            Button("Copy Summary") { model.copySummary() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(noGroup)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Edit Expense…") { model.editSelected() }.keyboardShortcut("e").disabled(model.selectedExpense == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(model.showBalances ? "Hide Balances" : "Show Balances") {
                withAnimation(.snappy) { model.showBalances.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
    }
}

// MARK: - Demo

extension SplitModel {
    /// Fixed books for the website screenshot.
    static var demo: SplitModel {
        let model = SplitModel(groups: Demo.groups)
        model.selection = Demo.groups.first?.id
        return model
    }
}

enum Demo {
    static func day(_ d: Int, _ m: Int = 10) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: m, day: d, hour: 12)) ?? .now
    }

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static var groups: [SplitGroup] {
        let anna = Member(id: id(1), name: "Anna"), ben = Member(id: id(2), name: "Ben")
        let chloe = Member(id: id(3), name: "Chloe"), dev = Member(id: id(4), name: "Dev")
        let all = [anna, ben, chloe, dev]
        func equal(_ who: [Member]) -> [Portion] { who.map { Portion(member: $0.id, value: 1) } }
        var lisbon = SplitGroup(id: id(100), name: "Lisbon trip", currency: "EUR", members: all)
        lisbon.expenses = [
            Expense(id: id(101), title: "Apartment in Alfama", amount: 612, payer: anna.id, date: day(3), portions: equal(all)),
            Expense(id: id(102), title: "Train from the airport", amount: 26.40, payer: ben.id, date: day(3), portions: equal(all)),
            Expense(id: id(103), title: "Dinner at Taberna da Rua", amount: 148.50, payer: chloe.id, date: day(4),
                    note: "Ben had the big fish", mode: .shares,
                    portions: [Portion(member: anna.id, value: 1), Portion(member: ben.id, value: 2),
                               Portion(member: chloe.id, value: 1), Portion(member: dev.id, value: 1)]),
            Expense(id: id(104), title: "Tram 28 day passes", amount: 41.60, payer: dev.id, date: day(5), portions: equal(all)),
            Expense(id: id(105), title: "Surf lesson in Cascais", amount: 180, payer: ben.id, date: day(5), mode: .exact,
                    portions: [Portion(member: ben.id, value: 60), Portion(member: chloe.id, value: 60), Portion(member: dev.id, value: 60)]),
            Expense(id: id(106), title: "Pastéis de nata", amount: 10, payer: anna.id, date: day(6), portions: equal([anna, chloe, dev])),
            Expense(id: id(107), title: "Groceries", amount: 63.25, payer: dev.id, date: day(6), portions: equal(all)),
        ]
        lisbon.payments = [Payment(id: id(150), from: dev.id, to: anna.id, amount: 40, date: day(7))]

        let maya = Member(id: id(5), name: "Maya"), leo = Member(id: id(6), name: "Leo")
        var flat = SplitGroup(id: id(200), name: "Flat 3B", currency: "EUR", members: [anna, maya, leo])
        flat.expenses = [
            Expense(id: id(201), title: "Electricity", amount: 94.20, payer: maya.id, date: day(1, 11), portions: equal([anna, maya, leo])),
            Expense(id: id(202), title: "Internet", amount: 35, payer: leo.id, date: day(2, 11), portions: equal([anna, maya, leo])),
        ]
        var ski = SplitGroup(id: id(300), name: "Ski weekend", currency: "CHF", members: [ben, chloe, leo])
        ski.expenses = [
            Expense(id: id(301), title: "Chalet", amount: 540, payer: chloe.id, date: day(14, 2), portions: equal([ben, chloe, leo])),
        ]
        return [lisbon, flat, ski]
    }
}

// MARK: - Icon

//: a gold coin cut cleanly in two, its halves drifting apart on a mint tile

func appIcon() -> NSBitmapImageRep {
    render(0x3DDC97, 0x1E9E8A) { ctx in
        let r: CGFloat = 238
        let cut: CGFloat = -62 * .pi / 180 // Direction of the cut line, steep from upper left to lower right.
        let normal = CGPoint(x: cos(cut + .pi / 2), y: sin(cut + .pi / 2))
        let center = CGPoint(x: 512, y: 520)

        // Soft glow in the gap.
        radial([NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)], center: center, radius: 300, in: ctx)

        func half(_ side: CGFloat, tilt: CGFloat) {
            let drift: CGFloat = 58
            let c = CGPoint(x: center.x + normal.x * drift * side, y: center.y + normal.y * drift * side)
            // Semicircle on one side of the cut, in a frame where the cut runs along the y axis.
            func shape(in ctx: CGContext) {
                ctx.move(to: CGPoint(x: 0, y: -r))
                ctx.addArc(center: .zero, radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: side > 0)
                ctx.closePath()
            }
            ctx.saveGState()
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: tilt * .pi / 180)

            // Coin thickness, with the drop shadow.
            ctx.saveGState()
            shadow(ctx, y: -22, blur: 34, alpha: 0.34)
            ctx.translateBy(x: 0, y: -24)
            ctx.rotate(by: cut - .pi / 2)
            shape(in: ctx)
            ctx.setFillColor(rgb(0xB9791A).cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.translateBy(x: 0, y: -24)
            ctx.rotate(by: cut - .pi / 2)
            shape(in: ctx)
            ctx.clip()
            ctx.rotate(by: -(cut - .pi / 2))
            gradient([rgb(0xC98A22), rgb(0x9A5F10)], from: CGPoint(x: -r, y: 0), to: CGPoint(x: r, y: 0), in: ctx)
            ctx.restoreGState()

            // The face.
            ctx.saveGState()
            ctx.rotate(by: cut - .pi / 2)
            shape(in: ctx)
            ctx.clip()
            ctx.rotate(by: -(cut - .pi / 2))
            gradient([rgb(0xFFE89A), rgb(0xF7C548), rgb(0xE9A12C)], from: CGPoint(x: -r * 0.6, y: r), to: CGPoint(x: r * 0.6, y: -r), in: ctx)
            radial([NSColor.white.withAlphaComponent(0.55), NSColor.white.withAlphaComponent(0)],
                   center: CGPoint(x: -r * 0.35, y: r * 0.45), radius: r * 0.75, in: ctx)
            // Raised rim: a dark groove with a light edge just inside it.
            ctx.setLineWidth(16)
            ctx.setStrokeColor(rgb(0xC7871F, 0.75).cgColor)
            ctx.addEllipse(in: CGRect(x: -r * 0.78, y: -r * 0.78, width: r * 1.56, height: r * 1.56))
            ctx.strokePath()
            ctx.setLineWidth(6)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
            ctx.addEllipse(in: CGRect(x: -r * 0.78 - 9, y: -r * 0.78 - 7, width: r * 1.56 + 18, height: r * 1.56 + 18))
            ctx.strokePath()
            // Embossed centre: a smaller disc, lit from the top left.
            let inner = CGRect(x: -r * 0.42, y: -r * 0.42, width: r * 0.84, height: r * 0.84)
            ctx.saveGState()
            ctx.addEllipse(in: inner)
            ctx.clip()
            gradient([rgb(0xE5A030), rgb(0xFFDC7A)], from: CGPoint(x: -r * 0.3, y: r * 0.3), to: CGPoint(x: r * 0.3, y: -r * 0.3), in: ctx)
            ctx.restoreGState()
            ctx.setLineWidth(5)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
            ctx.addArc(center: .zero, radius: r * 0.42, startAngle: .pi * 0.15, endAngle: .pi * 1.05, clockwise: true)
            ctx.strokePath()
            // Outer edge highlight.
            ctx.setLineWidth(8)
            ctx.setStrokeColor(rgb(0xFFF3C4, 0.9).cgColor)
            ctx.addArc(center: .zero, radius: r - 4, startAngle: .pi * 0.2, endAngle: .pi * 0.95, clockwise: false)
            ctx.strokePath()
            ctx.restoreGState()

            // The clean cut face catching the light.
            ctx.saveGState()
            ctx.rotate(by: cut - .pi / 2)
            ctx.setLineWidth(6)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(side > 0 ? 0.75 : 0.35).cgColor)
            ctx.move(to: CGPoint(x: 0, y: -r + 6))
            ctx.addLine(to: CGPoint(x: 0, y: r - 6))
            ctx.strokePath()
            ctx.restoreGState()

            ctx.restoreGState()
        }
        half(-1, tilt: 5)
        half(1, tilt: -5)

        sparkle(ctx, at: CGPoint(x: 512 + normal.x * 4 + 150, y: 520 + 300), size: 34, color: NSColor.white.withAlphaComponent(0.9))
        sparkle(ctx, at: CGPoint(x: 512 - 170, y: 520 - 300), size: 22, color: NSColor.white.withAlphaComponent(0.7))
    }
}
