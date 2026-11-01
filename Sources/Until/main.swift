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
    let store = EventStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "hourglass", accessibilityLabel: "Until") {
            UntilView().environmentObject(self.store)
        }
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatus() }
            .store(in: &cancellables)
        updateStatus()
    }

    private func updateStatus() {
        guard let pinned = store.pinned else { return status.setTitle("") }
        let left = Countdown(from: store.now, to: pinned.date)
        status.setTitle((pinned.emoji.isEmpty ? "" : pinned.emoji + " ") + left.short)
    }
}

// MARK: - Model

struct Event: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var date: Date
    var emoji = ""
}

/// Time left until a date, in the largest unit that reads well.
struct Countdown: Equatable {
    let value: Int
    let unit: String
    let past: Bool

    init(from now: Date, to date: Date, calendar: Calendar = .current) {
        // An event at midnight is a whole day: it is "today" until the day is over, not "16 hours ago".
        if calendar.startOfDay(for: date) == date {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day ?? 0
            past = days < 0
            value = abs(days)
            unit = "day"
            return
        }
        let seconds = date.timeIntervalSince(now)
        past = seconds < 0
        let s = abs(seconds)
        if s < 3600 {
            value = Int((s / 60).rounded(.up))
            unit = "minute"
        } else if s < 86_400 {
            value = Int(s / 3600)
            unit = "hour"
        } else {
            // Whole calendar days, so an event tomorrow morning reads "1 day" all of today.
            let a = calendar.startOfDay(for: now), b = calendar.startOfDay(for: date)
            value = abs(calendar.dateComponents([.day], from: a, to: b).day ?? 0)
            unit = "day"
        }
    }

    var isToday: Bool { value == 0 && unit == "day" }
    var label: String { isToday ? "today" : value == 1 ? unit : unit + "s" }
    var short: String { isToday ? "today" : "\(value)\(unit.prefix(1))" }
    var sentence: String { isToday ? "today" : past ? "\(value) \(label) ago" : "in \(value) \(label)" }
}

@MainActor
final class EventStore: ObservableObject {
    @Published var events: [Event] {
        didSet { if !StatusPopover.isSnapshot { Storage.save(events, app: "Until", file: "events.json") } }
    }
    @Published var pinnedID: UUID? {
        didSet { if !StatusPopover.isSnapshot { UserDefaults.standard.set(pinnedID?.uuidString, forKey: "pinned") } }
    }
    @Published private(set) var now = Date()

    private var clock: Timer?

    init() {
        if StatusPopover.isSnapshot {
            // Fixed demo countdowns, never the user's own.
            let cal = Calendar.current, today = cal.startOfDay(for: Date())
            func day(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: today)! }
            events = [Event(name: "Summer holiday", date: day(46), emoji: "🏖️"),
                      Event(name: "Mum's birthday", date: day(12), emoji: "🎂"),
                      Event(name: "Product launch", date: cal.date(byAdding: .hour, value: 5, to: Date())!, emoji: "🚀"),
                      Event(name: "Marathon", date: day(-9), emoji: "🏅")]
            pinnedID = events[1].id
            return
        }
        events = Storage.load([Event].self, app: "Until", file: "events.json") ?? []
        pinnedID = UserDefaults.standard.string(forKey: "pinned").flatMap(UUID.init)
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
    }

    /// Upcoming events soonest first, then past events most recent first.
    var sorted: [Event] {
        // Past means the countdown says so, so a whole-day event stays upcoming all of its day.
        let upcoming = events.filter { !isPast($0) }.sorted { $0.date < $1.date }
        let past = events.filter(isPast).sorted { $0.date > $1.date }
        return upcoming + past
    }

    func isPast(_ event: Event) -> Bool { Countdown(from: now, to: event.date).past }

    var pinned: Event? { events.first { $0.id == pinnedID } }

    func save(_ event: Event) {
        withAnimation(.snappy) {
            if let i = events.firstIndex(where: { $0.id == event.id }) { events[i] = event } else { events.append(event) }
        }
        if pinnedID == nil { pinnedID = event.id }
    }

    func delete(_ id: UUID) {
        withAnimation(.snappy) { events.removeAll { $0.id == id } }
        if pinnedID == id { pinnedID = nil }
    }

    func togglePin(_ id: UUID) { pinnedID = pinnedID == id ? nil : id }
}

