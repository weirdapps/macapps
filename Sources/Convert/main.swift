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
    let model = ConvertModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "arrow.left.arrow.right", accessibilityLabel: "Convert") {
            ConvertView().environmentObject(self.model)
        }
    }
}

// MARK: - Units

struct UnitOption: Identifiable, Hashable {
    let id: String
    let name: String
    let unit: Dimension

    static func == (a: UnitOption, b: UnitOption) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Category: String, CaseIterable, Identifiable {
    case length = "Length", mass = "Mass", temperature = "Temperature", volume = "Volume", speed = "Speed"
    case area = "Area", data = "Data", time = "Time", energy = "Energy", pressure = "Pressure"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .length: "ruler"
        case .mass: "scalemass"
        case .temperature: "thermometer.medium"
        case .volume: "drop"
        case .speed: "speedometer"
        case .area: "square.dashed"
        case .data: "externaldrive"
        case .time: "clock"
        case .energy: "bolt"
        case .pressure: "gauge.with.dots.needle.33percent"
        }
    }

    var units: [UnitOption] {
        let list: [(String, Dimension)] = switch self {
        case .length: [("Millimetres", UnitLength.millimeters), ("Centimetres", UnitLength.centimeters), ("Metres", UnitLength.meters),
                       ("Kilometres", UnitLength.kilometers), ("Inches", UnitLength.inches), ("Feet", UnitLength.feet),
                       ("Yards", UnitLength.yards), ("Miles", UnitLength.miles), ("Nautical miles", UnitLength.nauticalMiles)]
        case .mass: [("Milligrams", UnitMass.milligrams), ("Grams", UnitMass.grams), ("Kilograms", UnitMass.kilograms),
                     ("Tonnes", UnitMass.metricTons), ("Ounces", Extra.ounces), ("Pounds", Extra.pounds), ("Stones", Extra.stones)]
        case .temperature: [("Celsius", UnitTemperature.celsius), ("Fahrenheit", UnitTemperature.fahrenheit), ("Kelvin", UnitTemperature.kelvin)]
        case .volume: [("Millilitres", UnitVolume.milliliters), ("Litres", UnitVolume.liters), ("Cubic metres", UnitVolume.cubicMeters),
                       ("Teaspoons", Extra.teaspoons), ("Tablespoons", Extra.tablespoons), ("Cups (US)", Extra.cups),
                       ("Fluid ounces (US)", Extra.fluidOunces), ("Pints (US)", Extra.pints), ("Gallons (US)", Extra.gallons),
                       ("Pints (UK)", Extra.imperialPints), ("Gallons (UK)", Extra.imperialGallons)]
        case .speed: [("Metres per second", UnitSpeed.metersPerSecond), ("Kilometres per hour", Extra.kilometersPerHour),
                      ("Miles per hour", Extra.milesPerHour), ("Knots", Extra.knots)]
        case .area: [("Square millimetres", UnitArea.squareMillimeters), ("Square centimetres", UnitArea.squareCentimeters),
                     ("Square metres", UnitArea.squareMeters), ("Hectares", UnitArea.hectares), ("Square kilometres", UnitArea.squareKilometers),
                     ("Square inches", UnitArea.squareInches), ("Square feet", UnitArea.squareFeet), ("Acres", UnitArea.acres),
                     ("Square miles", UnitArea.squareMiles)]
        case .data: [("Bits", UnitInformationStorage.bits), ("Bytes", UnitInformationStorage.bytes), ("Kilobytes", UnitInformationStorage.kilobytes),
                     ("Megabytes", UnitInformationStorage.megabytes), ("Gigabytes", UnitInformationStorage.gigabytes),
                     ("Terabytes", UnitInformationStorage.terabytes), ("Kibibytes", UnitInformationStorage.kibibytes),
                     ("Mebibytes", UnitInformationStorage.mebibytes), ("Gibibytes", UnitInformationStorage.gibibytes),
                     ("Tebibytes", UnitInformationStorage.tebibytes), ("Megabits", UnitInformationStorage.megabits),
                     ("Gigabits", UnitInformationStorage.gigabits)]
        case .time: [("Milliseconds", UnitDuration.milliseconds), ("Seconds", UnitDuration.seconds), ("Minutes", UnitDuration.minutes),
                     ("Hours", UnitDuration.hours), ("Days", Extra.days), ("Weeks", Extra.weeks), ("Years", Extra.years)]
        case .energy: [("Joules", UnitEnergy.joules), ("Kilojoules", UnitEnergy.kilojoules), ("Calories", UnitEnergy.calories),
                       ("Kilocalories", UnitEnergy.kilocalories), ("Watt hours", Extra.wattHours), ("Kilowatt hours", UnitEnergy.kilowattHours),
                       ("Megajoules", Extra.megajoules), ("BTU", Extra.btu)]
        case .pressure: [("Pascals", UnitPressure.newtonsPerMetersSquared), ("Kilopascals", UnitPressure.kilopascals),
                         ("Bars", UnitPressure.bars), ("Millibars", UnitPressure.millibars), ("Atmospheres", Extra.atmospheres),
                         ("PSI", Extra.psi), ("Millimetres of mercury", Extra.mmHg),
                         ("Inches of mercury", Extra.inHg)]
        }
        return list.map { UnitOption(id: "\(rawValue).\($0.0)", name: $0.0, unit: $0.1) }
    }

    /// Sensible starting pair for each category.
    var defaults: (from: Int, to: Int) {
        switch self {
        case .length: (7, 3)
        case .mass: (5, 2)
        case .temperature: (1, 0)
        case .volume: (8, 1)
        case .speed: (2, 1)
        case .area: (7, 3)
        case .data: (8, 4)
        case .time: (3, 1)
        case .energy: (3, 1)
        case .pressure: (5, 2)
        }
    }
}

