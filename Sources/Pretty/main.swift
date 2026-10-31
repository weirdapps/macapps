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
    let model = PrettyModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "curlybraces.square", accessibilityLabel: "Pretty") {
            PrettyView().environmentObject(self.model)
        }
        hotKey = HotKey(keyCode: kVK_ANSI_F, modifiers: cmdKey | optionKey) { [weak self] in self?.model.formatClipboard() }
    }
}

// MARK: - Model

/// A parsed JSON document that keeps key order and the exact text of numbers and strings.
indirect enum JSONValue: Equatable {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String) // Source text, quotes and escapes included.
    case number(String)
    case bool(Bool)
    case null

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)), (.number(let x), .number(let y)): x == y
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }
}

struct JSONError: Error, Equatable {
    let message: String
    let line: Int
    let column: Int
}

/// A strict RFC 8259 parser that reports the line and column of the first problem.
struct JSONParser {
    private let s: [Unicode.Scalar]
    private var i = 0
    private var depth = 0

    init(_ text: String) { s = Array(text.unicodeScalars) }

    static func parse(_ text: String) -> Result<JSONValue, JSONError> {
        var p = JSONParser(text)
        do {
            p.skipSpace()
            if p.i == p.s.count { throw p.error("The input is empty.") }
            let v = try p.value()
            p.skipSpace()
            if p.i < p.s.count { throw p.error("Unexpected \(p.describe(p.s[p.i])) after the end of the JSON value.") }
            return .success(v)
        } catch let e as JSONError {
            return .failure(e)
        } catch {
            return .failure(JSONError(message: "\(error)", line: 1, column: 1))
        }
    }

    func error(_ message: String, at index: Int? = nil) -> JSONError {
        let end = min(index ?? i, s.count)
        var line = 1, column = 1
        for c in s[..<end] {
            if c == "\n" { line += 1; column = 1 } else { column += 1 }
        }
        return JSONError(message: message, line: line, column: column)
    }

    func describe(_ c: Unicode.Scalar) -> String {
        switch c {
        case "\n": "line break"
        case "\t": "tab"
        default: "\u{201C}\(c)\u{201D}"
        }
    }

    private var current: String { i < s.count ? describe(s[i]) : "end of input" }

    mutating func skipSpace() {
        while i < s.count, s[i] == " " || s[i] == "\n" || s[i] == "\r" || s[i] == "\t" { i += 1 }
    }

    mutating func value() throws -> JSONValue {
        guard i < s.count else { throw error("Expected a value, found the end of input.") }
        switch s[i] {
        case "{": return try object()
        case "[": return try array()
        case "\"": return .string(try string())
        case "t": try literal("true"); return .bool(true)
        case "f": try literal("false"); return .bool(false)
        case "n": try literal("null"); return .null
        case "-", "0"..."9": return .number(try number())
        case "'": throw error("Strings need double quotes, not single quotes.")
        default: throw error("Expected a value, found \(current).")
        }
    }

    mutating func literal(_ word: String) throws {
        for c in word.unicodeScalars {
            guard i < s.count, s[i] == c else { throw error("Expected \u{201C}\(word)\u{201D}.") }
            i += 1
        }
    }

    mutating func object() throws -> JSONValue {
        depth += 1
        guard depth <= 512 else { throw error("Nested more than 512 levels deep.") }
        defer { depth -= 1 }
        i += 1
        var members: [(key: String, value: JSONValue)] = []
        skipSpace()
        if i < s.count, s[i] == "}" { i += 1; return .object(members) }
        while true {
            skipSpace()
            guard i < s.count, s[i] == "\"" else {
                throw error(i < s.count && s[i] == "}" ? "Trailing comma before \u{201C}}\u{201D}." : "Expected a key in double quotes, found \(current).")
            }
            let key = try string()
            skipSpace()
            guard i < s.count, s[i] == ":" else { throw error("Expected \u{201C}:\u{201D} after the key, found \(current).") }
            i += 1
            skipSpace()
            members.append((key, try value()))
            skipSpace()
            guard i < s.count else { throw error("The object is not closed; expected \u{201C}}\u{201D}.") }
            if s[i] == "," { i += 1; continue }
            if s[i] == "}" { i += 1; return .object(members) }
            throw error("Expected \u{201C},\u{201D} or \u{201C}}\u{201D}, found \(current).")
        }
    }

