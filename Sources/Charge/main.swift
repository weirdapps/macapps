import AppKit
import Combine
import IOKit
import IOKit.ps
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
    let battery = BatteryMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "battery.100percent", accessibilityLabel: "Charge") {
            ChargeView().environmentObject(self.battery)
        }
        battery.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        guard let s = battery.state else {
            status.setSymbol("powerplug.fill", label: "No battery")
            status.setTitle("")
            return
        }
        status.setSymbol(s.symbol, label: "Battery \(s.percent) percent")
        switch battery.barShows {
        case .percent: status.setTitle("\(s.percent)%")
        case .time: status.setTitle(s.minutesLeft.map(Battery.duration) ?? "\(s.percent)%")
        case .icon: status.setTitle("")
        }
    }
}

// MARK: - Model

struct BatteryState: Equatable {
    var percent = 100
    var charging = false
    var charged = false
    /// macOS tops up the last few percent slowly and reports no time estimate meanwhile.
    var finishing = false
    var onAC = true
    /// Minutes to empty on battery, or to full while charging; nil while macOS is still estimating.
    var minutesLeft: Int?
    var cycles: Int?
    var designCycles: Int?
    var health: Int?
    var condition: String?
    var temperature: Double?
    var watts: Double?
    var adapter: String?

    var symbol: String {
        if charging || (onAC && charged) { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    var headline: String {
        if charged && onAC { return "Fully charged" }
        if charging && (finishing || percent >= 100) { return "Finishing charge" }
        if charging { return "Charging" }
        if onAC { return "Not charging" }
        return "On battery"
    }

    var detail: String {
        if charged && onAC { return "Connected to power" }
        if charging && (finishing || percent >= 100) { return "Almost full" }
        guard let minutesLeft else { return onAC ? "Estimating time until full" : "Estimating time remaining" }
        return charging ? "\(Battery.duration(minutesLeft)) until full" : "\(Battery.duration(minutesLeft)) remaining"
    }
}

enum Battery {
    /// Reads every value public APIs offer; nil on a Mac without an internal battery.
    static func read() -> BatteryState? {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef]
        let battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType }
        guard let ps = battery else { return nil }

        var s = BatteryState()
        let current = ps[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = ps[kIOPSMaxCapacityKey] as? Int ?? 100
        s.percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        s.charging = ps[kIOPSIsChargingKey] as? Bool ?? false
        s.charged = ps[kIOPSIsChargedKey] as? Bool ?? false
        s.finishing = ps["Is Finishing Charge"] as? Bool ?? false
        s.onAC = (ps[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let minutes = s.charging ? ps[kIOPSTimeToFullChargeKey] as? Int : ps[kIOPSTimeToEmptyKey] as? Int
        s.minutesLeft = minutes.flatMap { $0 > 0 && $0 < 6000 ? $0 : nil }
        if let health = ps[kIOPSBatteryHealthKey] as? String {
            s.condition = health == "Good" ? "Normal" : "Service Recommended"
        }

        if let reg = registry() {
            let data = reg["BatteryData"] as? [String: Any] ?? [:]
            func number(_ key: String) -> NSNumber? { (reg[key] ?? data[key]) as? NSNumber }
            s.cycles = number("CycleCount")?.intValue
            s.designCycles = number("DesignCycleCount9C")?.intValue
            // Temperature is hidden from non-root processes on recent macOS; the row shows only when it is readable.
            if let t = number("Temperature") ?? number("VirtualTemperature"), t.doubleValue > 0 { s.temperature = t.doubleValue / 100 }
            if let volts = number("Voltage"), let amps = number("InstantAmperage") ?? number("Amperage"), amps.int64Value != 0 {
                s.watts = power(millivolts: volts.doubleValue, milliamps: Double(amps.int64Value))
            }
        }
        if s.onAC, let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            let watts = details[kIOPSPowerAdapterWattsKey] as? Int
            // "96W USB-C Power Adapter" becomes "96W USB-C adapter" so it fits the row.
            s.adapter = (details["Name"] as? String)?.replacingOccurrences(of: " Power Adapter", with: " adapter")
                ?? watts.map { "\($0) W adapter" }
        }
        return s
    }

    /// Read-only properties of the battery controller.
    private static func registry() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return props?.takeRetainedValue() as? [String: Any]
    }

    /// Maximum capacity and condition exactly as System Settings shows them. The registry hides the raw
    /// capacity from non-root processes, so this asks system_profiler, which takes about a second.
    static func profilerHealth() -> ProfilerHealth {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["-json", "SPPowerDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ProfilerHealth() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseProfiler(data)
    }

    static func parseProfiler(_ data: Data) -> ProfilerHealth {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return ProfilerHealth() }
        var h = ProfilerHealth()
        if let max = info["sppower_battery_health_maximum_capacity"] as? String {
            h.maximumCapacity = Int(max.filter(\.isNumber))
        }
        if let health = info["sppower_battery_health"] as? String {
            h.condition = health == "Good" ? "Normal" : "Service Recommended"
        }
        return h
    }

    /// Watts flowing in (positive) or out (negative).
    static func power(millivolts: Double, milliamps: Double) -> Double { millivolts * milliamps / 1_000_000 }

    static func duration(_ minutes: Int) -> String { String(format: "%d:%02d", minutes / 60, minutes % 60) }
}

struct ProfilerHealth: Equatable, Sendable {
    var maximumCapacity: Int?
    var condition: String?
}

enum BarShows: String, CaseIterable {
    case percent, time, icon

