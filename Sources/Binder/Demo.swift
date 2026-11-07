import AppKit
import PDFKit

// Fixed demo documents for the website snapshot, drawn in code so no real file is read.

enum DemoPDF {
    enum Kind { case letter, report }

    /// A PDF of `pages` US Letter pages that look like a real document of `kind`.
    static func document(_ kind: Kind, title: String, pages: Int) -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return PDFDocument() }
        for n in 0..<pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            switch kind {
            case .letter: letterPage(ctx, title: title, page: n, of: pages)
            case .report: reportPage(ctx, title: title, page: n)
            }
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return PDFDocument(data: data as Data) ?? PDFDocument()
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .black) {
        (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    private static func paragraph(_ ctx: CGContext, top: CGFloat, lines: Int, seed: Int) {
        for i in 0..<lines {
            let last = i == lines - 1
            let w: CGFloat = last ? CGFloat(180 + (seed * 37 + i * 53) % 200) : CGFloat(470 - (seed * 13 + i * 29) % 40)
            ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 72, y: top - CGFloat(i) * 15, width: w, height: 6))
        }
    }

    private static func letterPage(_ ctx: CGContext, title: String, page: Int, of total: Int) {
        if page == 0 {
            text(title.uppercased(), at: CGPoint(x: 72, y: 700), size: 22, weight: .bold, color: NSColor(white: 0.15, alpha: 1))
            ctx.setFillColor(NSColor(srgbRed: 0.2, green: 0.45, blue: 0.9, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 72, y: 688, width: 80, height: 3))
        }
        var top: CGFloat = page == 0 ? 650 : 720
        var seed = page * 7
        while top > 140 {
            let lines = 3 + seed % 4
            paragraph(ctx, top: top, lines: lines, seed: seed)
            top -= CGFloat(lines) * 15 + 26
            seed += 1
        }
        if page == total - 1 {
            ctx.setFillColor(NSColor(white: 1, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 60, y: 60, width: 500, height: 200))
            for x in [72.0, 340.0] {
                ctx.setStrokeColor(NSColor(white: 0.3, alpha: 1).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: x, y: 120)); ctx.addLine(to: CGPoint(x: x + 200, y: 120)); ctx.strokePath()
                ctx.setFillColor(NSColor(white: 0.62, alpha: 1).cgColor)
                ctx.fill(CGRect(x: x, y: 100, width: 90, height: 6))
            }
            // A signature scribble.
            ctx.setStrokeColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.55, alpha: 1).cgColor)
            ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: 90, y: 128))
            ctx.addCurve(to: CGPoint(x: 150, y: 140), control1: CGPoint(x: 100, y: 175), control2: CGPoint(x: 120, y: 100))
            ctx.addCurve(to: CGPoint(x: 230, y: 132), control1: CGPoint(x: 175, y: 170), control2: CGPoint(x: 190, y: 110))
            ctx.strokePath()
        }
        text("\(page + 1)", at: CGPoint(x: 300, y: 40), size: 10, color: NSColor(white: 0.4, alpha: 1))
    }

    private static func reportPage(_ ctx: CGContext, title: String, page: Int) {
        let accent = NSColor(srgbRed: 0.96, green: 0.58, blue: 0.10, alpha: 1)
        ctx.setFillColor(accent.cgColor)
        ctx.fill(CGRect(x: 0, y: 742, width: 612, height: 50))
        text(page == 0 ? title : "\(title), section \(page + 1)", at: CGPoint(x: 40, y: 756), size: 17, weight: .semibold, color: .white)
        switch page % 3 {
        case 0:
            // Bar chart.
            let heights: [CGFloat] = [120, 180, 150, 230, 200, 280, 260]
            for (i, h) in heights.enumerated() {
                ctx.setFillColor((i == 5 ? accent : NSColor(white: 0.78, alpha: 1)).cgColor)
                ctx.fill(CGRect(x: 72 + CGFloat(i) * 68, y: 420, width: 44, height: h))
            }
            ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 60, y: 418, width: 492, height: 1.5))
            paragraph(ctx, top: 360, lines: 5, seed: 3)
            paragraph(ctx, top: 260, lines: 4, seed: 5)
        case 1:
            // Table.
            for r in 0..<14 {
                let y = 680 - CGFloat(r) * 32
                if r == 0 { ctx.setFillColor(NSColor(white: 0.88, alpha: 1).cgColor); ctx.fill(CGRect(x: 60, y: y - 8, width: 492, height: 30)) }
                for c in 0..<4 {
                    ctx.setFillColor(NSColor(white: r == 0 ? 0.35 : 0.62, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: 72 + CGFloat(c) * 122, y: y, width: CGFloat(60 + (r * 17 + c * 23) % 40), height: 6))
                }
                ctx.setFillColor(NSColor(white: 0.9, alpha: 1).cgColor)
                ctx.fill(CGRect(x: 60, y: y - 10, width: 492, height: 1))
            }
            paragraph(ctx, top: 200, lines: 4, seed: 9)
        default:
            // Photo and notes.
            ctx.setFillColor(NSColor(srgbRed: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 72, y: 470, width: 468, height: 240))
            ctx.setFillColor(NSColor(srgbRed: 0.45, green: 0.62, blue: 0.42, alpha: 1).cgColor)
            ctx.move(to: CGPoint(x: 72, y: 470)); ctx.addLine(to: CGPoint(x: 230, y: 610)); ctx.addLine(to: CGPoint(x: 330, y: 540))
            ctx.addLine(to: CGPoint(x: 420, y: 640)); ctx.addLine(to: CGPoint(x: 540, y: 520)); ctx.addLine(to: CGPoint(x: 540, y: 470))
            ctx.fillPath()
            ctx.setFillColor(NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: 450, y: 640, width: 40, height: 40))
            paragraph(ctx, top: 430, lines: 6, seed: 2)
            paragraph(ctx, top: 310, lines: 5, seed: 4)
        }
    }

    /// A landscape floor plan, as an image.
    static func floorPlan() -> NSImage {
        NSImage(size: NSSize(width: 1100, height: 780), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let ink = NSColor(srgbRed: 0.18, green: 0.32, blue: 0.55, alpha: 1)
            ink.setStroke()
            let outer = NSBezierPath(rect: rect.insetBy(dx: 80, dy: 80)); outer.lineWidth = 14; outer.stroke()
            for (a, b) in [((80.0, 400.0), (620.0, 400.0)), ((620.0, 80.0), (620.0, 700.0)), ((620.0, 300.0), (1020.0, 300.0)),
                           ((350.0, 400.0), (350.0, 700.0))] {
                let p = NSBezierPath(); p.move(to: NSPoint(x: a.0, y: a.1)); p.line(to: NSPoint(x: b.0, y: b.1)); p.lineWidth = 8; p.stroke()
            }
            NSColor(srgbRed: 0.18, green: 0.32, blue: 0.55, alpha: 0.08).setFill()
            NSBezierPath(rect: NSRect(x: 627, y: 307, width: 386, height: 386)).fill()
            for (x, y) in [(200.0, 230.0), (480.0, 540.0), (820.0, 190.0), (210.0, 560.0), (820.0, 500.0)] {
                ink.withAlphaComponent(0.5).setFill()
                NSBezierPath(roundedRect: NSRect(x: x - 50, y: y - 8, width: 100, height: 16), xRadius: 8, yRadius: 8).fill()
            }
            return true
        }
    }
}

