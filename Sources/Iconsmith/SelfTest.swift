import AppKit
import ImageIO

/// `Iconsmith --selftest`: checks the crop maths, the renderer's pixels and every export format on temporary files.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    private static func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.5) -> Bool { abs(a - b) <= tolerance }

    /// Reads one pixel as RGBA bytes, (x, y) from the top left.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 4)
        data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: IconRenderer.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return data
    }

    private static func solid(_ w: Int, _ h: Int, _ color: CGColor) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: IconRenderer.colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private static func pixelSize(_ url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    static func run() -> Int32 {
        let wide = CGSize(width: 2000, height: 1000)
        var o = IconOptions()

        // Crop maths.
        var r = Geometry.cropRect(imageSize: wide, options: o)
        check(r == CGRect(x: 500, y: 0, width: 1000, height: 1000), "landscape crops to a centred square")
        o.center = CGPoint(x: 0, y: 0.5)
        r = Geometry.cropRect(imageSize: wide, options: o)
        check(close(r.minX, 0) && close(r.width, 1000), "crop clamps to the left edge")
        o.center = CGPoint(x: 1, y: 0.5)
        check(close(Geometry.cropRect(imageSize: wide, options: o).maxX, 2000), "crop clamps to the right edge")
        o = IconOptions()
        o.zoom = 2
        check(close(Geometry.cropRect(imageSize: wide, options: o).width, 500), "zoom 2 halves the crop")
        o.zoom = 100
        check(close(Geometry.cropRect(imageSize: wide, options: o).width, 1000 / 6), "zoom is capped at 6")
        o = IconOptions()
        o.framing = .fit
        r = Geometry.cropRect(imageSize: wide, options: o)
        check(r == CGRect(x: 0, y: -500, width: 2000, height: 2000), "fit letterboxes the whole image")
        o = IconOptions()
        o.center = CGPoint(x: 0.5, y: 0.95)
        let tall = CGSize(width: 600, height: 1800)
        check(close(Geometry.cropRect(imageSize: tall, options: o).maxY, 1800), "portrait crop clamps to the bottom")
        let clamped = Geometry.clampedCenter(imageSize: tall, options: o)
        check(close(clamped.y, (1800 - 300) / 1800, 0.001) && close(clamped.x, 0.5, 0.001), "clamped centre stays inside")

        // Grid.
        o = IconOptions()
        check(Geometry.contentRect(o) == Geometry.tileRect, "no padding fills the 824 tile")
        o.padding = 0.1
        check(close(Geometry.contentRect(o).width, 824 * 0.8, 0.01), "10% padding insets each side")
        o.shape = .fullBleed
        o.padding = 0
        check(Geometry.contentRect(o).width == 1024, "full bleed uses the whole canvas")

        // Rendering.
        let red = solid(800, 600, CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        o = IconOptions()
        o.shadow = false
        let tile = IconRenderer.render(red, options: o, size: 1024)!
        check(tile.width == 1024 && tile.height == 1024, "render is 1024 square")
        check(pixel(tile, 4, 4)[3] == 0, "tile corners are transparent")
        check(pixel(tile, 120, 120)[3] == 0, "rounded corner is cut away")
        // A circular arc would already be a straight, opaque edge here; Apple's continuous corner is still curving.
        check(pixel(tile, 275, 101)[3] < 128 && pixel(tile, 512, 101)[3] > 200, "tile corners are continuous, not circular")
        let mid = pixel(tile, 512, 512)
        check(mid[3] == 255 && mid[0] > 250 && mid[1] < 5, "tile centre shows the image")
        check(pixel(tile, 512, 960)[3] == 0, "no shadow below the tile when off")
        o.shadow = true
        let shadowed = IconRenderer.render(red, options: o, size: 1024)!
        check(pixel(shadowed, 512, 935)[3] > 20, "drop shadow falls below the tile")
        check(pixel(shadowed, 4, 4)[3] < 3, "shadow does not reach the canvas corner")
        var bleed = IconOptions()
        bleed.shape = .fullBleed
        check(pixel(IconRenderer.render(red, options: bleed, size: 256)!, 0, 0)[3] == 255, "full bleed fills the corners")

        let clear = solid(400, 400, CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0))
        o = IconOptions()
        o.shadow = false
        check(pixel(IconRenderer.render(clear, options: o, size: 512)!, 256, 256)[3] == 0, "transparent image stays transparent")
        o.fillBackground = true
        o.background = RGBA(r: 0, g: 0, b: 1, a: 1)
        let filled = pixel(IconRenderer.render(clear, options: o, size: 512)!, 256, 256)
        check(filled[2] > 250 && filled[3] == 255 && filled[0] < 5, "background fills transparent areas")
        o = IconOptions()
        o.shadow = false
        o.padding = 0.2
        let padded = IconRenderer.render(red, options: o, size: 1024)!
        check(pixel(padded, 512, 130)[3] == 0, "padding leaves the tile edge empty without a fill")
        check(pixel(padded, 512, 512)[0] > 250, "padded artwork is still centred")

        let all = IconRenderer.renderAll(red, options: IconOptions())
        check(Geometry.sizes.allSatisfy { all[$0]?.width == $0 }, "renderAll makes every size")
        let small = pixel(all[16]!, 8, 8)
        check(small[0] > 240 && small[3] > 240, "16 px keeps the colour")

        // Export formats.
        let slots = IconExporter.slots
        check(slots.count == 10 && Set(slots.map(\.filename)).count == 10, "iconset has 10 unique files")
        check(slots.contains(Slot(points: 512, scale: 2)) && slots.first?.filename == "icon_16x16.png", "iconset names follow iconutil")
        check(Set(slots.map(\.pixels)).isSubset(of: Set(Geometry.sizes)), "every slot has a rendered size")
        if let json = try? JSONSerialization.jsonObject(with: IconExporter.contentsJSON()) as? [String: Any],
           let images = json["images"] as? [[String: String]] {
            check(images.count == 10 && images.allSatisfy { $0["idiom"] == "mac" }, "Contents.json lists 10 mac images")
            check(images.contains { $0["size"] == "512x512" && $0["scale"] == "2x" && $0["filename"] == "icon_512x512@2x.png" },
                  "Contents.json has the 1024 slot")
        } else {
            check(false, "Contents.json parses")
        }
        check(ExportKind.icns.defaultName(base: "Sunset") == "Sunset.icns", "icns default name")
        check(ExportKind.appIconSet.defaultName(base: "Sunset") == "AppIcon.appiconset", "Xcode set is named AppIcon")

        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("Iconsmith-selftest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        let iconset = temp.appendingPathComponent("Test.iconset")
        do {
            try IconExporter.export(.iconset, image: red, options: IconOptions(), to: iconset)
            let files = (try? fm.contentsOfDirectory(atPath: iconset.path)) ?? []
            check(files.count == 10, "iconset folder holds 10 PNGs")
            let big = pixelSize(iconset.appendingPathComponent("icon_512x512@2x.png"))
            let tiny = pixelSize(iconset.appendingPathComponent("icon_16x16.png"))
            check(big?.0 == 1024 && tiny?.0 == 16, "iconset PNGs have the right pixel sizes")
        } catch {
            check(false, "iconset export: \(error.localizedDescription)")
        }
        // Exporting again over the same name replaces it.
        check((try? IconExporter.export(.iconset, image: red, options: IconOptions(), to: iconset)) != nil, "export replaces an existing folder")

        let appIcon = temp.appendingPathComponent("AppIcon.appiconset")
        do {
            try IconExporter.export(.appIconSet, image: red, options: IconOptions(), to: appIcon)
            check(fm.fileExists(atPath: appIcon.appendingPathComponent("Contents.json").path), "app icon set has Contents.json")
            check(((try? fm.contentsOfDirectory(atPath: appIcon.path)) ?? []).count == 11, "app icon set has 10 PNGs and the JSON")
        } catch {
            check(false, "app icon set export: \(error.localizedDescription)")
        }

        let icns = temp.appendingPathComponent("Test.icns")
        do {
            try IconExporter.export(.icns, image: red, options: IconOptions(), to: icns)
            let data = (try? Data(contentsOf: icns)) ?? Data()
            check(data.prefix(4) == Data("icns".utf8), "icns file starts with the icns magic")
            if let src = CGImageSourceCreateWithURL(icns as CFURL, nil) {
                check(CGImageSourceGetCount(src) >= 5, "icns holds several sizes")
            } else {
                check(false, "icns reads back")
            }
        } catch {
            check(false, "icns export: \(error.localizedDescription)")
        }
        let fallback = temp.appendingPathComponent("Fallback.icns")
        check((try? IconExporter.writeICNSWithImageIO(all, to: fallback)) != nil && fm.fileExists(atPath: fallback.path), "ImageIO icns fallback writes")
        check(CGImageSourceCreateWithURL(fallback as CFURL, nil).map(CGImageSourceGetCount) == 10, "ImageIO icns keeps all 10 slots, 1024 included")
        // Reopening an .icns edits its largest picture, not the 16 px one stored first.
        check(ImageLoader.load(icns)?.width == 1024, "an .icns opens at 1024 px")
        check(ImageLoader.load(fallback)?.width == 1024, "an ImageIO .icns opens at 1024 px")
        check((try? IconExporter.export(.icns, image: red, options: IconOptions(), to: icns)) != nil && pixelSize(icns) != nil,
              "export replaces an existing .icns")

        // Re-exporting a folder replaces it whole, leaving nothing stale behind.
        try? Data("old".utf8).write(to: iconset.appendingPathComponent("stale.txt"))
        try? IconExporter.export(.iconset, image: red, options: IconOptions(), to: iconset)
        let after = (try? fm.contentsOfDirectory(atPath: iconset.path)) ?? []
        check(after.count == 10 && !after.contains("stale.txt"), "re-export leaves no stale files")
        let leftovers = ((try? fm.contentsOfDirectory(atPath: temp.path)) ?? []).filter { $0.hasPrefix("Iconsmith-out") }
        check(leftovers.isEmpty, "export cleans up its staging folder")

        // Loading.
        let png = temp.appendingPathComponent("source.png")
        try? IconRenderer.pngData(solid(320, 200, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)))?.write(to: png)
        let loaded = ImageLoader.load(png)
        check(loaded?.width == 320 && loaded?.height == 200, "loads a PNG at its own size")
        let junk = temp.appendingPathComponent("junk.png")
        try? Data("not an image".utf8).write(to: junk)
        check(ImageLoader.load(junk) == nil, "rejects a file that is not an image")
        let big = ImageLoader.downsampled(solid(4000, 1000, CGColor(gray: 0.5, alpha: 1)), maxPixels: 2048)
        check(big.width == 2048 && big.height == 512, "preview keeps the aspect ratio")

        // Persistence and the model.
        var saved = IconOptions()
        saved.background = RGBA(r: 0.2, g: 0.4, b: 0.6, a: 1)
        saved.padding = 0.12
        let decoded = try? JSONDecoder().decode(IconOptions.self, from: JSONEncoder().encode(saved))
        check(decoded == saved, "options survive a JSON round trip")
        check(RGBA(RGBA(r: 0.25, g: 0.5, b: 0.75, a: 1).nsColor).b > 0.74, "colour converts through NSColor")

        let model = IconModel(persist: false)
        model.setImage(solid(1600, 1000, CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)), name: "Test")
        check(model.renders.count == 7, "model renders every preview size")
        model.update("Zoom") { $0.zoom = 2 }
        model.pan(from: CGPoint(x: 0.5, y: 0.5), translation: CGSize(width: 10_000, height: 0), canvasSide: 400)
        check(close(model.cropRect.minX, 0), "dragging far right stops at the image edge")
        model.update("Zoom") { $0.zoom = 0.1 }
        check(model.options.zoom == 1, "zoom never drops below 100%")
        check(!model.isLowResolution, "a large image is not flagged as soft")
        model.update("Zoom") { $0.zoom = 6 }
        check(model.isLowResolution, "a deep zoom is flagged as soft")
        check(IconModel.demo.renders[1024] != nil, "demo model draws")

        // Opening runs off the main thread and reports back.
        func waitForLoad(_ m: IconModel) {
            let deadline = Date().addingTimeInterval(10)
            while m.isLoading && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        let opener = IconModel(persist: false)
        opener.open(junk)
        check(opener.isLoading, "opening shows progress at once")
        waitForLoad(opener)
        check(!opener.isLoading && opener.errorMessage != nil && !opener.hasImage, "a bad file reports an error")
        opener.errorMessage = nil
        opener.open(png)
        waitForLoad(opener)
        check(opener.hasImage && opener.name == "source" && opener.sourceSize == CGSize(width: 320, height: 200), "a PNG opens in the background")
        let empty = temp.appendingPathComponent("empty.jpg")
        fm.createFile(atPath: empty.path, contents: Data())
        opener.open(empty)
        waitForLoad(opener)
        check(opener.errorMessage != nil && opener.name == "source", "an empty file is refused and keeps the open image")

        check(Theme.defaults === UserDefaults.standard, "the app reads the user's view settings outside the snapshot")

        print(failures == 0 ? "PASS: all \(checks) checks" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    private typealias Slot = IconExporter.Slot
}
