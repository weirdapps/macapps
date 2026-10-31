import AppKit

// Shared drawing helpers for app icons, on the macOS icon grid: an 824 px rounded tile in a 1024 px canvas.
// Each app draws its own icon and writes it with `<App> --icon out.png` (see `IconKit.handleCommandLine`).

public let iconSize: CGFloat = 1024
public let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
public let tileRadius: CGFloat = 186

public func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

public func gradient(_ colors: [NSColor], from: CGPoint, to: CGPoint, in ctx: CGContext) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

public func radial(_ colors: [NSColor], center: CGPoint, radius: CGFloat, in ctx: CGContext) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

public func shadow(_ ctx: CGContext, y: CGFloat = -10, blur: CGFloat = 24, alpha: CGFloat = 0.3) {
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
}

public func roundedRect(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// The tile: background gradient, top sheen and hairline edge. `art` draws inside, clipped to the tile.
public func render(_ top: UInt32, _ bottom: UInt32, art: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(iconSize), pixelsHigh: Int(iconSize), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let path = roundedRect(tile, tileRadius)

    ctx.saveGState()
    shadow(ctx, y: -12, blur: 28, alpha: 0.32)
    ctx.addPath(path)
    ctx.setFillColor(rgb(bottom).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    gradient([rgb(top), rgb(bottom)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY), in: ctx)
    art(ctx)
    // Sheen across the upper half.
    gradient([NSColor.white.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0)],
             from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.midY), in: ctx)
    ctx.restoreGState()

    ctx.addPath(roundedRect(tile.insetBy(dx: 1, dy: 1), tileRadius - 1))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

public func sparkle(_ ctx: CGContext, at p: CGPoint, size s: CGFloat, color: NSColor) {
    ctx.move(to: CGPoint(x: p.x, y: p.y + s))
    ctx.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: CGPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: CGPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: CGPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: CGPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}


public enum IconKit {
    /// If launched with `--icon <path>`, draws the icon to that PNG and exits before the app starts.
    public static func handleCommandLine(draw: () -> NSBitmapImageRep) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--icon"), i + 1 < args.count else { return }
        let png = draw().representation(using: .png, properties: [:])!
        try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        exit(0)
    }
}
