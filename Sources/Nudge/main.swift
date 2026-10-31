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
    let store = ReminderStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "bell", accessibilityLabel: "Nudge") {
            NudgeView().environmentObject(self.store)
        }
        hotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: cmdKey | optionKey) { [weak self] in self?.status.toggle() }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        store.$reminders
            .sink { [weak self] list in
                self?.status.setSymbol(list.isEmpty ? "bell" : "bell.badge.fill", label: "Nudge, \(list.count) pending")
            }
            .store(in: &cancellables)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Model

struct Reminder: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var due: Date
}

/// Reads a trailing "in 20m", "in 2 hours", "at 17:30" or "at 5pm" off the end of a reminder.
enum When {
    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> (text: String, due: Date)? {
        let s = input.trimmingCharacters(in: .whitespaces)
        let relative = #/(?i)^(.+?)\s+in\s+(\d+(?:[.,]\d+)?)\s*(m|min|mins|minute|minutes|h|hr|hrs|hour|hours)$/#
        if let m = s.wholeMatch(of: relative) {
            let value = Double(m.2.replacingOccurrences(of: ",", with: ".")) ?? 0
            let hours = m.3.lowercased().hasPrefix("h")
            guard value > 0 else { return nil }
            return (String(m.1), now.addingTimeInterval(value * (hours ? 3600 : 60)))
        }
        let clock = #/(?i)^(.+?)\s+at\s+(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm)?$/#
        if let m = s.wholeMatch(of: clock) {
            var hour = Int(m.2) ?? 0
            let minute = m.3.flatMap { Int($0) } ?? 0
            if let ampm = m.4?.lowercased() {
                guard (1...12).contains(hour) else { return nil }
                hour = hour % 12 + (ampm == "pm" ? 12 : 0)
            } else if m.3 == nil {
                return nil // "at 5" alone is too ambiguous to guess.
            }
            guard hour < 24, minute < 60 else { return nil }
            return (String(m.1), next(hour: hour, minute: minute, after: now, calendar: calendar))
        }
        return nil
    }

    /// The next time the clock reads hour:minute, today or tomorrow.
    static func next(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute, second: 0), matchingPolicy: .nextTime) ?? now
    }

    static func countdown(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded(.up))
        if interval <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "in \(h) h" : "in \(h) h \(m) min"
    }
}

@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var reminders: [Reminder] = [] { didSet { if !demo { persist() } } }
    @Published var now = Date()
    private var timer: Timer?
    private let demo = CommandLine.arguments.contains("--snapshot")

    init() {
        if demo {
            reminders = [Reminder(text: "Call mum", due: Date().addingTimeInterval(14 * 60)),
                         Reminder(text: "Take the laundry out", due: Date().addingTimeInterval(52 * 60)),
                         Reminder(text: "Submit the expense report", due: Date().addingTimeInterval(5 * 3600 + 20 * 60))]
        } else {
            reminders = Storage.load([Reminder].self, app: "Nudge", file: "reminders.json") ?? []
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func add(_ text: String, due: Date) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reminder = Reminder(text: text, due: due)
        withAnimation(.snappy) {
            reminders.append(reminder)
            reminders.sort { $0.due < $1.due }
        }
        schedule(reminder)
    }

    func cancel(_ reminder: Reminder) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [reminder.id.uuidString])
        withAnimation(.snappy) { reminders.removeAll { $0.id == reminder.id } }
    }

    /// The system delivers the notification even if Nudge is not running; the HUD needs the app.
    private func schedule(_ reminder: Reminder) {
        let content = UNMutableNotificationContent()
        content.title = reminder.text
        content.body = "Reminder from Nudge"
        content.sound = .default
        let interval = max(1, reminder.due.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger))
    }

    private func tick() {
        now = Date()
        let due = reminders.filter { $0.due <= now }
        guard !due.isEmpty, !demo else { return }
        withAnimation(.snappy) { reminders.removeAll { $0.due <= now } }
        NSSound(named: "Glass")?.play()
        HUD.show(symbol: "bell.badge.fill", title: due.count == 1 ? due[0].text : "\(due.count) reminders", tint: Accent.solid)
    }

    private func persist() { Storage.save(reminders, app: "Nudge", file: "reminders.json") }
}

// MARK: - Views

struct NudgeView: View {
    @EnvironmentObject var store: ReminderStore
    @State private var text = ""
    @State private var pickingTime = false
    @State private var at = Date().addingTimeInterval(3600)
    @FocusState private var focused: Bool

    private static let presets: [(String, TimeInterval)] = [("5m", 300), ("15m", 900), ("30m", 1800), ("1h", 3600), ("3h", 10800)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Nudge").font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                if !store.reminders.isEmpty {
                    Text("\(store.reminders.count) pending")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            PanelFooter(name: "Nudge", shortcut: "⌥⌘R") {
                Button("Cancel All", role: .destructive) { store.reminders.forEach(store.cancel) }
                    .disabled(store.reminders.isEmpty)
            }
        }
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    private var parsed: (text: String, due: Date)? { When.parse(text, now: store.now) }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bell.fill").foregroundStyle(Accent.gradient)
                TextField("Remind me to…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(submit)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.45)))

            if let parsed {
                Label("\(parsed.due.formatted(date: .omitted, time: .shortened)), \(When.countdown(parsed.due.timeIntervalSince(store.now))). Press Return.",
                      systemImage: "return")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Accent.solid)
                    .transition(.opacity)
            }

