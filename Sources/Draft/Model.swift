import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// A plain text or Markdown file. Draft never adds anything to the text it saves.
struct DraftDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }
    static var writableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String
    /// Markdown files get light styling (headings, emphasis, quotes); plain text stays plain.
    var isMarkdown: Bool

    init(text: String = "", isMarkdown: Bool = true) {
        self.text = text
        self.isMarkdown = isMarkdown
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        text = Self.decode(data)
        isMarkdown = configuration.contentType.conforms(to: .markdownText)
            || ["md", "markdown", "mdown", "mkd"].contains((configuration.file.filename as NSString?)?.pathExtension.lowercased() ?? "")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Self.encode(text))
    }

    /// UTF-8 first (with or without a byte order mark), then UTF-16 with a mark, then Windows Latin 1.
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func encode(_ text: String) -> Data { Data(text.utf8) }
}

// MARK: - Stats

struct TextStats: Equatable {
    var words: Int
    var characters: Int

    init(_ text: String) {
        words = Self.countWords(text)
        characters = text.count
    }

    /// Minutes at an unhurried 238 words a minute, never less than one once there is a word.
    var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 238).rounded(.up))) }

    var readingLabel: String { words == 0 ? "No reading time" : "\(readingMinutes) min read" }

    /// A word is a run of letters, digits or marks, which may contain an apostrophe or hyphen between letters
    /// ("don't", "well-known" count once). Markdown symbols and punctuation never count.
    static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        var pendingJoiner = false
        for scalar in text.unicodeScalars {
            let p = scalar.properties
            if p.isAlphabetic || p.numericType != nil || p.generalCategory == .nonspacingMark {
                if !inWord { count += 1 }
                inWord = true
                pendingJoiner = false
            } else if inWord, !pendingJoiner, "'’-‐".unicodeScalars.contains(scalar) {
                pendingJoiner = true
            } else {
                inWord = false
                pendingJoiner = false
            }
        }
        return count
    }
}

/// Words written since the window opened (or since Restart Session), against the goal.
@MainActor
final class WritingSession: ObservableObject {
    @Published private(set) var baseline: Int?
    @Published private(set) var words = 0

    init(baseline: Int? = nil) { self.baseline = baseline }

    var written: Int { max(0, words - (baseline ?? words)) }

    func update(words: Int) {
        if baseline == nil { baseline = words }
        // Deleting below where the session began moves the start down, so the count never goes negative.
        if let b = baseline, words < b { baseline = words }
        self.words = words
    }

    func restart() { baseline = words }

    static func progress(written: Int, goal: Int) -> Double {
        goal <= 0 ? 0 : min(1, Double(written) / Double(goal))
    }
}

// MARK: - Focus

enum FocusMode: String, CaseIterable, Identifiable {
    case off, paragraph, sentence
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .paragraph: "Paragraph"
        case .sentence: "Sentence"
        }
    }
}

enum FocusRange {
    /// The range kept at full strength: the paragraph or sentence that holds the caret.
    static func range(in text: NSString, caret: Int, mode: FocusMode) -> NSRange {
        let length = text.length
        guard mode != .off, length > 0 else { return NSRange(location: 0, length: length) }
        let at = min(max(0, caret), length)
        // A caret right after a paragraph's last character belongs to that paragraph.
        let probe = at == length || (at > 0 && isNewline(text.character(at: at)) && !isNewline(text.character(at: at - 1))) ? max(0, at - 1) : at
        var paragraph = text.paragraphRange(for: NSRange(location: probe, length: 0))
        // Drop the trailing newline so a blank following line stays dim.
        while paragraph.length > 0, isNewline(text.character(at: NSMaxRange(paragraph) - 1)) { paragraph.length -= 1 }
        guard mode == .sentence, paragraph.length > 0 else { return paragraph }
        var found: NSRange?
        var last = paragraph
        text.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, range, enclosing, stop in
            last = range
            if at >= enclosing.location && at < NSMaxRange(enclosing) || at == NSMaxRange(range) {
                found = range
                stop.pointee = true
            }
        }
        return found ?? last
    }

    private static func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2029 || c == 0x2028 }
}

