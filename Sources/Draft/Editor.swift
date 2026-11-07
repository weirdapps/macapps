import AppKit
import Kit
import SwiftUI

/// The writing surface: an NSTextView (TextKit 1, for temporary attributes) in a centred column,
/// with typewriter scrolling, focus dimming and light Markdown styling.
struct WritingEditor: NSViewRepresentable {
    @Binding var text: String
    var style: EditorStyle
    /// Where the caret starts; the snapshot puts it in the middle of the demo.
    var initialCaret: Int = 0
    var onType: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay

        let tv = NSTextView(usingTextLayoutManager: false)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isContinuousSpellCheckingEnabled = !Desktop.isSnapshot
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.setAccessibilityLabel("Text")

        let c = context.coordinator
        c.textView = tv
        c.scrollView = scroll
        tv.delegate = c
        tv.textStorage?.delegate = c
        scroll.documentView = tv
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.clipChanged),
                                               name: NSView.frameDidChangeNotification, object: scroll.contentView)

        c.apply(style, force: true)
        tv.string = text
        let caret = min(initialCaret, (text as NSString).length)
        tv.setSelectedRange(NSRange(location: caret, length: 0))
        DispatchQueue.main.async {
            c.layoutInsets()
            c.refreshFocus()
            c.centerCaret(animated: false)
            if let window = tv.window, !Desktop.isSnapshot || window.firstResponder !== tv { window.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text {
            let selection = tv.selectedRange()
            tv.string = text
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            c.refreshFocus()
        }
        c.apply(style)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: WritingEditor
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        private(set) var style: EditorStyle?
        private var lastCaretLine: CGFloat = -1

        init(_ parent: WritingEditor) { self.parent = parent }

        // MARK: Style

        func apply(_ new: EditorStyle, force: Bool = false) {
            guard force || new != style, let tv = textView else { return }
            let old = style
            style = new
            let theme = new.theme
            tv.insertionPointColor = rgb(theme.caret)
            tv.selectedTextAttributes = [.backgroundColor: rgb(theme.selection)]
            tv.typingAttributes = baseAttributes(new)
            tv.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            scrollView?.appearance = tv.appearance
            if let storage = tv.textStorage, storage.length > 0,
               old.map({ $0.typeface != new.typeface || $0.size != new.size || $0.lineHeight != new.lineHeight
                   || $0.theme != new.theme || $0.markdown != new.markdown }) ?? true {
                storage.beginEditing()
                restyle(storage, range: NSRange(location: 0, length: storage.length), style: new)
                storage.endEditing()
            }
            layoutInsets()
            refreshFocus()
            if old?.typewriter != new.typewriter || old?.size != new.size { lastCaretLine = -1; centerCaret(animated: false) }
        }

        private func baseAttributes(_ s: EditorStyle) -> [NSAttributedString.Key: Any] {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = s.lineHeight
                        return [.font: s.font, .foregroundColor: rgb(s.theme.ink), .paragraphStyle: p]
        }

        private func restyle(_ storage: NSTextStorage, range: NSRange, style s: EditorStyle) {
            storage.setAttributes(baseAttributes(s), range: range)
            guard s.markdown else { return }
            let font = s.font
            let bold = Self.font(font, adding: .bold)
            let italic = Self.font(font, adding: .italic)
            for span in Markdown.spans(in: storage.string as NSString, range: range) {
                switch span {
                case .heading(let r), .strong(let r): storage.addAttribute(.font, value: bold, range: r)
                case .emphasis(let r): storage.addAttribute(.font, value: italic, range: r)
                case .quote(let r):
                    storage.addAttribute(.font, value: italic, range: r)
                    storage.addAttribute(.foregroundColor, value: s.theme.faint, range: r)
                case .marker(let r): storage.addAttribute(.foregroundColor, value: s.theme.faint, range: r)
                }
            }
        }

        static func font(_ font: NSFont, adding trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            return NSFont(descriptor: d, size: font.pointSize) ?? font
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                guard let style else { return }
                let ns = textStorage.string as NSString
                let safe = NSRange(location: min(editedRange.location, ns.length),
                                   length: min(editedRange.length, ns.length - min(editedRange.location, ns.length)))
                restyle(textStorage, range: ns.paragraphRange(for: safe), style: style)
            }
        }

        // MARK: Editing

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onType()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            refreshFocus()
            DispatchQueue.main.async { [weak self] in self?.centerCaret(animated: true) }
        }

        // MARK: Layout

        @objc func clipChanged() { layoutInsets(); centerCaret(animated: false) }

        /// Centres the column, and in typewriter mode pads top and bottom by half a screen so any line can sit mid window.
        func layoutInsets() {
            guard let tv = textView, let scroll = scrollView, let style else { return }
            let clip = scroll.contentView.bounds.size
            let h = EditorStyle.horizontalInset(viewWidth: clip.width, column: style.columnWidth)
            let line = style.size * style.lineHeight
            let v = style.typewriter ? max(48, (clip.height / 2 - line / 2).rounded()) : 56
            let inset = NSSize(width: h, height: v)
            if tv.textContainerInset != inset { tv.textContainerInset = inset }
        }

        /// Keeps the caret's line at the vertical centre of the window.
        func centerCaret(animated: Bool) {
            guard let style, style.typewriter, let tv = textView, let scroll = scrollView,
                  let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let length = (tv.string as NSString).length
            let loc = tv.selectedRange().location
            var rect: NSRect
            if length == 0 || (loc >= length && !lm.extraLineFragmentRect.isEmpty) {
                rect = lm.extraLineFragmentRect
            } else {
                rect = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: min(loc, length - 1)), effectiveRange: nil)
            }
            rect.origin.y += tv.textContainerOrigin.y
            let clip = scroll.contentView
            let maxY = max(0, tv.frame.height - clip.bounds.height)
            let y = min(maxY, max(0, (rect.midY - clip.bounds.height / 2).rounded()))
            guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
            let changedLine = rect.midY != lastCaretLine
            lastCaretLine = rect.midY
            if animated && changedLine && !Desktop.isSnapshot {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
                }
            } else {
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(clip)
        }

        // MARK: Focus

        func refreshFocus() {
            guard let tv = textView, let lm = tv.layoutManager, let style else { return }
            let ns = tv.string as NSString
            let all = NSRange(location: 0, length: ns.length)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
            guard style.focus != .off, ns.length > 0 else { return }
            let keep = FocusRange.range(in: ns, caret: tv.selectedRange().location, mode: style.focus)
            lm.addTemporaryAttribute(.foregroundColor, value: style.theme.dimmed, forCharacterRange: all)
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: keep)
        }
    }
}

