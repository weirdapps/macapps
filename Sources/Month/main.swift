import AppKit
import Combine
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
    private var cancellables: Set<AnyCancellable> = []
    let model = MonthModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "calendar", accessibilityLabel: "Month") {
            MonthView().environmentObject(self.model)
        }
        model.$today
            .sink { [weak self] day in self?.status.item.button?.image = MenuGlyph.image(day: Cal.iso.component(.day, from: day)) }
            .store(in: &cancellables)
    }
}

// MARK: - Model

/// Calendar maths, kept pure so it can be checked from a script.
enum Cal {
    /// ISO 8601: weeks start on Monday and week 1 holds the year's first Thursday.
    static let iso: Calendar = {
        var c = Calendar(identifier: .iso8601)
        c.locale = .current
        c.timeZone = .current
        return c
    }()

    static func week(_ date: Date) -> Int { iso.component(.weekOfYear, from: date) }

    static func dayOfYear(_ date: Date) -> Int { iso.ordinality(of: .day, in: .year, for: date) ?? 1 }

    static func daysInYear(_ date: Date) -> Int { iso.range(of: .day, in: .year, for: date)?.count ?? 365 }

    /// The first of the month containing `date`.
    static func monthStart(_ date: Date) -> Date {
        iso.date(from: iso.dateComponents([.year, .month], from: date)) ?? date
    }

    /// Six rows of seven days, Monday first, covering the month that starts at `start`.
    static func grid(_ start: Date) -> [[Date]] {
        let weekday = iso.component(.weekday, from: start) // 1 = Sunday
        let lead = (weekday + 5) % 7
        let first = iso.date(byAdding: .day, value: -lead, to: start)!
        return (0..<6).map { row in
            (0..<7).map { col in iso.date(byAdding: .day, value: row * 7 + col, to: first)! }
        }
    }
}

@MainActor
final class MonthModel: ObservableObject {
    @Published var shown = Cal.monthStart(Date())
    @Published var selected = Cal.iso.startOfDay(for: Date())
    @Published private(set) var today = Cal.iso.startOfDay(for: Date())
    private var timer: Timer?

    init() {
        // A light poll catches midnight, sleep and time zone changes alike.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshToday() }
        }
    }

    private func refreshToday() {
        let now = Cal.iso.startOfDay(for: Date())
        guard now != today else { return }
        if selected == today { selected = now }
        today = now
    }

    func move(_ months: Int) {
        shown = Cal.iso.date(byAdding: .month, value: months, to: shown) ?? shown
    }

    func goToday() {
        shown = Cal.monthStart(today)
        selected = today
    }

    var isCurrentMonth: Bool { shown == Cal.monthStart(today) }
}

// MARK: - Views

struct MonthView: View {
    @EnvironmentObject var model: MonthModel
    @State private var direction = 1

