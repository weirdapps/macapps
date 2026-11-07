import AppKit
import Foundation

/// `Hues --selftest`: checks the colour maths, the extractor, the exporters and history persistence.
enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0

    static func check(_ ok: Bool, _ name: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(name)") }
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double = 0.01) -> Bool { abs(a - b) <= tol }

    /// A test image made of solid blocks: each colour covers `parts` columns out of the total.
    static func blocks(_ colors: [(UInt32, Int)], height: Int = 40) -> CGImage {
        let width = colors.reduce(0) { $0 + $1.1 }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var x = 0
        for (hex, w) in colors {
            let c = RGB(hex)
            ctx.setFillColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: w, height: height))
            x += w
        }
        return ctx.makeImage()!
    }

    static func run() -> Int32 {
        // Hex.
        check(RGB(0xE07A3F).hex == "#E07A3F", "hex formatting")
        check(RGB(hex: "#e07a3f") == RGB(0xE07A3F), "hex parsing lower case")
        check(RGB(hex: "fa0")?.hex == "#FFAA00", "three digit hex")
        check(RGB(hex: "#12345") == nil && RGB(hex: "zzzzzz") == nil, "bad hex rejected")

        // Lab.
        let white = ColorMath.lab(RGB(r: 1, g: 1, b: 1))
        check(near(white.l, 100, 0.01) && near(white.a, 0, 0.01) && near(white.b, 0, 0.01), "white is L100 a0 b0")
        let red = ColorMath.lab(RGB(r: 1, g: 0, b: 0))
        check(near(red.l, 53.24, 0.05) && near(red.a, 80.09, 0.1) && near(red.b, 67.20, 0.1), "red in Lab")
        let black = ColorMath.lab(RGB(r: 0, g: 0, b: 0))
        check(near(black.l, 0, 0.001), "black is L0")
        var roundTrip = true
        for hex: UInt32 in [0xE07A3F, 0x2E1F55, 0x3DBE8B, 0x808080, 0x0A0B0C, 0xFFFFFF] {
            if ColorMath.rgb(ColorMath.lab(RGB(hex))).hex != RGB(hex).hex { roundTrip = false; print("  round trip \(RGB(hex).hex)") }
        }
        check(roundTrip, "sRGB to Lab and back")

        // HSL.
        let hsl = ColorMath.hsl(RGB(0xE07A3F))
        check(near(hsl.h, 22, 0.5) && near(hsl.s, 0.72, 0.01) && near(hsl.l, 0.563, 0.01), "HSL of #E07A3F")
        check(ColorMath.hslText(RGB(0x00FF00)) == "120\u{00B0}, 100%, 50%", "HSL text of green")
        check(ColorMath.hsl(RGB(0x808080)).s == 0, "grey has no saturation")
        check(ColorMath.rgbText(RGB(0x0A80FF)) == "10, 128, 255", "RGB text")

        // Extraction on known blocks: 50% red, 30% blue, 20% green.
        guard let bmp = Bitmap(blocks([(0xD03030, 50), (0x2050C0, 30), (0x30A050, 20)]), maxSide: 220) else {
            check(false, "bitmap")
            return summary()
        }
        let e = Extractor.extract(bmp, count: 3)
        check(e.swatches.count == 3, "three swatches from three colours")
        check(e.swatches.map(\.color.hex) == ["#D03030", "#2050C0", "#30A050"], "colours sorted by share: \(e.swatches.map(\.color.hex))")
        let shares = e.swatches.compactMap(\.share)
        check(shares.count == 3 && near(shares[0], 0.5) && near(shares[1], 0.3) && near(shares[2], 0.2), "shares 50/30/20: \(shares)")
        check(near(shares.reduce(0, +), 1, 1e-9), "shares sum to one")
        check(Extractor.extract(bmp, count: 10).swatches.count == 3, "never more swatches than distinct colours")
        check(e.assignment.count == bmp.width * bmp.height, "one assignment per pixel")
        check(e.assignment.filter { $0 == 0 }.count == bmp.width * bmp.height / 2, "assignment matches the red half")

        // Determinism and the requested count on a busy image.
        let scene = Bitmap(DemoScene.sunset.image(width: 400, height: 273), maxSide: 220)!
        let a = Extractor.extract(scene, count: 8), b = Extractor.extract(scene, count: 8)
        check(a.swatches.map(\.color) == b.swatches.map(\.color) && a.swatches.map(\.share) == b.swatches.map(\.share), "deterministic seeding")
        check(a.swatches.count == 8, "eight colours from a scene")
        let sorted = a.swatches.compactMap(\.share)
        check(sorted == sorted.sorted(by: >), "sorted by share")
        check(Extractor.extract(scene, count: 12).swatches.count == 12, "twelve colours from a scene")
        check(Extractor.mask(a, index: 0)?.width == scene.width, "hover mask size")
        let big = Bitmap(DemoScene.sunset.image(width: 400, height: 273), maxSide: 400)!
        let mapped = Extractor.assign(big, to: a)
        check(mapped.assignment.count == 400 * 273 && !mapped.assignment.contains(-1), "mask map covers a larger bitmap")
        let recount = (0..<a.swatches.count).map { i in Double(mapped.assignment.filter { Int($0) == i }.count) / Double(400 * 273) }
        check(zip(recount, a.swatches.compactMap(\.share)).allSatisfy { abs($0 - $1) < 0.05 }, "mask map agrees with shares")
        let blocksMap = Extractor.assign(bmp, to: e)
        check(blocksMap.assignment == e.assignment, "assign reproduces the sample assignment")

        // Transparent pixels are ignored.
        let clear = CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        clear.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        clear.fill(CGRect(x: 0, y: 0, width: 10, height: 20))
        let half = Extractor.extract(Bitmap(clear.makeImage()!, maxSide: 220)!, count: 5)
        check(half.swatches.count == 1 && half.swatches[0].color.hex == "#0000FF" && near(half.swatches[0].share ?? 0, 1),
              "transparent pixels skipped")
        check(half.assignment.filter { $0 == -1 }.count == 200, "transparent pixels unassigned")

        // Export.
        var swatches = e.swatches
        swatches.append(Swatch(color: RGB(0xFFFFFF), share: nil, point: CGPoint(x: 0.5, y: 0.5)))
        let css = Exporter.css(swatches, name: "Sunset over the bay.jpg")
        check(css.hasPrefix(":root {\n") && css.contains("--sunset-over-the-bay-1: #d03030; /* 50% */"), "CSS variables")
        check(css.contains("--sunset-over-the-bay-4: #ffffff; /* picked */"), "CSS picked colour")
        let swift = Exporter.swift(swatches, name: "2024 trip.png")
        check(swift.contains("enum Palette2024TripPalette {") && swift.contains("static let color1 = Color(red: 0.816, green: 0.188, blue: 0.188) // #D03030, 50%"),
              "Swift code")
        check(swift.contains("static let all = [color1, color2, color3, color4]"), "Swift all array")
        let json = Exporter.json(swatches, name: "Pasted image")
        let decoded = try? JSONDecoder().decode(Exporter.JSONPalette.self, from: Data(json.utf8))
        check(decoded == Exporter.jsonPalette(swatches, name: "Pasted image"), "JSON round trip")
        check(decoded?.colors.first?.rgb == [208, 48, 48] && decoded?.colors.last?.picked == true, "JSON values")
        let strip = Exporter.strip(swatches)
        check(strip?.pixelsWide == 240 * 4 && strip?.pixelsHigh == 320, "PNG strip size")
        if let strip {
            let c = strip.colorAt(x: 120, y: 40)?.usingColorSpace(.sRGB)
            check(c.map { RGB(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent)).hex } == "#D03030", "PNG strip colour")
        }
        check(Exporter.data(.png, [], name: "x") == nil, "no strip for an empty palette")

        // History persistence.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hues-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(directory: dir)
        let item = SavedPalette(id: UUID(), name: "Test.png", date: Date(timeIntervalSince1970: 1_800_000_000), count: 3, swatches: swatches)
        store.save([item])
        check(store.load() == [item], "history round trip")
        store.saveImage(bmp.image, id: item.id)
        check(store.loadImage(item.id)?.width == bmp.width, "history image round trip")
        store.removeImage(item.id)
        check(store.loadImage(item.id) == nil, "history image removed")
        var items: [SavedPalette] = []
        var dropped: [UUID] = []
        for i in 0..<(HistoryStore.limit + 3) {
            dropped += HistoryStore.upsert(SavedPalette(id: UUID(), name: "\(i)", date: Date(), count: 5, swatches: []), into: &items)
        }
        check(items.count == HistoryStore.limit && dropped.count == 3 && items.first?.name == "\(HistoryStore.limit + 2)", "history limit")
        var again = items
        _ = HistoryStore.upsert(items[5], into: &again)
        check(again.count == items.count && again.first?.id == items[5].id, "upsert moves to the top")

        return summary()
    }

    static func summary() -> Int32 {
        print("\(passes) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
