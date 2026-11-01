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
    let store = CounterStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "plusminus.circle", accessibilityLabel: "Tally") {
            TallyView().environmentObject(self.store)
        }
        // Right-click adds one to the first counter.
        status.onSecondaryClick = { [weak self] in
            guard let self, let first = self.store.counters.first else { return }
            self.store.bump(first.id, by: 1)
        }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        if store.showInMenuBar, let first = store.counters.first {
            status.setTitle(first.value.formatted())
        } else {
            status.setTitle("")
        }
    }
}

// MARK: - Model

struct Counter: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var value = 0
    var color = 0
    var dailyReset = false
    var day = Counter.today

    /// The local calendar day; a plain `.iso8601` style would use UTC and roll over at 02:00 or 03:00 in Athens.
    static var today: String { Date().formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()) }
}

@MainActor
final class CounterStore: ObservableObject {
    @Published var counters: [Counter] {
        didSet { if !StatusPopover.isSnapshot { Storage.save(counters, app: "Tally", file: "counters.json") } }
    }
    @Published var renaming: UUID?
    @AppStorage("showInMenuBar") var showInMenuBar = true { willSet { objectWillChange.send() } }

    private var clock: Timer?

    init() {
        if StatusPopover.isSnapshot {
            // Fixed demo counters, never the user's own.
            counters = [Counter(name: "Glasses of water", value: 6, color: 1, dailyReset: true),
                        Counter(name: "Push-ups", value: 40, color: 3),
                        Counter(name: "Books this year", value: 12, color: 2)]
            return
        }
        counters = Storage.load([Counter].self, app: "Tally", file: "counters.json")
            ?? [Counter(name: "Counter")]
        rollOver()
        let clock = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rollOver() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    /// Zeroes daily counters the first time they are seen on a new day.
    func rollOver() {
        let today = Counter.today
        for i in counters.indices where counters[i].dailyReset && counters[i].day != today {
            counters[i].value = 0
            counters[i].day = today
        }
    }

    func bump(_ id: UUID, by delta: Int) {
        rollOver()
        guard let i = counters.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) {
            counters[i].value += delta
            counters[i].day = Counter.today
        }
    }

    func update(_ id: UUID, _ change: (inout Counter) -> Void) {
        guard let i = counters.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { change(&counters[i]) }
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let used = Set(counters.map(\.color))
        let color = Palette.all.indices.first { !used.contains($0) } ?? counters.count % Palette.all.count
        withAnimation(.snappy) { counters.append(Counter(name: trimmed, color: color)) }
    }

    func delete(_ id: UUID) {
        withAnimation(.snappy) { counters.removeAll { $0.id == id } }
    }

    func moveToTop(_ id: UUID) {
        guard let i = counters.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.snappy) { counters.insert(counters.remove(at: i), at: 0) }
    }
}

enum Palette {
    static let all: [(name: String, colors: [Color])] = [
        ("Lime", [Color(red: 0.62, green: 0.88, blue: 0.3), Color(red: 0.2, green: 0.62, blue: 0.27)]),
        ("Ocean", [Color(red: 0.35, green: 0.78, blue: 1), Color(red: 0.12, green: 0.45, blue: 0.9)]),
        ("Grape", [Color(red: 0.75, green: 0.52, blue: 1), Color(red: 0.48, green: 0.25, blue: 0.88)]),
        ("Sunset", [Color(red: 1, green: 0.7, blue: 0.3), Color(red: 0.95, green: 0.4, blue: 0.2)]),
        ("Berry", [Color(red: 1, green: 0.45, blue: 0.6), Color(red: 0.85, green: 0.15, blue: 0.4)]),
        ("Graphite", [Color(red: 0.6, green: 0.63, blue: 0.7), Color(red: 0.32, green: 0.35, blue: 0.42)]),
    ]

    static func colors(_ i: Int) -> [Color] { all[i % all.count].colors }
}

// MARK: - Views

struct TallyView: View {
    @EnvironmentObject var store: CounterStore
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tally").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                Text(total).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 8)

            if store.counters.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "plusminus.circle").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Count anything: glasses of water, laps, cups of coffee.\nName your first counter below.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.counters) { counter in
                            CounterCard(counter: counter)
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15)).foregroundStyle(Palette.colors(0)[1])
                TextField("New counter", text: $newName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit { store.add(newName); newName = "" }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)

            Divider().opacity(0.5)
            PanelFooter(name: "Tally") {
                Toggle("Show First Counter in Menu Bar", isOn: $store.showInMenuBar)
                Button("Reset All Counters") { for c in store.counters { store.update(c.id) { $0.value = 0 } } }
            }
        }
        .frame(width: 340, height: 470)
    }

    private var total: String {
        let n = store.counters.count
        return "\(n) counter\(n == 1 ? "" : "s")"
    }
}