extension Color {
    static let until = [Color(red: 1, green: 0.7, blue: 0.36), Color(red: 0.66, green: 0.24, blue: 0.56)]
}

// MARK: - Views

struct UntilView: View {
    @EnvironmentObject var store: EventStore
    @State private var draft: Event?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Until").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                GlassIconButton(draft == nil ? "plus" : "xmark", help: draft == nil ? "New countdown" : "Cancel") {
                    withAnimation(.snappy) {
                        // New countdowns start as a whole day a week from today.
                        draft = draft == nil ? Event(name: "", date: Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: Date()))!) : nil
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let binding = Binding($draft) {
                EventForm(event: binding, save: { event in
                    store.save(event)
                    withAnimation(.snappy) { draft = nil }
                }, close: { withAnimation(.snappy) { draft = nil } })
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if store.events.isEmpty && draft == nil {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("Add a trip, a birthday or a deadline\nand watch the days count down.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(store.sorted) { event in
                            EventRow(event: event) { withAnimation(.snappy) { draft = event } }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Until") {
                Button("Unpin from Menu Bar") { store.pinnedID = nil }.disabled(store.pinnedID == nil)
                Button("Delete Past Events") {
                    for e in store.events where store.isPast(e) { store.delete(e.id) }
                }
            }
        }
        .frame(width: 350, height: 460)
    }
}

struct EventRow: View {
    @EnvironmentObject var store: EventStore
    let event: Event
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        let left = Countdown(from: store.now, to: event.date)
        let pinned = store.pinnedID == event.id
        HStack(spacing: 11) {
            Text(event.emoji.isEmpty ? "📅" : event.emoji)
                .font(.system(size: 20))
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.6)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(event.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.until[1]).help("Shown in the menu bar")
                    }
                }
                Text(event.date.formatted(date: .abbreviated, time: hasTime ? .shortened : .omitted) + (left.past ? " · " + left.sentence : ""))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !left.past {
                VStack(alignment: .trailing, spacing: -2) {
                    Text(left.isToday ? "Today" : "\(left.value)")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(LinearGradient(colors: Color.until, startPoint: .top, endPoint: .bottom))
                        .contentTransition(.numericText(value: Double(left.value)))
                    Text(left.isToday ? "" : left.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(hovering ? 0.5 : 0.28)))
        .opacity(left.past ? 0.5 : 1)
        .saturation(left.past ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button(pinned ? "Unpin from Menu Bar" : "Show in Menu Bar") { store.togglePin(event.id) }
            Button("Edit", action: edit)
            Divider()
            Button("Delete", role: .destructive) { store.delete(event.id) }
        }
        .help("Double-click to edit, right-click to pin")
    }

    private var hasTime: Bool {
        let c = Calendar.current.dateComponents([.hour, .minute], from: event.date)
        return c.hour != 0 || c.minute != 0
    }
}

struct EventForm: View {
    @EnvironmentObject var store: EventStore
    @Binding var event: Event
    let save: (Event) -> Void
    let close: () -> Void
    @FocusState private var nameFocused: Bool

    private let emojis = ["🎂", "✈️", "🏖️", "🎄", "🎆", "💍", "🎓", "🚀", "📦", "⚽️", "🎉", "❤️"]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Button("None") { event.emoji = "" }
                    ForEach(emojis, id: \.self) { e in Button(e) { event.emoji = e } }
                } label: {
                    Text(event.emoji.isEmpty ? "📅" : event.emoji).font(.system(size: 18))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Choose an emoji")
                TextField("What are you counting down to?", text: $event.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($nameFocused)
                    .onSubmit(submit)
            }
            HStack {
                DatePicker("", selection: $event.date, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
                Spacer()
                if store.events.contains(where: { $0.id == event.id }) {
                    Button { store.delete(event.id); close() } label: {
                        Image(systemName: "trash").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete")
                }
                Button("Save", action: submit)
                    .buttonStyle(PillButtonStyle(Color.until))
                    .disabled(event.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.4)))
        .onAppear { DispatchQueue.main.async { nameFocused = true } }
    }

    private func submit() {
        var e = event
        e.name = e.name.trimmingCharacters(in: .whitespaces)
        guard !e.name.isEmpty else { return }
        save(e)
    }
}

