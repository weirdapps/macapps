import AppKit
import CoreGraphics
import Foundation
import Kit

// MARK: - Colour maths

/// An sRGB colour with components in 0...1.
struct RGB: Hashable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    var bytes: (Int, Int, Int) { (Self.byte(r), Self.byte(g), Self.byte(b)) }
    var hex: String {
        let (r, g, b) = bytes
        return String(format: "#%02X%02X%02X", r, g, b)
    }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    /// Relative luminance (WCAG), for choosing a readable label colour.
    var luminance: Double { 0.2126 * ColorMath.linear(r) + 0.7152 * ColorMath.linear(g) + 0.0722 * ColorMath.linear(b) }

    static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ hex: UInt32) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    /// Parses "#RRGGBB", "RRGGBB" or "#RGB".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(v)
    }
}

struct Lab: Sendable {
    var l: Double
    var a: Double
    var b: Double

    func distance2(_ o: Lab) -> Double {
        let dl = l - o.l, da = a - o.a, db = b - o.b
        return dl * dl + da * da + db * db
    }
}

enum ColorMath {
    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    // D65 reference white.
    static let xn = 0.95047, yn = 1.0, zn = 1.08883
    static let epsilon = 216.0 / 24389, kappa = 24389.0 / 27

    static func lab(_ c: RGB) -> Lab {
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / xn
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / yn
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / zn
        func f(_ t: Double) -> Double { t > epsilon ? cbrt(t) : (kappa * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return Lab(l: 116 * fy - 16, a: 500 * (fx - fy), b: 200 * (fy - fz))
    }

    static func rgb(_ lab: Lab) -> RGB {
        let fy = (lab.l + 16) / 116, fx = fy + lab.a / 500, fz = fy - lab.b / 200
        func inv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > epsilon ? t3 : (116 * t - 16) / kappa }
        let x = inv(fx) * xn, y = (lab.l > kappa * epsilon ? fy * fy * fy : lab.l / kappa) * yn, z = inv(fz) * zn
        let r = 3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b = 0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        func clamp(_ v: Double) -> Double { min(max(gamma(max(v, 0)), 0), 1) }
        return RGB(r: clamp(r), g: clamp(g), b: clamp(b))
    }

    /// Hue in degrees 0..<360, saturation and lightness in 0...1.
    static func hsl(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b)
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double
        if mx == c.r { h = (c.g - c.b) / d } else if mx == c.g { h = (c.b - c.r) / d + 2 } else { h = (c.r - c.g) / d + 4 }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    static func rgbText(_ c: RGB) -> String {
        let (r, g, b) = c.bytes
        return "\(r), \(g), \(b)"
    }

    static func hslText(_ c: RGB) -> String {
        let (h, s, l) = hsl(c)
        return "\(Int(h.rounded()) % 360)\u{00B0}, \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
    }
}

// MARK: - Bitmap

/// An RGBA8 sRGB bitmap (premultiplied alpha) with its CGImage, scaled so its longest side is at most `maxSide`.
struct Bitmap: @unchecked Sendable {
    let width: Int
    let height: Int
    let data: [UInt8]
    let image: CGImage

