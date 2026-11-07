import AppKit
import ImageIO
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Style

/// An sRGB colour that survives JSON.
struct RGB: Codable, Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(_ color: Color) {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(c.redComponent)
        g = Double(c.greenComponent)
        b = Double(c.blueComponent)
    }

    var hex: UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

struct Preset: Identifiable {
    let name: String
    let top: RGB
    let bottom: RGB
    var id: String { name }
}

enum Presets {
    static let gradients: [Preset] = [
        Preset(name: "Coral", top: RGB(hex: 0xFF7A59), bottom: RGB(hex: 0xD9345F)),
        Preset(name: "Sunrise", top: RGB(hex: 0xFFC371), bottom: RGB(hex: 0xFF5F6D)),
        Preset(name: "Peach", top: RGB(hex: 0xFFE0C2), bottom: RGB(hex: 0xF4908C)),
        Preset(name: "Grape", top: RGB(hex: 0xC471F5), bottom: RGB(hex: 0x5B3FE0)),
        Preset(name: "Ocean", top: RGB(hex: 0x4FACFE), bottom: RGB(hex: 0x3A47D5)),
        Preset(name: "Lagoon", top: RGB(hex: 0x43E8C9), bottom: RGB(hex: 0x1F86D6)),
        Preset(name: "Meadow", top: RGB(hex: 0xB8E36B), bottom: RGB(hex: 0x2E9E7A)),
        Preset(name: "Mist", top: RGB(hex: 0xEEF2F8), bottom: RGB(hex: 0xC5D3E8)),
        Preset(name: "Dusk", top: RGB(hex: 0xF5A47F), bottom: RGB(hex: 0x4A3B8F)),
        Preset(name: "Night", top: RGB(hex: 0x3A4668), bottom: RGB(hex: 0x10131F)),
    ]

    static let solids: [Preset] = [
        Preset(name: "White", top: RGB(hex: 0xFFFFFF), bottom: RGB(hex: 0xFFFFFF)),
        Preset(name: "Silver", top: RGB(hex: 0xE6E7EC), bottom: RGB(hex: 0xE6E7EC)),
        Preset(name: "Sand", top: RGB(hex: 0xF2E6D3), bottom: RGB(hex: 0xF2E6D3)),
        Preset(name: "Graphite", top: RGB(hex: 0x3B3C42), bottom: RGB(hex: 0x3B3C42)),
        Preset(name: "Black", top: RGB(hex: 0x111114), bottom: RGB(hex: 0x111114)),
    ]
}

/// What sits behind the screenshot.
enum Backdrop: Codable, Hashable {
    case gradient(Int)
    case solid(Int)
    case custom

    /// Every backdrop in swatch order, for View > Next Background.
    static var all: [Backdrop] {
        Presets.gradients.indices.map { .gradient($0) } + Presets.solids.indices.map { .solid($0) } + [.custom]
    }

    func stepped(by delta: Int) -> Backdrop {
        let list = Backdrop.all
        let i = list.firstIndex(of: self) ?? 0
        let n = list.count
        return list[((i + delta) % n + n) % n]
    }
}

enum Aspect: String, Codable, CaseIterable, Identifiable {
    case auto, wide, standard, square, twitter, instagram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .wide: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        case .twitter: "Twitter/X"
        case .instagram: "Instagram 4:5"
        }
    }

    /// Width over height, or nil to wrap the image with even padding.
    var ratio: Double? {
        switch self {
        case .auto: nil
        case .wide, .twitter: 16.0 / 9
        case .standard: 4.0 / 3
        case .square: 1
        case .instagram: 4.0 / 5
        }
    }

    /// Social presets export at the size the network shows, whatever the screenshot's size.
    var fixedSize: CGSize? {
        switch self {
        case .twitter: CGSize(width: 1600, height: 900)
        case .instagram: CGSize(width: 1080, height: 1350)
        default: nil
        }
    }
}

