import AppKit
import Combine
import Darwin
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
    private var cancellables: Set<AnyCancellable> = []
    let monitor = SystemMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "waveform.path.ecg", accessibilityLabel: "Pulse") {
            PulseView().environmentObject(self.monitor)
        }
        monitor.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    private func updateTitle() {
        switch monitor.barShows {
        case .cpu: status.setTitle(Format.percent(monitor.cpu.total))
        case .memory: status.setTitle(Format.percent(monitor.memory.usedFraction))
        case .icon: status.setTitle("")
        }
    }
}

// MARK: - Sampling

/// Raw CPU tick counters; usage is the difference between two readings.
struct CPUTicks: Equatable {
    var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
    var total: UInt64 { user + system + idle + nice }

    /// Busy fractions between an earlier reading and this one.
    func usage(since old: CPUTicks) -> CPUUsage {
        let total = Double(self.total &- old.total)
        guard total > 0 else { return CPUUsage() }
        return CPUUsage(user: Double((user &- old.user) &+ (nice &- old.nice)) / total,
                        system: Double(system &- old.system) / total)
    }
}

struct CPUUsage: Equatable {
    var user = 0.0, system = 0.0
    var total: Double { min(1, user + system) }
}

struct MemoryUsage: Equatable {
    var physical: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
    /// What Activity Monitor calls Memory Used.
    var used: UInt64 { app + wired + compressed }
    var usedFraction: Double { physical > 0 ? min(1, Double(used) / Double(physical)) : 0 }
}

enum Pressure: Int {
    case normal = 1, warning = 2, critical = 4

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

enum Probe {
    private static let host = mach_host_self()

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    /// One reading per logical core.
    static func coreTicks() -> [CPUTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { i in
            let base = i * stride
            return CPUTicks(user: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])),
                            system: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])),
                            idle: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])),
                            nice: UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])))
        }
    }

    static func memory() -> MemoryUsage? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(getpagesize())
        var m = MemoryUsage()
        let purgeable = UInt64(stats.purgeable_count)
        m.app = (UInt64(stats.internal_page_count) - min(purgeable, UInt64(stats.internal_page_count))) * page
        m.wired = UInt64(stats.wire_count) * page
        m.compressed = UInt64(stats.compressor_page_count) * page
        m.cached = (UInt64(stats.external_page_count) + purgeable) * page
        return m
    }

    static func pressure() -> Pressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return Pressure(rawValue: Int(level)) ?? .normal
    }

    static func loadAverages() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : [0, 0, 0]
    }
}

enum BarShows: String, CaseIterable {
    case cpu, memory, icon

    var title: String {
        switch self {
        case .cpu: "CPU Usage"
        case .memory: "Memory Used"
        case .icon: "Icon Only"
        }
    }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let capacity = 60

    @Published private(set) var cpu = CPUUsage()
    @Published private(set) var cores: [Double] = []
    @Published private(set) var memory = MemoryUsage()
    @Published private(set) var pressure = Pressure.normal
    @Published private(set) var loads: [Double] = [0, 0, 0]
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @AppStorage("barShows") var barShows = BarShows.cpu

    private var lastTicks: CPUTicks?
    private var lastCores: [CPUTicks] = []
    private var timer: Timer?

    init() {
        lastTicks = Probe.cpuTicks()
        lastCores = Probe.coreTicks()
        // Screenshots get a full chart of real, faster samples.
        let interval = CommandLine.arguments.contains("--snapshot") ? 0.08 : 2
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.sample() }
    }

    private func sample() {
        if let now = Probe.cpuTicks() {
            if let lastTicks { cpu = now.usage(since: lastTicks) }
            lastTicks = now
        }
        let nowCores = Probe.coreTicks()
        if nowCores.count == lastCores.count {
            cores = zip(nowCores, lastCores).map { $0.usage(since: $1).total }
        }
        lastCores = nowCores
        if let m = Probe.memory() { memory = m }
        pressure = Probe.pressure()
        loads = Probe.loadAverages()
        cpuHistory = Array((cpuHistory + [cpu.total]).suffix(Self.capacity))
        memoryHistory = Array((memoryHistory + [memory.usedFraction]).suffix(Self.capacity))
    }
}

enum Format {
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    static func gigabytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }
}

// MARK: - Views

/// Static members, not top-level lets: `main.swift` globals initialize only when execution reaches them, after `app.run()`.
enum Palette {
    static let accent = [Color(red: 0.36, green: 0.86, blue: 0.95), Color(red: 0.49, green: 0.38, blue: 0.98)]
    static let app = Color(red: 0.49, green: 0.38, blue: 0.98)
    static let wired = Color(red: 0.98, green: 0.55, blue: 0.3)
    static let compressed = Color(red: 0.95, green: 0.35, blue: 0.6)
}

struct PulseView: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                CPUCard()
                MemoryCard()
            }
            .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Pulse") {
                Picker("Menu Bar Shows", selection: $monitor.barShows) {
                    ForEach(BarShows.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
        }
        .frame(width: 340)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct CPUCard: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Text(Format.percent(monitor.cpu.total))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Legend(color: Palette.accent[0], title: "User", value: Format.percent(monitor.cpu.user))
                    Legend(color: Palette.accent[1], title: "System", value: Format.percent(monitor.cpu.system))
                }
            }
            Sparkline(values: monitor.cpuHistory, capacity: SystemMonitor.capacity, colors: Palette.accent)
                .frame(height: 54)
            CoreBars(values: monitor.cores)
            HStack(spacing: 0) {
                Text("Load average").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                ForEach(Array(zip(["1m", "5m", "15m"], monitor.loads)), id: \.0) { label, value in
                    HStack(spacing: 3) {
                        Text(label).foregroundStyle(.tertiary)
                        Text(String(format: "%.2f", value)).monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.leading, 10)
                }
            }
        }
    }
}

