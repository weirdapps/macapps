import AppKit
import Carbon.HIToolbox
import Kit
import QuartzCore
import SwiftUI

// MARK: - Stage

/// The text itself, one `Text` per paragraph so long scripts never become one giant layer.
/// Equatable, so scrolling (which only changes the offset) never lays the text out again.
struct PromptText: View, Equatable {
    let text: String
    let fontSize: Double
    let width: CGFloat

    var body: some View {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        VStack(alignment: .leading, spacing: fontSize * 0.3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Color.clear.frame(height: fontSize * 0.3)
                } else {
                    Text(line)
                        .font(.system(size: fontSize, weight: .semibold))
                        .lineSpacing(fontSize * 0.3)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: max(1, width), alignment: .leading)
    }
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Dark stage, scrolling text, the reading line and soft fades. Drawn at the real display size;
/// the inspector preview shows the same view scaled down.
struct PromptStage: View {
    let text: String
    let settings: PromptSettings
    let offset: Double
    let size: CGSize
    var onTextHeight: ((CGFloat) -> Void)?

    var lineY: CGFloat { size.height * settings.readingLine }

    var body: some View {
        let width = size.width * (1 - 2 * settings.margin)
        ZStack(alignment: .topLeading) {
            Theme.stage
            PromptText(text: text.isEmpty ? "This script is empty." : text, fontSize: settings.fontSize, width: width)
                .equatable()
                .background(GeometryReader { Color.clear.preference(key: TextHeightKey.self, value: $0.size.height) })
                .offset(x: size.width * settings.margin, y: lineY - settings.fontSize * 0.62 - offset)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(x: settings.mirror ? -1 : 1, y: 1)
            // Fade the lines already read, and the bottom edge.
            LinearGradient(stops: [.init(color: Theme.stage.opacity(0.88), location: 0),
                                   .init(color: Theme.stage.opacity(0.35), location: max(0.01, (lineY - settings.lineHeight * 0.8) / size.height)),
                                   .init(color: Theme.stage.opacity(0), location: max(0.02, (lineY - settings.lineHeight * 0.45) / size.height)),
                                   .init(color: Theme.stage.opacity(0), location: 0.86),
                                   .init(color: Theme.stage.opacity(0.9), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            if settings.showReadingLine {
                ReadingLine(fontSize: settings.fontSize, width: size.width)
                    .offset(y: lineY - settings.fontSize * 0.62)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onPreferenceChange(TextHeightKey.self) { height in onTextHeight?(height) }
    }
}

/// A faint band behind the line being read, with an arrow at each edge.
struct ReadingLine: View {
    let fontSize: Double
    let width: CGFloat

    var body: some View {
        let band = fontSize * 1.24
        ZStack {
            Rectangle().fill(Theme.cyan.opacity(0.07)).frame(height: band)
            VStack {
                Rectangle().fill(Theme.cyan.opacity(0.35)).frame(height: max(1, fontSize / 48))
                Spacer()
                Rectangle().fill(Theme.cyan.opacity(0.35)).frame(height: max(1, fontSize / 48))
            }
            .frame(height: band)
            HStack {
                Arrow().fill(Theme.cyan).frame(width: fontSize * 0.34, height: fontSize * 0.46)
                    .shadow(color: Theme.cyan.opacity(0.8), radius: fontSize / 10)
                Spacer()
                Arrow().fill(Theme.cyan).frame(width: fontSize * 0.34, height: fontSize * 0.46)
                    .scaleEffect(x: -1)
                    .shadow(color: Theme.cyan.opacity(0.8), radius: fontSize / 10)
            }
            .padding(.horizontal, fontSize * 0.2)
        }
        .frame(width: width, height: band)
        .allowsHitTesting(false)
    }

    struct Arrow: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}

// MARK: - Full screen prompt

@MainActor
final class PromptEngine: ObservableObject {
    @Published var clock = PromptClock()
    @Published var flash: String?
    var textHeight = 0.0
    let script: Script
    private var flashTask: Task<Void, Never>?

    init(script: Script) { self.script = script }

    func show(_ message: String) {
        withAnimation(.snappy(duration: 0.15)) { flash = message }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { self?.flash = nil }
        }
    }
}

struct PromptScreen: View {
    @ObservedObject var engine: PromptEngine
    @ObservedObject var model: CueModel
    var topInset: CGFloat = 0 // The camera housing on displays with one.
    var close: () -> Void

    var body: some View {
        GeometryReader { geo in
            let s = model.settings
            ZStack {
                PromptStage(text: engine.script.text, settings: s, offset: engine.clock.offset, size: geo.size) { height in
                    let old = engine.textHeight
                    engine.textHeight = Double(height)
                    engine.clock.limit = max(0, Double(height) - s.lineHeight * 0.7)
                    // A new size or margin reflows the text: stay on the same words.
                    if old > 0, height > 0 { engine.clock.rescale(by: Double(height) / old) }
                }
                VStack(spacing: 0) {
                    hud(s)
                    Spacer()
                    if !engine.clock.isPlaying { hints.transition(.opacity.combined(with: .move(edge: .bottom))) }
                }
                if let n = engine.clock.countdownNumber { countdown(n) }
                if engine.clock.phase == .finished { finished }
                if let flash = engine.flash {
                    Text(flash)
                        .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: engine.clock.isPlaying)
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private func hud(_ s: PromptSettings) -> some View {
        let total = Metrics.duration(words: engine.script.words, wpm: s.wordsPerMinute)
        return VStack(spacing: 0) {
            HStack(spacing: 18) {
                HStack(spacing: 8) {
                    Circle().fill(engine.clock.isPlaying ? Theme.cyan : .white.opacity(0.4)).frame(width: 9, height: 9)
                    Text(Metrics.clock(engine.clock.elapsed)).foregroundStyle(.white.opacity(0.9))
                        .contentTransition(.numericText())
                    Text("of about \(Metrics.clock(total))").foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Text(engine.script.displayTitle).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                Spacer()
                Text("Speed \(s.speed, specifier: "%.1f")").foregroundStyle(.white.opacity(0.7))
                    .contentTransition(.numericText())
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                        .background(Circle().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).focusEffectDisabled()
                .help("Stop prompting (Esc)")
            }
            .font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
            .padding(.horizontal, 28).padding(.vertical, 14).padding(.top, topInset)
            GeometryReader { g in
                Rectangle().fill(LinearGradient(colors: Theme.gradient, startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * engine.clock.progress)
            }
            .frame(height: 2)
            .background(.white.opacity(0.06))
        }
        .opacity(engine.clock.isPlaying ? 0.55 : 1)
    }

    private var hints: some View {
        HStack(spacing: 22) {
            hint("space", "Play or pause")
            hint("↑ ↓", "Speed")
            hint("← →", "Step a line")
            hint("R", "Restart")
            hint("M", "Mirror")
            hint("esc", "Close")
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .padding(.bottom, 32)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 7) {
            Text(key).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.14)))
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func countdown(_ n: Int) -> some View {
        ZStack {
            Theme.stage.opacity(0.75)
            Circle().strokeBorder(LinearGradient(colors: Theme.gradient, startPoint: .top, endPoint: .bottom), lineWidth: 6)
                .frame(width: 220, height: 220)
                .shadow(color: Theme.cyan.opacity(0.5), radius: 24)
            Text("\(n)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: n)
        }
        .transition(.opacity)
    }

    private var finished: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Theme.cyan)
            Text("That is the end").font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            Text("\(Metrics.clock(engine.clock.elapsed)) elapsed. Press Space or R to go again, Esc to close.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(32)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.6)))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

/// A borderless window that can take key focus, to cover a whole display.
final class PromptWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Opens, drives and closes the full screen prompt.
@MainActor
final class PromptController: NSObject, ObservableObject {
    static let shared = PromptController()

    @Published private(set) var isActive = false
    private var window: PromptWindow?
    private var engine: PromptEngine?
    private weak var model: CueModel?
    private var link: CADisplayLink?
    private var monitor: Any?
    private var lastTime: CFTimeInterval = 0

    func start(_ script: Script, model: CueModel) {
        stop()
        guard let screen = NSScreen.prompt(model.settings.displayID) else { NSSound.beep(); return }
        let engine = PromptEngine(script: script)
        let window = PromptWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .statusBar
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(Theme.stage)
        window.title = script.displayTitle
        let host = NSHostingView(rootView: PromptScreen(engine: engine, model: model, topInset: screen.safeAreaInsets.top) { [weak self] in self?.stop() })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
        self.engine = engine
        self.model = model
        isActive = true
        engine.clock.start(countdown: model.settings.countdown)

        lastTime = CACurrentMediaTime()
        let link = host.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func stop() {
        link?.invalidate()
        link = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        engine = nil
        if isActive { isActive = false }
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastTime
        lastTime = now
        guard let engine, let model else { return }
        let before = engine.clock
        var clock = before
        clock.advance(by: dt, rate: model.settings.pointsPerSecond)
        if clock != before { engine.clock = clock }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let engine, let model else { return false }
        if event.type == .scrollWheel {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
            engine.clock.nudge(by: -Double(delta))
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags.contains(.command) {
            if key == "w" || key == "." { stop(); return true }
            return false // ⌘+, ⌘- and the rest go to the menu.
        }
        switch Int(event.keyCode) {
        case kVK_Escape: stop()
        case kVK_Space: engine.clock.toggle(countdown: model.settings.countdown)
        case kVK_UpArrow: model.settings.changeSpeed(by: 0.5); engine.show("Speed \(String(format: "%.1f", model.settings.speed))")
        case kVK_DownArrow: model.settings.changeSpeed(by: -0.5); engine.show("Speed \(String(format: "%.1f", model.settings.speed))")
        case kVK_LeftArrow: engine.clock.nudge(by: -model.settings.lineHeight)
        case kVK_RightArrow: engine.clock.nudge(by: model.settings.lineHeight)
        case kVK_Home: engine.clock.nudge(by: -engine.clock.offset)
        default:
            switch key {
            case "r": engine.clock.start(countdown: model.settings.countdown)
            case "m": model.settings.mirror.toggle(); engine.show(model.settings.mirror ? "Mirrored" : "Not mirrored")
            case "=", "+": model.settings.changeFont(by: 8); engine.show("Text \(Int(model.settings.fontSize)) pt")
            case "-": model.settings.changeFont(by: -8); engine.show("Text \(Int(model.settings.fontSize)) pt")
            default: return false
            }
        }
        return true
    }
}
