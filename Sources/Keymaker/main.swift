import AppKit
import Kit
import Security
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
    let model = KeyModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "key.fill", accessibilityLabel: "Keymaker") {
            KeymakerView().environmentObject(self.model)
        }
        NotificationCenter.default.addObserver(forName: .popoverDidShow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.generate() }
        }
    }
}

// MARK: - Generation

/// Random numbers straight from the system's cryptographic generator.
struct SecureRandom: RandomNumberGenerator {
    mutating func next() -> UInt64 {
        var value: UInt64 = 0
        let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        if status != errSecSuccess {
            var fallback = SystemRandomNumberGenerator()
            return fallback.next()
        }
        return value
    }
}

enum CharacterSets {
    static let lower = "abcdefghijklmnopqrstuvwxyz"
    static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    static let digits = "0123456789"
    static let symbols = "!@#$%^&*()_+=-[]{};:,.?/~"
    static let ambiguous: Set<Character> = ["0", "O", "o", "1", "l", "I", "|"]
}

struct PasswordOptions: Equatable {
    var length = 20
    var lower = true
    var upper = true
    var digits = true
    var symbols = true
    var avoidAmbiguous = false

    var sets: [[Character]] {
        var result: [String] = []
        if lower { result.append(CharacterSets.lower) }
        if upper { result.append(CharacterSets.upper) }
        if digits { result.append(CharacterSets.digits) }
        if symbols { result.append(CharacterSets.symbols) }
        return result.map { set in Array(set).filter { !avoidAmbiguous || !CharacterSets.ambiguous.contains($0) } }
    }

    var poolSize: Int { sets.reduce(0) { $0 + $1.count } }
}

