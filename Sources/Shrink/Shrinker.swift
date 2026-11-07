import AppKit
import ImageIO
import UniformTypeIdentifiers

// The image pipeline: settings, planning output names, and the ImageIO resize and encode. Nothing here touches the UI,
// so it runs on any thread and the self test drives it directly.

enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    case keep, jpeg, heic, png
    var id: Self { self }
    var title: String {
        switch self {
        case .keep: "Keep"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .png: "PNG"
        }
    }
}

enum ResizeMode: String, Codable, CaseIterable, Identifiable {
    case none, fit, percent
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "Original size"
        case .fit: "Fit within"
        case .percent: "Percentage"
        }
    }
}

enum OutputLocation: String, Codable, CaseIterable, Identifiable {
    case nextToOriginal, folder
    var id: Self { self }
    var title: String { self == .nextToOriginal ? "Next to originals" : "In a folder" }
}

struct ShrinkSettings: Codable, Equatable {
    var format: OutputFormat = .keep
    var quality: Double = 0.75
    var resize: ResizeMode = .fit
    var maxWidth = 2048
    var maxHeight = 2048
    var percent: Double = 50
    var stripMetadata = true
    var location: OutputLocation = .nextToOriginal
    var suffix = "-small"
    var folderPath: String?

    init() {}

    /// Tolerates missing or unknown keys, so a settings file from another version never resets everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ShrinkSettings()
        format = (try? c.decode(OutputFormat.self, forKey: .format)) ?? d.format
        quality = (try? c.decode(Double.self, forKey: .quality)) ?? d.quality
        resize = (try? c.decode(ResizeMode.self, forKey: .resize)) ?? d.resize
        maxWidth = (try? c.decode(Int.self, forKey: .maxWidth)) ?? d.maxWidth
        maxHeight = (try? c.decode(Int.self, forKey: .maxHeight)) ?? d.maxHeight
        percent = (try? c.decode(Double.self, forKey: .percent)) ?? d.percent
        stripMetadata = (try? c.decode(Bool.self, forKey: .stripMetadata)) ?? d.stripMetadata
        location = (try? c.decode(OutputLocation.self, forKey: .location)) ?? d.location
        suffix = (try? c.decode(String.self, forKey: .suffix)) ?? d.suffix
        folderPath = try? c.decode(String.self, forKey: .folderPath)
    }

    var folderURL: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// A short description for the summary bar, such as "JPEG at 75%, fit within 2048 × 2048".
    var summary: String {
        var parts: [String] = []
        switch format {
        case .keep: parts.append("Same format at \(Int((quality * 100).rounded()))%")
        case .png: parts.append("PNG")
        default: parts.append("\(format.title) at \(Int((quality * 100).rounded()))%")
        }
        switch resize {
        case .none: parts.append("original size")
        case .fit: parts.append("fit within \(Shrinker.dimensions(maxWidth, maxHeight))")
        case .percent: parts.append("\(Int(percent.rounded()))% of original size")
        }
        if stripMetadata { parts.append("no metadata") }
        return parts.joined(separator: ", ")
    }
}

struct ImageInfo: Equatable {
    var width: Int // Displayed width, after the EXIF orientation is applied.
    var height: Int
    var type: String // Uniform type identifier, such as public.jpeg.
    var hasAlpha: Bool
    var bytes: Int64
}

struct ShrinkOutput: Equatable {
    var url: URL
    var type: String
    var bytes: Int64
    var width: Int
    var height: Int
}

enum ShrinkError: LocalizedError, Equatable {
    case unreadable
    case wouldOverwriteOriginal
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This file could not be read as an image."
        case .wouldOverwriteOriginal: "Skipped so the original is not overwritten."
        case .encodeFailed(let type): "Could not write a \(type) file here."
        }
    }
}

enum Shrinker {
    static let readableExtensions: Set<String> = ["jpg", "jpeg", "jpe", "png", "heic", "heif", "tif", "tiff", "webp"]

    static func isSupported(_ url: URL) -> Bool { readableExtensions.contains(url.pathExtension.lowercased()) }

