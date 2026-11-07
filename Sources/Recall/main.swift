import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(MainActor.assumeIsolated { SelfTest.run() }) }
Desktop.handleSnapshot(title: "Recall", size: CGSize(width: 980, height: 640)) {
    MainActor.assumeIsolated { ContentView(model: .demo) }
}
RecallApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A single library window, like Calculator: closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// CSV or TSV files opened from Finder are imported as decks.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { RecallModel.receive(urls) }
    }
}

struct RecallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RecallModel()

    var body: some Scene {
        Window("Recall", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified)
        .commands {
            AppHelpCommands(name: "Recall")
            RecallCommands(model: model)
        }
        Settings { SettingsView(model: model) }
    }
}

struct RecallCommands: Commands {
    @ObservedObject var model: RecallModel

    private var studying: Bool { model.session != nil }
    private var inProgress: Bool { model.session.map { !$0.finished } == true }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Card") { model.addCard() }
                .keyboardShortcut("n")
                .disabled(model.deck == nil || studying)
            Button("New Deck") { model.newDeck() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(studying)
            Divider()
            Button("Import\u{2026}") { model.openImportPanel() }
                .keyboardShortcut("o")
                .disabled(studying)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export Deck as CSV\u{2026}") { model.exportDeck() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.deck == nil || studying)
            Divider()
            Button("Rename Deck\u{2026}") { model.renaming = model.deck }
                .disabled(model.deck == nil || studying)
            Button("Delete Deck\u{2026}") { model.deckToDelete = model.deck }
                .disabled(model.deck == nil || studying)
        }
        CommandMenu("Card") {
            Button("Edit Card\u{2026}") { if let id = model.selectedCards.first { model.edit(id) } }
                .keyboardShortcut("e")
                .disabled(model.selectedCards.count != 1 || studying)
            Button("Reset Progress") { model.reset(model.selectedCards) }
                .disabled(model.selectedCards.isEmpty || studying)
            Divider()
            Button("Delete") { model.delete(model.selectedCards) }
                .keyboardShortcut(.delete)
                .disabled(model.selectedCards.isEmpty || studying)
        }
        CommandMenu("Study") {
            Button("Study Now") { model.startStudy() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStudy)
            Divider()
            Button("Show Answer") { model.reveal() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!inProgress || model.session?.revealed == true)
            ForEach(Grade.allCases) { grade in
                Button(grade.title) { model.answer(grade) }
                    .keyboardShortcut(grade.key, modifiers: [])
                    .disabled(!inProgress || model.session?.revealed != true)
            }
            Divider()
            Button("End Session") { model.endSession() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!studying)
        }
    }
}

// MARK: - Demo

