import Foundation

// The calculator behind every sheet: a tokenizer, a recursive descent parser and an evaluator that knows
// percentages, units, currency symbols, variables and references to the lines above.

// MARK: - Values

enum Dimension: String, Sendable {
    case length, mass, temperature, time, angle
}

/// A unit converts to its dimension's base unit as `(value + shift) * factor`, which covers temperatures too.
struct Unit: Equatable, Sendable {
    let symbol: String
    let dimension: Dimension
    let factor: Double
    var shift: Double = 0
    var plural: String? = nil
    /// Degree symbols sit right against the number: 21°C, not 21 °C.
    var tight: Bool { symbol.hasPrefix("°") }

    func toBase(_ v: Double) -> Double { (v + shift) * factor }
    func fromBase(_ b: Double) -> Double { b / factor - shift }

    static func == (a: Unit, b: Unit) -> Bool { a.symbol == b.symbol }

    static let meter = Unit(symbol: "m", dimension: .length, factor: 1)
    static let all: [String: Unit] = {
        let mm = Unit(symbol: "mm", dimension: .length, factor: 0.001)
        let cm = Unit(symbol: "cm", dimension: .length, factor: 0.01)
        let km = Unit(symbol: "km", dimension: .length, factor: 1000)
        let inch = Unit(symbol: "in", dimension: .length, factor: 0.0254)
        let ft = Unit(symbol: "ft", dimension: .length, factor: 0.3048)
        let yd = Unit(symbol: "yd", dimension: .length, factor: 0.9144)
        let mi = Unit(symbol: "mi", dimension: .length, factor: 1609.344)
        let g = Unit(symbol: "g", dimension: .mass, factor: 0.001)
        let kg = Unit(symbol: "kg", dimension: .mass, factor: 1)
        let lb = Unit(symbol: "lb", dimension: .mass, factor: 0.45359237)
        let oz = Unit(symbol: "oz", dimension: .mass, factor: 0.028349523125)
        let c = Unit(symbol: "°C", dimension: .temperature, factor: 1, shift: 273.15)
        let f = Unit(symbol: "°F", dimension: .temperature, factor: 5.0 / 9.0, shift: 459.67)
        let k = Unit(symbol: "K", dimension: .temperature, factor: 1)
        let ms = Unit(symbol: "ms", dimension: .time, factor: 0.001)
        let s = Unit(symbol: "s", dimension: .time, factor: 1)
        let min = Unit(symbol: "min", dimension: .time, factor: 60)
        let h = Unit(symbol: "h", dimension: .time, factor: 3600)
        let day = Unit(symbol: "day", dimension: .time, factor: 86400, plural: "days")
        let week = Unit(symbol: "week", dimension: .time, factor: 604_800, plural: "weeks")
        let deg = Unit(symbol: "°", dimension: .angle, factor: .pi / 180)
        let rad = Unit(symbol: "rad", dimension: .angle, factor: 1)
        let names: [(Unit, [String])] = [
            (mm, ["mm", "millimeter", "millimeters", "millimetre", "millimetres"]),
            (cm, ["cm", "centimeter", "centimeters", "centimetre", "centimetres"]),
            (meter, ["m", "meter", "meters", "metre", "metres"]),
            (km, ["km", "kilometer", "kilometers", "kilometre", "kilometres"]),
            (inch, ["in", "inch", "inches"]),
            (ft, ["ft", "foot", "feet"]),
            (yd, ["yd", "yard", "yards"]),
            (mi, ["mi", "mile", "miles"]),
            (g, ["g", "gram", "grams"]),
            (kg, ["kg", "kilo", "kilos", "kilogram", "kilograms"]),
            (lb, ["lb", "lbs", "pound", "pounds"]),
            (oz, ["oz", "ounce", "ounces"]),
            (c, ["c", "°c", "celsius"]),
            (f, ["f", "°f", "fahrenheit"]),
            (k, ["k", "kelvin"]),
            (ms, ["ms", "millisecond", "milliseconds"]),
            (s, ["s", "sec", "secs", "second", "seconds"]),
            (min, ["min", "mins", "minute", "minutes"]),
            (h, ["h", "hr", "hrs", "hour", "hours"]),
            (day, ["day", "days"]),
            (week, ["week", "weeks", "wk"]),
            (deg, ["°", "deg", "degree", "degrees"]),
            (rad, ["rad", "radian", "radians"]),
        ]
        var table: [String: Unit] = [:]
        for (unit, keys) in names { for key in keys { table[key] = unit } }
        return table
    }()

