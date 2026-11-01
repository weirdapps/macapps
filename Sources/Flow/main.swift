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
    let meter = TrafficMeter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "arrow.up.arrow.down", accessibilityLabel: "Flow") {
            FlowView().environmentObject(self.meter)
        }
        meter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        let down = Rate.compact(meter.down, bits: meter.bits), up = Rate.compact(meter.up, bits: meter.bits)
        switch meter.barShows {
        case .both:
            status.setSymbol("", label: "Flow")
            status.setTitle("↓\(down) ↑\(up)")
        case .download:
            status.setSymbol("", label: "Flow")
            status.setTitle("↓\(down)")
        case .icon:
            status.setSymbol("arrow.up.arrow.down", label: "Flow")
            status.setTitle("")
        }
    }
}

// MARK: - Counters

struct Counter: Equatable {
    var received: UInt64
    var sent: UInt64
}

enum Interfaces {
    /// 64-bit byte counters for every interface, from the routing table's `if_msghdr2` records.
    /// (`getifaddrs` exposes the same counters as 32-bit values, which wrap every 4 GB.)
    static func counters() -> [String: Counter] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counter] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2 {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil {
                        result[String(cString: name)] = Counter(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    /// Interfaces whose traffic counts toward the total. Tunnels and bridges would count the same bytes twice.
    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("pdp_ip")
    }

    static func isHidden(_ name: String) -> Bool {
        ["lo", "gif", "stf", "awdl", "llw", "anpi", "ap", "XHC"].contains { name.hasPrefix($0) }
    }

    /// "Wi-Fi", "Ethernet", "Thunderbolt Bridge" from System Configuration, keyed by BSD name.
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
}

enum Rate {
    /// Fixed-width text for the menu bar, so the item does not jiggle: "1.2M", " 80K".
    static func compact(_ bytesPerSecond: Double, bits: Bool) -> String {
        var value = bits ? bytesPerSecond * 8 : bytesPerSecond
        var unit = 0
        let units = bits ? ["b", "Kb", "Mb", "Gb"] : ["B", "K", "M", "G"]
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let number = value < 9.95 && unit > 0 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        let padded = String(repeating: "\u{2007}", count: max(0, 3 - number.count)) + number
        return padded + units[unit]
    }

    /// Full text for the panel: "1.2 MB/s", "80 KB/s", "9.6 Mbps".
    static func full(_ bytesPerSecond: Double, bits: Bool) -> String {
        var value = bits ? bytesPerSecond * 8 : bytesPerSecond
        var unit = 0
        let units = bits ? ["bps", "Kbps", "Mbps", "Gbps"] : ["B/s", "KB/s", "MB/s", "GB/s"]
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return (value < 9.95 && unit > 0 ? String(format: "%.1f ", value) : String(format: "%.0f ", value)) + units[unit]
    }

    /// Decimal units as Finder uses them: "56 KB", "1.4 GB".
    static func bytes(_ count: UInt64) -> String {
        var value = Double(count)
        var unit = 0
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        while value >= 999.5 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return (value < 9.95 && unit > 0 ? String(format: "%.1f ", value) : String(format: "%.0f ", value)) + units[unit]
    }
}

struct InterfaceTotal: Identifiable, Equatable {
    let id: String
    let name: String
    var received: UInt64
    var sent: UInt64
}

enum BarShows: String, CaseIterable {
    case both, download, icon

    var title: String {
        switch self {
        case .both: "Download and Upload"
        case .download: "Download Only"
        case .icon: "Icon Only"
        }
    }
}

@MainActor
final class TrafficMeter: ObservableObject {
    static let capacity = 60

    @Published private(set) var down = 0.0
    @Published private(set) var up = 0.0
    @Published private(set) var history: [(down: Double, up: Double)] = []
    @Published private(set) var totals: [InterfaceTotal] = []
    @AppStorage("barShows") var barShows = BarShows.both
    @AppStorage("bits") var bits = false

    private var start: [String: Counter]
    private var last: [String: Counter]
    private var lastTime = Date()
    private var names = Interfaces.displayNames()
    private var timer: Timer?

    init() {
        start = Interfaces.counters()
        last = start
        // Screenshots go on a public page: show fixed demo traffic, never this Mac's interfaces.
        if StatusPopover.isSnapshot {
            loadDemo()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 0.1
    }

    private func loadDemo() {
        history = (0..<Self.capacity).map { i in
            let t = Double(i)
            let down = 2_400_000 + 1_600_000 * sin(t / 5) + 900_000 * sin(t / 1.7) + (i > 44 && i < 52 ? 3_500_000 : 0)
            let up = 380_000 + 220_000 * sin(t / 3.3 + 1) + 90_000 * cos(t / 1.3)
            return (max(down, 60_000), max(up, 20_000))
        }
        down = history.last?.down ?? 0
        up = history.last?.up ?? 0
        totals = [
            InterfaceTotal(id: "en0", name: "Wi-Fi", received: 1_842_000_000, sent: 212_400_000),
            InterfaceTotal(id: "en7", name: "USB 10/100/1000 LAN", received: 386_000_000, sent: 41_300_000),
        ]
    }

    private func sample() {
        let now = Interfaces.counters(), time = Date()
        let elapsed = time.timeIntervalSince(lastTime)
        guard elapsed > 0 else { return }
        var received: UInt64 = 0, sent: UInt64 = 0
        for (name, c) in now where Interfaces.isPhysical(name) {
            guard let old = last[name] else { continue }
            // A counter that went backwards was reset (interface restarted); skip it this round.
            received += c.received >= old.received ? c.received - old.received : 0
            sent += c.sent >= old.sent ? c.sent - old.sent : 0
        }
        down = Double(received) / elapsed
        up = Double(sent) / elapsed
        history = Array((history + [(down, up)]).suffix(Self.capacity))
        last = now
        lastTime = time

        for (name, c) in now where start[name] == nil { start[name] = c }
        // Idle tunnels only send keepalives; list a tunnel once it carried real traffic.
        let tunnelFloor: UInt64 = 64_000
        if now.keys.contains(where: { names[$0] == nil && Interfaces.isPhysical($0) }) { names = Interfaces.displayNames() }
        totals = now.compactMap { name, c in
            guard !Interfaces.isHidden(name), let s = start[name] else { return nil }
            let r = c.received >= s.received ? c.received - s.received : c.received
            let t = c.sent >= s.sent ? c.sent - s.sent : c.sent
            guard r + t > (name.hasPrefix("utun") ? tunnelFloor : 0) else { return nil }
            return InterfaceTotal(id: name, name: names[name] ?? (name.hasPrefix("utun") ? "VPN" : name), received: r, sent: t)
        }
        .sorted { $0.received + $0.sent > $1.received + $1.sent }
    }
}

// MARK: - Views

enum Palette {
    static let down = [Color(red: 0.31, green: 0.75, blue: 1), Color(red: 0.0, green: 0.42, blue: 0.9)]
    static let up = [Color(red: 1, green: 0.55, blue: 0.75), Color(red: 0.92, green: 0.25, blue: 0.55)]
}

struct FlowView: View {
    @EnvironmentObject var meter: TrafficMeter

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                RateBlock(symbol: "arrow.down", title: "Download", value: Rate.full(meter.down, bits: meter.bits), colors: Palette.down)
                RateBlock(symbol: "arrow.up", title: "Upload", value: Rate.full(meter.up, bits: meter.bits), colors: Palette.up)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            MirrorChart(history: meter.history, capacity: TrafficMeter.capacity, bits: meter.bits)
                .frame(height: 96)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            VStack(spacing: 6) {
                HStack {
                    Text("Since launch").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
                if meter.totals.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "network.slash")
                        Text("No traffic yet. Totals per connection appear here.")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                ForEach(meter.totals) { InterfaceRow(total: $0) }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Flow") {
                Picker("Menu Bar Shows", selection: $meter.barShows) {
                    ForEach(BarShows.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show Bits per Second", isOn: $meter.bits)
            }
        }
        .frame(width: 340)
        .animation(.snappy, value: meter.totals)
    }
}

struct RateBlock: View {
    let symbol: String
    let title: String
    let value: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
                .shadow(color: colors[1].opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Download grows up from the centre line and upload grows down, on a shared scale.
struct MirrorChart: View {
    let history: [(down: Double, up: Double)]
    let capacity: Int
    let bits: Bool

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            guard history.count > 1 else { return }
            let peak = max(history.map { max($0.down, $0.up) }.max() ?? 0, 1024)
            let step = size.width / CGFloat(capacity - 1)
            let start = size.width - CGFloat(history.count - 1) * step
            func series(_ values: [Double], sign: CGFloat, colors: [Color]) {
                let points = values.enumerated().map { i, v in
                    CGPoint(x: start + CGFloat(i) * step, y: mid - sign * CGFloat(v / peak) * (mid - 2))
                }
                var line = Path()
                line.addLines(points)
                var area = line
                area.addLine(to: CGPoint(x: points.last!.x, y: mid))
                area.addLine(to: CGPoint(x: points[0].x, y: mid))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [colors[0].opacity(0.45), colors[0].opacity(0.05)]),
                                                     startPoint: CGPoint(x: 0, y: mid - sign * mid), endPoint: CGPoint(x: 0, y: mid)))
                ctx.stroke(line, with: .color(colors[1]), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            }
            series(history.map(\.down), sign: 1, colors: Palette.down)
            series(history.map(\.up), sign: -1, colors: Palette.up)
            ctx.draw(Text(Rate.full(peak, bits: bits)).font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary),
                     at: CGPoint(x: 2, y: 2), anchor: .topLeading)
        }
    }
}

