import AppKit
import Combine
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
    private var cancellables: Set<AnyCancellable> = []
    let model = LunaModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "moon", accessibilityLabel: "Luna") {
            LunaView().environmentObject(self.model)
        }
        model.$now.combineLatest(model.$southern)
            .sink { [weak self] now, southern in
                let s = Moon.state(at: now)
                self?.status.item.button?.image = MoonGlyph.image(state: s, southern: southern)
            }
            .store(in: &cancellables)
    }
}

// MARK: - Model

@MainActor
final class LunaModel: ObservableObject {
    @Published private(set) var now = Date()
    /// Days the panel is moved away from today.
    @Published var offset = 0
    @Published var southern = UserDefaults.standard.bool(forKey: "southern") {
        didSet { UserDefaults.standard.set(southern, forKey: "southern") }
    }
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    var shown: Date { now.addingTimeInterval(TimeInterval(offset) * 86400) }
}

// MARK: - Views

struct LunaView: View {
    @EnvironmentObject var model: LunaModel

    var body: some View {
        let date = model.shown
        let state = Moon.state(at: date)
        VStack(spacing: 0) {
            ZStack {
                Starfield()
                VStack(spacing: 12) {
                    MoonDisc(illumination: state.illumination, waxing: state.waxing, southern: model.southern)
                        .frame(width: 150, height: 150)
                        .shadow(color: .white.opacity(0.18), radius: 18)
                        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: state.illumination)
                    VStack(spacing: 2) {
                        Text(state.name)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.opacity)
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.vertical, 20)
                HStack {
                    DayButton(symbol: "chevron.left") { withAnimation(.snappy) { model.offset -= 1 } }
                    Spacer()
                    DayButton(symbol: "chevron.right") { withAnimation(.snappy) { model.offset += 1 } }
                }
                .padding(.horizontal, 12)
            }
            .background(LinearGradient(colors: [Color(red: 0.1, green: 0.08, blue: 0.24), Color(red: 0.02, green: 0.02, blue: 0.08)],
                                       startPoint: .top, endPoint: .bottom))

            HStack(spacing: 8) {
                Fact(value: "\(Int((state.illumination * 100).rounded()))%", label: "illuminated")
                Fact(value: state.age.formatted(.number.precision(.fractionLength(1))), label: "days old")
                Fact(value: state.waxing ? "Waxing" : "Waning", label: state.waxing ? "growing" : "shrinking")
            }
            .padding(12)

            VStack(spacing: 5) {
                EventRow(symbol: "circle.fill", title: "Full Moon", date: Moon.next(0.5, after: date), from: date)
                EventRow(symbol: "circle", title: "New Moon", date: Moon.next(0, after: date), from: date)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            if model.offset != 0 {
                Button("Back to Today") { withAnimation(.snappy) { model.offset = 0 } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.bottom, 10)
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Luna") {
                Toggle("Southern Hemisphere View", isOn: $model.southern)
            }
        }
        .frame(width: 320)
    }
}