    /// The image files among `urls`, with folders searched recursively (hidden files and packages skipped), deduplicated.
    static func expand(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ url: URL) {
            let url = url.standardizedFileURL
            guard isSupported(url), seen.insert(url.path.lowercased()).inserted else { return }
            out.append(url)
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { add(url); continue }
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var found: [URL] = []
            for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                found.append(file)
            }
            found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
        }
        return out
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func orientedSize(_ props: [CFString: Any]) -> (Int, Int) {
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 && orientation <= 8 ? (h, w) : (w, h)
    }

    static func info(of url: URL) -> ImageInfo? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0, let type = CGImageSourceGetType(src) as String?,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let (w, h) = orientedSize(props)
        guard w > 0, h > 0 else { return nil }
        return ImageInfo(width: w, height: h, type: type, hasAlpha: props[kCGImagePropertyHasAlpha] as? Bool ?? false,
                         bytes: fileSize(url))
    }

    static func thumbnail(of url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// The output size for an image of `width` × `height`. Never enlarges; keeps the aspect ratio.
    static func targetSize(width: Int, height: Int, settings: ShrinkSettings) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (width, height) }
        var scale = 1.0
        switch settings.resize {
        case .none: break
        case .fit:
            if settings.maxWidth > 0 { scale = min(scale, Double(settings.maxWidth) / Double(width)) }
            if settings.maxHeight > 0 { scale = min(scale, Double(settings.maxHeight) / Double(height)) }
        case .percent:
            scale = min(1, max(0.01, settings.percent / 100))
        }
        if scale >= 1 { return (width, height) }
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// What an image is saved as. "Keep" keeps JPEG, PNG, HEIC and TIFF; anything ImageIO cannot write (WebP)
    /// becomes PNG when it has transparency and JPEG otherwise. HEIC falls back to JPEG on Macs that cannot encode it.
    static func outputType(sourceType: String, hasAlpha: Bool, format: OutputFormat, writable: Set<String> = writableTypes) -> UTType {
        let fallback: UTType = hasAlpha ? .png : .jpeg
        switch format {
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return writable.contains(UTType.heic.identifier) ? .heic : .jpeg
        case .keep:
            let kept: [UTType] = [.jpeg, .png, .heic, .tiff]
            if let type = UTType(sourceType), kept.contains(type), writable.contains(type.identifier) { return type }
            if UTType(sourceType) == .heif, writable.contains(UTType.heic.identifier) { return .heic }
            return fallback
        }
    }

    /// The source's own extension when the type is unchanged (so .JPEG stays .JPEG), otherwise the usual one.
    static func fileExtension(for type: UTType, source: URL) -> String {
        if let sourceType = UTType(filenameExtension: source.pathExtension), sourceType == type { return source.pathExtension }
        if type == .jpeg { return "jpg" }
        return type.preferredFilenameExtension ?? "img"
    }

    static func sanitizedSuffix(_ suffix: String) -> String {
        String(suffix.filter { $0 != "/" && $0 != ":" && !$0.isNewline })
    }

    /// Where a source image is written. Never the source itself, never a path in `taken` (claimed by another image in
    /// the same batch), and never an existing file, unless it is `previous`, this image's own earlier output.
    static func outputURL(for source: URL, type: UTType, settings: ShrinkSettings, taken: Set<String>, previous: URL?,
                          exists: (URL) -> Bool) -> URL {
        let useFolder = settings.location == .folder && settings.folderURL != nil
        let dir = useFolder ? settings.folderURL! : source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let stem = useFolder ? base : base + sanitizedSuffix(settings.suffix)
        let ext = fileExtension(for: type, source: source)
        let sourceKey = source.standardizedFileURL.path.lowercased()
        let previousKey = previous?.standardizedFileURL.path.lowercased()
        var n = 1
        while true {
            let url = dir.appendingPathComponent(n == 1 ? "\(stem).\(ext)" : "\(stem) \(n).\(ext)").standardizedFileURL
            let key = url.path.lowercased()
            if key != sourceKey, !taken.contains(key), key == previousKey || !exists(url) { return url }
            n += 1
        }
    }

    /// Destinations for a whole batch, in order. Every source in the batch is off limits, so an image that an earlier
    /// run produced and that was later added to the list is never overwritten while it is being read, and no two
    /// images claim the same name.
    /// `reserved` adds the other files in the list that are not in the batch.
    static func plan(_ entries: [(source: URL, type: UTType, previous: URL?)], reserved: [URL] = [], settings: ShrinkSettings,
                     exists: (URL) -> Bool) -> [URL] {
        var taken = Set((entries.map(\.source) + reserved).map { $0.standardizedFileURL.path.lowercased() })
        return entries.map { entry in
            let url = outputURL(for: entry.source, type: entry.type, settings: settings, taken: taken, previous: entry.previous,
                                exists: exists)
            taken.insert(url.path.lowercased())
            return url
        }
    }

    /// Resizes and re-encodes `source` into `destination` with ImageIO. Orientation is baked into the pixels, the colour
    /// profile is kept, and metadata is copied unless the settings strip it. Writes through a temporary file, so a failed
    /// run never leaves a half-written image, and refuses outright to write over the source.
    static func shrink(_ source: URL, to destination: URL, type: UTType, settings: ShrinkSettings) throws -> ShrinkOutput {
        guard source.standardizedFileURL.path.lowercased() != destination.standardizedFileURL.path.lowercased() else {
            throw ShrinkError.wouldOverwriteOriginal
        }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { throw ShrinkError.unreadable }
        let (w, h) = orientedSize(props)
        let target = targetSize(width: w, height: h, settings: settings)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height)]
        guard var image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { throw ShrinkError.unreadable }
        if type == .jpeg, hasAlpha(image), let flat = flattened(image) { image = flat }

        let fm = FileManager.default
        let dir = destination.deletingLastPathComponent()
        let name = type.preferredFilenameExtension?.uppercased() ?? "image"
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw ShrinkError.encodeFailed(name) }
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).shrinking")
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, 1, nil) else {
            throw ShrinkError.encodeFailed(name)
        }
        CGImageDestinationAddImage(dest, image, destinationProperties(props, settings: settings, type: type,
                                                                      width: image.width, height: image.height) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? fm.removeItem(at: temp)
            throw ShrinkError.encodeFailed(name)
        }
        do {
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw ShrinkError.encodeFailed(name)
        }
        return ShrinkOutput(url: destination, type: type.identifier, bytes: fileSize(destination), width: image.width, height: image.height)
    }

    static func destinationProperties(_ props: [CFString: Any], settings: ShrinkSettings, type: UTType,
                                      width: Int, height: Int) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        if !settings.stripMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyGPSDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let value = props[key] { out[key] = value }
            }
            if var exif = out[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = width
                exif[kCGImagePropertyExifPixelYDimension] = height
                out[kCGImagePropertyExifDictionary] = exif
            }
        }
        // The pixels are already upright, so the tag must say so in both places it can live.
        out[kCGImagePropertyOrientation] = 1
        var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if !tiff.isEmpty || type == .tiff {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            if type == .tiff { tiff[kCGImagePropertyTIFFCompression] = 5 } // LZW, lossless.
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        if type != .png && type != .tiff { out[kCGImageDestinationLossyCompressionQuality] = min(1, max(0, settings.quality)) }
        return out
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// The image on white, for formats without transparency.
    static func flattened(_ image: CGImage) -> CGImage? {
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    // MARK: Formatting

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func dimensions(_ w: Int, _ h: Int) -> String { "\(w) \u{00D7} \(h)" }

    /// Percent saved, rounded: positive when smaller, negative when the output grew.
    static func percentSaved(original: Int64, new: Int64) -> Int {
        guard original > 0 else { return 0 }
        return Int((Double(original - new) / Double(original) * 100).rounded())
    }

    static func typeName(_ identifier: String) -> String {
        switch UTType(identifier) {
        case .some(.jpeg): "JPEG"
        case .some(.png): "PNG"
        case .some(.heic), .some(.heif): "HEIC"
        case .some(.tiff): "TIFF"
        case .some(.webP): "WebP"
        default: UTType(identifier)?.preferredFilenameExtension?.uppercased() ?? "Image"
        }
    }
}
