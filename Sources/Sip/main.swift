import AppKit
import Combine
import Kit
import SwiftUI
import UserNotifications

IconKit.handleCommandLine(draw: appIcon)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var status: StatusPopover!
    private var cancellables: Set<AnyCancellable> = []
    let log = WaterLog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "drop", accessibilityLabel: "Sip") {
            SipView().environmentObject(self.log)
        }
        status.onSecondaryClick = { [weak self] in self?.log.add(self?.log.defaultGlass ?? 250) }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        log.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        let done = log.today >= log.goal
        status.setSymbol(done ? "drop.fill" : log.today > 0 ? "drop.halffull" : "drop", label: "Sip")
        status.setTitle(log.today > 0 ? "\(Int((log.progress * 100).rounded()))%" : "")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Model

struct Drink: Codable, Equatable {
    var at: Date
    var ml: Int
}

enum Schedule {
    /// True when a reminder is due: inside waking hours, and `interval` hours since the later of the last drink and the last nudge.
    static func due(now: Date, lastDrink: Date?, lastNudge: Date?, intervalHours: Double, wake: Int, sleep: Int,
                    calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour >= wake && hour < sleep else { return false }
        // Count from wake-up time when nothing happened yet today.
        let wakeToday = calendar.date(bySettingHour: wake, minute: 0, second: 0, of: now) ?? now
        let reference = [lastDrink, lastNudge, wakeToday].compactMap { $0 }.max() ?? wakeToday
        return now.timeIntervalSince(reference) >= intervalHours * 3600
    }

    static func litres(_ ml: Int) -> String {
        ml >= 1000 ? (Double(ml) / 1000).formatted(.number.precision(.fractionLength(0...2))) + " L" : "\(ml) ml"
    }
}

@MainActor
final class WaterLog: ObservableObject {
    /// Total per day, keyed "yyyy-MM-dd".
    @Published private(set) var days: [String: Int] = [:]
    /// Today's drinks, for undo.
    @Published private(set) var drinks: [Drink] = []
    @Published private(set) var lastNudge: Date?

    @AppStorage("goal") var goal = 2000
    @AppStorage("defaultGlass") var defaultGlass = 250
    @AppStorage("remind") var remind = true
    @AppStorage("interval") var interval = 1.5
    @AppStorage("wake") var wake = 8
    @AppStorage("sleep") var sleep = 22

    private struct Saved: Codable { var days: [String: Int]; var drinks: [Drink] }
    private var timer: Timer?
    private let demo = CommandLine.arguments.contains("--snapshot")