/// Units Foundation lacks, and exact definitions where Foundation rounds to six digits
/// (its knot gives 1.851997 km/h). Each is defined against its dimension's base unit.
enum Extra {
    static let pounds = UnitMass(symbol: "lb", converter: UnitConverterLinear(coefficient: 0.45359237))
    static let ounces = UnitMass(symbol: "oz", converter: UnitConverterLinear(coefficient: 0.45359237 / 16))
    static let stones = UnitMass(symbol: "st", converter: UnitConverterLinear(coefficient: 0.45359237 * 14))
    static let kilometersPerHour = UnitSpeed(symbol: "km/h", converter: UnitConverterLinear(coefficient: 1 / 3.6))
    static let knots = UnitSpeed(symbol: "kn", converter: UnitConverterLinear(coefficient: 1852.0 / 3600))
    static let milesPerHour = UnitSpeed(symbol: "mph", converter: UnitConverterLinear(coefficient: 0.44704))
    // US customary volumes from the 231 cubic inch gallon; the base unit is the litre.
    static let gallons = UnitVolume(symbol: "gal", converter: UnitConverterLinear(coefficient: 3.785411784))
    /// Foundation's cup is the 240 ml legal cup; the customary cup keeps 16 tablespoons to the cup.
    static let cups = UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: 3.785411784 / 16))
    static let pints = UnitVolume(symbol: "pt", converter: UnitConverterLinear(coefficient: 3.785411784 / 8))
    static let fluidOunces = UnitVolume(symbol: "fl oz", converter: UnitConverterLinear(coefficient: 3.785411784 / 128))
    static let tablespoons = UnitVolume(symbol: "tbsp", converter: UnitConverterLinear(coefficient: 3.785411784 / 256))
    static let teaspoons = UnitVolume(symbol: "tsp", converter: UnitConverterLinear(coefficient: 3.785411784 / 768))
    static let imperialGallons = UnitVolume(symbol: "gal", converter: UnitConverterLinear(coefficient: 4.54609))
    static let imperialPints = UnitVolume(symbol: "pt", converter: UnitConverterLinear(coefficient: 4.54609 / 8))
    // Pressure; the base unit is the pascal.
    static let psi = UnitPressure(symbol: "psi", converter: UnitConverterLinear(coefficient: 6894.757293168361))
    static let mmHg = UnitPressure(symbol: "mmHg", converter: UnitConverterLinear(coefficient: 133.322387415))
    static let inHg = UnitPressure(symbol: "inHg", converter: UnitConverterLinear(coefficient: 3386.388640341))
    static let days = UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86400))
    static let weeks = UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800))
    /// Julian year, 365.25 days.
    static let years = UnitDuration(symbol: "yr", converter: UnitConverterLinear(coefficient: 31_557_600))
    static let wattHours = UnitEnergy(symbol: "Wh", converter: UnitConverterLinear(coefficient: 3600))
    static let megajoules = UnitEnergy(symbol: "MJ", converter: UnitConverterLinear(coefficient: 1_000_000))
    /// International Table BTU.
    static let btu = UnitEnergy(symbol: "BTU", converter: UnitConverterLinear(coefficient: 1055.05585262))
    /// Standard atmosphere; UnitPressure's base unit is the pascal.
    static let atmospheres = UnitPressure(symbol: "atm", converter: UnitConverterLinear(coefficient: 101_325))
}