extension BinderModel {
    /// Three files, one page deleted and two selected, with every thumbnail rendered.
    static var demo: BinderModel {
        let model = BinderModel()
        let lease = Source(name: "Lease agreement", url: nil, document: DemoPDF.document(.letter, title: "Lease agreement", pages: 4),
                           tint: 1, bytes: 386_000, isImage: false)
        let plan = DemoPDF.floorPlan()
        let planDoc = PDFDocument()
        if let page = Binder.imagePage(plan) { planDoc.insert(page, at: 0) }
        let floor = Source(name: "Floor plan", url: nil, document: planDoc, tint: 3, bytes: 1_240_000, isImage: true)
        let report = Source(name: "Inspection report", url: nil, document: DemoPDF.document(.report, title: "Inspection report", pages: 4),
                            tint: 2, bytes: 2_150_000, isImage: false)
        model.add([lease, floor, report])
        // Drop the report's last page, and select the floor plan and the first report page.
        let reportPages = model.pages.filter { $0.sourceID == report.id }
        model.delete(ids: [reportPages[3].id])
        let floorPage = model.pages.first { $0.sourceID == floor.id }!
        model.selection = [floorPage.id, reportPages[0].id]
        model.tileSize = 158
        model.demoHover = model.pages[2].id
        model.renderAllThumbnails()
        return model
    }
}
