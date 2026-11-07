import AppKit
import Charts
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 1, green: 0x6F / 255, blue: 0xA5 / 255)
    static let bottom = Color(red: 0xD6 / 255, green: 0x33 / 255, blue: 0x84 / 255)
    static let accent = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let error = Color(nsColor: .systemOrange)
    static let card = Color(nsColor: .controlBackgroundColor)

    static let fontSize: CGFloat = 25
    static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    static let font = Font(nsFont)
    static let charWidth = ("M" as NSString).size(withAttributes: [.font: nsFont]).width
    static let lineHeight: CGFloat = 44
    static let visibleLines = 3
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

// MARK: - Window

struct ContentView: View {
    @ObservedObject var model: TypistModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 16) {
            StatsStrip(model: model)
            Card { if model.phase == .finished, let result = model.lastResult { ResultView(model: model, result: result) } else { TypingView(model: model) } }
                .frame(height: 216)
            HStack(spacing: 16) {
                Card { HeatmapView(stats: model.keyStats) }
                Card { HistoryView(history: model.history) }
                    .frame(width: 370)
            }
            .frame(minHeight: 240)
        }
        .padding(20)
        .frame(minWidth: 880, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { Toolbar(model: model) }
        .onAppear { if !Desktop.isSnapshot { model.startListening() } }
        .confirmationDialog("Clear all \(model.history.count) results?", isPresented: $model.confirmingClear) {
            Button("Clear History", role: .destructive) { model.clearHistory(undoManager: undoManager) }
        } message: {
            Text("Your chart and key heatmap start over. You can undo this with Edit > Undo.")
        }
        .fileExporter(isPresented: $model.exporting, document: CSVDocument(text: CSV.history(model.history)),
                      contentType: .commaSeparatedText, defaultFilename: "Typist History") { result in
            if case .success(let url) = result { revealInFinder([url]) }
        }
    }
}

struct Toolbar: ToolbarContent {
    @ObservedObject var model: TypistModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("Test", selection: $model.config.mode) {
                ForEach(TestMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Timed test, a set number of words, or a quote")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.config.mode {
            case .time:
                Picker("Length", selection: $model.config.seconds) {
                    ForEach(TestConfig.secondOptions, id: \.self) { Text("\($0) s").tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Test length in seconds")
            case .words:
                Picker("Length", selection: $model.config.wordCount) {
                    ForEach(TestConfig.wordOptions, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Test length in words")
            case .quote:
                EmptyView()
            }
            Toggle(isOn: $model.config.punctuation) { Label("Punctuation", systemImage: "textformat") }
                .help("Add capitals and punctuation")
                .disabled(model.config.mode == .quote)
            Toggle(isOn: $model.config.numbers) { Label("Numbers", systemImage: "number") }
                .help("Mix numbers in")
                .disabled(model.config.mode == .quote)
            Button { model.newTest() } label: { Label("New Test", systemImage: "arrow.clockwise") }
                .help("New test (Esc)")
        }
    }
}

// MARK: - Live numbers

struct StatsStrip: View {
    @ObservedObject var model: TypistModel

    var body: some View {
        let started = model.phase != .ready
        HStack(spacing: 12) {
            StatTile(title: "Net speed", value: started ? "\(Int(model.liveNet.rounded()))" : "0", unit: "wpm", highlight: true)
            StatTile(title: "Accuracy", value: started ? String(format: "%.1f", model.liveAccuracy) : "100", unit: "%")
            StatTile(title: "Raw speed", value: started ? "\(Int(model.liveRaw.rounded()))" : "0", unit: "wpm")
            switch model.config.mode {
            case .time: StatTile(title: "Time left", value: "\(model.secondsLeft)", unit: "s")
            default: StatTile(title: "Words", value: "\(model.session.wordsDone)", unit: "of \(model.session.totalWords)")
            }
        }
        .frame(height: 74)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(highlight ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary))
                Text(unit).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlight ? AnyShapeStyle(Theme.top.opacity(0.1)) : AnyShapeStyle(Theme.card))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlight ? AnyShapeStyle(Theme.top.opacity(0.35)) : AnyShapeStyle(.separator.opacity(0.6)), lineWidth: 0.5)
        }
        .animation(.snappy, value: value)
    }
}

// MARK: - Typing

struct TypingView: View {
    @ObservedObject var model: TypistModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                let columns = max(12, Int(geo.size.width / Theme.charWidth))
                PassageView(session: model.session, columns: columns, blinking: model.phase == .ready && !Desktop.isSnapshot)
            }
            .frame(height: Theme.lineHeight * CGFloat(Theme.visibleLines))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: model.config.mode == .quote ? "quote.opening" : model.config.mode == .time ? "timer" : "text.word.spacing")
                    .foregroundStyle(Theme.accent)
                Text(model.author ?? ([model.config.label, "common words"] + model.config.extras).joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.phase == .ready {
                    Text("Start typing to begin").foregroundStyle(.secondary)
                } else {
                    KeyCap("esc")
                    Text("new test").foregroundStyle(.secondary)
                    KeyCap("⌘R").padding(.leading, 6)
                    Text("restart").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }
}

