import Charts
import Kit
import SwiftUI

enum Theme {
    static let light = Color(red: 0xB9 / 255, green: 0xA7 / 255, blue: 0xFF / 255)
    static let deep = Color(red: 0x6E / 255, green: 0x5B / 255, blue: 0xC9 / 255)
    static let colors = [light, deep]
    static let accent = LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
}

struct ContentView: View {
    @ObservedObject var model: ExhaleModel

    var body: some View {
        NavigationSplitView {
            PatternList(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            VStack(spacing: 0) {
                Stage(model: model)
                Divider()
                ControlBar(model: model)
            }
            .frame(minWidth: 460, minHeight: 440)
            .inspector(isPresented: $model.showHistory) {
                HistoryPanel(model: model)
                    .inspectorColumnWidth(min: 230, ideal: 250, max: 320)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.runState == .running || model.runState == .paused {
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("End the session (⌘.)")
                }
                Button { model.toggle() } label: {
                    Label(model.runState == .running ? "Pause" : "Start",
                          systemImage: model.runState == .running ? "pause.fill" : "play.fill")
                }
                .help(model.runState == .running ? "Pause (Space)" : "Start breathing (Space)")
                Button { withAnimation(.snappy) { model.showHistory.toggle() } } label: {
                    Label("History", systemImage: "sidebar.trailing")
                }
                .help("Show or hide history (⌥⌘I)")
            }
        }
        .tint(Theme.deep)
    }
}

// MARK: - Sidebar

struct PatternList: View {
    @ObservedObject var model: ExhaleModel

