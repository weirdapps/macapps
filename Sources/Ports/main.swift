import AppKit
import Combine
import Kit
import SwiftUI

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var status: StatusPopover!
    let scanner = PortScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "app.connected.to.app.below.fill", accessibilityLabel: "Ports") {
            PortsView().environmentObject(self.scanner)
        }
    }
}

// MARK: - Model

struct Listener: Identifiable, Hashable {
    enum Proto: String { case tcp = "TCP", udp = "UDP" }

    let proto: Proto
    let port: Int
    let pid: Int32
    let command: String
    /// Local addresses bound, e.g. "*", "127.0.0.1", "[::1]".
    var hosts: Set<String>

    var id: String { "\(proto.rawValue)-\(port)-\(pid)" }
    var isLocalOnly: Bool { hosts.allSatisfy { $0 == "127.0.0.1" || $0 == "[::1]" || $0 == "localhost" } }
    var scope: String { isLocalOnly ? "This Mac only" : hosts.contains("*") ? "All interfaces" : hosts.sorted().joined(separator: ", ") }
}

enum Lsof {
    /// Parses `lsof -F pcPn` output: a `p` line starts each process, `c` names it, then `P` and `n` repeat per socket.
    static func parse(_ output: String) -> [Listener] {
        var result: [String: Listener] = [:]
        var pid: Int32 = 0, command = "", proto = ""
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value) ?? 0
            case "c": command = value
            case "P": proto = value
            case "n":
                // Connected sockets ("a->b") and unbound ones ("*:*") are not listening.
                guard !value.contains("->"), let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]),
                      let kind = Listener.Proto(rawValue: proto) else { continue }
                let host = String(value[..<colon])
                let key = "\(kind.rawValue)-\(port)-\(pid)"
                result[key, default: Listener(proto: kind, port: port, pid: pid, command: command, hosts: [])].hosts.insert(host)
            default: break
            }
        }
        return result.values.sorted { ($0.port, $0.proto.rawValue, $0.pid) < ($1.port, $1.proto.rawValue, $1.pid) }
    }

    static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every listening TCP socket and bound UDP port this user can see. `+c 0` keeps full command names.
    static func scan() -> [Listener] {
        let tcp = run(["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcPn"])
        let udp = run(["+c", "0", "-nP", "-iUDP", "-F", "pcPn"])
        return parse(tcp + "\n" + udp)
    }
}

enum Filter: String, CaseIterable {
    case all = "All", tcp = "TCP", udp = "UDP"
}

@MainActor
final class PortScanner: ObservableObject {
    @Published private(set) var listeners: [Listener] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedOnce = false
    @Published var query = ""
    @Published var copied: String?
    @AppStorage("filter") var filter = Filter.tcp

    private var timer: Timer?

    init() {
        if StatusPopover.isSnapshot {
            // Fixed demo listeners for screenshots: never this Mac's real processes.
            listeners = PortScanner.demo
            scannedOnce = true
            return
        }
        refresh()
        // Refresh while the panel is in use; the popover activates the app and closing it deactivates it.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if NSApp.isActive { self?.refresh() } }
        }
        timer?.tolerance = 1
    }

    private static let demo: [Listener] = [
        Listener(proto: .tcp, port: 3000, pid: 4211, command: "node", hosts: ["127.0.0.1"]),
        Listener(proto: .tcp, port: 5173, pid: 4388, command: "vite", hosts: ["[::1]"]),
        Listener(proto: .tcp, port: 5432, pid: 812, command: "postgres", hosts: ["127.0.0.1", "[::1]"]),
        Listener(proto: .udp, port: 5353, pid: 402, command: "mDNSResponder", hosts: ["*"]),
        Listener(proto: .tcp, port: 6379, pid: 905, command: "redis-server", hosts: ["127.0.0.1"]),
        Listener(proto: .tcp, port: 8000, pid: 5102, command: "Python", hosts: ["*"]),
        Listener(proto: .tcp, port: 8080, pid: 5240, command: "nginx", hosts: ["*"]),
    ]

    var visible: [Listener] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return listeners.filter { l in
            (filter == .all || l.proto.rawValue == filter.rawValue)
                && (q.isEmpty || String(l.port).hasPrefix(q) || l.command.lowercased().contains(q) || String(l.pid) == q)
        }
    }

    func refresh() {
        guard !scanning, !StatusPopover.isSnapshot else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Lsof.scan()
            await MainActor.run {
                self.scanning = false
                self.scannedOnce = true
                if found != self.listeners { withAnimation(.snappy) { self.listeners = found } }
            }
        }
    }

    func copy(_ l: Listener) {
        let text = "localhost:\(l.port)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) { copied = l.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copied == l.id { withAnimation(.snappy) { self?.copied = nil } }
        }
    }

    func open(_ l: Listener) {
        if let url = URL(string: "http://localhost:\(l.port)") { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 1, green: 0.62, blue: 0.3), Color(red: 0.93, green: 0.36, blue: 0.16)]
    static let udp = [Color(red: 0.45, green: 0.7, blue: 1), Color(red: 0.25, green: 0.45, blue: 0.95)]
}

