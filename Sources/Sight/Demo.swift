import AppKit

/// A sample design drawn in code: a small analytics dashboard that leans on red, green, blue and amber,
/// the kind of screen that falls apart for many colour blind people. Used for the snapshot and Open Sample.
enum Demo {
    static let red = 0xE5484D as UInt32, green = 0x30A46C as UInt32, blue = 0x3E63DD as UInt32, amber = 0xF5A524 as UInt32

    static func image() -> CGImage {
        let w = 1600, h = 1000
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Draw top-down, like a screen.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(ctx, size: CGSize(width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    private static func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular,
                             color hex: UInt32 = 0x1C2024, align: NSTextAlignment = .left, width: CGFloat = 0) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color(hex))!,
            .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let height = str.size().height
        if width > 0 {
            str.draw(in: CGRect(x: p.x, y: p.y - height / 2, width: width, height: height))
        } else {
            str.draw(at: CGPoint(x: p.x, y: p.y - height / 2))
        }
    }

    private static func card(_ ctx: CGContext, _ rect: CGRect) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: color(0x0B1220, 0.08))
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 28, cornerHeight: 28, transform: nil))
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func draw(_ ctx: CGContext, size: CGSize) {
        ctx.setFillColor(color(0xF1F3F6))
        ctx.fill(CGRect(origin: .zero, size: size))

        // Header and legend.
        text("Revenue by region", at: CGPoint(x: 64, y: 78), size: 46, weight: .bold)
        text("Weekly, third quarter, in thousands", at: CGPoint(x: 66, y: 126), size: 24, color: 0x6B7280)
        let legend: [(String, UInt32)] = [("Europe", red), ("Americas", green), ("Asia", blue), ("Africa", amber)]
        var x: CGFloat = 900
        for (label, hex) in legend {
            ctx.setFillColor(color(hex))
            ctx.fillEllipse(in: CGRect(x: x, y: 88, width: 22, height: 22))
            text(label, at: CGPoint(x: x + 32, y: 99), size: 24, weight: .medium, color: 0x374151)
            x += 46 + CGFloat(label.count) * 14 + 24
        }

        // Line chart.
        let chart = CGRect(x: 60, y: 176, width: 940, height: 764)
        card(ctx, chart)
        let plot = CGRect(x: chart.minX + 90, y: chart.minY + 60, width: chart.width - 140, height: chart.height - 150)
        ctx.setStrokeColor(color(0xE5E7EB))
        ctx.setLineWidth(2)
        for i in 0...4 {
            let y = plot.minY + plot.height * CGFloat(i) / 4
            ctx.move(to: CGPoint(x: plot.minX, y: y))
            ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
            text("\(400 - i * 100)", at: CGPoint(x: chart.minX + 24, y: y), size: 20, color: 0x9CA3AF, align: .right, width: 50)
        }
        ctx.strokePath()
        for (i, week) in ["W1", "W3", "W5", "W7", "W9", "W11", "W13"].enumerated() {
            let px = plot.minX + plot.width * CGFloat(i) / 6
            text(week, at: CGPoint(x: px - 30, y: plot.maxY + 36), size: 20, color: 0x9CA3AF, align: .center, width: 60)
        }
        let series: [([CGFloat], UInt32)] = [
            ([0.62, 0.58, 0.66, 0.71, 0.64, 0.74, 0.82], red),
            ([0.48, 0.60, 0.57, 0.69, 0.72, 0.66, 0.78], green),
            ([0.30, 0.34, 0.41, 0.38, 0.47, 0.52, 0.56], blue),
            ([0.16, 0.22, 0.19, 0.27, 0.31, 0.29, 0.37], amber),
        ]
        for (values, hex) in series {
            let points = values.enumerated().map { i, v in
                CGPoint(x: plot.minX + plot.width * CGFloat(i) / 6, y: plot.maxY - plot.height * v)
            }
            ctx.setStrokeColor(color(hex))
            ctx.setLineWidth(7)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addLines(between: points)
            ctx.strokePath()
            for p in points {
                ctx.setFillColor(color(0xFFFFFF))
                ctx.fillEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
                ctx.setStrokeColor(color(hex))
                ctx.setLineWidth(5)
                ctx.strokeEllipse(in: CGRect(x: p.x - 10, y: p.y - 10, width: 20, height: 20))
            }
        }

        // Donut.
        let donutCard = CGRect(x: 1040, y: 176, width: 500, height: 372)
        card(ctx, donutCard)
        text("Share", at: CGPoint(x: donutCard.minX + 36, y: donutCard.minY + 48), size: 26, weight: .semibold)
        let center = CGPoint(x: donutCard.minX + 170, y: donutCard.midY + 26)
        var angle = -CGFloat.pi / 2
        let shares: [(CGFloat, UInt32)] = [(0.36, red), (0.31, green), (0.21, blue), (0.12, amber)]
        for (share, hex) in shares {
            let end = angle + share * 2 * .pi
            ctx.setStrokeColor(color(hex))
            ctx.setLineWidth(46)
            ctx.setLineCap(.butt)
            ctx.addArc(center: center, radius: 104, startAngle: angle + 0.02, endAngle: end - 0.02, clockwise: false)
            ctx.strokePath()
            angle = end
        }
        text("4.2M", at: CGPoint(x: center.x - 80, y: center.y), size: 36, weight: .bold, align: .center, width: 160)
        for (i, (share, hex)) in shares.enumerated() {
            let y = donutCard.minY + 140 + CGFloat(i) * 52
            ctx.setFillColor(color(hex))
            ctx.addPath(CGPath(roundedRect: CGRect(x: donutCard.minX + 330, y: y - 9, width: 18, height: 18),
                               cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            text("\(Int(share * 100))%", at: CGPoint(x: donutCard.minX + 362, y: y), size: 24, weight: .semibold, color: 0x374151)
        }

        // Service status pills.
        let statusCard = CGRect(x: 1040, y: 584, width: 500, height: 356)
        card(ctx, statusCard)
        text("Services", at: CGPoint(x: statusCard.minX + 36, y: statusCard.minY + 48), size: 26, weight: .semibold)
        let rows: [(String, String, UInt32)] = [
            ("Payments", "Healthy", green), ("Checkout", "Down", red), ("Search", "Degraded", amber), ("Sign in", "Healthy", green),
        ]
        for (i, (service, state, hex)) in rows.enumerated() {
            let y = statusCard.minY + 118 + CGFloat(i) * 62
            text(service, at: CGPoint(x: statusCard.minX + 36, y: y), size: 24, color: 0x374151)
            let pill = CGRect(x: statusCard.maxX - 196, y: y - 21, width: 160, height: 42)
            ctx.setFillColor(color(hex, 0.16))
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 21, cornerHeight: 21, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(color(hex))
            ctx.fillEllipse(in: CGRect(x: pill.minX + 16, y: pill.midY - 7, width: 14, height: 14))
            text(state, at: CGPoint(x: pill.minX + 38, y: pill.midY), size: 21, weight: .semibold, color: hex)
        }
    }
}
