import AppKit
import CoreText
import Kit
import SwiftUI

// MARK: - Catalog

enum FontCategory: String, Codable, CaseIterable {
    case serif, sans, script, symbol, other

    var title: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans serif"
        case .script: "Script"
        case .symbol: "Symbols"
        case .other: "Display"
        }
    }
}

enum FontFilter: String, CaseIterable, Identifiable {
    case all, favourites, monospaced, serif, sans, script
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Fonts"
        case .favourites: "Favourites"
        case .monospaced: "Monospaced"
        case .serif: "Serif"
        case .sans: "Sans Serif"
        case .script: "Script"
        }
    }

    var symbol: String {
        switch self {
        case .all: "textformat"
        case .favourites: "star"
        case .monospaced: "chevron.left.forwardslash.chevron.right"
        case .serif: "textformat.size.larger"
        case .sans: "textformat.alt"
        case .script: "signature"
        }
    }
}

enum DetailMode: String, CaseIterable, Identifiable {
    case styles, waterfall, glyphs, compare
    var id: String { rawValue }

    var title: String {
        switch self {
        case .styles: "Styles"
        case .waterfall: "Waterfall"
        case .glyphs: "Glyphs"
        case .compare: "Compare"
        }
    }

    var symbol: String {
        switch self {
        case .styles: "list.bullet"
        case .waterfall: "text.line.first.and.arrowtriangle.forward"
        case .glyphs: "square.grid.3x3"
        case .compare: "rectangle.split.3x1"
        }
    }
}

struct FontFamily: Identifiable, Hashable, Sendable {
    let name: String
    var category: FontCategory = .other
    var isMonospaced = false
    /// False for symbol fonts and fonts that lack the letters of their own name, so the sidebar shows those in the system font.
    var canPreviewName = false
    var id: String { name }
}

struct FontStyle: Identifiable, Hashable {
    let postScriptName: String
    let styleName: String
    let weight: Int
    var id: String { postScriptName }
}

enum FontCatalog {
    static let defaultSample = "Sphinx of black quartz, judge my vow."
    static let waterfallSizes: [CGFloat] = [12, 14, 18, 24, 30, 36, 48, 60, 72, 96]
    static let sizeRange: ClosedRange<Double> = 9...160
    static let maxPinned = 4
    static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n0123456789 &?!@#%"

    /// Installed family names, without the hidden system families whose names start with a dot.
    static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The family's category from its OS/2 stylistic class bits, falling back to its name when the font leaves them unset.
    static func category(name: String, classBits: UInt32) -> FontCategory {
        switch classBits >> 28 {
        case 1, 2, 3, 4, 5, 7: return .serif
        case 8: return .sans
        case 10: return .script
        case 9, 12: return .symbol
        default: break
        }
        let n = name.lowercased()
        let has: ([String]) -> Bool = { words in words.contains { n.contains($0) } }
        if has(["dings", "ornament", "symbol", "emoji", "dingbat", "webdings"]) { return .symbol }
        if has(["sans", "gothic", "grotesk", "grotesque", "helvetica", "arial", "verdana", "avenir", "futura", "gill",
                "tahoma", "trebuchet", "optima", "myriad", "inter", "sf pro", "menlo", "monaco"]) { return .sans }
        if has(["serif", "times", "georgia", "garamond", "baskerville", "didot", "bodoni", "caslon", "palatino", "roman",
                "charter", "cochin", "hoefler", "new york", "rockwell", "courier", "iowan", "athelas", "big caslon"]) { return .serif }
        if has(["script", "hand", "brush", "chancery", "zapfino", "snell", "signpainter", "marker", "chalk", "noteworthy",
                "savoye", "bradley", "apple chancery", "party"]) { return .script }
        return .other
    }

    static func isMonospacedName(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["mono", "code", "courier", "menlo", "monaco", "consol"].contains { n.contains($0) }
    }

