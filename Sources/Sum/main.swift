import AppKit
import Carbon.HIToolbox
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
    private var hotKey: HotKey?
    let model = SumModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "plus.forwardslash.minus", accessibilityLabel: "Sum") {
            SumView().environmentObject(self.model)
        }
        hotKey = HotKey(keyCode: kVK_ANSI_K, modifiers: cmdKey | optionKey) { [weak self] in self?.status.toggle() }
    }
}

// MARK: - Model

struct CalcError: Error, Equatable {
    let message: String
    let position: Int?
}

/// A recursive descent evaluator. Precedence, lowest first: + -, then * / % and implied multiplication,
/// then unary minus, then ^ (right associative, so -2^2 is -4 and 2^3^2 is 512).
struct Calculator {
    enum Token: Equatable {
        case number(Double), name(String), op(Character), open, close, comma
    }

    var ans: Double = 0
    var degrees = false

    static let functions: [String: (Double) -> Double] = [
        "sqrt": { $0.squareRoot() }, "abs": { abs($0) }, "ln": { log($0) }, "log": { log10($0) },
        "round": { $0.rounded(.toNearestOrAwayFromZero) },
    ]
    static let trig: [String: (Double) -> Double] = ["sin": sin, "cos": cos, "tan": tan]
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    static func tokenize(_ text: String) throws -> [(Token, Int)] {
        var out: [(Token, Int)] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isNumber || c == "." {
                let start = i
                while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
                // Exponent: 1e5, 2.5E-3.
                if i < chars.count, chars[i] == "e" || chars[i] == "E", i + 1 < chars.count,
                   chars[i + 1].isNumber || ((chars[i + 1] == "-" || chars[i + 1] == "+") && i + 2 < chars.count && chars[i + 2].isNumber) {
                    i += 2
                    while i < chars.count, chars[i].isNumber { i += 1 }
                }
                let s = String(chars[start..<i])
                guard let v = Double(s) else { throw CalcError(message: "\u{201C}\(s)\u{201D} is not a number.", position: start) }
                out.append((.number(v), start))
                continue
            }
            if c.isLetter || c == "π" {
                let start = i
                while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "π" { i += 1 }
                out.append((.name(String(chars[start..<i]).lowercased()), start))
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": out.append((.op(c), i))
            case "\u{2212}": out.append((.op("-"), i))
            case "\u{00D7}", "\u{00B7}": out.append((.op("*"), i))
            case "\u{00F7}": out.append((.op("/"), i))
            case "(": out.append((.open, i))
            case ")": out.append((.close, i))
            case ",": out.append((.comma, i))
            default: throw CalcError(message: "\u{201C}\(c)\u{201D} is not something I can calculate with.", position: i)
            }
            i += 1
        }
        return out
    }

    func evaluate(_ text: String) -> Result<Double, CalcError> {
        do {
            var p = Parser(tokens: try Self.tokenize(text), calc: self, length: text.count)
            guard !p.tokens.isEmpty else { throw CalcError(message: "Type an expression.", position: nil) }
            let v = try p.expression()
            if p.index < p.tokens.count {
                let (t, pos) = p.tokens[p.index]
                throw CalcError(message: t == .close ? "A closing parenthesis has no opening one." : "Missing an operator here.", position: pos)
            }
            if v.isNaN { throw CalcError(message: "Not a real number.", position: nil) }
            if v.isInfinite { throw CalcError(message: p.dividedByZero ? "Division by zero." : "Too large to show.", position: nil) }
            return .success(v == 0 ? 0 : v) // No negative zero.
        } catch let e as CalcError {
            return .failure(e)
        } catch {
            return .failure(CalcError(message: "\(error)", position: nil))
        }
    }

    struct Parser {
        let tokens: [(Token, Int)]
        let calc: Calculator
        let length: Int
        var index = 0
        var depth = 0
        var dividedByZero = false

        init(tokens: [(Token, Int)], calc: Calculator, length: Int) {
            self.tokens = tokens
            self.calc = calc
            self.length = length
        }

        var peek: Token? { index < tokens.count ? tokens[index].0 : nil }
        var position: Int { index < tokens.count ? tokens[index].1 : length }

        mutating func expression() throws -> Double {
            var v = try term()
            while let t = peek, t == .op("+") || t == .op("-") {
                index += 1
                let r = try term()
                v = t == .op("+") ? v + r : v - r
            }
            return v
        }

        /// Whether the next token starts a value that multiplies the previous one: 2pi, 2(3), (1)(2), 3 sqrt(4).
        var impliedMultiply: Bool {
            guard let t = peek, index > 0 else { return false }
            let prev = tokens[index - 1].0
            switch t {
            case .open, .name: return prev == .close || { if case .number = prev { return true }; if case .name = prev { return true }; return false }()
            case .number: return prev == .close
            default: return false
            }
        }

        mutating func term() throws -> Double {
            var v = try unary()
            while true {
                if let t = peek, t == .op("*") || t == .op("/") || t == .op("%") {
                    index += 1
                    let r = try unary()
                    switch t {
                    case .op("*"): v *= r
                    case .op("/"):
                        if r == 0 && v != 0 { dividedByZero = true }
                        v /= r
                    default:
                        if r == 0 { throw CalcError(message: "Remainder of division by zero.", position: nil) }
                        v = fmod(v, r)
                    }
                } else if impliedMultiply {
                    v *= try unary()
                } else {
                    return v
                }
            }
        }

        mutating func unary() throws -> Double {
            if peek == .op("-") { index += 1; return -(try unary()) }
            if peek == .op("+") { index += 1; return try unary() }
            return try power()
        }

        mutating func power() throws -> Double {
            let base = try primary()
            guard peek == .op("^") else { return base }
            index += 1
            return pow(base, try unary())
        }

        mutating func primary() throws -> Double {
            guard let t = peek else { throw CalcError(message: "The expression ends too soon.", position: length) }
            let pos = position
            index += 1
            switch t {
            case .number(let v):
                return v
            case .open:
                depth += 1
                defer { depth -= 1 }
                guard depth <= 200 else { throw CalcError(message: "Nested too deeply.", position: pos) }
                let v = try expression()
                guard peek == .close else { throw CalcError(message: "An opening parenthesis is never closed.", position: pos) }
                index += 1
                return v
            case .name(let name):
                if name == "ans" { return calc.ans }
                if let c = Calculator.constants[name] { return c }
                let f: ((Double) -> Double)?
                if let trig = Calculator.trig[name] {
                    let degrees = calc.degrees
                    f = { trig(degrees ? $0 * .pi / 180 : $0) }
                } else {
                    f = Calculator.functions[name]
                }
                guard let f else { throw CalcError(message: "I do not know \u{201C}\(name)\u{201D}.", position: pos) }
                // Functions take parentheses, or bind to the next value: sqrt 16, sin pi.
                if peek == .open {
                    index += 1
                    let arg = try expression()
                    guard peek == .close else { throw CalcError(message: "\(name)( is never closed.", position: pos) }
                    index += 1
                    return snap(f(arg))
                }
                guard peek != nil else { throw CalcError(message: "\(name) needs a value.", position: position) }
                return snap(f(try power()))
            case .close: throw CalcError(message: "Expected a value before \u{201C})\u{201D}.", position: pos)
            case .comma: throw CalcError(message: "Unexpected comma.", position: pos)
            case .op(let o): throw CalcError(message: "Expected a value before \u{201C}\(o)\u{201D}.", position: pos)
            }
        }

        /// sin(pi) is 1.2e-16 in floating point; show it as 0.
        private func snap(_ v: Double) -> Double { abs(v) < 1e-15 ? 0 : v }
    }

    /// Twelve significant digits, no trailing zeros, plain digits up to a quadrillion.
    static func format(_ v: Double, grouping: Bool = false) -> String {
        if v == v.rounded(), abs(v) < 1e15 {
            let i = Int64(v)
            return grouping ? i.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US"))) : String(i)
        }
        var s = String(format: "%.12g", v)
        if s.contains("e") {
            // 1.5e+20 reads better as 1.5e20.
            s = s.replacingOccurrences(of: "e+", with: "e").replacingOccurrences(of: "e-0", with: "e-").replacingOccurrences(of: "e0", with: "e")
        }
        if grouping, !s.contains("e"), let dot = s.firstIndex(of: "."), let whole = Int64(s[..<dot]) {
            let head = whole == 0 && s.hasPrefix("-") ? "-0" : whole.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
            s = head + s[dot...]
        }
        return s
    }
}

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var expression: String
    var value: Double
}