    init() {
        if demo {
            let cal = Calendar.current
            for (i, ml) in [1750, 2250, 1500, 2000, 2400, 1250].enumerated() {
                days[WaterLog.key(cal.date(byAdding: .day, value: -(6 - i), to: Date())!)] = ml
            }
            drinks = [Drink(at: Date(), ml: 1250)]
            days[WaterLog.key(Date())] = 1250
        } else if let saved = Storage.load(Saved.self, app: "Sip", file: "log.json") {
            days = saved.days
            drinks = saved.drinks.filter { Calendar.current.isDateInToday($0.at) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    static func key(_ date: Date) -> String { date.formatted(.iso8601.year().month().day()) }

    var today: Int { days[WaterLog.key(Date())] ?? 0 }
    var progress: Double { goal > 0 ? min(1, Double(today) / Double(goal)) : 0 }

    /// The last seven days, oldest first.
    var week: [(date: Date, ml: Int)] {
        (0..<7).reversed().map { back in
            let d = Calendar.current.date(byAdding: .day, value: -back, to: Date())!
            return (d, days[WaterLog.key(d)] ?? 0)
        }
    }

    func add(_ ml: Int) {
        let before = today
        drinks.removeAll { !Calendar.current.isDateInToday($0.at) }
        drinks.append(Drink(at: Date(), ml: ml))
        days[WaterLog.key(Date()), default: 0] += ml
        persist()
        if before < goal && today >= goal {
            NSSound(named: "Glass")?.play()
            HUD.show(symbol: "checkmark.seal.fill", title: "Goal reached", tint: Accent.solid)
        }
    }

    func undo() {
        guard let last = drinks.popLast() else { return }
        days[WaterLog.key(last.at), default: 0] = max(0, (days[WaterLog.key(last.at)] ?? 0) - last.ml)
        persist()
    }

    private func check() {
        objectWillChange.send() // a new day resets the view
        guard remind, !demo, today < goal,
              Schedule.due(now: Date(), lastDrink: drinks.last?.at, lastNudge: lastNudge, intervalHours: interval, wake: wake, sleep: sleep)
        else { return }
        lastNudge = Date()
        HUD.show(symbol: "drop.fill", title: "Time for a glass", tint: Accent.solid)
        let content = UNMutableNotificationContent()
        content.title = "Time for a glass of water"
        content.body = "\(Schedule.litres(today)) of \(Schedule.litres(goal)) so far today."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func persist() {
        // Keep sixty days of totals; the panel shows seven.
        let cutoff = WaterLog.key(Calendar.current.date(byAdding: .day, value: -60, to: Date())!)
        days = days.filter { $0.key >= cutoff }
        if !demo { Storage.save(Saved(days: days, drinks: drinks), app: "Sip", file: "log.json") }
    }
}

// MARK: - Views

struct SipView: View {
    @EnvironmentObject var log: WaterLog

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                FillingGlass(level: log.progress)
                    .frame(width: 96, height: 128)
                VStack(alignment: .leading, spacing: 4) {
                    Text(Schedule.litres(log.today))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("of \(Schedule.litres(log.goal)) today")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(remainingText)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Accent.solid)
                        .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HStack(spacing: 6) {
                ForEach([150, 250, 330, 500], id: \.self) { ml in
                    GlassButton(ml: ml) { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { log.add(ml) } }
                }
            }
            .padding(.horizontal, 12)

            WeekChart()
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Sip") {
                Button("Undo Last Glass") { withAnimation(.snappy) { log.undo() } }
                    .keyboardShortcut("z")
                    .disabled(log.drinks.isEmpty)
                Picker("Daily Goal", selection: $log.goal) {
                    ForEach([1500, 2000, 2500, 3000, 3500], id: \.self) { Text(Schedule.litres($0)).tag($0) }
                }
                Picker("Right-Click Adds", selection: $log.defaultGlass) {
                    ForEach([150, 250, 330, 500], id: \.self) { Text("\($0) ml").tag($0) }
                }
                Divider()
                Toggle("Remind Me", isOn: $log.remind)
                Picker("Every", selection: $log.interval) {
                    ForEach([1.0, 1.5, 2, 3], id: \.self) { Text($0 == 1 ? "hour" : "\($0.formatted()) hours").tag($0) }
                }
                Picker("From", selection: $log.wake) {
                    ForEach(5...12, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("Until", selection: $log.sleep) {
                    ForEach(18...24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
            }
        }
        .frame(width: 330)
    }

    private var remainingText: String {
        let left = log.goal - log.today
        return left > 0 ? "\(Schedule.litres(left)) to go" : "Goal reached"
    }
}

struct GlassButton: View {
    let ml: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: ml >= 500 ? "waterbottle.fill" : ml >= 330 ? "takeoutbag.and.cup.and.straw.fill" : ml >= 250 ? "mug.fill" : "cup.and.saucer.fill")
                    .font(.system(size: ml >= 330 ? 15 : 13))
                    .foregroundStyle(Accent.gradient)
                    .frame(height: 18)
                Text("\(ml) ml")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add \(ml) ml")
        .onHover { hovering = $0 }
    }
}

/// A tapered glass with a gently moving water surface.
struct FillingGlass: View {
    let level: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 2.2
            ZStack {
                GlassShape().fill(.quaternary.opacity(0.35))
                Wave(level: level, phase: phase, amplitude: level > 0 && level < 1 ? 3.5 : 0)
                    .fill(LinearGradient(colors: [Accent.colors[0].opacity(0.85), Accent.colors[1]], startPoint: .top, endPoint: .bottom))
                    .clipShape(GlassShape())
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: level)
                Wave(level: level, phase: phase + 1.6, amplitude: level > 0 && level < 1 ? 2.5 : 0)
                    .fill(.white.opacity(0.18))
                    .clipShape(GlassShape())
                    .animation(.spring(response: 0.7, dampingFraction: 0.8), value: level)
                GlassShape().stroke(.secondary.opacity(0.6), lineWidth: 2)
                // Highlight down the left wall.
                Capsule().fill(.white.opacity(0.35)).frame(width: 4, height: 70).offset(x: -30, y: -6).rotationEffect(.degrees(4))
            }
        }
    }
}

