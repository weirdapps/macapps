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
    let model = ContrastModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "circle.lefthalf.filled", accessibilityLabel: "Contrast") {
            ContrastView().environmentObject(self.model)
        }
    }
}

// MARK: - WCAG maths

/// An sRGB colour with components in 0...1.
struct RGB: Equatable {
    var r: Double, g: Double, b: Double

    init(r: Double, g: Double, b: Double) { (self.r, self.g, self.b) = (r, g, b) }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Relative luminance as WCAG 2.2 defines it (sRGB, 0.04045 threshold).
    var luminance: Double {
        func channel(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }

    /// The same colour, lighter or darker in steps of 1/255 on every channel, keeping the hue.
    func shifted(_ amount: Double) -> RGB {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        return amount > 0
            ? RGB(r: clamp(r + (1 - r) * amount), g: clamp(g + (1 - g) * amount), b: clamp(b + (1 - b) * amount))
            : RGB(r: clamp(r * (1 + amount)), g: clamp(g * (1 + amount)), b: clamp(b * (1 + amount)))
    }
}

enum WCAG {
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (l1 + 0.05) / (l2 + 0.05)
    }

    struct Criterion: Identifiable {
        let id: String
        let level: String
        let label: String
        let minimum: Double
    }

    static let criteria = [
        Criterion(id: "aa", level: "AA", label: "Normal text", minimum: 4.5),
        Criterion(id: "aal", level: "AA", label: "Large text", minimum: 3),
        Criterion(id: "aaa", level: "AAA", label: "Normal text", minimum: 7),
        Criterion(id: "aaal", level: "AAA", label: "Large text", minimum: 4.5),
        Criterion(id: "ui", level: "AA", label: "Icons and controls", minimum: 3),
    ]

    /// Rounds down to two places, so 4.499 never shows as a passing 4.50.
    static func format(_ ratio: Double) -> String {
        String(format: "%.2f:1", (ratio * 100).rounded(.down) / 100)
    }

    /// The nearest shade of `foreground` that reaches `target` on `background`, darker or lighter, whichever is closer.
    static func fix(_ foreground: RGB, on background: RGB, target: Double) -> RGB? {
        if ratio(foreground, background) >= target { return foreground }
        for step in 1...100 {
            let t = Double(step) / 100
            for candidate in [foreground.shifted(-t), foreground.shifted(t)] where ratio(candidate, background) >= target {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Model

@MainActor
final class ContrastModel: ObservableObject {
    @AppStorage("foreground") var foregroundHex = "#8C959F"
    @AppStorage("background") var backgroundHex = "#FFFFFF"

    var foreground: RGB {
        get { RGB(hex: foregroundHex) ?? RGB(r: 0, g: 0, b: 0) }
        set { foregroundHex = newValue.hex }
    }

    var background: RGB {
        get { RGB(hex: backgroundHex) ?? RGB(r: 1, g: 1, b: 1) }
        set { backgroundHex = newValue.hex }
    }

    var ratio: Double { WCAG.ratio(foreground, background) }

    func swap() {
        (foregroundHex, backgroundHex) = (backgroundHex, foregroundHex)
    }
}

// MARK: - Views

struct ContrastView: View {
    @EnvironmentObject var model: ContrastModel

    var body: some View {
        let ratio = model.ratio
        VStack(spacing: 0) {
            Preview()
                .padding(12)
            HStack(spacing: 8) {
                ColorField(title: "Text", hex: $model.foregroundHex)
                Button {
                    withAnimation(.snappy) { model.swap() }
                } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(.quaternary.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help("Swap text and background")
                ColorField(title: "Background", hex: $model.backgroundHex)
            }
            .padding(.horizontal, 12)

            HStack(alignment: .firstTextBaseline) {
                Text(WCAG.format(ratio))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text(verdict(ratio))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(ratio >= 4.5 ? .green : ratio >= 3 ? .orange : .red)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(spacing: 4) {
                ForEach(WCAG.criteria) { c in
                    CriterionRow(criterion: c, ratio: ratio)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            if ratio < 4.5, let fixed = WCAG.fix(model.foreground, on: model.background, target: 4.5) {
                Button {
                    withAnimation(.snappy) { model.foreground = fixed }
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(fixed.color).frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)))
                        Text("Use \(fixed.hex) to pass AA")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Image(systemName: "wand.and.stars").foregroundStyle(Accent.gradient)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Accent.solid.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.opacity)
            }
            Spacer().frame(height: 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Contrast") {
                Button("Copy Result") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(model.foregroundHex) on \(model.backgroundHex): \(WCAG.format(ratio))", forType: .string)
                }
                Button("Swap Colours") { model.swap() }
            }
        }
        .frame(width: 340)
    }

    private func verdict(_ r: Double) -> String {
        switch r {
        case 7...: "Excellent"
        case 4.5...: "Good"
        case 3...: "Large text only"
        default: "Fails"
        }
    }
}

struct Preview: View {
    @EnvironmentObject var model: ContrastModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Large heading")
                .font(.system(size: 24, weight: .bold))
            Text("Body text at regular size, the way a paragraph reads on a page.")
                .font(.system(size: 13))
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                Text("Small caption").font(.system(size: 11))
            }
        }
        .foregroundStyle(model.foreground.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(model.background.color))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        .animation(.snappy, value: model.foregroundHex + model.backgroundHex)
    }
}

struct ColorField: View {
    let title: String
    @Binding var hex: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let rgb = RGB(hex: hex) ?? RGB(r: 0, g: 0, b: 0)
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button {
                    ColorPanel.shared.edit(rgb) { picked in hex = picked.hex }
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rgb.color)
                        .frame(width: 24, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("Open the colour panel")
                TextField("#000000", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: focused) { _, f in if !f { commit() } }
                    .onChange(of: draft) { _, d in if d.count >= 6, RGB(hex: d) != nil { hex = RGB(hex: d)!.hex } }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
        }
        .onAppear { draft = hex }
        .onChange(of: hex) { _, h in if !focused { draft = h } }
    }