struct MatStyle: Codable, Equatable {
    var backdrop: Backdrop = .gradient(0)
    var customTop = RGB(hex: 0x6E8BFF)
    var customBottom = RGB(hex: 0xF76DB4)
    /// Padding as a fraction of the screenshot's longer side.
    var padding: Double = 0.08
    /// Corner radius in thousandths of the longer side.
    var radius: Double = 10
    /// Shadow strength, 0 to 1.
    var shadow: Double = 0.55
    var border = true
    var aspect: Aspect = .auto
    var scale = 1

    var colors: (top: RGB, bottom: RGB) {
        switch backdrop {
        case .gradient(let i): Presets.gradients.indices.contains(i) ? (Presets.gradients[i].top, Presets.gradients[i].bottom)
            : (Presets.gradients[0].top, Presets.gradients[0].bottom)
        case .solid(let i): Presets.solids.indices.contains(i) ? (Presets.solids[i].top, Presets.solids[i].bottom)
            : (Presets.solids[0].top, Presets.solids[0].bottom)
        case .custom: (customTop, customBottom)
        }
    }

    /// The same style with every value pulled back into the range the inspector offers, for a damaged or hand edited file.
    func sanitized() -> MatStyle {
        var s = self
        func clamp(_ v: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, lo), hi) : fallback }
        s.padding = clamp(padding, 0, 0.25, 0.08)
        s.radius = clamp(radius, 0, 40, 10)
        s.shadow = clamp(shadow, 0, 1, 0.55)
        s.scale = scale == 2 ? 2 : 1
        switch backdrop {
        case .gradient(let i) where !Presets.gradients.indices.contains(i): s.backdrop = .gradient(0)
        case .solid(let i) where !Presets.solids.indices.contains(i): s.backdrop = .gradient(0)
        default: break
        }
        return s
    }
}

// MARK: - Layout and rendering

struct MatLayout: Equatable {
    /// The canvas in source pixels, before any output scaling.
    var canvas: CGSize
    /// Where the screenshot sits on the canvas, in source pixels (y up).
    var imageRect: CGRect
    /// The PNG's pixel size at 1x.
    var output: CGSize

    static func compute(image: CGSize, style: MatStyle) -> MatLayout {
        let long = max(image.width, image.height)
        let pad = (long * min(max(style.padding, 0), 0.5)).rounded()
        var canvas = CGSize(width: image.width + 2 * pad, height: image.height + 2 * pad)
        if let ratio = style.aspect.ratio {
            if canvas.width / canvas.height < ratio {
                canvas.width = (canvas.height * ratio).rounded()
            } else {
                canvas.height = (canvas.width / ratio).rounded()
            }
        }
        let rect = CGRect(x: ((canvas.width - image.width) / 2).rounded(), y: ((canvas.height - image.height) / 2).rounded(),
                          width: image.width, height: image.height)
        return MatLayout(canvas: canvas, imageRect: rect, output: style.aspect.fixedSize ?? canvas)
    }

    /// The longest side Mat will write, so a very long or very large screenshot cannot ask for gigabytes of memory.
    static let maxSide: CGFloat = 16384

    func pixels(scale: Int) -> CGSize {
        let w = output.width * CGFloat(scale), h = output.height * CGFloat(scale)
        let k = min(1, MatLayout.maxSide / max(w, h, 1))
        return CGSize(width: max((w * k).rounded(), 1), height: max((h * k).rounded(), 1))
    }
}