    init?(_ source: CGImage, maxSide: Int) {
        let scale = min(1, Double(maxSide) / Double(max(source.width, source.height)))
        let w = max(1, Int((Double(source.width) * scale).rounded())), h = max(1, Int((Double(source.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let made = ctx.makeImage(), let raw = ctx.data else { return nil }
        width = w
        height = h
        data = Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        image = made
    }

    /// The colour of the pixel at `x, y` (top-left origin), or nil when it is mostly transparent.
    func color(x: Int, y: Int) -> RGB? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        let a = Double(data[i + 3])
        guard a >= 128 else { return nil }
        return RGB(r: Double(data[i]) / a, g: Double(data[i + 1]) / a, b: Double(data[i + 2]) / a)
    }
}

// MARK: - Palette extraction

struct Swatch: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var color: RGB
    /// Fraction of the image this colour covers; nil for a colour picked by hand.
    var share: Double?
    /// Where a picked colour came from, in 0...1 image coordinates (top-left origin).
    var point: CGPoint?

    var isPicked: Bool { share == nil }
}

struct Extraction: Sendable {
    var swatches: [Swatch]
    /// The cluster centres, in the same order as `swatches`.
    var centres: [Lab] = []
    /// Per pixel of the sample bitmap, the index of its swatch, or -1 for transparent pixels.
    var assignment: [Int16]
    var width: Int
    var height: Int
}

/// A small deterministic generator (SplitMix64) so the same image always gives the same palette.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum Extractor {
    static let range = 5...12
    static let seed: UInt64 = 0x4875_6573 // "Hues"

    /// Dominant colours by weighted k-means in CIE Lab over a 15 bit colour histogram, seeded with k-means++.
    static func extract(_ bitmap: Bitmap, count requested: Int) -> Extraction {
        let bins = 1 << 15
        var weight = [Double](repeating: 0, count: bins)
        var sumR = [Double](repeating: 0, count: bins), sumG = weight, sumB = weight
        var pixelBin = [Int32](repeating: -1, count: bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                guard let c = bitmap.color(x: x, y: y) else { continue }
                let (r, g, b) = c.bytes
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                weight[key] += 1
                sumR[key] += c.r
                sumG[key] += c.g
                sumB[key] += c.b
                pixelBin[y * bitmap.width + x] = Int32(key)
            }
        }

        // One point per occupied bin, at the mean colour of its pixels.
        var points: [Lab] = [], weights: [Double] = [], pointOfBin = [Int32](repeating: -1, count: bins)
        for key in 0..<bins where weight[key] > 0 {
            let w = weight[key]
            pointOfBin[key] = Int32(points.count)
            points.append(ColorMath.lab(RGB(r: sumR[key] / w, g: sumG[key] / w, b: sumB[key] / w)))
            weights.append(w)
        }
        let total = weights.reduce(0, +)
        let k = min(requested, points.count)
        guard k > 0, total > 0 else { return Extraction(swatches: [], centres: [], assignment: [], width: bitmap.width, height: bitmap.height) }

        // k-means++ seeding: start at the heaviest colour, then pick far, heavy colours.
        var rng = SeededGenerator(seed: seed)
        var centres = [points[weights.indices.max { weights[$0] < weights[$1] }!]]
        var nearest = points.map { $0.distance2(centres[0]) }
        while centres.count < k {
            var sum = 0.0
            for i in points.indices { sum += weights[i] * nearest[i] }
            guard sum > 0 else { break }
            var target = rng.unit() * sum, chosen = points.count - 1
            for i in points.indices {
                target -= weights[i] * nearest[i]
                if target <= 0 { chosen = i; break }
            }
            centres.append(points[chosen])
            for i in points.indices { nearest[i] = min(nearest[i], points[i].distance2(points[chosen])) }
        }

        // Lloyd iterations.
        var label = [Int](repeating: 0, count: points.count)
        for iteration in 0..<50 {
            var changed = false
            for i in points.indices {
                var best = 0, bestD = Double.infinity
                for (c, centre) in centres.enumerated() {
                    let d = points[i].distance2(centre)
                    if d < bestD { bestD = d; best = c }
                }
                if label[i] != best { label[i] = best; changed = true }
            }
            var acc = [(l: Double, a: Double, b: Double, w: Double)](repeating: (0, 0, 0, 0), count: centres.count)
            for i in points.indices {
                let w = weights[i], p = points[i]
                acc[label[i]].l += p.l * w
                acc[label[i]].a += p.a * w
                acc[label[i]].b += p.b * w
                acc[label[i]].w += w
            }
            for c in centres.indices where acc[c].w > 0 {
                centres[c] = Lab(l: acc[c].l / acc[c].w, a: acc[c].a / acc[c].w, b: acc[c].b / acc[c].w)
            }
            if !changed && iteration > 0 { break }
        }

        var clusterWeight = [Double](repeating: 0, count: centres.count)
        for i in points.indices { clusterWeight[label[i]] += weights[i] }
        let order = centres.indices.filter { clusterWeight[$0] > 0 }.sorted {
            clusterWeight[$0] != clusterWeight[$1] ? clusterWeight[$0] > clusterWeight[$1] : centres[$0].l > centres[$1].l
        }
        var rank = [Int](repeating: -1, count: centres.count)
        for (r, c) in order.enumerated() { rank[c] = r }
        let swatches = order.map { Swatch(color: ColorMath.rgb(centres[$0]), share: clusterWeight[$0] / total) }
        let assignment = pixelBin.map { key -> Int16 in
            key < 0 ? -1 : Int16(rank[label[Int(pointOfBin[Int(key)])]])
        }
        return Extraction(swatches: swatches, centres: order.map { centres[$0] }, assignment: assignment,
                          width: bitmap.width, height: bitmap.height)
    }

