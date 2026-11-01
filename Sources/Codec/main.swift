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
    let model = CodecModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "arrow.left.arrow.right.square", accessibilityLabel: "Codec") {
            CodecView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Scheme: String, CaseIterable, Identifiable {
    case base64, base64URL, url, html, hex, unicode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .base64: "Base64"
        case .base64URL: "Base64 URL"
        case .url: "URL"
        case .html: "HTML"
        case .hex: "Hex"
        case .unicode: "Unicode"
        }
    }
}

enum CodecError: Error, Equatable {
    case invalid(String)

    var message: String { if case .invalid(let m) = self { m } else { "" } }
}

/// Pure encoders and decoders. Text is always UTF-8.
enum Codec {
    static func encode(_ text: String, _ scheme: Scheme) -> String {
        let bytes = Data(text.utf8)
        switch scheme {
        case .base64: return bytes.base64EncodedString()
        case .base64URL:
            return bytes.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        case .url:
            // Unreserved characters from RFC 3986 stay as they are; everything else is escaped.
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            return text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
        case .html:
            var out = ""
            for ch in text {
                switch ch {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&#39;"
                default: out.append(ch)
                }
            }
            return out
        case .hex: return bytes.map { String(format: "%02x", $0) }.joined()
        case .unicode:
            var out = ""
            for scalar in text.unicodeScalars {
                if scalar.value == 0x5C { out += "\\\\" } else if scalar.isASCII && scalar.value >= 0x20 && scalar.value < 0x7F {
                    out.unicodeScalars.append(scalar)
                } else {
                    // UTF-16 units, as JavaScript, JSON and Java write them.
                    for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
                }
            }
            return out
        }
    }

