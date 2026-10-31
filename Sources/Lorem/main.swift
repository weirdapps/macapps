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
    let model = LoremModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "text.alignleft", accessibilityLabel: "Lorem") {
            LoremView().environmentObject(self.model)
        }
        NotificationCenter.default.addObserver(forName: .popoverDidShow, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.regenerate() }
        }
    }
}

// MARK: - Model

enum Kind: String, CaseIterable, Identifiable {
    case words = "Words", sentences = "Sentences", paragraphs = "Paragraphs"
    case names = "Names", emails = "Emails", addresses = "Addresses"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .words: "textformat.abc"
        case .sentences: "text.alignleft"
        case .paragraphs: "text.justify.left"
        case .names: "person.fill"
        case .emails: "at"
        case .addresses: "house.fill"
        }
    }

    var isText: Bool { [.words, .sentences, .paragraphs].contains(self) }
    var range: ClosedRange<Int> { self == .words ? 1...500 : 1...50 }
    var defaultCount: Int {
        switch self {
        case .words: 30
        case .sentences: 4
        case .paragraphs: 3
        default: 5
        }
    }
}

@MainActor
final class LoremModel: ObservableObject {
    @AppStorage("kind") var kind: Kind = .paragraphs { willSet { objectWillChange.send() } }
    @AppStorage("startWithLorem") var startWithLorem = true { willSet { objectWillChange.send() } }
    @Published var counts: [Kind: Int] = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, $0.defaultCount) })
    @Published private(set) var output = ""

    init() { regenerate() }

    var count: Int {
        get { counts[kind] ?? kind.defaultCount }
        set { counts[kind] = min(max(newValue, kind.range.lowerBound), kind.range.upperBound); regenerate() }
    }

    func regenerate() {
        var rng = SystemRandomNumberGenerator()
        withAnimation(.snappy(duration: 0.2)) {
            output = Generator.make(kind, count: count, classic: startWithLorem, using: &rng)
        }
    }

    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        HUD.show(symbol: "doc.on.clipboard.fill", title: "Copied", tint: Color.lorem[1])
    }
}

enum Generator {
    static let classicOpening = "Lorem ipsum dolor sit amet, consectetur adipiscing elit"

    static func make<R: RandomNumberGenerator>(_ kind: Kind, count n: Int, classic: Bool, using rng: inout R) -> String {
        switch kind {
        case .words:
            var words = (0..<n).map { _ in Lists.latin.randomElement(using: &rng)! }
            if classic {
                let opening = classicOpening.lowercased().replacingOccurrences(of: ",", with: "").split(separator: " ").map(String.init)
                for (i, w) in opening.prefix(n).enumerated() { words[i] = w }
                words[0] = words[0].capitalized
            }
            return words.joined(separator: " ")
        case .sentences:
            return (0..<n).map { i in i == 0 && classic ? classicOpening + "." : sentence(using: &rng) }.joined(separator: " ")
        case .paragraphs:
            return (0..<n).map { i in
                let count = Int.random(in: 4...7, using: &rng)
                return (0..<count).map { j in i == 0 && j == 0 && classic ? classicOpening + "." : sentence(using: &rng) }
                    .joined(separator: " ")
            }.joined(separator: "\n\n")
        case .names:
            return (0..<n).map { _ in name(using: &rng) }.joined(separator: "\n")
        case .emails:
            return (0..<n).map { _ in email(using: &rng) }.joined(separator: "\n")
        case .addresses:
            return (0..<n).map { _ in address(using: &rng) }.joined(separator: "\n\n")
        }
    }

    static func sentence<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let length = Int.random(in: 6...14, using: &rng)
        var words = (0..<length).map { _ in Lists.latin.randomElement(using: &rng)! }
        words[0] = words[0].capitalized
        // An occasional comma in the middle reads more like prose.
        if length > 8, Bool.random(using: &rng) {
            let i = Int.random(in: 3...(length - 4), using: &rng)
            words[i] += ","
        }
        return words.joined(separator: " ") + "."
    }

    static func name<R: RandomNumberGenerator>(using rng: inout R) -> String {
        Lists.firstNames.randomElement(using: &rng)! + " " + Lists.lastNames.randomElement(using: &rng)!
    }

    static func email<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let first = Lists.firstNames.randomElement(using: &rng)!.lowercased()
        let last = Lists.lastNames.randomElement(using: &rng)!.lowercased().replacingOccurrences(of: "'", with: "")
        let local: String
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: local = "\(first).\(last)"
        case 1: local = "\(first.prefix(1))\(last)"
        case 2: local = "\(first)\(Int.random(in: 1...99, using: &rng))"
        default: local = "\(first)_\(last)"
        }
        // Reserved example domains, so a generated address can never reach a real inbox.
        return local + "@" + ["example.com", "example.org", "example.net", "mail.example.com"].randomElement(using: &rng)!
    }

    static func address<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let number = Int.random(in: 1...9800, using: &rng)
        let street = Lists.streets.randomElement(using: &rng)! + " " + Lists.streetTypes.randomElement(using: &rng)!
        let place = Lists.cities.randomElement(using: &rng)!
        let zip = String(format: "%05d", Int.random(in: 10000...99950, using: &rng))
        return "\(number) \(street)\n\(place.city), \(place.state) \(zip)"
    }
}

