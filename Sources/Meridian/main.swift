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
    let store = ClockStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "globe.europe.africa.fill", accessibilityLabel: "Meridian") {
            MeridianView().environmentObject(self.store)
        }
        store.$now.combineLatest(store.$pinned, store.$cities)
            .sink { [weak self] _ in self?.updateTitle() }
            .store(in: &cancellables)
    }

    private func updateTitle() {
        guard let city = store.cities.first(where: { $0.id == store.pinned }) else {
            status.setTitle("")
            return
        }
        status.setTitle("\(city.shortName) \(Clock.time(store.now, in: city.zone))")
    }
}

// MARK: - Model

struct City: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var timeZoneID: String

    var zone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }
    var shortName: String {
        let words = name.split(separator: " ")
        return words.count > 1 ? words.map { String($0.prefix(1)) }.joined().uppercased() : String(name.prefix(3)).uppercased()
    }

    static func named(from identifier: String) -> String {
        identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? identifier
    }
}

@MainActor
final class ClockStore: ObservableObject {
    @Published var cities: [City] { didSet { persist() } }
    @Published var pinned: UUID? { didSet { persist() } }
    @Published var now = Date()
    /// Minutes added to the clock by the time travel slider.
    @Published var offset: Double = 0 {
        didSet {
            let snapped = (offset / 15).rounded() * 15
            if snapped != offset { offset = snapped }
        }
    }

    private var timer: Timer?

    private struct Saved: Codable { var cities: [City]; var pinned: UUID? }

    init() {
        if StatusPopover.isSnapshot {
            // Fixed demo cities, never the user's own list or home time zone.
            cities = [("London", "Europe/London"), ("New York", "America/New_York"), ("Tokyo", "Asia/Tokyo"), ("Sydney", "Australia/Sydney")]
                .map { City(name: $0.0, timeZoneID: $0.1) }
            pinned = nil
        } else if let saved = Storage.load(Saved.self, app: "Meridian", file: "cities.json") {
            cities = saved.cities
            pinned = saved.pinned
        } else {
            let here = TimeZone.current.identifier
            cities = [City(name: City.named(from: here), timeZoneID: here)]
                + [("New York", "America/New_York"), ("London", "Europe/London"), ("Tokyo", "Asia/Tokyo")]
                .filter { $0.1 != here }
                .map { City(name: $0.0, timeZoneID: $0.1) }
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        // Common modes keep the clocks ticking while the time travel slider is dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    var displayed: Date { now.addingTimeInterval(offset * 60) }

    func add(_ identifier: String) {
        withAnimation(.snappy) {
            cities.append(City(name: City.named(from: identifier), timeZoneID: identifier))
        }
    }

    func remove(_ city: City) {
        withAnimation(.snappy) {
            cities.removeAll { $0.id == city.id }
            if pinned == city.id { pinned = nil }
        }
    }

    func move(from: IndexSet, to: Int) { cities.move(fromOffsets: from, toOffset: to) }

    private func persist() {
        guard !StatusPopover.isSnapshot else { return }
        Storage.save(Saved(cities: cities, pinned: pinned), app: "Meridian", file: "cities.json")
    }
}

enum Clock {
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.timeZone = zone
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    static func hour(_ date: Date, in zone: TimeZone) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute], from: date)
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    /// "Today", "Tomorrow" or "Yesterday", relative to the Mac's own calendar day.
    static func day(_ date: Date, in zone: TimeZone) -> String {
        var there = Calendar(identifier: .gregorian)
        there.timeZone = zone
        let a = there.dateComponents([.year, .month, .day], from: date)
        let b = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let da = Calendar.current.date(from: a), let db = Calendar.current.date(from: b) else { return "Today" }
        switch Calendar.current.dateComponents([.day], from: db, to: da).day ?? 0 {
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        default: return "Today"
        }
    }

    static func offsetLabel(_ zone: TimeZone, at date: Date) -> String {
        let seconds = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        if seconds == 0 { return "Local time" }
        let hours = seconds / 3600
        let minutes = abs(seconds % 3600) / 60
        let sign = seconds > 0 ? "+" : "-"
        return minutes == 0 ? "\(sign)\(abs(hours))h" : "\(sign)\(abs(hours))h \(minutes)m"
    }
}

// MARK: - Views

struct MeridianView: View {
    @EnvironmentObject var store: ClockStore
    @State private var adding = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("World Clock").font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(store.displayed.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
                GlassIconButton(adding ? "xmark" : "plus", help: adding ? "Done" : "Add a city") {
                    withAnimation(.snappy) { adding.toggle() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if adding {
                CitySearch { identifier in
                    store.add(identifier)
                    withAnimation(.snappy) { adding = false }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.cities) { city in
                            CityRow(city: city)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: min(CGFloat(store.cities.count) * 70 + 4, 360))
                TimeTravel()
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Meridian") {
                Button("Unpin Menu Bar Clock") { store.pinned = nil }.disabled(store.pinned == nil)
            }
        }
        .frame(width: 380)
    }
}

struct CityRow: View {
    @EnvironmentObject var store: ClockStore
    let city: City
    @State private var hovering = false