    /// Reads traits for each family through Core Text. Safe off the main thread.
    static func classify(_ names: [String]) -> [FontFamily] {
        names.map { name in
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, 13, nil)
            let traits = CTFontGetSymbolicTraits(font)
            let category = category(name: name, classBits: traits.rawValue & 0xF000_0000)
            let mono = traits.contains(.traitMonoSpace) || isMonospacedName(name)
            let matched = (CTFontCopyFamilyName(font) as String) == name
            return FontFamily(name: name, category: category, isMonospaced: mono,
                              canPreviewName: matched && category != .symbol && covers(font, name))
        }
    }

    static func covers(_ font: CTFont, _ text: String) -> Bool {
        let chars = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count)
    }

    static func filter(_ families: [FontFamily], search: String, filter: FontFilter, favourites: Set<String>) -> [FontFamily] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return families.filter { family in
            let kept = switch filter {
            case .all: true
            case .favourites: favourites.contains(family.name)
            case .monospaced: family.isMonospaced
            case .serif: family.category == .serif
            case .sans: family.category == .sans
            case .script: family.category == .script
            }
            return kept && (query.isEmpty || family.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    static func styles(of family: String) -> [FontStyle] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { member in
            guard member.count >= 3, let ps = member[0] as? String, let style = member[1] as? String else { return nil }
            return FontStyle(postScriptName: ps, styleName: style, weight: (member[2] as? Int) ?? 5)
        }
    }

    /// The style to show where one style stands for the family: Regular if there is one, otherwise the first.
    static func regularStyle(in styles: [FontStyle]) -> FontStyle? {
        styles.first { ["regular", "roman", "book", "medium"].contains($0.styleName.lowercased()) } ?? styles.first
    }

    static func font(_ postScriptName: String, size: CGFloat) -> Font {
        if let ns = NSFont(name: postScriptName, size: size) { return Font(ns as CTFont) }
        return .system(size: size)
    }

    static func familyFont(_ family: String, size: CGFloat) -> Font {
        if let ns = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) { return Font(ns as CTFont) }
        if let first = styles(of: family).first { return font(first.postScriptName, size: size) }
        return .system(size: size)
    }

    static let glyphRanges: [ClosedRange<UInt32>] = [
        0x21...0x7E, 0xA1...0xFF, 0x100...0x17F, 0x370...0x3FF, 0x400...0x45F,
        0x2010...0x205E, 0x20A0...0x20C0, 0x2100...0x215F, 0x2190...0x21FF, 0x2200...0x22FF, 0x25A0...0x25FF, 0xFB00...0xFB06,
    ]

    /// Printable characters the font covers, common blocks first; fonts with none of those (CJK, symbols) get their first covered characters.
    static func glyphScalars(for font: CTFont, limit: Int = 720) -> [Unicode.Scalar] {
        let set = CTFontCopyCharacterSet(font)
        var out: [Unicode.Scalar] = []
        func scan(_ range: ClosedRange<UInt32>) {
            for v in range where out.count < limit {
                guard CFCharacterSetIsLongCharacterMember(set, v), let s = Unicode.Scalar(v), isPrintable(s) else { continue }
                out.append(s)
            }
        }
        glyphRanges.forEach(scan)
        if out.count < 40 {
            out.removeAll()
            scan(0x21...0x2FFFF)
        }
        return out
    }

    static func isPrintable(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .spaceSeparator, .lineSeparator, .paragraphSeparator, .nonspacingMark, .enclosingMark: false
        default: true
        }
    }

    static func codeLabel(_ s: Unicode.Scalar) -> String {
        "U+" + String(format: "%04X", s.value)
    }

    static func clampSize(_ v: Double) -> Double {
        min(max(v.rounded(), sizeRange.lowerBound), sizeRange.upperBound)
    }
}

// MARK: - Preferences

struct SpecimenPrefs: Codable, Equatable {
    var sampleText = FontCatalog.defaultSample
    var size = 36.0
    var darkSample = false
    var favourites: [String] = []
    var pinned: [String] = []
}

// MARK: - Model

@MainActor
final class FontModel: ObservableObject {
    @Published var families: [FontFamily] = []
    @Published var search = ""
    @Published var filter: FontFilter = .all
    @Published var selection: String? { didSet { if selection != oldValue { styleChoice = nil } } }
    @Published var mode: DetailMode = .styles
    @Published var styleChoice: String?
    @Published var sampleText: String { didSet { save() } }
    @Published var size: Double { didSet { save() } }
    @Published var darkSample: Bool { didSet { save() } }
    @Published var favourites: Set<String> { didSet { save() } }
    @Published var pinned: [String] { didSet { save() } }
    @Published var toast: String?
    @Published var focusSearch = 0

