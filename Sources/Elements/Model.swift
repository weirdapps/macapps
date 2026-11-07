import AppKit
import Foundation
import Kit
import SwiftUI

// MARK: - Element

enum Category: String, CaseIterable, Identifiable {
    case alkali = "am", alkalineEarth = "ae", transition = "tm", postTransition = "pt", metalloid = "md"
    case nonmetal = "nm", halogen = "ha", nobleGas = "ng", lanthanide = "la", actinide = "ac", unknown = "uk"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alkali: "Alkali metal"
        case .alkalineEarth: "Alkaline earth metal"
        case .transition: "Transition metal"
        case .postTransition: "Post-transition metal"
        case .metalloid: "Metalloid"
        case .nonmetal: "Reactive nonmetal"
        case .halogen: "Halogen"
        case .nobleGas: "Noble gas"
        case .lanthanide: "Lanthanide"
        case .actinide: "Actinide"
        case .unknown: "Unknown properties"
        }
    }

    /// The short legend label.
    var short: String {
        switch self {
        case .alkali: "Alkali"
        case .alkalineEarth: "Alkaline earth"
        case .transition: "Transition"
        case .postTransition: "Post-transition"
        case .metalloid: "Metalloid"
        case .nonmetal: "Nonmetal"
        case .halogen: "Halogen"
        case .nobleGas: "Noble gas"
        case .lanthanide: "Lanthanide"
        case .actinide: "Actinide"
        case .unknown: "Unknown"
        }
    }

    var hex: UInt32 {
        switch self {
        case .alkali: 0xFF6B6B
        case .alkalineEarth: 0xFFA94D
        case .transition: 0x9B8CFF
        case .postTransition: 0x4DABF7
        case .metalloid: 0x2FC7C9
        case .nonmetal: 0x51CF66
        case .halogen: 0xB7E34B
        case .nobleGas: 0xE17BF0
        case .lanthanide: 0xFFD43B
        case .actinide: 0xF783AC
        case .unknown: 0xB0B7BF
        }
    }
}

enum Phase: String, CaseIterable, Identifiable {
    case solid, liquid, gas, unknown
    var id: String { rawValue }
    var title: String { self == .unknown ? "Unknown" : rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .solid: 0x8C9EFF
        case .liquid: 0x2FC7C9
        case .gas: 0xFFB45C
        case .unknown: 0xB0B7BF
        }
    }
}

struct Element: Identifiable, Equatable {
    let number: Int
    let symbol: String
    let name: String
    let mass: Double
    /// True when `mass` is the mass number of the most stable isotope, shown in brackets.
    let massIsIsotope: Bool
    let category: Category
    let configuration: String
    let electronegativity: Double?
    let melting: Double?
    let sublimes: Bool
    let boiling: Double?
    let density: Double?
    /// nil means known since antiquity.
    let year: Int?

    var id: Int { number }

    /// Grid position: row 1...7 for the main table, 9 and 10 for the lanthanide and actinide rows; column 1...18.
    var row: Int { Element.position(number).row }
    var column: Int { Element.position(number).column }

    var period: Int { row <= 7 ? row : row - 3 }
    var group: Int? { row <= 7 ? column : nil }
    var block: String {
        if row > 7 { return "f" }
        if number == 2 || column <= 2 { return "s" }
        return column <= 12 ? "d" : "p"
    }

    /// State at 20 °C (293.15 K), from the melting and boiling points; unknown for elements never made in bulk.
    var phase: Phase {
        if number >= 100 { return .unknown }
        let t = 293.15
        if let boiling, boiling < t { return .gas }
        if let melting, melting > t || sublimes { return .solid }
        if melting != nil, boiling != nil { return .liquid }
        return .unknown
    }

    static func position(_ z: Int) -> (row: Int, column: Int) {
        switch z {
        case 1: (1, 1)
        case 2: (1, 18)
        case 3...4: (2, z - 2)
        case 5...10: (2, z + 8)
        case 11...12: (3, z - 10)
        case 13...18: (3, z)
        case 19...36: (4, z - 18)
        case 37...54: (5, z - 36)
        case 55...56: (6, z - 54)
        case 57...71: (9, z - 54)
        case 72...86: (6, z - 68)
        case 87...88: (7, z - 86)
        case 89...103: (10, z - 86)
        default: (7, z - 100)
        }
    }

    // MARK: Formatting

    var massText: String {
        massIsIsotope ? "[\(Int(mass))]" : Format.number(mass, maxDecimals: 4)
    }

    var configurationText: String { Format.superscripted(configuration) }

    var yearText: String { year.map(String.init) ?? "Ancient" }

    var densityText: String? {
        guard let density else { return nil }
        // Gases read better in g/L.
        if phase == .gas { return Format.number(density * 1000, maxDecimals: 4) + " g/L" }
        return Format.number(density, maxDecimals: 3) + " g/cm³"
    }

    var meltingText: String? {
        guard let melting else { return nil }
        return Format.temperature(melting)
    }