extension RecallModel {
    /// Fixed sample decks with a month of history, for the website screenshot.
    static var demo: RecallModel {
        let now = Date()
        let day: TimeInterval = 86_400
        func deck(_ name: String, _ pairs: [(String, String)], seed: Int) -> Deck {
            var d = Deck(name: name)
            let intervals = [1, 3, 6, 15, 24, 40, 2, 9, 31, 4]
            let offsets = [0, 0, 1, 0, 3, 5, -1, 2, 12, 0, 7, 0, 4]
            for (i, pair) in pairs.enumerated() {
                var c = Card(front: pair.0, back: pair.1, created: now.addingTimeInterval(-60 * day + Double(i) * 60))
                if (i + seed) % 6 != 5 {
                    c.interval = intervals[(i + seed) % intervals.count]
                    c.reps = c.interval > 3 ? 3 : 1
                    c.ease = [2.5, 2.36, 2.65, 2.2, 2.5][(i + seed) % 5]
                    c.lapses = (i + seed) % 7 == 0 ? 1 : 0
                    c.reviewed = now.addingTimeInterval(-Double(c.interval) * day)
                    c.due = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(offsets[(i + seed) % offsets.count]) * day)
                }
                d.cards.append(c)
            }
            return d
        }
        let spanish = deck("Spanish verbs", [
            ("ser", "to be (essence)\n*soy, eres, es*"), ("estar", "to be (state, place)\n*estoy, estás, está*"),
            ("tener", "to have\n*tengo, tienes, tiene*"), ("hacer", "to do, to make\n*hago, haces, hace*"),
            ("poder", "to be able to\n*puedo, puedes, puede*"), ("decir", "to say, to tell\n*digo, dices, dice*"),
            ("ir", "to go\n*voy, vas, va*"), ("ver", "to see\n*veo, ves, ve*"), ("dar", "to give\n*doy, das, da*"),
            ("saber", "to know (facts)\n*sé, sabes, sabe*"), ("querer", "to want, to love\n*quiero, quieres, quiere*"),
            ("llegar", "to arrive"), ("pasar", "to pass, to happen"), ("deber", "to owe, must"), ("poner", "to put\n*pongo, pones, pone*"),
            ("parecer", "to seem"), ("quedar", "to stay, to remain"), ("creer", "to believe"), ("hablar", "to speak"),
            ("llevar", "to carry, to wear"), ("dejar", "to leave, to let"), ("seguir", "to follow, to continue"),
            ("encontrar", "to find"), ("llamar", "to call"), ("venir", "to come\n*vengo, vienes, viene*"), ("pensar", "to think"),
            ("salir", "to go out\n*salgo, sales, sale*"), ("volver", "to return"), ("tomar", "to take, to drink"),
            ("conocer", "to know (people, places)\n*conozco, conoces, conoce*"), ("vivir", "to live"), ("sentir", "to feel"),
            ("tratar", "to try, to treat"), ("mirar", "to look at"), ("contar", "to count, to tell"), ("empezar", "to begin"),
        ], seed: 0)
        let capitals = deck("World capitals", [
            ("Australia", "Canberra"), ("Canada", "Ottawa"), ("Brazil", "Brasília"), ("Turkey", "Ankara"), ("Morocco", "Rabat"),
            ("New Zealand", "Wellington"), ("Switzerland", "Bern"), ("Vietnam", "Hanoi"), ("Nigeria", "Abuja"), ("Kazakhstan", "Astana"),
            ("Myanmar", "Naypyidaw"), ("Bolivia", "Sucre (constitutional), La Paz (seat of government)"), ("Sri Lanka", "Sri Jayawardenepura Kotte"),
            ("Tanzania", "Dodoma"), ("Pakistan", "Islamabad"), ("Mongolia", "Ulaanbaatar"), ("Iceland", "Reykjavík"), ("Peru", "Lima"),
        ], seed: 2)
        let chemistry = deck("Organic chemistry", [
            ("Functional group of an **alcohol**", "Hydroxyl, `-OH`"), ("Functional group of a **ketone**", "Carbonyl inside the chain, `C=O`"),
            ("SN2 stereochemistry", "Inversion of configuration (Walden inversion)"), ("Markovnikov's rule", "H adds to the carbon with *more* hydrogens"),
            ("Hybridisation of carbon in ethyne", "sp, linear, 180°"), ("Aromatic ring rule", "Hückel: 4n + 2 π electrons"),
            ("Strongest intermolecular force in water", "Hydrogen bonding"), ("Chiral centre", "A carbon with four different groups"),
        ], seed: 4)
        let swift = deck("Swift concurrency", [
            ("What does `await` mark?", "A possible suspension point"), ("`@MainActor`", "Isolates code to the main thread's actor"),
            ("`Sendable`", "A type that is safe to share across concurrency domains"), ("`Task.detached`", "A task that inherits no actor or priority"),
            ("`async let`", "Starts a child task that runs in parallel and is awaited later"), ("Actor reentrancy", "State may change across every `await` inside an actor"),
        ], seed: 1)
        var library = Library(decks: [spanish, capitals, chemistry, swift])
        // A month of review history so retention has something to say.
        for n in 0..<260 {
            let d = library.decks[n % library.decks.count]
            let card = d.cards[(n * 7) % d.cards.count]
            let grade: Grade = n % 9 == 0 ? .again : n % 5 == 0 ? .hard : n % 4 == 0 ? .easy : .good
            library.reviews.append(Review(cardID: card.id, deckID: d.id, date: now.addingTimeInterval(-Double(n % 29 + 1) * day),
                                          grade: grade, wasNew: false))
        }
        let model = RecallModel(library: library, persists: false, now: now)
        model.selection = spanish.id
        return model
    }
}

// MARK: - Icon

//: two stacked cards, the top one caught mid-flip with a lightbulb on its face

