import AppKit
import SwiftUI

/// The byte grid: offset, 16 hex bytes and their ASCII per row. Only the visible rows are ever drawn, and the scroll
/// position is kept in this view (not a giant document view), so a 10 GB file scrolls like a 10 KB one.
final class HexView: NSView, NSMenuItemValidation {
    let model: HexModel
    private let scroller = NSScroller()
    private var scrollY: Double = 0
    private var lastReveal = -1
    private var lastFocus = -1
    private var pendingReveal = false
    private var dragTimer: Timer?
    private var lastDragPoint: NSPoint = .zero

    enum Metrics {
        static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        static let headerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        static let charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        static let rowHeight: CGFloat = 20
        static let headerHeight: CGFloat = 26
        static let gap: CGFloat = 22
    }

    init(model: HexModel) {
        self.model = model
        super.init(frame: .zero)
        scroller.scrollerStyle = .overlay
        scroller.knobStyle = .default
        scroller.target = self
        scroller.action = #selector(scrolled)
        addSubview(scroller)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
        model.window = window
    }

    /// Called by SwiftUI whenever the model changes.
    func refresh() {
        if model.revealToken != lastReveal {
            lastReveal = model.revealToken
            reveal(model.cursor, center: true)
        }
        if model.focusToken != lastFocus {
            lastFocus = model.focusToken
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }
        }
        updateScroller()
        needsDisplay = true
    }

    // MARK: Geometry

    private var cw: CGFloat { Metrics.charWidth }
    private var rows: Int { (model.count + 15) / 16 }
    private var digits: Int { HexFormat.offsetDigits(forCount: model.count) }
    private var visibleHeight: Double { Double(bounds.height - Metrics.headerHeight) }
    private var contentHeight: Double { Double(rows) * Double(Metrics.rowHeight) + 8 }
    private var maxScroll: Double { max(0, contentHeight - visibleHeight) }
    private var hexWidth: CGFloat { cw * 48 }
    private var contentWidth: CGFloat { CGFloat(digits) * cw + Metrics.gap + hexWidth + Metrics.gap + 16 * cw }
    private var originX: CGFloat { max(18, floor((bounds.width - contentWidth) / 2)) }
    private var hexX: CGFloat { originX + CGFloat(digits) * cw + Metrics.gap }
    private var asciiX: CGFloat { hexX + hexWidth + Metrics.gap }

    /// The x of byte column `i` (0...15) in the hex area; an extra space splits the row into two groups of 8.
    private func byteX(_ i: Int) -> CGFloat { hexX + CGFloat(i * 3 + (i >= 8 ? 1 : 0)) * cw }
    private func rowY(_ row: Int) -> CGFloat {
        Metrics.headerHeight + CGFloat(Double(row) * Double(Metrics.rowHeight) - scrollY) + 4
    }

    override func layout() {
        super.layout()
        let w = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        scroller.frame = NSRect(x: bounds.width - w, y: Metrics.headerHeight, width: w,
                                height: max(0, bounds.height - Metrics.headerHeight))
        setScroll(scrollY)
        if pendingReveal, bounds.height > Metrics.headerHeight {
            pendingReveal = false
            reveal(model.cursor, center: true)
        }
    }

    private func setScroll(_ y: Double) {
        scrollY = min(max(0, y), maxScroll)
        updateScroller()
        needsDisplay = true
    }

    private func updateScroller() {
        scroller.isHidden = maxScroll <= 0
        scroller.knobProportion = CGFloat(min(1, visibleHeight / max(1, contentHeight)))
        scroller.doubleValue = maxScroll > 0 ? scrollY / maxScroll : 0
    }

    @objc private func scrolled() {
        switch scroller.hitPart {
        case .knob, .knobSlot: setScroll(scroller.doubleValue * maxScroll)
        case .decrementPage: setScroll(scrollY - visibleHeight)
        case .incrementPage: setScroll(scrollY + visibleHeight)
        default: break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * Metrics.rowHeight * 3
        setScroll(scrollY - Double(dy))
    }

    /// Scrolls so byte `i` is visible; a far jump puts it a third of the way down.
    func reveal(_ i: Int, center: Bool) {
        guard model.hasBytes else { setScroll(0); return }
        guard bounds.height > Metrics.headerHeight else { pendingReveal = true; return }
        let rowTop = Double(i / 16) * Double(Metrics.rowHeight)
        let rowBottom = rowTop + Double(Metrics.rowHeight) + 8
        if rowTop >= scrollY && rowBottom <= scrollY + visibleHeight { return }
        if center {
            setScroll(rowTop - visibleHeight / 3)
        } else if rowTop < scrollY {
            setScroll(rowTop)
        } else {
            setScroll(rowBottom - visibleHeight)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard let source = model.source, model.hasBytes else { return }
        let count = source.count
        let first = max(0, Int(scrollY / Double(Metrics.rowHeight)))
        let last = min(rows - 1, Int((scrollY + visibleHeight) / Double(Metrics.rowHeight)) + 1)
        let sel = model.selection
        let accent = Theme.amber
        let stripe = NSColor.alternatingContentBackgroundColors.count > 1 ? NSColor.alternatingContentBackgroundColors[1] : .clear

        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: Metrics.headerHeight, width: bounds.width, height: bounds.height - Metrics.headerHeight).clip()

        let normal: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: NSColor.labelColor]
        let dim: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: NSColor.tertiaryLabelColor]
        let other: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: Theme.tealText]
        let offsetAttrs: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: NSColor.secondaryLabelColor]
        let offsetCursor: [NSAttributedString.Key: Any] = [.font: Metrics.font, .foregroundColor: Theme.amberText]
        let textBaseline = (Metrics.rowHeight - Metrics.font.ascender + Metrics.font.descender) / 2 - 0.5

        if last >= first {
            for row in first...last {
                let y = rowY(row)
                if row % 2 == 1 {
                    stripe.setFill()
                    NSRect(x: 0, y: y, width: bounds.width, height: Metrics.rowHeight).fill()
                }
                let start = row * 16, end = min(count, start + 16)

                // Bookmarks: a teal bar under each marked byte.
                for i in start..<end where model.isBookmarked(i) {
                    Theme.teal.withAlphaComponent(0.85).setFill()
                    let c = i - start
                    NSBezierPath(roundedRect: NSRect(x: byteX(c) - 1, y: y + Metrics.rowHeight - 3.5, width: cw * 2 + 2, height: 2.5),
                                 xRadius: 1.25, yRadius: 1.25).fill()
                    NSBezierPath(roundedRect: NSRect(x: asciiX + CGFloat(c) * cw, y: y + Metrics.rowHeight - 3.5, width: cw, height: 2.5),
                                 xRadius: 1.25, yRadius: 1.25).fill()
                }

                // Selection, strong in the active column and soft in the other.
                let lo = max(start, sel.lowerBound), hi = min(end - 1, sel.upperBound)
                if lo <= hi {
                    let a = lo - start, b = hi - start
                    let hexRect = NSRect(x: byteX(a) - cw * 0.45, y: y + 1, width: byteX(b) - byteX(a) + cw * 2.9, height: Metrics.rowHeight - 2)
                    let textRect = NSRect(x: asciiX + CGFloat(a) * cw - 1.5, y: y + 1, width: CGFloat(b - a + 1) * cw + 3, height: Metrics.rowHeight - 2)
                    let strong = accent.withAlphaComponent(0.34), soft = accent.withAlphaComponent(0.14)
                    (model.column == .hex ? strong : soft).setFill()
                    NSBezierPath(roundedRect: hexRect, xRadius: 4, yRadius: 4).fill()
                    (model.column == .text ? strong : soft).setFill()
                    NSBezierPath(roundedRect: textRect, xRadius: 4, yRadius: 4).fill()
                }
                // The cursor byte gets an outline in both columns.
                if model.cursor >= start && model.cursor < end {
                    let c = model.cursor - start
                    accent.withAlphaComponent(0.9).setStroke()
                    let r1 = NSBezierPath(roundedRect: NSRect(x: byteX(c) - cw * 0.45, y: y + 1.5, width: cw * 2.9, height: Metrics.rowHeight - 3),
                                          xRadius: 3.5, yRadius: 3.5)
                    r1.lineWidth = model.column == .hex ? 1.5 : 1
                    r1.stroke()
                    let r2 = NSBezierPath(roundedRect: NSRect(x: asciiX + CGFloat(c) * cw - 1, y: y + 1.5, width: cw + 2, height: Metrics.rowHeight - 3),
                                          xRadius: 3, yRadius: 3)
                    r2.lineWidth = model.column == .text ? 1.5 : 1
                    r2.stroke()
                }

                // Text.
                let ty = y + textBaseline
                let cursorRow = model.cursor >= start && model.cursor < end
                (HexFormat.hex(start, digits: digits) as NSString)
                    .draw(at: NSPoint(x: originX, y: ty), withAttributes: cursorRow ? offsetCursor : offsetAttrs)
                let hex = NSMutableAttributedString()
                let text = NSMutableAttributedString()
                for i in start..<end {
                    let b = source[i]
                    let attrs = b == 0 ? dim : (0x20...0x7E).contains(b) ? normal : other
                    let c = i - start
                    hex.append(NSAttributedString(string: HexFormat.byteStrings[Int(b)] + (c == 7 ? "  " : " "), attributes: attrs))
                    text.append(NSAttributedString(string: String(HexFormat.ascii(b)), attributes: b == 0 ? dim : (0x20...0x7E).contains(b) ? normal : dim))
                }
                hex.draw(at: NSPoint(x: hexX, y: ty))
                text.draw(at: NSPoint(x: asciiX, y: ty))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        drawHeader()
    }

    private func drawHeader() {
        let rect = NSRect(x: 0, y: 0, width: bounds.width, height: Metrics.headerHeight)
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: rect.maxY - 1, width: bounds.width, height: 1).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: Metrics.headerFont, .foregroundColor: NSColor.secondaryLabelColor]
        let y = (Metrics.headerHeight - Metrics.headerFont.ascender + Metrics.headerFont.descender) / 2 - 1
        ("Offset" as NSString).draw(at: NSPoint(x: originX, y: y), withAttributes: attrs)
        let cursorColumn = model.hasBytes ? model.cursor % 16 : -1
        for i in 0..<16 {
            var a = attrs
            if i == cursorColumn { a[.foregroundColor] = Theme.amberText }
            (HexFormat.byteStrings[i] as NSString).draw(at: NSPoint(x: byteX(i), y: y), withAttributes: a)
            (String(HexFormat.digits[i]) as NSString).draw(at: NSPoint(x: asciiX + CGFloat(i) * cw, y: y), withAttributes: a)
        }
    }

    // MARK: Mouse

    /// The byte under a point, and which column it is in.
    private func hit(_ p: NSPoint) -> (Int, Column)? {
        guard model.hasBytes else { return nil }
        let row = Int(floor((Double(p.y - Metrics.headerHeight - 4) + scrollY) / Double(Metrics.rowHeight)))
        let column: Column = p.x < asciiX - Metrics.gap / 2 ? .hex : .text
        var c: Int
        if column == .hex {
            c = 0
            for i in 0..<16 where p.x >= byteX(i) - cw * 0.5 { c = i }
        } else {
            c = Int(floor((p.x - asciiX) / cw))
        }
        c = min(15, max(0, c))
        let r = min(rows - 1, max(0, row))
        return (min(model.count - 1, r * 16 + c), column)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard p.y > Metrics.headerHeight, let (i, column) = hit(p) else { return }
        model.column = column
        if event.modifierFlags.contains(.shift) {
            model.cursor = i
        } else {
            model.anchor = i
            model.cursor = i
        }
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragPoint = convert(event.locationInWindow, from: nil)
        dragTo(lastDragPoint)
        let outside = lastDragPoint.y < Metrics.headerHeight || lastDragPoint.y > bounds.height
        if outside, dragTimer == nil {
            dragTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autoscroll() }
            }
        } else if !outside {
            stopDragTimer()
        }
    }

    override func mouseUp(with event: NSEvent) { stopDragTimer() }

    private func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func autoscroll() {
        let p = lastDragPoint
        if p.y < Metrics.headerHeight {
            setScroll(scrollY - Double(Metrics.headerHeight - p.y))
        } else if p.y > bounds.height {
            setScroll(scrollY + Double(p.y - bounds.height))
        }
        dragTo(p)
    }

    private func dragTo(_ p: NSPoint) {
        let clamped = NSPoint(x: p.x, y: min(max(p.y, Metrics.headerHeight + 1), bounds.height - 1))
        guard let (i, _) = hit(clamped) else { return }
        if model.cursor != i { model.cursor = i }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    private func move(by delta: Int, extend: Bool) {
        guard model.hasBytes else { return }
        let target = min(model.count - 1, max(0, model.cursor + delta))
        moveTo(target, extend: extend)
    }

    private func moveTo(_ target: Int, extend: Bool) {
        model.cursor = target
        if !extend { model.anchor = target }
        reveal(target, center: false)
    }

    private var pageBytes: Int { max(1, Int(visibleHeight / Double(Metrics.rowHeight)) - 1) * 16 }

    override func moveLeft(_ sender: Any?) { move(by: -1, extend: false) }
    override func moveRight(_ sender: Any?) { move(by: 1, extend: false) }
    override func moveUp(_ sender: Any?) { move(by: -16, extend: false) }
    override func moveDown(_ sender: Any?) { move(by: 16, extend: false) }
    override func moveLeftAndModifySelection(_ sender: Any?) { move(by: -1, extend: true) }
    override func moveRightAndModifySelection(_ sender: Any?) { move(by: 1, extend: true) }
    override func moveUpAndModifySelection(_ sender: Any?) { move(by: -16, extend: true) }
    override func moveDownAndModifySelection(_ sender: Any?) { move(by: 16, extend: true) }
    override func moveWordLeft(_ sender: Any?) { move(by: -4, extend: false) }
    override func moveWordRight(_ sender: Any?) { move(by: 4, extend: false) }
    override func moveWordLeftAndModifySelection(_ sender: Any?) { move(by: -4, extend: true) }
    override func moveWordRightAndModifySelection(_ sender: Any?) { move(by: 4, extend: true) }
    override func moveToBeginningOfLine(_ sender: Any?) { moveTo(model.cursor - model.cursor % 16, extend: false) }
    override func moveToEndOfLine(_ sender: Any?) { moveTo(min(model.count - 1, model.cursor - model.cursor % 16 + 15), extend: false) }
    override func moveToLeftEndOfLine(_ sender: Any?) { moveToBeginningOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { moveToEndOfLine(sender) }
    override func moveToBeginningOfDocument(_ sender: Any?) { if model.hasBytes { moveTo(0, extend: false) } }
    override func moveToEndOfDocument(_ sender: Any?) { if model.hasBytes { moveTo(model.count - 1, extend: false) } }
    override func moveToBeginningOfDocumentAndModifySelection(_ sender: Any?) { if model.hasBytes { moveTo(0, extend: true) } }
    override func moveToEndOfDocumentAndModifySelection(_ sender: Any?) { if model.hasBytes { moveTo(model.count - 1, extend: true) } }
    override func scrollToBeginningOfDocument(_ sender: Any?) { setScroll(0) }
    override func scrollToEndOfDocument(_ sender: Any?) { setScroll(maxScroll) }
    override func pageDown(_ sender: Any?) { setScroll(scrollY + visibleHeight - Double(Metrics.rowHeight)); move(by: pageBytes, extend: false) }
    override func pageUp(_ sender: Any?) { setScroll(scrollY - visibleHeight + Double(Metrics.rowHeight)); move(by: -pageBytes, extend: false) }
    override func scrollPageDown(_ sender: Any?) { setScroll(scrollY + visibleHeight - Double(Metrics.rowHeight)) }
    override func scrollPageUp(_ sender: Any?) { setScroll(scrollY - visibleHeight + Double(Metrics.rowHeight)) }
    override func pageDownAndModifySelection(_ sender: Any?) { move(by: pageBytes, extend: true) }
    override func pageUpAndModifySelection(_ sender: Any?) { move(by: -pageBytes, extend: true) }
    override func insertTab(_ sender: Any?) { model.column = model.column == .hex ? .text : .hex }
    override func insertBacktab(_ sender: Any?) { insertTab(sender) }
    override func cancelOperation(_ sender: Any?) { if model.showFind { model.closeFind() } else { model.anchor = model.cursor } }
    override func insertText(_ insertString: Any) { NSSound.beep() }
    override func doCommand(by selector: Selector) {
        if responds(to: selector) { super.doCommand(by: selector) } else { NSSound.beep() }
    }

    @objc func copy(_ sender: Any?) { model.copy() }
    override func selectAll(_ sender: Any?) { model.selectAll() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) || item.action == #selector(selectAll(_:)) { return model.hasBytes }
        return true
    }
}

/// SwiftUI wrapper for the grid.
struct HexGrid: NSViewRepresentable {
    @ObservedObject var model: HexModel

    func makeNSView(context: Context) -> HexView { HexView(model: model) }

    func updateNSView(_ view: HexView, context: Context) {
        _ = (model.anchor, model.cursor, model.column, model.bookmarks, model.revealToken, model.focusToken)
        view.refresh()
    }
}