struct CounterCard: View {
    @EnvironmentObject var store: CounterStore
    let counter: Counter
    @State private var hovering = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var colors: [Color] { Palette.colors(counter.color) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if store.renaming == counter.id {
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, weight: .semibold))
                        .focused($nameFocused)
                        .onSubmit { commitName() }
                        .onAppear { name = counter.name; DispatchQueue.main.async { nameFocused = true } }
                        // Clicking away keeps the new name instead of leaving the field open.
                        .onChange(of: nameFocused) { _, focused in if !focused, store.renaming == counter.id { commitName() } }
                } else {
                    Text(counter.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { store.renaming = counter.id }
                }
                if counter.dailyReset {
                    Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 10)).foregroundStyle(colors[1]).help("Resets every day")
                }
                Spacer()
                menu.opacity(hovering ? 1 : 0.5)
            }
            HStack {
                RoundButton(symbol: "minus", colors: colors, filled: false) { store.bump(counter.id, by: -1) }
                Spacer()
                Text(counter.value.formatted())
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText(value: Double(counter.value)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer()
                RoundButton(symbol: "plus", colors: colors, filled: true) { store.bump(counter.id, by: 1) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.3)))
        .overlay(alignment: .leading) {
            Capsule().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                .frame(width: 4).padding(.vertical, 12)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu { menuItems }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { store.update(counter.id) { $0.name = trimmed } }
        store.renaming = nil
    }

    private var menu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        Button("Rename") { store.renaming = counter.id }
        Menu("Colour") {
            ForEach(Palette.all.indices, id: \.self) { i in
                Button { store.update(counter.id) { $0.color = i } } label: {
                    if i == counter.color { Label(Palette.all[i].name, systemImage: "checkmark") } else { Text(Palette.all[i].name) }
                }
            }
        }
        Toggle("Reset Every Day", isOn: Binding(get: { counter.dailyReset },
                                               set: { v in store.update(counter.id) { $0.dailyReset = v; $0.day = Counter.today } }))
        Button("Show in Menu Bar") { store.moveToTop(counter.id) }.disabled(store.counters.first?.id == counter.id)
        Divider()
        Button("Reset to Zero") { store.update(counter.id) { $0.value = 0 } }
        Button("Delete", role: .destructive) { store.delete(counter.id) }
    }
}

struct RoundButton: View {
    let symbol: String
    let colors: [Color]
    let filled: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(colors[1]))
                .frame(width: 44, height: 44)
                .background {
                    if filled {
                        Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                            .shadow(color: colors[1].opacity(0.35), radius: hovering ? 6 : 3, y: 2)
                    } else {
                        Circle().fill(colors[1].opacity(hovering ? 0.22 : 0.13))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Icon

//: four tally marks struck through on a card

func appIcon() -> NSBitmapImageRep {
    render(0xB8EE5A, 0x2A8A3E) { ctx in
        let card = CGRect(x: 232, y: 262, width: 560, height: 500)
        ctx.saveGState()
        shadow(ctx, y: -18, blur: 36, alpha: 0.3)
        ctx.addPath(roundedRect(card, 70))
        ctx.setFillColor(rgb(0xFBFFF4).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // Inner soft shading at the card bottom.
        ctx.saveGState()
        ctx.addPath(roundedRect(card, 70))
        ctx.clip()
        gradient([rgb(0xFFFFFF, 0), rgb(0xD8EFC4, 0.7)], from: CGPoint(x: 0, y: card.midY), to: CGPoint(x: 0, y: card.minY), in: ctx)
        ctx.restoreGState()

        ctx.setLineCap(.round)
        ctx.setLineWidth(52)
        ctx.setStrokeColor(rgb(0x2F7D3B).cgColor)
        for i in 0..<4 {
            let x = 352 + CGFloat(i) * 104
            let lean = CGFloat(i % 2 == 0 ? 6 : -4)
            ctx.move(to: CGPoint(x: x - lean, y: 352)); ctx.addLine(to: CGPoint(x: x + lean, y: 672))
        }
        ctx.strokePath()
        // The fifth mark, struck across.
        ctx.saveGState()
        shadow(ctx, y: -6, blur: 14, alpha: 0.25)
        ctx.setLineWidth(56)
        ctx.setStrokeColor(rgb(0xFF5A4E).cgColor)
        ctx.move(to: CGPoint(x: 290, y: 400)); ctx.addLine(to: CGPoint(x: 734, y: 628))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