    /// The same palette with every pixel of a (larger) `bitmap` assigned to its nearest centre, for a crisp hover mask.
    static func assign(_ bitmap: Bitmap, to e: Extraction) -> Extraction {
        var out = e
        out.width = bitmap.width
        out.height = bitmap.height
        guard !e.centres.isEmpty else { out.assignment = []; return out }
        var cache = [Int16](repeating: -2, count: 1 << 15)
        var assignment = [Int16](repeating: -1, count: bitmap.width * bitmap.height)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                guard let c = bitmap.color(x: x, y: y) else { continue }
                let (r, g, b) = c.bytes
                let key = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                if cache[key] == -2 {
                    let lab = ColorMath.lab(c)
                    var best = 0, bestD = Double.infinity
                    for (i, centre) in e.centres.enumerated() {
                        let d = lab.distance2(centre)
                        if d < bestD { bestD = d; best = i }
                    }
                    cache[key] = Int16(best)
                }
                assignment[y * bitmap.width + x] = cache[key]
            }
        }
        out.assignment = assignment
        return out
    }

    /// A mask over the sample bitmap that dims every pixel not assigned to swatch `index`.
    static func mask(_ e: Extraction, index: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: e.width * e.height * 4)
        for (i, a) in e.assignment.enumerated() where Int(a) != index {
            bytes[i * 4 + 3] = 170 // Premultiplied black at two thirds.
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: e.width, height: e.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: e.width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

// MARK: - Export

enum ExportFormat: String, CaseIterable, Identifiable {
    case css, swift, json, png

    var id: String { rawValue }
    var title: String {
        switch self {
        case .css: "CSS Variables"
        case .swift: "Swift Code"
        case .json: "JSON"
        case .png: "PNG Swatch Strip"
        }
    }
    var fileExtension: String { rawValue }
    var symbol: String {
        switch self {
        case .css: "number"
        case .swift: "swift"
        case .json: "curlybraces"
        case .png: "photo"
        }
    }
}

enum Exporter {
    /// "Sunset over the bay.jpg" becomes ["sunset", "over", "the", "bay"].
    static func words(_ name: String) -> [String] {
        let base = (name as NSString).deletingPathExtension
        let words = base.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        guard let first = words.first else { return ["palette"] }
        return first.first?.isLetter == true ? words : ["palette"] + words
    }

    static func kebab(_ name: String) -> String { words(name).prefix(4).joined(separator: "-") }

    static func pascal(_ name: String) -> String {
        words(name).prefix(4).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func percent(_ s: Swatch) -> String {
        guard let share = s.share else { return "picked" }
        return "\(Int((share * 100).rounded()))%"
    }

    static func css(_ swatches: [Swatch], name: String) -> String {
        let prefix = kebab(name)
        var out = ":root {\n"
        for (i, s) in swatches.enumerated() {
            out += "  --\(prefix)-\(i + 1): \(s.color.hex.lowercased()); /* \(percent(s)) */\n"
        }
        return out + "}\n"
    }

    static func swift(_ swatches: [Swatch], name: String) -> String {
        let type = pascal(name) + "Palette"
        func n(_ v: Double) -> String { String(format: "%.3f", v) }
        var out = "import SwiftUI\n\nenum \(type) {\n"
        for (i, s) in swatches.enumerated() {
            out += "    static let color\(i + 1) = Color(red: \(n(s.color.r)), green: \(n(s.color.g)), blue: \(n(s.color.b))) // \(s.color.hex), \(percent(s))\n"
        }
        out += "\n    static let all = [\(swatches.indices.map { "color\($0 + 1)" }.joined(separator: ", "))]\n}\n"
        return out
    }

    struct JSONPalette: Codable, Equatable {
        struct Entry: Codable, Equatable {
            var hex: String
            var rgb: [Int]
            var hsl: [Int]
            var share: Double?
            var picked: Bool
        }
        var name: String
        var colors: [Entry]
    }

    static func jsonPalette(_ swatches: [Swatch], name: String) -> JSONPalette {
        JSONPalette(name: (name as NSString).deletingPathExtension, colors: swatches.map { s in
            let (r, g, b) = s.color.bytes
            let (h, sat, l) = ColorMath.hsl(s.color)
            return .init(hex: s.color.hex, rgb: [r, g, b], hsl: [Int(h.rounded()) % 360, Int((sat * 100).rounded()), Int((l * 100).rounded())],
                         share: s.share.map { ($0 * 1000).rounded() / 1000 }, picked: s.isPicked)
        })
    }

    static func json(_ swatches: [Swatch], name: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(jsonPalette(swatches, name: name))) ?? Data()
        return (String(data: data, encoding: .utf8) ?? "") + "\n"
    }

    static func text(_ format: ExportFormat, _ swatches: [Swatch], name: String) -> String {
        switch format {
        case .css: css(swatches, name: name)
        case .swift: swift(swatches, name: name)
        case .json, .png: json(swatches, name: name)
        }
    }

    /// Equal blocks with the hex code printed at the bottom of each, 240 x 320 px per colour.
    static func strip(_ swatches: [Swatch]) -> NSBitmapImageRep? {
        guard !swatches.isEmpty else { return nil }
        let block = 240, height = 320
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: block * swatches.count, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, s) in swatches.enumerated() {
            let rect = NSRect(x: i * block, y: 0, width: block, height: height)
            s.color.nsColor.setFill()
            rect.fill()
            let ink = s.color.luminance > 0.4 ? NSColor(white: 0, alpha: 0.72) : NSColor(white: 1, alpha: 0.9)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .semibold), .foregroundColor: ink,
            ]
            let label = s.color.hex as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: 28), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func data(_ format: ExportFormat, _ swatches: [Swatch], name: String) -> Data? {
        if format == .png { return strip(swatches)?.representation(using: .png, properties: [:]) }
        return text(format, swatches, name: name).data(using: .utf8)
    }
}

