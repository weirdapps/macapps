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
    let model = CronModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "calendar.badge.clock", accessibilityLabel: "Cron") {
            CronView().environmentObject(self.model)
        }
    }
}

// MARK: - Model

enum FieldKind: Int, CaseIterable {
    case second, minute, hour, dayOfMonth, month, dayOfWeek

    var name: String {
        switch self {
        case .second: "Second"
        case .minute: "Minute"
        case .hour: "Hour"
        case .dayOfMonth: "Day"
        case .month: "Month"
        case .dayOfWeek: "Weekday"
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .second, .minute: 0...59
        case .hour: 0...23
        case .dayOfMonth: 1...31
        case .month: 1...12
        case .dayOfWeek: 0...7 // 7 is Sunday too.
        }
    }

    var names: [String] {
        switch self {
        case .month: ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        case .dayOfWeek: ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        default: []
        }
    }
}

struct FieldError: Error, Equatable {
    let field: FieldKind?
    let message: String
}

struct Field: Equatable {
    let kind: FieldKind
    let text: String
    let values: Set<Int>
    /// Vixie cron treats a field that starts with "*" as unrestricted when combining day of month and day of week.
    var star: Bool { text.hasPrefix("*") || text.hasPrefix("?") }
}

struct CronExpression: Equatable {
    let fields: [FieldKind: Field]
    let hasSeconds: Bool

    static let macros = ["@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *", "@weekly": "0 0 * * 0",
                         "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@hourly": "0 * * * *"]

    static func parse(_ raw: String) -> Result<CronExpression, FieldError> {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("@") {
            guard let expanded = macros[text.lowercased()] else {
                return .failure(FieldError(field: nil, message: "Unknown shortcut \(text). Try @hourly, @daily, @weekly, @monthly or @yearly."))
            }
            text = expanded
        }
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 || parts.count == 6 else {
            return .failure(FieldError(field: nil, message: "Expected 5 fields (minute hour day month weekday) or 6 with seconds first; found \(parts.count)."))
        }
        let kinds: [FieldKind] = parts.count == 6 ? FieldKind.allCases : Array(FieldKind.allCases.dropFirst())
        var fields: [FieldKind: Field] = [:]
        for (kind, part) in zip(kinds, parts) {
            switch parseField(part, kind) {
            case .success(let f): fields[kind] = f
            case .failure(let e): return .failure(e)
            }
        }
        if parts.count == 5 { fields[.second] = Field(kind: .second, text: "0", values: [0]) }
        return .success(CronExpression(fields: fields, hasSeconds: parts.count == 6))
    }