enum Lists {
    static let latin = """
    a ac accumsan ad adipiscing aenean aliquam aliquet amet ante aptent arcu at auctor augue bibendum blandit class \
    commodo condimentum congue consectetur consequat conubia convallis cras cubilia curabitur curae cursus dapibus diam \
    dictum dictumst dignissim dis dolor donec dui duis efficitur egestas eget eleifend elementum elit enim erat eros est \
    et etiam eu euismod ex facilisi facilisis fames faucibus felis fermentum feugiat finibus fringilla fusce gravida \
    habitant habitasse hac hendrerit himenaeos iaculis id imperdiet in inceptos integer interdum ipsum justo lacinia \
    lacus laoreet lectus leo libero ligula litora lobortis lorem luctus maecenas magna magnis malesuada massa mattis \
    mauris maximus metus mi molestie mollis montes morbi mus nam nascetur natoque nec neque netus nibh nisi nisl non \
    nostra nulla nullam nunc odio orci ornare parturient pellentesque penatibus per pharetra phasellus placerat platea \
    porta porttitor posuere potenti praesent pretium primis proin pulvinar purus quam quis quisque rhoncus ridiculus \
    risus rutrum sagittis sapien scelerisque sed sem semper senectus sit sociosqu sodales sollicitudin suscipit \
    suspendisse taciti tellus tempor tempus tincidunt torquent tortor tristique turpis ullamcorper ultrices ultricies \
    urna ut varius vehicula vel velit venenatis vestibulum vitae vivamus viverra volutpat vulputate
    """.split(separator: " ").map(String.init)

    static let firstNames = """
    Ada Alan Alice Amara Amelia Anna Arjun Ava Ben Bianca Caleb Carmen Chloe Daniel Diego Elena Eli Emma Ethan Eva \
    Felix Fiona Grace Hana Hugo Ines Isaac Ivy Jack Jade James Julia Kai Kenji Lars Laura Leo Lina Lucas Luna Maya \
    Milo Mira Nadia Noah Nora Oliver Omar Owen Paula Priya Quinn Rafael Rosa Ruby Sam Sara Sofia Theo Tomas Uma Victor \
    Wren Yara Yusuf Zoe
    """.split(separator: " ").map(String.init)

    static let lastNames = """
    Adams Almeida Andersen Bauer Becker Bennett Brooks Campbell Carter Chen Costa Cruz Dimitriou Dubois Edwards Evans \
    Fischer Fleming Garcia Gomez Graham Hansen Harper Hayes Ito Jensen Kaur Keller Kim Kowalski Larsen Laurent Lee Lopez \
    Martin Meyer Moreau Morris Nakamura Novak O'Brien Okafor Olsen Park Patel Perez Petrov Quinn Reed Rossi Russo Sato \
    Schmidt Silva Singh Stewart Suzuki Tanaka Turner Vasquez Wagner Walsh Weber Wright Young Zhang
    """.split(separator: " ").map(String.init)

    static let streets = """
    Maple Oak Cedar Pine Elm Willow Birch Chestnut Walnut Spruce Aspen Laurel Magnolia Juniper Hawthorn Linden Poplar \
    Sycamore Cypress Hickory Main High Church Mill Park Lake River Hill Meadow Spring Sunset Harbor Orchard Forest Garden \
    Valley Ridge Brook Bridge Station Market Union Liberty Franklin Lincoln Washington Jefferson Madison Highland
    """.split(separator: " ").map(String.init)

    static let streetTypes = ["Street", "Avenue", "Road", "Lane", "Drive", "Court", "Place", "Way", "Boulevard", "Terrace"]

    static let cities: [(city: String, state: String)] = [
        ("Springfield", "IL"), ("Riverside", "CA"), ("Franklin", "TN"), ("Greenville", "SC"), ("Bristol", "CT"),
        ("Clinton", "IA"), ("Fairview", "OR"), ("Salem", "MA"), ("Madison", "WI"), ("Georgetown", "TX"),
        ("Arlington", "VA"), ("Ashland", "OR"), ("Dover", "DE"), ("Milford", "NH"), ("Oxford", "MS"),
        ("Burlington", "VT"), ("Lexington", "KY"), ("Auburn", "AL"), ("Hudson", "NY"), ("Kingston", "NY"),
        ("Marion", "OH"), ("Newport", "RI"), ("Portland", "ME"), ("Winchester", "VA"), ("Boulder", "CO"),
    ]
}

