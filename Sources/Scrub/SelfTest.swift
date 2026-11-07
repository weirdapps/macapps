import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Scrub --selftest`: formatting, parsing and real round trips through ImageIO on temporary photos.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func run() -> Int32 {
        formatting()
        parsing()
        naming()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScrubSelfTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        roundTrips(dir)
        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    private static func formatting() {
        check(Format.exposure(1.0 / 250) == "1/250 s", "exposure fraction")
        check(Format.exposure(2) == "2 s", "exposure whole seconds")
        check(Format.exposure(1.5) == "1.5 s", "exposure decimal seconds")
        check(Format.fNumber(1.78) == "\u{0192}/1.8", "f-number rounding")
        check(Format.focal(6.86, equivalent: 24) == "6.86 mm (24 mm equiv.)", "focal length with equivalent")
        check(Format.focal(35, equivalent: 35) == "35 mm", "focal length without redundant equivalent")
        check(Format.bias(0.6667) == "+0.7 EV" && Format.bias(-1) == "\u{2212}1 EV" && Format.bias(0) == "0 EV", "exposure bias")
        check(Format.dms(37.971532, positive: "N", negative: "S") == "37\u{00B0}58\u{2032}17.5\u{2033} N", "degrees minutes seconds")
        check(Format.dms(-0.99999999, positive: "E", negative: "W") == "1\u{00B0}00\u{2032}00.0\u{2033} W", "seconds carry into degrees")
        check(Format.decimal(Coordinate(latitude: -33.8568, longitude: -151.2153)) == "33.85680\u{00B0} S, 151.21530\u{00B0} W", "decimal coordinates")
        check(MetadataReader.compass(248) == "W" && MetadataReader.compass(359) == "N" && MetadataReader.compass(45) == "NE", "compass points")
        let d = Format.exifDate("2026:08:14 19:42:07", offset: "+03:00")
        check(d?.timeIntervalSince1970 == 1_786_725_727, "EXIF date with offset")
        check(Format.timeZone("-05:30")?.secondsFromGMT() == -19800, "offset time zone")
        // Odd values straight from a file: none may crash.
        check(Format.exposure(.nan) == "Unknown" && Format.exposure(.infinity) == "Unknown" && Format.exposure(1e-300) == "Unknown",
              "exposure survives NaN, infinity and absurdly short times")
        check(MetadataReader.compass(.nan) == "" && MetadataReader.compass(-90) == "W", "compass survives NaN and negative angles")
        check(MetadataReader.int(Double.nan as NSNumber) == nil && MetadataReader.int(1e300 as NSNumber) == nil
              && MetadataReader.int("nan") == nil && MetadataReader.int("12") == 12, "integers from metadata never trap")
        let odd = MetadataReader.report(from: [Keys.exif: [kCGImagePropertyExifExposureTime as String: Double.nan,
                                                         kCGImagePropertyExifISOSpeedRatings as String: [Double.infinity],
                                                         kCGImagePropertyExifFlash as String: 1e40],
                                               Keys.gps: [kCGImagePropertyGPSLatitude as String: 10.0, kCGImagePropertyGPSLongitude as String: 20.0,
                                                          kCGImagePropertyGPSImgDirection as String: Double.nan],
                                               kCGImagePropertyPixelWidth as String: Double.infinity], type: "public.jpeg")
        check(odd.pixelWidth == 0 && odd.coordinate != nil, "a report from broken numbers still builds")
    }

    private static func parsing() {
        let gps: [String: Any] = [kCGImagePropertyGPSLatitude as String: 33.8568, kCGImagePropertyGPSLatitudeRef as String: "S",
                                  kCGImagePropertyGPSLongitude as String: 151.2153, kCGImagePropertyGPSLongitudeRef as String: "E",
                                  kCGImagePropertyGPSAltitude as String: 4.0, kCGImagePropertyGPSAltitudeRef as String: 1]
        let c = MetadataReader.coordinate(fromGPS: gps)
        check(c?.latitude == -33.8568 && c?.longitude == 151.2153 && c?.altitude == -4, "GPS references give signs")
        check(MetadataReader.coordinate(fromGPS: [kCGImagePropertyGPSLatitude as String: 120.0, kCGImagePropertyGPSLongitude as String: 0.0]) == nil,
              "out of range GPS rejected")

        let r = Demo.model.photos[1].report!
        check(r.flags == [.location, .cameraSerial, .lensSerial, .owner, .device, .dateTaken, .software], "every flag found in a camera photo")
        check(r.groups.map(\.title) == ["Camera", "Lens", "Exposure", "Date", "Location", "Software", "Other"], "groups in order")
        check(r.groups.first?.rows.first { $0.label == "Serial number" }?.sensitive == true, "serial marked sensitive")
        let screenshot = Demo.model.photos[4].report!
        check(screenshot.flags.isEmpty, "a screenshot has no privacy flags")
        check(Exposure.sentence([.location, .device, .dateTaken]) == "Anyone you send this photo to can see where it was taken, which camera took it and when.",
              "exposure sentence")
        check(Exposure.sentence([]).hasPrefix("Nothing"), "exposure sentence when clean")
        check(Demo.model.photos[0].report?.hasMakerNotes == true, "maker notes detected")
        let tagged = MetadataReader.report(from: [Keys.tiff: [kCGImagePropertyTIFFCopyright as String: "(c) Alex"],
                                                  Keys.iptc: [kCGImagePropertyIPTCKeywords as String: ["home", "kids"]],
                                                  kCGImagePropertyProfileName as String: "sRGB IEC61966-2.1"], type: "public.jpeg")
        check(tagged.flags.isEmpty && tagged.hasRemovableMetadata && tagged.removableRows == 2,
              "copyright and keywords alone can still be removed")
        let plain = MetadataReader.report(from: [kCGImagePropertyProfileName as String: "sRGB IEC61966-2.1",
                                                 kCGImagePropertyDPIWidth as String: 72], type: "public.png")
        check(!plain.hasRemovableMetadata, "a colour profile and resolution alone leave nothing to remove")
    }

    private static func naming() {
        let url = URL(fileURLWithPath: "/tmp/Pics/IMG_1.HEIC")
        check(Scrubber.outputURL(for: url, suffix: "-clean", folder: nil, exists: { _ in false }).path == "/tmp/Pics/IMG_1-clean.HEIC", "suffix name")
        let taken: Set<String> = ["/tmp/Pics/IMG_1-clean.HEIC", "/tmp/Pics/IMG_1-clean 2.HEIC"]
        check(Scrubber.outputURL(for: url, suffix: "-clean", folder: nil, exists: { taken.contains($0.path) }).path == "/tmp/Pics/IMG_1-clean 3.HEIC",
              "taken names are numbered")
        check(Scrubber.outputURL(for: url, suffix: "", folder: nil, exists: { _ in false }).path == "/tmp/Pics/IMG_1 2.HEIC",
              "empty suffix never overwrites the original")
        check(Scrubber.outputURL(for: url, suffix: "-clean", folder: URL(fileURLWithPath: "/tmp/Out"), exists: { _ in false }).path
              == "/tmp/Out/IMG_1-clean.HEIC", "chosen folder")
        check(Scrubber.outputURL(for: url, suffix: "/../../x", folder: nil, exists: { _ in false }).path == "/tmp/Pics/IMG_1-..-..-x.HEIC",
              "a suffix cannot leave the folder")
        check(Scrubber.outputURL(for: URL(fileURLWithPath: "/tmp/Pics/Ελλάδα 東京 🌅.jpg"), suffix: " -clean ", folder: nil, exists: { _ in false })
              .lastPathComponent == "Ελλάδα 東京 🌅-clean.jpg", "unicode names and a padded suffix")
        check(Scrubber.outputURL(for: URL(fileURLWithPath: "/tmp/Pics/noext"), suffix: "-clean", folder: nil, exists: { _ in false })
              .lastPathComponent == "noext-clean", "a name without an extension")
    }

    // MARK: Round trips

    /// A 64 by 48 photo with a gradient and full camera metadata, written as `type`.
    static func makePhoto(_ url: URL, type: UTType, orientation: Int = 6) -> Bool {
        let w = 64, h = 48
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        for x in 0..<w {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / CGFloat(w), green: 0.4, blue: 1 - CGFloat(x) / CGFloat(w), alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Testcam", kCGImagePropertyTIFFModel: "T1000",
                                             kCGImagePropertyTIFFSoftware: "Firmware 2.0", kCGImagePropertyTIFFOrientation: orientation],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:05:01 10:20:30",
                                             kCGImagePropertyExifBodySerialNumber: "SN12345", kCGImagePropertyExifFNumber: 2.8,
                                             kCGImagePropertyExifExposureTime: 0.01, kCGImagePropertyExifCameraOwnerName: "Test Owner"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImageDestinationLossyCompressionQuality: 0.9,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// The decoded pixels of `url`, ignoring orientation, for comparing a copy with its original.
    static func pixels(_ url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let data = ctx.data else { return nil }
        return Data(bytes: data, count: image.width * image.height * 4)
    }

    private static func roundTrips(_ dir: URL) {
        let jpeg = dir.appendingPathComponent("photo.jpg")
        check(makePhoto(jpeg, type: .jpeg), "test JPEG written")
        guard let original = MetadataReader.read(jpeg) else { check(false, "test JPEG read"); return }
        check(original.flags.isSuperset(of: [.location, .cameraSerial, .owner, .device, .dateTaken, .software]), "test JPEG flags read back")
        check(original.coordinate.map { abs($0.latitude - 48.8584) < 0.0001 && abs($0.longitude - 2.2945) < 0.0001 } == true, "test JPEG coordinate")
        check(original.orientation == 6, "test JPEG orientation")

        // Remove location only.
        let noLocation = Scrubber.outputURL(for: jpeg, suffix: "-noloc", folder: nil)
        do {
            let r = try Scrubber.clean(jpeg, mode: .location, to: noLocation)
            check(r.lossless, "location removal is lossless for JPEG")
            check(!r.report.flags.contains(.location) && r.report.coordinate == nil, "location gone")
            check(r.report.flags.isSuperset(of: [.device, .cameraSerial, .dateTaken]), "other metadata kept when removing location")
            check(r.report.orientation == 6, "orientation kept when removing location")
            check(pixels(noLocation) == pixels(jpeg), "pixels identical after removing location")
        } catch { check(false, "remove location: \(error.localizedDescription)") }

        // Remove everything.
        let clean = Scrubber.outputURL(for: jpeg, suffix: "-clean", folder: nil)
        do {
            let r = try Scrubber.clean(jpeg, mode: .all, to: clean)
            check(r.report.flags.isEmpty, "no privacy flags after removing all (left: \(r.report.sortedFlags.map(\.title)))")
            check(r.report.orientation == 6, "orientation kept when removing all")
            check(r.report.pixelWidth == 64 && r.report.pixelHeight == 48, "size kept when removing all")
            check(r.lossless && pixels(clean) == pixels(jpeg), "pixels identical after removing all")
            check(Scrubber.verify(clean, mode: .all, against: original).ok, "verification passes on the clean copy")
            check(!Scrubber.verify(jpeg, mode: .all, against: original).ok, "verification fails on the original")
        } catch { check(false, "remove all: \(error.localizedDescription)") }
        check(MetadataReader.read(jpeg)?.flags.contains(.location) == true, "original untouched")

        // Other formats.
        for type in [UTType.png, .tiff, .heic] {
            let ids = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            guard ids.contains(type.identifier) else { continue }
            let src = dir.appendingPathComponent("photo." + (type.preferredFilenameExtension ?? "img"))
            guard makePhoto(src, type: type, orientation: 3) else { check(false, "\(type.identifier) written"); continue }
            let before = MetadataReader.read(src)
            do {
                let out = Scrubber.outputURL(for: src, suffix: "-clean", folder: nil)
                let r = try Scrubber.clean(src, mode: .all, to: out)
                check(r.report.flags.isEmpty && r.report.orientation == 3 && r.report.pixelWidth == before?.pixelWidth,
                      "\(type.preferredFilenameExtension ?? "") clean copy (\(r.lossless ? "lossless" : "re-encoded"), left: \(r.report.sortedFlags.map(\.title)))")
                let loc = try Scrubber.clean(src, mode: .location, to: Scrubber.outputURL(for: src, suffix: "-noloc", folder: nil))
                check(!loc.report.flags.contains(.location) && loc.report.flags.contains(.device),
                      "\(type.preferredFilenameExtension ?? "") location removal keeps the rest")
            } catch { check(false, "\(type.identifier): \(error.localizedDescription)") }
        }

        // Folder discovery.
        let sub = dir.appendingPathComponent("Album", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = makePhoto(sub.appendingPathComponent("b.jpg"), type: .jpeg)
        try? Data("notes".utf8).write(to: sub.appendingPathComponent("notes.txt"))
        let found = Scrubber.imageFiles(in: [sub, sub.appendingPathComponent("b.jpg")])
        check(found.count == 1 && found.first?.lastPathComponent == "b.jpg", "folders searched, non images and duplicates skipped")

        // Empty and garbage files with image names are read as nothing, not as a crash.
        let empty = dir.appendingPathComponent("empty.jpg"), junk = dir.appendingPathComponent("junk.heic")
        try? Data().write(to: empty)
        try? Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        check(MetadataReader.read(empty) == nil && MetadataReader.thumbnail(empty) == nil, "an empty file is not a photo")
        check(MetadataReader.read(junk) == nil, "a garbage file is not a photo")
        check((try? Scrubber.clean(empty, mode: .all, to: dir.appendingPathComponent("empty-clean.jpg"))) == nil
              && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("empty-clean.jpg").path), "an empty file writes no copy")

        // A folder Scrub may not write into gives a clear error and leaves nothing behind.
        let locked = dir.appendingPathComponent("Locked", isDirectory: true)
        try? FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        do {
            _ = try Scrubber.clean(jpeg, mode: .all, to: locked.appendingPathComponent("photo-clean.jpg"))
            check(false, "read only folder refused")
        } catch ScrubError.folderNotWritable {
            check(true, "read only folder refused")
        } catch { check(false, "read only folder refused (\(error.localizedDescription))") }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        // A file that is not an image fails cleanly.
        do {
            _ = try Scrubber.clean(sub.appendingPathComponent("notes.txt"), mode: .all, to: dir.appendingPathComponent("x.txt"))
            check(false, "non image rejected")
        } catch { check(true, "non image rejected") }
    }
}
