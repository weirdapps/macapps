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
    let store = SwatchStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "eyedropper.halffull", accessibilityLabel: "Swatch") {
            SwatchView().environmentObject(self.store)
        }
        store.closePanel = { [weak self] in self?.status.close() }
        status.onSecondaryClick = { [weak self] in self?.store.pick() }
        hotKey = HotKey(keyCode: kVK_ANSI_C, modifiers: cmdKey | optionKey) { [weak self] in self?.store.pick() }
        store.hotKeyReady = StatusPopover.isSnapshot || hotKey?.isRegistered == true
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

    var bytes: (Int, Int, Int) { (Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }

    var hex: String { let (r, g, b) = bytes; return String(format: "#%02X%02X%02X", r, g, b) }

    /// Hue in degrees, saturation and lightness in 0...1.
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
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    /// OKLCH, Björn Ottosson's perceptual space: lightness 0...1, chroma, hue in degrees.
    var oklch: (l: Double, c: Double, h: Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (linear(r), linear(g), linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(bb, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, sqrt(a * a + bb * bb), h)
    }

    var luminance: Double {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
}

enum Format: String, CaseIterable, Identifiable {
    case hex = "HEX", rgb = "RGB", hsl = "HSL", swiftUI = "SwiftUI", css = "CSS"
    var id: String { rawValue }

    func string(_ c: RGB) -> String {
        switch self {
        case .hex: return c.hex
        case .rgb:
            let (r, g, b) = c.bytes
            return "rgb(\(r), \(g), \(b))"
        case .hsl:
            let v = c.hsl
            return "hsl(\(Int(v.h.rounded())), \(Int((v.s * 100).rounded()))%, \(Int((v.l * 100).rounded()))%)"
        case .swiftUI:
            return String(format: "Color(red: %.3f, green: %.3f, blue: %.3f)", c.r, c.g, c.b)
        case .css:
            let v = c.oklch
            return String(format: "oklch(%.1f%% %.3f %.1f)", v.l * 100, v.c, v.c < 0.0005 ? 0 : v.h)
        }
    }
}

// MARK: - Model

@MainActor
final class SwatchStore: ObservableObject {
    @Published var history: [RGB] {
        didSet { if !StatusPopover.isSnapshot { Storage.save(history, app: "Swatch", file: "history.json") } }
    }
    /// False when another app owns the shortcut, so the panel does not advertise one that never fires.
    @Published var hotKeyReady = false
    @Published var current: RGB?
    @AppStorage("copyFormat") var copyFormat: Format = .hex
    @AppStorage("copyOnPick") var copyOnPick = true
    var closePanel: (() -> Void)?
    private let sampler = NSColorSampler()

    init() {
        if StatusPopover.isSnapshot {
            // Fixed demo colours and settings, never the user's own; nothing is saved.
            UserDefaults.standard.setVolatileDomain(["copyFormat": Format.hex.rawValue, "copyOnPick": true],
                                                    forName: UserDefaults.argumentDomain)
            history = ["#3B82F6", "#F97316", "#10B981", "#EF4444", "#8B5CF6", "#FACC15", "#0F172A", "#EC4899"].compactMap { RGB(hex: $0) }
        } else {
            history = Storage.load([RGB].self, app: "Swatch", file: "history.json") ?? []
        }
        current = history.first
    }

    func pick() {
        closePanel?()
        sampler.show { [weak self] picked in
            guard let picked, let srgb = picked.usingColorSpace(.sRGB) else { return }
            MainActor.assumeIsolated {
                self?.add(RGB(r: Double(srgb.redComponent), g: Double(srgb.greenComponent), b: Double(srgb.blueComponent)))
            }
        }
    }

    func add(_ c: RGB) {
        withAnimation(.snappy) {
            history.removeAll { $0.hex == c.hex }
            history.insert(c, at: 0)
            if history.count > 40 { history.removeLast(history.count - 40) }
            current = c
        }
        if copyOnPick {
            copy(copyFormat.string(c))
            HUD.show(symbol: "eyedropper.full", title: c.hex, tint: c.color)
        }
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func remove(_ c: RGB) {
        withAnimation(.snappy) {
            history.removeAll { $0 == c }
            if current == c { current = history.first }
        }
    }
}

// MARK: - Views

struct SwatchView: View {
    @EnvironmentObject var store: SwatchStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Swatch").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    store.pick()
                } label: {
                    Label("Pick", systemImage: "eyedropper")
                }
                .buttonStyle(PillButtonStyle(Accent.colors))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            if let c = store.current {
                Hero(color: c)
                    .padding(.horizontal, 12)
                VStack(spacing: 4) {
                    ForEach(Format.allCases) { f in
                        FormatRow(format: f, value: f.string(c))
                    }
                }
                .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "eyedropper").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(store.hotKeyReady ? "Press Pick or ⌥⌘C, then click anywhere on screen to sample a colour."
                                           : "Press Pick, then click anywhere on screen to sample a colour.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
            }

            if !store.history.isEmpty {
                HistoryGrid()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Swatch", shortcut: store.hotKeyReady ? "⌥⌘C" : nil) {
                Toggle("Copy When Picked", isOn: $store.copyOnPick)
                Picker("Copy As", selection: $store.copyFormat) {
                    ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Clear History", role: .destructive) { withAnimation { store.history = []; store.current = nil } }
                    .disabled(store.history.isEmpty)
            }
        }
        .frame(width: 380)
    }
}

struct Hero: View {
    let color: RGB

    var body: some View {
        let dark = color.luminance < 0.4
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(color.color)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1)))
                .shadow(color: color.color.opacity(0.45), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(color.hex)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Luminance \(Int((color.luminance * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium))
                    .opacity(0.75)
            }
            .foregroundStyle(dark ? .white : .black)
            .padding(14)
        }
        .frame(height: 104)
        .animation(.snappy, value: color)
    }
}

