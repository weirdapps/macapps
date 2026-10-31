import AppKit

// Draws each app's 1024 px icon on the macOS icon grid: an 824 px rounded square with a soft drop shadow.
// Usage: IconGen <output directory>

let size: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ colors: [NSColor], from: CGPoint, to: CGPoint, in ctx: CGContext) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func radial(_ colors: [NSColor], center: CGPoint, radius: CGFloat, in ctx: CGContext) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors.map(\.cgColor) as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

func shadow(_ ctx: CGContext, y: CGFloat = -10, blur: CGFloat = 24, alpha: CGFloat = 0.3) {
    ctx.setShadow(offset: CGSize(width: 0, height: y), blur: blur, color: NSColor.black.withAlphaComponent(alpha).cgColor)
}

func roundedRect(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// The tile: background gradient, top sheen and hairline edge. `art` draws inside, clipped to the tile.
func render(_ top: UInt32, _ bottom: UInt32, art: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let path = roundedRect(tile, radius)

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

    ctx.addPath(roundedRect(tile.insetBy(dx: 1, dy: 1), radius - 1))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Jot: a ruled note card and a pencil

func jot() -> NSBitmapImageRep {
    render(0xFFD84F, 0xFF9500) { ctx in
        ctx.saveGState()
        ctx.translateBy(x: 470, y: 520)
        ctx.rotate(by: 6 * .pi / 180)
        let card = CGRect(x: -250, y: -290, width: 500, height: 580)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.28)
        ctx.addPath(roundedRect(card, 44))
        ctx.setFillColor(rgb(0xFFFDF4).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(roundedRect(card, 44))
        ctx.clip()
        // Header band.
        ctx.setFillColor(rgb(0xFFF1C9).cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.maxY - 110, width: card.width, height: 110))
        // Ruled lines and the margin.
        ctx.setStrokeColor(rgb(0xBFD7F2).cgColor)
        ctx.setLineWidth(5)
        for i in 0..<7 {
            let y = card.maxY - 160 - CGFloat(i) * 62
            ctx.move(to: CGPoint(x: card.minX, y: y)); ctx.addLine(to: CGPoint(x: card.maxX, y: y))
        }
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0xFF8A80).cgColor)
        ctx.move(to: CGPoint(x: card.minX + 88, y: card.minY)); ctx.addLine(to: CGPoint(x: card.minX + 88, y: card.maxY))
        ctx.strokePath()
        // Handwriting, as soft strokes.
        ctx.setStrokeColor(rgb(0x5B6B82, 0.75).cgColor)
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        for (i, w) in [300.0, 240, 330, 170].enumerated() {
            let y = card.maxY - 160 - CGFloat(i) * 62 + 22
            ctx.move(to: CGPoint(x: card.minX + 120, y: y)); ctx.addLine(to: CGPoint(x: card.minX + 120 + w, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // Pencil, laid diagonally across the lower right, drawn as one shadowed layer.
        ctx.saveGState()
        ctx.translateBy(x: 610, y: 380)
        ctx.rotate(by: 40 * .pi / 180)
        shadow(ctx, y: -14, blur: 24, alpha: 0.35)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(roundedRect(CGRect(x: -370, y: -42, width: 90, height: 84), 26))
        ctx.setFillColor(rgb(0xFF7AA2).cgColor)
        ctx.fillPath()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: -300, y: -42, width: 72, height: 84))
        gradient([rgb(0xF2F4F7), rgb(0x9AA4B1)], from: CGPoint(x: 0, y: 42), to: CGPoint(x: 0, y: -42), in: ctx)
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x3A7BFF).cgColor)
        ctx.fill(CGRect(x: -230, y: -42, width: 360, height: 84))
        ctx.setFillColor(rgb(0x6FA0FF).cgColor)
        ctx.fill(CGRect(x: -230, y: 6, width: 360, height: 22))
        ctx.setFillColor(rgb(0x2A5FD6).cgColor)
        ctx.fill(CGRect(x: -230, y: -42, width: 360, height: 18))
        // Sharpened wood and graphite tip.
        ctx.move(to: CGPoint(x: 130, y: 42)); ctx.addLine(to: CGPoint(x: 250, y: 0)); ctx.addLine(to: CGPoint(x: 130, y: -42))
        ctx.closePath()
        ctx.setFillColor(rgb(0xF5CFA0).cgColor)
        ctx.fillPath()
        ctx.move(to: CGPoint(x: 210, y: 14)); ctx.addLine(to: CGPoint(x: 250, y: 0)); ctx.addLine(to: CGPoint(x: 210, y: -14))
        ctx.closePath()
        ctx.setFillColor(rgb(0x2B2F36).cgColor)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