    static func parseField(_ text: String, _ kind: FieldKind) -> Result<Field, FieldError> {
        func fail(_ m: String) -> Result<Field, FieldError> { .failure(FieldError(field: kind, message: m)) }
        func number(_ s: Substring) -> Int? {
            if let n = Int(s) { return n }
            return kind.names.firstIndex(of: s.lowercased()).map { kind == .month ? $0 + 1 : $0 }
        }
        let r = kind.range
        var values = Set<Int>()
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard !item.isEmpty else { return fail("An empty item in the list.") }
            let pieces = item.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { return fail("\u{201C}\(item)\u{201D} has more than one step.") }
            var step = 1
            if pieces.count == 2 {
                guard let s = Int(pieces[1]), s > 0 else { return fail("The step in \u{201C}\(item)\u{201D} must be a whole number above 0.") }
                step = s
            }
            let base = pieces[0]
            var lo: Int, hi: Int
            if base == "*" || base == "?" {
                lo = r.lowerBound
                hi = kind == .dayOfWeek ? 6 : r.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = number(base[..<dash]), let b = number(base[base.index(after: dash)...]) else {
                    return fail("\u{201C}\(base)\u{201D} is not a valid range.")
                }
                lo = a; hi = b
                guard lo <= hi else { return fail("The range \(base) runs backwards.") }
            } else {
                guard let a = number(base) else { return fail("\u{201C}\(base)\u{201D} is not a valid \(kind.name.lowercased()).") }
                lo = a
                // "a/n" means from a to the end in steps of n.
                hi = pieces.count == 2 ? (kind == .dayOfWeek ? 6 : r.upperBound) : a
            }
            guard r.contains(lo), r.contains(hi) else {
                let shown = kind == .dayOfWeek ? "0 to 7" : "\(r.lowerBound) to \(r.upperBound)"
                return fail("\(kind.name) must be \(shown); \(lo < r.lowerBound || lo > r.upperBound ? lo : hi) is out of range.")
            }
            for v in stride(from: lo, through: hi, by: step) { values.insert(kind == .dayOfWeek && v == 7 ? 0 : v) }
        }
        return .success(Field(kind: kind, text: text, values: values))
    }

    func field(_ k: FieldKind) -> Field { fields[k]! }

    /// Whether the calendar day matches, with Vixie cron's rule: when both day fields are restricted, either may match.
    func dayMatches(day: Int, weekday: Int) -> Bool {
        let dom = field(.dayOfMonth), dow = field(.dayOfWeek)
        let domHit = dom.values.contains(day), dowHit = dow.values.contains(weekday)
        if dom.star || dow.star { return domHit && dowHit }
        return domHit || dowHit
    }

    /// The next `count` run times strictly after `start`, searching up to eight years ahead.
    func nextRuns(after start: Date, count: Int, calendar: Calendar) -> [Date] {
        var cal = calendar
        cal.firstWeekday = 1
        var runs: [Date] = []
        var t = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down) + 1)
        let limit = cal.date(byAdding: .year, value: 8, to: start)!
        let sec = field(.second).values, min = field(.minute).values, hour = field(.hour).values, month = field(.month).values
        while runs.count < count && t < limit {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: t)
            if !month.contains(c.month!) {
                t = cal.date(from: DateComponents(year: c.year, month: c.month! + 1, day: 1))!
                continue
            }
            if !dayMatches(day: c.day!, weekday: c.weekday! - 1) {
                t = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t))!
                continue
            }
            if !hour.contains(c.hour!) {
                t = nextBoundary(t, .hour, cal)
                continue
            }
            if !min.contains(c.minute!) {
                t = nextBoundary(t, .minute, cal)
                continue
            }
            if !sec.contains(c.second!) {
                let next = sec.filter { $0 > c.second! }.min()
                t = next.map { t.addingTimeInterval(TimeInterval($0 - c.second!)) } ?? nextBoundary(t, .minute, cal)
                continue
            }
            // When clocks go back, a wall time repeats. Like Vixie cron, run fixed-time jobs once; jobs that
            // run every hour still run in both copies of the hour.
            let wall = DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second)
            if hour.count == 24 || !runs.contains(where: { cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) == wall }) {
                runs.append(t)
            }
            t = t.addingTimeInterval(1)
        }
        return runs
    }

    /// The start of the next hour or minute, measured in real time so DST changes do not loop.
    private func nextBoundary(_ t: Date, _ unit: Calendar.Component, _ cal: Calendar) -> Date {
        let size: TimeInterval = unit == .hour ? 3600 : 60
        let c = cal.dateComponents([.minute, .second], from: t)
        let into = unit == .hour ? TimeInterval(c.minute! * 60 + c.second!) : TimeInterval(c.second!)
        return t.addingTimeInterval(size - into)
    }
}

/// Plain English for a parsed expression.
enum Describer {
    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    /// A step pattern that runs to the end of the field, such as */15 or 5/10: (step, start).
    static func stride(_ values: Set<Int>, _ full: ClosedRange<Int>) -> (step: Int, start: Int)? {
        let v = values.sorted()
        guard v.count >= 2, v[1] - v[0] > 1, v.last! + (v[1] - v[0]) > full.upperBound, v[0] - (v[1] - v[0]) < full.lowerBound else { return nil }
        let step = v[1] - v[0]
        return zip(v, v.dropFirst()).allSatisfy { $1 - $0 == step } ? (step, v[0]) : nil
    }

