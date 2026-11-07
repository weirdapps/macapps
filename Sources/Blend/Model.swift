import AppKit
import Kit
import SwiftUI

// MARK: - Colour

/// A colour in sRGB, components 0...1, straight (not premultiplied) alpha.
struct RGBA: Codable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without the hash.
    init?(hex text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 8 {
            self.init(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255,
                      b: Double((v >> 8) & 0xFF) / 255, a: Double(v & 0xFF) / 255)
        } else {
            self.init(UInt32(v))
        }
    }

    var clamped: RGBA {
        RGBA(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: min(max(a, 0), 1))
    }

    private static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour is not opaque.
    var hex: String {
        let base = String(format: "#%02X%02X%02X", Self.byte(r), Self.byte(g), Self.byte(b))
        return Self.byte(a) == 255 ? base : base + String(format: "%02X", Self.byte(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self = RGBA(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent).clamped
    }

    /// Relative luminance, for choosing a legible handle outline.
    var luminance: Double { 0.2126 * OKLab.linear(r) + 0.7152 * OKLab.linear(g) + 0.0722 * OKLab.linear(b) }
}

/// Björn Ottosson's OKLab: a perceptual space where straight lines between colours look even.
struct OKLab: Hashable, Sendable {
    var l: Double, a: Double, b: Double

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

    init(_ c: RGBA) {
        let r = Self.linear(c.r), g = Self.linear(c.g), bl = Self.linear(c.b)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    /// Back to sRGB, unclamped (components may fall outside 0...1 for out-of-gamut colours).
    func rgb(alpha: Double = 1) -> RGBA {
        let lc = l + 0.3963377774 * a + 0.2158037573 * b
        let mc = l - 0.1055613458 * a - 0.0638541728 * b
        let sc = l - 0.0894841775 * a - 1.2914855480 * b
        let L = lc * lc * lc, M = mc * mc * mc, S = sc * sc * sc
        return RGBA(r: Self.gamma(4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S),
                    g: Self.gamma(-1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S),
                    b: Self.gamma(-0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S), a: alpha)
    }

    /// From lightness, chroma and hue in degrees (OKLCH), reducing chroma until the colour fits in sRGB.
    static func lch(_ l: Double, _ c: Double, _ hue: Double) -> RGBA {
        var chroma = c
        while true {
            let h = hue * .pi / 180
            let out = OKLab(l: l, a: chroma * cos(h), b: chroma * sin(h)).rgb()
            let inGamut = [out.r, out.g, out.b].allSatisfy { $0 >= -0.0005 && $0 <= 1.0005 }
            if inGamut || chroma <= 0 { return out.clamped }
            chroma -= 0.005
        }
    }
}

enum Interpolation: String, Codable, CaseIterable, Sendable {
    case oklab, srgb
    var title: String { self == .oklab ? "Smooth (OKLab)" : "sRGB" }
}

/// Mixes two colours at `t` in the given space, with premultiplied alpha as CSS does.
func mix(_ x: RGBA, _ y: RGBA, _ t: Double, in space: Interpolation) -> RGBA {
    let alpha = x.a + (y.a - x.a) * t
    switch space {
    case .srgb:
        guard alpha > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func c(_ p: Double, _ q: Double) -> Double { (p * x.a + (q * y.a - p * x.a) * t) / alpha }
        return RGBA(r: c(x.r, y.r), g: c(x.g, y.g), b: c(x.b, y.b), a: alpha)
    case .oklab:
        let p = OKLab(x), q = OKLab(y)
        guard alpha > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
        func c(_ u: Double, _ v: Double) -> Double { (u * x.a + (v * y.a - u * x.a) * t) / alpha }
        return OKLab(l: c(p.l, q.l), a: c(p.a, q.a), b: c(p.b, q.b)).rgb(alpha: alpha).clamped
    }
}

// MARK: - Gradient

enum GradientKind: String, Codable, CaseIterable, Sendable {
    case linear, radial, conic
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .linear: "rectangle.righthalf.inset.filled"
        case .radial: "circle.circle"
        case .conic: "circle.lefthalf.striped.horizontal"
        }
    }
}

struct Stop: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var color: RGBA
    var location: Double
}

