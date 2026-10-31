import AppKit
import Carbon.HIToolbox
import Combine
import Kit
import SwiftUI
import UserNotifications

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
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        timer.objectWillChange
            .receive(on: RunLoop.main)
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

    @AppStorage("focusMinutes") var focusMinutes = 25
    @AppStorage("shortMinutes") var shortMinutes = 5
    @AppStorage("longMinutes") var longMinutes = 15
    @AppStorage("autoStartNext") var autoStartNext = false
    @AppStorage("dailyGoal") var dailyGoal = 8

    private var clock: Timer?
    private var streakDay: String { Date().formatted(.iso8601.year().month().day()) }

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: "today") as? [String: Int]
        completedToday = saved?[streakDay] ?? 0
        clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
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
