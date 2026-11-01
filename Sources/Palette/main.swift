import AppKit
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
    let store = PaletteStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "swatchpalette", accessibilityLabel: "Palette") {
            PaletteView().environmentObject(self.store)
        }
    }
}

// MARK: - Colour maths

/// An sRGB colour with components in 0...1.
struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// From hue in degrees, saturation and lightness in 0...1.
    init(h: Double, s: Double, l: Double) {
        let h = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double) = switch h {
        case ..<60: (c, x, 0)
        case ..<120: (x, c, 0)
        case ..<180: (0, c, x)
        case ..<240: (0, x, c)
        case ..<300: (x, 0, c)
        default: (c, 0, x)
        }
        self.init(r: r + m, g: g + m, b: b + m)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), l = (mx + mn) / 2, d = mx - mn
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        switch mx {
        case r: h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        case g: h = (b - r) / d + 2
        default: h = (r - g) / d + 4
        }
        h *= 60
        return (h < 0 ? h + 360 : h, s, l)
    }

    var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    func rotated(_ degrees: Double) -> RGB {
        let v = hsl
        return RGB(h: v.h + degrees, s: v.s, l: v.l)
    }

    /// Linear mix toward `other` by `t` in 0...1.
    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t)
    }
}

enum Harmony: String, CaseIterable, Identifiable {
    case complementary = "Complementary", analogous = "Analogous", triadic = "Triadic", tetradic = "Tetradic"
    case shades = "Shades", tints = "Tints"
    var id: String { rawValue }

    func colors(from base: RGB) -> [RGB] {
        switch self {
        case .complementary: [base, base.rotated(180)]
        case .analogous: [base.rotated(-30), base, base.rotated(30)]
        case .triadic: [base, base.rotated(120), base.rotated(240)]
        case .tetradic: [base, base.rotated(90), base.rotated(180), base.rotated(270)]
        case .shades: (0..<6).map { base.mixed(with: RGB(r: 0, g: 0, b: 0), Double($0) * 0.15) }
        case .tints: (0..<6).map { base.mixed(with: RGB(r: 1, g: 1, b: 1), Double($0) * 0.15) }
        }
    }
}

// MARK: - Model

struct Favourite: Codable, Identifiable, Equatable {
    var id = UUID()
    var base: RGB
    var harmony: String
}

@MainActor
final class PaletteStore: ObservableObject {
    /// Snapshots read a store nothing ever writes, so they show the default colour, never the user's.
    private static let defaults = StatusPopover.isSnapshot ? UserDefaults(suiteName: "com.weirdapps.palette.snapshot") : UserDefaults.standard
    @AppStorage("base", store: PaletteStore.defaults) var baseHex = "#2A9D8F"
    @Published var favourites: [Favourite] { didSet { Storage.save(favourites, app: "Palette", file: "favourites.json") } }
    @Published var copied: String?
    private var clearCopied: DispatchWorkItem?

    init() {
        favourites = StatusPopover.isSnapshot
            ? [Favourite(base: RGB(r: 0.91, g: 0.44, b: 0.32), harmony: "Analogous"), Favourite(base: RGB(r: 0.15, g: 0.27, b: 0.33), harmony: "Analogous")]
            : Storage.load([Favourite].self, app: "Palette", file: "favourites.json") ?? []
    }

    var base: RGB {
        get { RGB(hex: baseHex) ?? RGB(r: 0.16, g: 0.62, b: 0.56) }
        set { if !StatusPopover.isSnapshot { baseHex = newValue.hex } }
    }

    func copy(_ c: RGB) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.hex, forType: .string)
        withAnimation(.snappy) { copied = c.hex }
        clearCopied?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation { self?.copied = nil } }
        clearCopied = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    func random() {
        base = RGB(h: Double.random(in: 0..<360), s: Double.random(in: 0.45...0.85), l: Double.random(in: 0.4...0.6))
    }

    var isFavourite: Bool { favourites.contains { $0.base.hex == baseHex } }

    func toggleFavourite() {
        withAnimation(.snappy) {
            if isFavourite {
                favourites.removeAll { $0.base.hex == baseHex }
            } else {
                favourites.insert(Favourite(base: base, harmony: "Analogous"), at: 0)
            }
        }
    }
}

// MARK: - Views

