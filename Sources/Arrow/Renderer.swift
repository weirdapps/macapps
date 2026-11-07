import AppKit
import Kit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

/// Draws the image and its marks. The same code paints the canvas and the exported PNG, so what you see is what you get.
/// Every function expects a context whose user space is image pixels with the origin at the top left (y down).
enum Renderer {
    /// Pre-computed redaction sources for the whole image; a redaction draws the matching one clipped to its box.
    struct Effects {
        var pixelated: CGImage?
        var blurred: CGImage?
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    static func effects(for image: CGImage) -> Effects {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let longest = max(extent.width, extent.height)
        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = input.clampedToExtent()
        pixellate.scale = Float(max(8, longest / 110))
        pixellate.center = .zero
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(max(8, longest / 120)))
        return Effects(
            pixelated: pixellate.outputImage.flatMap { ciContext.createCGImage($0.cropped(to: extent), from: extent) },
            blurred: ciContext.createCGImage(blurred.cropped(to: extent), from: extent))
    }

    static func drawImage(_ image: CGImage, in rect: CGRect, _ cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: 0, y: rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
        cg.restoreGState()
    }

    /// `shadowScale` converts image pixels to device pixels for shadow blur, which ignores the transform.
    static func draw(image: CGImage, annotations: [Annotation], effects: Effects, numbers: [UUID: Int],
                     hiding: UUID? = nil, shadowScale: CGFloat = 1, in cg: CGContext) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        cg.interpolationQuality = .high
        drawImage(image, in: full, cg)
        for a in annotations where a.id != hiding {
            draw(a, number: numbers[a.id] ?? 1, image: image, effects: effects, shadowScale: shadowScale, in: cg)
        }
    }

    static func draw(_ a: Annotation, number: Int, image: CGImage, effects: Effects, shadowScale: CGFloat, in cg: CGContext) {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let w = a.width
        cg.saveGState()
        defer { cg.restoreGState() }
        func lift() {
            cg.setShadow(offset: .zero, blur: max(2, w * 1.1) * shadowScale, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        switch a.kind {
        case .redact:
            let box = a.box
            guard box.width > 0, box.height > 0 else { return }
            cg.clip(to: box)
            if let source = a.style == .pixelate ? effects.pixelated : effects.blurred {
                drawImage(source, in: full, cg)
            } else {
                cg.setFillColor(NSColor.gray.cgColor)
                cg.fill(box)
            }
        case .rectangle:
            lift()
            let box = a.box
            let radius = min(w * 0.8, box.width / 2, box.height / 2)
            cg.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.setStrokeColor(a.color.cg)
            cg.setLineWidth(w)
            cg.strokePath()
        case .ellipse:
            lift()
            cg.addEllipse(in: a.box)
            cg.setStrokeColor(a.color.cg)
            cg.setLineWidth(w)
            cg.strokePath()
        case .line:
            lift()
            cg.move(to: a.start)
            cg.addLine(to: a.end)
            cg.setStrokeColor(a.color.cg)
            cg.setLineWidth(w)
            cg.strokePath()
        case .arrow:
            lift()
            cg.addPath(Geometry.arrowPath(from: a.start, to: a.end, width: w))
            cg.setFillColor(a.color.cg)
            cg.setStrokeColor(a.color.cg)
            cg.setLineWidth(w * 0.35)
            cg.drawPath(using: .fillStroke)
        case .highlighter:
            cg.setBlendMode(.multiply)
            cg.addPath(Geometry.smoothPath(a.points))
            cg.setStrokeColor(a.color.ns.withAlphaComponent(0.45).cgColor)
            cg.setLineWidth(Geometry.highlighterWidth(w))
            cg.strokePath()
        case .text:
            lift()
            drawText(a.text, at: a.start, size: Geometry.fontSize(w), color: a.color, in: cg)
        case .step:
            lift()
            let r = Geometry.stepRadius(w)
            let disc = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            cg.setFillColor(a.color.cg)
            cg.fillEllipse(in: disc)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setStrokeColor(a.color.contrast.ns.withAlphaComponent(0.95).cgColor)
            cg.setLineWidth(max(1.5, r * 0.12))
            cg.strokeEllipse(in: disc.insetBy(dx: r * 0.06, dy: r * 0.06))
            let label = "\(number)" as NSString
            let font = Geometry.font(size: r * (number > 9 ? 0.95 : 1.15))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: a.color.contrast.ns]
            let size = label.size(withAttributes: attrs)
            withAppKit(cg) {
                label.draw(at: CGPoint(x: a.start.x - size.width / 2, y: a.start.y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    /// Bold rounded text with a contrasting outline, readable on any screenshot.
    static func drawText(_ text: String, at origin: CGPoint, size: CGFloat, color: RGBA, in cg: CGContext) {
        let font = Geometry.font(size: size)
        let s = text as NSString
        withAppKit(cg) {
            s.draw(at: origin, withAttributes: [.font: font, .strokeColor: color.contrast.ns, .strokeWidth: 18])
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            s.draw(at: origin, withAttributes: [.font: font, .foregroundColor: color.ns])
        }
    }

    /// Runs AppKit text drawing in `cg`, which is flipped (y down).
    static func withAppKit(_ cg: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Flattens the marks onto the image, cut to `region` (image pixels).
    static func export(image: CGImage, annotations: [Annotation], region: CGRect, effects: Effects, numbers: [UUID: Int]) -> CGImage? {
        let r = region.integral
        guard r.width >= 1, r.height >= 1 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = CGContext(data: nil, width: Int(r.width), height: Int(r.height), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cg.translateBy(x: 0, y: r.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -r.minX, y: -r.minY)
        draw(image: image, annotations: annotations, effects: effects, numbers: numbers, in: cg)
        return cg.makeImage()
    }

    /// PNG data that keeps the image's Retina density, so it pastes at the size it was captured.
    static func png(_ image: CGImage, pixelScale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * pixelScale
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

// MARK: - Demo

/// A made up web app screenshot with a set of marks, for the website snapshot.
enum Demo {
    static let size = CGSize(width: 1600, height: 1000)

    @MainActor
    static func board() -> Board {
        let board = Board()
        board.load(screenshot(), name: "Team settings")
        let red = RGBA(hex: 0xFF3B30)
        let emails = (0..<4).map { i in
            Annotation(kind: .redact, start: CGPoint(x: 712, y: 322 + CGFloat(i) * 111), end: CGPoint(x: 1000, y: 378 + CGFloat(i) * 111),
                       color: red, width: 8)
        }
        board.annotations = emails + [
            Annotation(kind: .highlighter, start: .zero, end: .zero,
                       points: [CGPoint(x: 438, y: 864), CGPoint(x: 600, y: 863), CGPoint(x: 760, y: 865)], color: RGBA(hex: 0xFFCC00), width: 8),
            Annotation(kind: .rectangle, start: CGPoint(x: 1094, y: 426), end: CGPoint(x: 1262, y: 496), color: red, width: 8),
            Annotation(kind: .ellipse, start: CGPoint(x: 1478, y: 14), end: CGPoint(x: 1574, y: 78), color: RGBA(hex: 0x0A84FF), width: 7),
            Annotation(kind: .text, start: CGPoint(x: 770, y: 222), end: .zero, color: red, width: 8, text: "Invite your team"),
            Annotation(kind: .arrow, start: CGPoint(x: 1100, y: 256), end: CGPoint(x: 1286, y: 198), color: red, width: 9),
            Annotation(kind: .step, start: CGPoint(x: 52, y: 232), end: .zero, color: red, width: 8),
            Annotation(kind: .step, start: CGPoint(x: 1300, y: 428), end: .zero, color: red, width: 8),
            Annotation(kind: .step, start: CGPoint(x: 390, y: 864), end: .zero, color: red, width: 8),
        ]
        board.selection = board.annotations[8].id
        board.tool = .arrow
        return board
    }

    static func screenshot() -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        func fill(_ r: CGRect, _ hex: UInt32, radius: CGFloat = 0) {
            cg.setFillColor(rgb(hex).cgColor)
            cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.fillPath()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight, _ hex: UInt32) {
            Renderer.withAppKit(cg) {
                (s as NSString).draw(at: CGPoint(x: x, y: y),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: rgb(hex)])
            }
        }
        // Page, top bar and sidebar.
        fill(CGRect(x: 0, y: 0, width: w, height: h), 0xFFFFFF)
        fill(CGRect(x: 0, y: 0, width: w, height: 92), 0xFBFBFD)
        fill(CGRect(x: 0, y: 92, width: w, height: 2), 0xE8E8ED)
        fill(CGRect(x: 36, y: 26, width: 40, height: 40), 0x5E5CE6, radius: 11)
        text("Acme Cloud", 92, 28, 28, .bold, 0x1D1D1F)
        for (i, item) in ["Overview", "Projects", "Billing", "Team"].enumerated() {
            text(item, 470 + CGFloat(i) * 150, 31, 24, i == 3 ? .semibold : .regular, i == 3 ? 0x1D1D1F : 0x86868B)
        }
        fill(CGRect(x: 1500, y: 20, width: 52, height: 52), 0xFF9F0A, radius: 26)
        text("DP", 1508, 32, 22, .bold, 0xFFFFFF)
        fill(CGRect(x: 0, y: 94, width: 300, height: h - 94), 0xF5F5F7)
        fill(CGRect(x: 300, y: 94, width: 2, height: h - 94), 0xE8E8ED)
        for (i, item) in ["General", "Members", "Billing", "Security", "Integrations", "API keys"].enumerated() {
            let y = 130 + CGFloat(i) * 70
            if i == 1 { fill(CGRect(x: 86, y: y - 10, width: 196, height: 56), 0x0071E3, radius: 12) }
            fill(CGRect(x: 102, y: y + 8, width: 20, height: 20), i == 1 ? 0xFFFFFF : 0xC7C7CC, radius: 6)
            text(item, 136, y, 24, i == 1 ? .semibold : .regular, i == 1 ? 0xFFFFFF : 0x3A3A3C)
        }
        // Heading and the primary button.
        text("Members", 344, 132, 46, .bold, 0x1D1D1F)
        text("People with access to Acme Cloud.", 346, 196, 24, .regular, 0x86868B)
        fill(CGRect(x: 1300, y: 150, width: 256, height: 66), 0x0071E3, radius: 14)
        text("Invite member", 1346, 167, 26, .semibold, 0xFFFFFF)
        // Members card.
        fill(CGRect(x: 342, y: 292, width: 1216, height: 448), 0xE8E8ED, radius: 20)
        fill(CGRect(x: 344, y: 294, width: 1212, height: 444), 0xFFFFFF, radius: 19)
        let people: [(String, String, String, UInt32)] = [
            ("Maria Kitri", "maria@acme.cloud", "Owner", 0xFF375F),
            ("Nikos Pappas", "nikos.p@acme.cloud", "Admin", 0x30B0C7),
            ("Eleni Vlachou", "eleni@acme.cloud", "Member", 0x34C759),
            ("George Lamb", "g.lamb@acme.cloud", "Member", 0xAF52DE),
        ]
        for (i, p) in people.enumerated() {
            let y = 294 + CGFloat(i) * 111
            if i > 0 { fill(CGRect(x: 376, y: y, width: 1148, height: 2), 0xF0F0F3) }
            fill(CGRect(x: 380, y: y + 26, width: 60, height: 60), p.3, radius: 30)
            text(String(p.0.prefix(1)), 398, y + 38, 28, .bold, 0xFFFFFF)
            text(p.0, 466, y + 38, 27, .semibold, 0x1D1D1F)
            text(p.1, 724, y + 38, 26, .regular, 0x6E6E73)
            fill(CGRect(x: 1110, y: y + 34, width: 136, height: 44), i == 1 ? 0xE5F1FF : 0xF2F2F7, radius: 22)
            text(p.2, 1132, y + 41, 22, .medium, i == 1 ? 0x0071E3 : 0x3A3A3C)
            for d in 0..<3 { fill(CGRect(x: 1470 + CGFloat(d) * 14, y: y + 53, width: 8, height: 8), 0xAEAEB2, radius: 4) }
        }
        // Pending invitations.
        fill(CGRect(x: 342, y: 790, width: 1216, height: 150), 0xF5F5F7, radius: 20)
        text("Pending invitations · 2", 440, 846, 26, .semibold, 0x1D1D1F)
        text("Resend", 1430, 848, 24, .medium, 0x0071E3)
        return cg.makeImage()!
    }
}