struct DayButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.55))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.white.opacity(hovering ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct Fact: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct EventRow: View {
    let symbol: String
    let title: String
    let date: Date
    let from: Date
    @State private var hovering = false

    var body: some View {
        let days = Int((date.timeIntervalSince(from) / 86400).rounded())
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Accent.gradient)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(days == 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(date.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .onHover { hovering = $0 }
    }
}

/// The lit part of the disc: the bright limb plus a half ellipse for the terminator.
struct LitShape: Shape {
    var illumination: Double
    /// True when the lit limb is on the right, as seen when waxing from the northern hemisphere.
    let rightLit: Bool

    var animatableData: Double {
        get { illumination }
        set { illumination = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let side: Double = rightLit ? 1 : -1
        // The terminator's half width: r at new moon (no light), 0 at quarter, -r at full.
        let a = r * (1 - 2 * illumination)
        var p = Path()
        let steps = 64
        for i in 0...steps {
            let t = -Double.pi / 2 + Double.pi * Double(i) / Double(steps)
            let pt = CGPoint(x: c.x + side * r * cos(t), y: c.y - r * sin(t))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        for i in 0...steps {
            let t = Double.pi / 2 - Double.pi * Double(i) / Double(steps)
            p.addLine(to: CGPoint(x: c.x + side * a * cos(t), y: c.y - r * sin(t)))
        }
        p.closeSubpath()
        return p
    }
}

struct MoonDisc: View {
    let illumination: Double
    let waxing: Bool
    let southern: Bool

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.16))
            Maria().fill(Color(white: 0.135))
            LitShape(illumination: illumination, rightLit: waxing != southern)
                .fill(RadialGradient(colors: [Color(white: 0.98), Color(red: 0.86, green: 0.85, blue: 0.8)],
                                     center: .init(x: 0.4, y: 0.35), startRadius: 0, endRadius: 90))
            Maria()
                .fill(Color(red: 0.55, green: 0.55, blue: 0.56).opacity(0.2))
                .mask(LitShape(illumination: illumination, rightLit: waxing != southern))
            Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .rotationEffect(.degrees(southern ? 180 : 0))
    }
}

/// A few dark seas, placed roughly where they sit on the near side.
struct Maria: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var p = Path()
        for (x, y, rx, ry) in [(0.32, 0.3, 0.13, 0.1), (0.5, 0.28, 0.09, 0.08), (0.58, 0.42, 0.12, 0.1), (0.38, 0.52, 0.1, 0.12),
                               (0.68, 0.6, 0.08, 0.07), (0.3, 0.7, 0.07, 0.06), (0.55, 0.78, 0.05, 0.05)] {
            p.addEllipse(in: CGRect(x: rect.minX + (x - rx) * w, y: rect.minY + (y - ry) * h, width: rx * 2 * w, height: ry * 2 * h))
        }
        return p
    }
}

struct Starfield: View {
    var body: some View {
        Canvas { ctx, size in
            var rng = SplitMix(seed: 7)
            for _ in 0..<60 {
                let x = rng.next() * size.width, y = rng.next() * size.height, r = 0.4 + rng.next() * 1.1
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.25 + rng.next() * 0.5)))
            }
        }
    }
}

/// A tiny deterministic generator so the stars stay put between redraws.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

enum Accent {
    static let gradient = LinearGradient(colors: [Color(red: 0.62, green: 0.58, blue: 1), Color(red: 0.36, green: 0.3, blue: 0.85)],
                                         startPoint: .top, endPoint: .bottom)
}

/// The menu bar glyph: the current phase, lit part solid and the dark part as an outline.
enum MoonGlyph {
    static func image(state: Moon.State, southern: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let disc = rect.insetBy(dx: 2, dy: 2)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: disc.insetBy(dx: 0.6, dy: 0.6))
            let lit = LitShape(illumination: state.illumination, rightLit: state.waxing != southern).path(in: disc)
            ctx.addPath(lit.cgPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "\(state.name), \(Int((state.illumination * 100).rounded())) percent lit"
        return image
    }
}

// MARK: - Astronomy

/// Moon phase maths from Jean Meeus, "Astronomical Algorithms" (2nd ed.):
/// chapter 49 for the instants of new and full moon, chapter 48 for the illuminated fraction.
enum Moon {
    static let synodicMonth = 29.530588861
    /// Terrestrial minus universal time, close enough for the 2020s and 2030s.
    static let deltaT: TimeInterval = 69

    static func julianDay(_ date: Date) -> Double { date.timeIntervalSince1970 / 86400 + 2440587.5 }
    static func date(julianDay jd: Double) -> Date { Date(timeIntervalSince1970: (jd - 2440587.5) * 86400) }

    private static func rad(_ deg: Double) -> Double { deg * .pi / 180 }
    private static func norm(_ deg: Double) -> Double { let d = deg.truncatingRemainder(dividingBy: 360); return d < 0 ? d + 360 : d }