enum Convert {
    static func value(_ v: Double, from: Dimension, to: Dimension) -> Double {
        Measurement(value: v, unit: from).converted(to: to).value
    }

    /// NumberFormatter, not FormatStyle: it honours the separators chosen in System Settings, which
    /// FormatStyle ignores in favour of the region, and `parse` reads with the same separators.
    static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesSignificantDigits = true
        f.minimumSignificantDigits = 1
        f.maximumSignificantDigits = 7
        return f
    }()

    static let scientific: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .scientific
        f.usesSignificantDigits = true
        f.minimumSignificantDigits = 1
        f.maximumSignificantDigits = 6
        return f
    }()

    /// Up to seven significant digits; scientific notation outside 1e-6...1e12.
    static func format(_ v: Double) -> String {
        if v == 0 || !v.isFinite { return v.isFinite ? "0" : "-" }
        let a = abs(v)
        let f = a < 1e-6 || a >= 1e12 ? scientific : decimal
        return f.string(from: v as NSNumber) ?? String(v)
    }

    /// Reads what `format` writes and what people type: either separator as the decimal mark,
    /// grouping marks, spaces, and exponents. With both "." and "," present the last one is the decimal;
    /// a lone grouping mark followed by exactly three digits groups thousands, so "1.000" is 1000 in Greek.
    static func parse(_ s: String, decimalSeparator: String = Locale.current.decimalSeparator ?? ".",
                      groupingSeparator: String = Locale.current.groupingSeparator ?? ",") -> Double? {
        var t = s.filter { !$0.isWhitespace && $0 != "\u{202F}" }
        let marks = t.filter { $0 == "." || $0 == "," }
        if let last = marks.last {
            let other: Character = last == "." ? "," : "."
            if marks.contains(other) {
                t.removeAll { $0 == other }
            } else if marks.count > 1 {
                t.removeAll { $0 == last }
            } else if String(last) != decimalSeparator, String(last) == groupingSeparator,
                      let i = t.firstIndex(of: last), t[t.index(after: i)...].count == 3,
                      t[t.index(after: i)...].allSatisfy(\.isNumber) {
                t.removeAll { $0 == last }
            }
            t = t.replacingOccurrences(of: ",", with: ".")
        }
        return Double(t)
    }
}

// MARK: - Model

struct FavouritePair: Codable, Equatable, Identifiable {
    var category: String
    var from: String
    var to: String
    var id: String { "\(from)>\(to)" }
}

@MainActor
final class ConvertModel: ObservableObject {
    @Published var category: Category { didSet { if category != oldValue { resetUnits() } } }
    @Published var from: UnitOption
    @Published var to: UnitOption
    @Published var input = "1"
    @Published var favourites: [FavouritePair] { didSet { Storage.save(favourites, app: "Convert", file: "favourites.json") } }
    @Published var copied: String?

    init() {
        // The README snapshot shows the defaults, never this Mac's saved choices.
        let saved = StatusPopover.isSnapshot ? nil : UserDefaults.standard.string(forKey: "category")
        let c = Category(rawValue: saved ?? "") ?? .length
        category = c
        from = c.units[c.defaults.from]
        to = c.units[c.defaults.to]
        favourites = StatusPopover.isSnapshot ? [] : Storage.load([FavouritePair].self, app: "Convert", file: "favourites.json") ?? []
    }

