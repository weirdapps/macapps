import AppKit
import CoreGraphics

// Procedural illustrations for the website snapshot and the self test, so neither needs a real photo.

enum DemoScene: CaseIterable {
    case sunset, forest, lagoon

    var name: String {
        switch self {
        case .sunset: "Sunset over the bay.jpg"
        case .forest: "Pine ridge.heic"
        case .lagoon: "Lagoon at noon.png"
        }
    }

    func image(width: Int = 1200, height: Int = 820) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        switch self {
        case .sunset: Self.sunset(ctx, w, h)
        case .forest: Self.forest(ctx, w, h)
        case .lagoon: Self.lagoon(ctx, w, h)
        }
        return ctx.makeImage()!
    }

    private static func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private static func vertical(_ ctx: CGContext, _ colors: [UInt32], _ locations: [CGFloat], top: CGFloat, bottom: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map { c($0) } as CFArray, locations: locations)!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    }

    /// A ridge line through `points` (x, y in 0...1 of the width and height), filled down to the bottom.
    private static func ridge(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat, _ points: [(CGFloat, CGFloat)], _ color: CGColor) {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: points[0].1 * h))
        for i in 1..<points.count {
            let p0 = points[i - 1], p1 = points[i]
            let mid = CGPoint(x: (p0.0 + p1.0) / 2 * w, y: (p0.1 + p1.1) / 2 * h)
            ctx.addQuadCurve(to: mid, control: CGPoint(x: p0.0 * w, y: p0.1 * h))
        }
        ctx.addLine(to: CGPoint(x: points.last!.0 * w, y: points.last!.1 * h))
        ctx.addLine(to: CGPoint(x: w, y: 0))
        ctx.closePath()
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private static func sunset(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        let horizon = h * 0.36
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon, width: w, height: h - horizon))
        vertical(ctx, [0x2E1F55, 0x7A3A6E, 0xD9604A, 0xF6A24E, 0xFAD27A], [0, 0.3, 0.62, 0.85, 1], top: h, bottom: horizon)
        ctx.restoreGState()
        // Sun with a soft glow.
        let sun = CGPoint(x: w * 0.62, y: horizon + h * 0.13)
        let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [c(0xFFE7A8, 0.85), c(0xFFC870, 0)] as CFArray, locations: nil)!
        ctx.drawRadialGradient(glow, startCenter: sun, startRadius: 0, endCenter: sun, endRadius: h * 0.36, options: [])
        ctx.setFillColor(c(0xFFF0C4))
        ctx.fillEllipse(in: CGRect(x: sun.x - h * 0.085, y: sun.y - h * 0.085, width: h * 0.17, height: h * 0.17))
        ridge(ctx, w, h, [(0, 0.47), (0.12, 0.55), (0.25, 0.48), (0.4, 0.58), (0.52, 0.45), (0.7, 0.42), (0.85, 0.51), (1, 0.44)], c(0x8B4A72))
        ridge(ctx, w, h, [(0, 0.41), (0.15, 0.46), (0.3, 0.4), (0.45, 0.43), (0.6, 0.38), (0.78, 0.44), (0.9, 0.4), (1, 0.42)], c(0x553060))
        // Sea.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: horizon))
        vertical(ctx, [0x3A3F78, 0x22305A, 0x141D3A], [0, 0.5, 1], top: horizon, bottom: 0)
        ctx.restoreGState()
        // Sun reflection: short horizontal strokes narrowing towards the viewer.
        for i in 0..<16 {
            let t = CGFloat(i) / 15
            let y = horizon - 8 - t * horizon * 0.8
            let half = (1 - t * 0.6) * h * 0.09 * (i % 2 == 0 ? 1 : 0.6)
            ctx.setFillColor(c(i % 3 == 0 ? 0xFAD27A : 0xF29A55, 0.85 - t * 0.4))
            ctx.fill(CGRect(x: sun.x - half, y: y, width: half * 2, height: 5))
        }
        // Foreground shore.
        ridge(ctx, w, h, [(0, 0.2), (0.12, 0.17), (0.28, 0.1), (0.45, 0.04), (0.6, 0), (1, 0)], c(0x1E1630))
    }

    private static func forest(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        vertical(ctx, [0xCFE8DA, 0xEAF3DC, 0xF5EBC8], [0, 0.6, 1], top: h, bottom: h * 0.3)
        ridge(ctx, w, h, [(0, 0.55), (0.2, 0.62), (0.4, 0.52), (0.6, 0.6), (0.8, 0.5), (1, 0.58)], c(0x9CC3A6))
        ridge(ctx, w, h, [(0, 0.45), (0.25, 0.5), (0.5, 0.42), (0.75, 0.48), (1, 0.4)], c(0x5E9475))
        for i in 0..<22 {
            let x = CGFloat(i) / 21 * w + CGFloat((i * 37) % 23) - 11
            let base = h * (0.12 + CGFloat((i * 13) % 7) / 60)
            let tall = h * (0.32 + CGFloat((i * 29) % 9) / 40)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: base + tall))
            ctx.addLine(to: CGPoint(x: x - tall * 0.2, y: base))
            ctx.addLine(to: CGPoint(x: x + tall * 0.2, y: base))
            ctx.closePath()
            ctx.setFillColor(c(i % 2 == 0 ? 0x2F5D45 : 0x23473A))
            ctx.fillPath()
        }
        ridge(ctx, w, h, [(0, 0.16), (0.3, 0.12), (0.6, 0.17), (1, 0.1)], c(0x7A5B3A))
    }

    private static func lagoon(_ ctx: CGContext, _ w: CGFloat, _ h: CGFloat) {
        vertical(ctx, [0x7CC8F0, 0xC9ECF7], [0, 1], top: h, bottom: h * 0.55)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h * 0.56))
        vertical(ctx, [0x1E8FA8, 0x3FC6C0, 0x9BE3D0], [0, 0.6, 1], top: h * 0.56, bottom: h * 0.1)
        ctx.restoreGState()
        ridge(ctx, w, h, [(0, 0.22), (0.3, 0.16), (0.6, 0.08), (1, 0.05)], c(0xF2DDB0))
        ridge(ctx, w, h, [(0, 0.08), (0.5, 0.03), (1, 0)], c(0xE8C88E))
        ctx.setFillColor(c(0xFFFFFF, 0.9))
        ctx.fillEllipse(in: CGRect(x: w * 0.15, y: h * 0.78, width: w * 0.18, height: h * 0.07))
        ctx.fillEllipse(in: CGRect(x: w * 0.6, y: h * 0.84, width: w * 0.22, height: h * 0.06))
    }
}