@MainActor
final class SumModel: ObservableObject {
    @Published var input = "(1 + sqrt 5) / 2"
    @Published private(set) var history: [Entry] = []
    @Published private(set) var ans: Double = 0
    @AppStorage("degrees") var degrees = false

    init() {
        history = Storage.load([Entry].self, app: "Sum", file: "history.json") ?? []
        ans = history.first?.value ?? 0
    }

    var calculator: Calculator { Calculator(ans: ans, degrees: degrees) }
    var result: Result<Double, CalcError> { calculator.evaluate(input) }

    /// Records the expression and its value, which becomes `ans`.
    func commit() {
        guard case .success(let v) = result else { return }
        withAnimation(.snappy) {
            history.insert(Entry(expression: input.trimmingCharacters(in: .whitespaces), value: v), at: 0)
            if history.count > 50 { history.removeLast(history.count - 50) }
        }
        ans = v
        input = ""
        Storage.save(history, app: "Sum", file: "history.json")
    }

    func clearHistory() {
        history = []
        Storage.save(history, app: "Sum", file: "history.json")
    }

    func copy(_ v: Double) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Calculator.format(v), forType: .string)
    }
}

// MARK: - Views

struct SumView: View {
    @EnvironmentObject var model: SumModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Hero()
            InputField(focused: $focused)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            Divider().opacity(0.5)
            HistoryList()
            Divider().opacity(0.5)
            PanelFooter(name: "Sum", shortcut: "⌥⌘K") {
                Toggle("Angles in Degrees", isOn: $model.degrees)
                Divider()
                Button("Clear History") { model.clearHistory() }
            }
        }
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }
}