struct GlassShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let taper = r.width * 0.12
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - taper, y: r.maxY - 10))
        p.addQuadCurve(to: CGPoint(x: r.maxX - taper - 10, y: r.maxY), control: CGPoint(x: r.maxX - taper, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + taper + 10, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX + taper, y: r.maxY - 10), control: CGPoint(x: r.minX + taper, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct Wave: Shape {
    var level: Double
    let phase: Double
    let amplitude: Double

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let surface = r.maxY - r.height * level
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        for x in stride(from: r.minX, through: r.maxX, by: 2) {
            let y = surface + sin(Double(x) / r.width * 2 * .pi * 1.3 + phase) * amplitude
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct WeekChart: View {
    @EnvironmentObject var log: WaterLog

    var body: some View {
        let week = log.week
        let top = Double(max(log.goal, week.map(\.ml).max() ?? 0)) * 1.1
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(week.filter { $0.ml >= log.goal }.count) of 7 on goal")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let h = geo.size.height - 16
                ZStack(alignment: .bottomLeading) {
                    // Goal line.
                    Rectangle()
                        .fill(Accent.solid.opacity(0.5))
                        .frame(height: 1)
                        .offset(y: -16 - h * Double(log.goal) / top)
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(week, id: \.date) { day in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(day.ml >= log.goal ? AnyShapeStyle(Accent.gradient) : AnyShapeStyle(Accent.solid.opacity(0.35)))
                                    .frame(height: max(3, h * Double(day.ml) / top))
                                    .help(Schedule.litres(day.ml))
                                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                    .font(.system(size: 10, weight: Calendar.current.isDateInToday(day.date) ? .bold : .medium, design: .rounded))
                                    .foregroundStyle(Calendar.current.isDateInToday(day.date) ? .primary : .secondary)
                                    .frame(height: 12)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(height: 84)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

enum Accent {
    static let solid = Color(red: 0.13, green: 0.6, blue: 0.95)
    static let colors = [Color(red: 0.38, green: 0.85, blue: 1), Color(red: 0.1, green: 0.48, blue: 0.92)]
    static let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a glass of water with a wave and a falling drop

func appIcon() -> NSBitmapImageRep {
    render(0x7DE6F5, 0x1673D6) { ctx in
        // The glass, slightly tapered.
        let top: CGFloat = 760, bottom: CGFloat = 210, left: CGFloat = 300, right: CGFloat = 724, taper: CGFloat = 50
        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: left, y: top))
        glass.addLine(to: CGPoint(x: right, y: top))
        glass.addLine(to: CGPoint(x: right - taper, y: bottom + 40))
        glass.addQuadCurve(to: CGPoint(x: right - taper - 40, y: bottom), control: CGPoint(x: right - taper, y: bottom))
        glass.addLine(to: CGPoint(x: left + taper + 40, y: bottom))
        glass.addQuadCurve(to: CGPoint(x: left + taper, y: bottom + 40), control: CGPoint(x: left + taper, y: bottom))
        glass.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.3)
        ctx.addPath(glass)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.3).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Water with a wavy surface.
        ctx.saveGState()
        ctx.addPath(glass)
        ctx.clip()
        let surface: CGFloat = 520
        let water = CGMutablePath()
        water.move(to: CGPoint(x: left - 20, y: 0))
        water.addLine(to: CGPoint(x: left - 20, y: surface))
        water.addCurve(to: CGPoint(x: 512, y: surface), control1: CGPoint(x: 380, y: surface + 46), control2: CGPoint(x: 440, y: surface + 46))
        water.addCurve(to: CGPoint(x: right + 20, y: surface), control1: CGPoint(x: 584, y: surface - 46), control2: CGPoint(x: 660, y: surface - 46))
        water.addLine(to: CGPoint(x: right + 20, y: 0))
        water.closeSubpath()
        ctx.addPath(water)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xBFEFFF)], from: CGPoint(x: 0, y: surface + 40), to: CGPoint(x: 0, y: bottom), in: ctx)
        ctx.restoreGState()
        // Rim and glints.
        ctx.addPath(glass)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(16)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(18)
        ctx.move(to: CGPoint(x: left + 52, y: top - 70)); ctx.addLine(to: CGPoint(x: left + 76, y: 470))
        ctx.strokePath()
        // A drop falling into the glass.
        let d = CGPoint(x: 512, y: 640)
        let drop = CGMutablePath()
        drop.move(to: CGPoint(x: d.x, y: d.y + 120))
        drop.addCurve(to: CGPoint(x: d.x + 58, y: d.y - 10), control1: CGPoint(x: d.x + 20, y: d.y + 70), control2: CGPoint(x: d.x + 58, y: d.y + 30))
        drop.addArc(center: CGPoint(x: d.x, y: d.y - 10), radius: 58, startAngle: 0, endAngle: .pi, clockwise: true)
        drop.addCurve(to: CGPoint(x: d.x, y: d.y + 120), control1: CGPoint(x: d.x - 58, y: d.y + 30), control2: CGPoint(x: d.x - 20, y: d.y + 70))
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 18, alpha: 0.3)
        ctx.addPath(drop)
        ctx.setFillColor(rgb(0x2A8BEA).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.fillEllipse(in: CGRect(x: d.x - 34, y: d.y - 20, width: 18, height: 30))
    }
}
