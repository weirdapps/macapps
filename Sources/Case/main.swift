import AppKit
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
    let clipboard = Clipboard()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "textformat", accessibilityLabel: "Case") {
            CaseView().environmentObject(self.clipboard)
        }
    }
}

// MARK: - Model

@MainActor
final class Clipboard: ObservableObject {
    @Published private(set) var text: String
    @Published var lastApplied: Style?

    private let pasteboard = NSPasteboard.general
    private var lastChange: Int
    private var timer: Timer?

    init() {
        lastChange = pasteboard.changeCount
        // Published screenshots show demo text, never the real clipboard.
        if CommandLine.arguments.contains("--snapshot") {
            text = "Let's ship the new release before Friday's review."
            return
        }
        text = pasteboard.string(forType: .string) ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard pasteboard.changeCount != lastChange else { return }
        lastChange = pasteboard.changeCount
        text = pasteboard.string(forType: .string) ?? ""
        lastApplied = nil
    }

    func apply(_ style: Style) {
        let converted = style.convert(text)
        pasteboard.clearContents()
        pasteboard.setString(converted, forType: .string)
        lastChange = pasteboard.changeCount
        withAnimation(.snappy) {
            text = converted
            lastApplied = style
        }
        HUD.show(symbol: "textformat", title: style.name, tint: Color.casePalette[1])
    }
}

extension Color {
    static let casePalette = [Color(red: 0.4, green: 0.58, blue: 1), Color(red: 0.18, green: 0.32, blue: 0.84)]
}

// MARK: - Conversions

enum Style: String, CaseIterable, Identifiable {
    case upper, lower, title, sentence, camel, pascal, snake, kebab, constant

    var id: String { rawValue }

    var name: String {
        switch self {
        case .upper: "UPPERCASE"
        case .lower: "lowercase"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        case .camel: "camelCase"
        case .pascal: "PascalCase"
        case .snake: "snake_case"
        case .kebab: "kebab-case"
        case .constant: "CONSTANT_CASE"
        }
    }

    func convert(_ text: String) -> String {
        switch self {
        case .upper: return text.up
        case .lower: return text.low
        case .title: return CaseConverter.title(text)
        case .sentence: return CaseConverter.sentence(text)
        case .camel:
            let w = CaseConverter.words(text).map { $0.low }
            guard let first = w.first else { return "" }
            return first + w.dropFirst().map(CaseConverter.capitalized).joined()
        case .pascal: return CaseConverter.words(text).map { CaseConverter.capitalized($0.low) }.joined()
        case .snake: return CaseConverter.words(text).map { $0.low }.joined(separator: "_")
        case .kebab: return CaseConverter.words(text).map { $0.low }.joined(separator: "-")
        case .constant: return CaseConverter.words(text).map { $0.up }.joined(separator: "_")
        }
    }
}

/// Greek rules for whole-word case mapping: final sigma when lowering, no tonos in capitals.
/// They leave Latin text as the plain mapping would. Capitalising one letter keeps the tonos (Άλφα).
enum Greek {
    // A static, not a main.swift global: those are set only once top-level code reaches them.
    static let locale = Locale(identifier: "el")
}

extension StringProtocol {
    var up: String { uppercased(with: Greek.locale) }
    var low: String { lowercased(with: Greek.locale) }
}

enum CaseConverter {
    /// Words that stay lowercase inside a title, after the Chicago and AP conventions.
    static let smallWords: Set<String> = [
        "a", "an", "the", "and", "but", "or", "nor", "for", "so", "yet", "as", "at", "by", "in", "of", "off",
        "on", "per", "to", "up", "via", "vs", "vs.", "v", "v.", "en", "if", "from", "into", "onto", "with", "over",
    ]

