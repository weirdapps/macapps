import AppKit
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
Desktop.handleSnapshot(title: "orders.json", size: CGSize(width: 1080, height: 680)) { MainActor.assumeIsolated { ContentView(model: .demo) } }
CanopyApp.main()

final class AppDelegate: NSObject, NSApplicationDelegate {
    // A viewer, like Preview: closing the last window keeps the app ready for the next file.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// `Canopy data.json more.json` from Terminal opens those files, like Open With in Finder does.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let urls = CommandLineFiles.urls(CommandLine.arguments)
        guard !urls.isEmpty, !Desktop.isSnapshot else { return }
        MainActor.assumeIsolated { Router.shared.open(urls) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { Router.shared.open(urls) }
    }
}

struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup(id: "viewer", for: URL.self) { $url in
            ViewerWindow(url: $url)
        }
        .defaultSize(width: 1080, height: 680)
        .windowToolbarStyle(.unified)
        .commands { CanopyCommands() }
    }
}

enum Theme {
    static let top: UInt32 = 0x6DD47E
    static let bottom: UInt32 = 0x1F8A5B
    static let accent = Color(nsColor: rgb(0x22995F))
    static let gradient = LinearGradient(colors: [Color(nsColor: rgb(top)), Color(nsColor: rgb(bottom))], startPoint: .top, endPoint: .bottom)
    /// Object keys in the text view and object badges: the leaf green, lighter in dark mode.
    static let keyColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0x6DD47E) : rgb(0x1C7F52) }
    static let highlight = NSColor(srgbRed: 1, green: 0.84, blue: 0.2, alpha: 0.75)
    static let currentMatch = NSColor(srgbRed: 1, green: 0.62, blue: 0.1, alpha: 1)
}

// MARK: - Menus

