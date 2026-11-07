import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Metadata report

struct MetaRow: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let value: String
    var sensitive = false
}

struct MetaGroup: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let symbol: String
    var rows: [MetaRow]
}

/// Something in a photo that says more about you than the picture does.
enum PrivacyFlag: Int, CaseIterable, Sendable, Comparable {
    case location, cameraSerial, lensSerial, owner, device, dateTaken, software

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .location: "Location"
        case .cameraSerial: "Camera serial"
        case .lensSerial: "Lens serial"
        case .owner: "Owner name"
        case .device: "Camera model"
        case .dateTaken: "Date taken"
        case .software: "Software"
        }
    }

    var symbol: String {
        switch self {
        case .location: "location.fill"
        case .cameraSerial: "barcode"
        case .lensSerial: "camera.aperture"
        case .owner: "person.fill"
        case .device: "camera.fill"
        case .dateTaken: "calendar"
        case .software: "gearshape.fill"
        }
    }

    /// High risk flags identify a place or a person; the rest identify a device or a moment.
    var isHigh: Bool { self == .location || self == .cameraSerial || self == .lensSerial || self == .owner }
}

enum Exposure {
    /// One plain sentence on what a photo gives away to whoever receives it.
    static func sentence(_ flags: Set<PrivacyFlag>) -> String {
        var parts: [String] = []
        if flags.contains(.location) { parts.append("where it was taken") }
        if flags.contains(.owner) { parts.append("your name") }
        if flags.contains(.cameraSerial) || flags.contains(.lensSerial) { parts.append("your camera\u{2019}s serial number") }
        if flags.contains(.device) { parts.append("which camera took it") }
        if flags.contains(.dateTaken) { parts.append("when") }
        if flags.contains(.software) && parts.isEmpty { parts.append("the software that made it") }
        guard !parts.isEmpty else { return "Nothing in this photo points back to you or to a place." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Anyone you send this photo to can see " + list + "."
    }
}

struct Coordinate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var altitude: Double?
}

struct PhotoReport: Sendable {
    var groups: [MetaGroup] = []
    var flags: Set<PrivacyFlag> = []
    var coordinate: Coordinate?
    var pixelWidth = 0
    var pixelHeight = 0
    var orientation = 1
    var typeName = "Image"
    var tagCount = 0
    var hasMakerNotes = false

    var sortedFlags: [PrivacyFlag] { flags.sorted() }
}

enum Keys {
    static let tiff = kCGImagePropertyTIFFDictionary as String
    static let exif = kCGImagePropertyExifDictionary as String
    static let exifAux = kCGImagePropertyExifAuxDictionary as String
    static let gps = kCGImagePropertyGPSDictionary as String
    static let iptc = kCGImagePropertyIPTCDictionary as String
    static let apple = kCGImagePropertyMakerAppleDictionary as String
}

enum Format {
    static func exposure(_ t: Double) -> String {
        if t <= 0 { return "Unknown" }
        if t >= 1 { return number(t, digits: 1) + " s" }
        return "1/\(Int((1 / t).rounded())) s"
    }

    static func fNumber(_ f: Double) -> String { "\u{0192}/" + number(f, digits: 1) }

    static func focal(_ mm: Double, equivalent: Int?) -> String {
        var s = number(mm, digits: 2) + " mm"
        if let e = equivalent, e > 0, abs(Double(e) - mm) > 0.5 { s += " (\(e) mm equiv.)" }
        return s
    }

    static func bias(_ ev: Double) -> String {
        if abs(ev) < 0.01 { return "0 EV" }
        return (ev > 0 ? "+" : "\u{2212}") + number(abs(ev), digits: 1) + " EV"
    }

