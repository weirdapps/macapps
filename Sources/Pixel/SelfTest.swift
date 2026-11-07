import AppKit
import Foundation

/// `Pixel --selftest`: exercises the picture model, the file format, PNG export and import, and the editor's strokes.
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

    static func run() -> Int32 {
        let red = RGBA(0xFF004D), blue = RGBA(0x29ADFF)

        // Colours.
        check(RGBA(hex: "#FFA300") == RGBA(0xFFA300), "hex parses with a hash")
        check(RGBA(hex: "ff004d80") == RGBA(r: 255, g: 0, b: 77, a: 128), "eight-digit hex carries alpha")
        check(RGBA(hex: "12345") == nil && RGBA(hex: "GGGGGG") == nil, "bad hex is rejected")
        check(RGBA(hex: "+FFFFF") == nil && RGBA(hex: "+FFFFFFF") == nil, "a signed number is not a colour")
        check(RGBA(hex: "ＦＦＦＦＦＦ") == nil && RGBA(hex: "") == nil, "full width digits and empty text are rejected")
        check(RGBA(hex: red.hex8) == red, "hex round trip")
        check(RGBA(r: 1, g: 2, b: 3, a: 128).display == "#010203 50%", "display shows alpha percent")
        check(Set(Palette.presets).count == 16, "palette has 16 distinct colours")

        // Recents.
        var recents: [RGBA] = []
        for c in Palette.presets { recents = Palette.remember(c, in: recents) }
        recents = Palette.remember(Palette.presets[3], in: recents)
        check(recents.count == Palette.recentLimit, "recents are capped")
        check(recents.first == Palette.presets[3] && recents.filter { $0 == Palette.presets[3] }.count == 1,
              "a reused colour moves to the front once")
        check(Palette.remember(.clear, in: []) == [], "the empty colour is never remembered")

        // Shapes.
        let line = PixelImage.line(Point(x: 0, y: 0), Point(x: 5, y: 2))
        check(line.first == Point(x: 0, y: 0) && line.last == Point(x: 5, y: 2) && line.count == 6, "line spans its ends")
        check(PixelImage.line(Point(x: 3, y: 3), Point(x: 3, y: 3)) == [Point(x: 3, y: 3)], "a zero length line is one pixel")
        check(PixelImage.line(Point(x: 4, y: 0), Point(x: 0, y: 4)).count == 5, "diagonal line has no gaps")
        let rect = PixelImage.rectangle(Point(x: 3, y: 2), Point(x: 0, y: 0))
        check(rect.count == 10 && Set(rect).count == 10, "rectangle outline has each pixel once")
        check(PixelImage.rectangle(Point(x: 1, y: 1), Point(x: 1, y: 4)).count == 4, "a one wide rectangle is a line")

        // Fill and mirror.
        var ring = PixelImage(width: 8, height: 8)
        ring.plot(PixelImage.rectangle(Point(x: 1, y: 1), Point(x: 5, y: 5)), blue, mirror: false)
        var filled = ring
        filled.fill(from: Point(x: 3, y: 3), with: red)
        check(filled.pixels.filter { $0 == red }.count == 9, "fill stays inside the outline")
        check(filled[0, 0].isClear && filled[1, 1] == blue, "fill leaves the outside and the outline alone")
        var same = ring
        same.fill(from: Point(x: 1, y: 1), with: blue)
        check(same == ring, "filling with the same colour changes nothing")
        var mirrored = PixelImage(width: 8, height: 4)
        mirrored.plot([Point(x: 1, y: 2)], red, mirror: true)
        check(mirrored[1, 2] == red && mirrored[6, 2] == red, "mirror paints the reflected pixel")
        mirrored.plot([Point(x: 9, y: 9)], red, mirror: false)
        check(mirrored.pixels.filter { $0 == red }.count == 2, "off canvas pixels are ignored")

        // Resize.
        var dot = PixelImage(width: 8, height: 8)
        dot[4, 4] = red
        let bigger = dot.resized(width: 16, height: 16)
        check(bigger.width == 16 && bigger[8, 8] == red, "growing the canvas keeps the picture centred")
        check(bigger.resized(width: 8, height: 8) == dot, "shrinking back restores the picture")

        // File format.
        let cat = PixelImage.demoCat
        if let data = try? cat.jsonData(), let back = try? PixelImage.decode(data) {
            check(back == cat, "document round trip")
            let text = String(decoding: data, as: UTF8.self)
            check(text.contains("\"format\":\"pixel\"") && text.contains("\"width\":16"), "document is readable JSON")
        } else {
            check(false, "document encodes and decodes")
        }
        let short = #"{"width":2,"height":2,"pixels":["000000FF"]}"#
        check((try? PixelImage.decode(Data(short.utf8))) == nil, "a wrong pixel count is rejected")
        let huge = #"{"width":65,"height":1,"pixels":[]}"#
        check((try? PixelImage.decode(Data(huge.utf8))) == nil, "a canvas over 64 px is rejected")

        // PNG.
        var sprite = cat
        sprite[0, 0] = RGBA(r: 10, g: 20, b: 30, a: 255)
        do {
            let png = try sprite.pngData(scale: 1)
            check(try PixelImage.importing(png) == sprite, "PNG round trip at 1x keeps every pixel and transparency")
            let scaled = try sprite.pngData(scale: 8)
            if let rep = NSBitmapImageRep(data: scaled) {
                check(rep.pixelsWide == 128 && rep.pixelsHigh == 128, "8x export is 128 px")
            } else {
                check(false, "8x export is a readable PNG")
            }
            check(try PixelImage.importing(scaled) == sprite, "importing an 8x export gives the 16 px picture back")
            let blank = try PixelImage(width: 16, height: 16).pngData(scale: 4)
            check(try PixelImage.importing(blank).width >= 8, "a blank export is not reduced below 8 px")
        } catch {
            check(false, "PNG export and import: \(error)")
        }
        var noise = PixelImage(width: 64, height: 64)
        for i in 0..<64 { noise.plot([Point(x: i, y: (i * 7) % 64)], red, mirror: false) }
        if let png = try? noise.resized(width: 64, height: 64).pngData(scale: 1),
           var big = try? PixelImage.importing(png) {
            check(big.width == 64, "a 64 px PNG imports as is")
            big[0, 0] = red
            let wide = PixelImage.blockScale(big.pixels, width: 64, height: 64)
            check(wide == 1, "a detailed picture is not treated as upscaled")
        }
        check((try? PixelImage.importing(Data("not a png".utf8))) == nil, "garbage is not an image")
        if let png = oversize() {
            check((try? PixelImage.importing(png)) == nil, "a 100 px photo is refused")
        }
        if let png = flat(side: 4000) {
            let start = Date()
            do {
                _ = try PixelImage.importing(png)
                check(false, "a 4000 px image is refused")
            } catch {
                check(error as? PixelError == .tooLarge(4000, 4000) && Date().timeIntervalSince(start) < 0.5,
                      "a 4000 px image is refused from its header, without decoding")
            }
        }
        check((try? PixelImage.importing(Data())) == nil, "an empty file is not an image")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pixel-selftest-\(UUID().uuidString).png")
        if let png = try? sprite.pngData(scale: 4), (try? png.write(to: tmp)) != nil {
            check((try? PixelImage.importing(contentsOf: tmp)) == sprite, "importing a PNG file from disk")
            try? FileManager.default.removeItem(at: tmp)
        }
        check((try? PixelImage.importing(contentsOf: tmp)) == nil, "a missing file fails cleanly")

        // Editor strokes and undo.
        let doc = PixelDocument(image: PixelImage(width: 8, height: 8))
        let undo = UndoManager()
        undo.groupsByEvent = false
        let editor = EditorState(document: doc, persists: false)
        editor.undoManager = undo
        editor.color = red
        editor.mirror = true
        undo.beginUndoGrouping()
        editor.begin(at: Point(x: 0, y: 0))
        editor.move(to: Point(x: 2, y: 0))
        editor.end()
        undo.endUndoGrouping()
        check(doc.image[1, 0] == red && doc.image[7, 0] == red && doc.image[5, 0] == red, "pencil drags draw a gapless mirrored stroke")
        check(editor.recents.first == red, "drawing remembers the colour")
        check(undo.canUndo && undo.undoActionName == "Draw", "a stroke is one named undo step")
        undo.undo()
        check(doc.image.isBlank, "undo removes the whole stroke")
        undo.redo()
        check(doc.image[7, 0] == red, "redo puts it back")

        editor.mirror = false
        editor.select(.rectangle)
        undo.beginUndoGrouping()
        editor.begin(at: Point(x: 1, y: 2))
        editor.move(to: Point(x: 6, y: 6))
        editor.move(to: Point(x: 3, y: 4))
        editor.end()
        undo.endUndoGrouping()
        check(doc.image[6, 6].isClear && doc.image[3, 4] == red && doc.image[2, 3].isClear,
              "rectangle previews follow the drag and only the last one stays")

        editor.select(.eyedropper)
        editor.begin(at: Point(x: 7, y: 0))
        editor.end()
        check(editor.color == red && editor.tool == .rectangle, "eyedropper picks and returns to the last tool")

        editor.color = blue
        editor.begin(at: Point(x: 7, y: 7), option: true)
        editor.end()
        check(editor.color == blue, "the eyedropper ignores empty pixels")

        editor.select(.eraser)
        editor.pick(blue)
        check(editor.tool == .pencil, "choosing a colour while erasing switches to the pencil")

        undo.beginUndoGrouping()
        editor.resize(to: 16)
        undo.endUndoGrouping()
        check(doc.image.width == 16 && undo.undoActionName == "Change Canvas Size", "canvas size change is undoable")
        undo.undo()
        check(doc.image.width == 8, "undoing the size change restores the canvas")

        editor.fitZoom = EditorState.fit(doc.image, in: CGSize(width: 700, height: 500))
        check(editor.fitZoom == 54, "fit zoom uses the smaller side")
        editor.zoomIn()
        check(editor.zoom == 64, "zoom in steps to the next level")
        editor.zoomOut()
        editor.zoomOut()
        check(editor.zoom == 40, "zoom out steps down")

        print("\(checks - failures)/\(checks) checks passed")
        return failures == 0 ? 0 : 1
    }

    /// A flat PNG `side` px square, for the size limit.
    private static func flat(side: Int) -> Data? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A 100 px PNG with detail, too big to import.
    private static func oversize() -> Data? {
        guard let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        for i in 0..<100 { ctx.fill(CGRect(x: i, y: (i * 13) % 100, width: 1, height: 1)) }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
