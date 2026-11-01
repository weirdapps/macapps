import AppKit
import Combine
import CoreGraphics
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
    let coach = BreakCoach()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-break"), i + 1 < CommandLine.arguments.count {
            BreakOverlay.snapshot(coach: coach, to: CommandLine.arguments[i + 1])
            return
        }
        status = StatusPopover(symbol: "eye", accessibilityLabel: "Blink") {
            BlinkView().environmentObject(self.coach)
        }
        status.onSecondaryClick = { [weak self] in self?.coach.togglePause() }
        coach.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    func applicationWillTerminate(_ notification: Notification) { coach.persist() }

    private func updateStatus() {
        if coach.paused {
            status.setSymbol("eye.slash", label: "Blink, paused")
            status.setTitle("")
        } else if coach.onBreak {
            status.setSymbol("eye.fill", label: "Blink, on a break")
            status.setTitle("\(Int(coach.breakLeft.rounded(.up)))s")
        } else {
            status.setSymbol("eye", label: "Blink")
            status.setTitle(coach.showCountdown ? "\(Int((coach.untilBreak / 60).rounded(.up)))m" : "")
        }
    }
}

// MARK: - Model

/// Counts active screen time and decides when a break is due. Pure, so it can be stepped from a test.
struct BreakClock: Equatable {
    enum Event: Equatable { case breakDue, naturalBreak }

    var active: TimeInterval = 0
    var work: TimeInterval
    /// Idle longer than this pauses the count.
    var idleGrace: TimeInterval = 60
    /// Idle longer than this counts as a break taken away from the screen.
    var naturalBreak: TimeInterval = 300
    private var resetForIdle = false

    init(work: TimeInterval) { self.work = work }

    mutating func step(dt: TimeInterval, idle: TimeInterval) -> Event? {
        if idle >= naturalBreak {
            guard !resetForIdle else { return nil }
            resetForIdle = true
            // Only a pause that follows screen time counts as a break; launching on an idle Mac does not.
            let hadWork = active > 0
            active = 0
            return hadWork ? .naturalBreak : nil
        }
        resetForIdle = false
        guard idle < idleGrace else { return nil }
        active += dt
        if active >= work {
            active = 0
            return .breakDue
        }
        return nil
    }
}

@MainActor
final class BreakCoach: ObservableObject {
    @Published private(set) var clock: BreakClock
    @Published private(set) var onBreak = false
    @Published private(set) var breakLeft: TimeInterval = 0
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var stats = Stats()

    @AppStorage("workMinutes") var workMinutes = 20 { didSet { clock.work = TimeInterval(workMinutes * 60) } }
    @AppStorage("breakSeconds") var breakSeconds = 20
    @AppStorage("dim") var dim = true
    @AppStorage("showCountdown") var showCountdown = true
    @AppStorage("sound") var sound = true

    struct Stats: Codable, Equatable {
        var day = BreakCoach.dayKey
        var taken = 0
        var skipped = 0
        var activeSeconds: TimeInterval = 0
    }

    private var timer: Timer?
    private var lastTick = Date()
    private var ticks = 0
    private let overlay = BreakOverlay()
    /// Snapshot runs show fixed demo numbers and never read or write the real stats.
    private let demo = CommandLine.arguments.contains("--snapshot-break") || CommandLine.arguments.contains("--snapshot")

    init() {
        clock = BreakClock(work: TimeInterval(UserDefaults.standard.object(forKey: "workMinutes") as? Int ?? 20) * 60)
        // Snapshots need no clock.
        if demo {
            stats = Stats(taken: 5, skipped: 1, activeSeconds: 2 * 3600 + 25 * 60)
            clock.active = 7 * 60
            return
        }
        if let saved = Storage.load(Stats.self, app: "Blink", file: "today.json"), saved.day == BreakCoach.dayKey { stats = saved }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// The local calendar day; the ISO 8601 style defaults to GMT, which would roll over at 02:00 in Athens.
    nonisolated static var dayKey: String {
        Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
    }

    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    var untilBreak: TimeInterval { max(0, clock.work - clock.active) }
    var progress: Double { clock.work > 0 ? clock.active / clock.work : 0 }

    /// Seconds since the last keyboard, mouse or trackpad event. Reading it needs no permission.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        let now = Date()
        let dt = min(5, now.timeIntervalSince(lastTick)) // a sleeping Mac must not count as screen time
        lastTick = now
        ticks += 1
        // Screen time only changes here, so save it every minute rather than only on breaks.
        if ticks % 60 == 0 { persist() }
        if stats.day != BreakCoach.dayKey { stats = Stats() }
        if let until = pausedUntil, until <= now { pausedUntil = nil }

        if onBreak {
            breakLeft -= dt
            if breakLeft <= 0 { finishBreak(taken: true) }
            return
        }
        guard !paused else { return }
        let idle = BreakCoach.idleSeconds
        if idle < clock.idleGrace { stats.activeSeconds += dt }
        switch clock.step(dt: dt, idle: idle) {
        case .breakDue: startBreak()
        case .naturalBreak: stats.taken += 1; persist()
        case nil: break
        }
    }

