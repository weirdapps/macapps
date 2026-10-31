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
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []
    let watch = Stopwatch()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "stopwatch", accessibilityLabel: "Lap") {
            LapView().environmentObject(self.watch)
        }
        status.onSecondaryClick = { [weak self] in self?.watch.startOrStop() }
        watch.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.stateChanged() }
            .store(in: &cancellables)
        stateChanged()
    }

    private func stateChanged() {
        if watch.running {
            status.setSymbol("stopwatch.fill", label: "Lap, running")
            if ticker == nil {
                ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateTitle() }
                }
            }
        } else {
            status.setSymbol("stopwatch", label: "Lap")
            ticker?.invalidate()
            ticker = nil
        }
        updateTitle()
    }

    private func updateTitle() {
        status.setTitle(watch.elapsed() > 0 ? Stopwatch.format(watch.elapsed(), hundredths: false) : "")
    }
}

// MARK: - Model

@MainActor
final class Stopwatch: ObservableObject {
    /// Time banked before the current run.
    @Published private(set) var banked: TimeInterval = 0
    /// When the current run started, or nil when stopped.
    @Published private(set) var startedAt: Date?
    /// Elapsed time at each lap press, ascending.
    @Published private(set) var splits: [TimeInterval] = []

    private struct Saved: Codable { var banked: TimeInterval; var startedAt: Date?; var splits: [TimeInterval] }

    init() {
        if let saved = Storage.load(Saved.self, app: "Lap", file: "stopwatch.json") {
            banked = saved.banked
            startedAt = saved.startedAt
            splits = saved.splits
        }
    }

    var running: Bool { startedAt != nil }

