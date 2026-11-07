import AppKit
import SwiftUI

// Shared pieces for the desktop apps: windowed SwiftUI apps with a Dock icon and a full main menu.
// Each desktop app's main.swift runs `IconKit.handleCommandLine`, then `Desktop.handleSnapshot`, then `FooApp.main()`.

public enum Desktop {
    /// True when the app runs as `App --snapshot out.png`; apps show fixed demo data then, never the user's own.
    public static let isSnapshot = CommandLine.arguments.contains("--snapshot")

    /// The project website, for the Help menu.
    public static let website = "https://weirdapps.github.io/macapps/"

    /// If launched with `--snapshot <path>`, renders `content` in a real, active, light-mode window of `size` points
    /// (title bar and any SwiftUI `.toolbar` items included), writes a 2x PNG with rounded corners and exits
    /// before the app starts. Pass the same view the app's window shows, fed with fixed demo data.
    public static func handleSnapshot<Content: View>(title: String, size: CGSize, @ViewBuilder content: @escaping () -> Content) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        let path = args[i + 1]
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: .aqua)
            let delegate = SnapshotDelegate(title: title, size: size, path: path, content: { AnyView(content()) })
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
        exit(0)
    }
}

@MainActor
private final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    let title: String
    let size: CGSize
    let path: String
    let content: () -> AnyView
    var window: NSWindow?

    init(title: String, size: CGSize, path: String, content: @escaping () -> AnyView) {
        self.title = title
        self.size = size
        self.path = path
        self.content = content
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.toolbar = NSToolbar(identifier: "snapshot")
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: content().frame(width: size.width, height: size.height))
        window.setContentSize(size)
        // Off screen, but key and active, so controls draw in their active colours.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Self.write(window: window, to: self.path)
            exit(0)
        }
    }

    /// Caches the whole window frame view (title bar and toolbar included) and clips it to rounded window corners.
    static func write(window: NSWindow, to path: String) {
        guard let frameView = window.contentView?.superview,
              let body = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.cacheDisplay(in: frameView.bounds, to: body)
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: body.pixelsWide, pixelsHigh: body.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(origin: .zero, size: size)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        shape.addClip()
        body.draw(in: rect)
        NSColor(white: 0, alpha: 0.18).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 11.75, yRadius: 11.75)
        edge.lineWidth = 0.5
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// Help menu items for every desktop app: the website and the source, instead of the empty "Foo Help".
public struct AppHelpCommands: Commands {
    let name: String
    public init(name: String) { self.name = name }

    public var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("\(name) Website") { NSWorkspace.shared.open(URL(string: Desktop.website + "#" + name.lowercased())!) }
            Button("\(name) Source Code") {
                NSWorkspace.shared.open(URL(string: "https://github.com/weirdapps/macapps/tree/master/Sources/\(name)")!)
            }
        }
    }
}

/// The empty state of a file-based app: a dashed drop target with a symbol, a title, one helpful line and an Open button.
public struct DropZone: View {
    let symbol: String
    let title: String
    let message: String
    let button: String?
    let tint: Color
    let isTargeted: Bool
    let action: (() -> Void)?

    public init(symbol: String, title: String, message: String, button: String? = nil, tint: Color = .accentColor,
                isTargeted: Bool = false, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.button = button
        self.tint = tint
        self.isTargeted = isTargeted
        self.action = action
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(tint.gradient)
                .symbolEffect(.bounce, value: isTargeted)
            VStack(spacing: 5) {
                Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let button, let action {
                Button(button, action: action).controlSize(.large).buttonStyle(.borderedProminent).tint(tint)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                .foregroundStyle(isTargeted ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isTargeted ? AnyShapeStyle(tint.opacity(0.08)) : AnyShapeStyle(.clear)))
        }
        .padding(20)
        .animation(.snappy(duration: 0.2), value: isTargeted)
    }
}

/// Reveals a file in Finder.
public func revealInFinder(_ urls: [URL]) {
    NSWorkspace.shared.activateFileViewerSelecting(urls)
}