    static func named(_ name: String) -> Unit? { all[name.lowercased()] }
}

/// A number with an optional unit, an optional currency symbol, or a percent flag.
struct Quantity: Equatable, Sendable {
    var number: Double
    var unit: Unit? = nil
    var currency: String? = nil
    var isPercent = false

    init(_ number: Double, unit: Unit? = nil, currency: String? = nil, isPercent: Bool = false) {
        self.number = number
        self.unit = unit
        self.currency = currency
        self.isPercent = isPercent
    }

    var isPlain: Bool { unit == nil && !isPercent }
    /// The number as a fraction when it is a percentage: 20% is 0.2.
    var scalar: Double { isPercent ? number / 100 : number }

    /// How the result column shows it: "$1,038.50", "4.47 mi", "21.11°C", "15%", "0.333333".
    var formatted: String {
        if isPercent { return Format.number(number, maxFraction: 4) + "%" }
        if let currency {
            let body = Format.number(abs(number), maxFraction: 2, minFraction: 2)
            return (number < 0 && body != "0.00" ? "-" : "") + currency + body
        }
        if let unit {
            let n = Format.number(number, maxFraction: 2)
            let name = (unit.plural != nil && n != "1") ? unit.plural! : unit.symbol
            return n + (unit.tight ? "" : " ") + name
        }
        return Format.number(number, maxFraction: 6)
    }
}

enum Format {
    /// Rounds to `maxFraction` places, trims trailing zeros down to `minFraction`, groups thousands with commas.
    /// Very large and very small numbers switch to scientific notation.
    static func number(_ x: Double, maxFraction: Int, minFraction: Int = 0) -> String {
        guard x.isFinite else { return x.isNaN ? "NaN" : (x < 0 ? "-∞" : "∞") }
        let a = abs(x)
        if a >= 1e15 || (a > 0 && a < 1e-6) {
            return String(format: "%.6g", x).replacingOccurrences(of: "e+", with: "e")
        }
        var s = String(format: "%.\(maxFraction)f", x)
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        var parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var fraction = parts.count > 1 ? parts[1] : ""
        while fraction.count > minFraction, fraction.hasSuffix("0") { fraction.removeLast() }
        var whole = parts[0]
        var grouped = ""
        while whole.count > 3 {
            grouped = "," + whole.suffix(3) + grouped
            whole.removeLast(3)
        }
        grouped = whole + grouped
        parts = [grouped]
        if !fraction.isEmpty { parts.append(fraction) }
        let body = parts.joined(separator: ".")
        let isZero = body.allSatisfy { $0 == "0" || $0 == "." || $0 == "," }
        return (negative && !isZero ? "-" : "") + body
    }
}

enum FigureError: Error, Equatable {
    case syntax
    case undefined(String)
    case units
    case divisionByZero
    case domain
    case reserved(String)
}

// MARK: - Tokens

enum Tok: Equatable {
    case number(Double)
    case name(String)
    case currency(String)
    case op(String)
}

struct Token: Equatable {
    var tok: Tok
    /// UTF-16 range inside the line, for syntax colouring.
    var range: NSRange
}

/// What a line looks like once its comment and label are set aside.
struct ScannedLine {
    var tokens: [Token] = []
    /// UTF-16 offset where a `#` or `//` comment starts, if any.
    var commentStart: Int?
    /// UTF-16 length of a leading "Label:" prefix, if any.
    var labelLength: Int?
    var failed = false
}

enum Lexer {
    static let currencies: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₽", "₺", "₪", "₿"]
    static let operators: [Character: String] = [
        "+": "+", "-": "-", "−": "-", "*": "*", "×": "*", "·": "*", "/": "/", "÷": "/", "^": "^",
        "(": "(", ")": ")", ",": ",", "=": "=", "%": "%",
    ]

