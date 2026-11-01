import AppKit
import Carbon.HIToolbox
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
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []
    let timer = FocusTimer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "timer", accessibilityLabel: "Tempo") {
            TempoView().environmentObject(self.timer)
        }
        status.onSecondaryClick = { [weak self] in self?.timer.startOrPause() }
        hotKey = HotKey(keyCode: kVK_ANSI_T, modifiers: cmdKey | optionKey) { [weak self] in self?.timer.startOrPause() }
        // A snapshot never asks for notification permission (and has no bundle to ask with when run bare).
        if !StatusPopover.isSnapshot {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        timer.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        switch timer.state {
        case .idle:
            status.setSymbol("timer", label: "Tempo")
            status.setTitle("")
        case .running:
            status.setSymbol(timer.phase.symbol, label: timer.phase.title)
            status.setTitle(FocusTimer.format(timer.remaining))
        case .paused:
            status.setSymbol("pause.fill", label: "Paused")
            status.setTitle(FocusTimer.format(timer.remaining))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Model

enum Phase: String, Codable {
    case focus, shortBreak, longBreak

    var title: String {
        switch self {
        case .focus: "Focus"
        case .shortBreak: "Short Break"
        case .longBreak: "Long Break"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "brain.head.profile"
        case .shortBreak: "cup.and.saucer.fill"
        case .longBreak: "figure.walk"
        }
    }

    var colors: [Color] {
        switch self {
        case .focus: [Color(red: 1, green: 0.42, blue: 0.36), Color(red: 0.93, green: 0.2, blue: 0.45)]
        case .shortBreak: [Color(red: 0.25, green: 0.85, blue: 0.7), Color(red: 0.1, green: 0.6, blue: 0.85)]
        case .longBreak: [Color(red: 0.55, green: 0.5, blue: 1), Color(red: 0.35, green: 0.25, blue: 0.9)]
        }
    }
}

@MainActor
final class FocusTimer: ObservableObject {
    enum State: Equatable { case idle, running(end: Date), paused(remaining: TimeInterval) }

    @Published private(set) var state: State = .idle
    @Published private(set) var phase: Phase = .focus
    @Published private(set) var completedToday = 0
    @Published private(set) var tick = Date()

    // @AppStorage does not publish from an ObservableObject, so each setting announces its own change.
    @AppStorage("focusMinutes") var focusMinutes = 25 { willSet { objectWillChange.send() } }
    @AppStorage("shortMinutes") var shortMinutes = 5 { willSet { objectWillChange.send() } }
    @AppStorage("longMinutes") var longMinutes = 15 { willSet { objectWillChange.send() } }
    @AppStorage("autoStartNext") var autoStartNext = false { willSet { objectWillChange.send() } }
    @AppStorage("dailyGoal") var dailyGoal = 8 { willSet { objectWillChange.send() } }

    private var clock: Timer?
    /// The local calendar day; a plain `.iso8601` style would use UTC and roll over at 02:00 or 03:00 in Athens.
    private var streakDay: String { Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }
    private var shownDay = ""

    init() {
        if StatusPopover.isSnapshot {
            completedToday = 3 // Fixed demo progress, never the user's own.
            return
        }
        refreshDay()
        let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        // Common modes keep the menu bar countdown moving while a menu is open.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    /// Reloads today's session count when the day changes, so the tally restarts at midnight.
    private func refreshDay() {
        let day = streakDay
        guard day != shownDay else { return }
        shownDay = day
        let saved = UserDefaults.standard.dictionary(forKey: "today") as? [String: Int]
        completedToday = saved?[day] ?? 0
    }

    var length: TimeInterval {
        TimeInterval(60 * (phase == .focus ? focusMinutes : phase == .shortBreak ? shortMinutes : longMinutes))
    }

    var remaining: TimeInterval {
        switch state {
        case .idle: length
        case .running(let end): max(0, end.timeIntervalSince(tick))
        case .paused(let remaining): remaining
        }
    }

    var progress: Double { length > 0 ? 1 - remaining / length : 0 }

    func startOrPause() {
        switch state {
        case .idle: state = .running(end: Date().addingTimeInterval(length))
        case .running: state = .paused(remaining: remaining)
        case .paused(let r): state = .running(end: Date().addingTimeInterval(r))
        }
        tick = Date()
    }

    func reset() {
        state = .idle
    }

    func skip() { advance(completed: false) }

    func choose(_ phase: Phase) {
        self.phase = phase
        state = .idle
    }

    private func step() {
        refreshDay()
        guard case .running = state else { return }
        tick = Date()
        if remaining <= 0 { advance(completed: true) }
    }

    private func advance(completed: Bool) {
        let finished = phase
        if finished == .focus && completed {
            // Count from the stored value for today, so the tally restarts after midnight.
            let saved = UserDefaults.standard.dictionary(forKey: "today") as? [String: Int]
            completedToday = (saved?[streakDay] ?? 0) + 1
            UserDefaults.standard.set([streakDay: completedToday], forKey: "today")
        }
        if finished == .focus {
            phase = completedToday > 0 && completedToday % 4 == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        state = .idle
        if completed {
            announce(finished)
            if autoStartNext { startOrPause() }
        }
    }

    private func announce(_ finished: Phase) {
        let title = finished == .focus ? "Focus session done" : "Break is over"
        let body = finished == .focus ? "Nice work. Time for a \(phase.title.lowercased())." : "Ready for the next focus session?"
        NSSound(named: "Glass")?.play()
        HUD.show(symbol: finished == .focus ? "checkmark.circle.fill" : "bolt.fill", title: title,
                 tint: finished == .focus ? .green : .orange)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Views

struct TempoView: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        VStack(spacing: 0) {
            PhasePicker()
                .padding(.top, 14)
            Ring()
                .padding(.vertical, 18)
            Controls()
                .padding(.bottom, 16)
            Today()
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Tempo", shortcut: "⌥⌘T") {
                Picker("Focus", selection: $timer.focusMinutes) {
                    ForEach([15, 20, 25, 30, 45, 50, 60, 90], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Short Break", selection: $timer.shortMinutes) {
                    ForEach([3, 5, 10], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Long Break", selection: $timer.longMinutes) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Daily Goal", selection: $timer.dailyGoal) {
                    ForEach([4, 6, 8, 10, 12], id: \.self) { Text("\($0) sessions").tag($0) }
                }
                Toggle("Start Next Session Automatically", isOn: $timer.autoStartNext)
            }
        }
        .frame(width: 320)
    }
}

struct PhasePicker: View {
    @EnvironmentObject var timer: FocusTimer
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach([Phase.focus, .shortBreak, .longBreak], id: \.self) { phase in
                Button {
                    withAnimation(.snappy) { timer.choose(phase) }
                } label: {
                    Text(phase.title)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(timer.phase == phase ? .white : .secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background {
                            if timer.phase == phase {
                                Capsule()
                                    .fill(LinearGradient(colors: phase.colors, startPoint: .leading, endPoint: .trailing))
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
}

struct Ring: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        let colors = timer.phase.colors
        ZStack {
            Circle()
                .stroke(.quaternary.opacity(0.6), lineWidth: 14)
            Circle()
                .trim(from: 0, to: max(0.0001, timer.progress))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[1].opacity(0.35), radius: 6)
                .animation(.linear(duration: 0.5), value: timer.progress)
            VStack(spacing: 2) {
                Image(systemName: timer.phase.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                Text(FocusTimer.format(timer.remaining))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                Text(stateLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 190, height: 190)
    }

    private var stateLabel: String {
        switch timer.state {
        case .idle: "Ready"
        case .running: timer.phase == .focus ? "Stay with it" : "Breathe"
        case .paused: "Paused"
        }
    }
}

struct Controls: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        HStack(spacing: 14) {
            GlassIconButton("arrow.counterclockwise", help: "Reset") { withAnimation { timer.reset() } }
            Button {
                withAnimation(.snappy) { timer.startOrPause() }
            } label: {
                Label(primaryTitle, systemImage: isRunning ? "pause.fill" : "play.fill")
                    .frame(width: 92)
            }
            .buttonStyle(PillButtonStyle(timer.phase.colors))
            .keyboardShortcut(.space, modifiers: [])
            GlassIconButton("forward.end.fill", help: "Skip to next") { withAnimation { timer.skip() } }
        }
    }

    private var isRunning: Bool { if case .running = timer.state { true } else { false } }

    private var primaryTitle: String {
        switch timer.state {
        case .idle: "Start"
        case .running: "Pause"
        case .paused: "Resume"
        }
    }
}

struct Today: View {
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(timer.completedToday) of \(timer.dailyGoal) sessions")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(spacing: 5) {
                ForEach(0..<max(timer.dailyGoal, timer.completedToday), id: \.self) { i in
                    Capsule()
                        .fill(i < timer.completedToday
                              ? AnyShapeStyle(LinearGradient(colors: Phase.focus.colors, startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(.quaternary.opacity(0.7)))
                        .frame(height: 6)
                }
            }
        }
    }
}

// MARK: - Icon

//: a progress ring with a glowing knob

func appIcon() -> NSBitmapImageRep {
    render(0xFF7E5F, 0xD12A6E) { ctx in
        let c = CGPoint(x: 512, y: 512), r: CGFloat = 255
        ctx.setLineCap(.round)
        // Hour ticks.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(14)
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            let inner: CGFloat = i % 3 == 0 ? 150 : 170
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 192, y: c.y + sin(a) * 192))
        }
        ctx.strokePath()
        // Track and progress.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(66)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 22, alpha: 0.25)
        ctx.setStrokeColor(NSColor.white.cgColor)
        let start = CGFloat.pi / 2, end = start - 0.72 * 2 * .pi
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
        ctx.restoreGState()
        // Knob at the end of the arc.
        let k = CGPoint(x: c.x + cos(end) * r, y: c.y + sin(end) * r)
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 18, alpha: 0.35)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: k.x - 52, y: k.y - 52, width: 104, height: 104))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xF0476A).cgColor)
        ctx.fillEllipse(in: CGRect(x: k.x - 22, y: k.y - 22, width: 44, height: 44))
        // Centre dot.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
    }
}
