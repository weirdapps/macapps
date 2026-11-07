import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `Arrow --selftest`: exercises geometry, hit testing, the pointer state machine, undo, crop and export.
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

    /// A plain grey test image.
    private static func image(_ w: Int, _ h: Int, grey: CGFloat = 0.5) -> CGImage {
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(srgbRed: grey, green: grey, blue: grey, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A sharp checker in the top left quarter, so redactions have detail to destroy.
        cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for y in stride(from: 0, to: h / 2, by: 2) {
            for x in stride(from: (y / 2) % 2 * 2, to: w / 2, by: 4) { cg.fill(CGRect(x: x, y: h - 1 - y, width: 2, height: 2)) }
        }
        return cg.makeImage()!
    }

    /// The RGBA of one pixel, with (x, y) from the top left.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let cg = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private static func board(_ w: Int = 800, _ h: Int = 600) -> (Board, UndoManager) {
        let b = Board()
        let um = UndoManager()
        um.groupsByEvent = false
        b.undoManager = um
        b.load(image(w, h), name: "Test")
        return (b, um)
    }

    private static func undo(_ um: UndoManager, _ body: () -> Void) {
        um.beginUndoGrouping()
        body()
        um.endUndoGrouping()
    }

    private static func drag(_ b: Board, _ from: CGPoint, _ to: CGPoint, _ um: UndoManager, shift: Bool = false) {
        undo(um) {
            b.pointerDown(from, tolerance: 4)
            b.pointerDragged(CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), shift: shift)
            b.pointerDragged(to, shift: shift)
            b.pointerUp(moved: true)
        }
    }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let red = RGBA(hex: 0xFF3B30)

        // Geometry.
        check(Geometry.rect(CGPoint(x: 10, y: 50), CGPoint(x: 30, y: 20)) == CGRect(x: 10, y: 20, width: 20, height: 30), "rect normalises its corners")
        check(abs(Geometry.distance(CGPoint(x: 5, y: 5), toSegment: .zero, CGPoint(x: 10, y: 0)) - 5) < 0.001, "distance to a segment")
        check(abs(Geometry.distance(CGPoint(x: 20, y: 0), toSegment: .zero, CGPoint(x: 10, y: 0)) - 10) < 0.001, "distance past a segment end")
        let snapped = Geometry.constrain(.zero, CGPoint(x: 100, y: 12), kind: .line)
        check(abs(snapped.y) < 0.001 && abs(snapped.x - hypot(100, 12)) < 0.01, "shift snaps a line to horizontal")
        let diagonal = Geometry.constrain(.zero, CGPoint(x: 100, y: 90), kind: .arrow)
        check(abs(diagonal.x - diagonal.y) < 0.01, "shift snaps an arrow to 45 degrees")
        check(Geometry.constrain(.zero, CGPoint(x: -40, y: 25), kind: .rectangle) == CGPoint(x: -40, y: 40), "shift makes a square")
        let arrow = Geometry.arrowPath(from: .zero, to: CGPoint(x: 200, y: 0), width: 8)
        check(arrow.contains(CGPoint(x: 195, y: 0)) && arrow.contains(CGPoint(x: 20, y: 0)), "arrow fills its shaft and head")
        check(!arrow.contains(CGPoint(x: 20, y: 20)) && arrow.boundingBox.maxX <= 200.01, "arrow ends at its tip")
        check(Geometry.arrowPath(from: .zero, to: .zero, width: 8).isEmpty, "zero length arrow draws nothing")

        // Hit testing.
        let box = Annotation(kind: .rectangle, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 200), color: red, width: 4)
        check(Geometry.hit(box, CGPoint(x: 101, y: 150), 4), "rectangle hits on its edge")
        check(!Geometry.hit(box, CGPoint(x: 200, y: 150), 4), "rectangle is open inside")
        let ring = Annotation(kind: .ellipse, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 200, y: 100), color: red, width: 4)
        check(Geometry.hit(ring, CGPoint(x: 100, y: 1), 4) && !Geometry.hit(ring, CGPoint(x: 100, y: 50), 4), "ellipse hits on its outline")
        let step = Annotation(kind: .step, start: CGPoint(x: 50, y: 50), end: .zero, color: red, width: 4)
        check(Geometry.hit(step, CGPoint(x: 52, y: 48), 2), "step badge hits inside")
        check(Geometry.handleHit(box, CGPoint(x: 299, y: 201), 4) == .corner(2), "corner handle hit")
        let resized = box.resized(.corner(0), to: CGPoint(x: 350, y: 250))
        check(resized.box == CGRect(x: 300, y: 200, width: 50, height: 50), "dragging a corner past the opposite one flips the box")
        check(box.moved(by: CGSize(width: 5, height: -5)).box == CGRect(x: 105, y: 95, width: 200, height: 100), "move translates")

        // Colours.
        check(RGBA(hex: 0xFFCC00).contrast == RGBA(hex: 0x1C1C1E) && red.contrast == RGBA(hex: 0xFFFFFF), "badge text contrasts")
        check(RGBA(hex: 0x34C759).hex == 0x34C759, "colour hex round trip")

        // Layout maps both ways.
        let layout = CanvasLayout(region: CGRect(x: 100, y: 50, width: 800, height: 400), size: CGSize(width: 856, height: 456), pixelScale: 1)
        let p = CGPoint(x: 333, y: 222)
        let back = layout.toImage(layout.toView(p))
        check(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001 && layout.scale == 1, "canvas layout round trip")
        check(CanvasLayout(region: CGRect(x: 0, y: 0, width: 400, height: 200), size: CGSize(width: 2000, height: 2000), pixelScale: 2).scale == 0.5,
              "retina image never shows bigger than captured")

        // Drawing with the pointer, and undo.
        do {
            let (b, um) = board()
            b.tool = .rectangle
            drag(b, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250), um)
            check(b.annotations.count == 1 && b.annotations[0].box == CGRect(x: 100, y: 100, width: 200, height: 150), "drag draws a rectangle")
            check(b.selection == b.annotations.first?.id, "a new mark is selected")
            b.pointerDown(CGPoint(x: 150, y: 150), tolerance: 4)
            b.pointerUp(moved: false)
            check(b.annotations.count == 1, "a click without a drag adds nothing")
            drag(b, CGPoint(x: 100, y: 175), CGPoint(x: 120, y: 195), um)
            check(b.annotations[0].box.origin == CGPoint(x: 120, y: 120), "dragging an edge moves the mark")
            um.undo()
            check(b.annotations[0].box.origin == CGPoint(x: 100, y: 100), "undo restores the move")
            um.undo()
            check(b.annotations.isEmpty, "undo removes the mark")
            um.redo()
            check(b.annotations.count == 1, "redo brings it back")
            undo(um) { b.deleteSelection() }
            check(b.annotations.count == 1, "delete with nothing selected does nothing")
            b.selection = b.annotations[0].id
            undo(um) { b.deleteSelection() }
            check(b.annotations.isEmpty && b.selection == nil, "delete removes the selected mark")
            um.undo()
            check(b.annotations.count == 1, "undo delete")
        }

        // Steps renumber; highlighter and tiny drags.
        do {
            let (b, um) = board()
            b.tool = .step
            for x in [100, 200, 300] {
                undo(um) { b.pointerDown(CGPoint(x: x, y: 400), tolerance: 4); b.pointerUp(moved: false) }
            }
            let ids = b.annotations.map(\.id)
            check(ids.count == 3 && b.stepNumber(ids[2]) == 3, "steps count up")
            b.selection = ids[0]
            undo(um) { b.deleteSelection() }
            check(b.stepNumber(ids[2]) == 2, "deleting a step renumbers the rest")
            b.tool = .highlighter
            drag(b, CGPoint(x: 50, y: 500), CGPoint(x: 400, y: 510), um)
            check(b.annotations.last?.kind == .highlighter && (b.annotations.last?.points.count ?? 0) >= 3, "highlighter records its path")
            b.tool = .arrow
            let before = b.annotations.count
            drag(b, CGPoint(x: 600, y: 100), CGPoint(x: 601, y: 100), um)
            check(b.annotations.count == before, "a tiny drag leaves no arrow behind")
        }

        // Text: a click places it, empty text disappears.
        do {
            let (b, um) = board()
            b.tool = .text
            undo(um) { b.pointerDown(CGPoint(x: 100, y: 100), tolerance: 4); b.pointerUp(moved: false) }
            check(b.editingID != nil, "text tool starts editing on click")
            b.setText("Hello")
            undo(um) { b.endEditing() }
            check(b.annotations.first?.text == "Hello" && b.editingID == nil, "typed text is kept")
            um.undo()
            check(b.annotations.isEmpty, "undo removes the text")
            undo(um) { b.pointerDown(CGPoint(x: 300, y: 300), tolerance: 4); b.pointerUp(moved: false) }
            undo(um) { b.endEditing() }
            check(b.annotations.isEmpty, "empty text is dropped")
        }

        // Style changes apply to the selection.
        do {
            let (b, um) = board()
            b.tool = .line
            drag(b, CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 200), um)
            undo(um) { b.setColor(RGBA(hex: 0x0A84FF)) }
            check(b.annotations[0].color == RGBA(hex: 0x0A84FF), "colour applies to the selection")
            undo(um) { b.beginChange(); b.setWidth(9); b.commitChange("Change Width") }
            check(b.annotations[0].width == 9 * b.unit, "width applies to the selection")
            um.undo()
            check(b.annotations[0].width == 4 * b.unit, "undo width")
        }

        // Crop and export.
        do {
            let (b, um) = board(800, 600)
            b.tool = .crop
            check(b.pendingCrop == b.fullRect, "crop starts at the whole image")
            b.pointerDown(CGPoint(x: 400, y: 300), tolerance: 4)
            b.pointerDragged(CGPoint(x: 900, y: 700))
            b.pointerUp(moved: true)
            check(b.pendingCrop == CGRect(x: 400, y: 300, width: 400, height: 300), "crop is clamped to the image")
            undo(um) { b.applyCrop() }
            check(b.crop == CGRect(x: 400, y: 300, width: 400, height: 300) && b.tool == .select, "crop applies")
            let out = b.rendered()
            check(out?.width == 400 && out?.height == 300, "export is cut to the crop")
            um.undo()
            check(b.crop == nil && b.rendered()?.width == 800, "undo crop")

            b.annotations = [Annotation(kind: .rectangle, start: CGPoint(x: 600, y: 100), end: CGPoint(x: 700, y: 200), color: red, width: 6)]
            if let img = b.rendered() {
                let edge = pixel(img, 600, 150), inside = pixel(img, 650, 150)
                check(edge.r > 200 && edge.g < 120, "export paints the rectangle stroke")
                check(abs(inside.r - 128) < 6 && abs(inside.g - 128) < 6, "export leaves the inside untouched")
            } else { check(false, "export renders") }

            func spread(_ img: CGImage) -> Int {
                let reds = (100..<106).flatMap { x in (100..<106).map { y in pixel(img, x, y).r } }
                return (reds.max() ?? 0) - (reds.min() ?? 0)
            }
            let sharp = b.rendered().map(spread) ?? 0
            b.annotations = [Annotation(kind: .redact, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 400, y: 300), color: red, width: 4)]
            if let img = b.rendered() {
                check(sharp > 60 && spread(img) < 30, "pixelate wipes out detail")
                b.annotations[0].style = .blur
                check(b.rendered().map(spread).map { $0 < 30 } ?? false, "blur wipes out detail")
                b.annotations[0].style = .solid
                check(b.rendered().map(spread).map { $0 == 0 } ?? false, "solid redaction keeps nothing underneath")
                check(pixel(img, 600, 450).r == 128 || abs(pixel(img, 600, 450).r - 128) < 3, "redaction stays inside its box")
            } else { check(false, "export renders a redaction") }

            if let png = b.pngData(), let rep = NSBitmapImageRep(data: png) {
                check(rep.pixelsWide == 800 && rep.pixelsHigh == 600, "PNG keeps the pixel size")
            } else { check(false, "PNG encodes") }
        }

        // Loading a new image starts clean; the demo shot renders.
        do {
            let (b, _) = board()
            b.annotations = [Annotation(kind: .step, start: .zero, end: .zero, color: red, width: 4)]
            b.crop = CGRect(x: 0, y: 0, width: 10, height: 10)
            b.load(image(300, 200), name: "Next")
            check(b.annotations.isEmpty && b.crop == nil && b.fullRect.width == 300, "loading an image resets marks and crop")
            check(b.effects.blurred?.width == 300 && b.effects.blurred?.height == 200, "blur source matches the image")
            let png = Renderer.png(image(40, 30), pixelScale: 1)
            check(png.map { b.load(data: $0, name: "Data") } == true && b.fullRect.width == 40, "loads PNG data")
            let demo = Demo.board()
            check(demo.rendered()?.width == Int(Demo.size.width) && demo.annotations.count == 12, "demo renders")
        }

        // Loading odd input.
        do {
            let (b, um) = board(200, 100)
            check(!b.load(data: Data(), name: "Empty") && b.fullRect.width == 200, "empty data is refused and keeps the image")
            check(!b.load(data: Data("not an image".utf8), name: "Junk") && b.fullRect.width == 200, "junk data is refused")
            check(!b.load(url: URL(string: "https://example.com/a.png")!), "a web address is never fetched")
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent("arrow-missing-\(UUID().uuidString).png")
            check(!b.load(url: missing), "a missing file is refused")
            // A photo taken in portrait: 40 x 20 pixels stored, EXIF orientation 6 (rotate 90 degrees).
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image(40, 20), [kCGImagePropertyOrientation: 6] as CFDictionary)
                _ = CGImageDestinationFinalize(dest)
            }
            check(b.load(data: data as Data, name: "Portrait") && b.fullRect.size == CGSize(width: 20, height: 40), "EXIF orientation is applied")
            check(Board.pixelScale(dpi: 72) == 1 && Board.pixelScale(dpi: 144) == 2 && Board.pixelScale(dpi: 216) == 3, "screenshot densities")
            check(Board.pixelScale(dpi: 300) == 1 && Board.pixelScale(dpi: 0) == 1 && Board.pixelScale(dpi: .nan) == 1 && Board.pixelScale(dpi: 720) == 1,
                  "a print density does not shrink the canvas")
            _ = um
        }

        // Replacing the image never loses work silently.
        do {
            let (b, um) = board(800, 600)
            b.tool = .rectangle
            drag(b, CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 250), um)
            undo(um) { b.load(image(300, 200), name: "Pasted") }
            check(b.annotations.isEmpty && b.fullRect.width == 300, "a new image replaces the marks")
            check(um.canUndo && um.undoActionName == "Open Image", "replacing marked up work is undoable")
            um.undo()
            check(b.annotations.count == 1 && b.fullRect.width == 800 && b.imageName == "Test", "undo brings back the image and its marks")
            um.redo()
            check(b.fullRect.width == 300 && b.annotations.isEmpty, "redo opens the new image again")
            b.load(image(100, 100), name: "Third") // Registers nothing, so no group: an empty group would count as an undo step.
            check(!um.canUndo, "opening over an unmarked image leaves no stale undo steps")
        }

        // Pixelation averages blocks aligned to the box, so thin text turns into solid tiles.
        do {
            let w = 400, h = 200
            let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
            cg.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            for y in stride(from: 0, to: h, by: 6) { cg.fill(CGRect(x: 0, y: y, width: w, height: 1)) }
            let lines = cg.makeImage()!
            let (b, _) = board()
            b.load(lines, name: "Lines")
            b.annotations = [Annotation(kind: .redact, start: CGPoint(x: 13, y: 7), end: CGPoint(x: 377, y: 151), color: red, width: 4)]
            if let img = b.rendered() {
                let samples = [(15, 9), (100, 60), (200, 100), (375, 149), (376, 10), (14, 150)].map { pixel(img, $0.0, $0.1).r }
                check(samples.allSatisfy { $0 > 90 && $0 < 245 }, "pixelate averages every block, edges included")
                let outside = pixel(img, 390, 3).r
                check(outside == 0 || outside == 255, "pixelate leaves the outside sharp")
            } else { check(false, "pixelate renders") }
            let block = Renderer.blockSize(box: CGRect(x: 0, y: 0, width: 288, height: 56), imageSize: CGSize(width: 1600, height: 1000))
            check(block >= 12 && block <= 20, "a text row gets a few tall blocks")
            check(Renderer.blockSize(box: CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: CGSize(width: 50, height: 50)) >= 6, "tiny boxes still pixelate")
        }

        // The colour wheel reports every step of a drag; they make one undo step.
        do {
            let (b, um) = board()
            b.tool = .line
            drag(b, CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 200), um)
            let start = Date()
            undo(um) { b.setColor(RGBA(hex: 0x112233), continuous: true, now: start) }
            // The later steps must register nothing (outside a group that would raise).
            b.setColor(RGBA(hex: 0x445566), continuous: true, now: start.addingTimeInterval(0.1))
            b.setColor(RGBA(hex: 0x778899), continuous: true, now: start.addingTimeInterval(0.2))
            check(b.annotations[0].color == RGBA(hex: 0x778899), "colour wheel recolours live")
            um.undo()
            check(b.annotations[0].color == RGBA(hex: 0xFF3B30) && b.annotations.count == 1, "one undo reverts a whole colour wheel drag")
        }

        // Plain keys belong to the canvas only.
        do {
            let (b, _) = board()
            check(b.acceptsPlainKeys, "plain keys work on the canvas")
            b.windowIsKey = false
            check(!b.acceptsPlainKeys, "plain keys pass through to a Save or Colors panel")
            b.windowIsKey = true
            b.tool = .text
            b.pointerDown(CGPoint(x: 100, y: 100), tolerance: 4)
            b.pointerUp(moved: false)
            check(!b.acceptsPlainKeys, "plain keys pass through while typing a label")
            check(!Board().acceptsPlainKeys, "no plain keys without an image")
        }

        // Big images make their blur off the main thread, and a late result never lands on a newer image.
        do {
            let (b, _) = board()
            b.load(image(3000, 2400), name: "Big")
            check(b.effects.blurred == nil, "a big image does not block on its blur")
            let deadline = Date().addingTimeInterval(10)
            while b.effects.blurred == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(b.effects.blurred?.width == 3000, "the blur arrives for the big image")
            b.load(image(3000, 2400), name: "Big again")
            b.load(image(120, 80), name: "Small")
            let settle = Date().addingTimeInterval(3)
            while Date() < settle { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            check(b.effects.blurred?.width == 120, "a stale blur is dropped")
        }

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}
