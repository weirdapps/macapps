import AppKit
import SwiftUI

public extension Notification.Name {
    /// Posted each time the popover opens, so views can take focus or refresh.
    static let popoverDidShow = Notification.Name("Kit.popoverDidShow")
}

/// A menu bar item that opens a SwiftUI view in a native popover.
@MainActor
public final class StatusPopover: NSObject, NSPopoverDelegate {
    public let item: NSStatusItem
    private let popover = NSPopover()
    /// Called on right-click or control-click instead of opening the popover.
    public var onSecondaryClick: (() -> Void)?

    /// True when the app runs as `App --snapshot out.png`; apps show fixed demo data then, never the user's own.
    public static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    /// `.transient` by default. Apps that take drags from Finder or open panels use `.semitransient`.
    public var behavior: NSPopover.Behavior {
        get { popover.behavior }
        set { popover.behavior = newValue }
    }

    public init<Content: View>(symbol: String, accessibilityLabel: String, @ViewBuilder content: () -> Content) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        StatusPopover.installEditMenu()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: content())
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            StatusPopover.snapshot(content(), to: CommandLine.arguments[i + 1])
        }
        if let button = item.button {
            button.image = StatusPopover.symbol(symbol, label: accessibilityLabel)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// Renders the panel to a PNG and quits; used for README screenshots: `App --snapshot out.png`.
    private static func snapshot<Content: View>(_ content: Content, to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }

    /// Text fields get Cmd+C, V, X, A and Z through the main menu, which an accessory app does not have.
    /// This hidden Edit menu is never shown, but it makes those shortcuts work in every panel.
    private static func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        NSApp.mainMenu = main
    }

    public static func symbol(_ name: String, label: String, pointSize: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
        image?.isTemplate = true
        return image
    }

    public func setSymbol(_ name: String, label: String) {
        item.button?.image = StatusPopover.symbol(name, label: label)
    }

    /// Text next to the icon, in monospaced digits so the item keeps its width.
    public func setTitle(_ title: String) {
        guard let button = item.button else { return }
        if title.isEmpty {
            button.attributedTitle = NSAttributedString()
            button.imagePosition = .imageOnly
        } else {
            button.imagePosition = .imageLeading
            button.attributedTitle = NSAttributedString(
                string: " " + title,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
        }
    }

    public var isShown: Bool { popover.isShown }

    public func toggle() {
        isShown ? close() : show()
    }

    public func show() {
        guard let button = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NotificationCenter.default.post(name: .popoverDidShow, object: nil)
    }

    public func close() {
        popover.performClose(nil)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if secondary, let onSecondaryClick {
            onSecondaryClick()
        } else {
            toggle()
        }
    }
}
