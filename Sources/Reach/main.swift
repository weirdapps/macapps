import AppKit
import Combine
import Kit
import Network
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
    private var cancellables: Set<AnyCancellable> = []
    let probe = ReachProbe()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "dot.radiowaves.left.and.right", accessibilityLabel: "Reach") {
            ReachView().environmentObject(self.probe)
        }
        probe.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) { probe.save() }

    private func updateStatus() {
        status.setSymbol(probe.health.barSymbol(link: probe.link), label: probe.health.title)
        if probe.showLatencyInBar, probe.health != .offline, let ms = probe.samples.last?.milliseconds {
            status.setTitle("\(Int(ms.rounded())) ms")
        } else {
            status.setTitle("")
        }
    }
}

// MARK: - Model

struct Sample: Codable, Equatable {
    var date: Date
    /// nil when the request failed.
    var milliseconds: Double?
}

struct Outage: Codable, Identifiable, Equatable {
    var id = UUID()
    var start: Date
    var end: Date?
    var reason: String

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

enum Link: Equatable {
    case wifi, ethernet, cellular, other, none

    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .ethernet: "Ethernet"
        case .cellular: "Cellular"
        case .other: "Other network"
        case .none: "No network"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .ethernet: "cable.connector.horizontal"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .other: "network"
        case .none: "wifi.slash"
        }
    }
}

enum Health: Equatable {
    case checking, good, slow, offline

    var title: String {
        switch self {
        case .checking: "Checking"
        case .good: "Online"
        case .slow: "Slow"
        case .offline: "Offline"
        }
    }

    var colors: [Color] {
        switch self {
        case .checking: [Color(white: 0.7), Color(white: 0.5)]
        case .good: Palette.accent
        case .slow: [Color(red: 1, green: 0.78, blue: 0.3), Color(red: 0.95, green: 0.5, blue: 0.1)]
        case .offline: [Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.88, green: 0.16, blue: 0.2)]
        }
    }

    func barSymbol(link: Link) -> String {
        switch self {
        case .offline: "wifi.exclamationmark"
        case .slow: "tortoise.fill"
        default: link == .none ? "wifi.slash" : "dot.radiowaves.left.and.right"
        }
    }
}

enum Stats {
    /// Average, minimum, maximum of the successful samples and the share that failed.
    static func summary(_ samples: [Sample]) -> (avg: Double, min: Double, max: Double, loss: Double)? {
        guard !samples.isEmpty else { return nil }
        let ok = samples.compactMap(\.milliseconds)
        let loss = Double(samples.count - ok.count) / Double(samples.count)
        guard !ok.isEmpty else { return (0, 0, 0, loss) }
        return (ok.reduce(0, +) / Double(ok.count), ok.min()!, ok.max()!, loss)
    }

    static func duration(_ interval: TimeInterval) -> String {
        let s = Int(interval.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s / 60 % 60) min"
    }
}

@MainActor
final class ReachProbe: ObservableObject {
    static let capacity = 60
    static let defaultURL = "https://www.apple.com/library/test/success.html"
    static let slowThreshold = 300.0

    @Published private(set) var link = Link.none
    @Published private(set) var expensive = false
    @Published private(set) var constrained = false
    @Published private(set) var pathUp = true
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var outages: [Outage]
    @AppStorage("testURL") var testURL = ReachProbe.defaultURL
    @AppStorage("showLatencyInBar") var showLatencyInBar = true

    private let monitor = NWPathMonitor()
    private var timer: Timer?
    private var inFlight = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    var health: Health {
        if !pathUp { return .offline }
        guard let last = samples.last else { return .checking }
        guard let ms = last.milliseconds else { return .offline }
        return ms > Self.slowThreshold ? .slow : .good
    }

