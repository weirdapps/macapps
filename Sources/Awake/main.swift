import AppKit
import Carbon.HIToolbox
import Combine
import IOKit.pwr_mgt
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
    private var hotKey: HotKey?
    private var cancellables: Set<AnyCancellable> = []
    let keeper = Keeper()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "cup.and.saucer", accessibilityLabel: "Awake") {
            AwakeView().environmentObject(self.keeper)
        }
        status.onSecondaryClick = { [weak self] in self?.keeper.toggle(feedback: true) }
        hotKey = HotKey(keyCode: kVK_ANSI_A, modifiers: cmdKey | optionKey) { [weak self] in self?.keeper.toggle(feedback: true) }
        keeper.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) { keeper.stop(feedback: false) }

    private func updateStatus() {
        guard keeper.isActive else {
            status.setSymbol("cup.and.saucer", label: "Awake is off")
            status.setTitle("")
            return
        }
        status.setSymbol("cup.and.saucer.fill", label: "Keeping your Mac awake")
        status.setTitle(keeper.remaining.map(Keeper.format) ?? "")
    }
}

// MARK: - Model

/// Holds a power management assertion, the same mechanism `caffeinate` uses.
@MainActor
final class Keeper: ObservableObject {
    @Published private(set) var isActive = false
    /// nil while active means indefinitely.
    @Published private(set) var end: Date?
    @Published private(set) var started: Date?
    @Published private(set) var now = Date()
    @AppStorage("keepDisplayOn") var keepDisplayOn = true { didSet { if isActive { assert() } } }
    @AppStorage("customMinutes") var customMinutes = 45
    @AppStorage("defaultMinutes") var defaultMinutes = 0

    private var assertion: IOPMAssertionID = 0
    private var clock: Timer?

    var remaining: TimeInterval? { end.map { max(0, $0.timeIntervalSince(now)) } }

    var progress: Double {
        guard let end, let started else { return 1 }
        let total = end.timeIntervalSince(started)
        return total > 0 ? max(0, min(1, end.timeIntervalSince(now) / total)) : 0
    }

    func toggle(feedback: Bool) {
        if isActive { stop(feedback: feedback) } else { start(minutes: defaultMinutes, feedback: feedback) }
    }

    /// Zero minutes means indefinitely.
    func start(minutes: Int, feedback: Bool = false) {
        start(until: minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil, feedback: feedback)
    }

    func start(until end: Date?, feedback: Bool = false) {
        self.end = end
        started = Date()
        now = started!
        isActive = true
        assert()
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        clock?.tolerance = 0.2
        if feedback { HUD.show(symbol: "cup.and.saucer.fill", title: end == nil ? "Awake" : "Awake for \(Keeper.describe(until: end!))") }
    }

    func stop(feedback: Bool) {
        clock?.invalidate()
        clock = nil
        release()
        isActive = false
        end = nil
        started = nil
        if feedback { HUD.show(symbol: "moon.zzz.fill", title: "Sleep allowed") }
    }

    private func tick() {
        now = Date()
        if let end, now >= end { stop(feedback: true) }
    }

    private func assert() {
        release()
        let type = keepDisplayOn ? kIOPMAssertPreventUserIdleDisplaySleep : kIOPMAssertPreventUserIdleSystemSleep
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Awake is keeping this Mac awake" as CFString, &assertion)
    }

    private func release() {
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    // MARK: Time helpers

    /// "1:05:09" or "4:59".
    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func label(minutes: Int) -> String {
        if minutes == 0 { return "Indefinitely" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    static func describe(until end: Date) -> String { label(minutes: Int((end.timeIntervalSinceNow / 60).rounded())) }

    /// The next moment the clock shows the hour and minute of `time`: later today, or tomorrow if that has passed.
    static func next(_ time: Date, after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }
}

// MARK: - Views

enum Palette {
    static let accent = [Color(red: 1, green: 0.78, blue: 0.36), Color(red: 0.96, green: 0.45, blue: 0.24)]
    static let night = [Color(red: 0.45, green: 0.42, blue: 0.95), Color(red: 0.24, green: 0.18, blue: 0.62)]
    static let presets = [15, 30, 60, 120, 0]
}

struct AwakeView: View {
    @EnvironmentObject var keeper: Keeper
    @State private var untilTime = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Hero()
                VStack(spacing: 3) {
                    Text(keeper.isActive ? "Your Mac stays awake" : "Your Mac sleeps as usual")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .contentTransition(.interpolate)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.top, 22)
            .padding(.bottom, 16)

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Palette.presets, id: \.self) { minutes in
                        Chip(title: minutes == 0 ? "∞" : Keeper.label(minutes: minutes).replacingOccurrences(of: " ", with: "")) {
                            withAnimation(.snappy) { keeper.start(minutes: minutes) }
                        }
                        .help(Keeper.label(minutes: minutes))
                    }
                }
                OptionRow(symbol: "timer", title: "For") {
                    Stepper(value: $keeper.customMinutes, in: 5...720, step: 5) {
                        Text(Keeper.label(minutes: keeper.customMinutes))
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                } action: { keeper.start(minutes: keeper.customMinutes) }
                OptionRow(symbol: "clock", title: "Until") {
                    DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.stepperField)
                        .fixedSize()
                } action: { keeper.start(until: Keeper.next(untilTime)) }
                HStack(spacing: 6) {
                    Text("Toggle from anywhere").font(.system(size: 11)).foregroundStyle(.tertiary)
                    KeyCap("⌥⌘A")
                    Text("or right-click the icon").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            Divider().opacity(0.5)
            PanelFooter(name: "Awake", shortcut: "⌥⌘A") {
                Toggle("Keep the Display On", isOn: $keeper.keepDisplayOn)
                Picker("Shortcut Keeps Awake", selection: $keeper.defaultMinutes) {
                    ForEach(Palette.presets, id: \.self) { Text(Keeper.label(minutes: $0)).tag($0) }
                }
            }
        }
        .frame(width: 320)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: keeper.isActive)
    }

    private var subtitle: String {
        guard keeper.isActive else { return "Pick how long to stay awake" }
        let display = keeper.keepDisplayOn ? "Display stays on" : "Display may sleep"
        guard let end = keeper.end, let remaining = keeper.remaining else { return "Until you turn it off. \(display)." }
        return "\(Keeper.format(remaining)) left, until \(end.formatted(date: .omitted, time: .shortened))"
    }
}

