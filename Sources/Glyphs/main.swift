import AppKit
import Carbon.HIToolbox
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    private var hotKey: HotKey?
    let model = GlyphModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "character", accessibilityLabel: "Glyphs") {
            GlyphsView().environmentObject(self.model)
        }
        hotKey = HotKey(keyCode: kVK_ANSI_G, modifiers: cmdKey | optionKey) { [weak self] in self?.status.toggle() }
    }
}

// MARK: - Data

struct Glyph: Identifiable, Hashable {
    let char: String
    let name: String
    var id: String { char }
}

struct Category: Identifiable {
    let name: String
    let symbol: String
    let glyphs: [Glyph]
    var id: String { name }
}

enum Catalog {
    /// Friendlier names where the Unicode name is obscure, and extra search words.
    static let aliases: [String: String] = [
        "⌘": "command key", "⌥": "option key alt", "⇧": "shift key", "⌃": "control key", "⏎": "return key enter",
        "↩": "return key", "⌫": "delete key backspace", "⌦": "forward delete key", "⎋": "escape key esc",
        "⇥": "tab key", "⇤": "back tab key", "⇪": "caps lock key", "␣": "space key", "⏏": "eject key",
        "⇞": "page up key", "⇟": "page down key", "↖": "home key", "↘": "end key", "«": "guillemet left quote",
        "»": "guillemet right quote", "‹": "single guillemet left", "›": "single guillemet right", "…": "ellipsis dots",
        "•": "bullet", "·": "middle dot interpunct", "€": "euro", "£": "pound sterling", "¥": "yen yuan", "₿": "bitcoin",
        "₹": "rupee", "°": "degree", "™": "trademark", "©": "copyright", "®": "registered", "§": "section",
        "¶": "paragraph pilcrow", "√": "square root", "∞": "infinity", "≈": "approximately", "≠": "not equal",
        "≤": "less than or equal", "≥": "greater than or equal", "±": "plus minus", "×": "times multiply",
        "÷": "divide division", "−": "minus", "∆": "delta increment", "→": "right arrow", "←": "left arrow",
        "✓": "check tick", "✔": "check tick heavy", "✗": "cross x", "✘": "cross x heavy", "★": "star", "☆": "star outline",
        "♥": "heart", "‰": "per mille", "№": "numero number",
        "“": "left double quote", "”": "right double quote", "‘": "left single quote", "’": "right single quote apostrophe",
        "„": "low double quote", "‚": "low single quote",
    ]

    static func glyphs(_ chars: String) -> [Glyph] {
        chars.split(separator: " ").map { s in
            let char = String(s)
            let unicode = char.unicodeScalars.first?.properties.name?.lowercased() ?? ""
            let name = aliases[char].map { $0 + (unicode.isEmpty ? "" : " · " + unicode) } ?? unicode
            return Glyph(char: char, name: name)
        }
    }

