import AppKit
import ImageIO
import Kit

// Fixed demo photos for the website screenshot: made up metadata run through the real parser, and drawn thumbnails.

@MainActor
enum Demo {
    static var map: NSImage?
    static let acropolis = Coordinate(latitude: 37.971532, longitude: 23.725749, altitude: 152)

    /// Fetches the Location card's map before the snapshot window exists, waiting a few seconds at most.
    static func prefetchMap() {
        var finished = false
        MapSnapshot.make(acropolis, appearance: NSAppearance(named: .aqua)) { image in
            map = image
            finished = true
        }
        let deadline = Date().addingTimeInterval(8)
        while !finished, Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    static func gps(_ c: Coordinate, direction: Double? = nil) -> [String: Any] {
        var d: [String: Any] = [kCGImagePropertyGPSLatitude as String: abs(c.latitude), kCGImagePropertyGPSLatitudeRef as String: c.latitude >= 0 ? "N" : "S",
                                kCGImagePropertyGPSLongitude as String: abs(c.longitude), kCGImagePropertyGPSLongitudeRef as String: c.longitude >= 0 ? "E" : "W"]
        if let a = c.altitude { d[kCGImagePropertyGPSAltitude as String] = a; d[kCGImagePropertyGPSAltitudeRef as String] = 0 }
        if let direction { d[kCGImagePropertyGPSImgDirection as String] = direction }
        return d
    }

    static func props(width: Int, height: Int, tiff: [CFString: Any], exif: [CFString: Any], gps: [String: Any]? = nil,
                      extra: [String: Any] = [:]) -> [String: Any] {
        var p: [String: Any] = [kCGImagePropertyPixelWidth as String: width, kCGImagePropertyPixelHeight as String: height,
                                kCGImagePropertyProfileName as String: "Display P3", kCGImagePropertyDPIWidth as String: 72]
        p[Keys.tiff] = Dictionary(uniqueKeysWithValues: tiff.map { ($0.key as String, $0.value) })
        p[Keys.exif] = Dictionary(uniqueKeysWithValues: exif.map { ($0.key as String, $0.value) })
        if let gps { p[Keys.gps] = gps }
        return p.merging(extra) { a, _ in a }
    }

    static var model: ScrubModel {
        let m = ScrubModel()
        let iphone = props(width: 4032, height: 3024, tiff: [
            kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 16 Pro", kCGImagePropertyTIFFSoftware: "26.1",
            kCGImagePropertyTIFFHostComputer: "iPhone 16 Pro", kCGImagePropertyTIFFDateTime: "2026:08:14 19:42:07",
        ], exif: [
            kCGImagePropertyExifLensMake: "Apple", kCGImagePropertyExifLensModel: "iPhone 16 Pro back triple camera 6.765mm f/1.78",
            kCGImagePropertyExifFocalLength: 6.765, kCGImagePropertyExifFocalLenIn35mmFilm: 24,
            kCGImagePropertyExifExposureTime: 1.0 / 1250, kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifISOSpeedRatings: [80],
            kCGImagePropertyExifExposureBiasValue: 0.0, kCGImagePropertyExifExposureProgram: 2, kCGImagePropertyExifMeteringMode: 5,
            kCGImagePropertyExifFlash: 16, kCGImagePropertyExifWhiteBalance: 0,
            kCGImagePropertyExifDateTimeOriginal: "2026:08:14 19:42:07", kCGImagePropertyExifOffsetTimeOriginal: "+03:00",
        ], gps: gps(acropolis, direction: 248.6), extra: [Keys.apple: ["1": 14, "2": 1, "3": 0, "8": [0.1, 0.2], "14": 4]])
        let nikon = props(width: 6048, height: 4024, tiff: [
            kCGImagePropertyTIFFMake: "NIKON CORPORATION", kCGImagePropertyTIFFModel: "NIKON Z 6_2",
            kCGImagePropertyTIFFSoftware: "Ver.1.60", kCGImagePropertyTIFFArtist: "Alex Morgan",
        ], exif: [
            kCGImagePropertyExifBodySerialNumber: "6021843", kCGImagePropertyExifCameraOwnerName: "Alex Morgan",
            kCGImagePropertyExifLensModel: "NIKKOR Z 24-70mm f/4 S", kCGImagePropertyExifLensSerialNumber: "20117755",
            kCGImagePropertyExifFocalLength: 35.0, kCGImagePropertyExifExposureTime: 1.0 / 320, kCGImagePropertyExifFNumber: 8.0,
            kCGImagePropertyExifISOSpeedRatings: [100], kCGImagePropertyExifDateTimeOriginal: "2026:07:02 20:15:44",
        ], gps: gps(Coordinate(latitude: 36.461826, longitude: 25.375312, altitude: 98)))
        let pixel = props(width: 4080, height: 3072, tiff: [
            kCGImagePropertyTIFFMake: "Google", kCGImagePropertyTIFFModel: "Pixel 9", kCGImagePropertyTIFFSoftware: "HDR+ 1.0.641377693zd",
        ], exif: [
            kCGImagePropertyExifExposureTime: 1.0 / 2000, kCGImagePropertyExifFNumber: 1.68, kCGImagePropertyExifISOSpeedRatings: [44],
            kCGImagePropertyExifDateTimeOriginal: "2026:09:21 11:03:12",
        ], gps: gps(Coordinate(latitude: 46.558, longitude: 11.761, altitude: 2240)))
        let screenshot = props(width: 2940, height: 1912, tiff: [:], exif: [kCGImagePropertyExifUserComment: "Screenshot"])

        func photo(_ name: String, size: Int64, _ p: [String: Any], type: String, scene: Scene) -> Photo {
            var photo = Photo(url: URL(fileURLWithPath: "/Users/demo/Pictures/" + name))
            photo.fileSize = size
            photo.report = MetadataReader.report(from: p, type: type)
            photo.loading = false
            photo.thumbnail = scene.image
            return photo
        }
        var cleaned = photo("Harbour_0912.jpg", size: 3_412_880, pixel, type: "public.jpeg", scene: .harbour)
        var cleanReport = MetadataReader.report(from: props(width: 4080, height: 3072, tiff: [:], exif: [:]), type: "public.jpeg")
        cleanReport.tagCount = 4
        cleaned.result = CleanResult(output: URL(fileURLWithPath: "/Users/demo/Pictures/Harbour_0912-clean.jpg"), lossless: true,
                                     verification: Verification(problems: []), report: cleanReport, mode: .all)
        m.photos = [
            photo("IMG_4021.HEIC", size: 2_874_112, iphone, type: "public.heic", scene: .sunset),
            photo("DSC_0187.JPG", size: 11_604_321, nikon, type: "public.jpeg", scene: .sea),
            photo("Dolomites_hike.jpg", size: 4_190_552, pixel, type: "public.jpeg", scene: .mountains),
            cleaned,
            photo("Screenshot 2026-11-02.png", size: 1_208_334, screenshot, type: "public.png", scene: .screen),
        ]
        m.selection = [m.photos[0].id]
        if let map { m.maps[m.photos[0].id] = map }
        return m
    }

    enum Scene {
        case sunset, sea, mountains, harbour, screen

        var image: NSImage {
            NSImage(size: NSSize(width: 520, height: 390), flipped: false) { r in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                draw(ctx, r)
                return true
            }
        }

        private func fill(_ ctx: CGContext, _ colors: [UInt32], _ r: CGRect) {
            gradient(colors.map { rgb($0) }, from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY), in: ctx)
        }

        private func ridge(_ ctx: CGContext, _ r: CGRect, _ ys: [CGFloat], _ color: UInt32) {
            ctx.move(to: CGPoint(x: 0, y: 0))
            for (i, y) in ys.enumerated() { ctx.addLine(to: CGPoint(x: r.width * CGFloat(i) / CGFloat(ys.count - 1), y: y)) }
            ctx.addLine(to: CGPoint(x: r.width, y: 0))
            ctx.closePath()
            ctx.setFillColor(rgb(color).cgColor)
            ctx.fillPath()
        }

        func draw(_ ctx: CGContext, _ r: CGRect) {
            switch self {
            case .sunset:
                fill(ctx, [0x3B2A7A, 0xC0457A, 0xF59E57, 0xFCD9A0], r)
                ctx.setFillColor(rgb(0xFFF1C9).cgColor)
                ctx.fillEllipse(in: CGRect(x: 300, y: 120, width: 90, height: 90))
                ridge(ctx, r, [150, 170, 200, 186, 170, 150, 130], 0x5B2E5E)
                // A temple on the hill.
                ctx.setFillColor(rgb(0x3A1D40).cgColor)
                ctx.fill(CGRect(x: 160, y: 196, width: 150, height: 12))
                for i in 0..<7 { ctx.fill(CGRect(x: 166 + CGFloat(i) * 21, y: 208, width: 9, height: 44)) }
                ctx.move(to: CGPoint(x: 156, y: 252)); ctx.addLine(to: CGPoint(x: 314, y: 252)); ctx.addLine(to: CGPoint(x: 235, y: 280))
                ctx.fillPath()
                ridge(ctx, r, [90, 110, 100, 80, 96, 120, 100], 0x2B1533)
            case .sea:
                fill(ctx, [0x5BB4F0, 0xBFE6FB], CGRect(x: 0, y: 160, width: r.width, height: r.height - 160))
                ctx.setFillColor(rgb(0x1E6FB8).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: r.width, height: 175))
                for (x, y, w, h) in [(30.0, 140.0, 80.0, 70.0), (100, 160, 70, 80), (170, 130, 90, 60), (250, 150, 60, 90), (300, 120, 100, 70)] {
                    ctx.setFillColor(rgb(0xF8FAFC).cgColor)
                    ctx.fill(CGRect(x: x, y: y, width: w, height: h))
                    ctx.setFillColor(rgb(0x94A3B8, 0.5).cgColor)
                    ctx.fill(CGRect(x: x + w * 0.3, y: y + h * 0.3, width: w * 0.18, height: h * 0.28))
                }
                ctx.setFillColor(rgb(0x2563EB).cgColor)
                ctx.fillEllipse(in: CGRect(x: 268, y: 236, width: 46, height: 46))
                ctx.fill(CGRect(x: 268, y: 236, width: 46, height: 22))
                ctx.setFillColor(rgb(0xD6C7A8).cgColor)
                ctx.fill(CGRect(x: 0, y: 100, width: r.width, height: 40))
            case .mountains:
                fill(ctx, [0x7DB7E8, 0xD8ECFA], r)
                ridge(ctx, r, [140, 260, 200, 310, 220, 280, 150], 0x7A8AA6)
                ridge(ctx, r, [100, 150, 210, 160, 190, 130, 110], 0x4E7A55)
                ridge(ctx, r, [60, 80, 70, 95, 70, 60, 75], 0x2F5A37)
            case .harbour:
                fill(ctx, [0xF4C9A0, 0xF8E6CF], r)
                ctx.setFillColor(rgb(0x2E5E8A).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: r.width, height: 150))
                for i in 0..<4 {
                    let x = 60 + CGFloat(i) * 110
                    ctx.setFillColor(rgb([0xE11D48, 0xF59E0B, 0x10B981, 0x6366F1][i]).cgColor)
                    ctx.fill(CGRect(x: x, y: 120, width: 70, height: 26))
                    ctx.setFillColor(rgb(0xFFFFFF).cgColor)
                    ctx.fill(CGRect(x: x + 32, y: 146, width: 4, height: 80))
                }
            case .screen:
                fill(ctx, [0x6366F1, 0xA855F7], r)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
                ctx.addPath(roundedRect(CGRect(x: 60, y: 60, width: 400, height: 270), 14))
                ctx.fillPath()
                ctx.setFillColor(rgb(0xE5E7EB).cgColor)
                ctx.fill(CGRect(x: 60, y: 300, width: 400, height: 30))
                for i in 0..<5 { ctx.fill(CGRect(x: 90, y: 250 - CGFloat(i) * 36, width: CGFloat([300, 240, 280, 200, 260][i]), height: 14)) }
            }
        }
    }
}

extension ScrubModel {
    static var demo: ScrubModel { Demo.model }
}
