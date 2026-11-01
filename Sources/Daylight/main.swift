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
    let model = DaylightModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "sun.horizon", accessibilityLabel: "Daylight") {
            DaylightView().environmentObject(self.model)
        }
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        guard let next = model.nextEvent else {
            status.setSymbol("sun.horizon", label: "Daylight")
            status.setTitle("")
            return
        }
        status.setSymbol(next.rising ? "sunrise.fill" : "sunset.fill", label: next.rising ? "Next sunrise" : "Next sunset")
        status.setTitle(model.showInMenuBar ? model.time(next.date) : "")
    }
}

// MARK: - Model

@MainActor
final class DaylightModel: ObservableObject {
    @Published var place: Place { didSet { Storage.save(place, app: "Daylight", file: "place.json") } }
    @Published private(set) var now = Date()
    @AppStorage("showInMenuBar") var showInMenuBar = true
    private var timer: Timer?

    init() {
        // Snapshots show a fixed city, never the owner's saved place or time zone; didSet does not run in init, so nothing is saved.
        place = StatusPopover.isSnapshot ? Cities.all.first { $0.name == "London" }!
            : Storage.load(Place.self, app: "Daylight", file: "place.json") ?? Cities.guess
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    var today: Solar.Day { Solar.day(now, place: place) }
    var yesterday: Solar.Day { Solar.day(now.addingTimeInterval(-86400), place: place) }

    /// The next sunrise or sunset, looking into tomorrow if today's have passed.
    var nextEvent: (date: Date, rising: Bool)? {
        for offset in 0...1 {
            let d = Solar.day(now.addingTimeInterval(TimeInterval(offset) * 86400), place: place)
            let events: [(Solar.Crossing, Bool)] = [(d.sunrise, true), (d.sunset, false)]
            for case let (.at(date), rising) in events where date > now { return (date, rising) }
        }
        return nil
    }

    func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = place.zone
        return date.formatted(style)
    }