    static func scan(_ line: String) -> ScannedLine {
        var out = ScannedLine()
        let chars = Array(line)
        // UTF-16 offset of each character, plus the end.
        var offsets = [Int]()
        offsets.reserveCapacity(chars.count + 1)
        var o = 0
        for c in chars { offsets.append(o); o += c.utf16.count }
        offsets.append(o)

        var end = chars.count
        for i in chars.indices {
            if chars[i] == "#" || (chars[i] == "/" && i + 1 < chars.count && chars[i + 1] == "/") {
                end = i
                out.commentStart = offsets[i]
                break
            }
        }
        var i = 0
        // "Groceries: 120" ignores the label. The label needs a letter and no `=`; "10:30" is not a label.
        if let colon = chars[0..<end].firstIndex(of: ":") {
            let prefix = chars[0..<colon]
            if prefix.contains(where: \.isLetter), !prefix.contains("=") {
                i = colon + 1
                out.labelLength = offsets[colon + 1]
            }
        }

        func isNameStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "π" }
        func isNameBody(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        while i < end {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            let start = i
            if c.isASCII && c.isNumber || (c == "." && i + 1 < end && chars[i + 1].isASCII && chars[i + 1].isNumber) {
                var digits = ""
                var seenDot = false
                while i < end {
                    let d = chars[i]
                    if d.isASCII && d.isNumber { digits.append(d); i += 1; continue }
                    if d == ".", !seenDot, i + 1 < end, chars[i + 1].isASCII, chars[i + 1].isNumber {
                        seenDot = true; digits.append("."); i += 1; continue
                    }
                    // A comma followed by exactly three digits groups thousands: 1,200 but not round(2.5,2).
                    if d == ",", !seenDot, !digits.isEmpty, i + 3 < end + 1,
                       (1...3).allSatisfy({ i + $0 < end && chars[i + $0].isASCII && chars[i + $0].isNumber }),
                       !(i + 4 < end && chars[i + 4].isASCII && chars[i + 4].isNumber) {
                        i += 1; continue
                    }
                    break
                }
                // Exponent: 2e3, 1.5e-4. A bare "2e" stays 2 times e.
                if i < end, chars[i] == "e" || chars[i] == "E" {
                    var j = i + 1
                    if j < end, chars[j] == "+" || chars[j] == "-" { j += 1 }
                    if j < end, chars[j].isASCII, chars[j].isNumber {
                        var exp = String(chars[i + 1..<j])
                        while j < end, chars[j].isASCII, chars[j].isNumber { exp.append(chars[j]); j += 1 }
                        digits += "e" + exp
                        i = j
                    }
                }
                guard let value = Double(digits) else { out.failed = true; return out }
                out.tokens.append(Token(tok: .number(value), range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
            } else if c == "°" {
                i += 1
                while i < end, chars[i].isLetter { i += 1 }
                let name = String(chars[start..<i])
                out.tokens.append(Token(tok: .name(name), range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
            } else if isNameStart(c) {
                i += 1
                if c != "π" { while i < end, isNameBody(chars[i]) { i += 1 } }
                let name = String(chars[start..<i])
                out.tokens.append(Token(tok: .name(name), range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
            } else if currencies.contains(c) {
                i += 1
                out.tokens.append(Token(tok: .currency(String(c)), range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
            } else if c == "*" && i + 1 < end && chars[i + 1] == "*" {
                i += 2
                out.tokens.append(Token(tok: .op("^"), range: NSRange(location: offsets[start], length: 2)))
            } else if let op = operators[c] {
                i += 1
                out.tokens.append(Token(tok: .op(op), range: NSRange(location: offsets[start], length: offsets[i] - offsets[start])))
            } else {
                out.failed = true
                return out
            }
        }
        return out
    }
}

// MARK: - Evaluation

/// One line of a sheet after evaluation.
struct LineResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case blank, comment, text, value }
    var kind: Kind
    var value: Quantity?
    /// The variable this line defines, if any.
    var assigns: String?
    /// True for lines that are `sum`, `total` or `average` themselves, so a later total does not count them twice.
    var isTotal = false

    var display: String? { value?.formatted }
}

enum Engine {
    static let functions: Set<String> = ["sqrt", "cbrt", "abs", "round", "floor", "ceil", "sin", "cos", "tan", "log", "ln", "exp"]
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]
    static let references: Set<String> = ["prev", "ans", "sum", "total", "subtotal", "avg", "average"]
    static let keywords: Set<String> = ["of", "off", "in", "to", "as", "mod"]

    static func isReserved(_ name: String) -> Bool {
        let n = name.lowercased()
        return functions.contains(n) || constants[n] != nil || references.contains(n) || keywords.contains(n)
    }

    /// The line endings NSString (and so the editor) breaks on, so results never drift from their lines
    /// when pasted text uses \r\n, a lone \r or a Unicode line separator.
    static let lineBreaks: Set<Character> = ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"]

    static func lines(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: { lineBreaks.contains($0) }).map(String.init)
    }

    /// Evaluates every line of a sheet in order, carrying variables and line references downwards.
    static func evaluate(_ text: String) -> [LineResult] {
        var results: [LineResult] = []
        var vars: [String: Quantity] = [:]
        for line in lines(text) {
            results.append(evaluateLine(line, vars: &vars, above: results))
        }
        return results
    }

    static func evaluateLine(_ line: String, vars: inout [String: Quantity], above: [LineResult]) -> LineResult {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return LineResult(kind: .blank) }
        let scanned = Lexer.scan(line)
        if scanned.tokens.isEmpty { return LineResult(kind: scanned.commentStart != nil ? .comment : .text) }
        if scanned.failed { return LineResult(kind: .text) }
        var tokens = scanned.tokens.map(\.tok)
        var assigns: String?
        if tokens.count >= 2, case .name(let name) = tokens[0], tokens[1] == .op("=") {
            if isReserved(name) { return LineResult(kind: .text) }
            assigns = name
            tokens.removeFirst(2)
        }
        var parser = Parser(tokens: tokens, vars: vars, above: above)
        do {
            let value = try parser.parseLine()
            if let assigns { vars[assigns] = value }
            return LineResult(kind: .value, value: value, assigns: assigns, isTotal: parser.usedTotal)
        } catch {
            return LineResult(kind: .text)
        }
    }

    /// Shorthand for tests and the reference panel: the formatted result of one expression, or nil.
    static func result(_ line: String) -> String? {
        evaluate(line).last?.display
    }
}

// MARK: - Arithmetic

enum Arithmetic {
    /// Converts `q` into `unit`. A plain number takes the unit as is: "5 in km" is 5 km.
    static func convert(_ q: Quantity, to unit: Unit) throws -> Quantity {
        if q.isPercent || q.currency != nil { throw FigureError.units }
        guard let from = q.unit else { return Quantity(q.number, unit: unit, currency: q.currency) }
        guard from.dimension == unit.dimension else { throw FigureError.units }
        return Quantity(unit.fromBase(from.toBase(q.number)), unit: unit, currency: q.currency)
    }

    static func add(_ a: Quantity, _ b: Quantity, sign: Double) throws -> Quantity {
        let currency = a.currency ?? b.currency
        // 150 + 10% is 165: a percentage on the right scales the left side.
        if b.isPercent && !a.isPercent {
            return Quantity(a.number * (1 + sign * b.scalar), unit: a.unit, currency: currency)
        }
        if a.isPercent != b.isPercent { throw FigureError.units }
        if a.isPercent { return Quantity(a.number + sign * b.number, isPercent: true) }
        // Money and measurements do not add up: $5 + 3 km has no answer.
        if (a.currency != nil && b.unit != nil) || (a.unit != nil && b.currency != nil) { throw FigureError.units }
        switch (a.unit, b.unit) {
        case (nil, nil):
            return Quantity(a.number + sign * b.number, currency: currency)
        case (let u?, nil):
            return Quantity(a.number + sign * b.number, unit: u, currency: currency)
        case (nil, let u?):
            return Quantity(a.number + sign * b.number, unit: u, currency: currency)
        case (let u?, _?):
            let converted = try convert(b, to: u)
            return Quantity(a.number + sign * converted.number, unit: u, currency: currency)
        }
    }

    static func multiply(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        if a.unit != nil && b.unit != nil { throw FigureError.units }
        if a.isPercent && b.isPercent { return Quantity(a.number * b.number / 100, isPercent: true) }
        // A rate times an amount is money: 32 h × €45 is €1,440, not hours.
        let currency = a.currency ?? b.currency
        return Quantity(a.scalar * b.scalar, unit: currency == nil ? a.unit ?? b.unit : nil, currency: currency)
    }

    static func divide(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        if b.scalar == 0 { throw FigureError.divisionByZero }
        if let ua = a.unit, let ub = b.unit {
            // 10 km / 500 m is a plain ratio.
            guard ua.dimension == ub.dimension else { throw FigureError.units }
            return Quantity(ua.toBase(a.number) / ub.toBase(b.number))
        }
        if b.unit != nil { throw FigureError.units }
        if a.isPercent && b.isPercent { return Quantity(a.number / b.number) }
        if a.isPercent && b.isPlain { return Quantity(a.number / b.number, isPercent: true) }
        // Same currency on both sides gives a plain ratio: $300 / $50 is 6.
        let currency = (a.currency != nil && b.currency != nil) ? nil : (a.currency ?? b.currency)
        return Quantity(a.scalar / b.scalar, unit: a.unit, currency: currency)
    }

    static func modulo(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        guard b.isPlain, !a.isPercent, b.unit == nil else { throw FigureError.units }
        if b.number == 0 { throw FigureError.divisionByZero }
        return Quantity(a.number.truncatingRemainder(dividingBy: b.number), unit: a.unit, currency: a.currency)
    }

    static func power(_ a: Quantity, _ b: Quantity) throws -> Quantity {
        guard a.unit == nil, b.unit == nil, b.currency == nil else { throw FigureError.units }
        let r = pow(a.scalar, b.scalar)
        guard r.isFinite else { throw FigureError.domain }
        return Quantity(r, currency: a.currency)
    }
}

// MARK: - Parser

/// Precedence, lowest first: + and -; then * / mod `of` `off` and implied multiplication; unary minus; ^ (right
/// associative, so -2^2 is -4); then postfix % and units. `expr in unit` converts the whole line.
struct Parser {
    var tokens: [Tok]
    var vars: [String: Quantity]
    var above: [LineResult]
    var i = 0
    var usedTotal = false

    init(tokens: [Tok], vars: [String: Quantity], above: [LineResult]) {
        self.tokens = tokens
        self.vars = vars
        self.above = above
    }

    var peek: Tok? { i < tokens.count ? tokens[i] : nil }

    mutating func parseLine() throws -> Quantity {
        // "7.2 km in mi": the last `in`, `to` or `as` followed by exactly one unit converts the result.
        var target: Unit?
        if tokens.count >= 3, case .name(let kw) = tokens[tokens.count - 2], ["in", "to", "as"].contains(kw.lowercased()),
           case .name(let u) = tokens[tokens.count - 1], vars[u] == nil, let unit = Unit.named(u) {
            target = unit
            tokens.removeLast(2)
        }
        var value = try parseExpr()
        guard i == tokens.count else { throw FigureError.syntax }
        if let target { value = try Arithmetic.convert(value, to: target) }
        guard value.number.isFinite else { throw FigureError.domain }
        return value
    }

    mutating func parseExpr() throws -> Quantity {
        var left = try parseTerm()
        while let t = peek {
            if t == .op("+") { i += 1; left = try Arithmetic.add(left, try parseTerm(), sign: 1) }
            else if t == .op("-") { i += 1; left = try Arithmetic.add(left, try parseTerm(), sign: -1) }
            else { break }
        }
        return left
    }

    mutating func parseTerm() throws -> Quantity {
        var left = try parseUnary()
        while let t = peek {
            switch t {
            case .op("*"):
                i += 1; left = try Arithmetic.multiply(left, try parseUnary())
            case .op("/"):
                i += 1; left = try Arithmetic.divide(left, try parseUnary())
            case .op("%"):
                i += 1; left = try Arithmetic.modulo(left, try parseUnary())
            case .name(let n) where n.lowercased() == "mod":
                i += 1; left = try Arithmetic.modulo(left, try parseUnary())
            case .name(let n) where n.lowercased() == "x" && vars[n] == nil:
                // "3 x 4" in a note means times.
                i += 1; left = try Arithmetic.multiply(left, try parseUnary())
            case .name(let n) where n.lowercased() == "of":
                // 20% of 150 is 30.
                i += 1
                let right = try parseUnary()
                guard left.isPercent, !right.isPercent else { throw FigureError.syntax }
                left = Quantity(left.scalar * right.number, unit: right.unit, currency: right.currency)
            case .name(let n) where n.lowercased() == "off":
                // 10% off $80 is $72.
                i += 1
                let right = try parseUnary()
                guard left.isPercent, !right.isPercent else { throw FigureError.syntax }
                left = Quantity(right.number * (1 - left.scalar), unit: right.unit, currency: right.currency)
            default:
                guard startsOperand(t) else { return left }
                left = try Arithmetic.multiply(left, try parseUnary())
            }
        }
        return left
    }

    /// Implied multiplication: 2pi, 3(4 + 5), 2 sqrt(9), 12 rent.
    func startsOperand(_ t: Tok) -> Bool {
        switch t {
        case .number, .currency, .op("("): return true
        case .name(let n): return !Engine.keywords.contains(n.lowercased())
        default: return false
        }
    }

    mutating func parseUnary() throws -> Quantity {
        if peek == .op("-") { i += 1; var q = try parseUnary(); q.number = -q.number; return q }
        if peek == .op("+") { i += 1; return try parseUnary() }
        return try parsePower()
    }

    mutating func parsePower() throws -> Quantity {
        let base = try parsePostfix()
        if peek == .op("^") {
            i += 1
            return try Arithmetic.power(base, try parseUnary())
        }
        return base
    }

    mutating func parsePostfix() throws -> Quantity {
        var q = try parsePrimary()
        // A % is a percentage unless a number or bracket follows, where it means modulo: 10 % 3.
        if peek == .op("%") {
            let next = i + 1 < tokens.count ? tokens[i + 1] : nil
            let isModulo: Bool
            switch next {
            case .number?, .op("(")?: isModulo = true
            default: isModulo = false
            }
            if !isModulo {
                guard !q.isPercent, q.unit == nil else { throw FigureError.syntax }
                i += 1
                q.isPercent = true
            }
        }
        if case .name(let n)? = peek, vars[n] == nil, !Engine.keywords.contains(n.lowercased()) || n.lowercased() == "in",
           let unit = Unit.named(n) {
            // "12 in" is inches; the conversion keyword was already taken off the end of the line.
            guard q.unit == nil, !q.isPercent else { throw FigureError.units }
            i += 1
            q.unit = unit
        }
        if case .currency(let c)? = peek, q.currency == nil, q.unit == nil, !q.isPercent {
            // 950€
            i += 1
            q.currency = c
        }
        return q
    }

    mutating func parsePrimary() throws -> Quantity {
        guard let t = peek else { throw FigureError.syntax }
        i += 1
        switch t {
        case .number(let v):
            return Quantity(v)
        case .currency(let c):
            var q = try parsePower()
            guard q.unit == nil, !q.isPercent else { throw FigureError.units }
            q.currency = c
            return q
        case .op("("):
            let q = try parseExpr()
            guard peek == .op(")") else { throw FigureError.syntax }
            i += 1
            return q
        case .name(let name):
            if let v = vars[name] { return v }
            let lower = name.lowercased()
            if let c = Engine.constants[lower] { return Quantity(c) }
            if Engine.functions.contains(lower) { return try call(lower) }
            switch lower {
            case "prev", "ans":
                guard let v = above.last(where: { $0.value != nil })?.value else { throw FigureError.undefined(name) }
                return v
            case "sum", "total", "subtotal":
                usedTotal = true
                return try total(block())
            case "avg", "average":
                usedTotal = true
                let values = block()
                guard !values.isEmpty else { throw FigureError.undefined(name) }
                return try Arithmetic.divide(try total(values), Quantity(Double(values.count)))
            default:
                throw FigureError.undefined(name)
            }
        default:
            throw FigureError.syntax
        }
    }

    /// The values of the lines above, up to the nearest blank line or heading, leaving out other totals.
    func block() -> [Quantity] {
        var values: [Quantity] = []
        for line in above.reversed() {
            if line.kind == .blank || line.kind == .comment { break }
            if line.isTotal { continue }
            if let v = line.value { values.append(v) }
        }
        return values.reversed()
    }

    func total(_ values: [Quantity]) throws -> Quantity {
        guard var sum = values.first else { return Quantity(0) }
        for v in values.dropFirst() { sum = try Arithmetic.add(sum, v, sign: 1) }
        return sum
    }

    mutating func call(_ name: String) throws -> Quantity {
        var args: [Quantity] = []
        if peek == .op("(") {
            i += 1
            if peek != .op(")") {
                args.append(try parseExpr())
                while peek == .op(",") { i += 1; args.append(try parseExpr()) }
            }
            guard peek == .op(")") else { throw FigureError.syntax }
            i += 1
        } else {
            args.append(try parseUnary())
        }
        guard let x = args.first else { throw FigureError.syntax }
        func keep(_ v: Double) -> Quantity { Quantity(v, unit: x.unit, currency: x.currency, isPercent: x.isPercent) }
        func plain() throws -> Double {
            guard x.unit == nil else { throw FigureError.units }
            return x.scalar
        }
        func angle() throws -> Double {
            guard let u = x.unit else { return x.scalar }
            guard u.dimension == .angle else { throw FigureError.units }
            return u.toBase(x.number)
        }
        switch name {
        case "round":
            guard args.count <= 2 else { throw FigureError.syntax }
            let places = args.count == 2 ? args[1].number : 0
            let scale = pow(10, places.rounded())
            return keep((x.number * scale).rounded(.toNearestOrAwayFromZero) / scale)
        case "floor": return keep(x.number.rounded(.down))
        case "ceil": return keep(x.number.rounded(.up))
        case "abs": return keep(abs(x.number))
        default: break
        }
        guard args.count == 1 else { throw FigureError.syntax }
        switch name {
        case "sqrt":
            let v = try plain()
            guard v >= 0 else { throw FigureError.domain }
            return Quantity(v.squareRoot(), currency: x.currency)
        case "cbrt": return Quantity(cbrt(try plain()))
        case "sin": return Quantity(Self.clean(sin(try angle())))
        case "cos": return Quantity(Self.clean(cos(try angle())))
        case "tan": return Quantity(Self.clean(tan(try angle())))
        case "log", "ln":
            let v = try plain()
            guard v > 0 else { throw FigureError.domain }
            return Quantity(name == "log" ? log10(v) : log(v))
        case "exp": return Quantity(exp(try plain()))
        default: throw FigureError.undefined(name)
        }
    }

    /// sin(180°) is 0, not 1.2e-16.
    static func clean(_ v: Double) -> Double { abs(v) < 1e-12 ? 0 : v }
}

// MARK: - Syntax colouring

enum Highlight {
    enum Role { case comment, label, assignment, variable, keyword, unit }

    /// Colour ranges for one line, given its evaluation. Lines without a result stay plain prose.
    static func ranges(_ line: String, result: LineResult) -> [(NSRange, Role)] {
        let scanned = Lexer.scan(line)
        var out: [(NSRange, Role)] = []
        if let c = scanned.commentStart {
            out.append((NSRange(location: c, length: (line as NSString).length - c), .comment))
        }
        guard result.kind == .value else { return out }
        if let l = scanned.labelLength { out.append((NSRange(location: 0, length: l), .label)) }
        for (n, token) in scanned.tokens.enumerated() {
            guard case .name(let name) = token.tok else { continue }
            let lower = name.lowercased()
            if n == 0, result.assigns == name {
                out.append((token.range, .assignment))
            } else if Engine.isReserved(name) || lower == "x" {
                out.append((token.range, .keyword))
            } else if Unit.named(name) != nil {
                out.append((token.range, .unit))
            } else {
                out.append((token.range, .variable))
            }
        }
        return out
    }
}
