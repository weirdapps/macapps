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
    let model = EpochModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "clock.arrow.2.circlepath", accessibilityLabel: "Epoch") {
            EpochView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

/// A moment as whole seconds since 1970 plus nanoseconds, so nanosecond input survives exactly.
struct Instant: Equatable, Comparable {
    var seconds: Int64
    var nanos: Int64 // Always 0 ..< 1_000_000_000.

    init(seconds: Int64, nanos: Int64 = 0) {
        self.seconds = seconds + Self.floorDiv(nanos, 1_000_000_000)
        self.nanos = Self.mod(nanos, 1_000_000_000)
    }

    init(_ date: Date) {
        let t = date.timeIntervalSince1970
        let s = t.rounded(.down)
        self.init(seconds: Int64(s), nanos: Int64(((t - s) * 1e9).rounded()))
    }

    var date: Date { Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1e9) }

    /// The value in units of 1/`perSecond` s, floored, or nil on overflow.
    func value(perSecond: Int64) -> Int64? {
        let (whole, o1) = seconds.multipliedReportingOverflow(by: perSecond)
        let (sum, o2) = whole.addingReportingOverflow(nanos / (1_000_000_000 / perSecond))
        return o1 || o2 ? nil : sum
    }

    static func < (a: Instant, b: Instant) -> Bool { (a.seconds, a.nanos) < (b.seconds, b.nanos) }

    static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }
    static func mod(_ a: Int64, _ b: Int64) -> Int64 { ((a % b) + b) % b }
}

enum EpochUnit: String, CaseIterable, Identifiable {
    case auto, seconds, millis, micros, nanos

    var id: String { rawValue }
    var short: String {
        switch self {
        case .auto: "Auto"
        case .seconds: "s"
        case .millis: "ms"
        case .micros: "µs"
        case .nanos: "ns"
        }
    }
    var name: String {
        switch self {
        case .auto: "auto"
        case .seconds: "seconds"
        case .millis: "milliseconds"
        case .micros: "microseconds"
        case .nanos: "nanoseconds"
        }
    }
    var perSecond: Int64 {
        switch self {
        case .auto, .seconds: 1
        case .millis: 1000
        case .micros: 1_000_000
        case .nanos: 1_000_000_000
        }
    }
}

struct Parsed: Equatable {
    var instant: Instant
    var readAs: String
}