// MARK: - Meridian: a globe with meridians, half in night

func meridian() -> NSBitmapImageRep {
    render(0x0E1B4D, 0x3149B8) { ctx in
        // Stars.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        for (x, y, r) in [(220.0, 800.0, 5.0), (300, 870, 3), (790, 830, 4), (850, 740, 3), (180, 660, 3), (760, 210, 3), (240, 230, 4)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        let c = CGPoint(x: 512, y: 500), r: CGFloat = 300
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        // Glow.
        radial([rgb(0x7FD3FF, 0.45), rgb(0x7FD3FF, 0)], center: c, radius: r + 90, in: ctx)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.4)
        ctx.setFillColor(rgb(0x1E88E5).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        radial([rgb(0x8EE0FF), rgb(0x2E9BF0), rgb(0x1258C9)], center: CGPoint(x: c.x - 110, y: c.y + 120), radius: r * 1.5, in: ctx)
        // Meridians and parallels.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(9)
        for w in [0.0, 0.42, 0.78] {
            let half = r * CGFloat(w)
            ctx.strokeEllipse(in: CGRect(x: c.x - half, y: c.y - r, width: half * 2, height: r * 2))
        }
        ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r)); ctx.strokePath()
        for f in [-0.55, 0.0, 0.55] {
            let y = c.y + r * CGFloat(f)
            ctx.move(to: CGPoint(x: c.x - r, y: y)); ctx.addLine(to: CGPoint(x: c.x + r, y: y))
        }
        ctx.strokePath()
        // The night side, with a soft terminator.
        gradient([rgb(0x050A2A, 0), rgb(0x050A2A, 0), rgb(0x050A2A, 0.62)],
                 from: CGPoint(x: c.x - 40, y: c.y + 60), to: CGPoint(x: c.x + r, y: c.y - 40), in: ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: disc.insetBy(dx: -18, dy: -18))
        // Sun.
        let s = CGPoint(x: 760, y: 760)
        radial([rgb(0xFFE08A, 0.9), rgb(0xFFB547, 0.4), rgb(0xFFB547, 0)], center: s, radius: 150, in: ctx)
        ctx.setFillColor(rgb(0xFFF4CF).cgColor)
        ctx.fillEllipse(in: CGRect(x: s.x - 58, y: s.y - 58, width: 116, height: 116))
    }
}

// MARK: - Hush: a studio microphone with a slash

func hush() -> NSBitmapImageRep {
    render(0xFF6A6A, 0xD81B60) { ctx in
        let c = CGPoint(x: 512, y: 512)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(18)
        for r in [250.0, 340] { ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r + 30, width: r * 2, height: r * 2)) }

        ctx.saveGState()
        shadow(ctx, y: -14, blur: 26, alpha: 0.3)
        let head = CGRect(x: 412, y: 450, width: 200, height: 330)
        ctx.addPath(roundedRect(head, 100))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        // Holder arc, stem and base.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(40)
        ctx.setLineCap(.round)
        ctx.addArc(center: CGPoint(x: 512, y: 560), radius: 165, startAngle: .pi * 0.02, endAngle: .pi * 0.98, clockwise: true)
        ctx.strokePath()
        ctx.move(to: CGPoint(x: 512, y: 395)); ctx.addLine(to: CGPoint(x: 512, y: 300)); ctx.strokePath()
        ctx.move(to: CGPoint(x: 410, y: 290)); ctx.addLine(to: CGPoint(x: 614, y: 290)); ctx.strokePath()
        ctx.restoreGState()
        // Grille.
        ctx.saveGState()
        ctx.addPath(roundedRect(head, 100))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xF1E3E8)], from: CGPoint(x: head.minX, y: 0), to: CGPoint(x: head.maxX, y: 0), in: ctx)
        ctx.setStrokeColor(rgb(0xE6C2CF).cgColor)
        ctx.setLineWidth(10)
        ctx.setLineCap(.round)
        for i in 0..<4 {
            let y = 690 - CGFloat(i) * 44
            ctx.move(to: CGPoint(x: 462, y: y)); ctx.addLine(to: CGPoint(x: 562, y: y))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // Slash, cut out from the background colour so it reads at small sizes.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0xEC3B6A).cgColor)
        ctx.setLineWidth(84)
        ctx.move(to: CGPoint(x: 300, y: 770)); ctx.addLine(to: CGPoint(x: 724, y: 260)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(42)
        ctx.move(to: CGPoint(x: 300, y: 770)); ctx.addLine(to: CGPoint(x: 724, y: 260)); ctx.strokePath()
    }
}

