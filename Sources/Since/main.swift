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
    let journal = Journal()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "clock.arrow.circlepath", accessibilityLabel: "Since") {
            SinceView().environmentObject(self.journal)
        }
        journal.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()
    }

    func applicationWillTerminate(_ notification: Notification) { journal.record(.quit) }

    private func updateTitle() {
        status.setTitle(journal.showUptimeInBar ? Uptime.short(journal.now.timeIntervalSince(journal.boot)) : "")
    }
}

// MARK: - Model

enum EventKind: String, Codable {
    case boot, launch, quit, sleep, wake, lock, unlock

    var title: String {
        switch self {
        case .boot: "Started up"
        case .launch: "Since opened"
        case .quit: "Since quit"
        case .sleep: "Went to sleep"
        case .wake: "Woke up"
        case .lock: "Screen locked"
        case .unlock: "Screen unlocked"
        }
    }

    var symbol: String {
        switch self {
        case .boot: "power"
        case .launch: "eye.fill"
        case .quit: "eye.slash.fill"
        case .sleep: "moon.fill"
        case .wake: "sun.max.fill"
        case .lock: "lock.fill"
        case .unlock: "lock.open.fill"
        }
    }

    /// The state the Mac is in after this event. Boot time is read back from the kernel, so what
    /// happened between boot and the first launch was not observed.
    var state: MacState {
        switch self {
        case .launch, .wake, .unlock: .awake
        case .boot: .unknown
        case .sleep: .asleep
        case .lock: .locked
        case .quit: .unknown
        }
    }
}

enum MacState: Equatable {
    case awake, locked, asleep, unknown

    var title: String {
        switch self {
        case .awake: "In use"
        case .locked: "Locked"
        case .asleep: "Asleep"
        case .unknown: "Not recorded"
        }
    }
}

struct Event: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: EventKind
    var date: Date
}

struct Segment: Equatable {
    var start: Date
    var end: Date
    var state: MacState
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum Timeline {
    /// Splits [from, to) into stretches of one state, replaying the events in order.
    /// Before the first event the state is unknown, unless an earlier event says otherwise.
    static func segments(events: [Event], from: Date, to: Date) -> [Segment] {
        guard to > from else { return [] }
        let sorted = events.sorted { $0.date < $1.date }
        var state = sorted.last { $0.date <= from }?.kind.state ?? .unknown
        var cursor = from
        var result: [Segment] = []
        func close(at date: Date) {
            guard date > cursor else { return }
            if let last = result.last, last.state == state, last.end == cursor {
                result[result.count - 1].end = date
            } else {
                result.append(Segment(start: cursor, end: date, state: state))
            }
            cursor = date
        }
        for e in sorted where e.date > from && e.date < to {
            close(at: e.date)
            state = e.kind.state
        }
        close(at: to)
        return result
    }

    static func total(_ segments: [Segment], _ state: MacState) -> TimeInterval {
        segments.filter { $0.state == state }.reduce(0) { $0 + $1.duration }
    }
}

enum Uptime {
    static func bootTime() -> Date {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    /// "3d 4h", "5h 12m", "14m".
    static func short(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60, h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(m)m"
    }

    /// "3 days, 4 hours", "5 hours, 12 minutes".
    static func long(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60, h = m / 60, d = h / 24
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if d > 0 { return unit(d, "day") + ", " + unit(h % 24, "hour") }
        if h > 0 { return unit(h, "hour") + ", " + unit(m % 60, "minute") }
        return unit(m, "minute")
    }
}

@MainActor
final class Journal: ObservableObject {
    @Published private(set) var events: [Event]
    @Published private(set) var now = Date()
    @AppStorage("showUptimeInBar") var showUptimeInBar = false
    let boot = Uptime.bootTime()
    /// Screenshots must not write into the real history.
    private let persist = !CommandLine.arguments.contains("--snapshot")

    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?

    init() {
        // Keep two weeks.
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        events = (Storage.load([Event].self, app: "Since", file: "events.json") ?? []).filter { $0.date > cutoff }
        if !events.contains(where: { $0.kind == .boot && abs($0.date.timeIntervalSince(boot)) < 2 }) {
            events.append(Event(kind: .boot, date: boot))
        }
        record(.launch)

        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, NSWorkspace.willSleepNotification, .sleep)
        listen(workspace, NSWorkspace.didWakeNotification, .wake)
        let distributed = DistributedNotificationCenter.default()
        listen(distributed, Notification.Name("com.apple.screenIsLocked"), .lock)
        listen(distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlock)

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer?.tolerance = 5
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name, _ kind: EventKind) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.record(kind) }
        }
        observers.append((center, token))
    }

    func record(_ kind: EventKind) {
        // The system sometimes posts lock twice; one is enough.
        if let last = events.last, last.kind == kind, kind != .launch, Date().timeIntervalSince(last.date) < 5 { return }
        events.append(Event(kind: kind, date: Date()))
        events.sort { $0.date < $1.date }
        now = Date()
        if persist { Storage.save(events, app: "Since", file: "events.json") }
    }

    func clear() {
        events = [Event(kind: .boot, date: boot), Event(kind: .launch, date: Date())]
        if persist { Storage.save(events, app: "Since", file: "events.json") }
    }

    var startOfToday: Date { Calendar.current.startOfDay(for: now) }

    var today: [Segment] { Timeline.segments(events: events, from: startOfToday, to: now) }

    var todayEvents: [Event] { events.filter { $0.date >= startOfToday }.reversed() }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 1, green: 0.72, blue: 0.35), Color(red: 0.95, green: 0.42, blue: 0.3)]
    static let locked = Color(red: 0.55, green: 0.6, blue: 0.95)
    static let asleep = Color(red: 0.24, green: 0.25, blue: 0.5)

    static func fill(_ state: MacState) -> AnyShapeStyle {
        switch state {
        case .awake: AnyShapeStyle(LinearGradient(colors: accent, startPoint: .top, endPoint: .bottom))
        case .locked: AnyShapeStyle(locked)
        case .asleep: AnyShapeStyle(asleep)
        case .unknown: AnyShapeStyle(.quaternary.opacity(0.6))
        }
    }
}