enum Renderer {
    /// Draws `image` on its mat at `pixels` (the layout's output size times the export scale, or smaller for previews).
    static func render(_ image: CGImage, style: MatStyle, pixels: CGSize? = nil) -> CGImage? {
        let layout = MatLayout.compute(image: CGSize(width: image.width, height: image.height), style: style)
        let size = pixels ?? layout.pixels(scale: style.scale)
        let width = max(Int(size.width), 1), height = max(Int(size.height), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        // Social presets keep the canvas ratio, so one factor maps the canvas onto the output.
        let k = CGFloat(width) / layout.canvas.width
        let unit = max(layout.imageRect.width, layout.imageRect.height) / 1000 * k
        ctx.scaleBy(x: k, y: CGFloat(height) / layout.canvas.height)

        // Background, a diagonal from top left to bottom right.
        let colors = style.colors
        let canvas = CGRect(origin: .zero, size: layout.canvas)
        func paintBackground() {
            if colors.top == colors.bottom {
                ctx.setFillColor(colors.top.cgColor)
                ctx.fill(canvas)
            } else if let g = CGGradient(colorsSpace: space, colors: [colors.top.cgColor, colors.bottom.cgColor] as CFArray,
                                         locations: nil) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        }
        paintBackground()

        let rect = layout.imageRect
        let radius = min(CGFloat(style.radius) * unit / k, min(rect.width, rect.height) / 2)
        let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Shadow: offset and blur live in device pixels, so they scale by hand.
        if style.shadow > 0.001 {
            let s = CGFloat(style.shadow)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -(4 + 22 * s) * unit), blur: (10 + 70 * s) * unit,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.16 + 0.42 * s))
            ctx.addPath(shape)
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // Repaint the mat under the image, so transparent screenshots do not show the shadow fill.
        paintBackground()
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        // A window style edge: dark hairline outside, light hairline inside.
        if style.border {
            let line = max(1, 1.2 * unit) / k
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: -line / 2, dy: -line / 2), cornerWidth: radius + line / 2,
                               cornerHeight: radius + line / 2, transform: nil))
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22))
            ctx.setLineWidth(line)
            ctx.strokePath()
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: line / 2, dy: line / 2), cornerWidth: max(radius - line / 2, 0),
                               cornerHeight: max(radius - line / 2, 0), transform: nil))
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.32))
            ctx.setLineWidth(line)
            ctx.strokePath()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? Int ?? 1
        // Photos from a phone carry their rotation as metadata; apply it so the mat is not drawn sideways.
        if orientation != 1, let w = props?[kCGImagePropertyPixelWidth] as? Int, let h = props?[kCGImagePropertyPixelHeight] as? Int {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                            kCGImageSourceCreateThumbnailWithTransform: true,
                                            kCGImageSourceThumbnailMaxPixelSize: max(w, h)]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// The finished PNG and a TIFF twin for older apps that only paste TIFF.
    static func encoded(_ source: CGImage, style: MatStyle, tiff: Bool) -> (png: Data, tiff: Data?, size: CGSize)? {
        guard let image = render(source, style: style), let png = png(image) else { return nil }
        var tiffData: Data?
        if tiff {
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, nil)
                if CGImageDestinationFinalize(dest) { tiffData = data as Data }
            }
        }
        return (png, tiffData, CGSize(width: image.width, height: image.height))
    }

    /// "Screenshot 2026-11-07.png" becomes "Screenshot 2026-11-07 Mat.png".
    static func exportName(for source: String) -> String {
        let base = (source as NSString).deletingPathExtension
        return (base.isEmpty ? "Screenshot" : base) + " Mat.png"
    }
}

// MARK: - Model

@MainActor
final class MatModel: ObservableObject {
    @Published private(set) var source: CGImage?
    @Published private(set) var sourceName = ""
    @Published private(set) var preview: NSImage?
    @Published var toast: Toast?
    /// True while an export or copy renders in the background.
    @Published private(set) var busy = false
    @Published var style: MatStyle {
        didSet {
            guard style != oldValue else { return }
            if persist { Storage.save(style, app: "Mat", file: "style.json") }
            if !style.isColourEdit(of: oldValue) { lastColourEdit = nil }
            refresh()
        }
    }

    struct Toast: Equatable {
        let text: String
        let file: URL?
        var isError = false
        let id = UUID()
    }

    weak var undoManager: UndoManager?
    private let persist: Bool
    private var sliderStart: MatStyle?
    private var lastColourEdit: Date?
    private var rendering = false
    private var renderAgain = false

    init(persist: Bool = !Desktop.isSnapshot) {
        self.persist = persist
        style = persist ? (Storage.load(MatStyle.self, app: "Mat", file: "style.json")?.sanitized() ?? MatStyle()) : MatStyle()
    }

    static var demo: MatModel {
        let model = MatModel(persist: false)
        model.style = MatStyle(backdrop: .gradient(0), padding: 0.09, radius: 12, shadow: 0.6, border: true, aspect: .auto, scale: 2)
        model.set(DemoShot.make(), name: "Screenshot 2026-11-07 at 09.41.12.png")
        return model
    }

