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
    let table = ProcessTable()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "flame.fill", accessibilityLabel: "Hogs") {
            HogsView().environmentObject(self.table)
        }
        table.isOpen = { [weak self] in self?.status.isShown ?? false }
    }
}

// MARK: - Model

struct Proc: Identifiable, Equatable {
    let pid: Int32
    let cpu: Double
    /// Resident memory in bytes.
    let memory: UInt64
    let command: String
    /// Set only for demo rows, which have no running process to take an icon from.
    var bundleID: String? = nil

    var id: Int32 { pid }
}

enum Demo {
    /// Fixed rows for screenshots, which go on a public page: never this Mac's process list.
    static let procs: [Proc] = [
        Proc(pid: 812, cpu: 48.6, memory: 2_310_000_000, command: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Proc(pid: 1204, cpu: 31.2, memory: 1_640_000_000, command: "Safari", bundleID: "com.apple.Safari"),
        Proc(pid: 402, cpu: 18.9, memory: 610_000_000, command: "WindowServer"),
        Proc(pid: 1533, cpu: 12.4, memory: 980_000_000, command: "Photos", bundleID: "com.apple.Photos"),
        Proc(pid: 977, cpu: 7.8, memory: 420_000_000, command: "Music", bundleID: "com.apple.Music"),
        Proc(pid: 1388, cpu: 5.1, memory: 1_120_000_000, command: "Mail", bundleID: "com.apple.mail"),
        Proc(pid: 0, cpu: 4.6, memory: 52_000_000, command: "kernel_task"),
        Proc(pid: 1610, cpu: 3.3, memory: 760_000_000, command: "Notes", bundleID: "com.apple.Notes"),
        Proc(pid: 655, cpu: 2.2, memory: 180_000_000, command: "Finder", bundleID: "com.apple.finder"),
        Proc(pid: 1702, cpu: 1.4, memory: 330_000_000, command: "Preview", bundleID: "com.apple.Preview"),
        Proc(pid: 318, cpu: 0.9, memory: 96_000_000, command: "mds_stores"),
        Proc(pid: 1820, cpu: 0.6, memory: 540_000_000, command: "Calendar", bundleID: "com.apple.iCal"),
    ]
}

enum PS {
    /// Parses `ps -Aceo pid,pcpu,rss,comm`: a header line, then "  PID  %CPU    RSS COMM" columns; names may hold spaces.
    static func parse(_ output: String) -> [Proc] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]),
                  let cpu = Double(parts[1].replacingOccurrences(of: ",", with: ".")), let rss = UInt64(parts[2]) else { return nil }
            return Proc(pid: pid, cpu: cpu, memory: rss * 1024, command: String(parts[3]).trimmingCharacters(in: .whitespaces))
        }
    }

    static func snapshot() -> [Proc] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid,pcpu,rss,comm"]
        // A fixed locale keeps the decimal point a point.
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }
}

enum Sort: String, CaseIterable {
    case cpu = "CPU", memory = "Memory"
}

@MainActor
final class ProcessTable: ObservableObject {
    static let rows = 10

    @Published private(set) var all: [Proc] = []
    @Published private(set) var loaded = false
    @AppStorage("sort") var sort = Sort.cpu

    /// Whether the panel is on screen; set by the app delegate once the status item exists.
    var isOpen: () -> Bool = { false }
    private var timer: Timer?
    private var busy = false

    init() {
        if StatusPopover.isSnapshot {
            all = Demo.procs
            loaded = true
            return
        }
        refresh()
        // Sample every 2 seconds, only while the panel is open.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen() == true { self?.refresh() } }
        }
        timer?.tolerance = 0.3
    }

    var top: [Proc] {
        let sorted = sort == .cpu ? all.sorted { $0.cpu > $1.cpu } : all.sorted { $0.memory > $1.memory }
        return Array(sorted.prefix(Self.rows))
    }

    /// Share of the whole machine: ps reports 100% per core, so the raw sum can pass 1000% on a big Mac.
    var totalCPU: Double { all.reduce(0) { $0 + $1.cpu } / Double(max(ProcessInfo.processInfo.activeProcessorCount, 1)) }
    var totalMemory: UInt64 { all.reduce(0) { $0 + $1.memory } }

    func refresh() {
        guard !busy, !StatusPopover.isSnapshot else { return }
        busy = true
        Task.detached(priority: .utility) {
            let procs = PS.snapshot()
            await MainActor.run {
                self.busy = false
                self.loaded = true
                withAnimation(.snappy) { self.all = procs }
            }
        }
    }

    /// Only regular, visible apps can be quit, and only politely: the same as Quit from their menu.
    static func quittable(_ app: NSRunningApplication?) -> NSRunningApplication? {
        guard let app, app.activationPolicy == .regular, app.processIdentifier != getpid(),
              app.bundleIdentifier != "com.apple.finder" else { return nil }
        return app
    }

    func quit(_ proc: Proc) {
        ProcessTable.quittable(NSRunningApplication(processIdentifier: proc.pid))?.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.refresh() }
    }
}

enum Format {
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    static func cpu(_ value: Double) -> String { value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value) }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 1, green: 0.6, blue: 0.24), Color(red: 0.9, green: 0.22, blue: 0.2)]
    static let memory = [Color(red: 0.98, green: 0.45, blue: 0.62), Color(red: 0.72, green: 0.24, blue: 0.85)]
}