extension Color {
    static let lorem = [Color(red: 0.93, green: 0.66, blue: 0.4), Color(red: 0.7, green: 0.38, blue: 0.16)]
}

// MARK: - Views

struct LoremView: View {
    @EnvironmentObject var model: LoremModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lorem").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Text(summary).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                ForEach([Array(Kind.allCases.prefix(3)), Array(Kind.allCases.suffix(3))], id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row) { kind in KindChip(kind: kind) }
                    }
                }
            }
            .padding(.horizontal, 12)

            HStack(spacing: 10) {
                Stepper(value: Binding(get: { model.count }, set: { model.count = $0 }), in: model.kind.range) {
                    HStack(spacing: 4) {
                        Text("\(model.count)")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(model.kind.rawValue.lowercased()).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if model.kind.isText {
                    Toggle("Start with Lorem ipsum", isOn: $model.startWithLorem)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .onChange(of: model.startWithLorem) { _, _ in model.regenerate() }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                Text(model.output)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(height: 210)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.35)))
            .padding(.horizontal, 12)

            HStack(spacing: 12) {
                GlassIconButton("arrow.triangle.2.circlepath", help: "Generate again (⌘R)") { model.regenerate() }
                    .keyboardShortcut("r")
                Spacer()
                Button { model.copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(PillButtonStyle(Color.lorem))
                    .keyboardShortcut("c")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.5)
            PanelFooter(name: "Lorem") {
                Toggle("Start Text with Lorem Ipsum", isOn: $model.startWithLorem)
                Button("Generate Again") { model.regenerate() }
            }
        }
        .frame(width: 360)
    }

    private var summary: String {
        let words = model.output.split { $0.isWhitespace }.count
        return "\(words) words · \(model.output.count) characters"
    }
}

struct KindChip: View {
    @EnvironmentObject var model: LoremModel
    let kind: Kind
    @State private var hovering = false

    var body: some View {
        let selected = model.kind == kind
        Button {
            withAnimation(.snappy) { model.kind = kind }
            model.regenerate()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: kind.symbol).font(.system(size: 10.5, weight: .semibold))
                Text(kind.rawValue).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(selected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? AnyShapeStyle(LinearGradient(colors: Color.lorem, startPoint: .top, endPoint: .bottom))
                               : AnyShapeStyle(.quaternary.opacity(hovering ? 0.6 : 0.35))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Icon

//: a pilcrow on warm paper tones

func appIcon() -> NSBitmapImageRep {
    render(0xF7C890, 0xB8642C) { ctx in
        // Faint lines of text across the tile.
        ctx.setLineCap(.round)
        ctx.setLineWidth(26)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        for (i, w) in [520.0, 600, 470, 560, 380].enumerated() {
            let y = 760 - CGFloat(i) * 120
            ctx.move(to: CGPoint(x: 212, y: y)); ctx.addLine(to: CGPoint(x: 212 + w, y: y))
        }
        ctx.strokePath()

        // The pilcrow: a filled bowl and two stems.
        let bowl = CGMutablePath()
        let top: CGFloat = 790, bowlBottom: CGFloat = 470, bottom: CGFloat = 230
        bowl.move(to: CGPoint(x: 512, y: top))
        bowl.addLine(to: CGPoint(x: 512, y: bowlBottom))
        bowl.addArc(center: CGPoint(x: 512, y: (top + bowlBottom) / 2), radius: (top - bowlBottom) / 2,
                 startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        bowl.closeSubpath()
        let parts: [CGPath] = [
            bowl,
            roundedRect(CGRect(x: 480, y: bottom, width: 72, height: top - bottom), 20),
            roundedRect(CGRect(x: 612, y: bottom, width: 72, height: top - bottom), 20),
            roundedRect(CGRect(x: 480, y: top - 70, width: 204, height: 70), 20),
        ]
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 30, alpha: 0.3)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(NSColor.white.cgColor)
        // Filled one by one, so overlaps never cancel out.
        for part in parts { ctx.addPath(part); ctx.fillPath() }
        ctx.setBlendMode(.sourceIn)
        gradient([rgb(0xFFFFFF), rgb(0xFBEBDC)], from: CGPoint(x: 0, y: top), to: CGPoint(x: 0, y: bottom), in: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}