struct SinceView: View {
    @EnvironmentObject var journal: Journal

    var body: some View {
        let segments = journal.today
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up for").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(Uptime.long(journal.now.timeIntervalSince(journal.boot)))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("Started up \(journal.boot.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 10) {
                Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                DayBar(segments: segments, start: journal.startOfToday, now: journal.now)
                HStack {
                    Total(state: .awake, value: Timeline.total(segments, .awake))
                    Spacer()
                    Total(state: .locked, value: Timeline.total(segments, .locked))
                    Spacer()
                    Total(state: .asleep, value: Timeline.total(segments, .asleep))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
            .padding(.horizontal, 12)

            EventList(events: journal.todayEvents)
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Since") {
                Toggle("Show Uptime in Menu Bar", isOn: $journal.showUptimeInBar)
                Button("Clear History") { journal.clear() }
            }
        }
        .frame(width: 340)
        .animation(.snappy, value: journal.events)
    }
}

struct DayBar: View {
    let segments: [Segment]
    let start: Date
    let now: Date

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let day: TimeInterval = 86_400
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(0.35))
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, s in
                        Rectangle()
                            .fill(Palette.fill(s.state))
                            .frame(width: max(1, geo.size.width * s.duration / day))
                            .offset(x: geo.size.width * s.start.timeIntervalSince(start) / day)
                    }
                    // Now marker.
                    Capsule()
                        .fill(.primary)
                        .frame(width: 2, height: geo.size.height + 6)
                        .offset(x: geo.size.width * now.timeIntervalSince(start) / day - 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 22)
            HStack {
                ForEach(["00", "06", "12", "18", "24"], id: \.self) { h in
                    Text(h).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                    if h != "24" { Spacer() }
                }
            }
        }
    }
}

struct Total: View {
    let state: MacState
    let value: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.fill(state)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(value < 60 ? "0m" : Uptime.short(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

struct EventList: View {
    let events: [Event]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if events.isEmpty {
                Text("Sleep, wake, lock and unlock show up here as they happen.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(events.enumerated()), id: \.element.id) { i, e in
                            EventRow(event: e, isLast: i == events.count - 1)
                        }
                    }
                }
                .frame(maxHeight: 190)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EventRow: View {
    let event: Event
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: event.kind.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Palette.fill(event.kind.state == .unknown ? .asleep : event.kind.state)))
                if !isLast {
                    Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            Text(event.kind.title)
                .font(.system(size: 12.5))
                .padding(.top, 3)
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.top, 3)
        }
        .frame(height: 32, alignment: .top)
    }
}

// MARK: - Icon

//: a half sun and a crescent moon on one arc, day turning into night

func appIcon() -> NSBitmapImageRep {
    render(0x3E5C9A, 0x16203F) { ctx in
        // Horizon glow.
        radial([rgb(0xFFB86B, 0.55), rgb(0xFFB86B, 0)], center: CGPoint(x: 512, y: 330), radius: 430, in: ctx)
        sparkle(ctx, at: CGPoint(x: 720, y: 790), size: 26, color: NSColor.white.withAlphaComponent(0.8))
        sparkle(ctx, at: CGPoint(x: 820, y: 640), size: 16, color: NSColor.white.withAlphaComponent(0.6))
        // Dashed day arc.
        let c = CGPoint(x: 512, y: 330)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        ctx.setLineDash(phase: 0, lengths: [2, 40])
        ctx.addArc(center: c, radius: 330, startAngle: .pi, endAngle: 0, clockwise: true)
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        // Sun rising on the left of the arc.
        let sun = CGPoint(x: c.x + cos(.pi * 0.78) * 330, y: c.y + sin(.pi * 0.78) * 330)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 30, alpha: 0.25)
        ctx.addEllipse(in: CGRect(x: sun.x - 96, y: sun.y - 96, width: 192, height: 192))
        ctx.clip()
        gradient([rgb(0xFFE38A), rgb(0xFF9440)], from: CGPoint(x: 0, y: sun.y + 96), to: CGPoint(x: 0, y: sun.y - 96), in: ctx)
        ctx.restoreGState()
        // Moon on the right: a disc with a bite.
        let moon = CGPoint(x: c.x + cos(.pi * 0.25) * 330, y: c.y + sin(.pi * 0.25) * 330)
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(rgb(0xF1F4FF).cgColor)
        ctx.fillEllipse(in: CGRect(x: moon.x - 86, y: moon.y - 86, width: 172, height: 172))
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: moon.x - 40, y: moon.y - 30, width: 160, height: 160))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Horizon with a clock hand rising from it.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(roundedRect(CGRect(x: 180, y: 300, width: 664, height: 54), 27))
        ctx.fillPath()
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 18, alpha: 0.3)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(40)
        ctx.move(to: c)
        ctx.addLine(to: CGPoint(x: c.x + cos(.pi * 0.62) * 230, y: c.y + sin(.pi * 0.62) * 230))
        ctx.strokePath()
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xFF9440).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y - 3, width: 60, height: 60))
    }
}
