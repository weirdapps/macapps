import AppKit
import ServiceManagement
import SwiftUI

/// Launch at login through `SMAppService`, which needs the app in /Applications.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("LaunchAtLogin: \(error.localizedDescription)")
            }
        }
    }
}

public struct LaunchAtLoginToggle: View {
    @State private var enabled = LaunchAtLogin.isEnabled

    public init() {}

    public var body: some View {
        Toggle("Launch at login", isOn: $enabled)
            .onChange(of: enabled) { _, value in LaunchAtLogin.isEnabled = value }
    }
}

/// The bottom bar every app shares: name, shortcut hint, settings menu, quit.
public struct PanelFooter<MenuContent: View>: View {
    let name: String
    let shortcut: String?
    let menu: MenuContent

    public init(name: String, shortcut: String? = nil, @ViewBuilder menu: () -> MenuContent) {
        self.name = name
        self.shortcut = shortcut
        self.menu = menu()
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            if let shortcut {
                KeyCap(shortcut)
            }
            Spacer()
            Menu {
                menu
                Divider()
                LaunchAtLoginToggle()
                Button("About \(name)") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit \(name)") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.35))
    }
}

public struct KeyCap: View {
    let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary.opacity(0.6)))
    }
}

/// A round, softly lit icon button used in panel headers.
public struct GlassIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(.quaternary.opacity(hovering ? 0.9 : 0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A large rounded pill button with a gradient fill.
public struct PillButtonStyle: ButtonStyle {
    let colors: [Color]
    public init(_ colors: [Color]) { self.colors = colors }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: colors.last!.opacity(0.35), radius: configuration.isPressed ? 2 : 6, y: configuration.isPressed ? 1 : 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// JSON persistence in ~/Library/Application Support/<app>/.
public enum Storage {
    public static func url(app: String, file: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(app, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(file)
    }

    public static func load<T: Decodable>(_ type: T.Type, app: String, file: String) -> T? {
        guard let data = try? Data(contentsOf: url(app: app, file: file)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func save<T: Encodable>(_ value: T, app: String, file: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url(app: app, file: file), options: .atomic)
    }
}