enum EpochParser {
    static func parse(_ raw: String, unit: EpochUnit, zone: TimeZone, now: Date = Date()) -> Result<Parsed, ParseError> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(ParseError("Type a timestamp or a date.")) }
        if text.lowercased() == "now" { return .success(Parsed(instant: Instant(now), readAs: "now")) }
        if text.range(of: #"^[+-]?\d+(\.\d+)?$"#, options: .regularExpression) != nil { return number(text, unit: unit) }
        if let p = iso(text, zone: zone) { return p }
        if let p = rfc2822(text) { return p }
        return .failure(ParseError("Not a timestamp, an ISO 8601 date or an RFC 2822 date."))
    }

    /// Plain numbers. Auto picks the unit from the digit count: up to 11 digits is seconds, 14 is ms, 17 is µs, more is ns.
    static func number(_ text: String, unit: EpochUnit) -> Result<Parsed, ParseError> {
        var s = Substring(text)
        let negative = s.first == "-"
        if s.first == "-" || s.first == "+" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intDigits = parts[0].drop { $0 == "0" }
        var unit = unit
        if unit == .auto {
            unit = intDigits.count <= 11 ? .seconds : intDigits.count <= 14 ? .millis : intDigits.count <= 17 ? .micros : .nanos
        }
        guard let whole = Int64(parts[0]) else { return .failure(ParseError("That number is too large.")) }
        let perSecond = unit.perSecond
        let unitNanos = 1_000_000_000 / perSecond
        var nanos = (whole % perSecond) * unitNanos
        if parts.count > 1 {
            // Fraction of one unit, truncated past nanosecond precision.
            let digits = String(parts[1].prefix(9)).padding(toLength: 9, withPad: "0", startingAt: 0)
            nanos += Int64(digits)! / perSecond
        }
        var instant = Instant(seconds: whole / perSecond, nanos: nanos)
        if negative { instant = Instant(seconds: -instant.seconds, nanos: -instant.nanos) }
        return .success(Parsed(instant: instant, readAs: unit.name))
    }

    static let isoPattern = try! NSRegularExpression(pattern:
        #"^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?)?\s*(Z|z|UTC|[+-]\d{2}(?::?\d{2}(?::?\d{2})?)?)?$"#)

    static func iso(_ text: String, zone: TimeZone) -> Result<Parsed, ParseError>? {
        let ns = text as NSString
        guard let m = isoPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        var offset: Int?
        if let z = group(8) {
            if z == "Z" || z == "z" || z == "UTC" {
                offset = 0
            } else {
                let digits = z.dropFirst().filter(\.isNumber)
                let d = Array(digits).map { Int(String($0))! }
                let h = d[0] * 10 + d[1], mins = d.count >= 4 ? d[2] * 10 + d[3] : 0, secs = d.count == 6 ? d[4] * 10 + d[5] : 0
                guard h <= 23, mins <= 59, secs <= 59 else { return .failure(ParseError("The UTC offset \(z) is out of range.")) }
                offset = (z.first == "-" ? -1 : 1) * (h * 3600 + mins * 60 + secs)
            }
        }
        let fraction = group(7).map { Int64($0.padding(toLength: 9, withPad: "0", startingAt: 0))! } ?? 0
        let readAs = offset == nil ? (group(4) == nil ? "ISO 8601 date in \(zone.identifier)" : "ISO 8601 in \(zone.identifier)") : "ISO 8601"
        return build(year: Int(group(1)!)!, month: Int(group(2)!)!, day: Int(group(3)!)!, hour: Int(group(4) ?? "0")!,
                     minute: Int(group(5) ?? "0")!, second: Int(group(6) ?? "0")!, nanos: fraction,
                     offset: offset, zone: zone, readAs: readAs)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    static let zoneNames: [String: Int] = ["UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "EST": -5, "EDT": -4, "CST": -6, "CDT": -5,
                                           "MST": -7, "MDT": -6, "PST": -8, "PDT": -7]
    static let rfcPattern = try! NSRegularExpression(pattern:
        #"^(?:([A-Za-z]{3}),?\s+)?(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,3})?$"#)

    static func rfc2822(_ text: String) -> Result<Parsed, ParseError>? {
        let ns = text as NSString
        guard let m = rfcPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        guard let month = months.firstIndex(of: group(3)!.lowercased()) else { return .failure(ParseError("\(group(3)!) is not a month.")) }
        var year = Int(group(4)!)!
        if group(4)!.count == 2 { year += year < 50 ? 2000 : 1900 } // RFC 2822 section 4.3
        var offset = 0
        if let z = group(8) {
            if z.first == "+" || z.first == "-" {
                let d = z.dropFirst()
                offset = (z.first == "-" ? -1 : 1) * (Int(d.prefix(2))! * 3600 + Int(d.suffix(2))! * 60)
            } else if let h = zoneNames[z.uppercased()] {
                offset = h * 3600
            } else {
                return .failure(ParseError("Unknown time zone \(z)."))
            }
        }
        let result = build(year: year, month: month + 1, day: Int(group(2)!)!, hour: Int(group(5)!)!, minute: Int(group(6)!)!,
                           second: Int(group(7) ?? "0")!, nanos: 0, offset: offset, zone: .gmt, readAs: "RFC 2822")
        if case .success(let p) = result, let weekday = group(1) {
            let actual = Formats.string(p.instant.date, "EEE", zone: TimeZone(secondsFromGMT: offset)!)
            if actual.lowercased() != weekday.lowercased() {
                return .failure(ParseError("That date is a \(actual), not a \(weekday)."))
            }
        }
        return result
    }

    static func build(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, nanos: Int64,
                      offset: Int?, zone: TimeZone, readAs: String) -> Result<Parsed, ParseError> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? zone
        // Leap seconds are not representable; 23:59:60 reads as the next second.
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: min(second, 59))
        // 24:00:00 is allowed and means midnight at the end of the day.
        let endOfDay = hour == 24 && minute == 0 && second == 0
        guard (1...12).contains(month), hour <= 23 || endOfDay, minute <= 59, second <= 60, let date = cal.date(from: comps),
              endOfDay || cal.component(.day, from: date) == day else {
            return .failure(ParseError("\(String(format: "%04d-%02d-%02d", year, month, day)) is not a real date."))
        }
        let base = Int64(date.timeIntervalSince1970.rounded()) + (second == 60 ? 1 : 0)
        return .success(Parsed(instant: Instant(seconds: base, nanos: nanos), readAs: readAs))
    }
}