            HStack(spacing: 5) {
                ForEach(NudgeView.presets, id: \.0) { label, seconds in
                    Chip(label) { create(due: Date().addingTimeInterval(seconds)) }
                }
                Chip(pickingTime ? "Cancel" : "At…", filled: pickingTime) { withAnimation(.snappy) { pickingTime.toggle() } }
            }
            .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty && !pickingTime)

            if pickingTime {
                HStack {
                    DatePicker("", selection: $at, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                    Text(When.countdown(dueForPicked.timeIntervalSince(store.now)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remind") { create(due: dueForPicked) }
                        .buttonStyle(PillButtonStyle(Accent.colors))
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var dueForPicked: Date {
        let c = Calendar.current.dateComponents([.hour, .minute], from: at)
        return When.next(hour: c.hour ?? 0, minute: c.minute ?? 0, after: store.now)
    }

    @ViewBuilder private var list: some View {
        if store.reminders.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(.tertiary)
                Text("Nothing pending. Try \"stretch in 20m\" or \"call Anna at 17:30\".")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .frame(maxWidth: .infinity)
            .frame(height: 100)
        } else {
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.reminders) { r in
                        ReminderRow(reminder: r)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(10)
            }
            .frame(height: min(CGFloat(store.reminders.count) * 52 + 16, 260))
        }
    }

    private func submit() {
        if let parsed {
            store.add(parsed.text, due: parsed.due)
            text = ""
        } else {
            create(due: Date().addingTimeInterval(900))
        }
    }

    private func create(due: Date) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // A typed "in 20m" wins over the chip, but its words never end up in the reminder text.
        store.add(parsed?.text ?? text, due: due)
        text = ""
        withAnimation(.snappy) { pickingTime = false }
    }
}

struct Chip: View {
    let title: String
    let filled: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, filled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(filled ? AnyShapeStyle(Accent.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.9 : 0.5))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ReminderRow: View {
    @EnvironmentObject var store: ReminderStore
    let reminder: Reminder
    @State private var hovering = false

    var body: some View {
        let left = reminder.due.timeIntervalSince(store.now)
        HStack(spacing: 10) {
            Circle()
                .fill(Accent.gradient)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.text).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(When.countdown(left))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if hovering {
                GlassIconButton("xmark", help: "Cancel reminder") { store.cancel(reminder) }
                    .transition(.opacity)
            }
            Text(reminder.due.formatted(date: Calendar.current.isDateInToday(reminder.due) ? .omitted : .abbreviated, time: .shortened))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

enum Accent {
    static let solid = Color(red: 0.55, green: 0.33, blue: 0.98)
    static let colors = [Color(red: 0.72, green: 0.45, blue: 1), Color(red: 0.42, green: 0.24, blue: 0.94)]
    static let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a ringing bell with a tap mark

func appIcon() -> NSBitmapImageRep {
    render(0xB57BFF, 0x5B2FE0) { ctx in
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 500)
        ctx.rotate(by: -12 * .pi / 180)
        // Bell body: a flared dome built from curves.
        let bell = CGMutablePath()
        bell.move(to: CGPoint(x: -250, y: -150))
        bell.addCurve(to: CGPoint(x: -170, y: 60), control1: CGPoint(x: -190, y: -110), control2: CGPoint(x: -175, y: -40))
        bell.addCurve(to: CGPoint(x: 0, y: 250), control1: CGPoint(x: -165, y: 180), control2: CGPoint(x: -100, y: 250))
        bell.addCurve(to: CGPoint(x: 170, y: 60), control1: CGPoint(x: 100, y: 250), control2: CGPoint(x: 165, y: 180))
        bell.addCurve(to: CGPoint(x: 250, y: -150), control1: CGPoint(x: 175, y: -40), control2: CGPoint(x: 190, y: -110))
        bell.closeSubpath()
        // Clapper first, under the bell's shadow.
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 20, alpha: 0.3)
        ctx.setFillColor(rgb(0xFFD36B).cgColor)
        ctx.fillEllipse(in: CGRect(x: -52, y: -228, width: 104, height: 104))
        ctx.restoreGState()
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 36, alpha: 0.35)
        ctx.addPath(bell)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(bell)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xE7DEFF)], from: CGPoint(x: -200, y: 0), to: CGPoint(x: 220, y: 0), in: ctx)
        ctx.restoreGState()
        // Rim and the knob on top.
        ctx.addPath(roundedRect(CGRect(x: -275, y: -175, width: 550, height: 56), 28))
        ctx.setFillColor(rgb(0xF4EFFF).cgColor)
        ctx.fillPath()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: -36, y: 232, width: 72, height: 72))
        ctx.restoreGState()
        // Ringing arcs.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(26)
        let c = CGPoint(x: 512, y: 540)
        for (r, a) in [(300.0, 0.3), (365.0, 0.24)] {
            ctx.addArc(center: c, radius: r, startAngle: .pi * 0.12, endAngle: .pi * (0.12 + a), clockwise: false)
            ctx.strokePath()
            ctx.addArc(center: c, radius: r, startAngle: .pi * 0.88, endAngle: .pi * (0.88 - a), clockwise: true)
            ctx.strokePath()
        }
    }
}
