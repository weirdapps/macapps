import AppKit
import Kit
import NaturalLanguage
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
    let clipboard = ClipboardStats()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "ruler", accessibilityLabel: "Measure") {
            MeasureView().environmentObject(self.clipboard)
        }
    }
}

// MARK: - Statistics

struct TextStats: Equatable {
    var words = 0
    var characters = 0
    var charactersNoSpaces = 0
    var sentences = 0
    var paragraphs = 0
    var lines = 0
    var topWords: [(word: String, count: Int)] = []

    static let readingWPM = 238.0
    static let speakingWPM = 150.0

    var readingSeconds: Double { Double(words) / TextStats.readingWPM * 60 }
    var speakingSeconds: Double { Double(words) / TextStats.speakingWPM * 60 }

    static func == (a: TextStats, b: TextStats) -> Bool {
        a.words == b.words && a.characters == b.characters && a.sentences == b.sentences && a.paragraphs == b.paragraphs
            && a.lines == b.lines && a.topWords.map(\.word) == b.topWords.map(\.word)
    }

    /// Words that say little about a text, left out of the frequency list.
    static let stopWords: Set<String> = Set("""
    the and for are but not you all any can had her was one our out has him his how its may new now old see two way who \
    did get let put say she too use that with have this will your from they know want been good much some time very when \
    come here just like long make many more only over such take than them well were what into also then there their these \
    those would could should about after again being below between both down during each few further once other same so \
    than through under until while where which whom why yours yourself themselves ourselves itself himself herself does \
    doing because before above against off own very just don isn aren wasn weren hasn haven hadn won wouldn shouldn
    """.split(whereSeparator: \.isWhitespace).map(String.init))

    init() {}

    init(_ text: String) {
        characters = text.count
        charactersNoSpaces = text.filter { !$0.isWhitespace }.count
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var counts: [String: Int] = [:]
        let wordTokenizer = NLTokenizer(unit: .word)
        wordTokenizer.string = text
        wordTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            words += 1
            let w = text[range].lowercased()
            if w.count >= 3, !TextStats.stopWords.contains(w), w.contains(where: \.isLetter) { counts[w, default: 0] += 1 }
            return true
        }
        topWords = counts.filter { $0.value > 1 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map { ($0.key, $0.value) }

        // Greek ends a question with ";" (or U+037E), which the tokenizer does not read as a sentence end.
        let greek = NLLanguageRecognizer.dominantLanguage(for: text) == .greek
        let sentenceText = greek
            ? text.replacingOccurrences(of: ";", with: "?").replacingOccurrences(of: "\u{037E}", with: "?")
            : text
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        sentenceTokenizer.string = sentenceText
        sentenceTokenizer.enumerateTokens(in: sentenceText.startIndex..<sentenceText.endIndex) { range, _ in
            if sentenceText[range].contains(where: { $0.isLetter || $0.isNumber }) { sentences += 1 }
            return true
        }

        let allLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        lines = allLines.count - (allLines.last?.isEmpty == true ? 1 : 0)
        // A paragraph is a run of non-blank lines.
        var inParagraph = false
        for line in allLines {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank && !inParagraph { paragraphs += 1 }
            inParagraph = !blank
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "0 sec" }
        if seconds < 59.5 { return "\(Int(seconds.rounded())) sec" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

// MARK: - Model

@MainActor
final class ClipboardStats: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var stats = TextStats()
    @Published private(set) var updated = Date()

    private let pasteboard = NSPasteboard.general
    private var lastChange = -1
    private var timer: Timer?

    /// Shown by `--snapshot` instead of the clipboard, which may hold anything.
    static let demoText = """
    The best tools disappear into the work. You reach for them without thinking, they do one job well, and then they get out of the way.

    A menu bar app earns its place by being there the moment you need it. Copy a paragraph, glance up, and the numbers are already waiting.
    """

    init() {
        if StatusPopover.isSnapshot {
            text = ClipboardStats.demoText
            stats = TextStats(ClipboardStats.demoText)
            return
        }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        // Passwords from a password manager are marked concealed; never show or measure them.
        if pasteboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        let new = pasteboard.string(forType: .string) ?? ""
        let stamp = lastChange
        // Very large clipboards are measured off the main thread.
        Task.detached(priority: .userInitiated) {
            let stats = TextStats(new)
            await MainActor.run {
                // A newer clipboard may have finished first; keep the newest.
                guard stamp == self.lastChange else { return }
                withAnimation(.snappy) {
                    self.text = new
                    self.stats = stats
                    self.updated = Date()
                }
            }
        }
    }

    func copySummary() {
        let s = stats
        let summary = """
        Words: \(s.words)
        Characters: \(s.characters) (\(s.charactersNoSpaces) without spaces)
        Sentences: \(s.sentences)
        Paragraphs: \(s.paragraphs)
        Lines: \(s.lines)
        Reading time: \(TextStats.duration(s.readingSeconds))
        Speaking time: \(TextStats.duration(s.speakingSeconds))
        """
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        // Keep measuring the user's text, not the summary we just wrote.
        lastChange = pasteboard.changeCount
        HUD.show(symbol: "ruler.fill", title: "Copied", tint: Color.measure[1])
    }
}

extension Color {
    static let measure = [Color(red: 0.55, green: 0.65, blue: 1), Color(red: 0.24, green: 0.3, blue: 0.82)]
}

// MARK: - Views

struct MeasureView: View {
    @EnvironmentObject var clipboard: ClipboardStats

    var body: some View {
        VStack(spacing: 0) {
            if clipboard.stats.words == 0 && clipboard.stats.characters == 0 {
                VStack(spacing: 8) {
                    Image(systemName: "ruler").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Copy some text and its word count,\nreading time and more will show up here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else {
                content
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Measure") {
                Button("Copy Summary") { clipboard.copySummary() }
            }
        }
        .frame(width: 340)
    }

    private var content: some View {
        let s = clipboard.stats
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(s.words.formatted())
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: Color.measure, startPoint: .top, endPoint: .bottom))
                        .contentTransition(.numericText(value: Double(s.words)))
                        .monospacedDigit()
                    Text(s.words == 1 ? "word on the clipboard" : "words on the clipboard")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                GlassIconButton("doc.on.doc", help: "Copy a summary") { clipboard.copySummary() }
            }

            Text(clipboard.text.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.35)))

            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Tile(value: s.characters, label: "characters")
                    Tile(value: s.charactersNoSpaces, label: "without spaces")
                    Tile(value: s.sentences, label: s.sentences == 1 ? "sentence" : "sentences")
                }
                GridRow {
                    Tile(value: s.paragraphs, label: s.paragraphs == 1 ? "paragraph" : "paragraphs")
                    Tile(value: s.lines, label: s.lines == 1 ? "line" : "lines")
                    Tile(value: s.sentences > 0 ? Int((Double(s.words) / Double(s.sentences)).rounded()) : 0, label: "words a sentence")
                }
            }

            HStack(spacing: 6) {
                TimeTile(symbol: "book", value: TextStats.duration(s.readingSeconds), label: "reading")
                TimeTile(symbol: "waveform", value: TextStats.duration(s.speakingSeconds), label: "speaking")
            }

            if !s.topWords.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Most frequent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    let top = s.topWords.first?.count ?? 1
                    ForEach(s.topWords, id: \.word) { item in
                        HStack(spacing: 8) {
                            Text(item.word).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(width: 96, alignment: .leading)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(LinearGradient(colors: Color.measure, startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * CGFloat(item.count) / CGFloat(top)))
                            }
                            .frame(height: 7)
                            Text("\(item.count)").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding(14)
    }
}

