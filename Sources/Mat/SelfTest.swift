import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `Mat --selftest`: checks layout, rendering, persistence and naming without touching the user's data.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passed = 0

    private static func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1 } else { failures += 1; print("FAIL: \(name)") }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1) -> Bool { abs(a - b) <= tolerance }

    /// RGBA bytes of one pixel, with y counted from the top like the image's rows.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }

    private static func solidImage(_ width: Int, _ height: Int, _ hex: UInt32) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(RGB(hex: hex).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func run() -> Int32 {
        let shot = CGSize(width: 1000, height: 500)
        var style = MatStyle()

        // Layout: Auto wraps the image in even padding.
        style.padding = 0.1
        var layout = MatLayout.compute(image: shot, style: style)
        check(layout.canvas == CGSize(width: 1200, height: 700), "auto padding adds 10% of the long side on every edge")
        check(layout.imageRect == CGRect(x: 100, y: 100, width: 1000, height: 500), "auto centres the image")
        check(layout.output == layout.canvas, "auto exports at canvas size")

        style.padding = 0
        layout = MatLayout.compute(image: shot, style: style)
        check(layout.canvas == shot, "zero padding leaves the canvas the size of the image")

        // Ratio presets grow the short side, never crop.
        style.padding = 0.1
        style.aspect = .square
        layout = MatLayout.compute(image: shot, style: style)
        check(layout.canvas == CGSize(width: 1200, height: 1200), "1:1 makes a square canvas")
        check(layout.imageRect.midY == 600 && layout.imageRect.midX == 600, "1:1 centres the image")

        style.aspect = .wide
        layout = MatLayout.compute(image: shot, style: style)
        check(near(layout.canvas.width / layout.canvas.height, 16.0 / 9, 0.01), "16:9 canvas has the right ratio")
        check(layout.canvas.width >= 1200 && layout.canvas.height >= 700, "16:9 keeps at least the padding")

        style.aspect = .standard
        layout = MatLayout.compute(image: CGSize(width: 400, height: 1000), style: style)
        check(near(layout.canvas.width / layout.canvas.height, 4.0 / 3, 0.01), "4:3 widens a tall image")
        check(layout.canvas.height == 1200, "4:3 keeps the tall image's padded height")

        style.aspect = .twitter
        layout = MatLayout.compute(image: shot, style: style)
        check(layout.output == CGSize(width: 1600, height: 900), "Twitter/X exports at 1600 × 900")
        check(layout.pixels(scale: 2) == CGSize(width: 3200, height: 1800), "2x doubles the Twitter/X size")

        style.aspect = .instagram
        layout = MatLayout.compute(image: shot, style: style)
        check(layout.output == CGSize(width: 1080, height: 1350), "Instagram exports at 1080 × 1350")
        check(near(layout.canvas.width / layout.canvas.height, 0.8, 0.01), "Instagram canvas is 4:5")

        // Rendering.
        style = MatStyle()
        style.backdrop = .solid(0)
        style.padding = 0.1
        style.radius = 40
        style.shadow = 0
        style.border = false
        let red = solidImage(1000, 500, 0xE02020)
        if let out = Renderer.render(red, style: style) {
            check(out.width == 1200 && out.height == 700, "render at 1x matches the layout")
            let corner = pixel(out, 2, 2)
            check(corner.r == 255 && corner.g == 255 && corner.b == 255 && corner.a == 255, "solid white backdrop fills the corner")
            let middle = pixel(out, 600, 350)
            check(middle.r > 210 && middle.g < 50 && middle.b < 50, "the screenshot sits in the middle")
            let clipped = pixel(out, 102, 102)
            check(clipped.r == 255 && clipped.g == 255, "corner radius clips the screenshot's corner")
            let edge = pixel(out, 600, 103)
            check(edge.r > 210 && edge.g < 50, "corner radius leaves the straight edges alone")
        } else {
            check(false, "render returns an image")
        }

        style.scale = 2
        if let out = Renderer.render(red, style: style) {
            check(out.width == 2400 && out.height == 1400, "render at 2x doubles the pixels")
            let middle = pixel(out, 1200, 700)
            check(middle.r > 210 && middle.g < 50, "2x keeps the image centred")
        } else {
            check(false, "render at 2x returns an image")
        }

        style.scale = 1
        style.backdrop = .gradient(0)
        if let out = Renderer.render(red, style: style) {
            let topLeft = pixel(out, 0, 0), bottomRight = pixel(out, out.width - 1, out.height - 1)
            let top = Presets.gradients[0].top, bottom = Presets.gradients[0].bottom
            check(abs(topLeft.r - Int(top.r * 255)) < 6 && abs(topLeft.g - Int(top.g * 255)) < 6, "gradient starts top left")
            check(abs(bottomRight.g - Int(bottom.g * 255)) < 6 && abs(bottomRight.b - Int(bottom.b * 255)) < 6,
                  "gradient ends bottom right")
        }

        style.backdrop = .solid(0)
        style.shadow = 1
        if let out = Renderer.render(red, style: style) {
            let below = pixel(out, 600, 615)
            check(below.r < 250, "a strong shadow darkens the mat below the image")
            let above = pixel(out, 600, 40)
            check(below.r < above.r, "the shadow falls downwards")
        }

        // A transparent screenshot shows the mat through, not the shadow fill.
        let clear = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        if let out = Renderer.render(clear, style: style) {
            let middle = pixel(out, out.width / 2, out.height / 2)
            check(middle.r == 255 && middle.a == 255, "transparent pixels show the backdrop")
        }

        let preview = Renderer.render(red, style: style, pixels: CGSize(width: 600, height: 350))
        check(preview?.width == 600 && preview?.height == 350, "previews render at the requested size")

        // PNG round trip.
        if let png = Renderer.png(red), let back = Renderer.decode(png) {
            check(back.width == 1000 && back.height == 500, "PNG encodes and decodes at full size")
        } else {
            check(false, "PNG round trip")
        }
        check(Renderer.decode(Data("not an image".utf8)) == nil, "non image data is rejected")

        // Colours and presets.
        check(RGB(hex: 0xFF7A59).hex == 0xFF7A59, "hex colour round trip")
        check(RGB(RGB(hex: 0x3A47D5).color).hex == 0x3A47D5, "SwiftUI colour round trip")
        check(Backdrop.gradient(0).stepped(by: -1) == .custom, "previous background wraps to Custom")
        check(Backdrop.custom.stepped(by: 1) == .gradient(0), "next background wraps to the first gradient")
        check(Backdrop.all.count == Presets.gradients.count + Presets.solids.count + 1, "every backdrop is reachable")
        var bad = MatStyle()
        bad.backdrop = .gradient(99)
        check(bad.colors.top == Presets.gradients[0].top, "an out of range preset falls back to the first")

        // Persistence.
        var saved = MatStyle()
        saved.backdrop = .custom
        saved.customTop = RGB(hex: 0x123456)
        saved.aspect = .instagram
        saved.scale = 2
        saved.border = false
        if let data = try? JSONEncoder().encode(saved), let back = try? JSONDecoder().decode(MatStyle.self, from: data) {
            check(back == saved, "style survives a JSON round trip")
        } else {
            check(false, "style encodes")
        }

        // Naming and demo data.
        check(Renderer.exportName(for: "Screenshot 2026-11-07 at 09.41.12.png") == "Screenshot 2026-11-07 at 09.41.12 Mat.png",
              "export name keeps the original name")
        check(Renderer.exportName(for: "") == "Screenshot Mat.png", "export name has a fallback")
        let demo = DemoShot.make()
        check(demo.width == 1440 && demo.height == 900, "demo screenshot draws")

        // Damaged settings are pulled back into range instead of breaking the window.
        var wild = MatStyle()
        wild.padding = 7
        wild.radius = -3
        wild.shadow = .nan
        wild.scale = 0
        wild.backdrop = .solid(42)
        let tame = wild.sanitized()
        check(tame.padding == 0.25 && tame.radius == 0 && tame.shadow == 0.55, "sanitize clamps sliders and replaces NaN")
        check(tame.scale == 1 && tame.backdrop == .gradient(0), "sanitize fixes scale and an unknown preset")
        check(MatStyle().sanitized() == MatStyle(), "sanitize leaves a good style alone")

        // Huge or extreme screenshots never ask for an enormous bitmap.
        style = MatStyle()
        style.aspect = .square
        layout = MatLayout.compute(image: CGSize(width: 12000, height: 40), style: style)
        let huge = layout.pixels(scale: 2)
        check(max(huge.width, huge.height) <= MatLayout.maxSide, "output is capped at the longest side Mat writes")
        check(near(huge.width / huge.height, 1, 0.001), "the cap keeps the aspect ratio")
        check(MatLayout.compute(image: CGSize(width: 1, height: 1), style: MatStyle()).pixels(scale: 1).width >= 1,
              "a one pixel screenshot still lays out")
        let tiny = solidImage(1, 1, 0x000000)
        check(Renderer.render(tiny, style: MatStyle()) != nil, "a one pixel screenshot renders")

        // Photos carry rotation as metadata; Mat applies it.
        do {
            let data = NSMutableData()
            let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, solidImage(200, 100, 0x2060E0), [kCGImagePropertyOrientation: 6] as CFDictionary)
            CGImageDestinationFinalize(dest)
            let rotated = Renderer.decode(data as Data)
            check(rotated?.width == 100 && rotated?.height == 200, "EXIF orientation is applied on decode")
        }
        check(Renderer.decode(Data()) == nil, "empty data is rejected")

        // Copy and export encode off the main thread through one helper.
        if let enc = Renderer.encoded(red, style: MatStyle(), tiff: true) {
            check(Renderer.decode(enc.png) != nil && enc.tiff.map { Renderer.decode($0) != nil } == true, "copy encodes PNG and TIFF")
        } else {
            check(false, "copy encodes")
        }

        MainActor.assumeIsolated {
            // Pasting a non image file copied in Finder must not paste the file's icon.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mat-selftest-\(UUID().uuidString).txt")
            try? Data("hello".utf8).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let pb = NSPasteboard(name: NSPasteboard.Name("mat.selftest.\(UUID().uuidString)"))
            defer { pb.releaseGlobally() }
            pb.clearContents()
            pb.writeObjects([tmp as NSURL])
            if let tiff = NSBitmapImageRep(cgImage: red).tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            let model = MatModel(persist: false)
            model.paste(from: pb)
            check(!model.hasImage && model.toast?.isError == true, "pasting a Finder text file shows an error, not its icon")

            let imagePB = NSPasteboard(name: NSPasteboard.Name("mat.selftest.\(UUID().uuidString)"))
            defer { imagePB.releaseGlobally() }
            imagePB.clearContents()
            imagePB.setData(Renderer.png(red), forType: .png)
            model.paste(from: imagePB)
            check(model.hasImage && model.source?.width == 1000 && model.preview != nil, "pasting PNG data loads it with a preview")

            // A colour drag is one undo step, other edits are their own.
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.undoManager = undo
            let before = model.style
            for hex: UInt32 in [0x111111, 0x222222, 0x333333] {
                undo.beginUndoGrouping()
                model.updateColour { $0.customTop = RGB(hex: hex); $0.backdrop = .custom }
                undo.endUndoGrouping()
            }
            undo.beginUndoGrouping()
            model.update { $0.border.toggle() }
            undo.endUndoGrouping()
            undo.undo()
            check(model.style.border == before.border && model.style.customTop == RGB(hex: 0x333333), "undo reverts the last edit only")
            // Count the undos that change something; empty groups from this test do not.
            var steps = 0
            while undo.canUndo {
                let prior = model.style
                undo.undo()
                if model.style != prior { steps += 1 }
            }
            check(model.style == before && steps == 1, "one undo reverts a whole colour drag")
            check(!model.style.isColourEdit(of: { var s = before; s.padding = 0.2; return s }()), "a padding change is not a colour edit")
        }

        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