    func time(_ crossing: Solar.Crossing) -> String {
        switch crossing {
        case .at(let d): time(d)
        case .alwaysAbove: "None"
        case .alwaysBelow: "None"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    static func change(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let sign = s >= 0 ? "+" : "-"
        return "\(sign)\(abs(s) / 60)m \(String(format: "%02d", abs(s) % 60))s"
    }
}

// MARK: - Views

struct DaylightView: View {
    @EnvironmentObject var model: DaylightModel
    @State private var searching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.place.name).font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                GlassIconButton(searching ? "xmark" : "magnifyingglass", help: searching ? "Done" : "Choose a city") {
                    withAnimation(.snappy) { searching.toggle() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if searching {
                PlaceSearch { place in
                    model.place = place
                    withAnimation(.snappy) { searching = false }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                content.transition(.opacity)
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Daylight") {
                Toggle("Show Next Sunrise or Sunset in Menu Bar", isOn: $model.showInMenuBar)
            }
        }
        .frame(width: 350)
    }

    private var subtitle: String {
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        style.timeZone = model.place.zone
        // A snapshot never hints at the Mac's own zone.
        let local = StatusPopover.isSnapshot || model.place.zone.secondsFromGMT(for: model.now) == TimeZone.current.secondsFromGMT(for: model.now)
        return model.now.formatted(style) + (local ? "" : ", local time there")
    }

    private var content: some View {
        let day = model.today
        let delta = day.length - model.yesterday.length
        return VStack(spacing: 10) {
            SunArc(place: model.place, now: model.now)
                .frame(height: 118)
            HStack(spacing: 8) {
                BigTime(symbol: "sunrise.fill", label: "Sunrise", value: model.time(day.sunrise))
                BigTime(symbol: "sunset.fill", label: "Sunset", value: model.time(day.sunset))
            }
            VStack(spacing: 4) {
                InfoRow(symbol: "camera.aperture", color: .orange, label: "Golden hour",
                        value: "\(model.time(day.sunrise)) to \(model.time(day.goldenMorningEnd))",
                        second: "\(model.time(day.goldenEveningStart)) to \(model.time(day.sunset))")
                InfoRow(symbol: "moon.haze.fill", color: .indigo, label: "Civil twilight",
                        value: "dawn \(model.time(day.dawn))", second: "dusk \(model.time(day.dusk))")
                InfoRow(symbol: "sun.max.fill", color: .yellow, label: "Day length",
                        value: DaylightModel.duration(day.length),
                        second: "\(DaylightModel.change(delta)) since yesterday")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

struct BigTime: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 0) {
                Text(label).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct InfoRow: View {
    let symbol: String
    let color: Color
    let label: String
    let value: String
    let second: String
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .frame(width: 18)
            Text(label).font(.system(size: 12.5, weight: .medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(second).font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .onHover { hovering = $0 }
    }
}

/// The sun's altitude through the day, midnight to midnight, with the horizon and twilight bands.
struct SunArc: View {
    let place: Place
    let now: Date

    var body: some View {
        Canvas { ctx, size in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = place.zone
            let start = cal.startOfDay(for: now)
            let samples = (0...144).map { i -> (Double, Double) in
                let t = Double(i) / 144
                return (t, Solar.altitude(at: start.addingTimeInterval(t * 86400), place: place))
            }
            let top = max(20, samples.map(\.1).max() ?? 20) + 6
            let bottom = min(-12, samples.map(\.1).min() ?? -12) - 4
            func y(_ alt: Double) -> CGFloat { size.height * CGFloat((top - alt) / (top - bottom)) }
            func x(_ t: Double) -> CGFloat { size.width * CGFloat(t) }
            let horizonY = y(0)

            // Sky above the horizon, night below, with the twilight band between.
            let rect = CGRect(origin: .zero, size: size)
            let clip = Path(roundedRect: rect, cornerRadius: 12)
            ctx.clip(to: clip)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.45, green: 0.72, blue: 1).opacity(0.35), Color(red: 1, green: 0.78, blue: 0.5).opacity(0.3)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: horizonY)))
            ctx.fill(Path(CGRect(x: 0, y: horizonY, width: size.width, height: size.height - horizonY)),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.42, green: 0.32, blue: 0.75).opacity(0.35), Color(red: 0.08, green: 0.08, blue: 0.25).opacity(0.5)]),
                                           startPoint: CGPoint(x: 0, y: horizonY), endPoint: CGPoint(x: 0, y: size.height)))

            var curve = Path()
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: x(s.0), y: y(s.1))
                i == 0 ? curve.move(to: p) : curve.addLine(to: p)
            }
            // Daylight under the curve.
            var day = curve
            day.addLine(to: CGPoint(x: size.width, y: size.height))
            day.addLine(to: CGPoint(x: 0, y: size.height))
            day.closeSubpath()
            var aboveHorizon = ctx
            aboveHorizon.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: horizonY)))
            aboveHorizon.fill(day, with: .linearGradient(Gradient(colors: [Color.yellow.opacity(0.45), Color.orange.opacity(0.25)]),
                                                         startPoint: CGPoint(x: 0, y: y(top)), endPoint: CGPoint(x: 0, y: horizonY)))
            ctx.stroke(curve, with: .color(.orange.opacity(0.9)), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 0]))
            ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: horizonY)); $0.addLine(to: CGPoint(x: size.width, y: horizonY)) },
                       with: .color(.primary.opacity(0.35)), lineWidth: 1)

            // Hour ticks every six hours.
            for h in [6, 12, 18] {
                let tx = x(Double(h) / 24)
                ctx.stroke(Path { $0.move(to: CGPoint(x: tx, y: size.height - 6)); $0.addLine(to: CGPoint(x: tx, y: size.height)) },
                           with: .color(.secondary), lineWidth: 1)
                ctx.draw(Text(String(format: "%02d", h)).font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(.secondary),
                         at: CGPoint(x: tx, y: size.height - 13))
            }

            // The sun now.
            let t = now.timeIntervalSince(start) / 86400
            let alt = Solar.altitude(at: now, place: place)
            let sun = CGPoint(x: x(t), y: y(alt))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 14, y: sun.y - 14, width: 28, height: 28)), with: .color(.yellow.opacity(alt > 0 ? 0.3 : 0.12)))
            ctx.fill(Path(ellipseIn: CGRect(x: sun.x - 7, y: sun.y - 7, width: 14, height: 14)),
                     with: alt > -0.833 ? .color(Color(red: 1, green: 0.78, blue: 0.2)) : .color(Color(white: 0.85)))
            ctx.stroke(Path(ellipseIn: CGRect(x: sun.x - 7, y: sun.y - 7, width: 14, height: 14)), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
    }
}

