import AppKit
import Combine
import Darwin
import Kit
import SwiftUI
import SystemConfiguration

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
    private var cancellables: Set<AnyCancellable> = []
    let book = AddressBook()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "network", accessibilityLabel: "Address") {
            AddressView().environmentObject(self.book)
        }
        book.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        // The first IPv4 across interfaces, so an IPv6-only primary interface does not blank the title.
        let primary = book.interfaces.lazy.flatMap(\.addresses).first { $0.family == .v4 }
        status.setTitle(book.showInBar ? primary?.text ?? "" : "")
    }
}

// MARK: - Model

struct IPAddress: Hashable {
    enum Family { case v4, v6 }
    let text: String
    let family: Family

    /// fe80::/10 addresses only work on the local link.
    var isLinkLocal: Bool { family == .v6 && text.lowercased().hasPrefix("fe80") }
    var isLoopback: Bool { text == "127.0.0.1" || text == "::1" }

    var kind: String {
        switch family {
        case .v4: IPAddress.isPrivate(text) ? "IPv4, private" : "IPv4"
        case .v6: isLinkLocal ? "IPv6, link-local" : text.lowercased().hasPrefix("fd") ? "IPv6, private" : "IPv6"
        }
    }

    static func isPrivate(_ v4: String) -> Bool {
        let p = v4.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168)
            || (p[0] == 169 && p[1] == 254) || (p[0] == 100 && (64...127).contains(p[1]))
    }
}

struct NetInterface: Identifiable, Equatable {
    let id: String
    let name: String
    var addresses: [IPAddress]

    var symbol: String {
        let n = name.lowercased()
        if n.contains("wi-fi") { return "wifi" }
        if n.contains("thunderbolt") { return "bolt.horizontal.fill" }
        if id.hasPrefix("utun") || id.hasPrefix("ipsec") { return "lock.shield.fill" }
        if id.hasPrefix("bridge") { return "point.3.connected.trianglepath.dotted" }
        return "cable.connector.horizontal"
    }
}

enum Addresses {
    /// Every IPv4 and IPv6 address on the Mac, grouped by interface, primary interfaces first.
    static func read() -> [NetInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: [IPAddress]] = [:]
        var order: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            // Drop the "%en0" scope suffix of link-local addresses.
            let text = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
            let address = IPAddress(text: text, family: family == AF_INET ? .v4 : .v6)
            let name = String(cString: ifa.ifa_name)
            guard !address.isLoopback else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(address)
        }
        let names = displayNames()
        return order.compactMap { bsd in
            let all = byName[bsd] ?? []
            // Interfaces with only link-local addresses (AirDrop, idle tunnels) are noise.
            guard all.contains(where: { !$0.isLinkLocal }) else { return nil }
            let sorted = all.sorted { rank($0) < rank($1) }
            return NetInterface(id: bsd, name: names[bsd] ?? (bsd.hasPrefix("utun") ? "VPN" : bsd), addresses: sorted)
        }
        .sorted { priority($0.id) < priority($1.id) }
    }

    private static func rank(_ a: IPAddress) -> Int { a.family == .v4 ? 0 : a.isLinkLocal ? 2 : 1 }

    private static func priority(_ bsd: String) -> Int {
        bsd.hasPrefix("en") ? 0 : bsd.hasPrefix("bridge") ? 2 : 1
    }

    static func displayNames() -> [String: String] {
        var names: [String: String] = [:]
        for interface in SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [] {
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
               let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                names[bsd] = display
            }
        }
        return names
    }

    /// Fixed documentation-range addresses (RFC 5737, RFC 3849) for published screenshots.
    /// Nothing is read from the Mac, so no real interface or address can leak.
    static let demo: [NetInterface] = [
        NetInterface(id: "en0", name: "Wi-Fi", addresses: [
            IPAddress(text: "192.0.2.24", family: .v4),
            IPAddress(text: "2001:db8:85a3::8a2e:370:7334", family: .v6),
        ]),
        NetInterface(id: "utun4", name: "VPN", addresses: [
            IPAddress(text: "192.0.2.101", family: .v4),
            IPAddress(text: "fd00:db8::52c:1", family: .v6),
        ]),
    ]
    static let demoPublic = "203.0.113.42"
}

@MainActor
final class AddressBook: ObservableObject {
    enum Public: Equatable { case idle, loading, value(String), failed }

    @Published private(set) var interfaces: [NetInterface] = []
    @Published private(set) var publicIP = Public.idle
    @Published var copied: String?
    @AppStorage("showInBar") var showInBar = false

    private let snapshot = CommandLine.arguments.contains("--snapshot")
    private var timer: Timer?

    init() {
        if snapshot {
            interfaces = Addresses.demo
            publicIP = .value(Addresses.demoPublic)
            return
        }
        refresh()
        // Addresses change with the network; a light poll catches DHCP renewals and VPNs.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 1
    }

    func refresh() {
        guard !snapshot else { return }
        let now = Addresses.read()
        if now != interfaces { interfaces = now }
    }