    mutating func array() throws -> JSONValue {
        depth += 1
        guard depth <= 512 else { throw error("Nested more than 512 levels deep.") }
        defer { depth -= 1 }
        i += 1
        var items: [JSONValue] = []
        skipSpace()
        if i < s.count, s[i] == "]" { i += 1; return .array(items) }
        while true {
            skipSpace()
            if i < s.count, s[i] == "]" { throw error("Trailing comma before \u{201C}]\u{201D}.") }
            items.append(try value())
            skipSpace()
            guard i < s.count else { throw error("The array is not closed; expected \u{201C}]\u{201D}.") }
            if s[i] == "," { i += 1; continue }
            if s[i] == "]" { i += 1; return .array(items) }
            throw error("Expected \u{201C},\u{201D} or \u{201C}]\u{201D}, found \(current).")
        }
    }

    /// Returns the source text of the string, quotes included, after checking every escape.
    mutating func string() throws -> String {
        let start = i
        i += 1
        while i < s.count {
            let c = s[i]
            if c == "\"" {
                i += 1
                var out = String.UnicodeScalarView()
                out.append(contentsOf: s[start..<i])
                return String(out)
            }
            if c.value < 0x20 { throw error("Control characters such as a \(describe(c)) must be escaped inside strings.") }
            if c == "\\" {
                guard i + 1 < s.count else { break }
                let e = s[i + 1]
                if "\"\\/bfnrt".unicodeScalars.contains(e) {
                    i += 2
                } else if e == "u" {
                    guard i + 5 < s.count, s[(i + 2)...(i + 5)].allSatisfy({ $0.properties.isASCIIHexDigit }) else {
                        throw error("\\u needs four hex digits.")
                    }
                    i += 6
                } else {
                    throw error("\u{201C}\\\(e)\u{201D} is not a valid escape.")
                }
                continue
            }
            i += 1
        }
        throw error("The string is not closed.", at: start)
    }

    mutating func number() throws -> String {
        let start = i
        func digits() -> Int {
            let from = i
            while i < s.count, ("0"..."9").contains(s[i]) { i += 1 }
            return i - from
        }
        if s[i] == "-" { i += 1 }
        guard i < s.count, ("0"..."9").contains(s[i]) else { throw error("A minus sign must be followed by digits.") }
        if s[i] == "0" {
            i += 1
            if i < s.count, ("0"..."9").contains(s[i]) { throw error("Numbers cannot have leading zeros.", at: start) }
        } else {
            _ = digits()
        }
        if i < s.count, s[i] == "." {
            i += 1
            guard digits() > 0 else { throw error("A decimal point must be followed by digits.") }
        }
        if i < s.count, s[i] == "e" || s[i] == "E" {
            i += 1
            if i < s.count, s[i] == "+" || s[i] == "-" { i += 1 }
            guard digits() > 0 else { throw error("An exponent needs digits.") }
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s[start..<i])
        return String(out)
    }
}

enum TokenKind { case key, string, number, literal, punctuation, space }

enum JSONFormatter {
    /// `indent` nil means minified.
    static func tokens(_ value: JSONValue, indent: Int?, sortKeys: Bool) -> [(String, TokenKind)] {
        var out: [(String, TokenKind)] = []
        let unit = String(repeating: " ", count: indent ?? 0)
        func newline(_ level: Int) {
            if indent != nil { out.append(("\n" + String(repeating: unit, count: level), .space)) }
        }
        func emit(_ v: JSONValue, _ level: Int) {
            switch v {
            case .object(let members):
                if members.isEmpty { out.append(("{}", .punctuation)); return }
                let ordered = sortKeys ? members.enumerated().sorted { a, b in
                    // Stable: equal keys keep their order.
                    a.element.key == b.element.key ? a.offset < b.offset : a.element.key < b.element.key
                }.map(\.element) : members
                out.append(("{", .punctuation))
                for (n, m) in ordered.enumerated() {
                    newline(level + 1)
                    out.append((m.key, .key))
                    out.append((indent == nil ? ":" : ": ", .punctuation))
                    emit(m.value, level + 1)
                    if n < ordered.count - 1 { out.append((",", .punctuation)) }
                }
                newline(level)
                out.append(("}", .punctuation))
            case .array(let items):
                if items.isEmpty { out.append(("[]", .punctuation)); return }
                out.append(("[", .punctuation))
                for (n, item) in items.enumerated() {
                    newline(level + 1)
                    emit(item, level + 1)
                    if n < items.count - 1 { out.append((",", .punctuation)) }
                }
                newline(level)
                out.append(("]", .punctuation))
            case .string(let raw): out.append((raw, .string))
            case .number(let raw): out.append((raw, .number))
            case .bool(let b): out.append((b ? "true" : "false", .literal))
            case .null: out.append(("null", .literal))
            }
        }
        emit(value, 0)
        return out
    }

