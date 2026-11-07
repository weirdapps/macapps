import AppKit
import CoreGraphics
import ImageIO
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Options

enum IconShape: String, Codable, CaseIterable, Identifiable {
    case tile, fullBleed
    var id: String { rawValue }
    var title: String { self == .tile ? "macOS Tile" : "Full Bleed" }
}

enum Framing: String, Codable, CaseIterable, Identifiable {
    case crop, fit
    var id: String { rawValue }
    var title: String { self == .crop ? "Crop to Square" : "Fit Whole Image" }
}

/// An sRGB colour that survives JSON.
struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

struct IconOptions: Codable, Equatable {
    var shape: IconShape = .tile
    var shadow = true
    var fillBackground = false
    var background = RGBA.white
    /// Inset of the artwork inside the tile, as a fraction of the tile side (0 to 0.3).
    var padding: Double = 0
    var framing: Framing = .crop
    /// 1 shows the largest square the framing allows; 2 shows half of it.
    var zoom: Double = 1
    /// Centre of the crop in normalised image coordinates, origin top left.
    var center = CGPoint(x: 0.5, y: 0.5)

    static let zoomRange: ClosedRange<Double> = 1...6
    static let paddingRange: ClosedRange<Double> = 0...0.3

    /// The same look with the crop reset, for a newly opened image.
    var resetCrop: IconOptions {
        var o = self
        o.zoom = 1
        o.center = CGPoint(x: 0.5, y: 0.5)
        return o
    }
}

// MARK: - Geometry

/// The macOS icon grid: a 1024 px canvas with an 824 px rounded tile at 100,100 (y up).
enum Geometry {
    static let canvas: CGFloat = 1024
    static let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let tileRadius: CGFloat = 185.4
    static let sizes = [16, 32, 64, 128, 256, 512, 1024]

    /// The square of the source that becomes the artwork, in image pixels with the origin top left.
    /// When the square is larger than the image on an axis (Fit, or a narrow image), it is centred on that axis.
    static func cropRect(imageSize: CGSize, options: IconOptions) -> CGRect {
        let base = options.framing == .fit ? max(imageSize.width, imageSize.height) : min(imageSize.width, imageSize.height)
        let side = base / CGFloat(min(max(options.zoom, IconOptions.zoomRange.lowerBound), IconOptions.zoomRange.upperBound))
        func axis(_ length: CGFloat, _ c: CGFloat) -> CGFloat {
            if side >= length { return length / 2 }
            return min(max(c * length, side / 2), length - side / 2)
        }
        let cx = axis(imageSize.width, options.center.x), cy = axis(imageSize.height, options.center.y)
        return CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
    }

    /// `options.center` moved so the crop stays inside the image.
    static func clampedCenter(imageSize: CGSize, options: IconOptions) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let r = cropRect(imageSize: imageSize, options: options)
        return CGPoint(x: r.midX / imageSize.width, y: r.midY / imageSize.height)
    }

    /// The shape's rectangle in the 1024 canvas.
    static func shapeRect(_ options: IconOptions) -> CGRect {
        options.shape == .tile ? tileRect : CGRect(x: 0, y: 0, width: canvas, height: canvas)
    }

    /// Where the artwork goes in the 1024 canvas: the shape inset by the padding.
    static func contentRect(_ options: IconOptions) -> CGRect {
        let shape = shapeRect(options)
        let p = min(max(options.padding, IconOptions.paddingRange.lowerBound), IconOptions.paddingRange.upperBound)
        return shape.insetBy(dx: shape.width * p, dy: shape.height * p)
    }

    /// The tile uses continuous corners, the squircle Apple draws its own icons with, not circular arcs.
    static func shapePath(_ options: IconOptions) -> CGPath {
        options.shape == .tile
            ? Path(roundedRect: tileRect, cornerRadius: tileRadius, style: .continuous).cgPath
            : CGPath(rect: shapeRect(options), transform: nil)
    }
}

// MARK: - Rendering

/// A CGImage handed to a background task. CGImage is immutable, so sharing it across threads is safe.
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

enum IconRenderer {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(_ size: Int) -> CGContext? {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws the icon at `size` pixels: optional drop shadow, the shape clip, background fill and the framed artwork.
    static func render(_ image: CGImage, options: IconOptions, size: Int) -> CGImage? {
        guard size > 0, let ctx = context(size) else { return nil }
        let k = CGFloat(size) / Geometry.canvas
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: k, y: k)