    /// Asks ipify for the address the internet sees. Only when the panel opens or on request.
    func lookUpPublic() {
        guard !snapshot, publicIP != .loading else { return }
        publicIP = .loading
        Task {
            var request = URLRequest(url: URL(string: "https://api.ipify.org")!, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 8)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            let text = try? await URLSession.shared.data(for: request).0
            let ip = text.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
            withAnimation(.snappy) {
                publicIP = ip.flatMap { $0.isEmpty || $0.count > 45 ? nil : $0 }.map(Public.value) ?? .failed
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.snappy) { copied = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copied == text { withAnimation(.snappy) { self?.copied = nil } }
        }
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 0.8, green: 0.48, blue: 1), Color(red: 0.47, green: 0.22, blue: 0.86)]
}

struct AddressView: View {
    @EnvironmentObject var book: AddressBook

    var body: some View {
        VStack(spacing: 0) {
            PublicCard()
                .padding(12)
            VStack(spacing: 8) {
                if book.interfaces.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "network.slash").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("No network connection. Addresses appear when you connect.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 20)
                }
                ForEach(book.interfaces) { InterfaceCard(interface: $0) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Text("Click any address to copy it")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 10)
            Divider().opacity(0.5)
            PanelFooter(name: "Address") {
                Toggle("Show IP Address in Menu Bar", isOn: $book.showInBar)
                Button("Open Network Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                }
            }
        }
        .frame(width: 340)
        .animation(.snappy, value: book.interfaces)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            book.refresh()
            book.lookUpPublic()
        }
    }
}

struct PublicCard: View {
    @EnvironmentObject var book: AddressBook

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "globe.americas.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Circle().fill(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .shadow(color: Palette.accent[1].opacity(0.4), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Public IP").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                switch book.publicIP {
                case .idle:
                    Button("Look up") { book.lookUpPublic() }
                        .buttonStyle(.link)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                case .loading:
                    Text("Looking up…").font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                case .value(let ip):
                    CopyableText(text: ip, font: .system(size: 19, weight: .semibold, design: .rounded))
                case .failed:
                    Text("Could not reach ipify.org").font(.system(size: 13, weight: .medium)).foregroundStyle(.orange)
                }
            }
            Spacer()
            GlassIconButton("arrow.clockwise", help: "Look up again") { book.lookUpPublic() }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct InterfaceCard: View {
    let interface: NetInterface

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: interface.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom))
                    .frame(width: 18)
                Text(interface.name).font(.system(size: 13, weight: .semibold))
                Text(interface.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(interface.addresses, id: \.self) { AddressRow(address: $0) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct AddressRow: View {
    let address: IPAddress

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            CopyableText(text: address.text, font: .system(size: address.family == .v4 ? 14 : 12, weight: .medium, design: .monospaced))
            Spacer(minLength: 8)
            Text(address.kind).font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize()
        }
        .padding(.leading, 25)
    }
}

struct CopyableText: View {
    @EnvironmentObject var book: AddressBook
    let text: String
    let font: Font
    @State private var hovering = false

    var body: some View {
        let copied = book.copied == text
        HStack(spacing: 5) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                .opacity(copied || hovering ? 1 : 0)
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0)))
        .padding(.horizontal, -5)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture { book.copy(text) }
        .help("Copy \(text)")
    }
}

// MARK: - Icon

//: a location pin over a web of connected nodes

func appIcon() -> NSBitmapImageRep {
    render(0xD07BFF, 0x5B21C9) { ctx in
        // A ring of connected nodes behind the pin.
        let hub = CGPoint(x: 512, y: 520)
        let nodes = (0..<6).map { i -> CGPoint in
            let a = CGFloat(i) * .pi / 3 + .pi / 6
            return CGPoint(x: hub.x + cos(a) * 320, y: hub.y + sin(a) * 300)
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(16)
        ctx.setLineJoin(.round)
        ctx.addLines(between: nodes + [nodes[0]])
        ctx.strokePath()
        ctx.setFillColor(rgb(0xF1E4FF).cgColor)
        for n in nodes { ctx.fillEllipse(in: CGRect(x: n.x - 34, y: n.y - 34, width: 68, height: 68)) }

        // Map pin: a circle head tapering to a point.
        let c = CGPoint(x: 512, y: 580), r: CGFloat = 200
        let pin = CGMutablePath()
        pin.move(to: CGPoint(x: 512, y: 190))
        pin.addCurve(to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: 450, y: 300), control2: CGPoint(x: c.x - r, y: c.y - 110))
        pin.addArc(center: c, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        pin.addCurve(to: CGPoint(x: 512, y: 190), control1: CGPoint(x: c.x + r, y: c.y - 110), control2: CGPoint(x: 574, y: 300))
        pin.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 32, alpha: 0.35)
        ctx.addPath(pin)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(pin)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xEBDDFF)], from: CGPoint(x: 0, y: 780), to: CGPoint(x: 0, y: 190), in: ctx)
        ctx.restoreGState()
        // Inner dot.
        ctx.setFillColor(rgb(0x8A3FE6).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 92, y: c.y - 92, width: 184, height: 184))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 36, y: c.y - 36, width: 72, height: 72))
    }
}
