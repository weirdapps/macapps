import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Colour

/// One pixel: 8-bit sRGB with straight (not premultiplied) alpha. Alpha 0 is an empty pixel.
struct RGBA: Hashable, Codable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ hex: UInt32) {
        self.init(r: UInt8((hex >> 16) & 0xFF), g: UInt8((hex >> 8) & 0xFF), b: UInt8(hex & 0xFF))
    }

    /// Parses "RRGGBB" or "RRGGBBAA", with or without a leading "#".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(v)
        } else {
            self.init(r: UInt8((v >> 24) & 0xFF), g: UInt8((v >> 16) & 0xFF), b: UInt8((v >> 8) & 0xFF), a: UInt8(v & 0xFF))
        }
    }

    var isClear: Bool { a == 0 }

    /// "RRGGBBAA", the file format's spelling.
    var hex8: String { String(format: "%02X%02X%02X%02X", r, g, b, a) }

    /// "#RRGGBB" for display, with the alpha percentage when it is not opaque.
    var display: String {
        let base = String(format: "#%02X%02X%02X", r, g, b)
        return a == 255 ? base : base + " \(Int((Double(a) / 255 * 100).rounded()))%"
    }

    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: byte(c.redComponent), g: byte(c.greenComponent), b: byte(c.blueComponent), a: byte(c.alphaComponent))
    }

    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = RGBA(hex: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad colour \(s)"))
        }
        self = c
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex8)
    }
}

enum Palette {
    /// Sixteen balanced colours for small sprites (the PICO-8 set, which covers skin, foliage, sky and shadow).
    static let presets: [RGBA] = [
        0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
        0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
    ].map { RGBA($0) }

    static let recentLimit = 8

    /// Moves `color` to the front of `recents`, without duplicates, keeping at most `recentLimit`.
    static func remember(_ color: RGBA, in recents: [RGBA]) -> [RGBA] {
        guard !color.isClear else { return recents }
        return Array(([color] + recents.filter { $0 != color }).prefix(recentLimit))
    }
}

// MARK: - Image

struct Point: Hashable {
    var x: Int, y: Int
}

/// The picture itself: a small grid of pixels, row by row from the top left.
struct PixelImage: Equatable, Codable {
    static let sizeRange = 1...64
    static let presetSizes = [8, 12, 16, 24, 32, 48, 64]

    private(set) var width: Int
    private(set) var height: Int
    private(set) var pixels: [RGBA]

    init(width: Int, height: Int, fill: RGBA = .clear) {
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    init(width: Int, height: Int, pixels: [RGBA]) throws {
        guard Self.sizeRange.contains(width), Self.sizeRange.contains(height) else { throw PixelError.tooLarge(width, height) }
        guard pixels.count == width * height else { throw PixelError.corrupt }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Builds an image from rows of characters, one colour per character; any unmapped character is empty.
    init(rows: [String], colors: [Character: RGBA]) {
        let w = rows.map(\.count).max() ?? 0
        self.init(width: w, height: rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() { self[x, y] = colors[ch] ?? .clear }
        }
    }

    func contains(_ p: Point) -> Bool { p.x >= 0 && p.y >= 0 && p.x < width && p.y < height }

    subscript(x: Int, y: Int) -> RGBA {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    subscript(p: Point) -> RGBA {
        get { self[p.x, p.y] }
        set { if contains(p) { self[p.x, p.y] = newValue } }
    }

    var isBlank: Bool { pixels.allSatisfy(\.isClear) }

    /// The point reflected across the vertical centre line.
    func mirrored(_ p: Point) -> Point { Point(x: width - 1 - p.x, y: p.y) }

    mutating func plot(_ points: [Point], _ color: RGBA, mirror: Bool) {
        for p in points {
            self[p] = color
            if mirror { self[mirrored(p)] = color }
        }
    }

    /// 4-connected flood fill from `start`, replacing the contiguous region of its colour.
    mutating func fill(from start: Point, with color: RGBA) {
        guard contains(start) else { return }
        let target = self[start]
        guard target != color else { return }
        var stack = [start]
        while let p = stack.popLast() {
            guard contains(p), self[p] == target else { continue }
            self[p] = color
            stack += [Point(x: p.x + 1, y: p.y), Point(x: p.x - 1, y: p.y), Point(x: p.x, y: p.y + 1), Point(x: p.x, y: p.y - 1)]
        }
    }

    /// A copy at a new size, the old picture centred on the new canvas (cropped or padded with empty pixels).
    func resized(width w: Int, height h: Int) -> PixelImage {
        var out = PixelImage(width: w, height: h)
        let dx = (w - width) / 2, dy = (h - height) / 2
        for y in 0..<height {
            for x in 0..<width { out[Point(x: x + dx, y: y + dy)] = self[x, y] }
        }
        return out
    }

    // MARK: Shapes

    /// Bresenham's line from `a` to `b`, both ends included.
    static func line(_ a: Point, _ b: Point) -> [Point] {
        var points: [Point] = []
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        while true {
            points.append(Point(x: x, y: y))
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
        }
        return points
    }

    /// The outline of the rectangle with corners `a` and `b`, each pixel once.
    static func rectangle(_ a: Point, _ b: Point) -> [Point] {
        let x0 = min(a.x, b.x), x1 = max(a.x, b.x), y0 = min(a.y, b.y), y1 = max(a.y, b.y)
        var points: [Point] = []
        for x in x0...x1 {
            points.append(Point(x: x, y: y0))
            if y1 != y0 { points.append(Point(x: x, y: y1)) }
        }
        if y1 - y0 > 1 {
            for y in (y0 + 1)..<y1 {
                points.append(Point(x: x0, y: y))
                if x1 != x0 { points.append(Point(x: x1, y: y)) }
            }
        }
        return points
    }

    // MARK: File format

    private enum CodingKeys: String, CodingKey { case format, version, width, height, pixels }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height),
                      pixels: c.decode([RGBA].self, forKey: .pixels))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("pixel", forKey: .format)
        try c.encode(1, forKey: .version)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(pixels, forKey: .pixels)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> PixelImage {
        do { return try JSONDecoder().decode(PixelImage.self, from: data) } catch let e as PixelError { throw e } catch {
            throw PixelError.corrupt
        }
    }

    // MARK: PNG

    /// A CGImage at `scale` device pixels per picture pixel, nearest neighbour, straight alpha.
    func cgImage(scale: Int = 1) -> CGImage? {
        let w = width * scale, h = height * scale
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = self[x / scale, y / scale], i = (y * w + x) * 4
                bytes[i] = c.r; bytes[i + 1] = c.g; bytes[i + 2] = c.b; bytes[i + 3] = c.a
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func pngData(scale: Int) throws -> Data {
        guard let image = cgImage(scale: scale) else { throw PixelError.unreadable }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw PixelError.unreadable }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw PixelError.unreadable }
        return data as Data
    }