    private func commit() {
        if let c = RGB(hex: draft) { hex = c.hex }
        draft = hex
    }
}

/// Routes the shared system colour panel to whichever field opened it last.
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

struct CriterionRow: View {
    let criterion: WCAG.Criterion
    let ratio: Double

    var body: some View {
        let pass = ratio >= criterion.minimum
        HStack(spacing: 10) {
            Text(criterion.level)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(criterion.label).font(.system(size: 12.5))
            Text(String(format: "%g:1", criterion.minimum))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
            Spacer()
            Label(pass ? "Pass" : "Fail", systemImage: pass ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(pass ? .green : .red)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

enum Accent {
    static let solid = Color(red: 0.95, green: 0.7, blue: 0.05)
    static let gradient = LinearGradient(colors: [Color(red: 1, green: 0.85, blue: 0.3), Color(red: 0.95, green: 0.62, blue: 0)],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a disc split into black and white, with a pass mark

func appIcon() -> NSBitmapImageRep {
    render(0xFFE04D, 0xF2A900) { ctx in
        let c = CGPoint(x: 512, y: 512), r: CGFloat = 290
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.35)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        // The dark half, split on the diagonal.
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        ctx.move(to: CGPoint(x: c.x - r * 2, y: c.y - r * 2))
        ctx.addLine(to: CGPoint(x: c.x + r * 2, y: c.y + r * 2))
        ctx.addLine(to: CGPoint(x: c.x + r * 2, y: c.y - r * 2))
        ctx.closePath()
        ctx.clip()
        gradient([rgb(0x2B2B30), rgb(0x0E0E11)], from: CGPoint(x: 0, y: c.y + r), to: CGPoint(x: 0, y: c.y - r), in: ctx)
        ctx.restoreGState()
        // Dots of the opposite tone in each half.
        ctx.setFillColor(rgb(0x111114).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 150 - 46, y: c.y + 90 - 46, width: 92, height: 92))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x + 150 - 46, y: c.y - 90 - 46, width: 92, height: 92))
        // Pass badge.
        let b = CGPoint(x: c.x + 220, y: c.y + 220)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 20, alpha: 0.35)
        ctx.setFillColor(rgb(0x2DBE60).cgColor)
        ctx.fillEllipse(in: CGRect(x: b.x - 110, y: b.y - 110, width: 220, height: 220))
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(32)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: b.x - 50, y: b.y + 2))
        ctx.addLine(to: CGPoint(x: b.x - 12, y: b.y - 38))
        ctx.addLine(to: CGPoint(x: b.x + 54, y: b.y + 44))
        ctx.strokePath()
    }
}