struct BlendGradient: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var kind: GradientKind = .linear
    /// Degrees, CSS convention: 0 points up, clockwise. Direction for linear, start for conic.
    var angle: Double = 135
    /// Unit point, y down, for radial and conic.
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var interpolation: Interpolation = .oklab
    var stops: [Stop]

    init(name: String, kind: GradientKind = .linear, angle: Double = 135, center: (Double, Double) = (0.5, 0.5),
         interpolation: Interpolation = .oklab, colors: [UInt32], locations: [Double]? = nil) {
        self.name = name
        self.kind = kind
        self.angle = angle
        centerX = center.0
        centerY = center.1
        self.interpolation = interpolation
        let n = max(colors.count - 1, 1)
        stops = colors.enumerated().map { i, hex in
            Stop(color: RGBA(hex), location: locations?[i] ?? Double(i) / Double(n))
        }
    }

    var sortedStops: [Stop] { stops.sorted { $0.location < $1.location } }

    /// The colour at `t` (0...1) along the gradient, in its interpolation space.
    func color(at t: Double) -> RGBA {
        let s = sortedStops
        guard let first = s.first, let last = s.last else { return RGBA(r: 0, g: 0, b: 0) }
        if t <= first.location { return first.color }
        if t >= last.location { return last.color }
        for (p, q) in zip(s, s.dropFirst()) where t <= q.location {
            let span = q.location - p.location
            return span <= 0 ? q.color : mix(p.color, q.color, (t - p.location) / span, in: interpolation)
        }
        return last.color
    }

    /// Stops for SwiftUI and Core Graphics, sampled densely with `mix`, so both draw the premultiplied sRGB or OKLab
    /// blend that CSS draws, whatever their own interpolation does.
    func renderStops(samples: Int = 24) -> [(RGBA, Double)] {
        let s = sortedStops
        guard s.count > 1 else { return s.map { ($0.color, $0.location) } }
        var out: [(RGBA, Double)] = [(s[0].color, s[0].location)]
        for (p, q) in zip(s, s.dropFirst()) {
            let span = q.location - p.location
            if span <= 0 { out.append((q.color, q.location)); continue }
            for i in 1...samples {
                let f = Double(i) / Double(samples)
                out.append((mix(p.color, q.color, f, in: interpolation), p.location + span * f))
            }
        }
        return out
    }

    var swiftUIStops: [Gradient.Stop] { renderStops().map { Gradient.Stop(color: $0.0.color, location: $0.1) } }

    /// Linear start and end as unit points for a box of `size`, matching CSS: the line runs through the centre at
    /// `angle` and is long enough that the corners get the first and last colour.
    func linearPoints(size: CGSize) -> (UnitPoint, UnitPoint) {
        let w = max(size.width, 1), h = max(size.height, 1)
        let rad = angle * .pi / 180
        let dx = sin(rad), dy = -cos(rad)
        let half = (abs(w * dx) + abs(h * dy)) / 2
        return (UnitPoint(x: 0.5 - dx * half / w, y: 0.5 - dy * half / h),
                UnitPoint(x: 0.5 + dx * half / w, y: 0.5 + dy * half / h))
    }

    /// The radial ending shape in unit space: a circle through the farthest corner, which is an ellipse in the box.
    var radialFraction: Double {
        let dx = max(centerX, 1 - centerX), dy = max(centerY, 1 - centerY)
        return (dx * dx + dy * dy).squareRoot()
    }

    var isCentered: Bool { abs(centerX - 0.5) < 0.0005 && abs(centerY - 0.5) < 0.0005 }

    var hexList: String { sortedStops.map(\.color.hex).joined(separator: "\n") }

    /// Repairs a gradient read from disk: finite numbers in range, unique stop ids and at least two stops.
    var sanitized: BlendGradient {
        func unit(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : fallback }
        var g = self
        g.angle = angle.isFinite ? Export.degrees(angle) : 0
        g.centerX = unit(centerX, 0.5)
        g.centerY = unit(centerY, 0.5)
        var seen = Set<UUID>()
        g.stops = stops.map { s in
            var s = s
            s.location = unit(s.location, 0)
            s.color = RGBA(r: unit(s.color.r, 0), g: unit(s.color.g, 0), b: unit(s.color.b, 0), a: unit(s.color.a, 1))
            if !seen.insert(s.id).inserted { s.id = UUID() }
            return s
        }
        if g.stops.isEmpty { g.stops = [Stop(color: RGBA(0x000000), location: 0)] }
        if g.stops.count == 1 {
            g.stops[0].location = 0
            g.stops.append(Stop(color: g.stops[0].color, location: 1))
        }
        return g
    }
}