    var body: some View {
        let date = store.displayed
        let hour = Clock.hour(date, in: city.zone)
        VStack(spacing: 8) {
            HStack(spacing: 11) {
                DayGlyph(hour: hour)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(city.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if store.pinned == city.id {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange)
                        }
                    }
                    Text("\(Clock.day(date, in: city.zone)) · \(Clock.offsetLabel(city.zone, at: date))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if hovering {
                    HStack(spacing: 4) {
                        GlassIconButton(store.pinned == city.id ? "pin.slash" : "pin", help: "Show in menu bar") {
                            store.pinned = store.pinned == city.id ? nil : city.id
                        }
                        GlassIconButton("minus", help: "Remove") { store.remove(city) }
                    }
                    .transition(.opacity)
                }
                Text(Clock.time(date, in: city.zone))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            DayStrip(hour: hour)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.55 : 0.3)))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .animation(.snappy, value: store.offset)
    }
}

/// Sun, moon or twilight, on a small sky-coloured disc.
struct DayGlyph: View {
    let hour: Double

    var body: some View {
        let (symbol, colors): (String, [Color]) = switch hour {
        case 6..<8: ("sunrise.fill", [.orange, .pink])
        case 8..<18: ("sun.max.fill", [Color(red: 0.33, green: 0.68, blue: 1), Color(red: 0.15, green: 0.45, blue: 0.95)])
        case 18..<20.5: ("sunset.fill", [.orange, .purple])
        default: ("moon.stars.fill", [Color(red: 0.16, green: 0.18, blue: 0.42), Color(red: 0.05, green: 0.06, blue: 0.2)])
        }
        Image(systemName: symbol)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Circle().strokeBorder(.white.opacity(0.2)))
    }
}

/// The day as a 24 hour band from night through daylight, with a marker at the current time.
struct DayStrip: View {
    let hour: Double

    static let sky = Gradient(stops: [
        .init(color: Color(red: 0.1, green: 0.11, blue: 0.3), location: 0),
        .init(color: Color(red: 0.1, green: 0.11, blue: 0.3), location: 0.22),
        .init(color: .orange.opacity(0.9), location: 0.28),
        .init(color: Color(red: 0.45, green: 0.75, blue: 1), location: 0.36),
        .init(color: Color(red: 0.45, green: 0.75, blue: 1), location: 0.74),
        .init(color: .orange.opacity(0.9), location: 0.8),
        .init(color: .purple.opacity(0.8), location: 0.85),
        .init(color: Color(red: 0.1, green: 0.11, blue: 0.3), location: 0.92),
        .init(color: Color(red: 0.1, green: 0.11, blue: 0.3), location: 1),
    ])

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(gradient: DayStrip.sky, startPoint: .leading, endPoint: .trailing))
                    .opacity(0.85)
                // Working hours 09:00 to 18:00.
                Capsule()
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                    .frame(width: geo.size.width * 9 / 24)
                    .offset(x: geo.size.width * 9 / 24)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .frame(width: 9, height: 9)
                    .offset(x: geo.size.width * hour / 24 - 4.5)
            }
        }
        .frame(height: 6)
    }
}

struct TimeTravel: View {
    @EnvironmentObject var store: ClockStore

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label("Time travel", systemImage: "clock.arrow.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if store.offset != 0 {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                    Button("Now") { withAnimation(.snappy) { store.offset = 0 } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            Slider(value: $store.offset, in: -720...720)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var label: String {
        let total = Int(store.offset)
        let h = abs(total) / 60, m = abs(total) % 60
        return (total > 0 ? "+" : "-") + (m == 0 ? "\(h)h" : "\(h)h \(m)m")
    }
}

struct CitySearch: View {
    let onPick: (String) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private static let all: [(name: String, id: String, region: String)] = TimeZone.knownTimeZoneIdentifiers
        .filter { $0.contains("/") && !$0.hasPrefix("Etc/") }
        .map { id in (City.named(from: id), id, String(id.split(separator: "/").first ?? "")) }
        .sorted { $0.name < $1.name }