    /// Sorted values as a list, with three or more consecutive values as a range: "1 through 5, 9 and 17".
    static func runs(_ values: Set<Int>, name: (Int) -> String) -> String {
        let v = values.sorted()
        var out: [String] = []
        var i = 0
        while i < v.count {
            var j = i
            while j + 1 < v.count && v[j + 1] == v[j] + 1 { j += 1 }
            if j - i >= 2 { out.append("\(name(v[i])) through \(name(v[j]))") } else { out += (i...j).map { name(v[$0]) } }
            i = j + 1
        }
        return list(out)
    }

    static func describe(_ e: CronExpression) -> String {
        let sec = e.field(.second).values, min = e.field(.minute).values, hour = e.field(.hour).values
        let showSeconds = e.hasSeconds && sec != [0]
        var sentence: [String] = []

        if min.count == 1, (1...6).contains(hour.count), !showSeconds || sec.count == 1 {
            // A handful of exact times.
            let m = min.first!, s = sec.first!
            sentence.append("At " + list(hour.sorted().map { showSeconds ? String(format: "%02d:%02d:%02d", $0, m, s) : String(format: "%02d:%02d", $0, m) }))
        } else {
            var pieces: [String] = []
            if showSeconds {
                if sec.count == 60 { pieces.append("every second") }
                else if let st = stride(sec, 0...59) { pieces.append("every \(st.step) seconds" + (st.start > 0 ? " from second \(st.start)" : "")) }
                else { pieces.append("at second\(sec.count == 1 ? "" : "s") \(runs(sec) { "\($0)" })") }
            }
            if min.count == 60 {
                if !showSeconds { pieces.append("every minute") }
            } else if let st = stride(min, 0...59) {
                pieces.append("every \(st.step) minutes" + (st.start > 0 ? " from minute \(st.start)" : ""))
            } else if min == [0] {
                pieces.append("on the hour")
            } else {
                pieces.append("at minute\(min.count == 1 ? "" : "s") \(runs(min) { "\($0)" })" + (hour.count == 24 ? " past every hour" : ""))
            }
            if hour.count < 24 {
                if let st = stride(hour, 0...23) {
                    pieces.append("every \(st.step) hours" + (st.start > 0 ? " from \(String(format: "%02d:00", st.start))" : ""))
                } else {
                    pieces.append("during hour\(hour.count == 1 ? "" : "s") \(runs(hour) { String(format: "%02d", $0) })")
                }
            } else if min == [0], !showSeconds {
                pieces[pieces.count - 1] = "every hour, on the hour"
            }
            let joined = pieces.joined(separator: ", ")
            sentence.append(joined.prefix(1).uppercased() + joined.dropFirst())
        }

        let dom = e.field(.dayOfMonth), dow = e.field(.dayOfWeek)
        let domText: String = {
            if let st = stride(dom.values, 1...31) { return "on every \(ordinal(st.step)) day of the month" + (st.start > 1 ? " from the \(ordinal(st.start))" : "") }
            return "on the \(runs(dom.values) { ordinal($0) }) of the month"
        }()
        let dowText = runs(dow.values) { dayNames[$0] }
        switch (dom.values.count < 31, dow.values.count < 7) {
        case (true, true):
            // Vixie cron: two restricted day fields mean either day; a field written with * makes it both.
            sentence.append(dom.star || dow.star ? "\(domText), only if it is a \(dowText)" : "\(domText) and on every \(dowText)")
        case (true, false): sentence.append(domText)
        case (false, true): sentence.append("on " + dowText)
        case (false, false): break
        }

        let mon = e.field(.month).values
        if mon.count < 12 { sentence.append("in " + runs(mon) { monthNames[$0 - 1] }) }
        return sentence.joined(separator: " ") + "."
    }
}