// MARK: - Markdown

/// The few Markdown cues Draft draws: heading lines, strong and emphasised text, quotes and the marks themselves.
enum MarkdownSpan: Equatable {
    case heading(NSRange)
    case strong(NSRange)
    case emphasis(NSRange)
    case quote(NSRange)
    case marker(NSRange)
}

enum Markdown {
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+\\S.*$", options: .anchorsMatchLines)
    private static let quote = try! NSRegularExpression(pattern: "^(>[ \\t]?).*$", options: .anchorsMatchLines)
    private static let list = try! NSRegularExpression(pattern: "^[ \\t]*([-*+]|\\d+[.)])[ \\t]+", options: .anchorsMatchLines)
    private static let strong = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let emphasis = try! NSRegularExpression(pattern: "(?<![*_\\w])([*_])(?=[^\\s*_])(.+?)(?<=[^\\s*_])\\1(?![*_\\w])")

    static func spans(in text: NSString, range: NSRange) -> [MarkdownSpan] {
        var spans: [MarkdownSpan] = []
        let s = text as String
        for m in heading.matches(in: s, range: range) {
            spans.append(.heading(m.range))
            spans.append(.marker(m.range(at: 1)))
        }
        for m in quote.matches(in: s, range: range) {
            spans.append(.quote(m.range))
            spans.append(.marker(m.range(at: 1)))
        }
        for m in list.matches(in: s, range: range) { spans.append(.marker(m.range(at: 1))) }
        for m in strong.matches(in: s, range: range) {
            spans.append(.strong(m.range))
            let mark = m.range(at: 1).length
            spans.append(.marker(NSRange(location: m.range.location, length: mark)))
            spans.append(.marker(NSRange(location: NSMaxRange(m.range) - mark, length: mark)))
        }
        for m in emphasis.matches(in: s, range: range) {
            spans.append(.emphasis(m.range))
            spans.append(.marker(NSRange(location: m.range.location, length: 1)))
            spans.append(.marker(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
        return spans
    }
}

// MARK: - Appearance

enum Typeface: String, CaseIterable, Identifiable {
    case serif, sans, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans"
        case .mono: "Mono"
        }
    }

    func font(size: CGFloat) -> NSFont {
        switch self {
        case .mono: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sans: return .systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            guard let d = base.fontDescriptor.withDesign(.serif) else { return NSFont(name: "Georgia", size: size) ?? base }
            return NSFont(descriptor: d, size: size) ?? base
        }
    }

    var swiftUIDesign: Font.Design {
        switch self {
        case .serif: .serif
        case .sans: .default
        case .mono: .monospaced
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case paper, sepia, night
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var background: UInt32 {
        switch self {
        case .paper: 0xFCFBF8
        case .sepia: 0xF4EAD5
        case .night: 0x1D1C1A
        }
    }

    var ink: UInt32 {
        switch self {
        case .paper: 0x26241F
        case .sepia: 0x4B3B29
        case .night: 0xDCD6C8
        }
    }

    var caret: UInt32 { self == .night ? 0xE2B566 : 0xB27B26 }

    var selection: UInt32 {
        switch self {
        case .paper: 0xEEE1C2
        case .sepia: 0xE2CC9C
        case .night: 0x4D4230
        }
    }

    var isDark: Bool { self == .night }
    var backgroundColor: Color { Color(nsColor: rgb(background)) }
    var inkColor: Color { Color(nsColor: rgb(ink)) }
    /// Text outside the focused paragraph or sentence.
    var dimmed: NSColor { rgb(ink, isDark ? 0.3 : 0.26) }
    /// Markdown marks, quotes.
    var faint: NSColor { rgb(ink, 0.45) }
}

/// The accent gradient shared with the icon: cream paper into warm ochre, with dark ink.
enum Accent {
    static let light = Color(nsColor: rgb(0xD9B77A))
    static let deep = Color(nsColor: rgb(0xA87A38))
    static let ink = Color(nsColor: rgb(0x2A2118))
    static var gradient: LinearGradient { LinearGradient(colors: [light, deep], startPoint: .top, endPoint: .bottom) }
}

/// Everything the editor needs to draw, as one value so a change is cheap to detect.
struct EditorStyle: Equatable {
    var typeface: Typeface
    var size: CGFloat
    var lineHeight: CGFloat
    /// Column width in average characters.
    var measure: Int
    var theme: Theme
    var focus: FocusMode
    var typewriter: Bool
    var markdown: Bool

    var font: NSFont { typeface.font(size: size) }

    /// The column's width in points for this font: `measure` average lowercase characters.
    var columnWidth: CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz " as NSString
        let width = sample.size(withAttributes: [.font: font]).width / CGFloat(sample.length)
        return (width * CGFloat(measure)).rounded()
    }

    /// Side inset that centres the column, never tighter than a comfortable margin.
    static func horizontalInset(viewWidth: CGFloat, column: CGFloat, minimum: CGFloat = 32) -> CGFloat {
        max(minimum, ((viewWidth - column) / 2).rounded(.down))
    }
}

// MARK: - Preferences

/// Settings shared by every window. In a snapshot nothing is read from or written to the user's defaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs(store: Desktop.isSnapshot ? nil : .standard)

    static let sizes: ClosedRange<Double> = 12...32
    static let lineHeights: ClosedRange<Double> = 1.2...2.2
    static let measures: ClosedRange<Double> = 45...100
    static let goals: ClosedRange<Int> = 50...20000

    private let store: UserDefaults?

    @Published var typeface: Typeface { didSet { store?.set(typeface.rawValue, forKey: "typeface") } }
    @Published var size: Double { didSet { store?.set(size, forKey: "size") } }
    @Published var lineHeight: Double { didSet { store?.set(lineHeight, forKey: "lineHeight") } }
    @Published var measure: Double { didSet { store?.set(measure, forKey: "measure") } }
    @Published var theme: Theme { didSet { store?.set(theme.rawValue, forKey: "theme") } }
    @Published var focus: FocusMode { didSet { store?.set(focus.rawValue, forKey: "focus") } }
    @Published var typewriter: Bool { didSet { store?.set(typewriter, forKey: "typewriter") } }
    @Published var goal: Int { didSet { store?.set(goal, forKey: "goal") } }

    init(store: UserDefaults?) {
        self.store = store
        typeface = store?.string(forKey: "typeface").flatMap(Typeface.init) ?? .serif
        size = store?.object(forKey: "size") as? Double ?? 18
        lineHeight = store?.object(forKey: "lineHeight") as? Double ?? 1.5
        measure = store?.object(forKey: "measure") as? Double ?? 66
        theme = store?.string(forKey: "theme").flatMap(Theme.init) ?? .paper
        focus = store?.string(forKey: "focus").flatMap(FocusMode.init) ?? .off
        typewriter = store?.object(forKey: "typewriter") as? Bool ?? true
        goal = store?.object(forKey: "goal") as? Int ?? 500
    }

    func style(markdown: Bool) -> EditorStyle {
        EditorStyle(typeface: typeface, size: CGFloat(size), lineHeight: CGFloat(lineHeight), measure: Int(measure),
                    theme: theme, focus: focus, typewriter: typewriter, markdown: markdown)
    }

    func bigger() { size = min(Self.sizes.upperBound, size + 1) }
    func smaller() { size = max(Self.sizes.lowerBound, size - 1) }
    func actualSize() { size = 18 }

    /// The fixed look of the website screenshot.
    static var demo: Prefs {
        let p = Prefs(store: nil)
        p.theme = .sepia
        p.focus = .paragraph
        p.size = 17
        return p
    }
}