// MARK: - Icon

//: an hourglass with golden sand running through

func appIcon() -> NSBitmapImageRep {
    render(0xFFB65C, 0x9B3A8F) { ctx in
        let cx: CGFloat = 512
        // The two glass bulbs as one outline.
        let glass = CGMutablePath()
        glass.move(to: CGPoint(x: cx - 190, y: 735))
        glass.addLine(to: CGPoint(x: cx + 190, y: 735))
        glass.addCurve(to: CGPoint(x: cx + 26, y: 512), control1: CGPoint(x: cx + 190, y: 610), control2: CGPoint(x: cx + 26, y: 590))
        glass.addCurve(to: CGPoint(x: cx + 190, y: 289), control1: CGPoint(x: cx + 26, y: 434), control2: CGPoint(x: cx + 190, y: 414))
        glass.addLine(to: CGPoint(x: cx - 190, y: 289))
        glass.addCurve(to: CGPoint(x: cx - 26, y: 512), control1: CGPoint(x: cx - 190, y: 414), control2: CGPoint(x: cx - 26, y: 434))
        glass.addCurve(to: CGPoint(x: cx - 190, y: 735), control1: CGPoint(x: cx - 26, y: 590), control2: CGPoint(x: cx - 190, y: 610))
        glass.closeSubpath()

        ctx.saveGState()
        shadow(ctx, y: -14, blur: 30, alpha: 0.3)
        ctx.addPath(glass)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Sand: a little left on top, a mound below, and the falling stream.
        ctx.saveGState()
        ctx.addPath(glass)
        ctx.clip()
        let sand = [rgb(0xFFD36B), rgb(0xF29A2E)]
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 512, width: 1024, height: 110))
        gradient(sand, from: CGPoint(x: 0, y: 622), to: CGPoint(x: 0, y: 512), in: ctx)
        ctx.restoreGState()
        let mound = CGMutablePath()
        mound.move(to: CGPoint(x: cx - 220, y: 289))
        mound.addLine(to: CGPoint(x: cx - 220, y: 330))
        mound.addQuadCurve(to: CGPoint(x: cx, y: 440), control: CGPoint(x: cx - 120, y: 330))
        mound.addQuadCurve(to: CGPoint(x: cx + 220, y: 330), control: CGPoint(x: cx + 120, y: 330))
        mound.addLine(to: CGPoint(x: cx + 220, y: 289))
        mound.closeSubpath()
        ctx.addPath(mound)
        ctx.clip()
        gradient(sand, from: CGPoint(x: 0, y: 440), to: CGPoint(x: 0, y: 289), in: ctx)
        ctx.restoreGState()
        ctx.setFillColor(rgb(0xF5A83A).cgColor)
        ctx.fill(CGRect(x: cx - 7, y: 430, width: 14, height: 90))

        // Highlight on the upper bulb.
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(16)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: cx - 140, y: 700))
        ctx.addQuadCurve(to: CGPoint(x: cx - 70, y: 600), control: CGPoint(x: cx - 140, y: 640))
        ctx.strokePath()

        // Wooden caps.
        for y: CGFloat in [735, 245] {
            ctx.saveGState()
            shadow(ctx, y: -8, blur: 16, alpha: 0.3)
            ctx.addPath(roundedRect(CGRect(x: cx - 240, y: y, width: 480, height: 44), 22))
            ctx.setFillColor(rgb(0x5B2A55).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(roundedRect(CGRect(x: cx - 232, y: y + 24, width: 464, height: 14), 7))
            ctx.setFillColor(rgb(0x8A4A80).cgColor)
            ctx.fillPath()
        }
    }
}