struct Tile: View {
    let value: Int
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(value.formatted())
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

struct TimeTile: View {
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.measure[1])
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.measure[0].opacity(0.15)))
    }
}

// MARK: - Icon

//: a page of text with a ruler laid across it

func appIcon() -> NSBitmapImageRep {
    render(0x9DB2FF, 0x3346C9) { ctx in
        // The page.
        let page = CGRect(x: 270, y: 210, width: 440, height: 560)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 32, alpha: 0.3)
        ctx.addPath(roundedRect(page, 40))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setLineCap(.round)
        ctx.setLineWidth(22)
        ctx.setStrokeColor(rgb(0xC5CEEF).cgColor)
        for (i, w) in [300.0, 340, 250, 330, 280, 180].enumerated() {
            let y = page.maxY - 80 - CGFloat(i) * 76
            ctx.move(to: CGPoint(x: page.minX + 50, y: y)); ctx.addLine(to: CGPoint(x: page.minX + 50 + w, y: y))
        }
        ctx.strokePath()

        // The ruler, laid diagonally.
        ctx.saveGState()
        ctx.translateBy(x: 560, y: 420)
        ctx.rotate(by: 32 * .pi / 180)
        let ruler = CGRect(x: -330, y: -66, width: 660, height: 132)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 28, alpha: 0.35)
        ctx.addPath(roundedRect(ruler, 22))
        ctx.setFillColor(rgb(0xFFC93C).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(ruler, 22))
        ctx.clip()
        gradient([rgb(0xFFE07A), rgb(0xF5A623)], from: CGPoint(x: 0, y: ruler.maxY), to: CGPoint(x: 0, y: ruler.minY), in: ctx)
        ctx.restoreGState()
        // Ticks along the top edge: long every fifth.
        ctx.setStrokeColor(rgb(0x7A4E00, 0.75).cgColor)
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        for i in 0...24 {
            let x = ruler.minX + 42 + CGFloat(i) * 24.5
            let len: CGFloat = i % 5 == 0 ? 58 : 30
            ctx.move(to: CGPoint(x: x, y: ruler.maxY - 16)); ctx.addLine(to: CGPoint(x: x, y: ruler.maxY - 16 - len))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