        // Shadow parameters ignore the CTM, so they scale by hand.
        if options.shape == .tile && options.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: CGColor(gray: 0, alpha: 0.3))
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.saveGState()
        ctx.addPath(Geometry.shapePath(options))
        ctx.clip()
        if options.fillBackground {
            ctx.setFillColor(options.background.cgColor)
            ctx.fill(Geometry.shapeRect(options))
        }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let crop = Geometry.cropRect(imageSize: CGSize(width: w, height: h), options: options)
        let content = Geometry.contentRect(options)
        let scale = content.width / crop.width
        ctx.clip(to: content)
        ctx.draw(image, in: CGRect(x: content.minX - crop.minX * scale, y: content.minY - (h - crop.maxY) * scale,
                                   width: w * scale, height: h * scale))
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        return ctx.makeImage()
    }

    /// Resamples a square image to `size` pixels.
    static func scaled(_ image: CGImage, to size: Int) -> CGImage? {
        guard let ctx = context(size) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    /// Every size in `Geometry.sizes`: the 1024 master, then halved step by step, which keeps small sizes crisp.
    static func renderAll(_ image: CGImage, options: IconOptions) -> [Int: CGImage] {
        guard var current = render(image, options: options, size: 1024) else { return [:] }
        var out = [1024: current]
        var size = 1024
        while size > 16 {
            size /= 2
            guard let next = scaled(current, to: size) else { break }
            out[size] = next
            current = next
        }
        return out
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - Export

enum ExportKind: CaseIterable {
    case icns, iconset, appIconSet

    var ext: String {
        switch self {
        case .icns: "icns"
        case .iconset: "iconset"
        case .appIconSet: "appiconset"
        }
    }

    var menuTitle: String {
        switch self {
        case .icns: "Export .icns…"
        case .iconset: "Export Iconset…"
        case .appIconSet: "Export Xcode App Icon…"
        }
    }

    var message: String {
        switch self {
        case .icns: "Save an .icns file with every size from 16 to 1024 pixels."
        case .iconset: "Save an .iconset folder of PNGs, ready for iconutil."
        case .appIconSet: "Save an AppIcon.appiconset folder with Contents.json. Drop it into an Xcode asset catalog."
        }
    }

    /// Xcode looks for an asset named AppIcon, so the app icon set keeps that name.
    func defaultName(base: String) -> String {
        self == .appIconSet ? "AppIcon.appiconset" : "\(base).\(ext)"
    }

    var contentType: UTType? {
        switch self {
        case .icns: .icns
        case .iconset: UTType(filenameExtension: "iconset")
        case .appIconSet: UTType(filenameExtension: "appiconset")
        }
    }
}

enum ExportError: LocalizedError {
    case render, write(String), iconutil(String)

    var errorDescription: String? {
        switch self {
        case .render: "The icon could not be drawn."
        case .write(let name): "Could not write \(name)."
        case .iconutil(let message): "iconutil failed: \(message)"
        }
    }
}

enum IconExporter {
    /// One file of an iconset: a point size at a scale.
    struct Slot: Equatable {
        let points: Int
        let scale: Int
        var pixels: Int { points * scale }
        var filename: String { scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@\(scale)x.png" }
    }

    static let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

    static func contentsJSON() -> Data {
        let images = slots.map { ["filename": $0.filename, "idiom": "mac", "scale": "\($0.scale)x", "size": "\($0.points)x\($0.points)"] }
        let root: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
        return (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    static func writePNGs(_ images: [Int: CGImage], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for slot in slots {
            guard let image = images[slot.pixels], let data = IconRenderer.pngData(image) else { throw ExportError.render }
            do { try data.write(to: dir.appendingPathComponent(slot.filename)) } catch { throw ExportError.write(slot.filename) }
        }
    }

    static func writeAppIconSet(_ images: [Int: CGImage], to dir: URL) throws {
        try writePNGs(images, to: dir)
        do { try contentsJSON().write(to: dir.appendingPathComponent("Contents.json")) } catch { throw ExportError.write("Contents.json") }
    }

    /// Builds an iconset in a temporary folder and converts it with /usr/bin/iconutil; ImageIO is the fallback.
    static func writeICNS(_ images: [Int: CGImage], to url: URL) throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Iconsmith-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let iconset = temp.appendingPathComponent("Icon.iconset", isDirectory: true)
        try writePNGs(images, to: iconset)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", url.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return }
        } catch {}
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try writeICNSWithImageIO(images, to: url, iconutilMessage: message)
    }

    static func writeICNSWithImageIO(_ images: [Int: CGImage], to url: URL, iconutilMessage: String = "") throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, slots.count, nil) else {
            throw ExportError.iconutil(iconutilMessage.isEmpty ? "no icns writer available" : iconutilMessage)
        }
        // ImageIO keeps one picture per point size unless the @2x ones say 144 dpi; without it the 1024 slot is dropped.
        for slot in slots {
            guard let image = images[slot.pixels] else { throw ExportError.render }
            let dpi = 72 * slot.scale
            CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError.iconutil(iconutilMessage) }
    }

    /// Renders every size from the full-resolution source and writes `kind` to `url`, replacing what the save panel agreed to replace.
    static func export(_ kind: ExportKind, image: CGImage, options: IconOptions, to url: URL) throws {
        let images = IconRenderer.renderAll(image, options: options)
        guard images.count == Geometry.sizes.count else { throw ExportError.render }
        let fm = FileManager.default
        // Stage on the destination volume so the final swap is a rename, and an old export survives a failed write.
        let staging = (try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                   appropriateFor: url.deletingLastPathComponent(), create: true))
            ?? fm.temporaryDirectory.appendingPathComponent("Iconsmith-out-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(url.lastPathComponent)
        switch kind {
        case .icns: try writeICNS(images, to: staged)
        case .iconset: try writePNGs(images, to: staged)
        case .appIconSet: try writeAppIconSet(images, to: staged)
        }
        do {
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: staged) } else { try fm.moveItem(at: staged, to: url) }
        } catch {
            throw ExportError.write(url.lastPathComponent)
        }
    }
}