    private let persists: Bool
    private var styleCache: [String: [FontStyle]] = [:]
    private var toastTask: Task<Void, Never>?

    init(prefs: SpecimenPrefs, families: [FontFamily], persists: Bool) {
        sampleText = prefs.sampleText
        size = prefs.size
        darkSample = prefs.darkSample
        favourites = Set(prefs.favourites)
        pinned = prefs.pinned
        self.families = families
        self.persists = persists
    }

    /// The live model: installed fonts, classified in the background, and saved preferences.
    convenience init() {
        let prefs = Desktop.isSnapshot ? SpecimenPrefs() : (Storage.load(SpecimenPrefs.self, app: "Specimen", file: "prefs.json") ?? SpecimenPrefs())
        let names = FontCatalog.installedFamilies()
        self.init(prefs: prefs, families: names.map { FontFamily(name: $0) }, persists: !Desktop.isSnapshot)
        pinned = pinned.filter(names.contains)
        selection = names.first { $0 == "Helvetica Neue" } ?? names.first
        Task.detached(priority: .userInitiated) {
            let classified = FontCatalog.classify(names)
            await MainActor.run { self.families = classified }
        }
    }

    /// Fixed data for the website screenshot.
    static var demo: FontModel {
        let names = ["American Typewriter", "Avenir Next", "Baskerville", "Didot", "Futura", "Georgia", "Gill Sans",
                     "Helvetica Neue", "Hoefler Text", "Menlo", "Charter", "Optima", "Palatino", "SF Mono", "Snell Roundhand", "Zapfino"]
        let installed = Set(FontCatalog.installedFamilies())
        var prefs = SpecimenPrefs()
        prefs.sampleText = "Sphinx of black quartz, judge my vow."
        prefs.size = 34
        prefs.favourites = ["Didot", "Avenir Next", "Charter", "Futura"]
        prefs.pinned = ["Didot", "Avenir Next", "Menlo"]
        let model = FontModel(prefs: prefs, families: FontCatalog.classify(names.filter(installed.contains)), persists: false)
        model.selection = installed.contains("Avenir Next") ? "Avenir Next" : model.families.first?.name
        return model
    }

    var visibleFamilies: [FontFamily] {
        FontCatalog.filter(families, search: search, filter: filter, favourites: favourites)
    }

    var effectiveSample: String {
        sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FontCatalog.defaultSample : sampleText
    }

    func family(named name: String) -> FontFamily? { families.first { $0.name == name } }

    func styles(of family: String) -> [FontStyle] {
        if let cached = styleCache[family] { return cached }
        let styles = FontCatalog.styles(of: family)
        styleCache[family] = styles
        return styles
    }

    /// The style the waterfall and glyph views use: the one picked, else Regular.
    func currentStyle(of family: String) -> FontStyle? {
        let styles = styles(of: family)
        return styles.first { $0.postScriptName == styleChoice } ?? FontCatalog.regularStyle(in: styles)
    }

    func toggleFavourite(_ name: String) {
        if favourites.contains(name) { favourites.remove(name) } else { favourites.insert(name) }
    }

    /// Pins or unpins a family for comparison. Returns false when the pin was refused because four are already pinned.
    @discardableResult
    func togglePin(_ name: String) -> Bool {
        if let i = pinned.firstIndex(of: name) {
            pinned.remove(at: i)
            return true
        }
        guard pinned.count < FontCatalog.maxPinned else {
            flash("Up to \(FontCatalog.maxPinned) fonts can be compared")
            return false
        }
        pinned.append(name)
        return true
    }

    func adjustSize(by delta: Double) {
        size = FontCatalog.clampSize(size + delta)
    }

    func copy(_ text: String) {
        guard !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied \(text)")
    }

    func flash(_ message: String) {
        toastTask?.cancel()
        withAnimation(.snappy) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.toast = nil }
        }
    }

    private func save() {
        guard persists else { return }
        let prefs = SpecimenPrefs(sampleText: sampleText, size: size, darkSample: darkSample,
                                  favourites: favourites.sorted(), pinned: pinned)
        Storage.save(prefs, app: "Specimen", file: "prefs.json")
    }
}