    private func resetUnits() {
        from = category.units[category.defaults.from]
        to = category.units[category.defaults.to]
        UserDefaults.standard.set(category.rawValue, forKey: "category")
    }

    var value: Double? { Convert.parse(input) }

    func converted(to unit: UnitOption) -> Double? {
        value.map { Convert.value($0, from: from.unit, to: unit.unit) }
    }

    func swap() {
        if let result = converted(to: to) { input = Convert.format(result) }
        (from, to) = (to, from)
    }

    var isFavourite: Bool { favourites.contains { $0.from == from.id && $0.to == to.id } }

    func toggleFavourite() {
        withAnimation(.snappy) {
            if isFavourite {
                favourites.removeAll { $0.from == from.id && $0.to == to.id }
            } else {
                favourites.append(FavouritePair(category: category.rawValue, from: from.id, to: to.id))
            }
        }
    }

    func open(_ f: FavouritePair) {
        guard let c = Category(rawValue: f.category),
              let a = c.units.first(where: { $0.id == f.from }), let b = c.units.first(where: { $0.id == f.to }) else { return }
        category = c
        from = a
        to = b
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        withAnimation { copied = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in withAnimation { if self?.copied == s { self?.copied = nil } } }
    }
}

// MARK: - Views

struct ConvertView: View {
    @EnvironmentObject var model: ConvertModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CategoryBar()
                .padding(.top, 12)
                .padding(.bottom, 10)
            if !model.favourites.isEmpty {
                FavouriteBar()
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            converter
                .padding(.horizontal, 12)
            UnitList()
                .padding(12)
            Divider().opacity(0.5)
            PanelFooter(name: "Convert") {
                Button("Swap Units") { withAnimation(.snappy) { model.swap() } }
                Button(model.isFavourite ? "Remove Favourite" : "Add Favourite") { model.toggleFavourite() }
                if !model.favourites.isEmpty {
                    Button("Clear Favourites", role: .destructive) { model.favourites = [] }
                }
            }
        }
        .frame(width: 380)
        .background { shortcuts }
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { focused = true }
        }
    }

    /// Key equivalents in a closed menu never fire, so ⌘S and ⌘D live on invisible buttons in the panel.
    private var shortcuts: some View {
        ZStack {
            Button("Swap Units") { withAnimation(.snappy) { model.swap() } }.keyboardShortcut("s")
            Button("Favourite") { model.toggleFavourite() }.keyboardShortcut("d")
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var converter: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Value", text: $model.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .focused($focused)
                UnitMenu(selection: $model.from)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.45)))
            .overlay(alignment: .bottom) {
                HStack(spacing: 6) {
                    GlassIconButton("arrow.up.arrow.down", help: "Swap units (⌘S)") { withAnimation(.snappy) { model.swap() } }
                    GlassIconButton(model.isFavourite ? "star.fill" : "star", help: "Favourite this pair (⌘D)") { model.toggleFavourite() }
                        .foregroundStyle(model.isFavourite ? AnyShapeStyle(Accent.gradient) : AnyShapeStyle(.secondary))
                }
                .padding(3)
                .background(Capsule().fill(.background))
                .offset(y: 20)
            }
            .zIndex(1)

            HStack(spacing: 8) {
                let result = model.converted(to: model.to)
                Text(result.map(Convert.format) ?? "Not a number")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(result == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Accent.gradient))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                Spacer()
                UnitMenu(selection: $model.to)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.3)))
        }
        .animation(.snappy, value: model.input)
    }
}

struct UnitMenu: View {
    @EnvironmentObject var model: ConvertModel
    @Binding var selection: UnitOption

    var body: some View {
        Menu {
            ForEach(model.category.units) { u in
                Button("\(u.name) (\(u.unit.symbol))") { withAnimation(.snappy) { selection = u } }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selection.name).font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct CategoryBar: View {
    @EnvironmentObject var model: ConvertModel
    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Category.allCases) { c in
                        Button {
                            withAnimation(.snappy) { model.category = c }
                        } label: {
                            Label(c.rawValue, systemImage: c.symbol)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.category == c ? .white : .secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background {
                                    if model.category == c {
                                        Capsule().fill(Accent.gradient).matchedGeometryEffect(id: "pill", in: ns)
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(c)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onChange(of: model.category) { _, c in withAnimation { proxy.scrollTo(c, anchor: .center) } }
        }
    }
}

struct FavouriteBar: View {
    @EnvironmentObject var model: ConvertModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Accent.gradient)
                ForEach(model.favourites) { f in
                    Button { withAnimation(.snappy) { model.open(f) } } label: {
                        Text("\(short(f.from)) → \(short(f.to))")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.quaternary.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove", role: .destructive) { model.favourites.removeAll { $0 == f } }
                    }
                }
            }
        }
    }