    var body: some View {
        List(selection: Binding(get: { model.settings.pattern }, set: { if let p = $0, model.canEdit { model.settings.pattern = p } })) {
            Section("Patterns") {
                ForEach(PatternID.allCases) { id in
                    PatternRow(id: id, phases: Patterns.phases(id, custom: model.settings.custom),
                               selected: model.settings.pattern == id)
                        .tag(id)
                }
            }
            if model.settings.pattern == .custom {
                Section("Custom rhythm") {
                    RhythmStepper(title: "Breathe in", value: $model.settings.custom.inhale, minimum: 1)
                    RhythmStepper(title: "Hold", value: $model.settings.custom.holdFull, minimum: 0)
                    RhythmStepper(title: "Breathe out", value: $model.settings.custom.exhale, minimum: 1)
                    RhythmStepper(title: "Hold", value: $model.settings.custom.holdEmpty, minimum: 0)
                }
                .disabled(!model.canEdit)
            }
        }
        .listStyle(.sidebar)
        .disabled(!model.canEdit && model.settings.pattern != .custom)
    }
}

struct PatternRow: View {
    let id: PatternID
    let phases: [Phase]
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: id.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? AnyShapeStyle(.white.opacity(0.22)) : AnyShapeStyle(Theme.accent)))
            VStack(alignment: .leading, spacing: 1) {
                Text(id.name).font(.system(size: 13, weight: .medium))
                Text(Patterns.summary(phases)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct RhythmStepper: View {
    let title: String
    @Binding var value: Double
    let minimum: Double

    var body: some View {
        Stepper(value: $value, in: max(minimum, CustomRhythm.range.lowerBound)...CustomRhythm.range.upperBound, step: 1) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(value)) s").monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .animation(.snappy, value: value)
    }
}

// MARK: - Stage

struct Stage: View {
    @ObservedObject var model: ExhaleModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: model.runState != .running)) { context in
            let now = context.date
            let phases = model.phases
            let elapsed = model.elapsed(at: now)
            let state = Breath.state(at: elapsed, phases: phases)
            let active = model.runState == .running || model.runState == .paused
            GeometryReader { geo in
                let side = min(geo.size.width * 0.62, geo.size.height * 0.56)
                ZStack {
                    background(fullness: active ? state.fullness : 0.3)
                    VStack(spacing: 0) {
                        Spacer(minLength: 64)
                        Bloom(fullness: active ? state.fullness : (model.runState == .finished ? 1 : 0.32),
                              progress: active ? state.phaseElapsed / max(0.001, phases[state.phaseIndex].seconds) : 0,
                              showRing: active)
                            .frame(width: side, height: side)
                        caption(state: state, active: active)
                            .frame(height: 96)
                            .padding(.top, 26)
                        Spacer(minLength: 18)
                    }
                    .frame(maxWidth: .infinity)
                    header(now: now, elapsed: elapsed, state: state, active: active)
                }
            }
        }
        .clipped()
    }

    private func background(fullness: Double) -> some View {
        let dark = scheme == .dark
        let top = dark ? Color(red: 0.11, green: 0.09, blue: 0.20) : Color(red: 0.97, green: 0.96, blue: 1.0)
        let bottom = dark ? Color(red: 0.05, green: 0.04, blue: 0.11) : Color(red: 0.89, green: 0.86, blue: 0.99)
        return ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.light.opacity(dark ? 0.22 : 0.35) .opacity(0.5 + fullness / 2), .clear],
                           center: UnitPoint(x: 0.5, y: 0.42), startRadius: 10, endRadius: 420)
        }
    }

    @ViewBuilder
    private func caption(state: BreathState, active: Bool) -> some View {
        VStack(spacing: 6) {
            switch model.runState {
            case .idle:
                Text("Ready when you are").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Press Space to begin \(model.settings.minutes) \(model.settings.minutes == 1 ? "minute" : "minutes") of \(model.settings.pattern.name.lowercased()).")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            case .finished:
                Text("Session complete").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("\(Breath.clock(model.sessionTotal)) of \(model.sessionPattern.name.lowercased()). Nicely done.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            case .running, .paused:
                Text(model.runState == .paused ? "Paused" : state.kind.label)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .id(model.runState == .paused ? "paused" : state.kind.label)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                Text("\(state.countdown)")
                    .font(.system(size: 46, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(countsDown: true))
                    .opacity(model.runState == .paused ? 0.4 : 1)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: state.kind)
        .animation(.snappy, value: state.countdown)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    private func header(now: Date, elapsed: Double, state: BreathState, active: Bool) -> some View {
        VStack {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(active || model.runState == .finished ? model.sessionPattern.name : model.settings.pattern.name)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(Patterns.summary(model.phases) + " seconds")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Breath.clock(model.remaining(at: now)))
                        .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy, value: Int(model.remaining(at: now).rounded(.up)))
                    Text(active ? breathLine(state) : model.runState == .finished ? "complete" : "planned length")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
    }

    private func breathLine(_ state: BreathState) -> String {
        let total = Int((model.sessionTotal / max(0.001, Breath.cycleLength(model.phases))).rounded())
        return "breath \(min(total, state.cycle + 1)) of \(total)"
    }
}

/// Six translucent petals that bloom outward as the lungs fill, around a soft glowing core.
struct Bloom: View {
    let fullness: Double
    let progress: Double
    let showRing: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let s = fullness
            let petal = d * (0.30 + 0.16 * s)
            let spread = d * (0.03 + 0.18 * s)
            ZStack {
                Circle()
                    .fill(Theme.light.opacity(0.18 + 0.22 * s))
                    .frame(width: d * (0.55 + 0.4 * s), height: d * (0.55 + 0.4 * s))
                    .blur(radius: d * 0.08)
                ForEach(0..<6, id: \.self) { i in
                    Circle()
                        .fill(LinearGradient(colors: [Theme.light.opacity(0.75), Theme.deep.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(.white.opacity(scheme == .dark ? 0.12 : 0.35), lineWidth: 1))
                        .frame(width: petal, height: petal)
                        .offset(y: -spread)
                        .rotationEffect(.degrees(Double(i) * 60 + s * 40))
                        .blendMode(scheme == .dark ? .plusLighter : .normal)
                        .opacity(scheme == .dark ? 0.55 : 0.5)
                }
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0.0)], center: .center, startRadius: 0,
                                         endRadius: d * (0.08 + 0.06 * s)))
                    .frame(width: d * 0.3, height: d * 0.3)
                    .opacity(0.85)
                if showRing {
                    Circle()
                        .stroke(Theme.deep.opacity(0.12), lineWidth: 3)
                        .frame(width: d * 0.98, height: d * 0.98)
                    Circle()
                        .trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: d * 0.98, height: d * 0.98)
                }
            }
            .frame(width: d, height: d)
            .shadow(color: Theme.deep.opacity(0.18 * s), radius: 30, y: 8)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

