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
    let model = IdentModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "number.square", accessibilityLabel: "Ident") {
            IdentView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum Kind: String, CaseIterable, Identifiable {
    case uuid4, uuid7, ulid, nanoid, hex, base62

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uuid4: "UUID v4"
        case .uuid7: "UUID v7"
        case .ulid: "ULID"
        case .nanoid: "Nano ID"
        case .hex: "Hex"
        case .base62: "Base62"
        }
    }

    var hasLength: Bool { self == .nanoid || self == .hex || self == .base62 }
    /// ULIDs are always upper case, as the spec writes them.
    var hasCase: Bool { self == .uuid4 || self == .uuid7 || self == .hex }

    var defaultLength: Int { self == .nanoid ? 21 : 32 }
}

/// Generators with an injectable random source, so the bit layouts can be checked.
struct IDGenerator<R: RandomNumberGenerator> {
    var rng: R
    var lastMillis: UInt64 = 0
    var lastV7Counter: UInt16 = 0
    var lastULIDRandom: [UInt8] = []

    init(rng: R) { self.rng = rng }

    static var crockford: [Character] { Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ") }
    static var urlAlphabet: [Character] { Array("_-0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ") }
    static var base62Alphabet: [Character] { Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz") }

    mutating func bytes(_ n: Int) -> [UInt8] { (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) } }

    static func uuidString(_ b: [UInt8]) -> String {
        let hex = b.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { r in
            String(hex[hex.index(hex.startIndex, offsetBy: r.lowerBound)..<hex.index(hex.startIndex, offsetBy: r.upperBound)])
        }
        return parts.joined(separator: "-")
    }

    /// RFC 9562 version 4: 122 random bits.
    mutating func uuid4() -> String {
        var b = bytes(16)
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return Self.uuidString(b)
    }

    /// RFC 9562 version 7: 48-bit Unix milliseconds, then 12 bits used as a counter within the same
    /// millisecond (so a batch sorts in creation order), then 62 random bits.
    mutating func uuid7(millis now: UInt64) -> String {
        var ms = max(now, lastMillis)
        var counter: UInt16
        if ms == lastMillis {
            counter = lastV7Counter &+ 1
            if counter > 0xFFF { ms += 1; counter = UInt16.random(in: 0...0x7FF, using: &rng) }
        } else {
            // Start in the lower half so there is room to count up.
            counter = UInt16.random(in: 0...0x7FF, using: &rng)
        }
        lastMillis = ms
        lastV7Counter = counter
        var b = bytes(16)
        for i in 0..<6 { b[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        b[6] = 0x70 | UInt8(counter >> 8)
        b[7] = UInt8(counter & 0xFF)
        b[8] = (b[8] & 0x3F) | 0x80
        return Self.uuidString(b)
    }

    /// ULID: 48-bit milliseconds and 80 random bits in 26 Crockford base32 characters. Monotonic
    /// within a millisecond by incrementing the random part.
    mutating func ulid(millis now: UInt64) -> String {
        var random: [UInt8]
        if now <= lastMillis, lastULIDRandom.count == 10 {
            random = lastULIDRandom
            var i = 9
            while i >= 0 {
                random[i] &+= 1
                if random[i] != 0 { break }
                i -= 1
            }
        } else {
            random = bytes(10)
        }
        let ms = max(now, lastMillis)
        lastMillis = ms
        lastULIDRandom = random
        return Self.ulidString(millis: ms, random: random)
    }

    static func ulidString(millis: UInt64, random: [UInt8]) -> String {
        var out: [Character] = []
        for i in (0..<10).reversed() { out.append(crockford[Int((millis >> (5 * UInt64(i))) & 0x1F)]) }
        // 80 bits make exactly 16 groups of five.
        var acc: UInt32 = 0, bits = 0
        for byte in random {
            acc = (acc << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(crockford[Int((acc >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
            acc &= (1 << UInt32(bits)) - 1
        }
        return String(out)
    }

    /// Uniform choice from an alphabet by rejection sampling, so no character is favoured.
    mutating func random(from alphabet: [Character], length: Int) -> String {
        String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    mutating func make(_ kind: Kind, length: Int, millis: UInt64) -> String {
        switch kind {
        case .uuid4: uuid4()
        case .uuid7: uuid7(millis: millis)
        case .ulid: ulid(millis: millis)
        case .nanoid: random(from: Self.urlAlphabet, length: length)
        case .hex: bytes((length + 1) / 2).map { String(format: "%02x", $0) }.joined().prefix(length).description
        case .base62: random(from: Self.base62Alphabet, length: length)
        }
    }
}

/// What an ID says about itself.
enum Inspector {
    struct Info: Equatable {
        var kind: String
        var detail: String
        var date: Date?
    }

    static func inspect(_ raw: String) -> Info? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("urn:uuid:") { s = String(s.dropFirst(9)) }
        if s.hasPrefix("{"), s.hasSuffix("}") { s = String(s.dropFirst().dropLast()) }
        let hex = s.replacingOccurrences(of: "-", with: "").lowercased()
        if hex.count == 32, hex.allSatisfy(\.isHexDigit), s.count == 32 || s.count == 36 {
            let bytes = stride(from: 0, to: 32, by: 2).map { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)! }
            if bytes.allSatisfy({ $0 == 0 }) { return Info(kind: "Nil UUID", detail: "All bits are zero") }
            if bytes.allSatisfy({ $0 == 0xFF }) { return Info(kind: "Max UUID", detail: "All bits are one") }
            let version = bytes[6] >> 4
            let variant = bytes[8] >> 6 == 0b10 ? "RFC 9562" : bytes[8] >> 7 == 0 ? "NCS" : bytes[8] >> 5 == 0b110 ? "Microsoft" : "reserved"
            var info = Info(kind: "UUID version \(version)", detail: "\(variant) variant")
            if version == 7 {
                let ms = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                info.date = Date(timeIntervalSince1970: Double(ms) / 1000)
            } else if version == 1 || version == 6 {
                // 60-bit count of 100 ns intervals since 1582-10-15.
                let hi = UInt64(bytes[6] & 0x0F) << 8 | UInt64(bytes[7])
                let mid = UInt64(bytes[4]) << 8 | UInt64(bytes[5])
                let low = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                let ticks: UInt64
                if version == 1 {
                    ticks = hi << 48 | mid << 32 | low
                } else {
                    ticks = bytes[0..<6].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } << 12 | hi
                }
                info.date = Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 12_219_292_800)
            }
            return info
        }
        if s.count == 26 {
            let map: [Character: Int] = {
                var m: [Character: Int] = [:]
                for (i, c) in IDGenerator<SystemRandomNumberGenerator>.crockford.enumerated() { m[c] = i; m[Character(c.lowercased())] = i }
                for c in "iIlL" { m[c] = 1 }
                for c in "oO" { m[c] = 0 }
                return m
            }()
            let values = s.compactMap { map[$0] }
            guard values.count == 26, values[0] <= 7 else { return nil }
            let ms = values[0..<10].reduce(UInt64(0)) { $0 << 5 | UInt64($1) }
            return Info(kind: "ULID", detail: "80 random bits", date: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        return nil
    }
}

@MainActor
final class IdentModel: ObservableObject {
    @AppStorage("kind") var kindRaw = Kind.uuid4.rawValue { didSet { regenerate() } }
    @AppStorage("count") var count = 5 { didSet { regenerate() } }
    @AppStorage("uppercase") var uppercase = false
    @AppStorage("hyphens") var hyphens = true
    @AppStorage("length.nanoid") var nanoLength = 21 { didSet { regenerate() } }
    @AppStorage("length.random") var randomLength = 32 { didSet { regenerate() } }
    @Published private(set) var ids: [String] = []
    @Published var inspectText = ""

    private var generator = IDGenerator(rng: SystemRandomNumberGenerator())

    init() {
        // A snapshot shows the default settings, whatever the user chose. The argument domain is read
        // before the saved one and is never written, so nothing persists.
        if StatusPopover.isSnapshot {
            UserDefaults.standard.setVolatileDomain([
                "kind": Kind.uuid4.rawValue, "count": 5, "uppercase": false, "hyphens": true,
                "length.nanoid": 21, "length.random": 32,
            ], forName: UserDefaults.argumentDomain)
        }
        regenerate()
    }

    var kind: Kind {
        get { Kind(rawValue: kindRaw) ?? .uuid4 }
        set { kindRaw = newValue.rawValue }
    }

    var length: Int {
        get { kind == .nanoid ? nanoLength : randomLength }
        set { if kind == .nanoid { nanoLength = newValue } else { randomLength = newValue } }
    }

    func regenerate() {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        ids = (0..<count).map { _ in generator.make(kind, length: length, millis: ms) }
    }

    /// The ID as shown, with the case and hyphen options applied.
    func display(_ id: String) -> String {
        var s = id
        if kind == .uuid4 || kind == .uuid7, !hyphens { s = s.replacingOccurrences(of: "-", with: "") }
        if kind.hasCase { s = uppercase ? s.uppercased() : s.lowercased() }
        return s
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct IdentView: View {
    @EnvironmentObject var model: IdentModel
    @State private var copiedAll = false

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 10) {
                KindPicker()
                OptionsBar()
                IDList()
                InspectField()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Ident") {
                Button("Generate Again") { model.regenerate() }.keyboardShortcut("r")
                Button("Copy All") { model.copy(model.ids.map(model.display).joined(separator: "\n")) }
            }
        }
        .frame(width: 380)
        .background {
            Button("") { model.regenerate() }.keyboardShortcut("r").opacity(0)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Ident").font(.system(size: 17, weight: .bold, design: .rounded))
            Spacer()
            GlassIconButton(copiedAll ? "checkmark" : "doc.on.doc", help: "Copy all, one per line") {
                model.copy(model.ids.map(model.display).joined(separator: "\n"))
                withAnimation { copiedAll = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copiedAll = false } }
            }
            GlassIconButton("arrow.clockwise", help: "Generate again (⌘R)") { withAnimation(.snappy) { model.regenerate() } }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

struct KindPicker: View {
    @EnvironmentObject var model: IdentModel

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach([Array(Kind.allCases.prefix(3)), Array(Kind.allCases.suffix(3))], id: \.self) { row in
                GridRow { ForEach(row) { kind in cell(kind) } }
            }
        }
    }

    private func cell(_ kind: Kind) -> some View {
        let selected = model.kind == kind
        return Button {
            withAnimation(.snappy(duration: 0.2)) { model.kind = kind }
        } label: {
            Text(kind.title)
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

struct OptionsBar: View {
    @EnvironmentObject var model: IdentModel

    var body: some View {
        HStack(spacing: 6) {
            Counter(label: "Count", value: $model.count, range: 1...50, step: 1)
            if model.kind.hasLength {
                Counter(label: "Length", value: $model.length, range: 4...128, step: model.kind == .nanoid ? 1 : 4)
            }
            Spacer(minLength: 0)
            if model.kind.hasCase {
                Chip(title: "ABC", selected: model.uppercase) { model.uppercase.toggle() }
            }
            if model.kind == .uuid4 || model.kind == .uuid7 {
                Chip(title: "Hyphens", selected: model.hyphens) { model.hyphens.toggle() }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.kind)
    }
}

struct Counter: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 8)
            Button { value = max(range.lowerBound, value - step) } label: { Image(systemName: "minus").frame(width: 18, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain)
            Text("\(value)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(minWidth: 20).contentTransition(.numericText())
            Button { value = min(range.upperBound, value + step) } label: { Image(systemName: "plus").frame(width: 18, height: 20).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .padding(.trailing, 3)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .background(Capsule().fill(.quaternary.opacity(0.4)))
        .animation(.snappy, value: value)
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(selected ? .white : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.4))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IDList: View {
    @EnvironmentObject var model: IdentModel

    var body: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(Array(model.ids.enumerated()), id: \.offset) { _, id in
                    IDRow(text: model.display(id))
                }
            }
        }
        .frame(height: CGFloat(min(model.ids.count, 6)) * 35)
        .animation(.snappy, value: model.ids.count)
    }
}

struct IDRow: View {
    @EnvironmentObject var model: IdentModel
    let text: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            model.copy(text)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 8) {
                Text(text)
                    .font(.system(size: text.count > 40 ? 11 : 12.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .opacity(hovering || copied ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.28)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to copy")
        .onHover { hovering = $0 }
    }
}

struct InspectField: View {
    @EnvironmentObject var model: IdentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Inspect a UUID or ULID", text: $model.inspectText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                Button {
                    model.inspectText = NSPasteboard.general.string(forType: .string) ?? ""
                } label: {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Paste from clipboard")
            }
            if !model.inspectText.isEmpty {
                if let info = Inspector.inspect(model.inspectText) {
                    HStack(spacing: 6) {
                        Text(info.kind).font(.system(size: 11.5, weight: .semibold))
                        Text(info.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if let date = info.date {
                            Text(date.formatted(.dateTime.year().month().day().hour().minute().second()))
                                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } else {
                    Text("Not a UUID or ULID.").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

extension Color {
    static let accentGradient = LinearGradient(colors: [Color(red: 0.25, green: 0.82, blue: 0.95), Color(red: 0.05, green: 0.5, blue: 0.65)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a stack of ID tags with a punched hole, the top one carrying a barcode of random bars

func appIcon() -> NSBitmapImageRep {
    render(0x67E8F9, 0x0E7490) { ctx in
        func tag(_ rect: CGRect, fill: NSColor) {
            ctx.addPath(roundedRect(rect, 56))
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        ctx.saveGState()
        ctx.translateBy(x: 512, y: 500)
        ctx.rotate(by: -8 * .pi / 180)
        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.25)
        tag(CGRect(x: -300, y: -150, width: 600, height: 340), fill: NSColor.white.withAlphaComponent(0.35))
        ctx.restoreGState()
        ctx.translateBy(x: -26, y: 44)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.3)
        tag(CGRect(x: -300, y: -150, width: 600, height: 340), fill: .white)
        ctx.restoreGState()
        // Punched hole and a band on the left.
        ctx.addPath(roundedRect(CGRect(x: -300, y: -150, width: 600, height: 340), 56))
        ctx.clip()
        ctx.setFillColor(rgb(0xCFFAFE).cgColor)
        ctx.fill(CGRect(x: -300, y: -150, width: 130, height: 340))
        ctx.setFillColor(rgb(0x0E7490).cgColor)
        ctx.fillEllipse(in: CGRect(x: -268, y: -4, width: 64, height: 64))
        // A barcode of irregular bars.
        let widths: [CGFloat] = [14, 26, 10, 10, 34, 14, 22, 10, 30, 12, 18, 10, 26, 14, 10, 22]
        var x: CGFloat = -130
        for (n, w) in widths.enumerated() where x + w < 250 {
            if n % 2 == 0 {
                ctx.setFillColor(rgb(n % 6 == 0 ? 0x06B6D4 : 0x164E63).cgColor)
                ctx.fill(CGRect(x: x, y: -70, width: w, height: 190))
            }
            x += w + 4
        }
        ctx.restoreGState()
        sparkle(ctx, at: CGPoint(x: 790, y: 790), size: 58, color: .white)
    }
}