func appIcon() -> NSBitmapImageRep {
    render(0xFFC83D, 0xE58A00) { ctx in
        // Warm glow behind the cards.
        radial([NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)],
               center: CGPoint(x: 560, y: 560), radius: 420, in: ctx)

        // The card underneath, lying flat and tilted.
        ctx.saveGState()
        ctx.translateBy(x: 470, y: 470)
        ctx.rotate(by: -10 * .pi / 180)
        let under = CGRect(x: -210, y: -270, width: 420, height: 540)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.30)
        ctx.addPath(roundedRect(under, 48))
        ctx.setFillColor(rgb(0xFFF6E0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(under, 48))
        ctx.clip()
        gradient([rgb(0xFFFBF0), rgb(0xFBE6B8)], from: CGPoint(x: 0, y: under.maxY), to: CGPoint(x: 0, y: under.minY), in: ctx)
        ctx.setStrokeColor(rgb(0xE9C98A).cgColor)
        ctx.setLineWidth(18)
        ctx.setLineCap(.round)
        for (i, w) in ([240, 300, 190] as [CGFloat]).enumerated() {
            let y = under.minY + 70 + CGFloat(i) * 52
            ctx.move(to: CGPoint(x: under.minX + 60, y: y))
            ctx.addLine(to: CGPoint(x: under.minX + 60 + w, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // The top card, turning about its left edge: the right edge recedes, so it is shorter and closer.
        let l = CGPoint(x: 330, y: 220), lt = CGPoint(x: 330, y: 820)
        let r = CGPoint(x: 740, y: 290), rt = CGPoint(x: 740, y: 760)
        let face = CGMutablePath()
        let k: CGFloat = 44
        face.move(to: CGPoint(x: l.x, y: l.y + k))
        face.addQuadCurve(to: CGPoint(x: l.x + k, y: l.y + k * 0.14), control: l)
        face.addLine(to: CGPoint(x: r.x - k * 0.8, y: r.y - k * 0.05))
        face.addQuadCurve(to: CGPoint(x: r.x, y: r.y + k * 0.8), control: r)
        face.addLine(to: CGPoint(x: rt.x, y: rt.y - k * 0.8))
        face.addQuadCurve(to: CGPoint(x: rt.x - k * 0.8, y: rt.y + k * 0.05), control: rt)
        face.addLine(to: CGPoint(x: lt.x + k, y: lt.y - k * 0.14))
        face.addQuadCurve(to: CGPoint(x: lt.x, y: lt.y - k), control: lt)
        face.closeSubpath()

        ctx.saveGState()
        shadow(ctx, y: -26, blur: 46, alpha: 0.34)
        ctx.addPath(face)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(face)
        ctx.clip()
        // Light falls off as the face turns away.
        gradient([rgb(0xFFFFFF), rgb(0xF4EEE2)], from: CGPoint(x: l.x, y: 0), to: CGPoint(x: r.x, y: 0), in: ctx)
        // Thickness of the card along the left edge.
        ctx.setFillColor(rgb(0xE8DCC4).cgColor)
        ctx.fill(CGRect(x: l.x, y: l.y, width: 10, height: lt.y - l.y))
        ctx.restoreGState()

        // The lightbulb, squeezed horizontally to sit on the turning face.
        ctx.saveGState()
        ctx.translateBy(x: 545, y: 540)
        ctx.concatenate(CGAffineTransform(a: 0.86, b: 0.035, c: 0, d: 1, tx: 0, ty: 0))
        radial([rgb(0xFFD54A, 0.55), rgb(0xFFD54A, 0)], center: CGPoint(x: 0, y: 60), radius: 230, in: ctx)
        // Glass: a circle that narrows into a neck.
        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: -58, y: -70))
        glass.addCurve(to: CGPoint(x: -118, y: 70), control1: CGPoint(x: -60, y: -20), control2: CGPoint(x: -118, y: 10))
        glass.addArc(center: CGPoint(x: 0, y: 70), radius: 118, startAngle: .pi, endAngle: 0, clockwise: true)
        glass.addCurve(to: CGPoint(x: 58, y: -70), control1: CGPoint(x: 118, y: 10), control2: CGPoint(x: 60, y: -20))
        glass.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 16, alpha: 0.22)
        ctx.addPath(glass)
        ctx.setFillColor(rgb(0xFFC83D).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(glass)
        ctx.clip()
        gradient([rgb(0xFFE27A), rgb(0xF7A21B)], from: CGPoint(x: 0, y: 190), to: CGPoint(x: 0, y: -70), in: ctx)
        ctx.restoreGState()
        // Highlight on the glass.
        ctx.addEllipse(in: CGRect(x: -78, y: 92, width: 46, height: 70))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.fillPath()
        // Filament.
        ctx.setStrokeColor(rgb(0xB85F00).cgColor)
        ctx.setLineWidth(11)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: -26, y: -66))
        ctx.addLine(to: CGPoint(x: -26, y: 30))
        ctx.addCurve(to: CGPoint(x: 26, y: 30), control1: CGPoint(x: -26, y: 72), control2: CGPoint(x: 26, y: 72))
        ctx.addLine(to: CGPoint(x: 26, y: -66))
        ctx.strokePath()
        // Screw base.
        for i in 0..<3 {
            let y = -96 - CGFloat(i) * 30
            ctx.addPath(roundedRect(CGRect(x: -62 + CGFloat(i) * 4, y: y, width: 124 - CGFloat(i) * 8, height: 24), 12))
            ctx.setFillColor(rgb(i == 1 ? 0x8A8F99 : 0x6B707A).cgColor)
            ctx.fillPath()
        }
        ctx.addPath(roundedRect(CGRect(x: -28, y: -176, width: 56, height: 22), 11))
        ctx.setFillColor(rgb(0x4B505A).cgColor)
        ctx.fillPath()
        // Rays.
        ctx.setStrokeColor(rgb(0xF29A00).cgColor)
        ctx.setLineWidth(16)
        for angle: CGFloat in [90, 135, 45, 180, 0] {
            let a = angle * .pi / 180
            ctx.move(to: CGPoint(x: cos(a) * 150, y: 70 + sin(a) * 150))
            ctx.addLine(to: CGPoint(x: cos(a) * 192, y: 70 + sin(a) * 192))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // A motion arc over the top: the flip.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(20)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let center = CGPoint(x: 545, y: 450)
        let radius: CGFloat = 420
        let start: CGFloat = 110 * .pi / 180, end: CGFloat = 62 * .pi / 180
        ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
        let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
        // Arrowhead: two strokes back along the arc, opened by 38 degrees.
        let back = atan2(cos(end), -sin(end))
        for spread: CGFloat in [-0.66, 0.66] {
            ctx.move(to: tip)
            ctx.addLine(to: CGPoint(x: tip.x + 52 * cos(back + spread), y: tip.y + 52 * sin(back + spread)))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