    func elapsed(at now: Date = Date()) -> TimeInterval {
        banked + (startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    func startOrStop() {
        if let startedAt {
            banked += Date().timeIntervalSince(startedAt)
            self.startedAt = nil
        } else {
            startedAt = Date()
        }
        persist()
    }

    func lap() {
        guard running else { return }
        splits.append(elapsed())
        persist()
    }

    func reset() {
        banked = 0
        startedAt = nil
        splits = []
        persist()
    }

    private func persist() {
        Storage.save(Saved(banked: banked, startedAt: startedAt, splits: splits), app: "Lap", file: "stopwatch.json")
    }

    var laps: [LapRow] { Stopwatch.rows(splits) }

    /// Plain text table of the laps, for the clipboard.
    var text: String {
        let lines = laps.map { "Lap \($0.number)\t\(Stopwatch.format($0.time))\t\(Stopwatch.format($0.split))" }
        return (["Lap\tTime\tSplit"] + lines + ["Total\t\(Stopwatch.format(elapsed()))"]).joined(separator: "\n")
    }

    struct LapRow: Identifiable, Equatable {
        enum Mark { case none, fastest, slowest }
        let number: Int
        let time: TimeInterval
        let split: TimeInterval
        /// Difference to the previous lap; nil for the first.
        let delta: TimeInterval?
        let mark: Mark
        var id: Int { number }
    }

    /// Turns cumulative splits into laps with deltas, fastest and slowest marked once there are two or more.
    nonisolated static func rows(_ splits: [TimeInterval]) -> [LapRow] {
        let times = splits.enumerated().map { i, s in s - (i > 0 ? splits[i - 1] : 0) }
        let fastest = times.count > 1 ? times.min() : nil
        let slowest = times.count > 1 ? times.max() : nil
        return times.enumerated().map { i, t in
            LapRow(number: i + 1, time: t, split: splits[i], delta: i > 0 ? t - times[i - 1] : nil,
                   mark: t == fastest ? .fastest : t == slowest ? .slowest : .none)
        }
    }

    /// "4:05.27", or "1:04:05.27" past an hour, with the locale's decimal separator. Truncates, like a real stopwatch.
    nonisolated static func format(_ t: TimeInterval, hundredths: Bool = true) -> String {
        // The epsilon keeps 59.64 from printing as 59.63 after floating point subtraction.
        let cs = Int((max(0, t) * 100 + 1e-6).rounded(.down))
        let h = cs / 360_000, m = cs / 6000 % 60, s = cs / 100 % 60, c = cs % 100
        let lead = h > 0 ? String(format: "%d:%02d:", h, m) : "\(m):"
        guard hundredths else { return lead + String(format: "%02d", s) }
        // FormatStyle, not Locale.decimalSeparator: only it honours a region set apart from the language.
        let seconds = (Double(s) + Double(c) / 100).formatted(.number.precision(.integerAndFractionLength(integer: 2, fraction: 2)).grouping(.never))
        return lead + seconds
    }

    nonisolated static func formatDelta(_ d: TimeInterval) -> String {
        (d >= 0 ? "+" : "-") + abs(d).formatted(.number.precision(.fractionLength(2)).grouping(.never))
    }
}

// MARK: - Views

struct LapView: View {
    @EnvironmentObject var watch: Stopwatch

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: !watch.running)) { context in
                Dial(elapsed: watch.elapsed(at: context.date), lapElapsed: watch.elapsed(at: context.date) - (watch.splits.last ?? 0))
            }
            .padding(.top, 18)
            .padding(.bottom, 14)
            controls
                .padding(.bottom, 14)
            Divider().opacity(0.5)
            LapList()
            Divider().opacity(0.5)
            PanelFooter(name: "Lap") {
                Button("Copy Laps as Text") { copy() }.keyboardShortcut("c").disabled(watch.splits.isEmpty)
                Button("Reset", role: .destructive) { withAnimation(.snappy) { watch.reset() } }
            }
        }
        .frame(width: 320)
    }

    private var controls: some View {
        HStack(spacing: 14) {
            GlassIconButton("arrow.counterclockwise", help: "Reset") { withAnimation(.snappy) { watch.reset() } }
                .disabled(watch.running || watch.elapsed() == 0)
            Button {
                withAnimation(.snappy) { watch.startOrStop() }
            } label: {
                Label(watch.running ? "Stop" : watch.elapsed() > 0 ? "Resume" : "Start",
                      systemImage: watch.running ? "stop.fill" : "play.fill")
                    .frame(width: 92)
            }
            .buttonStyle(PillButtonStyle(watch.running ? Accent.stop : Accent.colors))
            .keyboardShortcut(.space, modifiers: [])
            GlassIconButton("flag.fill", help: "Lap (L)") { withAnimation(.snappy) { watch.lap() } }
                .disabled(!watch.running)
                .keyboardShortcut("l", modifiers: [])
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(watch.text, forType: .string)
        HUD.show(symbol: "doc.on.doc.fill", title: "Laps copied", tint: .green)
    }
}

/// The running time over a sweeping seconds ring.
struct Dial: View {
    let elapsed: TimeInterval
    let lapElapsed: TimeInterval

    var body: some View {
        let fraction = elapsed.truncatingRemainder(dividingBy: 60) / 60
        ZStack {
            // Sixty ticks, every fifth one longer.
            ForEach(0..<60) { i in
                Capsule()
                    .fill(Double(i) / 60 <= fraction && elapsed > 0 ? AnyShapeStyle(Accent.gradient) : AnyShapeStyle(.quaternary))
                    .frame(width: i % 5 == 0 ? 2.5 : 1.5, height: i % 5 == 0 ? 10 : 6)
                    .offset(y: -86)
                    .rotationEffect(.degrees(Double(i) * 6))
            }
            VStack(spacing: 3) {
                Text(Stopwatch.format(elapsed))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Lap \(Stopwatch.format(lapElapsed))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .opacity(elapsed > 0 ? 1 : 0)
            }
        }
        .frame(width: 184, height: 184)
    }
}

struct LapList: View {
    @EnvironmentObject var watch: Stopwatch

    var body: some View {
        let laps = watch.laps
        if laps.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text("Press the flag or L while running to mark a lap.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
        } else {
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(laps.reversed()) { lap in
                        LapRowView(lap: lap)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(10)
            }
            .frame(height: min(CGFloat(laps.count) * 34 + 16, 220))
        }
    }
}