enum Generator {
    /// A password with at least one character from every chosen set, shuffled so their places are random too.
    static func password<R: RandomNumberGenerator>(_ o: PasswordOptions, using rng: inout R) -> String {
        let sets = o.sets.filter { !$0.isEmpty }
        guard !sets.isEmpty else { return "" }
        let pool = sets.flatMap { $0 }
        var chars = sets.prefix(o.length).map { $0.randomElement(using: &rng)! }
        while chars.count < o.length { chars.append(pool.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }

    static func passphrase<R: RandomNumberGenerator>(words count: Int, separator: String, capitalize: Bool, number: Bool,
                                                     using rng: inout R) -> String {
        var words = (0..<count).map { _ in passphraseWords.randomElement(using: &rng)! }
        if capitalize { words = words.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        if number, !words.isEmpty {
            let i = Int.random(in: 0..<words.count, using: &rng)
            words[i] += String(Int.random(in: 0...9, using: &rng))
        }
        return words.joined(separator: separator)
    }

    /// Bits of entropy of a password drawn uniformly from the pool.
    static func passwordBits(_ o: PasswordOptions) -> Double {
        o.poolSize > 1 ? Double(o.length) * log2(Double(o.poolSize)) : 0
    }

    /// Each word adds log2(list size). Capitals add nothing, since they are always on or always off;
    /// a digit on a random word adds log2(10 x words).
    static func passphraseBits(words: Int, number: Bool) -> Double {
        let base = Double(words) * log2(Double(passphraseWords.count))
        return number && words > 0 ? base + log2(Double(10 * words)) : base
    }
}

enum Strength {
    static func describe(_ bits: Double) -> (label: String, color: Color, fraction: Double) {
        let fraction = min(1, bits / 128)
        switch bits {
        case ..<36: return ("Weak", .red, fraction)
        case ..<60: return ("Fair", .orange, fraction)
        case ..<80: return ("Strong", Color(red: 0.2, green: 0.7, blue: 0.35), fraction)
        default: return ("Very strong", Color(red: 0.1, green: 0.6, blue: 0.55), fraction)
        }
    }
}

// MARK: - Model

enum Mode: String, CaseIterable {
    case password = "Password", passphrase = "Passphrase"
}

@MainActor
final class KeyModel: ObservableObject {
    @AppStorage("mode") var mode: Mode = .password { willSet { objectWillChange.send() } }
    @AppStorage("length") var length = 20 { willSet { objectWillChange.send() } }
    @AppStorage("lower") var lower = true { willSet { objectWillChange.send() } }
    @AppStorage("upper") var upper = true { willSet { objectWillChange.send() } }
    @AppStorage("digits") var digits = true { willSet { objectWillChange.send() } }
    @AppStorage("symbols") var symbols = true { willSet { objectWillChange.send() } }
    @AppStorage("avoidAmbiguous") var avoidAmbiguous = false { willSet { objectWillChange.send() } }
    @AppStorage("wordCount") var wordCount = 5 { willSet { objectWillChange.send() } }
    @AppStorage("separator") var separator = "-" { willSet { objectWillChange.send() } }
    @AppStorage("capitalize") var capitalize = false { willSet { objectWillChange.send() } }
    @AppStorage("addNumber") var addNumber = false { willSet { objectWillChange.send() } }
    @AppStorage("clearClipboard") var clearClipboard = true { willSet { objectWillChange.send() } }

    @Published private(set) var output = ""
    private var clearWork: DispatchWorkItem?

    static let separators: [(name: String, value: String)] = [
        ("Hyphen  -", "-"), ("Dot  .", "."), ("Underscore  _", "_"), ("Space", " "), ("Comma  ,", ","), ("None", ""),
    ]

    var options: PasswordOptions {
        PasswordOptions(length: length, lower: lower, upper: upper, digits: digits, symbols: symbols, avoidAmbiguous: avoidAmbiguous)
    }

    var bits: Double {
        mode == .password ? Generator.passwordBits(options) : Generator.passphraseBits(words: wordCount, number: addNumber)
    }

    init() {
        // A snapshot shows the default settings, whatever the user chose. The argument domain is read
        // before the saved one and is never written, so nothing persists.
        if StatusPopover.isSnapshot {
            UserDefaults.standard.setVolatileDomain([
                "mode": Mode.password.rawValue, "length": 20, "lower": true, "upper": true, "digits": true, "symbols": true,
                "avoidAmbiguous": false, "wordCount": 5, "separator": "-", "capitalize": false, "addNumber": false,
                "clearClipboard": true,
            ], forName: UserDefaults.argumentDomain)
        }
        generate()
    }

    func generate() {
        var rng = SecureRandom()
        output = mode == .password
            ? Generator.password(options, using: &rng)
            : Generator.passphrase(words: wordCount, separator: separator, capitalize: capitalize, number: addNumber, using: &rng)
    }

    func copy() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
        // Asks clipboard managers not to keep it.
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        HUD.show(symbol: "key.fill", title: "Copied", tint: Color.keymaker[1])
        clearWork?.cancel()
        guard clearClipboard else { return }
        let change = pasteboard.changeCount
        let work = DispatchWorkItem {
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
}

extension Color {
    static let keymaker = [Color(red: 0.98, green: 0.8, blue: 0.38), Color(red: 0.8, green: 0.55, blue: 0.12)]
}

// MARK: - Views

struct KeymakerView: View {
    @EnvironmentObject var model: KeyModel
    @Namespace private var namespace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keymaker").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Button {
                            withAnimation(.snappy) { model.mode = mode }
                            model.generate()
                        } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.mode == mode ? .black.opacity(0.8) : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background {
                                    if model.mode == mode {
                                        Capsule().fill(LinearGradient(colors: Color.keymaker, startPoint: .top, endPoint: .bottom))
                                            .matchedGeometryEffect(id: "pill", in: namespace)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(.quaternary.opacity(0.5)))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Output()
                .padding(.horizontal, 12)

            StrengthMeter(bits: model.bits)
                .padding(.horizontal, 16)
                .padding(.top, 10)

            Group {
                if model.mode == .password { PasswordOptionsView() } else { PassphraseOptionsView() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.5)
            PanelFooter(name: "Keymaker") {
                Toggle("Clear Clipboard After a Minute", isOn: $model.clearClipboard)
                Button("Generate New") { model.generate() }.keyboardShortcut("r")
            }
        }
        .frame(width: 360)
    }
}

struct Output: View {
    @EnvironmentObject var model: KeyModel

    var body: some View {
        VStack(spacing: 10) {
            colored(model.output)
                .font(.system(size: model.output.count > 32 ? 14 : 17, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 62)
                .contentTransition(.interpolate)
            HStack(spacing: 10) {
                GlassIconButton("arrow.clockwise", help: "Generate new (⌘R)") {
                    withAnimation(.snappy(duration: 0.25)) { model.generate() }
                }
                Spacer()
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(PillButtonStyle(Color.keymaker))
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy (⇧⌘C)")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.4)))
    }

    /// Digits and symbols in colour, so similar characters are easy to tell apart.
    private func colored(_ text: String) -> Text {
        text.reduce(Text("")) { result, c in
            let piece = Text(String(c))
            if c.isNumber { return result + piece.foregroundColor(Color(red: 0.2, green: 0.5, blue: 0.95)) }
            if c.isLetter { return result + piece }
            return result + piece.foregroundColor(Color(red: 0.88, green: 0.3, blue: 0.5))
        }
    }
}

struct StrengthMeter: View {
    let bits: Double

    var body: some View {
        let s = Strength.describe(bits)
        VStack(spacing: 5) {
            HStack {
                Text(s.label).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundStyle(s.color)
                Spacer()
                Text("\(Int(bits.rounded())) bits of entropy")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule()
                        .fill(LinearGradient(colors: [s.color.opacity(0.7), s.color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * s.fraction))
                }
            }
            .frame(height: 6)
            .animation(.snappy, value: bits)
        }
    }
}

struct PasswordOptionsView: View {
    @EnvironmentObject var model: KeyModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Length").font(.system(size: 12, weight: .medium))
                // Continuous, rounded by hand: a `step:` would draw a tick mark for every value.
                Slider(value: Binding(get: { Double(model.length) }, set: { v in
                    let length = Int(v.rounded())
                    guard length != model.length else { return }
                    model.length = length
                    model.generate()
                }), in: 8...64)
                Text("\(model.length)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }
            HStack(spacing: 6) {
                SetToggle(title: "a-z", isOn: $model.lower)
                SetToggle(title: "A-Z", isOn: $model.upper)
                SetToggle(title: "0-9", isOn: $model.digits)
                SetToggle(title: "!@#", isOn: $model.symbols)
            }
            Toggle("Avoid look-alike characters (0 O 1 l I)", isOn: $model.avoidAmbiguous)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: model.avoidAmbiguous) { _, _ in model.generate() }
        }
    }
}

struct SetToggle: View {
    @EnvironmentObject var model: KeyModel
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            // Keep at least one set switched on.
            let onCount = [model.lower, model.upper, model.digits, model.symbols].filter { $0 }.count
            if isOn && onCount == 1 { NSSound.beep(); return }
            withAnimation(.snappy(duration: 0.15)) { isOn.toggle() }
            model.generate()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle").font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(isOn ? Color.keymaker[1] : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOn ? AnyShapeStyle(Color.keymaker[0].opacity(0.2)) : AnyShapeStyle(.quaternary.opacity(0.35))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PassphraseOptionsView: View {
    @EnvironmentObject var model: KeyModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Stepper(value: Binding(get: { model.wordCount }, set: { model.wordCount = $0; model.generate() }), in: 3...12) {
                    HStack(spacing: 4) {
                        Text("\(model.wordCount)").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("words").font(.system(size: 12, weight: .medium))
                    }
                }
                Spacer()
                Picker("Separator", selection: Binding(get: { model.separator }, set: { model.separator = $0; model.generate() })) {
                    ForEach(KeyModel.separators, id: \.value) { Text($0.name).tag($0.value) }
                }
                .font(.system(size: 12))
                .frame(width: 170)
            }
            HStack(spacing: 16) {
                Toggle("Capitalise words", isOn: Binding(get: { model.capitalize }, set: { model.capitalize = $0; model.generate() }))
                Toggle("Add a number", isOn: Binding(get: { model.addNumber }, set: { model.addNumber = $0; model.generate() }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11.5))
            Text("From a list of \(passphraseWords.count.formatted()) common English words.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Icon

//: a golden key on graphite

func appIcon() -> NSBitmapImageRep {
    render(0x474D5C, 0x15171D) { ctx in
        radial([rgb(0xFFD36B, 0.22), rgb(0xFFD36B, 0)], center: CGPoint(x: 430, y: 600), radius: 460, in: ctx)
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 512)
        ctx.rotate(by: -40 * .pi / 180)
        // The key: a round bow with a hole, a shaft and two teeth.
        let hole = CGPath(ellipseIn: CGRect(x: -250, y: -55, width: 110, height: 110), transform: nil)

        ctx.saveGState()
        shadow(ctx, y: -20, blur: 34, alpha: 0.5)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        // Each part filled on its own, so overlaps never cancel out; then the hole is punched through.
        for part in [CGPath(ellipseIn: CGRect(x: -330, y: -135, width: 270, height: 270), transform: nil),
                     roundedRect(CGRect(x: -90, y: -38, width: 420, height: 76), 26),
                     roundedRect(CGRect(x: 210, y: -150, width: 60, height: 130), 16),
                     roundedRect(CGRect(x: 110, y: -125, width: 56, height: 105), 16)] {
            ctx.addPath(part)
            ctx.fillPath()
        }
        ctx.setBlendMode(.sourceIn)
        gradient([rgb(0xFFE7A0), rgb(0xF2B53C), rgb(0xB9791A)], from: CGPoint(x: 0, y: 140), to: CGPoint(x: 0, y: -150), in: ctx)
        ctx.setBlendMode(.clear)
        ctx.addPath(hole)
        ctx.fillPath()
        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // A bright edge along the top of the shaft and the bow.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(8)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: -60, y: 24)); ctx.addLine(to: CGPoint(x: 300, y: 24))
        ctx.strokePath()
        ctx.addArc(center: CGPoint(x: -195, y: 0), radius: 118, startAngle: .pi * 0.35, endAngle: .pi * 0.85, clockwise: false)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