    var title: String {
        switch self {
        case .percent: "Percentage"
        case .time: "Time Remaining"
        case .icon: "Icon Only"
        }
    }
}

extension Notification.Name {
    static let powerSourceChanged = Notification.Name("Charge.powerSourceChanged")
}

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var state: BatteryState?
    @AppStorage("barShows") var barShows = BarShows.percent

    private var timer: Timer?
    private var healthTimer: Timer?
    private var observer: NSObjectProtocol?
    private var profiler = ProfilerHealth()

    /// Fixed values for the README snapshot, so the published image never shows this Mac's battery.
    static let sample = BatteryState(percent: 82, charging: false, charged: false, onAC: false, minutesLeft: 312,
                                     cycles: 143, designCycles: 1000, health: 97, condition: "Normal", temperature: 30.5, watts: -6.4)

    init() {
        if StatusPopover.isSnapshot {
            state = Self.sample
            return
        }
        state = Battery.read()
        // macOS calls this whenever percentage, power source or time estimate changes.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            NotificationCenter.default.post(name: .powerSourceChanged, object: nil)
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        observer = NotificationCenter.default.addObserver(forName: .powerSourceChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Power draw and temperature do not post notifications; a slow poll keeps them current.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 3
        loadHealth()
        // Maximum capacity moves over weeks; a slow re-read keeps a long-running app honest.
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadHealth() }
        }
    }

    private func loadHealth() {
        Task { [weak self] in
            let health = await Task.detached(priority: .utility) { Battery.profilerHealth() }.value
            self?.profiler = health
            self?.refresh()
        }
    }

    func refresh() {
        guard !StatusPopover.isSnapshot else { return }
        var now = Battery.read()
        now?.health = profiler.maximumCapacity
        if let condition = profiler.condition { now?.condition = condition }
        if now != state { state = now }
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 0.71, green: 0.93, blue: 0.32), Color(red: 0.2, green: 0.68, blue: 0.3)]
    static let low = [Color(red: 1, green: 0.75, blue: 0.3), Color(red: 0.96, green: 0.5, blue: 0.13)]
    static let critical = [Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.88, green: 0.16, blue: 0.2)]

    static func fill(for s: BatteryState) -> [Color] {
        if s.charging || s.onAC { return accent }
        return s.percent <= 10 ? critical : s.percent <= 20 ? low : accent
    }
}

struct ChargeView: View {
    @EnvironmentObject var battery: BatteryMonitor

    var body: some View {
        VStack(spacing: 0) {
            if let s = battery.state {
                VStack(spacing: 14) {
                    BatteryGlyph(state: s)
                        .frame(width: 190, height: 84)
                        .padding(.top, 22)
                    VStack(spacing: 3) {
                        Text("\(s.percent)%")
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(s.headline).font(.system(size: 13, weight: .semibold, design: .rounded))
                        Text(s.detail).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Details(state: s)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            } else {
                NoBattery()
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Charge") {
                Picker("Menu Bar Shows", selection: $battery.barShows) {
                    ForEach(BarShows.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Battery Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
            }
        }
        .frame(width: 320)
        .animation(.snappy, value: battery.state)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in battery.refresh() }
    }
}

struct BatteryGlyph: View {
    let state: BatteryState

    var body: some View {
        GeometryReader { geo in
            let nub: CGFloat = 10
            let body = CGSize(width: geo.size.width - nub - 4, height: geo.size.height)
            let colors = Palette.fill(for: state)
            HStack(spacing: 4) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.quaternary.opacity(0.35))
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.45), lineWidth: 3)
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                        )
                        .frame(width: max(18, (body.width - 14) * CGFloat(state.percent) / 100))
                        .padding(7)
                        .shadow(color: colors[1].opacity(0.4), radius: 6, y: 2)
                    if state.onAC {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                            .frame(width: body.width)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: body.width, height: body.height)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.secondary.opacity(0.45))
                    .frame(width: nub, height: body.height * 0.36)
            }
        }
    }
}