    init() {
        outages = Storage.load([Outage].self, app: "Reach", file: "outages.json") ?? []
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.update(path) }
        }
        monitor.start(queue: .global(qos: .utility))
        let snapshot = CommandLine.arguments.contains("--snapshot")
        let launch = Date()
        timer = Timer.scheduledTimer(withTimeInterval: snapshot ? 0.15 : 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if snapshot && Date().timeIntervalSince(launch) > 1.2 { return }
                self?.measure()
            }
        }
        timer?.tolerance = snapshot ? 0.01 : 1
        measure()
    }

    private func update(_ path: NWPath) {
        link = path.status != .satisfied ? .none
            : path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.wiredEthernet) ? .ethernet
            : path.usesInterfaceType(.cellular) ? .cellular : .other
        expensive = path.isExpensive
        constrained = path.isConstrained
        let up = path.status == .satisfied
        if up != pathUp {
            pathUp = up
            up ? endOutage() : beginOutage(reason: "Network connection lost")
            measure()
        }
    }

    /// Times one HEAD request. The connection is reused between samples, so this tracks round trip time.
    func measure() {
        guard !inFlight, let url = URL(string: testURL), url.scheme?.hasPrefix("http") == true else { return }
        guard pathUp else {
            record(nil)
            return
        }
        inFlight = true
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let started = Date()
        Task {
            var ms: Double?
            if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, http.statusCode < 500 {
                ms = Date().timeIntervalSince(started) * 1000
            }
            inFlight = false
            record(ms)
        }
    }

    private func record(_ ms: Double?) {
        samples = Array((samples + [Sample(date: Date(), milliseconds: ms)]).suffix(Self.capacity))
        if ms == nil, pathUp { beginOutage(reason: "No response from \(URL(string: testURL)?.host ?? "server")") }
        if ms != nil { endOutage() }
    }

    private func beginOutage(reason: String) {
        guard outages.first?.end != nil || outages.isEmpty else { return }
        outages.insert(Outage(start: Date(), reason: reason), at: 0)
        outages = Array(outages.prefix(100))
        save()
    }

    private func endOutage() {
        guard let first = outages.first, first.end == nil else { return }
        outages[0].end = Date()
        save()
    }

    func clearLog() {
        outages.removeAll { $0.end != nil }
        save()
    }

    func save() { Storage.save(outages, app: "Reach", file: "outages.json") }

    func editURL() {
        let alert = NSAlert()
        alert.messageText = "Test URL"
        alert.informativeText = "Reach sends a HEAD request to this address every 10 seconds and times the reply."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = testURL
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Default")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host != nil { testURL = text }
        case .alertThirdButtonReturn:
            testURL = Self.defaultURL
        default:
            return
        }
        samples = []
        measure()
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 0.25, green: 0.86, blue: 0.76), Color(red: 0.05, green: 0.55, blue: 0.6)]
}

struct ReachView: View {
    @EnvironmentObject var probe: ReachProbe

    var body: some View {
        VStack(spacing: 0) {
            StatusHeader()
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 8) {
                LatencyChart(samples: probe.samples, capacity: ReachProbe.capacity)
                    .frame(height: 70)
                StatsRow()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
            .padding(.horizontal, 12)
            OutageLog()
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Reach") {
                Toggle("Show Latency in Menu Bar", isOn: $probe.showLatencyInBar)
                Button("Change Test URL…") { probe.editURL() }
                Button("Clear Outage Log") { probe.clearLog() }
            }
        }
        .frame(width: 340)
        .animation(.snappy, value: probe.health)
        .animation(.snappy, value: probe.outages)
    }
}

struct StatusHeader: View {
    @EnvironmentObject var probe: ReachProbe

    var body: some View {
        let health = probe.health
        HStack(spacing: 13) {
            Image(systemName: probe.link.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(LinearGradient(colors: health.colors, startPoint: .top, endPoint: .bottom)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                .shadow(color: health.colors[1].opacity(0.4), radius: 6, y: 3)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                Text(health.title).font(.system(size: 20, weight: .bold, design: .rounded))
                HStack(spacing: 5) {
                    Text(probe.link == .none ? "No network" : "via \(probe.link.title)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if probe.expensive { Tag(text: "Expensive") }
                    if probe.constrained { Tag(text: "Low Data") }
                }
            }
            Spacer()
            if let ms = probe.samples.last?.milliseconds {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(ms.rounded()))")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("ms").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(.orange.opacity(0.14)))
    }
}

struct LatencyChart: View {
    let samples: [Sample]
    let capacity: Int

    var body: some View {
        Canvas { ctx, size in
            let peak = max(samples.compactMap(\.milliseconds).max() ?? 0, 100)
            let slot = size.width / CGFloat(capacity)
            let start = size.width - CGFloat(samples.count) * slot
            for f in [0.5] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * f))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            for (i, s) in samples.enumerated() {
                let x = start + CGFloat(i) * slot + 1
                let w = max(1.5, slot - 2)
                if let ms = s.milliseconds {
                    let h = max(3, CGFloat(ms / peak) * (size.height - 12))
                    let colors = ms > ReachProbe.slowThreshold ? Health.slow.colors : Palette.accent
                    let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, w / 2)),
                             with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 0, y: rect.minY),
                                                   endPoint: CGPoint(x: 0, y: rect.maxY)))
                } else {
                    let rect = CGRect(x: x, y: 0, width: w, height: size.height)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, w / 2)), with: .color(.red.opacity(0.3)))
                }
            }
            ctx.draw(Text("\(Int(peak)) ms").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary),
                     at: CGPoint(x: 0, y: 0), anchor: .topLeading)
            if samples.isEmpty {
                ctx.draw(Text("Measuring…").font(.system(size: 11)).foregroundStyle(.secondary),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
    }
}