struct Preset: Identifiable {
    let name: String
    let expression: String
    var id: String { expression }

    static let all = [
        Preset(name: "Every minute", expression: "* * * * *"),
        Preset(name: "Every 5 minutes", expression: "*/5 * * * *"),
        Preset(name: "Every hour", expression: "0 * * * *"),
        Preset(name: "Every day at midnight", expression: "0 0 * * *"),
        Preset(name: "Weekdays at 09:00", expression: "0 9 * * 1-5"),
        Preset(name: "Every Sunday", expression: "0 0 * * 0"),
        Preset(name: "First of the month", expression: "0 0 1 * *"),
        Preset(name: "Every quarter", expression: "0 0 1 */3 *"),
        Preset(name: "Every year", expression: "0 0 1 1 *"),
    ]
}

@MainActor
final class CronModel: ObservableObject {
    @AppStorage("expression") var expression = "30 9 * * 1-5"
    @Published private(set) var now = Date()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    var parsed: Result<CronExpression, FieldError> { CronExpression.parse(expression) }

    func runs(_ e: CronExpression) -> [Date] { e.nextRuns(after: now, count: 10, calendar: .current) }
}

// MARK: - Views

struct CronView: View {
    @EnvironmentObject var model: CronModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Cron").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Menu {
                    ForEach(Preset.all) { p in
                        Button("\(p.name)    \(p.expression)") { model.expression = p.expression }
                    }
                } label: {
                    Label("Presets", systemImage: "list.bullet").font(.system(size: 12, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            VStack(spacing: 10) {
                ExpressionField()
                FieldStrip()
                Summary()
                RunList()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            Divider().opacity(0.5)
            PanelFooter(name: "Cron") {
                Button("Paste Expression") { model.expression = NSPasteboard.general.string(forType: .string) ?? "" }
                Button("Copy Expression") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.expression, forType: .string)
                }
            }
        }
        .frame(width: 380)
    }
}

struct ExpressionField: View {
    @EnvironmentObject var model: CronModel

    var body: some View {
        let error: Bool = if case .failure = model.parsed { true } else { false }
        HStack(spacing: 8) {
            TextField("* * * * *", text: $model.expression)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
            Button { model.expression = NSPasteboard.general.string(forType: .string) ?? "" } label: { Image(systemName: "doc.on.clipboard") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Paste from clipboard")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(error ? 0.7 : 0), lineWidth: 1.5))
    }
}

/// One cell per field, red where that field is wrong.
struct FieldStrip: View {
    @EnvironmentObject var model: CronModel

    var body: some View {
        let parts = model.expression.trimmingCharacters(in: .whitespaces).hasPrefix("@") ? [] :
            model.expression.split(whereSeparator: \.isWhitespace).map(String.init)
        let kinds: [FieldKind] = parts.count == 6 ? FieldKind.allCases : Array(FieldKind.allCases.dropFirst())
        let failing: FieldKind? = if case .failure(let e) = model.parsed { e.field } else { nil }
        HStack(spacing: 4) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { i, kind in
                VStack(spacing: 2) {
                    Text(i < parts.count ? parts[i] : "?")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(kind.name).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(failing == kind ? AnyShapeStyle(Color.orange.opacity(0.22)) : AnyShapeStyle(.quaternary.opacity(0.3))))
            }
        }
        .animation(.snappy(duration: 0.2), value: failing)
    }
}

struct Summary: View {
    @EnvironmentObject var model: CronModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            switch model.parsed {
            case .success(let e):
                Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentGradient).font(.system(size: 16))
                Text(Describer.describe(e)).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    if let field = error.field { Text(field.name).font(.system(size: 11, weight: .bold)).foregroundStyle(.orange) }
                    Text(error.message).font(.system(size: 12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentTint.opacity(0.1)))
    }
}