// MARK: - Loading

enum ImageLoader {
    /// Longest side kept from a source; enough for a 6x zoom into a 1024 icon from most images.
    static let maxPixels = 6144
    static let previewPixels = 2048

    /// Decodes an image file the right way up (EXIF orientation applied). PDF and SVG go through NSImage.
    static func load(_ url: URL) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
           let image = thumbnail(src, index: largestIndex(src), maxPixels: maxPixels) {
            return image
        }
        guard let ns = NSImage(contentsOf: url) else { return nil }
        return rasterize(ns, longestSide: CGFloat(previewPixels))
    }

    /// The biggest picture in the file. An .icns or .ico stores its 16 px size first, and that is not the one to edit.
    static func largestIndex(_ src: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return 0 }
        var best = 0, bestArea = -1
        for i in 0..<count {
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { continue }
            if w * h > bestArea { best = i; bestArea = w * h }
        }
        return best
    }

    static func thumbnail(_ src: CGImageSource, index: Int = 0, maxPixels: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
    }

    /// A smaller copy for live previews, same aspect ratio.
    static func downsampled(_ image: CGImage, maxPixels: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxPixels else { return image }
        let s = CGFloat(maxPixels) / CGFloat(longest)
        let w = max(1, Int((CGFloat(image.width) * s).rounded())), h = max(1, Int((CGFloat(image.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: IconRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Draws any NSImage (vector or bitmap) so its longest side is `longestSide` pixels, or its own pixel size for bitmaps.
    static func rasterize(_ image: NSImage, longestSide: CGFloat) -> CGImage? {
        var size = image.size
        if let rep = image.representations.first as? NSBitmapImageRep { size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        guard size.width > 0, size.height > 0 else { return nil }
        let s = image.representations.first is NSBitmapImageRep ? min(1, longestSide / max(size.width, size.height))
                                                                 : longestSide / max(size.width, size.height)
        let w = max(1, Int(size.width * s)), h = max(1, Int(size.height * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: IconRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Model

@MainActor
final class IconModel: ObservableObject {
    @Published private(set) var source: CGImage?
    @Published private(set) var preview: CGImage?
    @Published private(set) var name = "Icon"
    @Published private(set) var renders: [Int: CGImage] = [:]
    @Published private(set) var isExporting = false
    @Published private(set) var isLoading = false
    @Published private(set) var lastExport: URL?
    @Published var banner: String?
    @Published var errorMessage: String?
    @Published private(set) var options: IconOptions {
        didSet {
            guard options != oldValue else { return }
            rerender()
            scheduleSave()
        }
    }

    weak var undoManager: UndoManager?
    private let persist: Bool
    private var lastUndo: (label: String, time: Date)?
    private var saveWork: DispatchWorkItem?
    private var bannerWork: DispatchWorkItem?
    private var loadGeneration = 0

    init(persist: Bool = !Desktop.isSnapshot) {
        self.persist = persist
        options = (persist ? Storage.load(IconOptions.self, app: "Iconsmith", file: "options.json") : nil)?.resetCrop ?? IconOptions()
    }

    var hasImage: Bool { preview != nil }
    var sourceSize: CGSize { source.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }
    var cropRect: CGRect { Geometry.cropRect(imageSize: sourceSize, options: options) }

    /// True when the 1024 icon asks for more pixels than the crop holds.
    var isLowResolution: Bool { hasImage && cropRect.width < Geometry.contentRect(options).width * 0.98 }

    // MARK: Opening

    /// Decodes off the main thread, so a 100 megapixel photo never beachballs the window. The newest request wins.
    func open(_ url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let loaded = ImageLoader.load(url).map { SendableImage(image: $0) }
            let preview = loaded.map { SendableImage(image: ImageLoader.downsampled($0.image, maxPixels: ImageLoader.previewPixels)) }
            await self.finishOpen(url: url, image: loaded, preview: preview, generation: generation)
        }
    }

    private func finishOpen(url: URL, image: SendableImage?, preview: SendableImage?, generation: Int) {
        guard generation == loadGeneration else { return }
        isLoading = false
        guard let image, let preview else {
            errorMessage = "\(url.lastPathComponent) is not an image Iconsmith can read."
            return
        }
        setImage(image.image, preview: preview.image, name: url.deletingPathExtension().lastPathComponent)
    }

    func setImage(_ image: CGImage, name: String) {
        setImage(image, preview: ImageLoader.downsampled(image, maxPixels: ImageLoader.previewPixels), name: name)
    }

    private func setImage(_ image: CGImage, preview: CGImage, name: String) {
        source = image
        self.preview = preview
        self.name = name.isEmpty ? "Icon" : name
        undoManager?.removeAllActions()
        lastUndo = nil
        let fresh = options.resetCrop
        if fresh == options { rerender() } else { options = fresh }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to turn into an app icon."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            open(url)
        } else if let ns = (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
                  let image = ImageLoader.rasterize(ns, longestSide: CGFloat(ImageLoader.previewPixels)) {
            loadGeneration += 1
            isLoading = false
            setImage(image, name: "Pasted Image")
        } else {
            NSSound.beep()
        }
    }

    func copyIcon() {
        guard let image = renders[1024], let png = IconRenderer.pngData(image) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
        pb.setData(NSImage(cgImage: image, size: NSSize(width: 512, height: 512)).tiffRepresentation, forType: .tiff)
        flash("Copied the 1024 px icon")
    }

    // MARK: Editing

    /// Applies a change with undo. Repeated changes with the same label in quick succession (a slider drag) undo as one step.
    func update(_ label: String, _ change: (inout IconOptions) -> Void) {
        var next = options
        change(&next)
        next.zoom = min(max(next.zoom, IconOptions.zoomRange.lowerBound), IconOptions.zoomRange.upperBound)
        next.padding = min(max(next.padding, IconOptions.paddingRange.lowerBound), IconOptions.paddingRange.upperBound)
        if hasImage { next.center = Geometry.clampedCenter(imageSize: sourceSize, options: next) }
        guard next != options else { return }
        let now = Date()
        if let last = lastUndo, last.label == label, now.timeIntervalSince(last.time) < 0.8 {
            // Coalesced into the open undo step.
        } else {
            registerUndo(previous: options, label: label)
        }
        lastUndo = (label, now)
        options = next
    }

    private func registerUndo(previous: IconOptions, label: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(previous, label: label) }
        }
        undoManager.setActionName(label)
    }

    private func restore(_ previous: IconOptions, label: String) {
        registerUndo(previous: options, label: label)
        lastUndo = nil
        options = previous
    }

    /// Moves the crop by a drag of `translation` points on an editor canvas `canvasSide` points wide.
    func pan(from start: CGPoint, translation: CGSize, canvasSide: CGFloat) {
        guard hasImage, canvasSide > 0 else { return }
        var o = options
        o.center = start
        let crop = Geometry.cropRect(imageSize: sourceSize, options: o)
        let contentPoints = Geometry.contentRect(o).width / Geometry.canvas * canvasSide
        let perPoint = crop.width / contentPoints
        let center = CGPoint(x: start.x - translation.width * perPoint / sourceSize.width,
                             y: start.y - translation.height * perPoint / sourceSize.height)
        update("Move Image") { $0.center = center }
    }

    func zoom(by factor: Double) { update("Zoom") { $0.zoom *= factor } }

    func resetCrop() { update("Reset Crop") { $0 = $0.resetCrop } }

    private func rerender() {
        guard let preview else { renders = [:]; return }
        renders = IconRenderer.renderAll(preview, options: options)
    }

    private func scheduleSave() {
        guard persist else { return }
        saveWork?.cancel()
        let snapshot = options
        let work = DispatchWorkItem { Storage.save(snapshot, app: "Iconsmith", file: "options.json") }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Export

    func export(_ kind: ExportKind) {
        guard let source, !isExporting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind.defaultName(base: name)
        if let type = kind.contentType { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = kind.message
        panel.prompt = "Export"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != kind.ext { url = url.appendingPathExtension(kind.ext) }

        isExporting = true
        let job = SendableImage(image: source)
        let opts = options
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try IconExporter.export(kind, image: job.image, options: opts, to: url)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await self.finishExport(url: url, error: failure)
        }
    }

    private func finishExport(url: URL, error: String?) {
        isExporting = false
        if let error {
            errorMessage = error
        } else {
            lastExport = url
            flash("Exported \(url.lastPathComponent)")
        }
    }

    func revealLastExport() {
        guard let lastExport else { return }
        revealInFinder([lastExport])
    }

    func flash(_ text: String) {
        bannerWork?.cancel()
        banner = text
        let work = DispatchWorkItem { [weak self] in self?.banner = nil }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }
}

// MARK: - Demo

extension IconModel {
    /// The snapshot's fixed content: a drawn mountain sunset, cropped and zoomed a little.
    static var demo: IconModel {
        let model = IconModel(persist: false)
        if let art = DemoArt.sunset() {
            model.setImage(art, name: "Sunset")
            model.update("Demo") {
                $0.zoom = 1.12
                $0.center = CGPoint(x: 0.56, y: 0.5)
            }
        }
        return model
    }
}

enum DemoArt {
    /// A 1600 x 1100 landscape: dusk sky, a glowing sun, three ridges of mountains and a lake.
    static func sunset() -> CGImage? {
        let w = 1600, h = 1100
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: IconRenderer.colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let cs = IconRenderer.colorSpace
        func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255,
                                                 CGFloat(hex & 0xFF) / 255, a])!
        }
        let horizon: CGFloat = 420
        let sky = CGGradient(colorsSpace: cs, colors: [color(0x1E1B4B), color(0x6D28D9), color(0xF472B6), color(0xFDBA74)] as CFArray,
                             locations: [0, 0.4, 0.75, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: horizon), options: [.drawsAfterEndLocation])

        let sun = CGPoint(x: 880, y: 560)
        let glow = CGGradient(colorsSpace: cs, colors: [color(0xFFF7D6, 0.9), color(0xFDBA74, 0.35), color(0xFDBA74, 0)] as CFArray,
                              locations: [0, 0.35, 1])!
        ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: 520, options: [])
        ctx.setFillColor(color(0xFFF4C7))
        ctx.fillEllipse(in: CGRect(x: sun.x - 150, y: sun.y - 150, width: 300, height: 300))

        func ridge(_ points: [(CGFloat, CGFloat)], top: UInt32, bottom: UInt32) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: horizon - 40))
            for (x, y) in points { path.addLine(to: CGPoint(x: x, y: y)) }
            path.addLine(to: CGPoint(x: CGFloat(w), y: horizon - 40))
            path.closeSubpath()
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            let g = CGGradient(colorsSpace: cs, colors: [color(top), color(bottom)] as CFArray, locations: nil)!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 900), end: CGPoint(x: 0, y: horizon), options: [])
            ctx.restoreGState()
        }
        ridge([(0, 600), (220, 700), (420, 610), (640, 760), (860, 640), (1080, 720), (1320, 600), (1600, 690)], top: 0xA855F7, bottom: 0x7C3AED)
        ridge([(0, 520), (260, 640), (520, 500), (760, 600), (1000, 480), (1240, 620), (1460, 520), (1600, 560)], top: 0x5B21B6, bottom: 0x3B0764)
        ridge([(0, 470), (180, 520), (420, 430), (700, 540), (980, 440), (1200, 500), (1600, 430)], top: 0x2E1065, bottom: 0x1E1B4B)

        // The lake mirrors the sky, darker, with a streak of sunlight.
        let lake = CGGradient(colorsSpace: cs, colors: [color(0xF9A8D4), color(0x6D28D9), color(0x1E1B4B)] as CFArray, locations: [0, 0.45, 1])!
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: Int(horizon)))
        ctx.drawLinearGradient(lake, start: CGPoint(x: 0, y: horizon), end: CGPoint(x: 0, y: 0), options: [])
        ctx.setFillColor(color(0xFFF4C7, 0.75))
        for (i, width) in [220, 170, 120, 80, 50].enumerated() {
            let y = horizon - 40 - CGFloat(i) * 58
            ctx.fill(CGRect(x: sun.x - CGFloat(width) / 2, y: y - 9, width: CGFloat(width), height: 14))
        }
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
