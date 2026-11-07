import AppKit
import SwiftUI

/// The pretty text view: a read-only, selectable, syntax coloured NSTextView.
struct TextPane: NSViewRepresentable {
    @ObservedObject var model: ViewerModel

    func makeCoordinator() -> TextPaneController { TextPaneController() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 14, height: 12)
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isAutomaticLinkDetectionEnabled = false
        text.allowsUndo = false
        text.setAccessibilityLabel("Pretty printed JSON")
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        context.coordinator.textView = text
        model.textPane = context.coordinator
        context.coordinator.show(model.pretty, focusID: model.focusID)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        model.textPane = context.coordinator
        context.coordinator.show(model.pretty, focusID: model.focusID)
    }
}

@MainActor
final class TextPaneController: NSObject {
    weak var textView: NSTextView?
    private var shown: PrettyText?
    private var highlighted: [NSRange] = []
    /// The syntax colours that match highlights painted over, put back when the highlights go.
    private var savedColors: [(NSRange, NSColor)] = []

    private var focus: NSRange?

    /// Shows a new text. Called on every SwiftUI update, so it does nothing (and finds no range) when the text is the same.
    func show(_ pretty: PrettyText?, focusID: Int32) {
        guard let textView, pretty !== shown else { return }
        let focus = pretty?.range(of: focusID)
        shown = pretty
        highlighted = []
        savedColors = []
        self.focus = nil
        textView.textStorage?.setAttributedString(pretty?.string ?? NSAttributedString())
        textView.scroll(.zero)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        reveal(focus)
    }

    /// Selects the selected node's text and scrolls to it (the top of the text for the root).
    func reveal(_ range: NSRange?) {
        guard let textView, let range, range != focus, NSMaxRange(range) <= (textView.textStorage?.length ?? 0) else { return }
        focus = range
        guard range.location > 0 else { textView.setSelectedRange(NSRange(location: 0, length: 0)); textView.scroll(.zero); return }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(NSRange(location: range.location, length: 0))
    }

    /// Marks every match and selects the current one.
    func highlight(_ ranges: [NSRange], current: Int?) {
        guard let textView, let storage = textView.textStorage else { return }
        let length = storage.length
        storage.beginEditing()
        for r in highlighted where NSMaxRange(r) <= length { storage.removeAttribute(.backgroundColor, range: r) }
        for (r, color) in savedColors where NSMaxRange(r) <= length { storage.addAttribute(.foregroundColor, value: color, range: r) }
        savedColors = []
        let shownRanges = ranges.filter { NSMaxRange($0) <= length }
        for r in shownRanges {
            // Dark text on the yellow marker reads in light and dark mode; remember the colours it covers.
            storage.enumerateAttribute(.foregroundColor, in: r) { value, sub, _ in
                if let color = value as? NSColor { savedColors.append((sub, color)) }
            }
            storage.addAttributes([.backgroundColor: Theme.highlight, .foregroundColor: NSColor.black], range: r)
        }
        // The current match in a stronger marker, like Safari's find, rather than a selection that turns grey
        // while the search field has focus.
        if let current, current < shownRanges.count {
            storage.addAttribute(.backgroundColor, value: Theme.currentMatch, range: shownRanges[current])
        }
        storage.endEditing()
        highlighted = shownRanges
        if let current, current < shownRanges.count {
            let r = shownRanges[current]
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
            textView.scrollRangeToVisible(r)
            textView.showFindIndicator(for: r)
        }
    }
}