    var boilingText: String? {
        guard let boiling else { return nil }
        return Format.temperature(boiling)
    }

    /// A plain text summary for the clipboard.
    var summary: String {
        var lines = ["\(name) (\(symbol)), atomic number \(number)",
                     "Atomic mass: \(massText)",
                     "Category: \(category.title)",
                     "Electron configuration: \(configuration)"]
        if let electronegativity { lines.append("Electronegativity: \(Format.number(electronegativity, minDecimals: 2, maxDecimals: 2))") }
        if let melting { lines.append((sublimes ? "Sublimes at: " : "Melting point: ") + Format.temperature(melting)) }
        if let boiling { lines.append("Boiling point: \(Format.temperature(boiling))") }
        if let densityText { lines.append("Density: \(densityText)") }
        lines.append("Discovered: \(yearText)")
        return lines.joined(separator: "\n")
    }

    // MARK: Search

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if let n = Int(q) { return n == number }
        if symbol.lowercased() == q { return true }
        let names = [name.lowercased()] + Element.aliases[number, default: []]
        return names.contains { $0.hasPrefix(q) } || (q.count >= 3 && names.contains { $0.contains(q) })
    }

    /// Lower ranks first: exact number or symbol, then name prefix, then the rest.
    func rank(_ query: String) -> Int {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if Int(q) == number || symbol.lowercased() == q { return 0 }
        if name.lowercased().hasPrefix(q) { return 1 }
        return 2
    }

    /// American spellings and common names, so search finds them too.
    static let aliases: [Int: [String]] = [13: ["aluminum"], 55: ["cesium"], 16: ["sulphur"], 74: ["wolfram"]]
}

// MARK: - Table

enum PeriodicTable {
    static let elements: [Element] = parse(ElementData.table)

    static func element(_ number: Int) -> Element? {
        guard number >= 1, number <= elements.count else { return nil }
        let e = elements[number - 1]
        return e.number == number ? e : elements.first { $0.number == number }
    }

    static func element(row: Int, column: Int) -> Element? {
        elements.first { $0.row == row && $0.column == column }
    }

    static func parse(_ text: String) -> [Element] {
        text.split(separator: "\n").compactMap { line in
            let f = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 11, let z = Int(f[0]), let category = Category(rawValue: f[4]) else { return nil }
            let isotope = f[3].hasPrefix("[")
            guard let mass = Double(f[3].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) else { return nil }
            let sublimes = f[7].hasPrefix("s")
            return Element(number: z, symbol: f[1], name: f[2], mass: mass, massIsIsotope: isotope, category: category,
                           configuration: f[5], electronegativity: Double(f[6]),
                           melting: Double(sublimes ? String(f[7].dropFirst()) : f[7]), sublimes: sublimes,
                           boiling: Double(f[8]), density: Double(f[9]),
                           year: Int(f[10]).flatMap { $0 == 0 ? nil : $0 })
        }
    }

    /// The element reached from `number` by moving `dr` rows and `dc` columns on the grid, skipping gaps.
    static func neighbour(of number: Int, dr: Int, dc: Int) -> Int {
        guard let e = element(number) else { return number }
        if dc != 0 {
            var c = e.column + dc
            while (1...18).contains(c) {
                if let n = element(row: e.row, column: c) { return n.number }
                c += dc
            }
            return number
        }
        let rows = [1, 2, 3, 4, 5, 6, 7, 9, 10]
        guard var i = rows.firstIndex(of: e.row) else { return number }
        i += dr
        while rows.indices.contains(i) {
            if let n = element(row: rows[i], column: e.column) { return n.number }
            i += dr
        }
        return number
    }
}

// MARK: - Colouring

enum ColorMode: String, CaseIterable, Identifiable {
    case category, state, electronegativity, mass, discovery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .category: "Category"
        case .state: "State"
        case .electronegativity: "Electronegativity"
        case .mass: "Atomic Mass"
        case .discovery: "Discovery Year"
        }
    }

    var short: String {
        switch self {
        case .category: "Category"
        case .state: "State"
        case .electronegativity: "Electronegativity"
        case .mass: "Mass"
        case .discovery: "Discovery"
        }
    }

    var isHeatmap: Bool { self == .electronegativity || self == .mass || self == .discovery }

    func value(_ e: Element) -> Double? {
        switch self {
        case .electronegativity: e.electronegativity
        case .mass: e.mass
        case .discovery: e.year.map(Double.init)
        default: nil
        }
    }

    /// The min and max over the table, for the legend and the scale.
    var range: ClosedRange<Double> {
        // Arsenic (1250) and phosphorus (1669) would wash out the rest; the scale starts at 1750 and clamps.
        if self == .discovery { return 1750...2010 }
        let values = PeriodicTable.elements.compactMap(value)
        guard let lo = values.min(), let hi = values.max(), lo < hi else { return 0...1 }
        return lo...hi
    }

    /// What a tile shows under its symbol in this mode.
    func caption(_ e: Element) -> String {
        switch self {
        case .category, .state: e.name
        case .electronegativity: e.electronegativity.map { Format.number($0, minDecimals: 2, maxDecimals: 2) } ?? "n/a"
        case .mass: e.massText
        case .discovery: e.yearText
        }
    }
}