    /// Up to `digits` decimals, trailing zeros dropped: 1.80 -> "1.8", 2.0 -> "2".
    static func number(_ v: Double, digits: Int) -> String {
        var s = String(format: "%.\(digits)f", v + (v >= 0 ? 1e-9 : -1e-9))
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    static func decimal(_ c: Coordinate) -> String {
        String(format: "%.5f\u{00B0} %@, %.5f\u{00B0} %@", abs(c.latitude), c.latitude >= 0 ? "N" : "S",
               abs(c.longitude), c.longitude >= 0 ? "E" : "W")
    }

    static func dms(_ value: Double, positive: String, negative: String) -> String {
        let v = abs(value)
        var deg = Int(v)
        var min = Int((v - Double(deg)) * 60)
        var sec = ((v - Double(deg)) * 60 - Double(min)) * 60
        if (sec * 10).rounded() >= 600 { sec = 0; min += 1 }
        if min >= 60 { min = 0; deg += 1 }
        return String(format: "%d\u{00B0}%02d\u{2032}%04.1f\u{2033} %@", deg, min, sec, value >= 0 ? positive : negative)
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// EXIF dates look like "2026:08:14 19:42:07", optionally with an offset such as "+03:00".
    static func exifDate(_ s: String, offset: String? = nil) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset, !offset.isEmpty {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: s + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f.date(from: s)
    }

    static func displayDate(_ s: String, offset: String? = nil) -> String {
        guard let d = exifDate(s, offset: offset) else { return s }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        if let offset, let tz = timeZone(offset) { f.timeZone = tz }
        return f.string(from: d) + (offset.map { " (UTC\($0))" } ?? "")
    }

    static func timeZone(_ offset: String) -> TimeZone? {
        let parts = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, let sign = offset.first, sign == "+" || sign == "-" else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (parts[0] * 3600 + parts[1] * 60))
    }
}

enum MetadataReader {
    static func read(_ url: URL) -> PhotoReport? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
        var report = report(from: props, type: CGImageSourceGetType(src) as String?)
        if let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil), hasXMPLocation(meta) { report.flags.insert(.location) }
        return report
    }

    static func thumbnail(_ url: URL, maxPixels: Int = 900) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// True when the XMP packet still carries GPS tags that the property dictionaries may not show.
    static func hasXMPLocation(_ meta: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(meta, nil, [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, _ in
            if (path as String).contains("GPSLatitude") || (path as String).contains("GPSLongitude") { found = true; return false }
            return true
        }
        return found
    }

    static func coordinate(fromGPS gps: [String: Any]) -> Coordinate? {
        guard let lat = double(gps[kCGImagePropertyGPSLatitude as String]),
              let lon = double(gps[kCGImagePropertyGPSLongitude as String]) else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef as String] as? String)?.uppercased() ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef as String] as? String)?.uppercased() ?? "E"
        var c = Coordinate(latitude: latRef == "S" ? -abs(lat) : lat, longitude: lonRef == "W" ? -abs(lon) : lon)
        if let alt = double(gps[kCGImagePropertyGPSAltitude as String]) {
            c.altitude = (gps[kCGImagePropertyGPSAltitudeRef as String] as? Int) == 1 ? -alt : alt
        }
        guard (-90...90).contains(c.latitude), (-180...180).contains(c.longitude) else { return nil }
        return c
    }

    static func report(from props: [String: Any], type: String?) -> PhotoReport {
        let tiff = props[Keys.tiff] as? [String: Any] ?? [:]
        let exif = props[Keys.exif] as? [String: Any] ?? [:]
        let aux = props[Keys.exifAux] as? [String: Any] ?? [:]
        let gps = props[Keys.gps] as? [String: Any] ?? [:]
        let iptc = props[Keys.iptc] as? [String: Any] ?? [:]
        func t(_ k: CFString) -> String? { string(tiff[k as String]) }
        func e(_ k: CFString) -> Any? { exif[k as String] }
        func es(_ k: CFString) -> String? { string(exif[k as String]) }

        var r = PhotoReport()
        r.pixelWidth = int(props[kCGImagePropertyPixelWidth as String]) ?? 0
        r.pixelHeight = int(props[kCGImagePropertyPixelHeight as String]) ?? 0
        r.orientation = int(props[kCGImagePropertyOrientation as String]) ?? int(tiff[kCGImagePropertyTIFFOrientation as String]) ?? 1
        if let type, let ut = UTType(type) { r.typeName = ut.localizedDescription ?? ut.preferredFilenameExtension?.uppercased() ?? "Image" }
        r.hasMakerNotes = props.keys.contains { $0.hasPrefix("{MakerApple") || $0.hasPrefix("{MakerCanon") || $0.hasPrefix("{MakerNikon")
            || $0.hasPrefix("{MakerMinolta") || $0.hasPrefix("{MakerFuji") || $0.hasPrefix("{MakerOlympus") || $0.hasPrefix("{MakerPentax") }
        r.tagCount = props.reduce(0) { n, kv in n + ((kv.value as? [String: Any]).map(leafCount) ?? 0) }

        // Camera
        var camera = MetaGroup(title: "Camera", symbol: "camera.fill", rows: [])
        if let make = t(kCGImagePropertyTIFFMake) { camera.rows.append(MetaRow(label: "Make", value: make)) }
        if let model = t(kCGImagePropertyTIFFModel) { camera.rows.append(MetaRow(label: "Model", value: model)) }
        if !camera.rows.isEmpty { r.flags.insert(.device) }
        if let serial = es(kCGImagePropertyExifBodySerialNumber) ?? string(aux[kCGImagePropertyExifAuxSerialNumber as String]) {
            camera.rows.append(MetaRow(label: "Serial number", value: serial, sensitive: true))
            r.flags.insert(.cameraSerial)
        }
        if let owner = es(kCGImagePropertyExifCameraOwnerName) {
            camera.rows.append(MetaRow(label: "Owner", value: owner, sensitive: true))
            r.flags.insert(.owner)
        }

        // Lens
        var lens = MetaGroup(title: "Lens", symbol: "camera.aperture", rows: [])
        if let make = es(kCGImagePropertyExifLensMake) { lens.rows.append(MetaRow(label: "Make", value: make)) }
        if let model = es(kCGImagePropertyExifLensModel) ?? string(aux[kCGImagePropertyExifAuxLensModel as String]) {
            lens.rows.append(MetaRow(label: "Model", value: model))
        }
        if let mm = double(e(kCGImagePropertyExifFocalLength)) {
            lens.rows.append(MetaRow(label: "Focal length", value: Format.focal(mm, equivalent: int(e(kCGImagePropertyExifFocalLenIn35mmFilm)))))
        }
        if let serial = es(kCGImagePropertyExifLensSerialNumber) ?? string(aux[kCGImagePropertyExifAuxLensSerialNumber as String]) {
            lens.rows.append(MetaRow(label: "Serial number", value: serial, sensitive: true))
            r.flags.insert(.lensSerial)
        }

        // Exposure
        var exposure = MetaGroup(title: "Exposure", symbol: "camera.metering.center.weighted", rows: [])
        if let v = double(e(kCGImagePropertyExifExposureTime)) { exposure.rows.append(MetaRow(label: "Shutter", value: Format.exposure(v))) }
        if let v = double(e(kCGImagePropertyExifFNumber)) { exposure.rows.append(MetaRow(label: "Aperture", value: Format.fNumber(v))) }
        if let iso = (e(kCGImagePropertyExifISOSpeedRatings) as? [Any])?.first.flatMap(int) ?? int(e(kCGImagePropertyExifISOSpeedRatings)) {
            exposure.rows.append(MetaRow(label: "ISO", value: "\(iso)"))
        }
        if let v = double(e(kCGImagePropertyExifExposureBiasValue)) { exposure.rows.append(MetaRow(label: "Compensation", value: Format.bias(v))) }
        if let v = int(e(kCGImagePropertyExifExposureProgram)), let name = program(v) { exposure.rows.append(MetaRow(label: "Program", value: name)) }
        if let v = int(e(kCGImagePropertyExifMeteringMode)), let name = metering(v) { exposure.rows.append(MetaRow(label: "Metering", value: name)) }
        if let v = int(e(kCGImagePropertyExifFlash)) { exposure.rows.append(MetaRow(label: "Flash", value: v & 1 == 1 ? "Fired" : "Off")) }
        if let v = int(e(kCGImagePropertyExifWhiteBalance)) { exposure.rows.append(MetaRow(label: "White balance", value: v == 1 ? "Manual" : "Auto")) }

        // Date
        var date = MetaGroup(title: "Date", symbol: "calendar", rows: [])
        if let s = es(kCGImagePropertyExifDateTimeOriginal) {
            date.rows.append(MetaRow(label: "Taken", value: Format.displayDate(s, offset: es(kCGImagePropertyExifOffsetTimeOriginal)), sensitive: true))
        }
        if let s = es(kCGImagePropertyExifDateTimeDigitized), s != es(kCGImagePropertyExifDateTimeOriginal) {
            date.rows.append(MetaRow(label: "Digitized", value: Format.displayDate(s, offset: es(kCGImagePropertyExifOffsetTimeDigitized))))
        }
        if let s = t(kCGImagePropertyTIFFDateTime) { date.rows.append(MetaRow(label: "Modified", value: Format.displayDate(s, offset: es(kCGImagePropertyExifOffsetTime)))) }
        if !date.rows.isEmpty { r.flags.insert(.dateTaken) }

        // Location
        var location = MetaGroup(title: "Location", symbol: "location.fill", rows: [])
        if let c = coordinate(fromGPS: gps) {
            r.coordinate = c
            r.flags.insert(.location)
            location.rows.append(MetaRow(label: "Coordinates", value: Format.decimal(c), sensitive: true))
            location.rows.append(MetaRow(label: "Latitude", value: Format.dms(c.latitude, positive: "N", negative: "S")))
            location.rows.append(MetaRow(label: "Longitude", value: Format.dms(c.longitude, positive: "E", negative: "W")))
            if let alt = c.altitude { location.rows.append(MetaRow(label: "Altitude", value: Format.number(alt, digits: 0) + " m")) }
            if let dir = double(gps[kCGImagePropertyGPSImgDirection as String]) {
                location.rows.append(MetaRow(label: "Facing", value: Format.number(dir, digits: 0) + "\u{00B0} " + compass(dir)))
            }
        } else if gps.keys.contains(where: { $0 != kCGImagePropertyGPSVersion as String }) {
            location.rows.append(MetaRow(label: "GPS", value: "\(leafCount(gps)) tags, no position", sensitive: true))
            r.flags.insert(.location)
        }
        for (label, key) in [("City", kCGImagePropertyIPTCCity), ("Region", kCGImagePropertyIPTCProvinceState),
                             ("Country", kCGImagePropertyIPTCCountryPrimaryLocationName)] {
            if let v = string(iptc[key as String]) { location.rows.append(MetaRow(label: label, value: v, sensitive: true)) }
        }

        // Software
        var software = MetaGroup(title: "Software", symbol: "gearshape.fill", rows: [])
        if let s = t(kCGImagePropertyTIFFSoftware) { software.rows.append(MetaRow(label: "Software", value: s)) }
        if let s = t(kCGImagePropertyTIFFHostComputer) { software.rows.append(MetaRow(label: "Computer", value: s, sensitive: true)) }
        if !software.rows.isEmpty { r.flags.insert(.software) }

        // Other
        var other = MetaGroup(title: "Other", symbol: "ellipsis.circle.fill", rows: [])
        if let artist = t(kCGImagePropertyTIFFArtist) ?? string(iptc[kCGImagePropertyIPTCByline as String]) {
            other.rows.append(MetaRow(label: "Author", value: artist, sensitive: true))
            r.flags.insert(.owner)
        }
        if let c = t(kCGImagePropertyTIFFCopyright) ?? string(iptc[kCGImagePropertyIPTCCopyrightNotice as String]) {
            other.rows.append(MetaRow(label: "Copyright", value: c))
        }
        if let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [Any], !keywords.isEmpty {
            other.rows.append(MetaRow(label: "Keywords", value: keywords.compactMap(string).joined(separator: ", ")))
        }
        if let profile = string(props[kCGImagePropertyProfileName as String]) { other.rows.append(MetaRow(label: "Colour profile", value: profile)) }
        if let dpi = double(props[kCGImagePropertyDPIWidth as String]) { other.rows.append(MetaRow(label: "Resolution", value: Format.number(dpi, digits: 0) + " dpi")) }
        if r.orientation != 1 { other.rows.append(MetaRow(label: "Orientation", value: orientationName(r.orientation))) }
        if r.hasMakerNotes { other.rows.append(MetaRow(label: "Maker notes", value: "Present")) }

        r.groups = [camera, lens, exposure, date, location, software, other].filter { !$0.rows.isEmpty }
        return r
    }

    // MARK: Value helpers

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            return trimmed.isEmpty ? nil : trimmed
        case let a as [Any]: return a.compactMap(string).first
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func double(_ v: Any?) -> Double? {
        switch v {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    static func int(_ v: Any?) -> Int? { double(v).map { Int($0) } }

    static func leafCount(_ d: [String: Any]) -> Int {
        d.values.reduce(0) { n, v in n + ((v as? [String: Any]).map(leafCount) ?? 1) }
    }

    static func compass(_ degrees: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let i = Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
        return names[i]
    }

    static func program(_ v: Int) -> String? {
        [1: "Manual", 2: "Normal", 3: "Aperture priority", 4: "Shutter priority", 5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"][v]
    }

    static func metering(_ v: Int) -> String? {
        [1: "Average", 2: "Center weighted", 3: "Spot", 4: "Multi spot", 5: "Pattern", 6: "Partial"][v]
    }

    static func orientationName(_ v: Int) -> String {
        [2: "Mirrored", 3: "Rotated 180\u{00B0}", 4: "Mirrored vertically", 5: "Mirrored, rotated 90\u{00B0}",
         6: "Rotated 90\u{00B0} clockwise", 7: "Mirrored, rotated 270\u{00B0}", 8: "Rotated 90\u{00B0} counterclockwise"][v] ?? "Normal"
    }
}

// MARK: - Scrubbing

enum ScrubMode: Sendable {
    case location, all

    var title: String { self == .location ? "Remove Location" : "Remove All Metadata" }
}

struct Verification: Sendable {
    var problems: [String]
    var ok: Bool { problems.isEmpty }
}

struct CleanResult: Sendable {
    let output: URL
    let lossless: Bool
    let verification: Verification
    let report: PhotoReport
    let mode: ScrubMode
}

enum ScrubError: LocalizedError {
    case unreadable, unwritable(String), verifyFailed([String])

    var errorDescription: String? {
        switch self {
        case .unreadable: "The photo could not be read."
        case .unwritable(let type): "Scrub cannot write \(type) files."
        case .verifyFailed(let problems): "The cleaned copy did not pass the check: " + problems.joined(separator: ", ") + "."
        }
    }
}

enum Scrubber {
    /// `IMG_1-clean.jpg` next to the original or in `folder`, numbered if that name is taken.
    static func outputURL(for url: URL, suffix: String, folder: URL?, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let dir = folder ?? url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent + suffix
        let ext = url.pathExtension
        func make(_ name: String) -> URL { dir.appendingPathComponent(ext.isEmpty ? name : name + "." + ext) }
        var candidate = make(base)
        var n = 2
        while exists(candidate) || candidate.standardizedFileURL == url.standardizedFileURL {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    /// Writes a cleaned copy and re-reads it to prove the metadata is gone. The original is never touched.
    /// A lossless copy keeps the compressed image data byte for byte; when ImageIO cannot copy a format that way
    /// (HEIC with an XMP packet, for one), it is re-encoded at high quality instead.
    static func clean(_ url: URL, mode: ScrubMode, to output: URL) throws -> CleanResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let type = CGImageSourceGetType(src) else { throw ScrubError.unreadable }
        let before = MetadataReader.report(from: CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:], type: type as String)

        var lossless = false
        if copyLossless(src, type: type, mode: mode, orientation: before.orientation, to: output) {
            let v = verify(output, mode: mode, against: before)
            if v.ok { lossless = true } else { try? FileManager.default.removeItem(at: output) }
        }
        if !lossless {
            guard reencode(src, type: type, mode: mode, orientation: before.orientation, to: output) else {
                throw ScrubError.unwritable(UTType(type as String)?.preferredFilenameExtension?.uppercased() ?? "these")
            }
        }
        let v = verify(output, mode: mode, against: before)
        guard v.ok else {
            try? FileManager.default.removeItem(at: output)
            throw ScrubError.verifyFailed(v.problems)
        }
        return CleanResult(output: output, lossless: lossless, verification: v, report: MetadataReader.read(output) ?? PhotoReport(), mode: mode)
    }

    private static func copyLossless(_ src: CGImageSource, type: CFString, mode: ScrubMode, orientation: Int, to output: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type, CGImageSourceGetCount(src), nil) else { return false }
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true, kCGImageDestinationMergeMetadata: false]
        switch mode {
        case .location:
            // Without metadata of its own the copy would drop everything; hand it the original minus GPS.
            guard let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil) else { return false }
            options[kCGImageDestinationMetadata] = meta
        case .all:
            // An XMP packet can repeat the date, the software and the place, so it goes too.
            options[kCGImageMetadataShouldExcludeXMP] = true
            let meta = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                             orientation as CFNumber)
            }
            options[kCGImageDestinationMetadata] = meta
        }
        return CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, nil)
    }

    private static func reencode(_ src: CGImageSource, type: CFString, mode: ScrubMode, orientation: Int, to output: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else { return false }
        var props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.92,
                                    kCGImagePropertyGPSDictionary as String: kCFNull as Any]
        if mode == .all {
            // Every metadata dictionary the source has, set to null, keeps only the pixels, the colour profile and the orientation.
            let source = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] ?? [:]
            for key in source.keys where key.hasPrefix("{") { props[key] = kCFNull }
            for key in [Keys.tiff, Keys.exif, Keys.exifAux, Keys.iptc, Keys.apple] { props[key] = kCFNull }
            props[kCGImagePropertyOrientation as String] = orientation
        }
        CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Re-reads `output` and lists anything that should have gone, or anything that changed but should not have.
    static func verify(_ output: URL, mode: ScrubMode, against before: PhotoReport) -> Verification {
        guard let after = MetadataReader.read(output) else { return Verification(problems: ["it could not be read back"]) }
        var problems: [String] = []
        if after.flags.contains(.location) { problems.append("location still present") }
        if mode == .all {
            for flag in after.sortedFlags where flag != .location { problems.append("\(flag.title.lowercased()) still present") }
            if after.hasMakerNotes { problems.append("maker notes still present") }
        }
        if after.pixelWidth != before.pixelWidth || after.pixelHeight != before.pixelHeight { problems.append("image size changed") }
        if after.orientation != before.orientation { problems.append("orientation changed") }
        return Verification(problems: problems)
    }

    /// Image files among `urls`, looking inside folders, without duplicates.
    static func imageFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        var seen = Set<String>()
        func add(_ u: URL) {
            guard isImage(u), seen.insert(u.standardizedFileURL.path).inserted else { return }
            out.append(u)
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
                let files = (e?.allObjects as? [URL] ?? []).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                files.forEach(add)
            } else {
                add(url)
            }
        }
        return out
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf)
    }
}