struct PlaceSearch: View {
    let onPick: (Place) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var results: [Place] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sorted = Cities.all.sorted { $0.name < $1.name }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.country.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search cities or countries", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = results.first { onPick(first) } }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results, id: \.self) { place in
                        PlaceRow(place: place) { onPick(place) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 330)
        }
        .padding(.bottom, 8)
        .onAppear { focused = true }
    }
}

struct PlaceRow: View {
    let place: Place
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(place.name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(place.country).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.orange.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Solar

/// The NOAA solar calculator (after Meeus), as published in NOAA's sunrise and sunset spreadsheet.
enum Solar {
    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Declination (degrees) and equation of time (minutes) at an instant.
    static func position(at date: Date) -> (declination: Double, equationOfTime: Double) {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let t = (jd - 2451545) / 36525
        let l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + t * (35999.05029 - 0.0001537 * t)
        let e = 0.016708634 - t * (0.000042037 + 0.0000001267 * t)
        let c = sin(rad(m)) * (1.914602 - t * (0.004817 + 0.000014 * t)) + sin(rad(2 * m)) * (0.019993 - 0.000101 * t)
            + sin(rad(3 * m)) * 0.000289
        let omega = 125.04 - 1934.136 * t
        let lambda = l0 + c - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(eps)) * sin(rad(lambda))))
        let y = pow(tan(rad(eps / 2)), 2)
        let eot = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
            - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        return (decl, eot)
    }

    /// Solar noon on the calendar day of `day` in `zone`.
    static func noon(on day: Date, longitude: Double, zone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var local = Calendar(identifier: .gregorian)
        local.timeZone = zone
        let c = local.dateComponents([.year, .month, .day], from: day)
        let midnightUTC = cal.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
        var noon = midnightUTC.addingTimeInterval((720 - 4 * longitude) * 60)
        // Twice, so the equation of time is taken at noon itself.
        for _ in 0..<2 {
            noon = midnightUTC.addingTimeInterval((720 - 4 * longitude - position(at: noon).equationOfTime) * 60)
        }
        // Where the clock runs more than 12 hours from the sun (UTC+13/+14 west of 180°), noon falls on the next or
        // previous UTC date: move it back onto the local day asked for.
        let landed = local.dateComponents([.year, .month, .day], from: noon)
        if landed != c {
            let ahead = (landed.year!, landed.month!, landed.day!) > (c.year!, c.month!, c.day!)
            noon = noon.addingTimeInterval(ahead ? -86400 : 86400)
        }
        return noon
    }

    enum Crossing: Equatable {
        case at(Date)
        /// The sun stays above the altitude all day.
        case alwaysAbove
        /// The sun never reaches the altitude.
        case alwaysBelow
    }

    /// When the sun crosses `altitude` degrees: rising before noon, setting after it.
    static func crossing(_ altitude: Double, rising: Bool, on day: Date, place: Place) -> Crossing {
        let noon = noon(on: day, longitude: place.longitude, zone: place.zone)
        var guess = noon
        for _ in 0..<3 {
            let decl = position(at: guess).declination
            let cosH = (sin(rad(altitude)) - sin(rad(place.latitude)) * sin(rad(decl))) / (cos(rad(place.latitude)) * cos(rad(decl)))
            if cosH > 1 { return .alwaysBelow }
            if cosH < -1 { return .alwaysAbove }
            let minutes = 4 * deg(acos(cosH))
            guess = noon.addingTimeInterval((rising ? -minutes : minutes) * 60)
        }
        return .at(guess)
    }

    /// Altitude of the sun's centre in degrees, without refraction.
    static func altitude(at date: Date, place: Place) -> Double {
        let p = position(at: date)
        let minutesUTC = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) / 60
        let trueSolar = minutesUTC + p.equationOfTime + 4 * place.longitude
        let hourAngle = trueSolar / 4 - 180
        let cosZ = sin(rad(place.latitude)) * sin(rad(p.declination))
            + cos(rad(place.latitude)) * cos(rad(p.declination)) * cos(rad(hourAngle))
        return 90 - deg(acos(min(1, max(-1, cosZ))))
    }

    struct Day: Equatable {
        let noon: Date
        let sunrise: Crossing, sunset: Crossing
        let dawn: Crossing, dusk: Crossing
        /// Golden hour: the sun below six degrees.
        let goldenMorningEnd: Crossing, goldenEveningStart: Crossing
        /// Seconds the sun is above the horizon.
        let length: TimeInterval
    }

    static let horizon = -0.833, civil = -6.0, golden = 6.0

    static func day(_ day: Date, place: Place) -> Day {
        let rise = crossing(horizon, rising: true, on: day, place: place)
        let set = crossing(horizon, rising: false, on: day, place: place)
        let length: TimeInterval = switch (rise, set) {
        case let (.at(r), .at(s)): s.timeIntervalSince(r)
        case (.alwaysAbove, _), (_, .alwaysAbove): 86400
        default: 0
        }
        return Day(noon: noon(on: day, longitude: place.longitude, zone: place.zone), sunrise: rise, sunset: set,
                   dawn: crossing(civil, rising: true, on: day, place: place), dusk: crossing(civil, rising: false, on: day, place: place),
                   goldenMorningEnd: crossing(golden, rising: true, on: day, place: place),
                   goldenEveningStart: crossing(golden, rising: false, on: day, place: place), length: length)
    }
}