// MARK: - Controls

struct ControlBar: View {
    @ObservedObject var model: ExhaleModel

    var body: some View {
        HStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                settings(compact: false)
                settings(compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.runState == .running || model.runState == .paused {
                Button("Stop") { model.stop() }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                    .help("End the session (⌘.)")
            }
            Button(primaryTitle) { model.toggle() }
                .buttonStyle(PillButtonStyle(Theme.colors))
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .animation(.snappy, value: model.runState)
    }

    private func settings(compact: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                if !compact { Image(systemName: "timer").foregroundStyle(.secondary) }
                Slider(value: Binding(get: { Double(model.settings.minutes) }, set: { model.settings.minutes = Int($0.rounded()) }),
                       in: Double(Settings.minutesRange.lowerBound)...Double(Settings.minutesRange.upperBound))
                    .frame(width: compact ? 90 : 130)
                Text("\(model.settings.minutes) min")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .frame(width: 46, alignment: .leading)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.settings.minutes)
            }
            .disabled(!model.canEdit)
            .help("Session length, 1 to 20 minutes")

            HStack(spacing: 8) {
                Picker("Sound", selection: $model.settings.sound) {
                    ForEach(SoundStyle.allCases) { Text($0.name).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Sound at each phase change")
                if !compact {
                    Image(systemName: model.settings.sound == .off ? "speaker.slash" : "speaker.wave.2")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Slider(value: $model.settings.volume, in: 0...1)
                        .frame(width: 64)
                        .disabled(model.settings.sound == .off)
                        .help("Volume")
                }
            }
        }
        .fixedSize()
    }

    private var primaryTitle: String {
        switch model.runState {
        case .idle: "Start"
        case .running: "Pause"
        case .paused: "Resume"
        case .finished: "Again"
        }
    }
}

// MARK: - History

struct HistoryPanel: View {
    @ObservedObject var model: ExhaleModel

    var body: some View {
        let now = Date()
        let week = History.week(model.sessions, now: now)
        let total = week.reduce(0) { $0 + $1.minutes }
        let streak = History.streak(model.sessions, now: now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This week").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(total.rounded()))")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                        Text(Int(total.rounded()) == 1 ? "minute" : "minutes").font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if streak > 1 {
                        Label("\(streak) day streak", systemImage: "flame")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }

                Chart(week, id: \.day) { item in
                    BarMark(x: .value("Day", item.day, unit: .day), y: .value("Minutes", item.minutes))
                        .foregroundStyle(Calendar.current.isDateInToday(item.day) ? AnyShapeStyle(Theme.accent)
                                         : AnyShapeStyle(Theme.light.opacity(0.65)))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel()
                    }
                }
                .frame(height: 120)

                Divider().opacity(0.5)

                Text("Recent").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                if model.sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "leaf").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.accent)
                        Text("Sessions you breathe for half a minute or more appear here.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    VStack(spacing: 6) {
                        ForEach(model.sessions.prefix(60)) { session in
                            SessionRow(session: session)
                                .contextMenu {
                                    Button("Delete Session", role: .destructive) { withAnimation(.snappy) { model.delete(session) } }
                                }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct SessionRow: View {
    let session: Session
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: session.pattern.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.deep)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.light.opacity(0.25)))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.pattern.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Self.when(session.date))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Self.duration(session.seconds))
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(session.completed ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0.3)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(session.completed ? "Completed" : "Ended early")
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today, \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    static func duration(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 1 ? "\(Int(seconds)) s" : "\(m) min"
    }
}