    func startBreak() {
        onBreak = true
        breakLeft = TimeInterval(breakSeconds)
        clock.active = 0
        if sound { NSSound(named: "Purr")?.play() }
        overlay.show(coach: self, dim: dim)
    }

    func finishBreak(taken: Bool) {
        guard onBreak else { return }
        onBreak = false
        if taken {
            stats.taken += 1
            if sound { NSSound(named: "Glass")?.play() }
        } else {
            stats.skipped += 1
        }
        overlay.hide()
        persist()
    }

    func snooze() {
        guard onBreak else { return }
        onBreak = false
        overlay.hide()
        // Come back in five minutes.
        clock.active = max(0, clock.work - 300)
    }

    func togglePause() {
        pausedUntil = paused ? nil : Date().addingTimeInterval(3600)
    }

    func pause(for seconds: TimeInterval) { pausedUntil = Date().addingTimeInterval(seconds) }

    func persist() { if !demo { Storage.save(stats, app: "Blink", file: "today.json") } }
}

// MARK: - Break overlay

/// A dimmed layer over every screen with the countdown card in the middle, or the card alone.
@MainActor
final class BreakOverlay {
    private var panels: [NSPanel] = []

    func show(coach: BreakCoach, dim: Bool) {
        hide()
        for screen in NSScreen.screens {
            // Without the dim, the panel shrinks to the card so the rest of the screen stays usable.
            let card = NSSize(width: 520, height: 360)
            let frame = dim ? screen.frame
                : NSRect(x: screen.frame.midX - card.width / 2, y: screen.frame.midY - card.height / 2, width: card.width, height: card.height)
            if !dim && screen != NSScreen.main { continue }
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let view = NSHostingView(rootView: BreakScreen(dim: dim, primary: screen == NSScreen.main).environmentObject(coach))
            panel.contentView = view
            panel.setFrame(frame, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.6; panel.animator().alphaValue = 1 }
            panels.append(panel)
        }
    }

    func hide() {
        for panel in panels {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        }
        panels = []
    }

    /// Renders the break card alone, for checking its design: `Blink --snapshot-break out.png`.
    static func snapshot(coach: BreakCoach, to path: String) {
        let host = NSHostingView(rootView: BreakCard(left: 14, total: 20).environmentObject(coach)
            .padding(40).background(Color(white: 0.25)))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            exit(0)
        }
    }
}

struct BreakScreen: View {
    @EnvironmentObject var coach: BreakCoach
    let dim: Bool
    let primary: Bool

    var body: some View {
        ZStack {
            if dim {
                Color.black.opacity(0.45)
            }
            if primary {
                BreakCard(left: coach.breakLeft, total: TimeInterval(coach.breakSeconds))
            }
        }
        .ignoresSafeArea()
    }
}

struct BreakCard: View {
    @EnvironmentObject var coach: BreakCoach
    let left: TimeInterval
    let total: TimeInterval
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: total > 0 ? max(0.001, left / total) : 0)
                    .stroke(Accent.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: left)
                Text("\(Int(left.rounded(.up)))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(.white)
            }
            .frame(width: 104, height: 104)
            .scaleEffect(breathe ? 1.04 : 0.97)
            VStack(spacing: 5) {
                Text("Look at something far away")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("About six metres away, for \(Int(total)) seconds. Let your eyes relax.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                Button("Snooze 5 min") { coach.snooze() }
                    .buttonStyle(CardButtonStyle())
                Button("Skip") { coach.finishBreak(taken: false) }
                    .buttonStyle(CardButtonStyle())
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .background(VisualEffect(material: .hudWindow).clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous)))
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.12).opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.25 : 0.14)))
    }
}

// MARK: - Views

