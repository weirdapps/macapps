import AppKit
import Kit
import SwiftUI

/// One document window: the page, and a quiet status line that fades while you type.
struct ContentView: View {
    @Binding var text: String
    var isMarkdown: Bool
    @ObservedObject var prefs: Prefs
    @ObservedObject var session: WritingSession
    var initialCaret = 0
    @State private var typing = false
    @State private var typeTick = 0

    var body: some View {
        let stats = TextStats(text)
        let theme = prefs.theme
        VStack(spacing: 0) {
            WritingEditor(text: $text, style: prefs.style(markdown: isMarkdown), initialCaret: initialCaret) { typeTick &+= 1 }
                .overlay(alignment: .bottom) {
                    // Lines fade out before the status line instead of running into it.
                    LinearGradient(colors: [theme.backgroundColor.opacity(0), theme.backgroundColor], startPoint: .top, endPoint: .bottom)
                        .frame(height: 28)
                        .allowsHitTesting(false)
                }
            StatusBar(stats: stats, session: session, prefs: prefs)
                .opacity(typing ? 0.22 : 1)
                .animation(.easeInOut(duration: 0.5), value: typing)
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .toolbar { EditorToolbar(prefs: prefs) }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { session.update(words: stats.words) }
        .onChange(of: stats.words) { _, words in session.update(words: words) }
        .task(id: typeTick) {
            guard typeTick > 0 else { return }
            typing = true
            try? await Task.sleep(for: .seconds(1.8))
            if !Task.isCancelled { typing = false }
        }
    }
}

struct EditorToolbar: ToolbarContent {
    @ObservedObject var prefs: Prefs

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("Focus", selection: $prefs.focus) {
                    ForEach(FocusMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Focus", systemImage: prefs.focus == .off ? "circle.dashed" : "scope")
            }
            .help("Focus mode: dim everything but the current paragraph or sentence")

            Toggle(isOn: $prefs.typewriter) {
                Label("Typewriter Scrolling", systemImage: "text.line.magnify")
            }
            .help("Typewriter scrolling: keep the current line in the middle of the window")

            Menu {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Theme", systemImage: "circle.lefthalf.filled")
            }
            .help("Theme: Paper, Sepia or Night")
        }
    }
}

// MARK: - Status

struct StatusBar: View {
    let stats: TextStats
    @ObservedObject var session: WritingSession
    @ObservedObject var prefs: Prefs
    @State private var showingGoal = false
    @State private var hovering = false

    var body: some View {
        let ink = prefs.theme.inkColor
        HStack(spacing: 20) {
            item(stats.words, stats.words == 1 ? "word" : "words")
            item(stats.characters, stats.characters == 1 ? "character" : "characters")
            Text(stats.readingLabel)
            Spacer(minLength: 12)
            Button { showingGoal.toggle() } label: {
                HStack(spacing: 8) {
                    GoalRing(progress: WritingSession.progress(written: session.written, goal: prefs.goal), ink: ink)
                    Group {
                        if session.written >= prefs.goal {
                            Text("Goal reached")
                        } else {
                            Text("\(session.written.formatted()) of \(prefs.goal.formatted()) words")
                                .contentTransition(.numericText())
                        }
                    }
                    .animation(.snappy, value: session.written)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(ink.opacity(hovering ? 0.08 : 0)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Words written this session, toward your goal")
            .popover(isPresented: $showingGoal, arrowEdge: .top) { GoalPopover(prefs: prefs, session: session) }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(ink.opacity(0.55))
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .frame(height: 36)
    }

    private func item(_ value: Int, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(value.formatted()).foregroundStyle(prefs.theme.inkColor.opacity(0.8)).contentTransition(.numericText())
            Text(unit)
        }
        .animation(.snappy, value: value)
    }
}

struct GoalRing: View {
    let progress: Double
    let ink: Color

    var body: some View {
        ZStack {
            Circle().stroke(ink.opacity(0.14), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Accent.gradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if progress >= 1 {
                Image(systemName: "checkmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(Accent.deep)
            }
        }
        .frame(width: 15, height: 15)
        .animation(.snappy, value: progress)
    }
}

struct GoalPopover: View {
    @ObservedObject var prefs: Prefs
    @ObservedObject var session: WritingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.written.formatted())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("words this session").foregroundStyle(.secondary)
            }
            ProgressView(value: WritingSession.progress(written: session.written, goal: prefs.goal)).tint(Accent.deep)
            Stepper(value: $prefs.goal, in: Prefs.goals, step: 50) {
                Text("Goal: \(prefs.goal.formatted()) words").monospacedDigit()
            }
            Button("Restart Session") { session.restart() }
        }
        .padding(16)
        .frame(width: 260)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section("Text") {
                Picker("Typeface", selection: $prefs.typeface) {
                    ForEach(Typeface.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledSlider(title: "Size", value: $prefs.size, range: Prefs.sizes, step: 1, label: "\(Int(prefs.size)) pt")
                LabeledSlider(title: "Line height", value: $prefs.lineHeight, range: Prefs.lineHeights, step: 0.1,
                              label: String(format: "%.1f", prefs.lineHeight))
                LabeledSlider(title: "Line width", value: $prefs.measure, range: Prefs.measures, step: 1,
                              label: "\(Int(prefs.measure)) characters")
                Preview(prefs: prefs)
            }
            Section("Writing") {
                Picker("Theme", selection: $prefs.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Focus", selection: $prefs.focus) {
                    ForEach(FocusMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Typewriter scrolling", isOn: $prefs.typewriter)
                Stepper(value: $prefs.goal, in: Prefs.goals, step: 50) {
                    Text("Session goal: \(prefs.goal.formatted()) words").monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step).labelsHidden()
                Text(label).monospacedDigit().foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            }
        }
    }
}

/// A line of sample text in the chosen typeface, size, line height and theme.
private struct Preview: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        let size = CGFloat(prefs.size)
        Text("The first draft of anything is just you telling yourself the story. Keep the pen moving.")
            .font(Font(prefs.typeface.font(size: size) as CTFont))
            .lineSpacing(size * CGFloat(prefs.lineHeight - 1))
            .foregroundStyle(prefs.theme.inkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(prefs.theme.backgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary))
            .animation(.snappy, value: prefs.theme)
    }
}