/// The heatmap scale, light cyan to deep indigo, sharing the app's accent family.
enum Heat {
    static let stops: [UInt32] = [0xE3FBFA, 0x9BE9EC, 0x3FC6D8, 0x1C8DC0, 0x24539E, 0x2B2C78]

    static func rgbComponents(_ t: Double) -> (r: Double, g: Double, b: Double) {
        let t = min(max(t, 0), 1) * Double(stops.count - 1)
        let i = min(Int(t), stops.count - 2)
        let f = t - Double(i)
        func comp(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
        let a = stops[i], b = stops[i + 1]
        return (comp(a, 16) + (comp(b, 16) - comp(a, 16)) * f,
                comp(a, 8) + (comp(b, 8) - comp(a, 8)) * f,
                comp(a, 0) + (comp(b, 0) - comp(a, 0)) * f)
    }

    static func color(_ t: Double) -> Color {
        let c = rgbComponents(t)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }

    /// True when white text reads better than black on the colour at `t`.
    static func isDark(_ t: Double) -> Bool {
        let c = rgbComponents(t)
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b < 0.5
    }
}

// MARK: - Formatting

enum Format {
    static func number(_ value: Double, minDecimals: Int = 0, maxDecimals: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.minimumFractionDigits = minDecimals
        f.maximumFractionDigits = maxDecimals
        f.minimumIntegerDigits = 1
        f.usesGroupingSeparator = false
        f.roundingMode = .halfUp
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// "1811 K (1538 °C)".
    static func temperature(_ kelvin: Double) -> String {
        "\(number(kelvin, maxDecimals: 2)) K (\(number(kelvin - 273.15, maxDecimals: 1)) °C)"
    }

    static func celsius(_ kelvin: Double) -> String { number(kelvin - 273.15, maxDecimals: 1) + " °C" }
    static func kelvin(_ kelvin: Double) -> String { number(kelvin, maxDecimals: 2) + " K" }

    /// "[Ar] 3d6 4s2" becomes "[Ar] 3d⁶ 4s²": digits after an orbital letter become superscripts.
    static func superscripted(_ config: String) -> String {
        let sup: [Character: Character] = ["0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹"]
        var out = ""
        var afterOrbital = false
        for ch in config {
            if "spdf".contains(ch) { afterOrbital = true; out.append(ch); continue }
            if afterOrbital, let s = sup[ch] { out.append(s); continue }
            afterOrbital = false
            out.append(ch)
        }
        return out
    }
}

// MARK: - Model

@MainActor
final class TableModel: ObservableObject {
    @Published var selected: Int { didSet { persist() } }
    @Published var mode: ColorMode { didSet { persist() } }
    @Published var query = ""
    @Published var hovered: Int?
    @Published var highlightedCategory: Category?
    @Published var highlightedPhase: Phase?
    private let persists: Bool

    init(selected: Int? = nil, mode: ColorMode? = nil, persists: Bool = true) {
        let defaults = UserDefaults.standard
        self.persists = persists && !Desktop.isSnapshot
        let savedZ = self.persists ? defaults.integer(forKey: "selected") : 0
        self.selected = selected ?? (PeriodicTable.element(savedZ) != nil ? savedZ : 26)
        self.mode = mode ?? (self.persists ? ColorMode(rawValue: defaults.string(forKey: "mode") ?? "") : nil) ?? .category
    }

    static var demo: TableModel { TableModel(selected: 29, mode: .category, persists: false) }

    var current: Element { PeriodicTable.element(hovered ?? selected) ?? PeriodicTable.elements[0] }
    var selectedElement: Element { PeriodicTable.element(selected) ?? PeriodicTable.elements[0] }

    var results: [Element] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return PeriodicTable.elements.filter { $0.matches(query) }.sorted { ($0.rank(query), $0.number) < ($1.rank(query), $1.number) }
    }

    /// Whether a tile is drawn at full strength, given the search and any legend highlight.
    func isLit(_ e: Element) -> Bool {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty, !e.matches(query) { return false }
        if let highlightedCategory, e.category != highlightedCategory { return false }
        if let highlightedPhase, e.phase != highlightedPhase { return false }
        return true
    }

    func move(dr: Int, dc: Int) {
        hovered = nil
        selected = PeriodicTable.neighbour(of: selected, dr: dr, dc: dc)
    }

    func selectFirstResult() {
        if let first = results.first { selected = first.number }
    }

    func copySelected() {
        guard !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedElement.summary, forType: .string)
    }

    private func persist() {
        guard persists else { return }
        UserDefaults.standard.set(selected, forKey: "selected")
        UserDefaults.standard.set(mode.rawValue, forKey: "mode")
    }
}