struct BlinkView: View {
    @EnvironmentObject var coach: BreakCoach

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ZStack {
                    Circle().stroke(.quaternary.opacity(0.6), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: max(0.001, coach.progress))
                        .stroke(Accent.gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: coach.progress)
                        .opacity(coach.progress <= 0 ? 0 : coach.paused ? 0.35 : 1)
                    Image(systemName: coach.paused ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Accent.gradient)
                }
                .frame(width: 76, height: 76)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(bigNumber)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Counts only while you are active")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.snappy) { coach.startBreak() }
                } label: {
                    Label("Break Now", systemImage: "eye")
                }
                .buttonStyle(PillButtonStyle(Accent.colors))
                .disabled(coach.onBreak)
                Button {
                    withAnimation(.snappy) { coach.togglePause() }
                } label: {
                    Label(coach.paused ? "Resume" : "Pause 1 Hour", systemImage: coach.paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PillButtonStyle([Color.gray.opacity(0.75), Color.gray]))
            }
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                StatTile(value: "\(coach.stats.taken)", label: coach.stats.taken == 1 ? "break taken" : "breaks taken", symbol: "checkmark.circle.fill")
                StatTile(value: "\(coach.stats.skipped)", label: "skipped", symbol: "forward.fill")
                StatTile(value: Self.duration(coach.stats.activeSeconds), label: "screen time", symbol: "display")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
            Divider().opacity(0.5)
            PanelFooter(name: "Blink") {
                Picker("Break Every", selection: $coach.workMinutes) {
                    ForEach([20, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Break Length", selection: $coach.breakSeconds) {
                    ForEach([20, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Toggle("Dim the Screen", isOn: $coach.dim)
                Toggle("Play Sounds", isOn: $coach.sound)
                Toggle("Show Minutes in Menu Bar", isOn: $coach.showCountdown)
                Divider()
                Button("Pause Until Tomorrow") {
                    let tomorrow = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
                    coach.pause(for: tomorrow.timeIntervalSinceNow)
                }
            }
        }
        .frame(width: 330)
    }

    private var headline: String {
        if coach.onBreak { return "On a break" }
        if let until = coach.pausedUntil, coach.paused { return "Paused until \(until.formatted(date: .omitted, time: .shortened))" }
        return "Next break in"
    }

    private var bigNumber: String {
        if coach.onBreak { return "\(Int(coach.breakLeft.rounded(.up))) s" }
        if coach.paused { return "Resting" }
        let s = Int(coach.untilBreak.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Accent.gradient)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

enum Accent {
    static let colors = [Color(red: 0.72, green: 0.9, blue: 0.3), Color(red: 0.33, green: 0.68, blue: 0.18)]
    static let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: an open eye with a leaf-green iris

func appIcon() -> NSBitmapImageRep {
    render(0xCDEB6B, 0x4E9A25) { ctx in
        let c = CGPoint(x: 512, y: 512)
        // Almond-shaped eye.
        let eye = CGMutablePath()
        eye.move(to: CGPoint(x: c.x - 330, y: c.y))
        eye.addQuadCurve(to: CGPoint(x: c.x + 330, y: c.y), control: CGPoint(x: c.x, y: c.y + 400))
        eye.addQuadCurve(to: CGPoint(x: c.x - 330, y: c.y), control: CGPoint(x: c.x, y: c.y - 400))
        eye.closeSubpath()
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.3)
        ctx.addPath(eye)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(eye)
        ctx.clip()
        // Soft shading under the lid.
        gradient([rgb(0xDCE6D5), rgb(0xFFFFFF, 0)], from: CGPoint(x: 0, y: c.y + 200), to: CGPoint(x: 0, y: c.y + 60), in: ctx)
        // Iris and pupil.
        let r: CGFloat = 150
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.clip()
        radial([rgb(0xB9E85A), rgb(0x5DA92B), rgb(0x2F6B19)], center: c, radius: r, in: ctx)
        ctx.restoreGState()
        // Fibres in the iris.
        ctx.setStrokeColor(rgb(0xE6FFB0, 0.35).cgColor)
        ctx.setLineWidth(5)
        for i in 0..<24 {
            let a = CGFloat(i) / 24 * 2 * .pi
            ctx.move(to: CGPoint(x: c.x + cos(a) * 70, y: c.y + sin(a) * 70))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 135, y: c.y + sin(a) * 135))
        }
        ctx.strokePath()
        ctx.setFillColor(rgb(0x14240C).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 62, y: c.y - 62, width: 124, height: 124))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x + 22, y: c.y + 30, width: 54, height: 54))
        ctx.fillEllipse(in: CGRect(x: c.x - 70, y: c.y - 74, width: 22, height: 22))
        ctx.restoreGState()
        // Upper lid line and lashes.
        ctx.setLineCap(.round)
        ctx.setStrokeColor(rgb(0x24480F).cgColor)
        ctx.setLineWidth(20)
        ctx.move(to: CGPoint(x: c.x - 330, y: c.y))
        ctx.addQuadCurve(to: CGPoint(x: c.x + 330, y: c.y), control: CGPoint(x: c.x, y: c.y + 400))
        ctx.strokePath()
        ctx.setLineWidth(18)
        for t in [0.22, 0.38, 0.5, 0.62, 0.78] {
            // Point on the lid curve and its outward normal.
            let p = CGPoint(x: (1 - t) * (1 - t) * (c.x - 330) + 2 * (1 - t) * t * c.x + t * t * (c.x + 330),
                            y: (1 - t) * (1 - t) * c.y + 2 * (1 - t) * t * (c.y + 400) + t * t * c.y)
            let dx = 2 * (1 - t) * 330 + 2 * t * 330, dy = 2 * (1 - t) * 400 - 2 * t * 400
            let len = sqrt(dx * dx + dy * dy)
            let n = CGPoint(x: -dy / len, y: dx / len)
            ctx.move(to: p)
            ctx.addLine(to: CGPoint(x: p.x + n.x * 62, y: p.y + n.y * 62))
        }
        ctx.strokePath()
    }
}