    static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Splits text into words for programming identifiers: on spaces and punctuation, and inside
    /// identifiers at lower-to-upper changes and at the end of an acronym ("HTTPServer" is HTTP, Server).
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let chars = Array(text.replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: ""))
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { result.append(current); current = "" }
                continue
            }
            if let prev = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = (prev.isLowercase || prev.isNumber) && c.isUppercase
                let acronymEnd = prev.isUppercase && c.isUppercase && (next?.isLowercase ?? false)
                if lowerToUpper || acronymEnd {
                    result.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// True when the text has letters and none of them is lowercase.
    static func isShouting(_ text: String) -> Bool {
        text.contains(where: \.isLetter) && !text.contains(where: \.isLowercase)
    }

    /// A word to leave alone: an acronym (NASA) or a mixed-case name (iPhone, McDonald).
    static func isSpecial(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard letters.count > 1 else { return false }
        return letters.dropFirst().contains(where: \.isUppercase)
    }

    static func title(_ text: String) -> String {
        let source = isShouting(text) ? text.low : text
        return source.split(separator: "\n", omittingEmptySubsequences: false).map { titleLine(String($0)) }.joined(separator: "\n")
    }

    private static func titleLine(_ line: String) -> String {
        // Tokens alternate between runs of spaces and words, so spacing is kept exactly.
        var tokens: [String] = []
        for c in line {
            if let last = tokens.last, last.first?.isWhitespace == c.isWhitespace { tokens[tokens.count - 1].append(c) } else { tokens.append(String(c)) }
        }
        let wordIndices = tokens.indices.filter { !(tokens[$0].first?.isWhitespace ?? true) }
        var startsPhrase = true
        for (n, i) in wordIndices.enumerated() {
            let word = tokens[i]
            let isEdge = startsPhrase || n == wordIndices.count - 1
            // In hyphenated compounds the first part follows the word's rule; later parts are capitalised unless small.
            tokens[i] = word.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { part, piece in
                titleWord(String(piece), force: part == 0 ? isEdge : false)
            }.joined(separator: "-")
            startsPhrase = word.last.map { ":.!?".contains($0) } ?? false
        }
        return tokens.joined()
    }

    private static func titleWord(_ word: String, force: Bool) -> String {
        // An all-caps word of five letters or more is shouting, not an acronym like NASA.
        let letters = word.filter(\.isLetter)
        let shouted = letters.count >= 5 && letters.allSatisfy(\.isUppercase)
        if isSpecial(word) && !shouted { return word }
        // Leading punctuation such as quotes or brackets stays in front.
        let prefix = word.prefix { !$0.isLetter && !$0.isNumber }
        let core = String(word.dropFirst(prefix.count))
        let bare = core.low.trimmingCharacters(in: .punctuationCharacters)
        if !force && smallWords.contains(bare) { return prefix + core.low }
        return prefix + capitalized(shouted ? core.low : core)
    }

    static func sentence(_ text: String) -> String {
        let shouting = isShouting(text)
        var output = ""
        var capitalizeNext = true
        var word = ""
        func flush() {
            guard !word.isEmpty else { return }
            var w = word
            // Keep acronyms (NASA) and mixed-case names (iPhone, McDonald's) as written.
            let keep = !shouting && isSpecial(w)
            if !keep {
                w = w.low
                if w == "i" || w.hasPrefix("i'") || w.hasPrefix("i\u{2019}") { w = "I" + w.dropFirst() }
            }
            if capitalizeNext, let idx = w.firstIndex(where: \.isLetter) {
                if !keep { w.replaceSubrange(idx...idx, with: String(w[idx]).uppercased()) }
                capitalizeNext = false
            } else if capitalizeNext && w.contains(where: \.isNumber) {
                capitalizeNext = false
            }
            output += w
            if let last = w.last(where: { !"\"')]\u{201D}\u{2019}".contains($0) }), ".!?".contains(last) { capitalizeNext = true }
            word = ""
        }
        for c in text {
            if c.isWhitespace {
                flush()
                if c.isNewline { capitalizeNext = true }
                output.append(c)
            } else {
                word.append(c)
            }
        }
        flush()
        return output
    }
}

// MARK: - Views

struct CaseView: View {
    @EnvironmentObject var clipboard: Clipboard

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Case").font(.system(size: 17, weight: .bold, design: .rounded))
                    Spacer()
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Group {
                    if clipboard.text.isEmpty {
                        Text("Copy some text, then pick a style below.").foregroundStyle(.secondary)
                    } else {
                        Text(clipboard.text)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 12.5))
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            VStack(spacing: 3) {
                ForEach(Style.allCases) { style in
                    StyleRow(style: style)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
            .disabled(clipboard.text.isEmpty)
            .opacity(clipboard.text.isEmpty ? 0.5 : 1)

            Divider().opacity(0.5)
            PanelFooter(name: "Case") {
                ForEach(Style.allCases) { style in
                    Button("Convert to \(style.name)") { clipboard.apply(style) }
                }
            }
        }
        .frame(width: 360)
    }
}

struct StyleRow: View {
    @EnvironmentObject var clipboard: Clipboard
    let style: Style
    @State private var hovering = false

    var body: some View {
        let applied = clipboard.lastApplied == style
        Button { clipboard.apply(style) } label: {
            HStack(spacing: 10) {
                Text(style.name)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .frame(width: 118, alignment: .leading)
                Text(preview)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: applied ? "checkmark.circle.fill" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 12))
                    .foregroundStyle(applied ? AnyShapeStyle(Color.casePalette[1]) : AnyShapeStyle(.tertiary))
                    .opacity(hovering || applied ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(applied ? AnyShapeStyle(Color.casePalette[0].opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.5 : 0.22))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Rewrite the clipboard as \(style.name)")
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var preview: String {
        let sample = String(clipboard.text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        return sample.isEmpty ? style.convert("the quick brown fox") : style.convert(sample)
    }
}

// MARK: - Icon

//: a capital A and a small single-storey a, side by side

func appIcon() -> NSBitmapImageRep {
    render(0xF4F6FA, 0xAEB8CB) { ctx in
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Capital A.
        ctx.saveGState()
        shadow(ctx, y: -12, blur: 24, alpha: 0.22)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setStrokeColor(rgb(0x2B3245).cgColor)
        ctx.setLineWidth(86)
        ctx.move(to: CGPoint(x: 220, y: 290))
        ctx.addLine(to: CGPoint(x: 372, y: 720))
        ctx.addLine(to: CGPoint(x: 524, y: 290))
        ctx.strokePath()
        ctx.setLineWidth(64)
        ctx.move(to: CGPoint(x: 282, y: 430)); ctx.addLine(to: CGPoint(x: 462, y: 430))
        ctx.strokePath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Small a, as a bowl and a stem, in the accent gradient.
        ctx.saveGState()
        shadow(ctx, y: -12, blur: 24, alpha: 0.25)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(62)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.strokeEllipse(in: CGRect(x: 596, y: 300, width: 180, height: 220))
        ctx.move(to: CGPoint(x: 806, y: 300)); ctx.addLine(to: CGPoint(x: 806, y: 520))
        ctx.strokePath()
        ctx.setBlendMode(.sourceIn)
        gradient([rgb(0x6A93FF), rgb(0x2547D0)], from: CGPoint(x: 0, y: 600), to: CGPoint(x: 0, y: 260), in: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
