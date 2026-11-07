import AppKit
import Foundation
import SwiftUI

/// `Blend --selftest`: checks colour maths, CSS and SwiftUI output, editing and rendering.
@MainActor
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    private static func check(_ ok: Bool, _ what: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(what)")
        }
    }

    private static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-4) -> Bool { abs(a - b) <= tol }

    static func run() -> Int32 {
        oklab()
        hex()
        css()
        swiftUI()
        geometry()
        editing()
        random()
        rendering()
        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }

    private static func oklab() {
        let white = OKLab(RGBA(r: 1, g: 1, b: 1))
        check(near(white.l, 1, 1e-3) && near(white.a, 0, 1e-3) && near(white.b, 0, 1e-3), "OKLab of white is L 1, a 0, b 0")
        let red = OKLab(RGBA(r: 1, g: 0, b: 0))
        check(near(red.l, 0.62796, 1e-4) && near(red.a, 0.22486, 1e-4) && near(red.b, 0.12585, 1e-4),
              "OKLab of sRGB red matches the reference (0.628, 0.225, 0.126), got \(red)")
        let blue = OKLab(RGBA(r: 0, g: 0, b: 1))
        check(near(blue.l, 0.45201, 1e-4) && near(blue.a, -0.03246, 1e-4) && near(blue.b, -0.31153, 1e-4),
              "OKLab of sRGB blue matches the reference, got \(blue)")
        check(near(OKLab(RGBA(r: 0, g: 0, b: 0)).l, 0), "OKLab of black is L 0")
        let samples = [RGBA(0xFF8FB1), RGBA(0x7A6CFF), RGBA(0x12A04C), RGBA(0x808080), RGBA(0x01FE77)]
        let roundTrip = samples.allSatisfy { c in
            let back = OKLab(c).rgb()
            return near(back.r, c.r, 1e-6) && near(back.g, c.g, 1e-6) && near(back.b, c.b, 1e-6)
        }
        check(roundTrip, "sRGB to OKLab and back is lossless")
        let mid = mix(RGBA(r: 0, g: 0, b: 0), RGBA(r: 1, g: 1, b: 1), 0.5, in: .oklab)
        check(near(OKLab(mid).l, 0.5, 1e-4), "OKLab midpoint of black and white has lightness 0.5")
        check(RGBA(r: mid.r, g: mid.g, b: mid.b).hex == "#636363", "OKLab grey midpoint is #636363, got \(mid.hex)")
        check(mix(RGBA(r: 0, g: 0, b: 0), RGBA(r: 1, g: 1, b: 1), 0.5, in: .srgb).hex == "#808080", "sRGB midpoint is #808080")
        let fade = mix(RGBA(r: 1, g: 1, b: 1, a: 0), RGBA(r: 1, g: 0, b: 0), 0.5, in: .srgb)
        check(near(fade.r, 1) && near(fade.g, 0) && near(fade.a, 0.5), "transparent stops mix with premultiplied alpha")
        let wild = OKLab.lch(0.7, 0.4, 140)
        check([wild.r, wild.g, wild.b].allSatisfy { $0 >= 0 && $0 <= 1 }, "OKLCH outside sRGB is brought into gamut")
    }

    private static func hex() {
        check(RGBA(hex: "#ff8fb1")?.hex == "#FF8FB1", "parses and prints six digit hex")
        check(RGBA(hex: "abc")?.hex == "#AABBCC", "expands three digit hex")
        check(RGBA(hex: "#7A6CFF80")?.hex == "#7A6CFF80", "keeps alpha in eight digit hex")
        check(RGBA(hex: "#12345") == nil && RGBA(hex: "#GGGGGG") == nil, "rejects malformed hex")
    }

    private static func css() {
        let simple = BlendGradient(name: "T", angle: 90, interpolation: .srgb, colors: [0xFF0000, 0x0000FF])
        check(Export.css(simple) == "background: linear-gradient(\n  90deg,\n  #FF0000 0%,\n  #0000FF 100%\n);",
              "linear CSS, got \(Export.css(simple))")
        let smooth = BlendGradient(name: "T", angle: -45, colors: [0xFF8FB1, 0xC88BFF, 0x7A6CFF])
        check(Export.css(smooth) == "background: linear-gradient(\n  315deg in oklab,\n  #FF8FB1 0%,\n  #C88BFF 50%,\n  #7A6CFF 100%\n);",
              "OKLab linear CSS with a normalised angle, got \(Export.css(smooth))")
        var thirds = BlendGradient(name: "T", angle: 0, interpolation: .srgb, colors: [0x000000, 0x777777, 0xFFFFFF])
        thirds.stops[1].location = 1.0 / 3
        check(Export.css(thirds).contains("#777777 33.33%"), "stop positions keep two decimals")
        let radial = BlendGradient(name: "T", kind: .radial, interpolation: .srgb, colors: [0xFFFFFF, 0x000000])
        check(Export.css(radial) == "background: radial-gradient(\n  #FFFFFF 0%,\n  #000000 100%\n);", "centered radial CSS uses the defaults")
        let offset = BlendGradient(name: "T", kind: .radial, center: (0.3, 0.25), colors: [0xFFFFFF, 0x000000])
        check(Export.css(offset) == "background: radial-gradient(\n  ellipse 102.59% 102.59% at 30% 25% in oklab,\n  #FFFFFF 0%,\n  #000000 100%\n);",
              "off-center radial CSS reaches the farthest corner, got \(Export.css(offset))")
        let conic = BlendGradient(name: "T", kind: .conic, angle: 45, colors: [0xFF0000, 0x00FF00, 0xFF0000])
        check(Export.css(conic) == "background: conic-gradient(\n  from 45deg in oklab,\n  #FF0000 0%,\n  #00FF00 50%,\n  #FF0000 100%\n);",
              "conic CSS, got \(Export.css(conic))")
        let moved = BlendGradient(name: "T", kind: .conic, angle: 0, center: (0.25, 0.75), interpolation: .srgb, colors: [0xFF0000, 0x0000FF])
        check(Export.css(moved).hasPrefix("background: conic-gradient(\n  from 0deg at 25% 75%,\n"), "conic CSS with a center")
        check(Export.number(33.3333) == "33.33" && Export.number(50) == "50" && Export.number(12.5) == "12.5" && Export.number(-0.001) == "0",
              "number formatting trims zeros")
        check(Export.degrees(-90) == 270 && Export.degrees(450) == 90, "angles normalise to 0..<360")
    }

    private static func swiftUI() {
        let linear = BlendGradient(name: "T", angle: 90, interpolation: .srgb, colors: [0xFF0000, 0x0000FF])
        let code = Export.swiftUI(linear)
        check(code.contains(".linearGradient(") && code.contains("startPoint: UnitPoint(x: 0.000, y: 0.500)")
              && code.contains("endPoint: UnitPoint(x: 1.000, y: 0.500)"), "SwiftUI linear points for 90 degrees")
        check(code.contains(".init(color: Color(red: 1.000, green: 0.000, blue: 0.000), location: 0.000),"), "SwiftUI stop line")
        check(!code.contains("perceptual"), "sRGB SwiftUI code has no perceptual colour space")
        let conic = BlendGradient(name: "T", kind: .conic, angle: 0, colors: [0xFF0000, 0x0000FF])
        let conicCode = Export.swiftUI(conic)
        check(conicCode.contains(".conicGradient(") && conicCode.contains("angle: .degrees(270)") && conicCode.contains(".colorSpace(.perceptual)"),
              "SwiftUI conic starts at the top and blends perceptually")
        let radial = BlendGradient(name: "T", kind: .radial, colors: [0xFFFFFF, 0x000000])
        check(Export.swiftUI(radial).contains("endRadiusFraction: 0.707"), "SwiftUI radial reaches the corners")
        let hex = BlendGradient(name: "T", colors: [0x7A6CFF, 0xFF8FB1])
        check(Export.code(hex, format: .hex) == "#7A6CFF\n#FF8FB1", "hex list in stop order")
    }

    private static func geometry() {
        func pts(_ a: Double, _ w: CGFloat = 1, _ h: CGFloat = 1) -> (UnitPoint, UnitPoint) {
            BlendGradient(name: "T", angle: a, colors: [0, 0xFFFFFF]).linearPoints(size: CGSize(width: w, height: h))
        }
        let (s1, e1) = pts(135)
        check(near(s1.x, 0) && near(s1.y, 0) && near(e1.x, 1) && near(e1.y, 1), "135 degrees runs corner to corner on a square")
        let (s2, e2) = pts(180)
        check(near(s2.x, 0.5) && near(s2.y, 0) && near(e2.y, 1), "180 degrees runs top to bottom")
        // CSS: on a 200 x 100 box at 45 degrees the line is |200 sin| + |100 cos| = 212.13 long.
        let (s3, e3) = pts(45, 200, 100)
        let length = hypot((e3.x - s3.x) * 200, (e3.y - s3.y) * 100)
        check(near(length, 212.132, 1e-2), "linear line length matches CSS on a wide box, got \(length)")
        let g = BlendGradient(name: "T", interpolation: .srgb, colors: [0x000000, 0xFFFFFF], locations: [0.2, 0.8])
        check(g.color(at: 0).hex == "#000000" && g.color(at: 1).hex == "#FFFFFF" && near(g.color(at: 0.5).r, 0.5, 1e-6),
              "colour lookup clamps outside the stops and mixes between them")
        let dense = BlendGradient(name: "T", colors: [0xFF0000, 0x00FF00, 0x0000FF]).renderStops(samples: 24)
        check(dense.count == 49 && dense.first?.1 == 0 && dense.last?.1 == 1, "OKLab renders as dense sRGB stops")
    }

    private static func editing() {
        let m = BlendModel(persists: false)
        m.select(.preset(Presets.all[3].id))
        let start = m.current
        m.addStop(at: 0.5)
        let added = m.selectedStop
        check(m.current.stops.count == start.stops.count + 1, "clicking the bar adds a stop")
        check(m.selectedStopValue?.color == start.color(at: 0.5), "a new stop takes the colour already there")
        m.undo()
        check(m.current == start, "undo removes the new stop")
        m.redo()
        check(m.current.stops.count == start.stops.count + 1, "redo puts it back")
        m.selectedStop = added
        if let id = m.selectedStop {
            m.setStop(id, location: 0.4)
            m.setStop(id, location: 0.3)
            m.setStop(id, location: 0.2)
            m.undo()
            check(m.selectedStopValue.map { near($0.location, 0.5) } == true, "a drag is one undo step")
        }
        m.deleteSelectedStop()
        m.deleteSelectedStop()
        check(m.current.stops.count == 2, "a gradient keeps at least two stops")
        m.reverse()
        check(m.current.sortedStops.first?.color == start.sortedStops.last?.color, "reverse flips the stops")
        m.saveToLibrary()
        check(m.library.count == 1 && m.isInLibrary, "save copies a preset into the library")
        m.rename("Hero")
        check(m.library.first?.name == "Hero", "edits to a library gradient write back")
        m.duplicate(m.current.id)
        check(m.library.count == 2 && m.library[1].name == "Hero copy", "duplicate names the copy")
        m.delete(m.current.id)
        check(m.library.count == 1 && m.current.id == m.library[0].id, "delete selects a neighbour")
        let data = try? JSONEncoder().encode(m.library)
        let back = data.flatMap { try? JSONDecoder().decode([BlendGradient].self, from: $0) }
        check(back == m.library, "the library survives a JSON round trip")
    }

    private static func random() {
        var seed: UInt64 = 42
        var dice = GradientDice(next: {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        })
        var ok = true
        for _ in 0..<200 {
            let g = dice.roll()
            let inGamut = g.stops.allSatisfy { [$0.color.r, $0.color.g, $0.color.b].allSatisfy { $0 >= 0 && $0 <= 1 } }
            let ordered = g.sortedStops.first?.location == 0 && g.sortedStops.last?.location == 1
            if g.stops.count < 2 || !inGamut || !ordered { ok = false }
        }
        check(ok, "random gradients have two or more in-gamut stops spanning 0 to 100%")
    }

    private static func pixel(_ data: Data?, _ x: Int, _ y: Int) -> RGBA? {
        guard let data, let rep = NSBitmapImageRep(data: data), let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }

    private static func rendering() {
        let linear = BlendGradient(name: "T", angle: 90, interpolation: .srgb, colors: [0xFF0000, 0x0000FF])
        let png = Export.png(linear, width: 64, height: 8)
        check(png.flatMap { NSBitmapImageRep(data: $0) }.map { $0.pixelsWide == 64 && $0.pixelsHigh == 8 } == true,
              "PNG export has the requested pixel size")
        let left = pixel(png, 0, 4), right = pixel(png, 63, 4)
        check((left?.r ?? 0) > 0.9 && (left?.b ?? 1) < 0.1 && (right?.b ?? 0) > 0.9 && (right?.r ?? 1) < 0.1,
              "PNG runs left red to right blue at 90 degrees")
        let radial = BlendGradient(name: "T", kind: .radial, interpolation: .srgb, colors: [0x000000, 0xFFFFFF])
        let r = Export.png(radial, width: 100, height: 50)
        check((pixel(r, 50, 25)?.r ?? 1) < 0.05 && (pixel(r, 0, 0)?.r ?? 0) > 0.95,
              "PNG radial is dark at the center and reaches white at the corner")
        let conic = BlendGradient(name: "T", kind: .conic, angle: 0, interpolation: .srgb, colors: [0xFF0000, 0x0000FF])
        let c = Export.png(conic, width: 100, height: 100)
        let after = pixel(c, 54, 2), before = pixel(c, 46, 2)
        check((after?.r ?? 0) > 0.85 && (before?.b ?? 0) > 0.85, "PNG conic starts at the top and turns clockwise")
    }
}