// MARK: - Export

enum CodeFormat: String, CaseIterable, Sendable {
    case css, swiftUI, hex
    var title: String {
        switch self {
        case .css: "CSS"
        case .swiftUI: "SwiftUI"
        case .hex: "Hex"
        }
    }
}

enum Export {
    /// Up to two decimals, trailing zeros trimmed: 50, 33.33, 12.5.
    static func number(_ v: Double) -> String {
        var s = String(format: "%.2f", (v * 100).rounded() / 100)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func degrees(_ a: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// One `background:` declaration with the gradient's own function.
    static func css(_ g: BlendGradient) -> String {
        let stops = g.sortedStops.map { "  \($0.color.hex) \(number($0.location * 100))%" }.joined(separator: ",\n")
        let space = g.interpolation == .oklab ? "in oklab" : ""
        var head: [String] = []
        switch g.kind {
        case .linear:
            head.append("\(number(degrees(g.angle)))deg")
            if !space.isEmpty { head.append(space) }
            return "background: linear-gradient(\n  \(head.joined(separator: " ")),\n\(stops)\n);"
        case .radial:
            if !g.isCentered {
                let r = number(g.radialFraction * 100)
                head.append("ellipse \(r)% \(r)% at \(number(g.centerX * 100))% \(number(g.centerY * 100))%")
            }
            if !space.isEmpty { head.append(space) }
            let prefix = head.isEmpty ? "" : "  " + head.joined(separator: " ") + ",\n"
            return "background: radial-gradient(\n\(prefix)\(stops)\n);"
        case .conic:
            head.append("from \(number(degrees(g.angle)))deg")
            if !g.isCentered { head.append("at \(number(g.centerX * 100))% \(number(g.centerY * 100))%") }
            if !space.isEmpty { head.append(space) }
            return "background: conic-gradient(\n  \(head.joined(separator: " ")),\n\(stops)\n);"
        }
    }

    private static func component(_ v: Double) -> String { String(format: "%.3f", min(max(v, 0), 1)) }

    static func swiftUI(_ g: BlendGradient) -> String {
        let stops = g.sortedStops.map { s -> String in
            let c = s.color
            let opacity = c.a < 0.9995 ? ", opacity: \(component(c.a))" : ""
            let color = "Color(red: \(component(c.r)), green: \(component(c.g)), blue: \(component(c.b))\(opacity))"
            return "            .init(color: \(color), location: \(String(format: "%.3f", s.location))),"
        }.joined(separator: "\n")
        let space = g.interpolation == .oklab ? ".colorSpace(.perceptual)" : ""
        let gradient = "        Gradient(stops: [\n\(stops)\n        ])\(space),"
        func unit(_ p: UnitPoint) -> String { "UnitPoint(x: \(String(format: "%.3f", p.x)), y: \(String(format: "%.3f", p.y)))" }
        let center = "        center: \(unit(UnitPoint(x: g.centerX, y: g.centerY)))"
        let tail: String
        let fn: String
        switch g.kind {
        case .linear:
            fn = "linearGradient"
            let (start, end) = g.linearPoints(size: CGSize(width: 1, height: 1))
            tail = "        startPoint: \(unit(start)),\n        endPoint: \(unit(end))"
        case .radial:
            fn = "ellipticalGradient"
            tail = "\(center),\n        endRadiusFraction: \(String(format: "%.3f", g.radialFraction))"
        case .conic:
            fn = "conicGradient"
            tail = "\(center),\n        angle: .degrees(\(number(degrees(g.angle - 90))))"
        }
        return "Rectangle()\n    .fill(.\(fn)(\n\(gradient)\n\(tail)\n    ))"
    }

    /// The suggested PNG file name: the gradient's name, or "Gradient" when it has none.
    static func fileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.isEmpty || trimmed.hasPrefix(".") ? "Gradient" : trimmed) + ".png"
    }

    static func code(_ g: BlendGradient, format: CodeFormat) -> String {
        switch format {
        case .css: css(g)
        case .swiftUI: swiftUI(g)
        case .hex: g.hexList
        }
    }