struct CanopyCommands: Commands {
    @FocusedObject private var model: ViewerModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "viewer") }
                .keyboardShortcut("n")
            Button("Open…") { Router.shared.showOpenPanel(preferring: model) }
                .keyboardShortcut("o")
            RecentMenu(model: model)
            Divider()
            Button("Open from Clipboard") { model?.pasteFromClipboard() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(model == nil)
        }
        CommandGroup(after: .saveItem) {
            Button("Export Pretty JSON…") { model?.exportPretty() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model?.hasDocument != true)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Value") { model?.copyValue() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy JSONPath") { model?.copyJSONPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy jq Path") { model?.copyJQPath() }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
        }
        CommandGroup(replacing: .textEditing) {
            Button("Find…") { model?.focusSearch += 1 }
                .keyboardShortcut("f")
            Button("Find Next") { model?.findNext() }
                .keyboardShortcut("g")
            Button("Find Previous") { model?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button("Tree") { model?.mode = .tree }
                .keyboardShortcut("1")
            Button("Text") { model?.mode = .text }
                .keyboardShortcut("2")
            Divider()
            Button("Expand All") { model?.expandAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Collapse All") { model?.collapseAll() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Menu("Expand to Level") {
                ForEach(1...5, id: \.self) { level in
                    Button("Level \(level)") { model?.expand(toLevel: level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")), modifiers: [.command, .control])
                }
            }
            Divider()
            Button(model?.showInspector == false ? "Show Inspector" : "Hide Inspector") {
                withAnimation(.snappy) { model?.showInspector.toggle() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
        }
        AppHelpCommands(name: "Canopy")
    }
}

private struct RecentMenu: View {
    let model: ViewerModel?
    @State private var recents = Recents.all

    var body: some View {
        Menu("Open Recent") {
            ForEach(recents, id: \.self) { url in
                Button(url.lastPathComponent) { Router.shared.open([url], preferring: model) }
            }
            if !recents.isEmpty { Divider() }
            Button("Clear Menu") { Recents.clear() }.disabled(recents.isEmpty)
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in recents = Recents.all }
    }
}

// MARK: - Demo

extension ViewerModel {
    static let demoJSON = """
    {
      "store": "Canopy Coffee Roasters",
      "generated": "2026-11-07T08:30:00Z",
      "currency": "EUR",
      "orders": [
        { "id": 10421, "status": "shipped", "customer": { "name": "Ada Lovelace", "email": "ada@example.com", "vip": true },
          "items": [ { "sku": "ETH-250", "name": "Ethiopia Guji", "qty": 2, "price": 14.5 } ], "total": 29.0, "coupon": null },
        { "id": 10422, "status": "pending", "customer": { "name": "Grace Hopper", "email": "grace@example.com", "vip": false },
          "items": [ { "sku": "COL-1K", "name": "Colombia Huila", "qty": 1, "price": 38.0 },
                     { "sku": "KEN-250", "name": "Kenya Nyeri AA", "qty": 3, "price": 16.0 } ],
          "total": 86.0, "coupon": "AUTUMN10" },
        { "id": 10423, "status": "pending", "customer": { "name": "Alan Turing", "email": "alan@example.com", "vip": false },
          "items": [ { "sku": "BRA-500", "name": "Brazil Cerrado", "qty": 1, "price": 21.0 } ], "total": 21.0, "coupon": null },
        { "id": 10424, "status": "delivered", "customer": { "name": "Katherine Johnson", "email": "kj@example.com", "vip": true },
          "items": [ { "sku": "GUA-250", "name": "Guatemala Huehue", "qty": 2, "price": 15.0 } ], "total": 30.0, "coupon": null },
        { "id": 10425, "status": "refunded", "customer": { "name": "Linus Pauling", "email": "linus@example.com", "vip": false },
          "items": [], "total": 0, "coupon": null }
      ],
      "page": { "number": 1, "size": 50, "hasMore": true }
    }
    """

    /// Fixed sample data for the website screenshot: an order list with a search for "pending" under way.
    static var demo: ViewerModel {
        let model = ViewerModel()
        let tree = try! JSONParser.parse(Array(demoJSON.utf8))
        model.install(tree, name: "orders.json", url: nil)
        let orders = tree.childIDs(0).first { tree.key($0) == "orders" }!
        let second = tree.child(orders, 1)
        let items = tree.childIDs(second).first { tree.key($0) == "items" }!
        let customer = tree.childIDs(second).first { tree.key($0) == "customer" }!
        model.initialExpansion = .nodes([0, orders, second, customer, items, tree.child(items, 0)])
        model.query = "pending"
        return model
    }
}

// MARK: - Icon

/// A tree whose branches end in leaves, each leaf a pair of curly braces.
func appIcon() -> NSBitmapImageRep {
    render(Theme.top, Theme.bottom) { ctx in
        let cream = rgb(0xFFFBEF)
        // Ground glow under the trunk.
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 184)
        ctx.scaleBy(x: 1, y: 0.28)
        radial([NSColor.black.withAlphaComponent(0.22), NSColor.black.withAlphaComponent(0)], center: .zero, radius: 210, in: ctx)
        ctx.restoreGState()

        // Trunk and branches.
        let base = CGPoint(x: 512, y: 190)
        let fork = CGPoint(x: 512, y: 420)
        let trunkTop = CGPoint(x: 512, y: 396)
        let tips: [(CGPoint, CGFloat)] = [
            (CGPoint(x: 300, y: 596), -40), (CGPoint(x: 724, y: 596), 40), (CGPoint(x: 512, y: 712), 0),
        ]
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 22, alpha: 0.28)
        ctx.setStrokeColor(cream.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(64)
        ctx.move(to: base); ctx.addLine(to: trunkTop)
        ctx.strokePath()
        ctx.setLineWidth(42)
        for (tip, _) in tips {
            ctx.move(to: CGPoint(x: fork.x, y: fork.y - 20))
            ctx.addQuadCurve(to: tip, control: CGPoint(x: tip.x, y: fork.y + 20))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Leaves pointing along their branch, each holding an upright brace pair.
        for (tip, angle) in tips {
            let r: CGFloat = angle == 0 ? 134 : 120
            ctx.saveGState()
            ctx.translateBy(x: tip.x, y: tip.y)
            ctx.saveGState()
            ctx.rotate(by: -angle * .pi / 180)
            let leaf = leafPath(radius: r)
            ctx.saveGState()
            shadow(ctx, y: -12, blur: 26, alpha: 0.3)
            ctx.addPath(leaf)
            ctx.setFillColor(cream.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(leaf)
            ctx.clip()
            gradient([rgb(0xFFFFFF), rgb(0xE2F3E0)], from: CGPoint(x: 0, y: r), to: CGPoint(x: 0, y: -r), in: ctx)
            ctx.restoreGState()
            ctx.setStrokeColor(rgb(0x1F8A5B).cgColor)
            ctx.setLineWidth(r * 0.16)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(brace(center: CGPoint(x: -r * 0.3, y: 0), height: r * 0.96, width: r * 0.36, flipped: false))
            ctx.addPath(brace(center: CGPoint(x: r * 0.3, y: 0), height: r * 0.96, width: r * 0.36, flipped: true))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}

/// A leaf: a circle drawn to a point at the top, centred on the origin.
private func leafPath(radius r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 0, y: r * 1.22))
    p.addCurve(to: CGPoint(x: r, y: -r * 0.05), control1: CGPoint(x: r * 0.42, y: r * 1.1), control2: CGPoint(x: r, y: r * 0.6))
    p.addCurve(to: CGPoint(x: 0, y: -r), control1: CGPoint(x: r, y: -r * 0.6), control2: CGPoint(x: r * 0.56, y: -r))
    p.addCurve(to: CGPoint(x: -r, y: -r * 0.05), control1: CGPoint(x: -r * 0.56, y: -r), control2: CGPoint(x: -r, y: -r * 0.6))
    p.addCurve(to: CGPoint(x: 0, y: r * 1.22), control1: CGPoint(x: -r, y: r * 0.6), control2: CGPoint(x: -r * 0.42, y: r * 1.1))
    p.closeSubpath()
    return p
}

/// An opening curly brace, or a closing one when `flipped`.
private func brace(center c: CGPoint, height h: CGFloat, width w: CGFloat, flipped: Bool) -> CGPath {
    let s: CGFloat = flipped ? -1 : 1
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: c.x + s * x, y: c.y + y) }
    p.move(to: pt(w / 2, h / 2))
    p.addQuadCurve(to: pt(0, h / 2 - w / 2), control: pt(0, h / 2))
    p.addLine(to: pt(0, w / 2))
    p.addQuadCurve(to: pt(-w / 2, 0), control: pt(0, 0))
    p.addQuadCurve(to: pt(0, -w / 2), control: pt(0, 0))
    p.addLine(to: pt(0, -h / 2 + w / 2))
    p.addQuadCurve(to: pt(w / 2, -h / 2), control: pt(0, -h / 2))
    return p
}
