import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Shrink --selftest`: exercises sizing, naming, formats and real ImageIO round trips on temporary files.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passes = 0

    private static func check(_ condition: Bool, _ name: String) {
        if condition { passes += 1 } else { failures += 1; print("FAIL: \(name)") }
    }

    static func run() -> Int32 {
        sizing()
        naming()
        formats()
        settingsRoundTrip()
        planning()
        files()
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func sizing() {
        var s = ShrinkSettings()
        s.resize = .fit; s.maxWidth = 2048; s.maxHeight = 2048
        check(Shrinker.targetSize(width: 4032, height: 3024, settings: s) == (2048, 1536), "fit landscape")
        check(Shrinker.targetSize(width: 3024, height: 4032, settings: s) == (1536, 2048), "fit portrait")
        check(Shrinker.targetSize(width: 800, height: 600, settings: s) == (800, 600), "fit never enlarges")
        s.maxWidth = 1000; s.maxHeight = 0
        check(Shrinker.targetSize(width: 4000, height: 3000, settings: s) == (1000, 750), "fit width only")
        s.maxWidth = 3000; s.maxHeight = 500
        check(Shrinker.targetSize(width: 4000, height: 2000, settings: s) == (1000, 500), "fit tighter side wins")
        s.resize = .percent; s.percent = 25
        check(Shrinker.targetSize(width: 4000, height: 3000, settings: s) == (1000, 750), "percent 25")
        s.percent = 150
        check(Shrinker.targetSize(width: 400, height: 300, settings: s) == (400, 300), "percent above 100 never enlarges")
        s.percent = 1
        check(Shrinker.targetSize(width: 10, height: 10, settings: s) == (1, 1), "percent keeps at least one pixel")
        s.resize = .none
        check(Shrinker.targetSize(width: 4000, height: 3000, settings: s) == (4000, 3000), "original size")
        check(Shrinker.orientedSize([kCGImagePropertyPixelWidth: 400, kCGImagePropertyPixelHeight: 300,
                                     kCGImagePropertyOrientation: 6]) == (300, 400), "orientation 6 swaps sides")
        check(Shrinker.percentSaved(original: 1000, new: 250) == 75, "percent saved")
        check(Shrinker.percentSaved(original: 1000, new: 1100) == -10, "percent grown is negative")
        check(Shrinker.percentSaved(original: 0, new: 10) == 0, "percent of nothing")
    }

    private static func naming() {
        let src = URL(fileURLWithPath: "/tmp/pics/photo.JPG")
        var s = ShrinkSettings()
        let none: (URL) -> Bool = { _ in false }
        let a = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: none)
        check(a.path == "/tmp/pics/photo-small.JPG", "suffix keeps the source extension (\(a.path))")
        let b = Shrinker.outputURL(for: src, type: .heic, settings: s, taken: [], previous: nil, exists: none)
        check(b.lastPathComponent == "photo-small.heic", "new type gets its extension")
        s.suffix = ""
        let c = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: none)
        check(c.path.lowercased() != src.path.lowercased() && c.lastPathComponent == "photo 2.JPG", "empty suffix never hits the original")
        s.suffix = "-small"
        let existing: (URL) -> Bool = { $0.lastPathComponent == "photo-small.JPG" }
        let d = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: existing)
        check(d.lastPathComponent == "photo-small 2.JPG", "existing file is not overwritten")
        let e = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: URL(fileURLWithPath: "/tmp/pics/photo-small.JPG"), exists: existing)
        check(e.lastPathComponent == "photo-small.JPG", "own previous output is replaced")
        s.location = .folder; s.folderPath = "/tmp/out"
        let f = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: none)
        check(f.path == "/tmp/out/photo.JPG", "folder keeps the name")
        let g = Shrinker.outputURL(for: URL(fileURLWithPath: "/tmp/b/photo.jpg"), type: .jpeg, settings: s, taken: [f.path.lowercased()],
                                   previous: nil, exists: none)
        check(g.lastPathComponent == "photo 2.jpg", "two sources with one name in a folder")
        s.folderPath = "/tmp/pics"
        let h = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: none)
        check(h.lastPathComponent == "photo 2.JPG", "folder equal to source folder never hits the original")
        s.folderPath = nil
        let i = Shrinker.outputURL(for: src, type: .jpeg, settings: s, taken: [], previous: nil, exists: none)
        check(i.lastPathComponent == "photo-small.JPG", "folder mode without a folder falls back to the suffix")
        check(Shrinker.sanitizedSuffix("a/b:c") == "abc", "suffix drops path characters")
    }

    private static func formats() {
        let all: Set<String> = ["public.jpeg", "public.png", "public.heic", "public.tiff"]
        check(Shrinker.outputType(sourceType: "public.png", hasAlpha: true, format: .keep, writable: all) == .png, "keep png")
        check(Shrinker.outputType(sourceType: "public.heic", hasAlpha: false, format: .keep, writable: all) == .heic, "keep heic")
        check(Shrinker.outputType(sourceType: "org.webmproject.webp", hasAlpha: false, format: .keep, writable: all) == .jpeg, "webp to jpeg")
        check(Shrinker.outputType(sourceType: "org.webmproject.webp", hasAlpha: true, format: .keep, writable: all) == .png, "transparent webp to png")
        check(Shrinker.outputType(sourceType: "public.png", hasAlpha: false, format: .heic, writable: ["public.jpeg"]) == .jpeg, "heic falls back")
        check(Shrinker.outputType(sourceType: "public.heic", hasAlpha: false, format: .keep, writable: ["public.jpeg"]) == .jpeg, "keep heic falls back")
        check(Shrinker.outputType(sourceType: "public.tiff", hasAlpha: false, format: .png, writable: all) == .png, "png forced")
        check(Shrinker.typeName("public.jpeg") == "JPEG" && Shrinker.typeName("org.webmproject.webp") == "WebP", "type names")
        check(Shrinker.isSupported(URL(fileURLWithPath: "/a/B.HEIC")) && !Shrinker.isSupported(URL(fileURLWithPath: "/a/b.gif")), "supported extensions")
    }

    private static func settingsRoundTrip() {
        var s = ShrinkSettings()
        s.format = .heic; s.quality = 0.6; s.resize = .percent; s.percent = 40; s.location = .folder; s.folderPath = "/tmp/x"
        let data = try? JSONEncoder().encode(s)
        check(data.flatMap { try? JSONDecoder().decode(ShrinkSettings.self, from: $0) } == s, "settings round trip")
        let partial = try? JSONDecoder().decode(ShrinkSettings.self, from: Data(#"{"format":"png","resize":"bogus"}"#.utf8))
        check(partial?.format == .png && partial?.resize == .fit && partial?.suffix == "-small", "settings tolerate missing and unknown keys")
    }

    // MARK: Real files

    private static func files() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shrink-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("nested/.hidden"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 400 × 300 JPEG, tagged as rotated (orientation 6), with a GPS position.
        let jpeg = dir.appendingPathComponent("photo.jpg")
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.86, kCGImagePropertyGPSLatitudeRef: "N"]
        write(makeImage(400, 300, alpha: false), to: jpeg, type: .jpeg,
              props: [kCGImagePropertyOrientation: 6, kCGImagePropertyGPSDictionary: gps])
        let png = dir.appendingPathComponent("nested/clear.png")
        write(makeImage(64, 64, alpha: true), to: png, type: .png, props: [:])
        write(makeImage(8, 8, alpha: false), to: dir.appendingPathComponent("nested/.hidden/secret.png"), type: .png, props: [:])
        try? Data("not an image".utf8).write(to: dir.appendingPathComponent("broken.png"))
        try? Data("text".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let found = Shrinker.expand([dir, jpeg])
        check(found.count == 3, "folder search finds images, skips hidden and other files (\(found.map(\.lastPathComponent)))")
        check(Set(found.map(\.lastPathComponent)) == ["photo.jpg", "clear.png", "broken.png"], "folder search names")

        guard let info = Shrinker.info(of: jpeg) else { check(false, "read info"); return }
        check(info.width == 300 && info.height == 400, "info uses the displayed orientation")
        check(Shrinker.info(of: dir.appendingPathComponent("broken.png")) == nil, "broken file has no info")
        check(Shrinker.thumbnail(of: jpeg, maxPixel: 64).map { max($0.width, $0.height) } == 64, "thumbnail size")
        let originalData = try? Data(contentsOf: jpeg)

        var s = ShrinkSettings()
        s.resize = .fit; s.maxWidth = 150; s.maxHeight = 150; s.stripMetadata = true
        let out1 = Shrinker.outputURL(for: jpeg, type: .jpeg, settings: s, taken: [], previous: nil) { FileManager.default.fileExists(atPath: $0.path) }
        do {
            let r = try Shrinker.shrink(jpeg, to: out1, type: .jpeg, settings: s)
            check((112...113).contains(r.width) && r.height == 150, "resized upright (\(r.width) × \(r.height))")
            let props = properties(out1)
            check(props?[kCGImagePropertyGPSDictionary] == nil, "strip removes GPS")
            check((props?[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "orientation is reset")
            check(r.bytes > 0 && r.bytes == Shrinker.fileSize(out1), "reported size")
        } catch { check(false, "shrink jpeg: \(error)") }

        s.stripMetadata = false
        let out2 = dir.appendingPathComponent("photo-kept.jpg")
        do {
            _ = try Shrinker.shrink(jpeg, to: out2, type: .jpeg, settings: s)
            check(properties(out2)?[kCGImagePropertyGPSDictionary] != nil, "keeping metadata keeps GPS")
        } catch { check(false, "shrink with metadata: \(error)") }

        // Quality changes the size.
        s.resize = .none; s.stripMetadata = true; s.quality = 0.2
        let low = dir.appendingPathComponent("low.jpg"), high = dir.appendingPathComponent("high.jpg")
        let lowSize = (try? Shrinker.shrink(jpeg, to: low, type: .jpeg, settings: s))?.bytes ?? 0
        s.quality = 1
        let highSize = (try? Shrinker.shrink(jpeg, to: high, type: .jpeg, settings: s))?.bytes ?? 0
        check(lowSize > 0 && lowSize < highSize, "lower quality is smaller (\(lowSize) < \(highSize))")

        // Transparency on JPEG becomes white.
        let flat = dir.appendingPathComponent("clear.jpg")
        do {
            _ = try Shrinker.shrink(png, to: flat, type: .jpeg, settings: s)
            check(cornerIsWhite(flat), "transparent pixels become white in JPEG")
        } catch { check(false, "shrink png to jpeg: \(error)") }

        // The original is never touched, and writing onto it is refused.
        check((try? Data(contentsOf: jpeg)) == originalData, "original unchanged")
        do {
            _ = try Shrinker.shrink(jpeg, to: URL(fileURLWithPath: jpeg.path.uppercased()), type: .jpeg, settings: s)
            check(false, "refuses to overwrite the original")
        } catch { check(error as? ShrinkError == .wouldOverwriteOriginal, "refuses to overwrite the original") }

        // Replacing an earlier output in place.
        s.resize = .percent; s.percent = 50
        let again = try? Shrinker.shrink(jpeg, to: out1, type: .jpeg, settings: s)
        check(again?.width == 150 && again?.height == 200, "rerun replaces its own output")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".shrinking") } ?? []
        check(leftovers.isEmpty, "no temporary files left behind")

        if Shrinker.writableTypes.contains(UTType.heic.identifier) {
            let heic = dir.appendingPathComponent("photo.heic")
            let r = try? Shrinker.shrink(jpeg, to: heic, type: .heic, settings: s)
            check(r != nil && CGImageSourceCreateWithURL(heic as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? } == "public.heic",
                  "writes HEIC")
        }
        let tiff = dir.appendingPathComponent("photo.tiff")
        check((try? Shrinker.shrink(jpeg, to: tiff, type: .tiff, settings: s)) != nil && Shrinker.info(of: tiff)?.width == 150, "writes TIFF")
        check((try? Shrinker.shrink(dir.appendingPathComponent("broken.png"), to: dir.appendingPathComponent("b2.png"), type: .png,
                                    settings: s)) == nil, "broken source fails cleanly")

        // An empty file is listed but never readable, and never crashes.
        let empty = dir.appendingPathComponent("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        check(Shrinker.info(of: empty) == nil && Shrinker.thumbnail(of: empty, maxPixel: 64) == nil, "empty file has no info")
        check((try? Shrinker.shrink(empty, to: dir.appendingPathComponent("empty-small.jpg"), type: .jpeg, settings: s)) == nil,
              "empty file fails cleanly")

        // Unicode names survive the trip.
        let greek = dir.appendingPathComponent("Φωτογραφία ü 🌅.png")
        write(makeImage(40, 30, alpha: false), to: greek, type: .png, props: [:])
        let greekOut = Shrinker.outputURL(for: greek, type: .jpeg, settings: ShrinkSettings(), taken: [], previous: nil) { _ in false }
        check(greekOut.lastPathComponent == "Φωτογραφία ü 🌅-small.jpg", "unicode output name")
        check((try? Shrinker.shrink(greek, to: greekOut, type: .jpeg, settings: s)) != nil, "unicode file shrinks")

        // Odd pixel formats: grey with alpha, 16 bits per channel, CMYK. Each must encode to every format.
        let odd: [(String, CGImage?)] = [("grey alpha", makeImage(48, 36, space: CGColorSpace(name: CGColorSpace.linearGray)!, bits: 8,
                                                                    info: CGImageAlphaInfo.premultipliedLast.rawValue)),
                                         ("16 bit", makeImage(48, 36, space: CGColorSpace(name: CGColorSpace.sRGB)!, bits: 16,
                                                              info: CGImageAlphaInfo.premultipliedLast.rawValue)),
                                         ("CMYK", makeImage(48, 36, space: CGColorSpace(name: CGColorSpace.genericCMYK)!, bits: 8,
                                                            info: CGImageAlphaInfo.none.rawValue))]
        for (label, image) in odd {
            guard let image else { check(false, "make \(label) image"); continue }
            let source = dir.appendingPathComponent("odd \(label).tiff")
            write(image, to: source, type: .tiff, props: [:])
            for type in [UTType.jpeg, .png, .tiff] + (Shrinker.writableTypes.contains(UTType.heic.identifier) ? [.heic] : []) {
                let target = dir.appendingPathComponent("odd \(label) out.\(type.preferredFilenameExtension ?? "img")")
                let r = try? Shrinker.shrink(source, to: target, type: type, settings: s)
                check(r != nil && Shrinker.info(of: target)?.width == 24, "\(label) to \(Shrinker.typeName(type.identifier))")
            }
        }
    }

    /// Batch planning: an output never lands on any image in the list, even one that an earlier run produced.
    private static func planning() {
        let a = URL(fileURLWithPath: "/tmp/pics/a.jpg")
        let own = URL(fileURLWithPath: "/tmp/pics/a-small.jpg") // a's earlier output, now also in the list as a source.
        let plan = Shrinker.plan([(a, UTType.jpeg, own), (own, UTType.jpeg, nil)], settings: ShrinkSettings()) { [a, own].contains($0) }
        check(plan.count == 2 && plan[0].path != own.path, "an earlier output that is now in the list is not overwritten (\(plan.map(\.lastPathComponent)))")
        check(Set(plan.map { $0.path.lowercased() }).count == 2 && !plan.contains(a) && !plan.contains(own), "plan never targets a source")
        let free = Shrinker.plan([(a, UTType.jpeg, own)], settings: ShrinkSettings()) { [a, own].contains($0) }
        check(free == [own], "own earlier output is replaced when it is not in the list")
    }

    private static func makeImage(_ w: Int, _ h: Int, alpha: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
        if !alpha {
            // Noise, so JPEG quality makes a measurable difference.
            for y in stride(from: 0, to: h, by: 2) {
                for x in stride(from: 0, to: w, by: 2) {
                    let v = CGFloat((x * 7919 + y * 104_729) % 255) / 255
                    ctx.setFillColor(CGColor(red: v, green: CGFloat(x) / CGFloat(w), blue: CGFloat(y) / CGFloat(h), alpha: 1))
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                }
            }
        } else {
            ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 0.5, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        }
        return ctx.makeImage()!
    }

    private static func makeImage(_ w: Int, _ h: Int, space: CGColorSpace, bits: Int, info: UInt32) -> CGImage? {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: bits, bytesPerRow: 0, space: space, bitmapInfo: info)
        ctx?.setFillColor(CGColor(gray: 0.4, alpha: 0.8))
        ctx?.fill(CGRect(x: 4, y: 4, width: w - 8, height: h - 8))
        return ctx?.makeImage()
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, props: [CFString: Any]) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func properties(_ url: URL) -> [CFString: Any]? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
    }

    private static func cornerIsWhite(_ url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixel[0] > 240 && pixel[1] > 240 && pixel[2] > 240
    }
}