struct ParseError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

enum Formats {
    static func string(_ date: Date, _ format: String, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = zone
        f.dateFormat = format
        return f.string(from: date)
    }

    /// ISO 8601 with as many fraction digits as the instant needs (0, 3, 6 or 9).
    static func iso(_ i: Instant, zone: TimeZone) -> String {
        var fraction = ""
        if i.nanos != 0 {
            var digits = String(format: "%09lld", i.nanos)
            while digits.hasSuffix("000") { digits.removeLast(3) }
            fraction = "." + digits
        }
        let base = string(Date(timeIntervalSince1970: Double(i.seconds)), "yyyy-MM-dd'T'HH:mm:ss", zone: zone)
        // "xxxxx" adds seconds only for historical local mean time offsets such as -03:30:52.
        let suffix = ["GMT", "UTC"].contains(zone.identifier) ? "Z" : string(i.date, "xxxxx", zone: zone)
        return base + fraction + suffix
    }

    static func rfc2822(_ i: Instant, zone: TimeZone) -> String {
        string(Date(timeIntervalSince1970: Double(i.seconds)), "EEE, dd MMM yyyy HH:mm:ss Z", zone: zone)
    }

    static func human(_ i: Instant, zone: TimeZone) -> String {
        string(Date(timeIntervalSince1970: Double(i.seconds)), "EEE d MMM yyyy, HH:mm:ss", zone: zone)
    }

    static func relative(_ i: Instant, now: Date) -> String {
        let delta = i.date.timeIntervalSince(now)
        let a = abs(delta)
        if a < 1 { return "now" }
        let units: [(Double, String)] = [(365.2425 * 86400, "year"), (30.436875 * 86400, "month"), (7 * 86400, "week"),
                                         (86400, "day"), (3600, "hour"), (60, "minute"), (1, "second")]
        let (size, name) = units.first { a >= $0.0 }!
        let n = Int((a / size).rounded(.down))
        let phrase = "\(n) \(name)\(n == 1 ? "" : "s")"
        return delta < 0 ? "\(phrase) ago" : "in \(phrase)"
    }

    static func rows(_ i: Instant, zone: TimeZone, now: Date) -> [(String, String)] {
        func v(_ per: Int64) -> String { i.value(perSecond: per).map(String.init) ?? "out of range" }
        var rows = [("Seconds", v(1)), ("Milliseconds", v(1000)), ("Microseconds", v(1_000_000)), ("Nanoseconds", v(1_000_000_000)),
                    ("ISO 8601 UTC", iso(i, zone: .gmt)), ("ISO 8601 local", iso(i, zone: .current)),
                    ("RFC 2822", rfc2822(i, zone: .gmt)), ("Local", human(i, zone: .current)), ("UTC", human(i, zone: .gmt))]
        if zone.identifier != TimeZone.current.identifier, !["GMT", "UTC"].contains(zone.identifier) {
            rows.append((zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier,
                         human(i, zone: zone)))
            rows.append(("ISO 8601 zone", iso(i, zone: zone)))
        }
        rows.append(("Relative", relative(i, now: now)))
        return rows
    }
}