// MARK: - Icon

//: the sun on the horizon under its dotted daily arc

func appIcon() -> NSBitmapImageRep {
    render(0x3D74E6, 0xFFA65C) { ctx in
        let horizon: CGFloat = 400
        // Warm glow where the sun meets the horizon.
        radial([rgb(0xFFE29A, 0.9), rgb(0xFFB25C, 0.35), rgb(0xFFB25C, 0)], center: CGPoint(x: 512, y: horizon), radius: 360, in: ctx)
        // The day's path as a dotted arc.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        let c = CGPoint(x: 512, y: horizon), r: CGFloat = 370
        for i in 0...16 {
            let a = CGFloat.pi * (0.06 + 0.88 * CGFloat(i) / 16)
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            guard p.y > horizon + 20 else { continue }
            ctx.fillEllipse(in: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22))
        }
        // Sun, half risen, with rays.
        let s = CGPoint(x: 512, y: horizon)
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon, width: 1024, height: 1024))
        ctx.setStrokeColor(rgb(0xFFF4D6).cgColor)
        ctx.setLineWidth(30)
        ctx.setLineCap(.round)
        for i in 0..<7 {
            let a = CGFloat.pi * CGFloat(i + 1) / 8
            ctx.move(to: CGPoint(x: s.x + cos(a) * 200, y: s.y + sin(a) * 200))
            ctx.addLine(to: CGPoint(x: s.x + cos(a) * 262, y: s.y + sin(a) * 262))
        }
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 50, color: rgb(0xFFD36B, 0.8).cgColor)
        ctx.setFillColor(rgb(0xFFF1C2).cgColor)
        ctx.fillEllipse(in: CGRect(x: s.x - 160, y: s.y - 160, width: 320, height: 320))
        ctx.restoreGState()
        // Ground: two layered hills.
        ctx.saveGState()
        shadow(ctx, y: 10, blur: 30, alpha: 0.25)
        ctx.setFillColor(rgb(0x2C3F8F).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: horizon))
        ctx.restoreGState()
        ctx.setFillColor(rgb(0x1E2C6B).cgColor)
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: 300))
        hill.addCurve(to: CGPoint(x: 1024, y: 250), control1: CGPoint(x: 300, y: 380), control2: CGPoint(x: 650, y: 200))
        hill.addLine(to: CGPoint(x: 1024, y: 0))
        hill.addLine(to: CGPoint(x: 0, y: 0))
        hill.closeSubpath()
        ctx.addPath(hill)
        ctx.fillPath()
        // Horizon line.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fill(CGRect(x: 0, y: horizon - 5, width: 1024, height: 10))
    }
}