    /// The instant of the new moon (fraction 0) or full moon (fraction 0.5) of lunation `k` counted from January 2000.
    static func phaseInstant(k: Double) -> Date {
        let t = k / 1236.85, t2 = t * t, t3 = t2 * t, t4 = t3 * t
        var jde = 2451550.09766 + 29.530588861 * k + 0.00015437 * t2 - 0.000000150 * t3 + 0.00000000073 * t4
        let e = 1 - 0.002516 * t - 0.0000074 * t2
        let m = rad(norm(2.5534 + 29.10535670 * k - 0.0000014 * t2 - 0.00000011 * t3))
        let mp = rad(norm(201.5643 + 385.81693528 * k + 0.0107582 * t2 + 0.00001238 * t3 - 0.000000058 * t4))
        let f = rad(norm(160.7108 + 390.67050284 * k - 0.0016118 * t2 - 0.00000227 * t3 + 0.000000011 * t4))
        let om = rad(norm(124.7746 - 1.56375588 * k + 0.0020672 * t2 + 0.00000215 * t3))
        let full = abs(k - k.rounded(.down) - 0.5) < 0.01
        // Periodic terms; new and full moon differ only in the first seven coefficients.
        let c: [Double] = full
            ? [-0.40614, 0.17302, 0.01614, 0.01043, 0.00734, -0.00515, 0.00209]
            : [-0.40720, 0.17241, 0.01608, 0.01039, 0.00739, -0.00514, 0.00208]
        jde += c[0] * sin(mp) + c[1] * e * sin(m) + c[2] * sin(2 * mp) + c[3] * sin(2 * f)
            + c[4] * e * sin(mp - m) + c[5] * e * sin(mp + m) + c[6] * e * e * sin(2 * m)
            - 0.00111 * sin(mp - 2 * f) - 0.00057 * sin(mp + 2 * f) + 0.00056 * e * sin(2 * mp + m)
            - 0.00042 * sin(3 * mp) + 0.00042 * e * sin(m + 2 * f) + 0.00038 * e * sin(m - 2 * f)
            - 0.00024 * e * sin(2 * mp - m) - 0.00017 * sin(om) - 0.00007 * sin(mp + 2 * m)
            + 0.00004 * sin(2 * mp - 2 * f) + 0.00004 * sin(3 * m) + 0.00003 * sin(mp + m - 2 * f)
            + 0.00003 * sin(2 * mp + 2 * f) - 0.00003 * sin(mp + m + 2 * f) + 0.00003 * sin(mp - m + 2 * f)
            - 0.00002 * sin(mp - m - 2 * f) - 0.00002 * sin(3 * mp + m) + 0.00002 * sin(4 * mp)
        // The largest planetary argument, A1 (Venus), worth up to half a minute.
        jde += 0.000325 * sin(rad(norm(299.77 + 0.107408 * k - 0.009173 * t2)))
        return date(julianDay: jde).addingTimeInterval(-deltaT)
    }

    /// Lunation number near a date.
    static func lunation(near date: Date) -> Double {
        ((julianDay(date) - 2451550.09766) / synodicMonth).rounded(.down)
    }

    /// The first new (offset 0) or full (offset 0.5) moon strictly after `date`.
    static func next(_ offset: Double, after date: Date) -> Date {
        var k = lunation(near: date) - 1 + offset
        while phaseInstant(k: k) <= date { k += 1 }
        return phaseInstant(k: k)
    }

    /// The last new or full moon at or before `date`.
    static func previous(_ offset: Double, before date: Date) -> Date {
        var k = lunation(near: date) + 1 + offset
        while phaseInstant(k: k) > date { k -= 1 }
        return phaseInstant(k: k)
    }

    struct State: Equatable {
        /// Illuminated fraction of the disc, 0...1.
        let illumination: Double
        /// Days since the last new moon.
        let age: Double
        let waxing: Bool
        let name: String
    }