struct InterfaceRow: View {
    @EnvironmentObject var meter: TrafficMeter
    let total: InterfaceTotal
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: Palette.down, startPoint: .top, endPoint: .bottom))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(total.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(total.id).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Label(Rate.bytes(total.received), systemImage: "arrow.down")
                Label(Rate.bytes(total.sent), systemImage: "arrow.up")
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .labelStyle(TrailingIconLabel())
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var symbol: String {
        let n = total.name.lowercased()
        if n.contains("wi-fi") { return "wifi" }
        if n.contains("thunderbolt") { return "bolt.horizontal.fill" }
        if n.contains("vpn") || total.id.hasPrefix("utun") { return "lock.shield.fill" }
        if total.id.hasPrefix("pdp_ip") || n.contains("iphone") { return "antenna.radiowaves.left.and.right" }
        return "cable.connector"
    }
}

struct TrailingIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.title
            configuration.icon.font(.system(size: 8, weight: .bold))
        }
    }
}

// MARK: - Icon

//: two crossing streams, one down and one up

func appIcon() -> NSBitmapImageRep {
    render(0x4FB8FF, 0x0A4FD6) { ctx in
        // Faint wave bands behind.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.1).cgColor)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        for i in 0..<4 {
            let y = 220 + CGFloat(i) * 190
            ctx.move(to: CGPoint(x: 100, y: y))
            ctx.addCurve(to: CGPoint(x: 924, y: y), control1: CGPoint(x: 380, y: y + 90), control2: CGPoint(x: 640, y: y - 90))
        }
        ctx.strokePath()

        func arrow(x: CGFloat, down: Bool, colors: [NSColor]) {
            let top: CGFloat = 740, bottom: CGFloat = 284, w: CGFloat = 104, head: CGFloat = 140
            let tip = down ? bottom : top
            let base = down ? bottom + head : top - head
            let tail = down ? top : bottom
            let path = CGMutablePath()
            path.move(to: CGPoint(x: x - w / 2, y: tail))
            path.addLine(to: CGPoint(x: x - w / 2, y: base))
            path.addLine(to: CGPoint(x: x - w * 1.15, y: base))
            path.addLine(to: CGPoint(x: x, y: tip))
            path.addLine(to: CGPoint(x: x + w * 1.15, y: base))
            path.addLine(to: CGPoint(x: x + w / 2, y: base))
            path.addLine(to: CGPoint(x: x + w / 2, y: tail))
            path.closeSubpath()
            // Round every corner by growing the outline with a round-joined stroke.
            let soft = path.union(path.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 10))
            ctx.saveGState()
            shadow(ctx, y: -14, blur: 28, alpha: 0.3)
            ctx.addPath(soft)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(soft)
            ctx.clip()
            gradient(colors, from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bottom), in: ctx)
            ctx.restoreGState()
        }
        arrow(x: 390, down: true, colors: [rgb(0xFFFFFF), rgb(0xD6ECFF)])
        arrow(x: 634, down: false, colors: [rgb(0xFFD3E6), rgb(0xFF7FB0)])
    }
}