struct RunList: View {
    @EnvironmentObject var model: CronModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Next runs, \(TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier)")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if case .success(let e) = model.parsed {
                let runs = model.runs(e)
                if runs.isEmpty {
                    Label("This schedule never runs, for example the 31st of a month that is too short.", systemImage: "calendar.badge.exclamationmark")
                        .font(.system(size: 12)).foregroundStyle(.orange).padding(.vertical, 8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(Array(runs.enumerated()), id: \.offset) { i, date in
                            RunRow(index: i, date: date, now: model.now, seconds: e.hasSeconds)
                        }
                    }
                }
            } else {
                Text("Fix the expression to see when it runs.").font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
    }
}

struct RunRow: View {
    let index: Int
    let date: Date
    let now: Date
    let seconds: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.tertiary).frame(width: 16)
            Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                .font(.system(size: 12, weight: .medium))
            Text(seconds ? date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                         : date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            Spacer()
            Text(date, format: .relative(presentation: .named))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(index == 0 ? 0.45 : hovering ? 0.35 : 0.15)))
        .onHover { hovering = $0 }
    }
}

extension Color {
    static let accentTint = Color(red: 0.06, green: 0.6, blue: 0.43)
    static let accentGradient = LinearGradient(colors: [Color(red: 0.43, green: 0.9, blue: 0.72), Color(red: 0.02, green: 0.47, blue: 0.34)],
                                               startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: a calendar page whose grid has a repeating pattern of marked days, and a small clock badge

func appIcon() -> NSBitmapImageRep {
    render(0x6EE7B7, 0x047857) { ctx in
        let page = CGRect(x: 230, y: 210, width: 564, height: 560)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.3)
        ctx.addPath(roundedRect(page, 64))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(page, 64))
        ctx.clip()
        ctx.clip(to: CGRect(x: page.minX, y: page.maxY - 128, width: page.width, height: 128))
        gradient([rgb(0x10B981), rgb(0x059669)], from: CGPoint(x: 0, y: page.maxY), to: CGPoint(x: 0, y: page.maxY - 130), in: ctx)
        ctx.restoreGState()
        // Rings binding the page.
        for x in [page.minX + 150, page.maxX - 150] {
            ctx.setFillColor(rgb(0x064E3B).cgColor)
            ctx.addPath(roundedRect(CGRect(x: x - 18, y: page.maxY - 60, width: 36, height: 110), 18))
            ctx.fillPath()
        }
        // Day grid: every other column marked, the cron pattern.
        let cols = 5, rows = 4
        let cell: CGFloat = 78, gap: CGFloat = 20
        let gridW = CGFloat(cols) * cell + CGFloat(cols - 1) * gap
        let x0 = page.midX - gridW / 2, y0 = page.minY + 50
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(x: x0 + CGFloat(c) * (cell + gap), y: y0 + CGFloat(r) * (cell + gap) - 6, width: cell, height: cell)
                let marked = c % 2 == 0 && r % 2 == 1 || c % 2 == 1 && r % 2 == 0 && c == 3
                ctx.addPath(roundedRect(rect, 20))
                ctx.setFillColor((marked ? rgb(0x10B981) : rgb(0xD1FAE5)).cgColor)
                ctx.fillPath()
            }
        }
        // Clock badge.
        let b = CGPoint(x: 760, y: 280)
        ctx.saveGState()
        shadow(ctx, y: -8, blur: 20, alpha: 0.3)
        ctx.setFillColor(rgb(0x064E3B).cgColor)
        ctx.fillEllipse(in: CGRect(x: b.x - 110, y: b.y - 110, width: 220, height: 220))
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0xA7F3D0).cgColor)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        ctx.move(to: b); ctx.addLine(to: CGPoint(x: b.x, y: b.y + 62))
        ctx.move(to: b); ctx.addLine(to: CGPoint(x: b.x + 48, y: b.y - 20))
        ctx.strokePath()
    }
}