struct FormatRow: View {
    @EnvironmentObject var store: SwatchStore
    let format: Format
    let value: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            store.copy(value)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 10) {
                Text(format.rawValue)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .overlay(alignment: .trailing) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .padding(6)
                    .background(Circle().fill(.background))
                    .padding(.trailing, 4)
                    .opacity(hovering || copied ? 1 : 0)
            }
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(format.rawValue)")
        .onHover { hovering = $0 }
    }
}

struct HistoryGrid: View {
    @EnvironmentObject var store: SwatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("History").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(stride(from: 0, to: store.history.count, by: 10)), id: \.self) { start in
                    GridRow {
                        ForEach(store.history[start..<min(start + 10, store.history.count)], id: \.self) { c in
                            Chip(color: c, selected: c == store.current)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Chip: View {
    @EnvironmentObject var store: SwatchStore
    let color: RGB
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.color)
            .frame(width: 28, height: 28)
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(selected ? 1 : 0))
            .scaleEffect(hovering ? 1.1 : 1)
            .animation(.snappy(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { withAnimation(.snappy) { store.current = color } }
            .help(color.hex)
            .contextMenu {
                Button("Copy \(color.hex)") { store.copy(color.hex) }
                Button("Remove", role: .destructive) { store.remove(color) }
            }
    }
}

enum Accent {
    static let colors = [Color(red: 1, green: 0.42, blue: 0.62), Color(red: 0.6, green: 0.3, blue: 0.95)]
}

// MARK: - Icon

//: an eyedropper drawing a drop from a ring of colour

func appIcon() -> NSBitmapImageRep {
    render(0x2B2D3A, 0x101118) { ctx in
        // Colour wheel in twelve segments.
        let c = CGPoint(x: 470, y: 470), outer: CGFloat = 300, inner: CGFloat = 175
        let hues: [UInt32] = [0xFF453A, 0xFF7A2E, 0xFFB52E, 0xFFE03A, 0xA6E23A, 0x34C759, 0x2ED3B7, 0x30B0FF,
                              0x3A7BFF, 0x7A5CFF, 0xBF5AF2, 0xFF4FA3]
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.5)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for (i, hex) in hues.enumerated() {
            let a0 = CGFloat(i) / 12 * 2 * .pi + .pi / 2, a1 = CGFloat(i + 1) / 12 * 2 * .pi + .pi / 2
            ctx.move(to: CGPoint(x: c.x + cos(a0) * inner, y: c.y + sin(a0) * inner))
            ctx.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
            ctx.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
            ctx.closePath()
            ctx.setFillColor(rgb(hex).cgColor)
            ctx.fillPath()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Thin gaps between segments.
        ctx.setStrokeColor(rgb(0x1C1D27).cgColor)
        ctx.setLineWidth(8)
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi + .pi / 2
            ctx.move(to: CGPoint(x: c.x + cos(a) * (inner - 2), y: c.y + sin(a) * (inner - 2)))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * (outer + 2), y: c.y + sin(a) * (outer + 2)))
        }
        ctx.strokePath()
        // The eyedropper, diagonal from the upper right, tip in the centre.
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: 45 * .pi / 180)
        shadow(ctx, y: -12, blur: 26, alpha: 0.5)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        // Glass tube.
        ctx.addPath(roundedRect(CGRect(x: -34, y: 30, width: 68, height: 300), 30))
        ctx.setFillColor(rgb(0xE9EEF5).cgColor)
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: -22, y: 40, width: 44, height: 150), 20))
        ctx.setFillColor(rgb(0x30B0FF).cgColor)
        ctx.fillPath()
        // Tip.
        ctx.move(to: CGPoint(x: -20, y: 36))
        ctx.addLine(to: CGPoint(x: -6, y: -40))
        ctx.addLine(to: CGPoint(x: 6, y: -40))
        ctx.addLine(to: CGPoint(x: 20, y: 36))
        ctx.closePath()
        ctx.setFillColor(rgb(0xC9D2DE).cgColor)
        ctx.fillPath()
        // Collar and bulb.
        ctx.addPath(roundedRect(CGRect(x: -58, y: 300, width: 116, height: 44), 16))
        ctx.setFillColor(rgb(0x5B5F73).cgColor)
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: -46, y: 336, width: 92, height: 130), 46))
        ctx.setFillColor(rgb(0x3E4152).cgColor)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // The sampled drop.
        let d = CGPoint(x: c.x + 64, y: c.y - 64)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 24, color: rgb(0x30B0FF, 0.8).cgColor)
        ctx.setFillColor(rgb(0x30B0FF).cgColor)
        ctx.fillEllipse(in: CGRect(x: d.x - 34, y: d.y - 34, width: 68, height: 68))
        ctx.restoreGState()
    }
}