struct StatsRow: View {
    @EnvironmentObject var probe: ReachProbe

    var body: some View {
        let s = Stats.summary(probe.samples)
        HStack {
            Stat(title: "Average", value: s.map { "\(Int($0.avg.rounded())) ms" } ?? "n/a")
            Spacer()
            Stat(title: "Best", value: s.map { "\(Int($0.min.rounded())) ms" } ?? "n/a")
            Spacer()
            Stat(title: "Worst", value: s.map { "\(Int($0.max.rounded())) ms" } ?? "n/a")
            Spacer()
            Stat(title: "Failed", value: s.map { "\(Int(($0.loss * 100).rounded()))%" } ?? "n/a")
        }
    }
}

struct Stat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct OutageLog: View {
    @EnvironmentObject var probe: ReachProbe

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Outages").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if probe.outages.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom))
                    Text("No outages so far. Drops are logged here.")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
                .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(probe.outages.prefix(30)) { OutageRow(outage: $0) }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OutageRow: View {
    let outage: Outage

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(outage.end == nil ? Color.red : Color.orange).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 0) {
                Text(outage.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.system(size: 12, weight: .medium))
                Text(outage.reason).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(outage.end == nil ? "Ongoing" : Stats.duration(outage.duration))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(outage.end == nil ? .red : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

// MARK: - Icon

//: a globe pinged by expanding signal rings

func appIcon() -> NSBitmapImageRep {
    render(0x3EE0C8, 0x0B6E86) { ctx in
        let c = CGPoint(x: 512, y: 470)
        // Signal rings radiating from the globe.
        ctx.setLineCap(.round)
        for (i, r) in [CGFloat(250), 320, 390].enumerated() {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55 - CGFloat(i) * 0.15).cgColor)
            ctx.setLineWidth(34)
            ctx.addArc(center: c, radius: r, startAngle: .pi * 0.22, endAngle: .pi * 0.78, clockwise: false)
            ctx.strokePath()
        }
        // Globe.
        let g = CGRect(x: c.x - 170, y: c.y - 170, width: 340, height: 340)
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.32)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: g)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: g)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xD5F6F1)], from: CGPoint(x: 0, y: g.maxY), to: CGPoint(x: 0, y: g.minY), in: ctx)
        ctx.setStrokeColor(rgb(0x19A7A0).cgColor)
        ctx.setLineWidth(18)
        ctx.strokeEllipse(in: g.insetBy(dx: 9, dy: 9))
        ctx.strokeEllipse(in: CGRect(x: c.x - 70, y: g.minY + 9, width: 140, height: g.height - 18))
        ctx.move(to: CGPoint(x: c.x, y: g.minY)); ctx.addLine(to: CGPoint(x: c.x, y: g.maxY))
        ctx.move(to: CGPoint(x: g.minX, y: c.y)); ctx.addLine(to: CGPoint(x: g.maxX, y: c.y))
        ctx.strokePath()
        for dy in [CGFloat(-90), 90] {
            let half = sqrt(170 * 170 - dy * dy)
            ctx.move(to: CGPoint(x: c.x - half, y: c.y + dy)); ctx.addLine(to: CGPoint(x: c.x + half, y: c.y + dy))
        }
        ctx.strokePath()
        ctx.restoreGState()
        // A bright ping dot riding the outer ring.
        let a = CGFloat.pi * 0.36
        let p = CGPoint(x: c.x + cos(a) * 390, y: c.y + sin(a) * 390)
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 22, alpha: 0.3)
        ctx.setFillColor(rgb(0xFFE36E).cgColor)
        ctx.fillEllipse(in: CGRect(x: p.x - 40, y: p.y - 40, width: 80, height: 80))
        ctx.restoreGState()
    }
}