    static func format(_ text: String, indent: Int?, sortKeys: Bool) -> Result<String, JSONError> {
        JSONParser.parse(text).map { tokens($0, indent: indent, sortKeys: sortKeys).map(\.0).joined() }
    }
}

@MainActor
final class PrettyModel: ObservableObject {
    @Published var input = """
    {"name":"Pretty","version":1.0,"tags":["json","menu bar"],"settings":{"indent":2,"sortKeys":false,"theme":null},"ok":true}
    """
    @AppStorage("indent") var indent = 2
    @AppStorage("minify") var minify = false
    @AppStorage("sortKeys") var sortKeys = false

    var parsed: Result<JSONValue, JSONError> { JSONParser.parse(input) }

    func tokens(_ value: JSONValue) -> [(String, TokenKind)] {
        JSONFormatter.tokens(value, indent: minify ? nil : indent, sortKeys: sortKeys)
    }

    /// Replaces the clipboard with its formatted JSON, for the global shortcut.
    func formatClipboard() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            HUD.show(symbol: "clipboard", title: "Clipboard is empty", tint: .secondary)
            return
        }
        switch JSONFormatter.format(text, indent: indent, sortKeys: sortKeys) {
        case .success(let out):
            pb.clearContents()
            pb.setString(out, forType: .string)
            HUD.show(symbol: "curlybraces", title: "JSON formatted", tint: Color(red: 0.35, green: 0.75, blue: 1))
        case .failure(let e):
            HUD.show(symbol: "exclamationmark.triangle.fill", title: "Not valid JSON (\(e.line):\(e.column))", tint: .orange)
        }
    }
}

// MARK: - Views

struct PrettyView: View {
    @EnvironmentObject var model: PrettyModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                InputPane()
                OptionsBar()
                OutputPane()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Pretty", shortcut: "⌥⌘F") {
                Picker("Indent", selection: $model.indent) {
                    Text("2 Spaces").tag(2)
                    Text("4 Spaces").tag(4)
                }
                Toggle("Sort Keys", isOn: $model.sortKeys)
                Divider()
                Button("Format Clipboard") { model.formatClipboard() }
            }
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Pretty").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            StatusBadge()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct StatusBadge: View {
    @EnvironmentObject var model: PrettyModel

    var body: some View {
        let (symbol, text, color): (String, String, Color) = switch model.parsed {
        case .success: ("checkmark.seal.fill", "Valid JSON", .green)
        case .failure where model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: ("curlybraces", "Waiting for JSON", .secondary)
        case .failure(let e): ("exclamationmark.triangle.fill", "Line \(e.line), column \(e.column)", .orange)
        }
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.13)))
            .contentTransition(.opacity)
            .animation(.snappy, value: text)
    }
}