    var hasImage: Bool { source != nil }

    var layout: MatLayout? {
        source.map { MatLayout.compute(image: CGSize(width: $0.width, height: $0.height), style: style) }
    }

    // MARK: Input

    func set(_ image: CGImage, name: String) {
        source = image
        sourceName = name
        preview = nil
        refresh()
    }

    @discardableResult
    func load(url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = Renderer.decode(data) else {
            show("\(url.lastPathComponent) is not an image Mat can read.", error: true)
            return false
        }
        set(image, name: url.lastPathComponent)
        return true
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot"
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func paste(from pb: NSPasteboard = .general) {
        // A file copied in Finder also puts its icon on the clipboard as TIFF; never paste the icon instead of the file.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first {
            load(url: url)
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let image = Renderer.decode(data) {
                set(image, name: "Pasted Image.png")
                return
            }
        }
        show("The clipboard has no image. Take a screenshot with ⌃⇧⌘4, then paste.", error: true)
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in self.load(url: url) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    if let image = Renderer.decode(data) {
                        self.set(image, name: "Dropped Image.png")
                    } else {
                        self.show("That is not an image Mat can read.", error: true)
                    }
                }
            }
            return true
        }
        return false
    }

    // MARK: Output

    func copy() {
        guard let source, !busy else { return }
        let style = style
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = Renderer.encoded(source, style: style, tiff: true)
            await MainActor.run {
                self.busy = false
                guard let result else { return self.show("Mat could not render the image.", error: true) }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.declareTypes(result.tiff == nil ? [.png] : [.png, .tiff], owner: nil)
                pb.setData(result.png, forType: .png)
                if let tiff = result.tiff { pb.setData(tiff, forType: .tiff) }
                self.show("Copied \(Int(result.size.width)) × \(Int(result.size.height)) PNG")
            }
        }
    }

    func export() {
        guard let source, !busy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = Renderer.exportName(for: sourceName)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let style = style
        busy = true
        Task.detached(priority: .userInitiated) {
            var message: (String, URL?, Bool)
            if let result = Renderer.encoded(source, style: style, tiff: false) {
                do {
                    try result.png.write(to: url, options: .atomic)
                    message = ("Saved \(url.lastPathComponent)", url, false)
                } catch {
                    message = ("Could not save: \(error.localizedDescription)", nil, true)
                }
            } else {
                message = ("Mat could not render the image.", nil, true)
            }
            let final = message
            await MainActor.run {
                self.busy = false
                self.show(final.0, file: final.1, error: final.2)
            }
        }
    }

    func show(_ text: String, file: URL? = nil, error: Bool = false) {
        let toast = Toast(text: text, file: file, isError: error)
        withAnimation(.snappy) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard self?.toast == toast else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }

    // MARK: Editing with undo

    func update(_ name: String = "Change Style", _ change: (inout MatStyle) -> Void) {
        let old = style
        change(&style)
        if style != old { registerUndo(old, name: name) }
    }

    /// A colour well sends a change for every step of a drag; one undo step covers a burst of them.
    func updateColour(_ change: (inout MatStyle) -> Void) {
        let old = style
        let now = Date()
        let coalesce = lastColourEdit.map { now.timeIntervalSince($0) < 1.0 } ?? false
        change(&style)
        guard style != old else { return }
        if !coalesce { registerUndo(old, name: "Change Colour") }
        lastColourEdit = now
    }

    func sliderEditing(_ editing: Bool, name: String) {
        if editing {
            sliderStart = style
        } else if let start = sliderStart {
            sliderStart = nil
            if start != style { registerUndo(start, name: name) }
        }
    }

    private func registerUndo(_ previous: MatStyle, name: String) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let current = target.style
                target.style = previous
                target.registerUndo(current, name: name)
            }
        }
        undoManager?.setActionName(name)
    }

    /// A preview at most 1600 px on its long side, drawn by the same renderer as the export.
    /// The first preview of an image draws at once; later ones draw off the main thread, newest style wins.
    private func refresh() {
        guard let source, let layout else {
            preview = nil
            return
        }
        let factor = min(1, 1600 / max(layout.output.width, layout.output.height))
        let pixels = CGSize(width: (layout.output.width * factor).rounded(), height: (layout.output.height * factor).rounded())
        if preview == nil || Desktop.isSnapshot {
            preview = Renderer.render(source, style: style, pixels: pixels).map { NSImage(cgImage: $0, size: .zero) }
            return
        }
        if rendering {
            renderAgain = true
            return
        }
        rendering = true
        let style = style
        Task.detached(priority: .userInitiated) {
            let image = Renderer.render(source, style: style, pixels: pixels)
            await MainActor.run {
                self.rendering = false
                if source === self.source, style == self.style, let image { self.preview = NSImage(cgImage: image, size: .zero) }
                if self.renderAgain || source !== self.source || style != self.style {
                    self.renderAgain = false
                    self.refresh()
                }
            }
        }
    }
}