    var body: some View {
        VStack(spacing: 0) {
            header
            MonthGrid()
                .id(model.shown)
                .transition(.asymmetric(insertion: .move(edge: direction > 0 ? .trailing : .leading).combined(with: .opacity),
                                        removal: .opacity))
                .padding(.horizontal, 12)
            DayDetail()
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Month") {
                Button("Go to Today") { withAnimation(.snappy) { model.goToday() } }.keyboardShortcut("t")
            }
        }
        .frame(width: 320)
        .clipped()
        .background {
            Group {
                Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(model.shown.formatted(.dateTime.month(.wide)))
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(model.shown.formatted(.dateTime.year()))
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(Accent.gradient)
            Spacer()
            if !model.isCurrentMonth {
                Button("Today") { withAnimation(.snappy) { model.goToday() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Accent.solid)
                    .transition(.opacity)
            }
            GlassIconButton("chevron.left", help: "Previous month") { step(-1) }
            GlassIconButton("chevron.right", help: "Next month") { step(1) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func step(_ d: Int) {
        direction = d
        withAnimation(.snappy(duration: 0.28)) { model.move(d) }
    }
}

struct MonthGrid: View {
    @EnvironmentObject var model: MonthModel

    private var weekdays: [String] {
        // veryShortWeekdaySymbols starts on Sunday; rotate to Monday first.
        let s = Cal.iso.veryShortStandaloneWeekdaySymbols
        return Array(s[1...]) + [s[0]]
    }

    var body: some View {
        let rows = Cal.grid(model.shown)
        let month = Cal.iso.component(.month, from: model.shown)
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("Wk").frame(width: 30)
                ForEach(Array(weekdays.enumerated()), id: \.offset) { i, d in
                    Text(d).frame(maxWidth: .infinity).foregroundStyle(i >= 5 ? .tertiary : .secondary)
                }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
            ForEach(rows, id: \.first) { row in
                HStack(spacing: 0) {
                    Text("\(Cal.week(row[0]))")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Accent.solid.opacity(0.8))
                        .frame(width: 30)
                    ForEach(row, id: \.self) { day in
                        DayCell(day: day, inMonth: Cal.iso.component(.month, from: day) == month)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct DayCell: View {
    @EnvironmentObject var model: MonthModel
    let day: Date
    let inMonth: Bool
    @State private var hovering = false

    var body: some View {
        let isToday = day == model.today
        let isSelected = day == model.selected
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                model.selected = day
                if !inMonth { model.shown = Cal.monthStart(day) }
            }
        } label: {
            Text("\(Cal.iso.component(.day, from: day))")
                .font(.system(size: 13, weight: isToday ? .bold : .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .frame(width: 32, height: 32)
                .background {
                    if isToday {
                        Circle().fill(Accent.gradient).shadow(color: Accent.solid.opacity(0.4), radius: 4, y: 1)
                    } else if hovering {
                        Circle().fill(.quaternary.opacity(0.8))
                    }
                }
                .overlay {
                    if isSelected && !isToday {
                        Circle().strokeBorder(Accent.solid, lineWidth: 1.5)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .onHover { hovering = $0 }
    }
}

struct DayDetail: View {
    @EnvironmentObject var model: MonthModel

    var body: some View {
        let day = model.selected
        let doy = Cal.dayOfYear(day)
        let total = Cal.daysInYear(day)
        let offset = Cal.iso.dateComponents([.day], from: model.today, to: day).day ?? 0
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(relative(offset))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            HStack(spacing: 8) {
                Stat(value: "\(doy)", label: "day of year")
                Stat(value: "\(Cal.week(day))", label: "ISO week")
                Stat(value: "\(total - doy)", label: "days left")
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.7))
                    Capsule().fill(Accent.gradient).frame(width: max(6, geo.size.width * CGFloat(doy) / CGFloat(total)))
                }
            }
            .frame(height: 5)
            .animation(.snappy, value: doy)
        }
    }

    private func relative(_ days: Int) -> String {
        switch days {
        case 0: "Today"
        case 1: "Tomorrow"
        case -1: "Yesterday"
        case let d where d > 0: "In \(d) days"
        default: "\(-days) days ago"
        }
    }
}

struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

enum Accent {
    static let solid = Color(red: 0.93, green: 0.23, blue: 0.27)
    static let gradient = LinearGradient(colors: [Color(red: 1, green: 0.42, blue: 0.38), Color(red: 0.86, green: 0.13, blue: 0.24)],
                                         startPoint: .top, endPoint: .bottom)
}

/// The menu bar glyph: a small calendar page with today's date punched out of it.
enum MenuGlyph {
    static func image(day: Int) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let body = CGRect(x: 1.5, y: 1.5, width: 15, height: 14.5)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(roundedRect(body, 3.2))
            ctx.fillPath()
            // Binding rings.
            for x in [5.5, 12.5] {
                ctx.addPath(roundedRect(CGRect(x: x - 1, y: 14, width: 2, height: 4), 1))
            }
            ctx.fillPath()
            // Punch the number out so it shows the menu bar through it.
            ctx.setBlendMode(.destinationOut)
            ctx.fill(CGRect(x: 1.5, y: 12.6, width: 15, height: 0.9))
            let text = NSAttributedString(string: "\(day)", attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.black,
            ])
            let t = text.size()
            text.draw(at: NSPoint(x: body.midX - t.width / 2, y: 6.6 - t.height / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Month, today is the \(day)"
        return image
    }
}

// MARK: - Icon

//: a tear-off calendar page with a ringed date

func appIcon() -> NSBitmapImageRep {
    render(0xF5F7FB, 0xC3CCDA) { ctx in
        let page = CGRect(x: 212, y: 196, width: 600, height: 600)
        ctx.saveGState()
        shadow(ctx, y: -22, blur: 40, alpha: 0.3)
        ctx.addPath(roundedRect(page, 70))
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(roundedRect(page, 70))
        ctx.clip()
        // Red header band.
        let band = CGRect(x: page.minX, y: page.maxY - 150, width: page.width, height: 150)
        ctx.saveGState()
        ctx.clip(to: band)
        gradient([rgb(0xFF6B61), rgb(0xDB2140)], from: CGPoint(x: 0, y: band.maxY), to: CGPoint(x: 0, y: band.minY), in: ctx)
        ctx.restoreGState()
        // Grid of days as soft dots, one row per week.
        let cols = 7, rows = 5
        let gx = page.minX + 70, gy = page.minY + 70
        let step = (page.width - 140) / CGFloat(cols - 1)
        let vstep: CGFloat = 84
        for r in 0..<rows {
            for c in 0..<cols {
                let p = CGPoint(x: gx + CGFloat(c) * step, y: gy + CGFloat(r) * vstep)
                let weekend = c >= 5
                ctx.setFillColor(rgb(weekend ? 0xF0B8BE : 0xC9D0DC).cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34))
            }
        }
        ctx.restoreGState()
        // Today, ringed.
        let today = CGPoint(x: gx + 3 * step, y: gy + 2 * vstep)
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 16, alpha: 0.35)
        ctx.setFillColor(rgb(0xE8304A).cgColor)
        ctx.fillEllipse(in: CGRect(x: today.x - 46, y: today.y - 46, width: 92, height: 92))
        ctx.restoreGState()
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: today.x - 15, y: today.y - 15, width: 30, height: 30))
        // Binding rings over the band.
        for x in [page.minX + 150, page.maxX - 150] {
            ctx.saveGState()
            shadow(ctx, y: -5, blur: 10, alpha: 0.3)
            ctx.addPath(roundedRect(CGRect(x: x - 22, y: page.maxY - 70, width: 44, height: 130), 22))
            ctx.setFillColor(rgb(0xE9EDF3).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}