struct Hero: View {
    @EnvironmentObject var model: SumModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(model.degrees ? "DEG" : "RAD")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                    .onTapGesture { model.degrees.toggle() }
                    .help("Switch between radians and degrees")
                Spacer()
                if case .success(let v) = model.result {
                    Button {
                        model.copy(v)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
            switch model.result {
            case .success(let v):
                Text(Calculator.format(v, grouping: true))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .contentTransition(.numericText())
                    .textSelection(.enabled)
                    .animation(.snappy(duration: 0.2), value: v)
            case .failure(let e):
                Text(model.input.isEmpty ? "0" : e.message)
                    .font(model.input.isEmpty ? .system(size: 40, weight: .semibold, design: .rounded) : .system(size: 14, weight: .medium))
                    .foregroundStyle(model.input.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))
                    .frame(minHeight: 48)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

struct InputField: View {
    @EnvironmentObject var model: SumModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentTint)
            TextField("2 ^ 10 / sqrt(16)", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .monospaced))
                .focused(focused)
                .onSubmit { model.commit() }
            Button { model.input = NSPasteboard.general.string(forType: .string) ?? "" } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Paste from clipboard")
            if !model.input.isEmpty {
                Button { model.input = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(0.4)))
    }
}

struct HistoryList: View {
    @EnvironmentObject var model: SumModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text("Press Return to keep a result here.\nUse ans for the last one, as in ans * 2.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.history) { HistoryRow(entry: $0) }
                    }
                    .padding(8)
                }
                .frame(height: 220)
            }
        }
    }
}

struct HistoryRow: View {
    @EnvironmentObject var model: SumModel
    let entry: Entry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.expression)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(Calculator.format(entry.value, grouping: true))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
            Button { model.copy(entry.value) } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Copy the result")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.22)))
        .contentShape(Rectangle())
        .onTapGesture { model.input = entry.expression }
        .onHover { hovering = $0 }
        .help("Click to use this expression again")
    }
}

extension Color {
    static let accentTint = Color(red: 1, green: 0.58, blue: 0.1)
}

// MARK: - Icon

//: a calculator keypad of four rounded keys, the operator key glowing orange

func appIcon() -> NSBitmapImageRep {
    render(0x52525B, 0x18181B) { ctx in
        // Display strip.
        let display = CGRect(x: 212, y: 640, width: 600, height: 150)
        ctx.addPath(roundedRect(display, 40))
        ctx.setFillColor(rgb(0x0A0A0B, 0.6).cgColor)
        ctx.fillPath()
        ctx.setFillColor(rgb(0xE4E4E7).cgColor)
        // An equals sign at the right of the display.
        ctx.addPath(roundedRect(CGRect(x: 640, y: 728, width: 120, height: 24), 12))
        ctx.addPath(roundedRect(CGRect(x: 640, y: 678, width: 120, height: 24), 12))
        ctx.fillPath()
        // Keys.
        let keys: [(CGRect, UInt32, UInt32)] = [
            (CGRect(x: 212, y: 400, width: 280, height: 200), 0x71717A, 0x52525B),
            (CGRect(x: 532, y: 400, width: 280, height: 200), 0xFFB340, 0xF97316),
            (CGRect(x: 212, y: 160, width: 280, height: 200), 0x71717A, 0x52525B),
            (CGRect(x: 532, y: 160, width: 280, height: 200), 0x71717A, 0x52525B),
        ]
        for (rect, top, bottom) in keys {
            ctx.saveGState()
            shadow(ctx, y: -10, blur: 22, alpha: 0.4)
            ctx.addPath(roundedRect(rect, 56))
            ctx.setFillColor(rgb(bottom).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(roundedRect(rect, 56))
            ctx.clip()
            gradient([rgb(top), rgb(bottom)], from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY), in: ctx)
            ctx.restoreGState()
        }
        // Symbols on the keys: plus, minus, times and divide as bars and dots.
        ctx.setFillColor(NSColor.white.cgColor)
        func bar(_ c: CGPoint, _ w: CGFloat, _ h: CGFloat) { ctx.addPath(roundedRect(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h), min(w, h) / 2)) }
        bar(CGPoint(x: 672, y: 500), 110, 30); bar(CGPoint(x: 672, y: 500), 30, 110) // plus on the orange key
        bar(CGPoint(x: 352, y: 500), 110, 30) // minus
        ctx.fillPath()
        ctx.saveGState()
        ctx.translateBy(x: 352, y: 260)
        ctx.rotate(by: .pi / 4)
        bar(.zero, 110, 30); bar(.zero, 30, 110) // times
        ctx.fillPath()
        ctx.restoreGState()
        bar(CGPoint(x: 672, y: 260), 110, 30)
        ctx.fillPath()
        ctx.fillEllipse(in: CGRect(x: 655, y: 288, width: 34, height: 34))
        ctx.fillEllipse(in: CGRect(x: 655, y: 198, width: 34, height: 34))
    }
}
