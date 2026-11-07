import Foundation

// The expression language: numbers, x, the sliders a b c, pi and e, + - * / ^, unary minus,
// implicit multiplication (2x, 3(x+1), x sin(x)), |x| and the usual functions.

/// The values an expression can read besides constants.
struct Variables {
    var x: Double = 0
    var a: Double = 1
    var b: Double = 1
    var c: Double = 1
}

enum Parameter: String, CaseIterable, Codable, Identifiable {
    case a, b, c
    var id: String { rawValue }
}

enum MathFunction: String, CaseIterable {
    case asin, acos, atan, sinh, cosh, tanh, sin, cos, tan, sqrt, abs, ln, log, exp, floor, ceil

    func apply(_ v: Double) -> Double {
        switch self {
        case .sin: Foundation.sin(v)
        case .cos: Foundation.cos(v)
        case .tan: Foundation.tan(v)
        case .asin: Foundation.asin(v)
        case .acos: Foundation.acos(v)
        case .atan: Foundation.atan(v)
        case .sinh: Foundation.sinh(v)
        case .cosh: Foundation.cosh(v)
        case .tanh: Foundation.tanh(v)
        case .sqrt: Foundation.sqrt(v)
        case .abs: Swift.abs(v)
        case .ln: Foundation.log(v)
        case .log: Foundation.log10(v)
        case .exp: Foundation.exp(v)
        case .floor: Foundation.floor(v)
        case .ceil: Foundation.ceil(v)
        }
    }
}

indirect enum Node: Equatable {
    case number(Double)
    case x
    case parameter(Parameter)
    case negate(Node)
    case add(Node, Node)
    case subtract(Node, Node)
    case multiply(Node, Node)
    case divide(Node, Node)
    case power(Node, Node)
    case call(MathFunction, Node)

    func evaluate(_ v: Variables) -> Double {
        switch self {
        case .number(let n): n
        case .x: v.x
        case .parameter(let p): p == .a ? v.a : p == .b ? v.b : v.c
        case .negate(let n): -n.evaluate(v)
        case .add(let l, let r): l.evaluate(v) + r.evaluate(v)
        case .subtract(let l, let r): l.evaluate(v) - r.evaluate(v)
        case .multiply(let l, let r): l.evaluate(v) * r.evaluate(v)
        case .divide(let l, let r): l.evaluate(v) / r.evaluate(v)
        case .power(let l, let r): Node.power(l.evaluate(v), r.evaluate(v))
        case .call(let f, let n): f.apply(n.evaluate(v))
        }
    }

    /// `pow`, plus real odd roots of negative numbers: (-8)^(1/3) is -2, as on a graphing calculator.
    static func power(_ base: Double, _ exponent: Double) -> Double {
        if base < 0, exponent.rounded() != exponent, exponent.isFinite {
            let inverse = 1 / exponent
            let odd = inverse.rounded()
            if Swift.abs(inverse - odd) < 1e-9, Int(odd) % 2 != 0 {
                return -Foundation.pow(-base, exponent)
            }
        }
        return Foundation.pow(base, exponent)
    }

    var parameters: Set<Parameter> {
        switch self {
        case .number, .x: []
        case .parameter(let p): [p]
        case .negate(let n), .call(_, let n): n.parameters
        case .add(let l, let r), .subtract(let l, let r), .multiply(let l, let r), .divide(let l, let r), .power(let l, let r):
            l.parameters.union(r.parameters)
        }
    }
}

struct ParseError: Error, Equatable {
    let message: String
}

enum Token: Equatable {
    case number(Double)
    case name(String)
    case op(Character)
}

enum Parser {
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    /// Every name the lexer knows, longest first, so "asin" wins over "a" then "sin" and "exp" over "e" then "x".
    static let names: [String] = (MathFunction.allCases.map(\.rawValue) + ["pi", "π", "e", "x", "a", "b", "c"])
        .sorted { $0.count > $1.count }