    static func decode(_ text: String, _ scheme: Scheme) -> Result<String, CodecError> {
        switch scheme {
        case .base64, .base64URL:
            var s = text.filter { !$0.isWhitespace }
            s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            if s.count % 4 == 1 { return .failure(.invalid("A Base64 length cannot leave one character over.")) }
            s += String(repeating: "=", count: (4 - s.count % 4) % 4)
            guard let data = Data(base64Encoded: s) else { return .failure(.invalid("Not valid Base64.")) }
            return utf8(data)
        case .url:
            // Form and query strings write a space as "+", so it decodes to one.
            guard let s = text.replacingOccurrences(of: "+", with: " ").removingPercentEncoding else { return .failure(.invalid("A % escape is broken or is not UTF-8.")) }
            return .success(s)
        case .html: return .success(decodeEntities(text))
        case .hex:
            var s = text.filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
            if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
            guard s.count % 2 == 0 else { return .failure(.invalid("Hex needs an even number of digits.")) }
            var data = Data(capacity: s.count / 2)
            var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                guard let byte = UInt8(s[i..<j], radix: 16) else { return .failure(.invalid("\"\(s[i..<j])\" is not a hex byte.")) }
                data.append(byte)
                i = j
            }
            return utf8(data)
        case .unicode: return decodeEscapes(text)
        }
    }

    private static func utf8(_ data: Data) -> Result<String, CodecError> {
        guard let s = String(data: data, encoding: .utf8) else {
            return .failure(.invalid("Decoded \(data.count) bytes, but they are not UTF-8 text."))
        }
        return .success(s)
    }

    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
        "times": "×", "divide": "÷", "middot": "·", "bull": "•", "sect": "§", "para": "¶", "plusmn": "±",
    ]

    static func decodeEntities(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = after[..<semi]
                var value: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    value = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
                } else if name.hasPrefix("#") {
                    value = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map(String.init)
                } else {
                    value = named[String(name)]
                }
                if let value {
                    out += value
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }

    /// Reads \uXXXX (with surrogate pairs), \u{X...}, \UXXXXXXXX, \xXX and the usual \n \t \r \" \\ escapes.
    /// A run of \xXX escapes that forms valid UTF-8 decodes as bytes (Python, C); otherwise each is a code point (JavaScript).
    static func decodeEscapes(_ text: String) -> Result<String, CodecError> {
        var units: [UInt16] = []
        let chars = Array(text.unicodeScalars)
        var i = 0
        func hex(_ from: Int, _ count: Int) -> UInt32? {
            guard from + count <= chars.count else { return nil }
            return UInt32(String(String.UnicodeScalarView(chars[from..<from + count])), radix: 16)
        }
        func append(_ v: UInt32) -> Bool {
            guard let s = Unicode.Scalar(v) else { return false }
            units += Array(String(s).utf16)
            return true
        }
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else { units += Array(String(c).utf16); i += 1; continue }
            let k = chars[i + 1]
            switch k {
            case "u":
                if i + 2 < chars.count, chars[i + 2] == "{", let close = chars[(i + 3)...].firstIndex(of: "}"),
                   let v = UInt32(String(String.UnicodeScalarView(chars[(i + 3)..<close])), radix: 16) {
                    guard append(v) else { return .failure(.invalid("\\u{\(String(v, radix: 16))} is not a valid code point.")) }
                    i = close + 1
                } else if let v = hex(i + 2, 4) {
                    units.append(UInt16(v)) // Surrogates pair up when the units become a String.
                    i += 6
                } else {
                    return .failure(.invalid("\\u needs four hex digits."))
                }
            case "U":
                guard let v = hex(i + 2, 8), append(v) else { return .failure(.invalid("\\U needs eight hex digits of a valid code point.")) }
                i += 10
            case "x":
                var run: [UInt8] = []
                while i + 1 < chars.count, chars[i] == "\\", chars[i + 1] == "x" {
                    guard let v = hex(i + 2, 2) else { return .failure(.invalid("\\x needs two hex digits.")) }
                    run.append(UInt8(v))
                    i += 4
                }
                if let s = String(bytes: run, encoding: .utf8) { units += Array(s.utf16) } else { units += run.map(UInt16.init) }
            default:
                let map: [Unicode.Scalar: String] = ["n": "\n", "t": "\t", "r": "\r", "\"": "\"", "'": "'", "\\": "\\", "0": "\0", "/": "/"]
                units += Array((map[k] ?? "\\" + String(k)).utf16)
                i += 2
            }
        }
        // Lone surrogates would decode to replacement characters; report them instead.
        var it = units.makeIterator()
        var decoder = UTF16()
        var out = ""
        loop: while true {
            switch decoder.decode(&it) {
            case .scalarValue(let s): out.unicodeScalars.append(s)
            case .emptyInput: break loop
            case .error: return .failure(.invalid("An unpaired surrogate escape cannot become text."))
            }
        }
        return .success(out)
    }

    /// The decoder the input most likely needs, or nil when it looks like plain text.
    static func suggest(_ text: String) -> Scheme? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 2 else { return nil }
        func decodes(_ scheme: Scheme) -> Bool {
            guard case .success(let out) = decode(s, scheme), out != s else { return false }
            return out.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        }
        if s.range(of: #"\\(u[0-9a-fA-F]{4}|u\{[0-9a-fA-F]+\}|U[0-9a-fA-F]{8}|x[0-9a-fA-F]{2})"#, options: .regularExpression) != nil,
           decodes(.unicode) { return .unicode }
        if s.range(of: "%[0-9a-fA-F]{2}", options: .regularExpression) != nil, decodes(.url) { return .url }
        if s.range(of: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z]+);", options: .regularExpression) != nil, decodes(.html) { return .html }
        // Short digit runs like "2024" are years and numbers far more often than hex.
        let hexLooking = s.count >= 8 || s.hasPrefix("0x") || s.contains(" ") || s.contains(":")
        if hexLooking, s.range(of: "^(0x)?([0-9a-fA-F]{2}[ :]?)+$", options: .regularExpression) != nil, decodes(.hex) { return .hex }
        if s.count >= 4, s.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil, s.contains(where: { $0 == "-" || $0 == "_" }),
           decodes(.base64URL) { return .base64URL }
        if s.count >= 4, s.range(of: "^[A-Za-z0-9+/\\s]+={0,2}$", options: .regularExpression) != nil, decodes(.base64) { return .base64 }
        return nil
    }
}

@MainActor
final class CodecModel: ObservableObject {
    @AppStorage("scheme") var schemeRaw = Scheme.base64.rawValue
    @AppStorage("decoding") var decoding = false
    @Published var input = "Hello, wörld! <3"

    var scheme: Scheme {
        get { Scheme(rawValue: schemeRaw) ?? .base64 }
        set { schemeRaw = newValue.rawValue; objectWillChange.send() }
    }

    var output: Result<String, CodecError> {
        decoding ? Codec.decode(input, scheme) : .success(Codec.encode(input, scheme))
    }

    var suggestion: Scheme? {
        guard let s = Codec.suggest(input), !(decoding && s == scheme) else { return nil }
        return s
    }

    func apply(_ suggestion: Scheme) {
        scheme = suggestion
        decoding = true
    }

    /// Moves the result into the input and flips the direction.
    func swap() {
        guard case .success(let out) = output else { return }
        input = out
        decoding.toggle()
    }
}

// MARK: - Views