/// Three lines of the passage around the caret: typed characters in the primary colour, mistakes highlighted,
/// the rest dimmed, with a caret that glides along.
struct PassageView: View {
    let session: TypingSession
    let columns: Int
    let blinking: Bool

    var body: some View {
        let lines = Wrap.lines(session.target, columns: columns)
        let caret = session.typed.count
        let caretLine = Wrap.line(of: caret, in: lines)
        let first = max(0, min(caretLine - 1, lines.count - Theme.visibleLines))
        let visible = Array(first..<min(lines.count, first + Theme.visibleLines))
        let column = caret - lines[caretLine].lowerBound
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(visible, id: \.self) { i in
                    Text(attributed(lines[i]))
                        .font(Theme.font)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: Theme.lineHeight, alignment: .leading)
                }
            }
            Caret(blinking: blinking)
                .offset(x: CGFloat(column) * Theme.charWidth - 1, y: CGFloat(caretLine - first) * Theme.lineHeight + 7)
                .animation(.easeOut(duration: 0.09), value: caret)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func attributed(_ range: Range<Int>) -> AttributedString {
        var out = AttributedString()
        for i in range {
            let expected = session.target[i]
            var piece: AttributedString
            if i < session.typed.count {
                if session.typed[i] == expected {
                    piece = AttributedString(String(expected))
                    piece.foregroundColor = .primary
                } else {
                    piece = AttributedString(expected == " " ? "·" : String(expected))
                    piece.foregroundColor = Theme.error
                    piece.backgroundColor = Theme.error.opacity(0.16)
                }
            } else {
                piece = AttributedString(String(expected))
                piece.foregroundColor = Color(nsColor: .tertiaryLabelColor)
            }
            out += piece
        }
        return out
    }
}

struct Caret: View {
    let blinking: Bool

    var body: some View {
        if blinking {
            TimelineView(.periodic(from: .now, by: 0.55)) { context in
                bar.opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0 ? 1 : 0.15)
            }
        } else {
            bar
        }
    }

    private var bar: some View {
        Capsule().fill(Theme.accent).frame(width: 2.5, height: Theme.lineHeight - 14)
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var model: TypistModel
    let result: TestResult

    var body: some View {
        HStack(alignment: .top, spacing: 26) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Net speed").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(result.netWPM.rounded()))")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    Text("wpm").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    metric("Accuracy", String(format: "%.1f%%", result.accuracy))
                    metric("Raw", "\(Int(result.rawWPM.rounded())) wpm")
                    metric("Characters", "\(result.characters - result.errors) right, \(result.errors) wrong")
                    metric("Time", String(format: "%.1f s", result.seconds))
                }
                .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .frame(width: 250, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    legend("Net", Theme.bottom)
                    legend("Raw", .secondary.opacity(0.5))
                    HStack(spacing: 4) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(Theme.error)
                        Text("Mistakes")
                    }
                    Spacer()
                    Text("Press")
                    KeyCap("return")
                    Text("or")
                    Button("Next Test") { model.newTest() }
                        .buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
                        .focusEffectDisabled()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                Chart(model.samples) { s in
                    LineMark(x: .value("Second", s.second), y: .value("Raw", s.raw), series: .value("Series", "Raw"))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Second", s.second), y: .value("WPM", s.wpm), series: .value("Series", "Net"))
                        .foregroundStyle(Theme.bottom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    if s.errors > 0 {
                        PointMark(x: .value("Second", s.second), y: .value("WPM", s.wpm))
                            .symbol(.cross)
                            .symbolSize(40)
                            .foregroundStyle(Theme.error)
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Int.self) { Text("\(v) s") } }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(title)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}

// MARK: - Heatmap

struct HeatmapView: View {
    let stats: [String: (hits: Int, errors: Int)]

    private static let rows: [[(String, CGFloat)]] = [
        "`1234567890-=".map { (String($0), 1) } + [("delete", 1.5)],
        [("tab", 1.5)] + "qwertyuiop[]\\".map { (String($0), 1) },
        [("caps", 1.8)] + "asdfghjkl;'".map { (String($0), 1) } + [("return", 1.7)],
        [("shift", 2.3)] + "zxcvbnm,./".map { (String($0), 1) } + [("shift", 2.2)],
    ]
    private static let modifiers: Set<String> = ["delete", "tab", "caps", "return", "shift"]