    /// Parses the right-hand side of `y = ...`. A leading "y =" or "f(x) =" is accepted and ignored.
    static func parse(_ source: String) throws -> Node {
        var text = source.trimmingCharacters(in: .whitespaces)
        if let eq = text.firstIndex(of: "=") {
            let left = text[..<eq].replacingOccurrences(of: " ", with: "").lowercased()
            if left == "y" || left.hasSuffix("(x)") { text = String(text[text.index(after: eq)...]) }
        }
        let tokens = try tokenize(text)
        guard !tokens.isEmpty else { throw ParseError(message: "Type a function of x") }
        var parser = TokenStream(tokens: tokens)
        let node = try parser.expression()
        if let extra = parser.peek {
            throw ParseError(message: extra == .op(")") ? "Unmatched closing bracket" : "Unexpected \(describe(extra))")
        }
        return node
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(text.lowercased())
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch.isDigit || (ch == "." && i + 1 < chars.count && chars[i + 1].isDigit) {
                var j = i
                var seenDot = false
                while j < chars.count, chars[j].isDigit || (chars[j] == "." && !seenDot) {
                    if chars[j] == "." { seenDot = true }
                    j += 1
                }
                guard let value = Double(String(chars[i..<j])) else { throw ParseError(message: "Bad number") }
                tokens.append(.number(value))
                i = j
                continue
            }
            if ch.isLetter {
                let rest = String(chars[i...])
                guard let name = names.first(where: { rest.hasPrefix($0) }) else {
                    var j = i
                    while j < chars.count, chars[j].isLetter { j += 1 }
                    throw ParseError(message: "Unknown name \u{201C}\(String(chars[i..<j]))\u{201D}")
                }
                tokens.append(.name(name))
                i += name.count
                continue
            }
            switch ch {
            case "+", "-", "*", "/", "^", "(", ")", "|": tokens.append(.op(ch))
            case "\u{2212}": tokens.append(.op("-"))
            case "\u{00D7}", "\u{00B7}", "\u{22C5}": tokens.append(.op("*"))
            case "\u{00F7}": tokens.append(.op("/"))
            case "[", "{": tokens.append(.op("("))
            case "]", "}": tokens.append(.op(")"))
            case "\u{00B2}": tokens += [.op("^"), .number(2)]
            case "\u{00B3}": tokens += [.op("^"), .number(3)]
            default: throw ParseError(message: "Unexpected \u{201C}\(ch)\u{201D}")
            }
            i += 1
        }
        return tokens
    }

    static func describe(_ token: Token) -> String {
        switch token {
        case .number(let n): "number \(n.formatted())"
        case .name(let s): "\u{201C}\(s)\u{201D}"
        case .op(let c): "\u{201C}\(c)\u{201D}"
        }
    }
}

/// Recursive descent, lowest precedence first:
/// expression = term (("+" | "-") term)*
/// term       = unary (("*" | "/") unary | implicit factor)*
/// unary      = ("-" | "+") unary | power
/// power      = primary ("^" unary)?        right associative, so -x^2 is -(x^2) and 2^-x works
private struct TokenStream {
    let tokens: [Token]
    var index = 0
    var absDepth = 0

    var peek: Token? { index < tokens.count ? tokens[index] : nil }

    mutating func next() -> Token? {
        defer { index += 1 }
        return peek
    }

    mutating func expression() throws -> Node {
        var node = try term()
        while let t = peek, t == .op("+") || t == .op("-") {
            index += 1
            let right = try term()
            node = t == .op("+") ? .add(node, right) : .subtract(node, right)
        }
        return node
    }

    mutating func term() throws -> Node {
        var node = try unary()
        while let t = peek {
            if t == .op("*") || t == .op("/") {
                index += 1
                let right = try unary()
                node = t == .op("*") ? .multiply(node, right) : .divide(node, right)
            } else if startsFactor(t) {
                node = .multiply(node, try power())
            } else {
                break
            }
        }
        return node
    }

    /// Tokens that begin an implicitly multiplied factor. A "|" only opens one outside an absolute value.
    func startsFactor(_ t: Token) -> Bool {
        switch t {
        case .number, .name: true
        case .op(let c): c == "(" || (c == "|" && absDepth == 0)
        }
    }

    mutating func unary() throws -> Node {
        if peek == .op("-") { index += 1; return .negate(try unary()) }
        if peek == .op("+") { index += 1; return try unary() }
        return try power()
    }

    mutating func power() throws -> Node {
        let base = try primary()
        if peek == .op("^") {
            index += 1
            return .power(base, try unary())
        }
        return base
    }

    mutating func primary() throws -> Node {
        guard let t = next() else { throw ParseError(message: "Expression ends too soon") }
        switch t {
        case .number(let n):
            return .number(n)
        case .name(let name):
            if name == "x" { return .x }
            if let p = Parameter(rawValue: name) { return .parameter(p) }
            if let value = Parser.constants[name] { return .number(value) }
            let f = MathFunction(rawValue: name)!
            guard let following = peek, following != .op(")") else {
                throw ParseError(message: "\(name) needs an argument, like \(name)(x)")
            }
            if following == .op("(") {
                index += 1
                let inner = try expression()
                guard next() == .op(")") else { throw ParseError(message: "Missing closing bracket") }
                // sin(x)^2 means (sin x)^2, as everyone writes it.
                return .call(f, inner)
            }
            // sin x, sin 2x: the argument is the next power.
            return .call(f, try power())
        case .op("("):
            let inner = try expression()
            guard next() == .op(")") else { throw ParseError(message: "Missing closing bracket") }
            return inner
        case .op("|"):
            absDepth += 1
            let inner = try expression()
            absDepth -= 1
            guard next() == .op("|") else { throw ParseError(message: "Missing closing |") }
            return .call(.abs, inner)
        case .op(let c):
            throw ParseError(message: c == ")" ? "Unmatched closing bracket" : "Unexpected \u{201C}\(c)\u{201D}")
        }
    }
}

private extension Character {
    /// ASCII digits only: superscripts like ² count as numbers to Swift but are operators here.
    var isDigit: Bool { ("0"..."9").contains(self) }
}