    /// Phase angle from the low precision positions in Meeus chapter 48.
    static func state(at date: Date) -> State {
        let t = (julianDay(date.addingTimeInterval(deltaT)) - 2451545) / 36525
        let d = norm(297.8501921 + 445267.1114034 * t - 0.0018819 * t * t)
        let m = norm(357.5291092 + 35999.0502909 * t - 0.0001536 * t * t)
        let mp = norm(134.9633964 + 477198.8675055 * t + 0.0087414 * t * t)
        let i = 180 - d - 6.289 * sin(rad(mp)) + 2.100 * sin(rad(m)) - 1.274 * sin(rad(2 * d - mp))
            - 0.658 * sin(rad(2 * d)) - 0.214 * sin(rad(2 * mp)) - 0.110 * sin(rad(d))
        let k = (1 + cos(rad(i))) / 2
        let age = date.timeIntervalSince(previous(0, before: date)) / 86400
        let waxing = age < synodicMonth / 2 && date < next(0.5, after: previous(0, before: date))
        return State(illumination: k, age: age, waxing: waxing, name: name(illumination: k, waxing: waxing))
    }

    static func name(illumination k: Double, waxing: Bool) -> String {
        switch k {
        case ..<0.02: "New Moon"
        case 0.98...: "Full Moon"
        case 0.46..<0.54: waxing ? "First Quarter" : "Last Quarter"
        case ..<0.46: waxing ? "Waxing Crescent" : "Waning Crescent"
        default: waxing ? "Waxing Gibbous" : "Waning Gibbous"
        }
    }
}

// MARK: - Icon

//: a waxing gibbous moon with seas, on a violet night sky

func appIcon() -> NSBitmapImageRep {
    render(0x3B2F7A, 0x0B0A22) { ctx in
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        for (x, y, r) in [(210.0, 790.0, 5.0), (300, 860, 3), (820, 840, 4), (860, 300, 3), (180, 420, 3), (250, 210, 4), (770, 180, 3)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        sparkle(ctx, at: CGPoint(x: 800, y: 760), size: 34, color: NSColor.white.withAlphaComponent(0.9))
        let c = CGPoint(x: 500, y: 500), r: CGFloat = 290
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        radial([rgb(0xB9B2FF, 0.4), rgb(0xB9B2FF, 0)], center: c, radius: r + 120, in: ctx)
        // Earthshine on the dark side.
        ctx.setFillColor(rgb(0x2A2752).cgColor)
        ctx.fillEllipse(in: disc)
        // The lit part: right limb plus the terminator, 78 percent lit.
        let k: CGFloat = 0.78, a = r * (1 - 2 * k)
        let lit = CGMutablePath()
        lit.addArc(center: c, radius: r, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: false)
        for i in 0...64 {
            let t = CGFloat.pi / 2 - CGFloat.pi * CGFloat(i) / 64
            lit.addLine(to: CGPoint(x: c.x + a * cos(t), y: c.y + r * sin(t)))
        }
        lit.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xE9E6FF, 0.55).cgColor)
        ctx.addPath(lit)
        ctx.setFillColor(rgb(0xF4F2EA).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(lit)
        ctx.clip()
        radial([rgb(0xFFFFFF), rgb(0xE4E1D6), rgb(0xC9C5BA)], center: CGPoint(x: c.x + 60, y: c.y + 90), radius: r * 1.2, in: ctx)
        // Seas and a crater or two.
        ctx.setFillColor(rgb(0x9C9A95, 0.45).cgColor)
        for (x, y, w, h) in [(-90.0, 90.0, 150.0, 110.0), (40, 120, 110, 90), (60, -10, 150, 120), (-60, -60, 110, 130), (150, -120, 90, 80)] {
            ctx.fillEllipse(in: CGRect(x: c.x + x - w / 2, y: c.y + y - h / 2, width: w, height: h))
        }
        ctx.setStrokeColor(rgb(0xB5B2AA, 0.8).cgColor)
        ctx.setLineWidth(6)
        for (x, y, d) in [(170.0, 150.0, 46.0), (110, -200, 34), (-20, 220, 28)] {
            ctx.strokeEllipse(in: CGRect(x: c.x + x - d / 2, y: c.y + y - d / 2, width: d, height: d))
        }
        ctx.restoreGState()
    }
}