// MARK: - History

struct SavedPalette: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var date: Date
    var count: Int
    var swatches: [Swatch]
}

/// Recent palettes as JSON, with a downscaled JPEG of each source image beside it.
struct HistoryStore {
    let directory: URL
    static let limit = 30

    static var standard: HistoryStore {
        HistoryStore(directory: Storage.url(app: "Hues", file: "History"))
    }

    var indexURL: URL { directory.appendingPathComponent("history.json") }
    func imageURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }

    func load() -> [SavedPalette] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedPalette].self, from: data)) ?? []
    }

    func save(_ items: [SavedPalette]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    func saveImage(_ image: CGImage, id: UUID) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])?.write(to: imageURL(id), options: .atomic)
    }

    func loadImage(_ id: UUID) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(imageURL(id) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func removeImage(_ id: UUID) { try? FileManager.default.removeItem(at: imageURL(id)) }

    /// Puts `item` first, replacing an older copy with the same id, and trims to `limit`. Returns ids that fell off.
    static func upsert(_ item: SavedPalette, into items: inout [SavedPalette]) -> [UUID] {
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        guard items.count > limit else { return [] }
        let dropped = items[limit...].map(\.id)
        items.removeLast(items.count - limit)
        return dropped
    }
}

// MARK: - Loading images

enum ImageLoader {
    static func cgImage(url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decode at most 2048 px on the long side, honouring EXIF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func cgImage(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