struct CodecView: View {
    @EnvironmentObject var model: CodecModel

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                SchemePicker()
                Pane(title: "Input", text: $model.input, placeholder: "Type or paste text") {
                    PaneButton("doc.on.clipboard", "Paste") { model.input = NSPasteboard.general.string(forType: .string) ?? "" }
                    PaneButton("xmark", "Clear") { model.input = "" }
                }
                if let s = model.suggestion {
                    SuggestionBar(scheme: s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                OutputPane()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .animation(.snappy(duration: 0.25), value: model.suggestion)
            Divider().opacity(0.5)
            PanelFooter(name: "Codec") {
                Button("Swap Input and Result") { model.swap() }
                Button("Clear") { model.input = "" }
            }
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Codec").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            DirectionToggle()
            GlassIconButton("arrow.up.arrow.down", help: "Use the result as input") { withAnimation(.snappy) { model.swap() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct DirectionToggle: View {
    @EnvironmentObject var model: CodecModel
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { decode in
                Button {
                    withAnimation(.snappy) { model.decoding = decode }
                } label: {
                    Text(decode ? "Decode" : "Encode")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(model.decoding == decode ? .white : .secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            if model.decoding == decode {
                                Capsule().fill(Color.accentGradient).matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2.5)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

struct SchemePicker: View {
    @EnvironmentObject var model: CodecModel

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach([Array(Scheme.allCases.prefix(3)), Array(Scheme.allCases.suffix(3))], id: \.self) { row in
                GridRow { ForEach(row) { scheme in cell(scheme) } }
            }
        }
    }

    private func cell(_ scheme: Scheme) -> some View {
        let selected = model.scheme == scheme
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.scheme = scheme }
        } label: {
            Text(scheme.title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.35))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SuggestionBar: View {
    @EnvironmentObject var model: CodecModel
    let scheme: Scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(Color.accentGradient)
            Text("This looks like \(scheme.title).").font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Decode") { withAnimation(.snappy) { model.apply(scheme) } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.42, green: 0.32, blue: 0.95))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(red: 0.42, green: 0.32, blue: 0.95).opacity(0.12)))
    }
}

struct OutputPane: View {
    @EnvironmentObject var model: CodecModel
    @State private var copied = false

    var body: some View {
        let result = model.output
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Result").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if case .success(let s) = result {
                    Text("\(s.count) characters").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary).monospacedDigit()
                    PaneButton(copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                        withAnimation { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copied = false } }
                    }
                }
            }
            Group {
                switch result {
                case .success(let s) where s.isEmpty:
                    Text("The result shows here as you type.").foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .success(let s):
                    ScrollView {
                        Text(s).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(8)
                    }
                case .failure(let e):
                    Label(e.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .font(.system(size: 12.5, design: .monospaced))
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
    }
}

struct Pane<Buttons: View>: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                buttons
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                if text.isEmpty {
                    Text(placeholder).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
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
    static let accentGradient = LinearGradient(colors: [Color(red: 0.63, green: 0.55, blue: 1), Color(red: 0.36, green: 0.24, blue: 0.88)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: two interlocking brackets passing a glowing token between them

func appIcon() -> NSBitmapImageRep {
    render(0xA18CFF, 0x5B3CE0) { ctx in
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        // Left and right angle brackets.
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.3)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(78)
        ctx.move(to: CGPoint(x: 400, y: 720)); ctx.addLine(to: CGPoint(x: 230, y: 512)); ctx.addLine(to: CGPoint(x: 400, y: 304))
        ctx.move(to: CGPoint(x: 624, y: 720)); ctx.addLine(to: CGPoint(x: 794, y: 512)); ctx.addLine(to: CGPoint(x: 624, y: 304))
        ctx.strokePath()
        ctx.restoreGState()
        // Two arrows crossing between them, one each way.
        ctx.setLineWidth(40)
        ctx.setStrokeColor(rgb(0xFFE38A).cgColor)
        ctx.move(to: CGPoint(x: 430, y: 572)); ctx.addLine(to: CGPoint(x: 600, y: 572))
        ctx.move(to: CGPoint(x: 560, y: 616)); ctx.addLine(to: CGPoint(x: 604, y: 572)); ctx.addLine(to: CGPoint(x: 560, y: 528))
        ctx.strokePath()
        ctx.setStrokeColor(rgb(0x8BF0FF).cgColor)
        ctx.move(to: CGPoint(x: 594, y: 452)); ctx.addLine(to: CGPoint(x: 424, y: 452))
        ctx.move(to: CGPoint(x: 464, y: 496)); ctx.addLine(to: CGPoint(x: 420, y: 452)); ctx.addLine(to: CGPoint(x: 464, y: 408))
        ctx.strokePath()
        sparkle(ctx, at: CGPoint(x: 760, y: 770), size: 56, color: NSColor.white.withAlphaComponent(0.9))
    }
}