struct HogsView: View {
    @EnvironmentObject var table: ProcessTable
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(table.sort == .cpu ? "Top CPU" : "Top Memory")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Sort.allCases, id: \.self) { s in
                        Button {
                            withAnimation(.snappy) { table.sort = s }
                        } label: {
                            Text(s.rawValue)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(table.sort == s ? .white : .secondary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background {
                                    if table.sort == s {
                                        Capsule()
                                            .fill(LinearGradient(colors: s == .cpu ? Palette.accent : Palette.memory,
                                                                 startPoint: .leading, endPoint: .trailing))
                                            .matchedGeometryEffect(id: "pill", in: namespace)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(3)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            let rows = table.top
            VStack(spacing: 4) {
                if rows.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "hourglass").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text(table.loaded ? "Could not read the process list." : "Reading processes…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 40)
                }
                let peak = table.sort == .cpu ? max(rows.first?.cpu ?? 1, 1) : Double(max(rows.first?.memory ?? 1, 1))
                ForEach(rows) { p in
                    ProcRow(proc: p, fraction: (table.sort == .cpu ? p.cpu : Double(p.memory)) / peak)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Hogs") {
                Button("Open Activity Monitor") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
            }
        }
        .frame(width: 360)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in table.refresh() }
    }

    private var summary: String {
        let count = "\(table.all.count) processes"
        return table.sort == .cpu ? "\(count), \(Format.cpu(table.totalCPU)) CPU in total"
            : "\(count), \(Format.memory(table.totalMemory)) resident in sum"
    }
}

struct ProcRow: View {
    @EnvironmentObject var table: ProcessTable
    let proc: Proc
    let fraction: Double
    @State private var hovering = false

    private var demoIcon: NSImage? {
        guard let id = proc.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var body: some View {
        let app = StatusPopover.isSnapshot ? nil : NSRunningApplication(processIdentifier: proc.pid)
        let quittable = ProcessTable.quittable(app)
        let colors = table.sort == .cpu ? Palette.accent : Palette.memory
        HStack(spacing: 10) {
            Group {
                if let icon = app?.icon ?? demoIcon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.2.fill").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(app?.localizedName ?? proc.command)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Text(String(proc.pid)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer(minLength: 4)
                    Text(table.sort == .cpu ? Format.cpu(proc.cpu) : Format.memory(proc.memory))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.6))
                        Capsule()
                            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * min(1, fraction)))
                    }
                }
                .frame(height: 4)
            }
            if let quittable, hovering {
                GlassIconButton("xmark", help: "Quit \(quittable.localizedName ?? "app")") { table.quit(proc) }
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Icon

//: bars of a chart with the tallest one on fire

func appIcon() -> NSBitmapImageRep {
    render(0xFF9A3C, 0xC2261E) { ctx in
        let base: CGFloat = 200, width: CGFloat = 132
        let bars: [(CGFloat, CGFloat)] = [(272, 170), (432, 270), (592, 380), (752, 210)]
        for (i, (x, h)) in bars.enumerated() {
            let rect = CGRect(x: x - width / 2, y: base, width: width, height: h)
            ctx.saveGState()
            shadow(ctx, y: -10, blur: 22, alpha: 0.28)
            ctx.addPath(roundedRect(rect, 36))
            ctx.setFillColor((i == 2 ? NSColor.white : NSColor.white.withAlphaComponent(0.38)).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        // Flame licking up from the tallest bar.
        let cx: CGFloat = 592, bottom = base + 380 - 40, w: CGFloat = 125, h: CGFloat = 300
        let flame = CGMutablePath()
        flame.move(to: CGPoint(x: cx, y: bottom))
        flame.addCurve(to: CGPoint(x: cx - w, y: bottom + h * 0.4), control1: CGPoint(x: cx - w * 0.7, y: bottom),
                       control2: CGPoint(x: cx - w, y: bottom + h * 0.15))
        flame.addCurve(to: CGPoint(x: cx - 10, y: bottom + h), control1: CGPoint(x: cx - w, y: bottom + h * 0.7),
                       control2: CGPoint(x: cx - 30, y: bottom + h * 0.75))
        flame.addCurve(to: CGPoint(x: cx + w, y: bottom + h * 0.4), control1: CGPoint(x: cx + 40, y: bottom + h * 0.75),
                       control2: CGPoint(x: cx + w, y: bottom + h * 0.68))
        flame.addCurve(to: CGPoint(x: cx, y: bottom), control1: CGPoint(x: cx + w, y: bottom + h * 0.15),
                       control2: CGPoint(x: cx + w * 0.7, y: bottom))
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 30, alpha: 0.3)
        ctx.addPath(flame)
        ctx.setFillColor(rgb(0xFFE07A).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(flame)
        ctx.clip()
        gradient([rgb(0xFFF1A8), rgb(0xFFB02E), rgb(0xFF5A26)], from: CGPoint(x: 0, y: bottom), to: CGPoint(x: 0, y: bottom + h), in: ctx)
        // Inner core.
        ctx.setFillColor(rgb(0xFFF6CF).cgColor)
        ctx.fillEllipse(in: CGRect(x: cx - 52, y: bottom + 16, width: 104, height: 140))
        ctx.restoreGState()
    }
}
