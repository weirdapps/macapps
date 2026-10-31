import AppKit
import SwiftUI

/// A brief, non-activating overlay in the style of the system volume HUD.
@MainActor
public enum HUD {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    public static func show(symbol: String, title: String, tint: Color = .primary) {
        let view = NSHostingView(rootView: HUDView(symbol: symbol, title: title, tint: tint))
        let size = NSSize(width: 200, height: 200)
        view.frame = NSRect(origin: .zero, size: size)

        let panel = self.panel ?? makePanel(size: size)
        self.panel = panel
        panel.contentView = view
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.18))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }

        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    private static func makePanel(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        return panel
    }
}

private struct HUDView: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(height: 80)
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
        .frame(width: 200, height: 200)
        .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

public struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material) { self.material = material }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