    // Dash characters are left out on purpose: there is no en or em dash anywhere in this list.
    static let categories: [Category] = [
        Category(name: "Arrows", symbol: "arrow.left.arrow.right",
                 glyphs: glyphs("← → ↑ ↓ ↔ ↕ ↖ ↗ ↘ ↙ ⇐ ⇒ ⇑ ⇓ ⇔ ⇕ ⟵ ⟶ ⟷ ⟸ ⟹ ➜ ➔ ➝ ↩ ↪ ⤴ ⤵ ↻ ↺ ⇄ ⇆ ⇵ ⇅")),
        Category(name: "Maths", symbol: "function",
                 glyphs: glyphs("± × ÷ − ≠ ≈ ≡ ≤ ≥ ≪ ≫ ∞ √ ∛ ∑ ∏ ∫ ∂ ∆ ∇ ∈ ∉ ∩ ∪ ⊂ ⊃ ⊆ ⊇ ∀ ∃ ∅ ∝ ∠ ⊥ ∥ ° ′ ″ % ‰ ¬ ∧ ∨ ⊕ ⊗ ∴ ∵ π")),
        Category(name: "Currency", symbol: "dollarsign",
                 glyphs: glyphs("€ £ ¥ $ ¢ ₹ ₽ ₩ ₺ ₪ ₫ ₱ ₦ ₿ ฿ ₴ ₸ ₡ ₲ ₵ ₼ ₾ ¤")),
        Category(name: "Punctuation", symbol: "quote.opening",
                 glyphs: glyphs("« » ‹ › “ ” ‘ ’ „ ‚ … • · ‣ ¡ ¿ ‽ § ¶ † ‡ © ® ™ ℗ № ℅ ※ ⁂ ′ ″ ‖ ¦ ⁄")),
        Category(name: "Greek", symbol: "textformat.alt",
                 glyphs: glyphs("Α Β Γ Δ Ε Ζ Η Θ Ι Κ Λ Μ Ν Ξ Ο Π Ρ Σ Τ Υ Φ Χ Ψ Ω α β γ δ ε ζ η θ ι κ λ μ ν ξ ο π ρ σ ς τ υ φ χ ψ ω")),
        Category(name: "Keyboard", symbol: "command",
                 glyphs: glyphs("⌘ ⌥ ⇧ ⌃ ⏎ ↩ ⌫ ⌦ ⎋ ⇥ ⇤ ⇪ ␣ ⏏ ⇞ ⇟ ↖ ↘ ◀︎ ▶︎ ▲ ▼")),
        Category(name: "Fractions", symbol: "divide",
                 glyphs: glyphs("½ ⅓ ⅔ ¼ ¾ ⅕ ⅖ ⅗ ⅘ ⅙ ⅚ ⅐ ⅛ ⅜ ⅝ ⅞ ⅑ ⅒ ↉")),
        Category(name: "Super & Sub", symbol: "textformat.superscript",
                 glyphs: glyphs("⁰ ¹ ² ³ ⁴ ⁵ ⁶ ⁷ ⁸ ⁹ ⁺ ⁻ ⁼ ⁽ ⁾ ⁿ ⁱ ₀ ₁ ₂ ₃ ₄ ₅ ₆ ₇ ₈ ₉ ₊ ₋ ₌ ₍ ₎ ₐ ₑ ₒ ₓ")),
        Category(name: "Symbols", symbol: "star",
                 glyphs: glyphs("★ ☆ ✓ ✔ ✗ ✘ ● ○ ◆ ◇ ■ □ ▲ △ ▼ ▽ ♥ ♦ ♣ ♠ ♪ ♫ ☀ ☁ ☂ ☎ ✉ ✂ ✎ ⚑ ⚠ ☯ ♻ ⚡ ✦ ✧ ❖")),
    ]

    static let all: [Glyph] = categories.flatMap(\.glyphs)

    static func search(_ query: String) -> [Glyph] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return all.filter { g in
            (g.char == q || q.split(separator: " ").allSatisfy { g.name.contains($0) }) && seen.insert(g.char).inserted
        }
    }
}

// MARK: - Model

@MainActor
final class GlyphModel: ObservableObject {
    @AppStorage("category") var category = "Arrows" { willSet { objectWillChange.send() } }
    @AppStorage("recent") private var recentStorage = "→ • … « » ⌘ € ½ ✓" { willSet { objectWillChange.send() } }
    @Published var query = ""
    @Published var hovered: Glyph?

    init() {
        // Screenshots use their own keys, so they show the defaults and never this Mac's recents.
        if StatusPopover.isSnapshot {
            _category = AppStorage(wrappedValue: "Arrows", "snapshot.category")
            _recentStorage = AppStorage(wrappedValue: "→ • … « » ⌘ € ½ ✓", "snapshot.recent")
        }
    }

    var recent: [Glyph] {
        recentStorage.split(separator: " ").compactMap { s in Catalog.all.first { $0.char == String(s) } }
    }

