import AppKit
import Kit
import SwiftUI

// The sheet editor: an NSTextView that keeps a results column at its right edge, one result per line,
// drawn in the same scrolling document so results never drift from their lines.

enum Palette {
    static let accent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0xFF9A5C) : rgb(0xE35F2A)
    }
    static let unit = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0x7CB8FF) : rgb(0x2F6FD0)
    }
    static let keyword = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0xD39BFF) : rgb(0x8A3FC4)
    }
    static let variable = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(0xFFB984) : rgb(0xB8562A)
    }
}

final class SheetTextView: NSTextView {
    var results: [LineResult] = [] { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 15
    var onCopy: ((String) -> Void)?

    private var hits: [(rect: NSRect, line: Int, text: String)] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var copied: Int?

    var columnWidth: CGFloat { min(300, max(170, bounds.width * 0.3)) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitContainer()
    }

    func fitContainer() {
        let width = max(120, bounds.width - columnWidth - textContainerInset.width * 2 - 8)
        if textContainer?.containerSize.width != width {
            textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let x = bounds.width - columnWidth
        Palette.accent.withAlphaComponent(0.045).setFill()
        NSRect(x: x, y: rect.minY, width: columnWidth, height: rect.height).fill()
        Palette.accent.withAlphaComponent(0.16).setFill()
        NSRect(x: x, y: rect.minY, width: 1, height: rect.height).fill()
        drawResults(in: rect)
    }

    /// Results draw with the background, which every display path (including window snapshots) runs.
    private func drawResults(in dirtyRect: NSRect) {
        guard let layout = layoutManager else { return }
        let text = string as NSString
        let font = Self.resultFont(fontSize)
        let column = NSRect(x: bounds.width - columnWidth + 12, y: 0, width: columnWidth - 26, height: 0)
        var newHits: [(NSRect, Int, String)] = []
        var location = 0
        for (index, result) in results.enumerated() {
            let range = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            defer { location = NSMaxRange(range) }
            guard let display = result.display else { continue }
            var fragment: NSRect
            if location >= text.length {
                fragment = layout.extraLineFragmentRect
            } else {
                let glyph = layout.glyphIndexForCharacter(at: location)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            fragment.origin.y += textContainerOrigin.y
            guard fragment.maxY >= dirtyRect.minY - 40, fragment.minY <= dirtyRect.maxY + 40 else { continue }
            let isCopied = copied == index
            let label = isCopied ? "Copied" : display
            let color = isCopied ? NSColor.secondaryLabelColor : Palette.accent
            let attributed = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color])
            let size = attributed.size()
            let width = min(size.width, column.width)
            let textRect = NSRect(x: column.maxX - width, y: fragment.minY + (fragment.height - size.height) / 2,
                                  width: width, height: size.height)
            let pill = textRect.insetBy(dx: -7, dy: -1.5)
            if hovered == index || isCopied {
                Palette.accent.withAlphaComponent(isCopied ? 0.1 : 0.14).setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = .right
            let drawn = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            drawn.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            newHits.append((pill, index, display))
        }
        hits = newHits
        window?.invalidateCursorRects(for: self)
    }

    static func resultFont(_ size: CGFloat) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
        if let rounded = base.fontDescriptor.withDesign(.rounded) { return NSFont(descriptor: rounded, size: size) ?? base }
        return base
    }

    // MARK: Pointer

    override func resetCursorRects() {
        super.resetCursorRects()
        for hit in hits { addCursorRect(hit.rect, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["figure"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["figure": true]))
    }

    private func hit(_ event: NSEvent) -> (rect: NSRect, line: Int, text: String)? {
        let p = convert(event.locationInWindow, from: nil)
        return hits.first { $0.rect.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let h = hit(event) {
            hovered = h.line
            NSCursor.pointingHand.set()
        } else {
            hovered = nil
            super.mouseMoved(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let h = hit(event) else { return super.mouseDown(with: event) }
        onCopy?(h.text)
        copied = h.line
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.copied == h.line else { return }
            self.copied = nil
            self.needsDisplay = true
        }
    }
}

/// SwiftUI wrapper. Each sheet gets its own text view (the caller sets `.id(sheet.id)`), so undo stays per sheet.
struct SheetEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var focus: Bool
    var onCopy: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let textView = SheetTextView(usingTextLayoutManager: false)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainerInset = NSSize(width: 22, height: 18)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = Palette.accent
        textView.fontSize = fontSize
        textView.onCopy = onCopy
        textView.delegate = context.coordinator
        textView.string = text
        scroll.documentView = textView
        context.coordinator.refresh(textView)
        if focus {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? SheetTextView else { return }
        textView.onCopy = onCopy
        var changed = false
        if textView.string != text {
            textView.string = text
            changed = true
        }
        if textView.fontSize != fontSize {
            textView.fontSize = fontSize
            changed = true
        }
        if changed { context.coordinator.refresh(textView) }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SheetEditor
        init(_ parent: SheetEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? SheetTextView else { return }
            parent.text = textView.string
            refresh(textView)
        }

        /// Re-evaluates the sheet, recolours it and redraws the results.
        func refresh(_ textView: SheetTextView) {
            let text = textView.string
            let results = Engine.evaluate(text)
            let font = NSFont.monospacedDigitSystemFont(ofSize: textView.fontSize, weight: .regular)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineHeightMultiple = 1.18
            paragraph.paragraphSpacing = 3
            let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            textView.typingAttributes = base
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            storage.setAttributes(base, range: NSRange(location: 0, length: storage.length))
            let lines = text.components(separatedBy: "\n")
            var offset = 0
            for (line, result) in zip(lines, results) {
                let isHeading = result.kind == .comment && line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                for (range, role) in Highlight.ranges(line, result: result) {
                    let r = NSRange(location: offset + range.location, length: range.length)
                    guard NSMaxRange(r) <= storage.length else { continue }
                    switch role {
                    case .comment:
                        storage.addAttribute(.foregroundColor, value: isHeading ? NSColor.labelColor : NSColor.secondaryLabelColor, range: r)
                        if isHeading {
                            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: textView.fontSize + 1, weight: .bold), range: r)
                        }
                    case .label: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                    case .assignment, .variable: storage.addAttribute(.foregroundColor, value: Palette.variable, range: r)
                    case .keyword: storage.addAttribute(.foregroundColor, value: Palette.keyword, range: r)
                    case .unit: storage.addAttribute(.foregroundColor, value: Palette.unit, range: r)
                    }
                }
                offset += (line as NSString).length + 1
            }
            storage.endEditing()
            textView.fitContainer()
            textView.results = results
        }
    }
}