struct PortsView: View {
    @EnvironmentObject var scanner: PortScanner

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Port, app or PID", text: $scanner.query)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.45)))
                Picker("", selection: $scanner.filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)

            let rows = scanner.visible
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: scanner.query.isEmpty ? "powerplug" : "magnifyingglass")
                        .font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text(!scanner.scannedOnce ? "Scanning…"
                         : scanner.query.isEmpty ? "Nothing is listening. Start a server and it shows up here."
                         : "No port matches \u{201C}\(scanner.query)\u{201D}.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows) { PortRow(listener: $0) }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: min(CGFloat(rows.count) * 50 + 4, 380))
            }
            HStack(spacing: 6) {
                Text("\(rows.count) \(rows.count == 1 ? "port" : "ports")")
                Text("·")
                Text("Ports opened by other users need admin rights to see")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if scanner.scanning { ProgressView().controlSize(.mini) }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().opacity(0.5)
            PanelFooter(name: "Ports") {
                Button("Refresh") { scanner.refresh() }.keyboardShortcut("r")
            }
        }
        .frame(width: 380)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in scanner.refresh() }
    }
}

struct PortRow: View {
    @EnvironmentObject var scanner: PortScanner
    let listener: Listener
    @State private var hovering = false

    var body: some View {
        // Demo PIDs could belong to a real app on this Mac, so snapshots never look them up.
        let app = StatusPopover.isSnapshot ? nil : NSRunningApplication(processIdentifier: listener.pid)
        let colors = listener.proto == .tcp ? Palette.accent : Palette.udp
        HStack(spacing: 10) {
            Text(String(listener.port))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 62, alignment: .leading)
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(app?.localizedName ?? listener.command)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(verbatim: "\(listener.proto.rawValue) · PID \(listener.pid) · \(listener.scope)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering || scanner.copied == listener.id {
                HStack(spacing: 4) {
                    GlassIconButton(scanner.copied == listener.id ? "checkmark" : "doc.on.doc", help: "Copy localhost:\(listener.port)") {
                        scanner.copy(listener)
                    }
                    if listener.proto == .tcp {
                        GlassIconButton("safari", help: "Open http://localhost:\(listener.port)") { scanner.open(listener) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Icon

//: a wall socket panel with a glowing port

func appIcon() -> NSBitmapImageRep {
    render(0x3A4556, 0x161B24) { ctx in
        // Soft orange glow from the centre.
        radial([rgb(0xFF8A3D, 0.45), rgb(0xFF8A3D, 0)], center: CGPoint(x: 512, y: 500), radius: 420, in: ctx)
        // Faceplate.
        let plate = CGRect(x: 262, y: 230, width: 500, height: 560)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.45)
        ctx.addPath(roundedRect(plate, 96))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(plate, 96))
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xDCE2EA)], from: CGPoint(x: 0, y: plate.maxY), to: CGPoint(x: 0, y: plate.minY), in: ctx)
        ctx.restoreGState()
        // Two ports, the upper one live.
        for (i, y) in [CGFloat(560), 330].enumerated() {
            let port = CGRect(x: 372, y: y, width: 280, height: 150)
            ctx.addPath(roundedRect(port, 34))
            ctx.setFillColor(rgb(0x262E3B).cgColor)
            ctx.fillPath()
            // Contacts.
            ctx.setFillColor((i == 0 ? rgb(0xFFB25C) : rgb(0x5B6678)).cgColor)
            for k in 0..<4 {
                ctx.addPath(roundedRect(CGRect(x: port.minX + 46 + CGFloat(k) * 52, y: port.maxY - 54, width: 30, height: 30), 6))
            }
            ctx.fillPath()
            if i == 0 {
                ctx.saveGState()
                ctx.setShadow(offset: .zero, blur: 30, color: rgb(0xFF8A3D).cgColor)
                ctx.setFillColor(rgb(0xFF8A3D).cgColor)
                ctx.addPath(roundedRect(CGRect(x: port.minX + 40, y: port.minY + 26, width: port.width - 80, height: 18), 9))
                ctx.fillPath()
                ctx.restoreGState()
            }
        }
        // Screws.
        ctx.setFillColor(rgb(0xB9C2CE).cgColor)
        for y in [CGFloat(750), 270] { ctx.fillEllipse(in: CGRect(x: 512 - 18, y: y - 18, width: 36, height: 36)) }
    }
}