    /// Reads a PNG (or any image ImageIO knows). A picture exported at a scale is reduced back to its own pixels;
    /// anything still larger than 64 px on a side is refused rather than resampled.
    static func importing(_ data: Data) throws -> PixelImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PixelError.unreadable }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w * h <= 4096 * 4096 else { throw PixelError.tooLarge(w, h) }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw PixelError.unreadable }
        var pixels = [RGBA](repeating: .clear, count: w * h)
        for i in 0..<(w * h) {
            let a = bytes[i * 4 + 3]
            guard a > 0 else { continue }
            func straight(_ v: UInt8) -> UInt8 { a == 255 ? v : UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
            pixels[i] = RGBA(r: straight(bytes[i * 4]), g: straight(bytes[i * 4 + 1]), b: straight(bytes[i * 4 + 2]), a: a)
        }
        let k = blockScale(pixels, width: w, height: h)
        let nw = w / k, nh = h / k
        guard sizeRange.contains(nw), sizeRange.contains(nh) else { throw PixelError.tooLarge(nw, nh) }
        var reduced = [RGBA](repeating: .clear, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw { reduced[y * nw + x] = pixels[(y * k) * w + x * k] }
        }
        return try PixelImage(width: nw, height: nh, pixels: reduced)
    }

    /// The largest k such that the picture is made of uniform k by k blocks (1 when it is not upscaled).
    static func blockScale(_ pixels: [RGBA], width w: Int, height h: Int) -> Int {
        let common = gcd(w, h)
        // Never reduce below 8 px on the short side: a flat picture is uniform at every scale.
        let floor = min(w, h) >= 8 ? 8 : 1
        for k in stride(from: common, to: 1, by: -1) where common % k == 0 && min(w, h) / k >= floor {
            var uniform = true
            check: for y in 0..<h {
                for x in 0..<w where pixels[y * w + x] != pixels[(y - y % k) * w + (x - x % k)] {
                    uniform = false
                    break check
                }
            }
            if uniform { return k }
        }
        return 1
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}

enum PixelError: LocalizedError, Equatable {
    case corrupt, unreadable, tooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .corrupt: "The file is not a Pixel document, or it is damaged."
        case .unreadable: "The image could not be read."
        case .tooLarge(let w, let h): "The image is \(w) × \(h) pixels. Pixel edits pictures up to 64 × 64."
        }
    }
}

// MARK: - Document

extension UTType {
    static let pixelDocument = UTType(exportedAs: "com.weirdapps.pixel", conformingTo: .json)
}

final class PixelDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pixelDocument] }

    @Published var image: PixelImage

    init(image: PixelImage = PixelImage(width: 16, height: 16)) {
        self.image = image
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw PixelError.corrupt }
        image = try PixelImage.decode(data)
    }

    func snapshot(contentType: UTType) throws -> PixelImage { image }

    func fileWrapper(snapshot: PixelImage, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.jsonData())
    }

    /// Replaces the picture as one undoable step named `action`; does nothing when the picture is unchanged.
    func commit(from old: PixelImage, action: String, undoManager: UndoManager?) {
        guard old != image else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] doc in
            doc.replace(with: old, action: action, undoManager: undoManager)
        }
        undoManager?.setActionName(action)
    }

    func replace(with new: PixelImage, action: String, undoManager: UndoManager?) {
        let old = image
        image = new
        commit(from: old, action: action, undoManager: undoManager)
    }
}