struct PaletteView: View {
    @EnvironmentObject var store: PaletteStore
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            VStack(spacing: 6) {
                ForEach(Harmony.allCases) { h in
                    HarmonyRow(harmony: h)
                }
            }
            .padding(.horizontal, 12)
            Favourites()
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Palette") {
                Button("Random Colour") { withAnimation(.snappy) { store.random() } }.keyboardShortcut("r")
                Button(store.isFavourite ? "Remove from Favourites" : "Add to Favourites") { store.toggleFavourite() }
                    .keyboardShortcut("d")
            }
        }
        .frame(width: 360)
        .onAppear { draft = store.baseHex }
        .onChange(of: store.baseHex) { _, h in if !focused { draft = h } }
    }

    private var header: some View {
        let base = store.base
        return HStack(spacing: 10) {
            Button {
                ColorPanel.shared.edit(base) { picked in store.base = picked }
            } label: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(base.color)
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.15)))
                    .shadow(color: base.color.opacity(0.5), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .help("Open the colour panel")
            VStack(alignment: .leading, spacing: 1) {
                Text("Base colour").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                TextField("#2A9D8F", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, d in if d.count >= 6, let c = RGB(hex: d) { store.base = c } }
                    .onChange(of: focused) { _, f in if !f { commit() } }
            }
            Spacer()
            GlassIconButton("dice", help: "Random colour") { withAnimation(.snappy) { store.random() } }
            GlassIconButton(store.isFavourite ? "heart.fill" : "heart", help: "Save to favourites") { store.toggleFavourite() }
                .foregroundStyle(store.isFavourite ? .pink : .secondary)
        }
    }

    private func commit() {
        if let c = RGB(hex: draft) { store.base = c }
        draft = store.baseHex
    }
}

struct HarmonyRow: View {
    @EnvironmentObject var store: PaletteStore
    let harmony: Harmony

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(harmony.rawValue).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(Array(harmony.colors(from: store.base).enumerated()), id: \.offset) { _, c in
                    SwatchCell(color: c)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}

struct SwatchCell: View {
    @EnvironmentObject var store: PaletteStore
    let color: RGB
    @State private var hovering = false

    var body: some View {
        let dark = color.luminance < 0.4
        Button {
            store.copy(color)
        } label: {
            ZStack {
                Rectangle().fill(color.color)
                Text(store.copied == color.hex ? "Copied" : color.hex)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(dark ? .white : .black)
                    .opacity(hovering || store.copied == color.hex ? 0.9 : 0)
            }
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(color.hex)")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .animation(.snappy, value: color)
    }
}

struct Favourites: View {
    @EnvironmentObject var store: PaletteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favourites").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if store.favourites.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "heart").foregroundStyle(.tertiary)
                    Text("Tap the heart to keep a palette here.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
            } else {
                ForEach(store.favourites) { f in
                    FavouriteRow(favourite: f)
                }
            }
        }
    }
}

struct FavouriteRow: View {
    @EnvironmentObject var store: PaletteStore
    let favourite: Favourite
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(Array((Harmony.allCases.first { $0.rawValue == favourite.harmony } ?? .analogous)
                    .colors(from: favourite.base).enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(c.color)
                }
            }
            .frame(width: 90, height: 20)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Text(favourite.base.hex).font(.system(size: 12, weight: .medium, design: .monospaced))
            Spacer()
            if hovering {
                GlassIconButton("trash", help: "Remove") {
                    withAnimation(.snappy) { store.favourites.removeAll { $0.id == favourite.id } }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { store.base = favourite.base } }
        .onHover { hovering = $0 }
    }
}

/// Routes the shared system colour panel to the base colour.
@MainActor
final class ColorPanel: NSObject {
    static let shared = ColorPanel()
    private var onChange: ((RGB) -> Void)?

    func edit(_ color: RGB, onChange: @escaping (RGB) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: 1)
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.isContinuous = true
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)))
    }
}

// MARK: - Icon

//: a fan of paint chips

func appIcon() -> NSBitmapImageRep {
    render(0xFFF4E2, 0xEBCFA6) { ctx in
        let pivot = CGPoint(x: 512, y: 210)
        let chips: [(UInt32, UInt32, CGFloat)] = [
            (0x2A9D8F, 0x1F7A6F, 38), (0x8AB17D, 0x6E9563, 19), (0xE9C46A, 0xD4A93F, 0),
            (0xF4A261, 0xE38A3E, -19), (0xE76F51, 0xC9533A, -38),
        ]
        for (top, bottom, angle) in chips {
            ctx.saveGState()
            ctx.translateBy(x: pivot.x, y: pivot.y)
            ctx.rotate(by: angle * .pi / 180)
            let card = CGRect(x: -70, y: -40, width: 140, height: 560)
            ctx.saveGState()
            shadow(ctx, y: -10, blur: 24, alpha: 0.28)
            ctx.addPath(roundedRect(card, 34))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(card.insetBy(dx: 12, dy: 12), 24))
            ctx.clip()
            gradient([rgb(top), rgb(bottom)], from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY + 120), in: ctx)
            ctx.restoreGState()
            // White label strip at the base of each chip.
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: card.minX + 12, y: card.minY + 12, width: card.width - 24, height: 80))
            ctx.setFillColor(rgb(0xD9D2C5).cgColor)
            ctx.addPath(roundedRect(CGRect(x: card.minX + 30, y: card.minY + 50, width: 64, height: 12), 6))
            ctx.fillPath()
            ctx.restoreGState()
        }
        // Rivet.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 8, alpha: 0.3)
        ctx.setFillColor(rgb(0xB8BEC7).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 26, y: pivot.y - 26, width: 52, height: 52))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xE8ECF1).cgColor)
        ctx.fillEllipse(in: CGRect(x: pivot.x - 12, y: pivot.y - 12, width: 24, height: 24))
    }
}