    var visible: [Glyph] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return Catalog.search(query) }
        return Catalog.categories.first { $0.name == category }?.glyphs ?? []
    }

    func copy(_ glyph: Glyph) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(glyph.char, forType: .string)
        var list = recentStorage.split(separator: " ").map(String.init).filter { $0 != glyph.char }
        list.insert(glyph.char, at: 0)
        recentStorage = list.prefix(9).joined(separator: " ")
        HUD.show(symbol: "doc.on.clipboard.fill", title: "Copied \(glyph.char)", tint: Color.glyphs[1])
    }
}

extension Color {
    static let glyphs = [Color(red: 1, green: 0.5, blue: 0.72), Color(red: 0.66, green: 0.12, blue: 0.62)]
}

// MARK: - Views

struct GlyphsView: View {
    @EnvironmentObject var model: GlyphModel
    @FocusState private var searchFocused: Bool
    private let columns = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("Search by name, like \u{201C}arrow\u{201D} or \u{201C}euro\u{201D}", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($searchFocused)
                    .onSubmit { if let first = model.visible.first { model.copy(first) } }
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if !model.recent.isEmpty && model.query.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18)
                    ForEach(model.recent) { glyph in
                        GlyphCell(glyph: glyph, size: 30, fontSize: 15)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            if model.query.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Catalog.categories) { cat in CategoryChip(category: cat) }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }
                .padding(.vertical, 8)
            } else {
                Spacer().frame(height: 8)
            }

            ScrollView {
                let glyphs = model.visible
                if glyphs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "character.magnify").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("No character is called \u{201C}\(model.query)\u{201D}.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    VStack(spacing: 4) {
                        ForEach(Array(stride(from: 0, to: glyphs.count, by: columns)), id: \.self) { start in
                            HStack(spacing: 4) {
                                ForEach(glyphs[start..<min(start + columns, glyphs.count)]) { glyph in
                                    GlyphCell(glyph: glyph, size: 40, fontSize: 20)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .frame(height: 232)

            HStack(spacing: 8) {
                if let g = model.hovered {
                    Text(g.char).font(.system(size: 15)).frame(minWidth: 18)
                    Text(g.name.capitalized).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(g.char.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                } else {
                    Text("Click a character to copy it.").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .frame(height: 30)
            .padding(.horizontal, 14)

            Divider().opacity(0.5)
            PanelFooter(name: "Glyphs", shortcut: "⌥⌘G") {
                ForEach(Catalog.categories) { cat in
                    Button(cat.name) { model.query = ""; model.category = cat.name }
                }
            }
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { searchFocused = true }
        }
    }
}

struct CategoryChip: View {
    @EnvironmentObject var model: GlyphModel
    let category: Category
    @State private var hovering = false

    var body: some View {
        let selected = model.category == category.name
        Button { withAnimation(.snappy) { model.category = category.name } } label: {
            HStack(spacing: 4) {
                Image(systemName: category.symbol).font(.system(size: 10, weight: .semibold))
                Text(category.name).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? .white : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(selected ? AnyShapeStyle(LinearGradient(colors: Color.glyphs, startPoint: .top, endPoint: .bottom))
                                                : AnyShapeStyle(.quaternary.opacity(hovering ? 0.7 : 0.4))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct GlyphCell: View {
    @EnvironmentObject var model: GlyphModel
    let glyph: Glyph
    let size: CGFloat
    let fontSize: CGFloat
    @State private var hovering = false

    var body: some View {
        Button { model.copy(glyph) } label: {
            Text(glyph.char)
                .font(.system(size: fontSize))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(hovering ? AnyShapeStyle(Color.glyphs[0].opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.3))))
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.1)) { hovering = h }
            if h { model.hovered = glyph } else if model.hovered == glyph { model.hovered = nil }
        }
        .help(glyph.name.capitalized)
    }
}

// MARK: - Icon

//: four keycaps holding an arrow, a star, a heart and an infinity sign

func appIcon() -> NSBitmapImageRep {
    render(0xFF8BC0, 0x9A1A94) { ctx in
        let size: CGFloat = 300, gap: CGFloat = 44
        let origin = CGPoint(x: 512 - size - gap / 2, y: 512 - size - gap / 2)
        let ink = rgb(0xA31F8F)
        for row in 0..<2 {
            for col in 0..<2 {
                let rect = CGRect(x: origin.x + CGFloat(col) * (size + gap), y: origin.y + CGFloat(row) * (size + gap), width: size, height: size)
                ctx.saveGState()
                shadow(ctx, y: -14, blur: 26, alpha: 0.3)
                ctx.addPath(roundedRect(rect, 70))
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
                ctx.saveGState()
                ctx.addPath(roundedRect(rect, 70))
                ctx.clip()
                gradient([rgb(0xFFFFFF), rgb(0xF6E3F1)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
                ctx.restoreGState()

                let c = CGPoint(x: rect.midX, y: rect.midY)
                ctx.saveGState()
                ctx.setFillColor(ink.cgColor)
                ctx.setStrokeColor(ink.cgColor)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                switch (row, col) {
                case (1, 0):
                    // Arrow.
                    ctx.setLineWidth(34)
                    ctx.move(to: CGPoint(x: c.x - 85, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 85, y: c.y))
                    ctx.move(to: CGPoint(x: c.x + 25, y: c.y + 62)); ctx.addLine(to: CGPoint(x: c.x + 88, y: c.y))
                    ctx.addLine(to: CGPoint(x: c.x + 25, y: c.y - 62))
                    ctx.strokePath()
                case (1, 1):
                    // Five-pointed star.
                    let star = CGMutablePath()
                    for i in 0..<10 {
                        let r: CGFloat = i % 2 == 0 ? 100 : 42
                        let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                        let p = CGPoint(x: c.x + cos(a) * r, y: c.y - 8 + sin(a) * r)
                        if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
                    }
                    star.closeSubpath()
                    ctx.addPath(star)
                    ctx.setLineWidth(14)
                    ctx.drawPath(using: .fillStroke)
                case (0, 0):
                    // Heart.
                    let heart = CGMutablePath()
                    heart.move(to: CGPoint(x: c.x, y: c.y - 82))
                    heart.addCurve(to: CGPoint(x: c.x - 90, y: c.y + 40), control1: CGPoint(x: c.x - 40, y: c.y - 40), control2: CGPoint(x: c.x - 90, y: c.y - 10))
                    heart.addArc(center: CGPoint(x: c.x - 46, y: c.y + 40), radius: 44, startAngle: .pi, endAngle: 0, clockwise: true)
                    heart.addArc(center: CGPoint(x: c.x + 46, y: c.y + 40), radius: 44, startAngle: .pi, endAngle: 0, clockwise: true)
                    heart.addCurve(to: CGPoint(x: c.x, y: c.y - 82), control1: CGPoint(x: c.x + 90, y: c.y - 10), control2: CGPoint(x: c.x + 40, y: c.y - 40))
                    ctx.addPath(heart)
                    ctx.setFillColor(rgb(0xFF4F8B).cgColor)
                    ctx.fillPath()
                default:
                    // Infinity, as a figure eight on its side.
                    ctx.setLineWidth(30)
                    let w: CGFloat = 52
                    ctx.move(to: c)
                    ctx.addCurve(to: CGPoint(x: c.x - 2 * w, y: c.y), control1: CGPoint(x: c.x - w * 0.6, y: c.y + w * 1.1), control2: CGPoint(x: c.x - 2 * w, y: c.y + w * 1.1))
                    ctx.addCurve(to: c, control1: CGPoint(x: c.x - 2 * w, y: c.y - w * 1.1), control2: CGPoint(x: c.x - w * 0.6, y: c.y - w * 1.1))
                    ctx.addCurve(to: CGPoint(x: c.x + 2 * w, y: c.y), control1: CGPoint(x: c.x + w * 0.6, y: c.y + w * 1.1), control2: CGPoint(x: c.x + 2 * w, y: c.y + w * 1.1))
                    ctx.addCurve(to: c, control1: CGPoint(x: c.x + 2 * w, y: c.y - w * 1.1), control2: CGPoint(x: c.x + w * 0.6, y: c.y - w * 1.1))
                    ctx.strokePath()
                }
                ctx.restoreGState()
            }
        }
    }
}