struct Hero: View {
    @EnvironmentObject var keeper: Keeper
    @State private var hovering = false

    var body: some View {
        let colors = keeper.isActive ? Palette.accent : Palette.night
        Button {
            withAnimation(.snappy) { keeper.toggle(feedback: false) }
        } label: {
            ZStack {
                Circle().stroke(.quaternary.opacity(0.5), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: keeper.isActive ? max(0.0001, keeper.progress) : 0)
                    .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: keeper.progress)
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center)).padding(3))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: colors[1].opacity(0.45), radius: hovering ? 14 : 9, y: 4)
                    .padding(12)
                Image(systemName: keeper.isActive ? "cup.and.saucer.fill" : "moon.zzz.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            }
            .frame(width: 112, height: 112)
            .scaleEffect(hovering ? 1.04 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(keeper.isActive ? "Allow sleep" : "Stay awake")
    }
}

struct Chip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.75 : 0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct OptionRow<Control: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var control: Control
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 12.5))
            Spacer()
            control
            Button { withAnimation(.snappy) { action() } } label: {
                Text("Start")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(LinearGradient(colors: Palette.accent, startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Palette.accent[1].opacity(0.3), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

// MARK: - Icon

//: an open eye with a sun for a pupil, on a night sky

func appIcon() -> NSBitmapImageRep {
    render(0x6C63FF, 0x221A5C) { ctx in
        // Stars.
        for (x, y, s) in [(250.0, 780.0, 22.0), (760, 800, 16), (820, 640, 12), (200, 560, 12), (700, 250, 14), (300, 240, 18)] {
            sparkle(ctx, at: CGPoint(x: x, y: y), size: s, color: NSColor.white.withAlphaComponent(0.7))
        }
        let c = CGPoint(x: 512, y: 500)
        // Eye outline: two arcs meeting at the corners.
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: c.x - 300, y: c.y))
        eye.addQuadCurve(to: CGPoint(x: c.x + 300, y: c.y), control: CGPoint(x: c.x, y: c.y + 330))
        eye.addQuadCurve(to: CGPoint(x: c.x - 300, y: c.y), control: CGPoint(x: c.x, y: c.y - 330))
        eye.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.35)
        ctx.addPath(eye)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Sun iris with rays, clipped to the eye.
        ctx.saveGState()
        ctx.addPath(eye)
        ctx.clip()
        radial([rgb(0xFFE08A), rgb(0xFF9A3C), rgb(0xF0602A)], center: c, radius: 130, in: ctx)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(eye)
        ctx.clip()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addRect(tile)
        ctx.addEllipse(in: CGRect(x: c.x - 130, y: c.y - 130, width: 260, height: 260))
        ctx.drawPath(using: .eoFill)
        ctx.restoreGState()
        // Pupil and highlight.
        ctx.setFillColor(rgb(0x2A1F6E).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 56, y: c.y - 56, width: 112, height: 112))
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x + 18, y: c.y + 26, width: 40, height: 40))
        // Lashes on the upper lid.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(30)
        ctx.setLineCap(.round)
        for i in -2...2 {
            let a = CGFloat.pi / 2 + CGFloat(i) * 0.36
            let base = CGPoint(x: c.x + cos(a) * 205, y: c.y - 40 + sin(a) * 205)
            ctx.move(to: base)
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 290, y: c.y - 40 + sin(a) * 290))
        }
        ctx.strokePath()
    }
}