    private func short(_ id: String) -> String { String(id.split(separator: ".").last ?? "") }
}

struct UnitList: View {
    @EnvironmentObject var model: ConvertModel

    var body: some View {
        let units = model.category.units.filter { $0 != model.from }
        ScrollView {
            VStack(spacing: 3) {
                ForEach(units) { u in
                    UnitRow(option: u)
                }
            }
        }
        .frame(height: min(CGFloat(units.count) * 31, 248))
    }
}

struct UnitRow: View {
    @EnvironmentObject var model: ConvertModel
    let option: UnitOption
    @State private var hovering = false

    var body: some View {
        let text = model.converted(to: option).map(Convert.format) ?? "-"
        let selected = option == model.to
        Button {
            withAnimation(.snappy) { model.to = option }
            model.copy(text)
        } label: {
            HStack {
                Text(option.name).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                Text(option.unit.symbol).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Text(model.copied == text && selected ? "Copied" : text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(Accent.solid.opacity(0.16)) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.5 : 0.25))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show in the result and copy")
        .onHover { hovering = $0 }
    }
}

enum Accent {
    static let solid = Color(red: 1, green: 0.48, blue: 0.2)
    static let gradient = LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.25), Color(red: 0.96, green: 0.36, blue: 0.16)],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Icon

//: two opposing arrows over a ruler edge

func appIcon() -> NSBitmapImageRep {
    render(0x55647E, 0x1F2635) { ctx in
        // Ruler band across the lower third.
        let ruler = CGRect(x: 160, y: 200, width: 704, height: 150)
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 24, alpha: 0.35)
        ctx.addPath(roundedRect(ruler, 30))
        ctx.setFillColor(rgb(0xF2E3C6).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0x8C7A5B).cgColor)
        ctx.setLineCap(.round)
        for i in 0...16 {
            let x = ruler.minX + 52 + CGFloat(i) * 37.5
            let long = i % 4 == 0
            ctx.setLineWidth(long ? 9 : 6)
            ctx.move(to: CGPoint(x: x, y: ruler.maxY - 22))
            ctx.addLine(to: CGPoint(x: x, y: ruler.maxY - (long ? 92 : 58)))
            ctx.strokePath()
        }
        // Arrows.
        func arrow(y: CGFloat, right: Bool, colors: [NSColor]) {
            let dir: CGFloat = right ? 1 : -1
            let tail = 512 - dir * 250, head = 512 + dir * 250
            let p = CGMutablePath()
            p.move(to: CGPoint(x: tail, y: y + 38))
            p.addLine(to: CGPoint(x: head - dir * 110, y: y + 38))
            p.addLine(to: CGPoint(x: head - dir * 110, y: y + 100))
            p.addLine(to: CGPoint(x: head, y: y))
            p.addLine(to: CGPoint(x: head - dir * 110, y: y - 100))
            p.addLine(to: CGPoint(x: head - dir * 110, y: y - 38))
            p.addLine(to: CGPoint(x: tail, y: y - 38))
            p.closeSubpath()
            ctx.saveGState()
            shadow(ctx, y: -10, blur: 22, alpha: 0.4)
            ctx.addPath(p)
            ctx.setFillColor(colors[1].cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            gradient(colors, from: CGPoint(x: 0, y: y + 100), to: CGPoint(x: 0, y: y - 100), in: ctx)
            ctx.restoreGState()
        }
        arrow(y: 680, right: true, colors: [rgb(0xFFB25A), rgb(0xF25A28)])
        arrow(y: 500, right: false, colors: [rgb(0xFFFFFF), rgb(0xD5DCE8)])
    }
}