// MARK: - Plain: a clean page and sparkles

func sparkle(_ ctx: CGContext, at p: CGPoint, size s: CGFloat, color: NSColor) {
    ctx.move(to: CGPoint(x: p.x, y: p.y + s))
    ctx.addQuadCurve(to: CGPoint(x: p.x + s, y: p.y), control: CGPoint(x: p.x + s * 0.12, y: p.y + s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y - s), control: CGPoint(x: p.x + s * 0.12, y: p.y - s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x - s, y: p.y), control: CGPoint(x: p.x - s * 0.12, y: p.y - s * 0.12))
    ctx.addQuadCurve(to: CGPoint(x: p.x, y: p.y + s), control: CGPoint(x: p.x - s * 0.12, y: p.y + s * 0.12))
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

func plain() -> NSBitmapImageRep {
    render(0x3DDBA4, 0x0B7C8E) { ctx in
        let page = CGRect(x: 300, y: 230, width: 400, height: 520)
        let fold: CGFloat = 110
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: page.minX + 40, y: page.minY))
        outline.addLine(to: CGPoint(x: page.maxX - 40, y: page.minY))
        outline.addQuadCurve(to: CGPoint(x: page.maxX, y: page.minY + 40), control: CGPoint(x: page.maxX, y: page.minY))
        outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        outline.addLine(to: CGPoint(x: page.minX + 40, y: page.maxY))
        outline.addQuadCurve(to: CGPoint(x: page.minX, y: page.maxY - 40), control: CGPoint(x: page.minX, y: page.maxY))
        outline.addLine(to: CGPoint(x: page.minX, y: page.minY + 40))
        outline.addQuadCurve(to: CGPoint(x: page.minX + 40, y: page.minY), control: CGPoint(x: page.minX, y: page.minY))
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 34, alpha: 0.3)
        ctx.addPath(outline)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Folded corner.
        ctx.move(to: CGPoint(x: page.maxX, y: page.maxY - fold))
        ctx.addLine(to: CGPoint(x: page.maxX - fold + 18, y: page.maxY - fold))
        ctx.addQuadCurve(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold + 18), control: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
        ctx.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
        ctx.closePath()
        ctx.setFillColor(rgb(0xCFEFEA).cgColor)
        ctx.fillPath()
        // Plain text lines.
        ctx.setStrokeColor(rgb(0x9DB8BF).cgColor)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        for (i, w) in [220.0, 300, 270, 300, 190].enumerated() {
            let y = page.maxY - 170 - CGFloat(i) * 62
            ctx.move(to: CGPoint(x: page.minX + 60, y: y)); ctx.addLine(to: CGPoint(x: page.minX + 60 + w, y: y))
        }
        ctx.strokePath()
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 16, alpha: 0.18)
        sparkle(ctx, at: CGPoint(x: 735, y: 760), size: 92, color: rgb(0xFFF6C2))
        sparkle(ctx, at: CGPoint(x: 820, y: 620), size: 46, color: .white)
        sparkle(ctx, at: CGPoint(x: 230, y: 330), size: 52, color: rgb(0xFFF6C2))
        ctx.restoreGState()
    }
}

// MARK: - Tempo: a progress ring with a glowing knob

func tempo() -> NSBitmapImageRep {
    render(0xFF7E5F, 0xD12A6E) { ctx in
        let c = CGPoint(x: 512, y: 512), r: CGFloat = 255
        ctx.setLineCap(.round)
        // Hour ticks.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(14)
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            let inner: CGFloat = i % 3 == 0 ? 150 : 170
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 192, y: c.y + sin(a) * 192))
        }
        ctx.strokePath()
        // Track and progress.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(66)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 22, alpha: 0.25)
        ctx.setStrokeColor(NSColor.white.cgColor)
        let start = CGFloat.pi / 2, end = start - 0.72 * 2 * .pi
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
        // Knob at the end of the arc.
        let k = CGPoint(x: c.x + cos(end) * r, y: c.y + sin(end) * r)
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 18, alpha: 0.35)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: k.x - 52, y: k.y - 52, width: 104, height: 104))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xF0476A).cgColor)
        ctx.fillEllipse(in: CGRect(x: k.x - 22, y: k.y - 22, width: 44, height: 44))
        // Centre dot.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
    }
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icons")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, draw) in [("Jot", jot), ("Meridian", meridian), ("Hush", hush), ("Plain", plain), ("Tempo", tempo)] {
    let png = draw().representation(using: .png, properties: [:])!
    try png.write(to: out.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}