    private func rate(_ key: String) -> Double? {
        guard let s = stats[key], s.hits > 0 else { return nil }
        return Double(s.errors) / Double(s.hits)
    }

    /// Error rates are scaled to the worst key, so the map always shows where the trouble is.
    private var worst: Double { max(0.02, stats.keys.compactMap { rate($0) }.max() ?? 0) }

    private var trouble: [(String, Double)] {
        stats.keys.compactMap { k in rate(k).map { (k, $0) } }.filter { $0.1 > 0 && (stats[$0.0]?.hits ?? 0) >= 5 }
            .sorted { $0.1 > $1.1 }.prefix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Missed keys").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if trouble.isEmpty {
                    Text("No misses yet").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Text("Most missed").font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(trouble, id: \.0) { key, r in
                        HStack(spacing: 4) {
                            Text(key == "space" ? "space" : key.uppercased()).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            Text("\(Int((r * 100).rounded()))%").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.top.opacity(0.14)))
                    }
                }
            }
            GeometryReader { geo in
                let gap: CGFloat = 4
                let unit = (geo.size.width - gap * 13) / 14.5
                let height = max(14, min(unit * 1.25, (geo.size.height - gap * 4) / 5))
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(Self.rows.indices, id: \.self) { r in
                        HStack(spacing: gap) {
                            ForEach(Self.rows[r].indices, id: \.self) { i in
                                let (key, width) = Self.rows[r][i]
                                keyCap(key, width: unit * width + gap * (width - 1), height: height)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        keyCap("space", width: unit * 6 + gap * 5, height: height)
                        Spacer()
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Fewer misses")
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [Theme.top.opacity(0.08), Theme.bottom], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 90, height: 7)
                Text("More")
                Spacer()
                Text("Last 50 tests")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func keyCap(_ key: String, width: CGFloat, height: CGFloat) -> some View {
        let isModifier = Self.modifiers.contains(key)
        let r = isModifier ? nil : rate(key)
        let level = r.map { min(1, $0 / worst) } ?? 0
        let s = stats[key]
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(r == nil ? AnyShapeStyle(.quaternary.opacity(isModifier ? 0.35 : 0.6))
                : AnyShapeStyle(Theme.bottom.opacity(0.08 + 0.86 * level)))
            .overlay {
                Text(key == "space" ? "" : isModifier ? key : key.uppercased())
                    .font(.system(size: isModifier ? 9 : 11.5, weight: .medium, design: isModifier ? .default : .rounded))
                    .foregroundStyle(level > 0.55 ? AnyShapeStyle(.white) : AnyShapeStyle(isModifier ? .tertiary : .secondary))
            }
            .frame(width: width, height: height)
            .help(s.map { "\($0.errors) misses in \($0.hits) presses" } ?? "Not typed yet")
    }
}

// MARK: - History

struct HistoryView: View {
    let history: [TestResult]

    var body: some View {
        let recent = Array(history.suffix(30).enumerated())
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Progress").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                if !history.isEmpty {
                    summary("Best", history.map(\.netWPM).max() ?? 0)
                    summary("Average", history.suffix(10).map(\.netWPM).reduce(0, +) / Double(min(10, history.count)))
                    Text("\(history.count) tests").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if history.isEmpty {
                ContentUnavailableView("No tests yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Finish a test and your speed shows up here."))
            } else {
                let values = recent.map(\.element.netWPM)
                let average = values.reduce(0, +) / Double(values.count)
                let low = max(0, ((values.min() ?? 0) - 8) / 10).rounded(.down) * 10
                let high = (((values.max() ?? 0) + 8) / 10).rounded(.up) * 10
                Chart {
                    ForEach(recent, id: \.element.id) { i, r in
                        AreaMark(x: .value("Test", i), yStart: .value("Low", low), yEnd: .value("WPM", r.netWPM))
                            .foregroundStyle(LinearGradient(colors: [Theme.top.opacity(0.32), Theme.top.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                        LineMark(x: .value("Test", i), y: .value("WPM", r.netWPM))
                            .foregroundStyle(Theme.bottom)
                            .lineStyle(StrokeStyle(lineWidth: 2.2))
                            .interpolationMethod(.catmullRom)
                        PointMark(x: .value("Test", i), y: .value("WPM", r.netWPM))
                            .foregroundStyle(Theme.bottom)
                            .symbolSize(18)
                    }
                    RuleMark(y: .value("Average", average))
                        .foregroundStyle(Color.gray.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartXAxis(.hidden)
                .chartYScale(domain: low...high)
                .chartYAxisLabel("wpm")
                Text((recent.count < history.count ? "Last \(recent.count) tests" : "All tests") + ", dashed line is the average")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text("\(Int(value.rounded()))").fontWeight(.semibold).monospacedDigit()
        }
        .font(.system(size: 12))
        .padding(.trailing, 6)
    }
}