struct MemoryCard: View {
    @EnvironmentObject var monitor: SystemMonitor

    var body: some View {
        let m = monitor.memory
        Card {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Format.gigabytes(m.used))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("of \(Format.gigabytes(m.physical))")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(monitor.pressure.color).frame(width: 7, height: 7)
                    Text("Pressure \(monitor.pressure.title)").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(monitor.pressure.color.opacity(0.14)))
            }
            Sparkline(values: monitor.memoryHistory, capacity: SystemMonitor.capacity,
                      colors: [Palette.compressed, Palette.app])
                .frame(height: 40)
            StackedBar(parts: [(m.app, Palette.app), (m.wired, Palette.wired), (m.compressed, Palette.compressed)],
                       total: m.physical)
                .frame(height: 8)
            HStack {
                Legend(color: Palette.app, title: "App", value: Format.gigabytes(m.app))
                Spacer()
                Legend(color: Palette.wired, title: "Wired", value: Format.gigabytes(m.wired))
                Spacer()
                Legend(color: Palette.compressed, title: "Compressed", value: Format.gigabytes(m.compressed))
            }
            HStack {
                Text("Cached files").foregroundStyle(.secondary)
                Spacer()
                Text(Format.gigabytes(m.cached)).monospacedDigit()
            }
            .font(.system(size: 11))
        }
    }
}

struct Legend: View {
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.system(size: 11, design: .rounded))
    }
}

/// A line chart of fractions (0 to 1), filling from the right like Activity Monitor.
struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    let colors: [Color]

    var body: some View {
        Canvas { ctx, size in
            for f in [0.25, 0.5, 0.75] {
                var grid = Path()
                grid.move(to: CGPoint(x: 0, y: size.height * f))
                grid.addLine(to: CGPoint(x: size.width, y: size.height * f))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.15)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(capacity - 1)
            let start = size.width - CGFloat(values.count - 1) * step
            let points = values.enumerated().map { i, v in
                CGPoint(x: start + CGFloat(i) * step, y: size.height - CGFloat(min(max(v, 0), 1)) * (size.height - 2) - 1)
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [colors[1].opacity(0.35), colors[0].opacity(0.03)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .linearGradient(Gradient(colors: colors), startPoint: .zero,
                                                   endPoint: CGPoint(x: size.width, y: 0)),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            let last = points.last!
            ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(colors[1]))
        }
    }
}

struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.quaternary.opacity(0.6))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(LinearGradient(colors: Palette.accent.reversed(), startPoint: .bottom, endPoint: .top))
                        .frame(height: max(2, 22 * v))
                }
                .frame(height: 22)
            }
        }
        .animation(.snappy, value: values)
        .help("\(values.count) cores")
    }
}

struct StackedBar: View {
    let parts: [(UInt64, Color)]
    let total: UInt64

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1)
                        .frame(width: total > 0 ? geo.size.width * CGFloat(part.0) / CGFloat(total) : 0)
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary.opacity(0.6))
            .clipShape(Capsule())
        }
        .animation(.snappy, value: parts.map(\.0))
    }
}

// MARK: - Icon

//: a heartbeat trace over a chart grid

func appIcon() -> NSBitmapImageRep {
    render(0x6B4DF2, 0x241A6B) { ctx in
        // Grid.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.09).cgColor)
        ctx.setLineWidth(6)
        for i in 1..<6 {
            let v = 100 + CGFloat(i) * 824 / 6
            ctx.move(to: CGPoint(x: v, y: 100)); ctx.addLine(to: CGPoint(x: v, y: 924))
            ctx.move(to: CGPoint(x: 100, y: v)); ctx.addLine(to: CGPoint(x: 924, y: v))
        }
        ctx.strokePath()
        // Area under the trace.
        let trace: [CGPoint] = [(100, 470), (300, 470), (360, 400), (430, 720), (510, 250), (580, 560), (630, 470), (924, 470)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        ctx.saveGState()
        ctx.move(to: CGPoint(x: 100, y: 100))
        trace.forEach { ctx.addLine(to: $0) }
        ctx.addLine(to: CGPoint(x: 924, y: 100))
        ctx.closePath()
        ctx.clip()
        gradient([rgb(0x5CE1F2, 0.35), rgb(0x5CE1F2, 0)], from: CGPoint(x: 0, y: 720), to: CGPoint(x: 0, y: 180), in: ctx)
        ctx.restoreGState()
        // Glow, then the trace itself.
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addLines(between: trace)
        ctx.setStrokeColor(rgb(0x5CE1F2, 0.35).cgColor)
        ctx.setLineWidth(80)
        ctx.strokePath()
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 20, alpha: 0.3)
        ctx.addLines(between: trace)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(46)
        ctx.strokePath()
        ctx.restoreGState()
        // Live dot on the peak.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 24, alpha: 0.35)
        ctx.setFillColor(rgb(0x5CE1F2).cgColor)
        ctx.fillEllipse(in: CGRect(x: 430 - 44, y: 720 - 44, width: 88, height: 88))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: 430 - 20, y: 720 - 20, width: 40, height: 40))
    }
}