@MainActor
final class EpochModel: ObservableObject {
    @Published var input = ""
    @Published private(set) var now = Date()
    @AppStorage("unit") var unitRaw = EpochUnit.auto.rawValue
    @AppStorage("zone") var zoneID = "America/New_York"

    private var timer: Timer?

    static let zones = ["America/Los_Angeles", "America/Denver", "America/Chicago", "America/New_York", "America/Sao_Paulo",
                        "Europe/London", "Europe/Paris", "Europe/Berlin", "Europe/Athens", "Europe/Moscow", "Africa/Johannesburg",
                        "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore", "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney",
                        "Pacific/Auckland"]

    init() {
        input = String(Int64(Date().timeIntervalSince1970))
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    var unit: EpochUnit {
        get { EpochUnit(rawValue: unitRaw) ?? .auto }
        set { unitRaw = newValue.rawValue }
    }

    var zone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }

    var parsed: Result<Parsed, ParseError> { EpochParser.parse(input, unit: unit, zone: .current, now: now) }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Views

struct EpochView: View {
    @EnvironmentObject var model: EpochModel

    var body: some View {
        VStack(spacing: 0) {
            NowHeader()
            Divider().opacity(0.5)
            VStack(spacing: 10) {
                InputField()
                ResultList()
            }
            .padding(14)
            Divider().opacity(0.5)
            PanelFooter(name: "Epoch") {
                Picker("Extra Time Zone", selection: $model.zoneID) {
                    ForEach(EpochModel.zones, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                Divider()
                Button("Convert Now") { model.input = String(Int64(Date().timeIntervalSince1970)) }
                Button("Convert Clipboard") { model.input = NSPasteboard.general.string(forType: .string) ?? "" }
            }
        }
        .frame(width: 400)
    }
}

struct NowHeader: View {
    @EnvironmentObject var model: EpochModel
    @State private var copied: String?

    var body: some View {
        let instant = Instant(model.now)
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Unix time now").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                copyable(String(instant.seconds), size: 32, weight: .bold)
                copyable(String(instant.value(perSecond: 1000) ?? 0) + " ms", value: String(instant.value(perSecond: 1000) ?? 0), size: 13, weight: .medium)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.snappy) { model.input = String(instant.seconds) }
            } label: {
                Label("Use", systemImage: "arrow.down")
            }
            .buttonStyle(PillButtonStyle([Color(red: 0.45, green: 0.72, blue: 1), Color(red: 0.12, green: 0.3, blue: 0.85)]))
            .help("Convert the current time")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func copyable(_ text: String, value: String? = nil, size: CGFloat, weight: Font.Weight) -> some View {
        Button {
            model.copy(value ?? text)
            withAnimation { copied = value ?? text }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = nil } }
        } label: {
            HStack(spacing: 6) {
                Text(text).font(.system(size: size, weight: weight, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                if copied == (value ?? text) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(.green)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Click to copy")
    }
}

struct InputField: View {
    @EnvironmentObject var model: EpochModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Timestamp, ISO 8601 or RFC 2822", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                Button { model.input = NSPasteboard.general.string(forType: .string) ?? "" } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Paste from clipboard")
                if !model.input.isEmpty {
                    Button { model.input = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).help("Clear")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            HStack(spacing: 4) {
                ForEach(EpochUnit.allCases) { unit in
                    let selected = model.unit == unit
                    Button { withAnimation(.snappy) { model.unit = unit } } label: {
                        Text(unit.short)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? .white : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(selected ? AnyShapeStyle(Color.accentGradient) : AnyShapeStyle(.quaternary.opacity(0.4))))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                switch model.parsed {
                case .success(let p):
                    Text("Read as \(p.readAs)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                case .failure(let e):
                    Text(e.message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }
}

struct ResultList: View {
    @EnvironmentObject var model: EpochModel

    var body: some View {
        Group {
            switch model.parsed {
            case .success(let p):
                VStack(spacing: 3) {
                    ForEach(Formats.rows(p.instant, zone: model.zone, now: model.now), id: \.0) { label, value in
                        ResultRow(label: label, value: value)
                    }
                }
            case .failure:
                VStack(spacing: 8) {
                    Image(systemName: "clock.badge.questionmark").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Try 1700000000, 1700000000000,\n2024-02-29T12:00:00Z or Tue, 14 Nov 2023 22:13:20 GMT.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            }
        }
    }
}

struct ResultRow: View {
    @EnvironmentObject var model: EpochModel
    let label: String
    let value: String
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            model.copy(value)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { copied = false } }
        } label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(value).font(.system(size: 12, design: .monospaced)).monospacedDigit()
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .opacity(hovering || copied ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.25)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy \(value)")
        .onHover { hovering = $0 }
    }
}

extension Color {
    static let accentGradient = LinearGradient(colors: [Color(red: 0.45, green: 0.72, blue: 1), Color(red: 0.12, green: 0.3, blue: 0.85)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a clock face whose hand sweeps round into a looping arrow

func appIcon() -> NSBitmapImageRep {
    render(0x93C5FD, 0x1D4ED8) { ctx in
        let c = CGPoint(x: 512, y: 512)
        // Dial.
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 34, alpha: 0.3)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 250, y: c.y - 250, width: 500, height: 500))
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - 250, y: c.y - 250, width: 500, height: 500))
        ctx.clip()
        radial([rgb(0xFFFFFF), rgb(0xDBEAFE)], center: CGPoint(x: c.x, y: c.y + 80), radius: 300, in: ctx)
        ctx.restoreGState()
        // Minute ticks.
        ctx.setLineCap(.round)
        for i in 0..<60 {
            let a = CGFloat(i) / 60 * 2 * .pi
            let major = i % 5 == 0
            ctx.setStrokeColor(rgb(major ? 0x1E3A8A : 0x93C5FD).cgColor)
            ctx.setLineWidth(major ? 14 : 6)
            let inner: CGFloat = major ? 186 : 204
            ctx.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 222, y: c.y + sin(a) * 222))
            ctx.strokePath()
        }
        // Looping arrow around the dial: time counted from an origin.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 14, alpha: 0.25)
        ctx.setStrokeColor(rgb(0xFBBF24).cgColor)
        ctx.setLineWidth(40)
        let r: CGFloat = 318, start = CGFloat.pi * 0.62, end = start - 1.55 * .pi
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
        ctx.strokePath()
        let tip = CGPoint(x: c.x + cos(end) * r, y: c.y + sin(end) * r)
        let dir = CGPoint(x: sin(end), y: -cos(end)) // Clockwise tangent.
        let normal = CGPoint(x: cos(end), y: sin(end))
        ctx.setFillColor(rgb(0xFBBF24).cgColor)
        ctx.move(to: CGPoint(x: tip.x + dir.x * 62, y: tip.y + dir.y * 62))
        ctx.addLine(to: CGPoint(x: tip.x + normal.x * 52, y: tip.y + normal.y * 52))
        ctx.addLine(to: CGPoint(x: tip.x - normal.x * 52, y: tip.y - normal.y * 52))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
        // Hands.
        ctx.setStrokeColor(rgb(0x1E3A8A).cgColor)
        ctx.setLineWidth(30)
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + 96, y: c.y + 96))
        ctx.strokePath()
        ctx.setLineWidth(20)
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x - 40, y: c.y + 168))
        ctx.strokePath()
        ctx.setFillColor(rgb(0x2563EB).cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y - 30, width: 60, height: 60))
    }
}