struct InputPane: View {
    @EnvironmentObject var model: PrettyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("JSON").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                PaneButton("doc.on.clipboard", "Paste") { model.input = NSPasteboard.general.string(forType: .string) ?? "" }
                PaneButton("wand.and.stars", "Format") {
                    if case .success(let v) = model.parsed { model.input = model.tokens(v).map(\.0).joined() }
                }
                PaneButton("xmark", "Clear") { model.input = "" }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.input)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if model.input.isEmpty {
                    Text("Paste or type JSON").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .frame(height: 100)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct OptionsBar: View {
    @EnvironmentObject var model: PrettyModel

    var body: some View {
        HStack(spacing: 6) {
            Chip("Pretty", selected: !model.minify) { model.minify = false }
            Chip("Minify", selected: model.minify) { model.minify = true }
            Spacer()
            if !model.minify {
                Chip("2", selected: model.indent == 2) { model.indent = 2 }
                Chip("4", selected: model.indent == 4) { model.indent = 4 }
            }
            Chip("Sort keys", symbol: model.sortKeys ? "checkmark" : nil, selected: model.sortKeys) { model.sortKeys.toggle() }
        }
        .animation(.snappy(duration: 0.2), value: model.minify)
    }
}

struct Chip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? .white : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.7 : 0.4))))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct OutputPane: View {
    @EnvironmentObject var model: PrettyModel
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if case .success(let v) = model.parsed {
                    let text = model.tokens(v).map(\.0).joined()
                    Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).monospacedDigit()
                    PaneButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    }
                }
            }
            Group {
                switch model.parsed {
                case .success(let v):
                    ScrollView([.vertical, .horizontal]) {
                        Text(Self.colored(model.tokens(v)))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: model.minify ? false : true, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(8)
                    }
                case .failure where model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    VStack(spacing: 6) {
                        Image(systemName: "curlybraces").font(.system(size: 24)).foregroundStyle(.tertiary)
                        Text("Paste JSON above, or press ⌥⌘F anywhere\nto format the clipboard in place.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure(let e):
                    ErrorView(error: e, source: model.input)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }

    static func colored(_ tokens: [(String, TokenKind)]) -> AttributedString {
        var out = AttributedString()
        for (text, kind) in tokens {
            var piece = AttributedString(text)
            piece.foregroundColor = switch kind {
            case .key: Color(red: 0.55, green: 0.42, blue: 0.98)
            case .string: Color(red: 0.16, green: 0.62, blue: 0.38)
            case .number: Color(red: 0.93, green: 0.48, blue: 0.12)
            case .literal: Color(red: 0.9, green: 0.25, blue: 0.5)
            case .punctuation, .space: .secondary
            }
            out += piece
        }
        return out
    }
}

/// The failing line with a caret under the column.
struct ErrorView: View {
    let error: JSONError
    let source: String

    var body: some View {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let line = error.line <= lines.count ? String(lines[error.line - 1]) : ""
        // Show a window of the line around the column so long minified JSON stays readable.
        let start = max(0, error.column - 1 - 30)
        let excerpt = String(line.unicodeScalars.dropFirst(start).prefix(50).map(Character.init))
        VStack(alignment: .leading, spacing: 8) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Text("Line \(error.line), column \(error.column)")
                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text((start > 0 ? "…" : "") + excerpt.replacingOccurrences(of: "\t", with: " "))
                Text(String(repeating: " ", count: error.column - 1 - start + (start > 0 ? 1 : 0)) + "^").foregroundStyle(.orange)
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PaneButton: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ title: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(.quaternary.opacity(hovering ? 0.8 : 0.4)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
    }
}

extension Color {
    static let accentGradient = LinearGradient(colors: [Color(red: 0.36, green: 0.7, blue: 1), Color(red: 0.2, green: 0.4, blue: 0.95)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a pair of glowing curly braces around stacked, coloured lines of code

func appIcon() -> NSBitmapImageRep {
    render(0x334155, 0x0F172A) { ctx in
        radial([rgb(0x3B82F6, 0.45), rgb(0x3B82F6, 0)], center: CGPoint(x: 512, y: 560), radius: 420, in: ctx)
        func brace(_ x: CGFloat, _ flip: CGFloat) {
            let p = CGMutablePath()
            let top: CGFloat = 770, bottom: CGFloat = 254, mid: CGFloat = 512
            p.move(to: CGPoint(x: x + 70 * flip, y: top))
            p.addQuadCurve(to: CGPoint(x: x, y: top - 70), control: CGPoint(x: x, y: top))
            p.addLine(to: CGPoint(x: x, y: mid + 60))
            p.addQuadCurve(to: CGPoint(x: x - 60 * flip, y: mid), control: CGPoint(x: x, y: mid))
            p.addQuadCurve(to: CGPoint(x: x, y: mid - 60), control: CGPoint(x: x, y: mid))
            p.addLine(to: CGPoint(x: x, y: bottom + 70))
            p.addQuadCurve(to: CGPoint(x: x + 70 * flip, y: bottom), control: CGPoint(x: x, y: bottom))
            ctx.addPath(p)
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x60A5FA, 0.9).cgColor)
        ctx.setLineWidth(58)
        ctx.setStrokeColor(rgb(0xE0F2FE).cgColor)
        brace(270, 1)
        brace(754, -1)
        ctx.strokePath()
        ctx.restoreGState()
        // Indented lines of code in syntax colours.
        let lines: [(CGFloat, CGFloat, UInt32)] = [(0, 170, 0xA78BFA), (50, 200, 0x34D399), (50, 140, 0xFB923C), (0, 120, 0xF472B6)]
        ctx.setLineWidth(40)
        for (n, (indent, width, color)) in lines.enumerated() {
            let y = 650 - CGFloat(n) * 92
            ctx.setStrokeColor(rgb(color).cgColor)
            ctx.move(to: CGPoint(x: 400 + indent, y: y)); ctx.addLine(to: CGPoint(x: 400 + indent + width, y: y))
            ctx.strokePath()
        }
    }
}