struct LapRowView: View {
    let lap: Stopwatch.LapRow
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text("Lap \(lap.number)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
            if lap.mark != .none {
                Text(lap.mark == .fastest ? "Fastest" : "Slowest")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint))
            }
            Spacer()
            if let d = lap.delta {
                Text(Stopwatch.formatDelta(d))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(d <= 0 ? Color.green : Color.orange)
            }
            Text(Stopwatch.format(lap.time))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(lap.mark == .none ? AnyShapeStyle(.primary) : AnyShapeStyle(tint))
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .help("Split \(Stopwatch.format(lap.split))")
        .onHover { hovering = $0 }
    }

    private var tint: Color { lap.mark == .fastest ? .green : .red }
}

enum Accent {
    static let colors = [Color(red: 0.25, green: 0.88, blue: 0.62), Color(red: 0.02, green: 0.62, blue: 0.5)]
    static let stop = [Color(red: 1, green: 0.45, blue: 0.4), Color(red: 0.88, green: 0.2, blue: 0.24)]
    static let gradient = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a stopwatch with a sweeping lap hand

func appIcon() -> NSBitmapImageRep {
    render(0x44E3A2, 0x078F79) { ctx in
        let c = CGPoint(x: 512, y: 470), r: CGFloat = 270
        // Crown and side button, drawn first so the case overlaps them.
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 20, alpha: 0.3)
        ctx.setFillColor(rgb(0xEFF6F3).cgColor)
        ctx.addPath(roundedRect(CGRect(x: c.x - 34, y: c.y + r - 10, width: 68, height: 80), 14))
        ctx.addPath(roundedRect(CGRect(x: c.x - 72, y: c.y + r + 58, width: 144, height: 52), 22))
        ctx.fillPath()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -40 * .pi / 180)
        ctx.addPath(roundedRect(CGRect(x: -28, y: r - 14, width: 56, height: 64), 14))
        ctx.fillPath()
        ctx.restoreGState()
        // Case.
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        shadow(ctx, y: -20, blur: 40, alpha: 0.35)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        // Face.
        let face = disc.insetBy(dx: 34, dy: 34)
        ctx.saveGState()
        ctx.addEllipse(in: face)
        ctx.clip()
        radial([rgb(0x1E3A3A), rgb(0x0B1F22)], center: CGPoint(x: c.x - 60, y: c.y + 80), radius: r * 1.3, in: ctx)
        ctx.restoreGState()
        // The swept lap, as a glowing wedge.
        let start = CGFloat.pi / 2, end = start - 0.36 * 2 * .pi
        ctx.saveGState()
        ctx.move(to: c)
        ctx.addArc(center: c, radius: face.width / 2 - 26, startAngle: start, endAngle: end, clockwise: true)
        ctx.closePath()
        ctx.clip()
        radial([rgb(0x5BF0B4, 0.65), rgb(0x5BF0B4, 0.15)], center: c, radius: face.width / 2, in: ctx)
        ctx.restoreGState()
        // Ticks.
        ctx.setLineCap(.round)
        for i in 0..<60 where i % 5 == 0 {
            let a = CGFloat(i) / 60 * 2 * .pi
            let inner: CGFloat = i % 15 == 0 ? 160 : 180
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 200, y: c.y + sin(a) * 200))
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(12)
        ctx.strokePath()
        // Hand.
        ctx.saveGState()
        shadow(ctx, y: -4, blur: 12, alpha: 0.5)
        ctx.move(to: CGPoint(x: c.x - cos(end) * 40, y: c.y - sin(end) * 40))
        ctx.addLine(to: CGPoint(x: c.x + cos(end) * 196, y: c.y + sin(end) * 196))
        ctx.setStrokeColor(rgb(0x5BF0B4).cgColor)
        ctx.setLineWidth(16)
        ctx.strokePath()
        ctx.setFillColor(rgb(0x5BF0B4).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x0B1F22).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
    }
}
