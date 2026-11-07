import AppKit
import Foundation

enum SelfTest {
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var failed = 0

    private static func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
    }

    private static func near(_ a: (UInt8, UInt8, UInt8), _ b: (Int, Int, Int), _ tol: Int = 1) -> Bool {
        abs(Int(a.0) - b.0) <= tol && abs(Int(a.1) - b.1) <= tol && abs(Int(a.2) - b.2) <= tol
    }

    static func run() -> Int32 {
        // Every Machado matrix keeps neutral colours neutral: each row sums to one.
        for (name, table) in [("protan", Machado.protan), ("deutan", Machado.deutan), ("tritan", Machado.tritan)] {
            check(table.count == 11, "\(name) table has 11 severities")
            check(table.allSatisfy { m in (0..<3).allSatisfy { abs(m.rowSum($0) - 1) < 0.0005 } }, "\(name) rows sum to 1")
            check(table[0] == .identity, "\(name) severity 0 is normal vision")
        }
        check((0..<3).allSatisfy { abs(Matrix3.luminance.rowSum($0) - 1) < 0.0001 }, "luminance rows sum to 1")

        // White stays white, black stays black, grey stays grey, in every mode and severity.
        for mode in Simulation.allCases {
            for severity in [0.1, 0.55, 1.0] {
                let m = mode.matrix(severity: severity)
                if !near(SRGB.simulate((255, 255, 255), m), (255, 255, 255)) { check(false, "\(mode) keeps white at \(severity)") }
                if !near(SRGB.simulate((0, 0, 0), m), (0, 0, 0), 0) { check(false, "\(mode) keeps black at \(severity)") }
                if !near(SRGB.simulate((128, 128, 128), m), (128, 128, 128)) { check(false, "\(mode) keeps grey at \(severity)") }
            }
        }
        check(true, "neutrals survive every mode")

        // Known colour transforms, worked out by hand from the published matrices.
        check(near(SRGB.simulate((255, 0, 0), Simulation.protanopia.matrix(severity: 1)), (109, 95, 0), 2),
              "protanopia turns red into a dark olive")
        let deutRed = SRGB.simulate((255, 0, 0), Simulation.deuteranopia.matrix(severity: 1))
        let deutGreen = SRGB.simulate((0, 255, 0), Simulation.deuteranopia.matrix(severity: 1))
        check((35...65).contains(hue(deutRed)) && (35...65).contains(hue(deutGreen)),
              "deuteranopia gives red and green the same yellowish hue")
        let tritBlue = SRGB.simulate((0, 0, 255), Simulation.tritanopia.matrix(severity: 1))
        check(tritBlue.1 > tritBlue.0 && (160...200).contains(hue(tritBlue)), "tritanopia turns blue teal")
        let grey = SRGB.simulate((0, 255, 0), Simulation.achromatopsia.matrix(severity: 1))
        check(grey.0 == grey.1 && grey.1 == grey.2 && abs(Int(grey.0) - 219) <= 1, "achromatopsia maps green to grey 219")

        // Severity interpolation.
        check(Simulation.protanomaly.matrix(severity: 1) == Simulation.protanopia.matrix(severity: 1), "full protanomaly is protanopia")
        check(Machado.matrix(Machado.deutan, severity: 0) == .identity, "severity 0 is identity")
        let mid = Machado.matrix(Machado.deutan, severity: 0.55)
        check(abs(mid.m[0] - (0.547494 + 0.498864) / 2) < 0.0001, "severity 0.55 is halfway between 0.5 and 0.6")
        let weak = SRGB.simulate((255, 0, 0), Simulation.deuteranomaly.matrix(severity: 0.3))
        let strong = SRGB.simulate((255, 0, 0), Simulation.deuteranomaly.matrix(severity: 0.9))
        check(weak.0 > strong.0 && weak.1 < strong.1, "stronger deuteranomaly moves red further toward yellow")

        // Transfer function.
        check((0..<256).allSatisfy { SRGB.byte(SRGB.toLinear[$0]) == UInt8($0) }, "sRGB lookup tables round trip every byte")
        check(abs(SRGB.encode(0.5) - 0.7354) < 0.0005, "linear 0.5 is sRGB 0.735")

        // Bitmaps.
        let bitmap = Bitmap(width: 2, height: 1, pixels: [255, 0, 0, 255, 0, 0, 255, 128])
        check(bitmap.simulated(.identity) == bitmap, "identity leaves the image untouched")
        let simulated = bitmap.simulated(Simulation.achromatopsia.matrix(severity: 1))
        check(simulated.pixel(1, 0).3 == 128, "alpha survives simulation")
        let back = bitmap.cgImage.flatMap { Bitmap($0) }
        check(back.map { $0.pixel(0, 0) == (255, 0, 0, 255) } == true, "bitmap round trips through CGImage")
        if let back { check(abs(Int(back.pixel(1, 0).2) - 255) <= 2 && back.pixel(1, 0).3 == 128, "translucent colour unpremultiplied") }
        let big = Bitmap(width: 300, height: 300, pixels: [UInt8](repeating: 200, count: 300 * 300 * 4))
        let bigOut = big.simulated(Simulation.protanopia.matrix(severity: 1))
        check(bigOut.pixels.count == big.pixels.count && abs(Int(bigOut.pixel(299, 299).0) - 200) <= 1, "parallel loop covers every pixel")

        // The sample design, scaling and the PNG export.
        let demo = Demo.image()
        check(demo.width == 1600 && demo.height == 1000, "sample design is 1600 by 1000")
        if let small = Bitmap(demo, maxSide: 400) {
            check(small.width == 400 && small.height == 250, "preview keeps the aspect ratio")
        } else {
            check(false, "sample design decodes")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sight-selftest-\(UUID().uuidString).png")
        if let image = bitmap.simulated(Simulation.achromatopsia.matrix(severity: 1)).cgImage {
            check(ImageFile.writePNG(image, to: url), "PNG writes")
            let read = ImageFile.load(url).flatMap { Bitmap($0) }
            check(read?.width == 2 && read.map { near(($0.pixel(0, 0).0, $0.pixel(0, 0).1, $0.pixel(0, 0).2), (127, 127, 127), 2) } == true,
                  "exported PNG reads back as grey")
            try? FileManager.default.removeItem(at: url)
        }

        // Modes and layout maths.
        check(Simulation.allCases.count == 7 && Set(Simulation.allCases.map(\.name)).count == 7, "seven distinct simulations")
        check(Simulation.allCases.filter(\.isAnomalous) == [.protanomaly, .deuteranomaly, .tritanomaly], "three modes take a severity")
        check(Simulation.achromatopsia.next(by: 1) == .protanopia && Simulation.protanopia.next(by: -1) == .achromatopsia,
              "next and previous wrap around")
        check(fitted(CGSize(width: 1600, height: 1000), in: CGSize(width: 800, height: 800)) == CGSize(width: 800, height: 500),
              "fitted keeps the aspect ratio")
        check(fitted(.zero, in: CGSize(width: 10, height: 10)) == .zero, "fitted handles an empty image")

        // Render bookkeeping: a severity change must not cancel the other modes of a freshly loaded image.
        var tokens = RenderTokens()
        let all = tokens.issue(Simulation.allCases)
        let anomalous = tokens.issue(Simulation.allCases.filter(\.isAnomalous))
        check(tokens.isCurrent(.protanopia, all) && tokens.isCurrent(.achromatopsia, all),
              "a severity change keeps the pending dichromacy renders")
        check(!tokens.isCurrent(.protanomaly, all) && tokens.isCurrent(.protanomaly, anomalous),
              "a severity change supersedes the old anomalous renders")
        let reload = tokens.issue(Simulation.allCases)
        check(Simulation.allCases.allSatisfy { !tokens.isCurrent($0, all) && !tokens.isCurrent($0, anomalous) && tokens.isCurrent($0, reload) },
              "a new image supersedes every older render")

        // Export names.
        check(exportFileName("Dashboard", .deuteranopia, severity: 0.6) == "Dashboard (Deuteranopia).png", "export name for a dichromacy")
        check(exportFileName("Login", .protanomaly, severity: 0.4) == "Login (Protanomaly 40%).png", "export name carries the severity")
        check(exportFileName("", .tritanopia, severity: 1) == "Image (Tritanopia).png", "export name for a nameless image")
        check(exportFileName("a/b:c", .achromatopsia, severity: 1) == "a-b-c (Achromatopsia).png", "export name has no path separators")

        // Remembered settings, on a throwaway defaults domain.
        let suite = "com.weirdapps.sight.selftest-\(UUID().uuidString)"
        if let d = UserDefaults(suiteName: suite) {
            check(Prefs.layout(d) == .split && Prefs.mode(d) == .deuteranopia && Prefs.severity(d) == 0.6, "defaults on first launch")
            d.set(Layout.grid.rawValue, forKey: Prefs.layoutKey)
            d.set(Simulation.tritanomaly.rawValue, forKey: Prefs.modeKey)
            d.set(0.3, forKey: Prefs.severityKey)
            check(Prefs.layout(d) == .grid && Prefs.mode(d) == .tritanomaly && Prefs.severity(d) == 0.3, "settings round trip")
            d.set("bogus", forKey: Prefs.modeKey)
            d.set(7.0, forKey: Prefs.severityKey)
            check(Prefs.mode(d) == .deuteranopia && Prefs.severity(d) == 0.6, "corrupt settings fall back to defaults")
            d.removePersistentDomain(forName: suite)
        }

        // Odd input: empty and non-image files do not decode.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sight-empty-\(UUID().uuidString).png")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        check(ImageFile.load(empty) == nil, "an empty file is not an image")
        try? FileManager.default.removeItem(at: empty)
        check(ImageFile.load(data: Data("not an image".utf8)) == nil, "text is not an image")
        let zero = Bitmap(width: 0, height: 0, pixels: [])
        check(zero.simulated(Simulation.protanopia.matrix(severity: 1)).pixels.isEmpty, "an empty bitmap simulates to nothing")

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