    private var results: [(name: String, id: String, region: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Array(CitySearch.all.prefix(40)) }
        let aliases = CitySearch.aliases.filter { $0.name.localizedCaseInsensitiveContains(q) }
            .map { (name: $0.name, id: $0.id, region: String($0.id.split(separator: "/").first ?? "")) }
        let zones = CitySearch.all.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.id.localizedCaseInsensitiveContains(q)
                || (TimeZone(identifier: $0.id)?.localizedName(for: .generic, locale: .current)?.localizedCaseInsensitiveContains(q) ?? false)
        }
        return aliases + zones
    }

    /// Well known cities that are not the name of their time zone.
    static let aliases: [(name: String, id: String)] = [
        ("San Francisco", "America/Los_Angeles"), ("Seattle", "America/Los_Angeles"), ("San Diego", "America/Los_Angeles"),
        ("Las Vegas", "America/Los_Angeles"), ("Washington", "America/New_York"), ("Boston", "America/New_York"),
        ("Miami", "America/New_York"), ("Atlanta", "America/New_York"), ("Philadelphia", "America/New_York"),
        ("Dallas", "America/Chicago"), ("Houston", "America/Chicago"), ("Austin", "America/Chicago"),
        ("Montreal", "America/Toronto"), ("Rio de Janeiro", "America/Sao_Paulo"),
        ("Thessaloniki", "Europe/Athens"), ("Heraklion", "Europe/Athens"), ("Patras", "Europe/Athens"),
        ("Larnaca", "Asia/Nicosia"), ("Limassol", "Asia/Nicosia"),
        ("Manchester", "Europe/London"), ("Edinburgh", "Europe/London"), ("Geneva", "Europe/Zurich"),
        ("Frankfurt", "Europe/Berlin"), ("Munich", "Europe/Berlin"), ("Hamburg", "Europe/Berlin"),
        ("Milan", "Europe/Rome"), ("Barcelona", "Europe/Madrid"), ("Mumbai", "Asia/Kolkata"),
        ("New Delhi", "Asia/Kolkata"), ("Delhi", "Asia/Kolkata"), ("Bangalore", "Asia/Kolkata"),
        ("Beijing", "Asia/Shanghai"), ("Shenzhen", "Asia/Shanghai"), ("Abu Dhabi", "Asia/Dubai"),
        ("Osaka", "Asia/Tokyo"), ("Kyoto", "Asia/Tokyo"), ("Canberra", "Australia/Sydney"),
        ("Wellington", "Pacific/Auckland"), ("Cape Town", "Africa/Johannesburg"), ("Tel Aviv", "Asia/Jerusalem"),
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search cities", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = results.first { onPick(first.id) } }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        SearchRow(name: result.name, detail: "\(result.region) · \(Clock.time(Date(), in: TimeZone(identifier: result.id) ?? .current))") {
                            onPick(result.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 300)
        }
        .onAppear { focused = true }
    }
}

struct SearchRow: View {
    let name: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Icon

//: a globe with meridians, half in night

func appIcon() -> NSBitmapImageRep {
    render(0x0E1B4D, 0x3149B8) { ctx in
        // Stars.
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        for (x, y, r) in [(220.0, 800.0, 5.0), (300, 870, 3), (790, 830, 4), (850, 740, 3), (180, 660, 3), (760, 210, 3), (240, 230, 4)] {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        let c = CGPoint(x: 512, y: 500), r: CGFloat = 300
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        // Glow.
        radial([rgb(0x7FD3FF, 0.45), rgb(0x7FD3FF, 0)], center: c, radius: r + 90, in: ctx)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.4)
        ctx.setFillColor(rgb(0x1E88E5).cgColor)
        ctx.fillEllipse(in: disc)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: disc)
        ctx.clip()
        radial([rgb(0x8EE0FF), rgb(0x2E9BF0), rgb(0x1258C9)], center: CGPoint(x: c.x - 110, y: c.y + 120), radius: r * 1.5, in: ctx)
        // Meridians and parallels.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(9)
        for w in [0.0, 0.42, 0.78] {
            let half = r * CGFloat(w)
            ctx.strokeEllipse(in: CGRect(x: c.x - half, y: c.y - r, width: half * 2, height: r * 2))
        }
        ctx.move(to: CGPoint(x: c.x, y: c.y - r)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r)); ctx.strokePath()
        for f in [-0.55, 0.0, 0.55] {
            let y = c.y + r * CGFloat(f)
            ctx.move(to: CGPoint(x: c.x - r, y: y)); ctx.addLine(to: CGPoint(x: c.x + r, y: y))
        }
        ctx.strokePath()
        // The night side, with a soft terminator.
        gradient([rgb(0x050A2A, 0), rgb(0x050A2A, 0), rgb(0x050A2A, 0.62)],
                 from: CGPoint(x: c.x - 40, y: c.y + 60), to: CGPoint(x: c.x + r, y: c.y - 40), in: ctx)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(5)
        ctx.strokeEllipse(in: disc.insetBy(dx: -18, dy: -18))
        // Sun.
        let s = CGPoint(x: 760, y: 760)
        radial([rgb(0xFFE08A, 0.9), rgb(0xFFB547, 0.4), rgb(0xFFB547, 0)], center: s, radius: 150, in: ctx)
        ctx.setFillColor(rgb(0xFFF4CF).cgColor)
        ctx.fillEllipse(in: CGRect(x: s.x - 58, y: s.y - 58, width: 116, height: 116))
    }
}