    /// Draws the gradient into a `width` by `height` pixel image with Core Graphics, the same geometry as the
    /// preview. Safe off the main thread, so big exports never stall the window.
    static func image(_ g: BlendGradient, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let opaque = g.stops.allSatisfy { $0.color.a >= 0.9995 }
        let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { return nil }
        let stops = g.renderStops()
        let colors = stops.map { CGColor(colorSpace: space, components: [$0.0.r, $0.0.g, $0.0.b, $0.0.a])! } as CFArray
        var locations = stops.map { CGFloat($0.1) }
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: &locations) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        // Work in a y-down space like SwiftUI and CSS.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        let extend: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        switch g.kind {
        case .linear:
            let (start, end) = g.linearPoints(size: CGSize(width: w, height: h))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: start.x * w, y: start.y * h),
                                   end: CGPoint(x: end.x * w, y: end.y * h), options: extend)
        case .radial:
            // A circle in unit space is the ellipse CSS draws: stretch a unit radial to the box.
            ctx.translateBy(x: g.centerX * w, y: g.centerY * h)
            ctx.scaleBy(x: w, y: h)
            ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero,
                                   endRadius: g.radialFraction, options: extend)
        case .conic:
            CGContextDrawConicGradient(ctx, gradient, CGPoint(x: g.centerX * w, y: g.centerY * h),
                                       (g.angle - 90) * .pi / 180)
        }
        return ctx.makeImage()
    }

    /// Renders the gradient to PNG data of exactly `width` by `height` pixels.
    static func png(_ g: BlendGradient, width: Int, height: Int) -> Data? {
        guard let cg = image(g, width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - Presets and random

enum Presets {
    static let all: [BlendGradient] = [
        BlendGradient(name: "Candy", angle: 120, colors: [0xFF8FB1, 0xC88BFF, 0x7A6CFF]),
        BlendGradient(name: "Aurora", angle: 135, colors: [0x00C9A7, 0x4D8CFF, 0xA56BFF]),
        BlendGradient(name: "Peach Fizz", angle: 160, colors: [0xFFD3A5, 0xFD6585]),
        BlendGradient(name: "Lagoon", angle: 200, colors: [0x80D0C7, 0x13547A]),
        BlendGradient(name: "Citrus", angle: 90, colors: [0xF9F047, 0x0FD850]),
        BlendGradient(name: "Ember", kind: .radial, center: (0.5, 0.7), colors: [0xFFE29F, 0xFFA99F, 0xFF719A, 0x8F2D56]),
        BlendGradient(name: "Spectrum", kind: .conic, angle: 0,
                      colors: [0xFF5E7E, 0xFFC95E, 0x6CF08B, 0x5EC8FF, 0xB45EFF, 0xFF5E7E]),
        BlendGradient(name: "Lavender Mist", angle: 45, colors: [0xE0C3FC, 0x8EC5FC]),
        BlendGradient(name: "Deep Sea", kind: .radial, center: (0.3, 0.25), colors: [0x4E8FB8, 0x2B5876, 0x231942]),
        BlendGradient(name: "Mango", angle: 30, colors: [0xFFE53B, 0xFF2525]),
        BlendGradient(name: "Midnight", angle: 180, colors: [0x2C5364, 0x203A43, 0x0F2027]),
        BlendGradient(name: "Glacier", angle: 160, colors: [0xF2F7FF, 0x9AC5F4, 0x5B8DEF]),
        BlendGradient(name: "Prism", kind: .conic, angle: 45, center: (0.5, 0.5),
                      colors: [0xFFB3C7, 0xB9A6FF, 0x8FE3FF, 0xB8FFC9, 0xFFB3C7]),
    ]
}

/// A random generator that seeds from a closure, so the self test can make it repeatable.
struct GradientDice {
    var next: () -> Double = { Double.random(in: 0..<1) }

    mutating func roll() -> BlendGradient {
        func r(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
        let count = 2 + Int(r(0, 2.999))
        let hue = r(0, 360), step = r(28, 85) * (next() < 0.5 ? -1 : 1)
        let lightStart = r(0.62, 0.9), lightEnd = r(0.5, 0.85)
        let colors = (0..<count).map { i -> RGBA in
            let f = Double(i) / Double(count - 1)
            return OKLab.lch(lightStart + (lightEnd - lightStart) * f, r(0.1, 0.2), hue + step * Double(i))
        }
        let roll = next()
        let kind: GradientKind = roll < 0.65 ? .linear : (roll < 0.88 ? .radial : .conic)
        var g = BlendGradient(name: "Random", kind: kind, angle: (r(0, 24).rounded(.down)) * 15, colors: [])
        g.stops = colors.enumerated().map { i, c in Stop(color: c, location: Double(i) / Double(count - 1)) }
        if kind == .conic, let first = g.stops.first { g.stops.append(Stop(color: first.color, location: 1)) }
        if kind == .conic { for i in g.stops.indices { g.stops[i].location = Double(i) / Double(g.stops.count - 1) } }
        return g
    }
}

// MARK: - Store

enum SidebarItem: Hashable {
    case library(UUID)
    case preset(UUID)
}

struct PNGSize: Hashable, Sendable {
    var name: String, width: Int, height: Int
    static let presets: [PNGSize] = [
        PNGSize(name: "Desktop", width: 2560, height: 1440), PNGSize(name: "Full HD", width: 1920, height: 1080),
        PNGSize(name: "4K", width: 3840, height: 2160), PNGSize(name: "Square", width: 1024, height: 1024),
        PNGSize(name: "iPhone", width: 1179, height: 2556), PNGSize(name: "Social banner", width: 1500, height: 500),
    ]
}

@MainActor
final class BlendModel: ObservableObject {
    static let app = "Blend"

    @Published var library: [BlendGradient]
    @Published private(set) var current: BlendGradient
    @Published var selection: SidebarItem?
    @Published var selectedStop: UUID?
    @Published var codeFormat: CodeFormat = .css
    @Published var showingExport = false
    @Published var exportWidth = 2560
    @Published var exportHeight = 1440
    @Published var notice: String?
    @Published var lastExport: URL?
    /// True while a text field has keyboard focus, so Undo and Delete go to the text instead of the gradient.
    @Published var textFocused = false
    /// True while a PNG export renders in the background.
    @Published private(set) var exporting = false
    private var exportTask: Task<Void, Never>?
    /// The library gradient deleted last and where it was, for the notice's Undo button.
    @Published private(set) var recentlyDeleted: (gradient: BlendGradient, index: Int)?

    private let persists: Bool
    private var undoStack: [BlendGradient] = []
    private var redoStack: [BlendGradient] = []
    private var lastKey = ""
    private var lastEdit = Date.distantPast
    private var dice = GradientDice()
    private var saveTask: DispatchWorkItem?

    init(persists: Bool = !Desktop.isSnapshot) {
        self.persists = persists
        let saved = persists ? Self.loadLibrary() : []
        library = saved
        if let first = saved.first {
            current = first
            selection = .library(first.id)
        } else {
            current = Presets.all[0]
            selection = .preset(Presets.all[0].id)
        }
        selectedStop = current.sortedStops.first?.id
        if persists {
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            }
        }
    }

    /// Reads the library, repairing odd values. A file that cannot be read is set aside, never overwritten.
    private static func loadLibrary() -> [BlendGradient] {
        let url = Storage.url(app: app, file: "library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let saved = Storage.load([BlendGradient].self, app: app, file: "library.json") else {
            let stamp = Int(Date().timeIntervalSince1970)
            try? FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
                .appendingPathComponent("library unreadable \(stamp).json"))
            return []
        }
        return repaired(saved)
    }

    /// Sanitises each gradient and gives duplicate ids fresh ones.
    static func repaired(_ list: [BlendGradient]) -> [BlendGradient] {
        var ids = Set<UUID>()
        return list.map { g in
            var g = g.sanitized
            if !ids.insert(g.id).inserted { g.id = UUID() }
            return g
        }
    }

    static var demo: BlendModel {
        let m = BlendModel(persists: false)
        m.library = [
            BlendGradient(name: "Launch hero", angle: 120, colors: [0xFFC48A, 0xFF7AA8, 0x9C7CFF, 0x5CC8FF]),
            BlendGradient(name: "Pricing card", kind: .radial, center: (0.3, 0.2), colors: [0xFFF1C1, 0xFFB38A, 0xE85D75]),
            BlendGradient(name: "Night mode", angle: 200, colors: [0x3A6073, 0x16222A]),
            BlendGradient(name: "Loading ring", kind: .conic, angle: 0, colors: [0x7A6CFF, 0x38D9F5, 0x7A6CFF]),
        ]
        m.current = m.library[0]
        m.selection = .library(m.library[0].id)
        m.selectedStop = m.current.sortedStops[1].id
        return m
    }

    var isInLibrary: Bool { library.contains { $0.id == current.id } }
    var selectedStopValue: Stop? { current.stops.first { $0.id == selectedStop } }
    var code: String { Export.code(current, format: codeFormat) }

    // MARK: Editing

    /// Applies a change with undo. Edits with the same `key` within a moment coalesce into one undo step,
    /// so a drag, a slider or the colour panel make a single entry.
    func edit(_ key: String = "", _ change: (inout BlendGradient) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        let now = Date()
        if key.isEmpty || key != lastKey || now.timeIntervalSince(lastEdit) > 0.8 {
            undoStack.append(current)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastKey = key
        lastEdit = now
        current = next
        writeBack()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        restore(next)
    }

    private func restore(_ g: BlendGradient) {
        lastKey = ""
        current = g
        if library.contains(where: { $0.id == g.id }) {
            selection = .library(g.id)
        } else if Presets.all.contains(where: { $0.id == g.id }) {
            selection = .preset(g.id)
        } else {
            selection = nil
        }
        if !current.stops.contains(where: { $0.id == selectedStop }) { selectedStop = current.sortedStops.first?.id }
        writeBack()
    }

    /// Library gradients save as they are edited.
    private func writeBack() {
        guard let i = library.firstIndex(where: { $0.id == current.id }) else { return }
        library[i] = current
        scheduleSave()
    }

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Storage.save(self.library, app: Self.app, file: "library.json")
        }
        saveTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
    }

    /// Writes a pending save straight away, when the app quits.
    func saveNow() {
        guard persists, let task = saveTask, !task.isCancelled else { return }
        task.cancel()
        saveTask = nil
        Storage.save(library, app: Self.app, file: "library.json")
    }

    private func load(_ g: BlendGradient) {
        current = g
        undoStack.removeAll()
        redoStack.removeAll()
        lastKey = ""
        selectedStop = g.sortedStops.first?.id
    }

    func select(_ item: SidebarItem?) {
        guard let item, item != selection else { return }
        selection = item
        switch item {
        case .library(let id): if let g = library.first(where: { $0.id == id }) { load(g) }
        case .preset(let id): if let g = Presets.all.first(where: { $0.id == id }) { load(g) }
        }
    }

    // MARK: Stops

    func addStop(at location: Double) {
        let t = min(max(location, 0), 1)
        let stop = Stop(color: current.color(at: t), location: t)
        edit { $0.stops.append(stop) }
        selectedStop = stop.id
    }

    /// Adds a stop in the middle of the widest gap.
    func addStopInWidestGap() {
        let s = current.sortedStops
        var best = (0.0, 0.5)
        for (p, q) in zip(s, s.dropFirst()) where q.location - p.location > best.0 {
            best = (q.location - p.location, (p.location + q.location) / 2)
        }
        addStop(at: best.1)
    }

    var canDeleteStop: Bool { current.stops.count > 2 && selectedStop != nil }

    func deleteSelectedStop() {
        guard canDeleteStop, let id = selectedStop else { return }
        let order = current.sortedStops
        let index = order.firstIndex { $0.id == id } ?? 0
        edit { $0.stops.removeAll { $0.id == id } }
        let remaining = current.sortedStops
        selectedStop = remaining[min(index, remaining.count - 1)].id
    }

    func setStop(_ id: UUID, location: Double, key: String = "move") {
        edit(key + id.uuidString) { g in
            if let i = g.stops.firstIndex(where: { $0.id == id }) { g.stops[i].location = min(max(location, 0), 1) }
        }
    }

    func setStop(_ id: UUID, color: RGBA) {
        edit("color" + id.uuidString) { g in
            if let i = g.stops.firstIndex(where: { $0.id == id }) { g.stops[i].color = color }
        }
    }

    func selectNeighbourStop(_ delta: Int) {
        let s = current.sortedStops
        guard let i = s.firstIndex(where: { $0.id == selectedStop }) else { selectedStop = s.first?.id; return }
        selectedStop = s[min(max(i + delta, 0), s.count - 1)].id
    }

    func reverse() {
        edit { g in for i in g.stops.indices { g.stops[i].location = 1 - g.stops[i].location } }
    }

    func distribute() {
        let order = current.sortedStops.map(\.id)
        guard order.count > 1 else { return }
        edit { g in
            for (n, id) in order.enumerated() {
                if let i = g.stops.firstIndex(where: { $0.id == id }) { g.stops[i].location = Double(n) / Double(order.count - 1) }
            }
        }
    }

    // MARK: Library

    func newGradient() {
        var g = BlendGradient(name: "Untitled", angle: 90, colors: [0xFF8FB1, 0x7A6CFF])
        g.name = uniqueName("Untitled")
        library.insert(g, at: 0)
        selection = .library(g.id)
        load(g)
        scheduleSave()
    }

    /// Rolls a new gradient. It is one undo step, so a gradient rolled past can be brought back.
    func randomize() {
        var g = dice.roll()
        g.name = "Random"
        undoStack.append(current)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastKey = ""
        selection = nil
        current = g
        selectedStop = g.sortedStops.first?.id
    }

    /// Saves the gradient on screen to the library (presets and random gradients become a copy there).
    func saveToLibrary() {
        guard !isInLibrary else { notice = "Already in your library"; return }
        var g = current
        g.id = UUID()
        g.name = uniqueName(current.name)
        library.insert(g, at: 0)
        selection = .library(g.id)
        let stop = current.sortedStops.firstIndex { $0.id == selectedStop }
        load(g)
        if let stop { selectedStop = g.sortedStops[stop].id }
        scheduleSave()
        notice = "Saved to library"
    }

    func duplicate(_ id: UUID) {
        guard let source = library.first(where: { $0.id == id }) ?? Presets.all.first(where: { $0.id == id }) else { return }
        var g = source
        g.id = UUID()
        g.name = uniqueName(source.name + " copy")
        let at = (library.firstIndex { $0.id == id }).map { $0 + 1 } ?? 0
        library.insert(g, at: at)
        selection = .library(g.id)
        load(g)
        scheduleSave()
    }

    func delete(_ id: UUID) {
        guard let i = library.firstIndex(where: { $0.id == id }) else { return }
        let gone = library.remove(at: i)
        recentlyDeleted = (gone, i)
        notice = "Deleted \(gone.name.isEmpty ? "Untitled" : gone.name)"
        scheduleSave()
        if current.id == id {
            if library.indices.contains(min(i, library.count - 1)) {
                let next = library[min(i, library.count - 1)]
                selection = .library(next.id)
                load(next)
            } else {
                selection = .preset(Presets.all[0].id)
                load(Presets.all[0])
            }
        }
    }

    /// Puts the gradient deleted last back where it was and opens it.
    func undoDelete() {
        guard let (g, i) = recentlyDeleted else { return }
        recentlyDeleted = nil
        library.insert(g, at: min(i, library.count))
        selection = .library(g.id)
        load(g)
        scheduleSave()
        notice = nil
    }

    func rename(_ name: String) {
        edit("name") { $0.name = name }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(library.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: Output

    func copy(_ format: CodeFormat) {
        guard !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Export.code(current, format: format), forType: .string)
        notice = "Copied \(format == .hex ? "hex list" : format.title)"
    }

    func exportPNG() {
        let width = min(max(exportWidth, 1), 8192), height = min(max(exportHeight, 1), 8192)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Export.fileName(current.name)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let gradient = current
        exporting = true
        notice = "Exporting \(width) × \(height)"
        // Rendering and encoding run off the main thread; the file is written only if the export was not cancelled.
        exportTask = Task {
            let data = await Task.detached(priority: .userInitiated) {
                Export.png(gradient, width: width, height: height)
            }.value
            guard !Task.isCancelled else { return }
            exporting = false
            exportTask = nil
            guard let data else { notice = "Could not render the image"; return }
            do {
                try data.write(to: url, options: .atomic)
                lastExport = url
                notice = "Saved \(url.lastPathComponent)"
            } catch {
                notice = "Could not save: \(error.localizedDescription)"
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exporting = false
        notice = "Export cancelled"
    }
}