extension MatStyle {
    /// True when `self` differs from `other` only in the custom colours (and the switch to Custom they imply).
    func isColourEdit(of other: MatStyle) -> Bool {
        var a = self, b = other
        a.customTop = b.customTop
        a.customBottom = b.customBottom
        a.backdrop = .custom
        b.backdrop = .custom
        return a == b
    }
}

// MARK: - Demo screenshot

/// A made up app window, drawn in code, for the website snapshot and the self test.
enum DemoShot {
    static func make(width: Int = 1440, height: Int = 900) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        func fill(_ hex: UInt32, _ rect: CGRect, radius: CGFloat = 0) {
            ctx.setFillColor(rgb(hex).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        // Window body, sidebar and title bar.
        fill(0xFFFFFF, CGRect(x: 0, y: 0, width: w, height: h))
        fill(0xF3F3F6, CGRect(x: 0, y: 0, width: 300, height: h))
        fill(0xE2E2E7, CGRect(x: 300, y: 0, width: 2, height: h))
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(UInt32(hex)).cgColor)
            ctx.fillEllipse(in: CGRect(x: 26 + CGFloat(i) * 30, y: h - 46, width: 22, height: 22))
        }
        // Sidebar rows, the second one selected.
        for i in 0..<9 {
            let y = h - 120 - CGFloat(i) * 58
            if i == 1 { fill(0x3478F6, CGRect(x: 16, y: y - 14, width: 268, height: 46), radius: 10) }
            fill(i == 1 ? 0xFFFFFF : 0x9AA0AE, CGRect(x: 34, y: y, width: 20, height: 20), radius: 6)
            fill(i == 1 ? 0xFFFFFF : 0x5D6270, CGRect(x: 68, y: y + 4, width: CGFloat([120, 96, 140, 84, 110, 132, 90, 118, 100][i]), height: 12),
                 radius: 6)
        }
        // Header.
        fill(0x1D1D22, CGRect(x: 360, y: h - 110, width: 330, height: 30), radius: 8)
        fill(0xB6BAC4, CGRect(x: 360, y: h - 150, width: 220, height: 14), radius: 7)
        // Three stat cards.
        let accents: [UInt32] = [0x3478F6, 0x30B26A, 0xF59E0B]
        for i in 0..<3 {
            let x = 360 + CGFloat(i) * 345
            fill(0xF6F7FA, CGRect(x: x, y: h - 330, width: 320, height: 140), radius: 18)
            fill(0x8D93A0, CGRect(x: x + 26, y: h - 236, width: 110, height: 12), radius: 6)
            fill(accents[i], CGRect(x: x + 26, y: h - 300, width: 150, height: 36), radius: 9)
        }
        // A bar chart.
        fill(0xF6F7FA, CGRect(x: 360, y: 60, width: 1020, height: 470), radius: 20)
        let bars: [CGFloat] = [0.42, 0.58, 0.5, 0.72, 0.64, 0.86, 0.7, 0.92, 0.8, 0.66, 0.88, 0.97]
        for (i, v) in bars.enumerated() {
            let x = 410 + CGFloat(i) * 80
            fill(i == 11 ? 0x3478F6 : 0xBFD4FB, CGRect(x: x, y: 100, width: 48, height: 360 * v), radius: 10)
        }
        return ctx.makeImage()!
    }
}