struct Details: View {
    let state: BatteryState

    var body: some View {
        VStack(spacing: 6) {
            DetailRow(symbol: state.onAC ? "powerplug.fill" : "battery.75percent", title: "Power source",
                      value: state.onAC ? (state.adapter ?? "Power adapter") : "Battery")
            if let watts = state.watts {
                DetailRow(symbol: "bolt.fill", title: watts > 0 ? "Charging at" : "Discharging at",
                          value: String(format: "%.1f W", abs(watts)))
            }
            if let health = state.health {
                DetailRow(symbol: "heart.fill", title: "Maximum capacity", value: "\(health)%")
            }
            if let condition = state.condition {
                DetailRow(symbol: "checkmark.seal.fill", title: "Condition", value: condition,
                          tint: condition == "Normal" ? .green : .orange)
            }
            if let cycles = state.cycles {
                DetailRow(symbol: "arrow.triangle.2.circlepath", title: "Cycle count",
                          value: state.designCycles.map { "\(cycles) of \($0)" } ?? "\(cycles)")
            }
            if let t = state.temperature {
                DetailRow(symbol: "thermometer.medium", title: "Temperature",
                          value: Self.celsius(t))
            }
        }
    }
}

extension Details {
    /// NumberFormatter honours the decimal mark chosen in System Settings; FormatStyle follows the region instead.
    static func celsius(_ t: Double) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return (f.string(from: t as NSNumber) ?? String(format: "%.1f", t)) + "\u{00B0}C"
    }
}

struct DetailRow: View {
    let symbol: String
    let title: String
    let value: String
    var tint: Color = .secondary
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(title).font(.system(size: 12.5))
            Spacer()
            Text(value)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct NoBattery: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "powerplug.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom))
            Text("No battery").font(.system(size: 16, weight: .bold, design: .rounded))
            Text("This Mac runs on mains power, so there is no battery to watch.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Icon

//: a glowing battery with a lightning bolt

func appIcon() -> NSBitmapImageRep {
    render(0xB6F15C, 0x1E9C4A) { ctx in
        let body = CGRect(x: 214, y: 352, width: 540, height: 320)
        // Battery shell.
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.3)
        ctx.addPath(roundedRect(body, 78))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.addPath(roundedRect(CGRect(x: 772, y: 450, width: 52, height: 124), 22))
        ctx.fillPath()
        ctx.restoreGState()
        // Charge level, inset in the shell.
        let level = body.insetBy(dx: 34, dy: 34)
        ctx.addPath(roundedRect(level, 48))
        ctx.setFillColor(rgb(0xDDEFD9).cgColor)
        ctx.fillPath()
        ctx.saveGState()
        ctx.addPath(roundedRect(CGRect(x: level.minX, y: level.minY, width: level.width * 0.78, height: level.height), 48))
        ctx.clip()
        gradient([rgb(0x9BE35A), rgb(0x23A04F)], from: CGPoint(x: 0, y: level.maxY), to: CGPoint(x: 0, y: level.minY), in: ctx)
        gradient([NSColor.white.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0)],
                 from: CGPoint(x: 0, y: level.maxY), to: CGPoint(x: 0, y: level.midY), in: ctx)
        ctx.restoreGState()
        // Lightning bolt, outlined in white so it reads over both halves.
        let bolt: [CGPoint] = [(530, 760), (370, 492), (488, 492), (446, 262), (626, 548), (504, 548), (566, 760)]
            .map { CGPoint(x: $0.0, y: $0.1) }
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 22, alpha: 0.35)
        ctx.addLines(between: bolt)
        ctx.closePath()
        ctx.setLineJoin(.round)
        ctx.setLineWidth(34)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
        ctx.addLines(between: bolt)
        ctx.closePath()
        ctx.setFillColor(rgb(0xFFC93C).cgColor)
        ctx.fillPath()
    }
}
