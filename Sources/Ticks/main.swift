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
    let list = Checklist()

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusPopover(symbol: "checklist", accessibilityLabel: "Ticks") {
            TicksView().environmentObject(self.list)
        }
        list.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                let open = items.filter { !$0.done }.count
                self?.status.setSymbol(open == 0 ? "checklist.checked" : "checklist", label: "Ticks")
                self?.status.setTitle(open == 0 ? "" : "\(open)")
            }
            .store(in: &cancellables)
    }
}

// MARK: - Model

struct Item: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var done = false
    var doneAt: Date?
}

@MainActor
final class Checklist: ObservableObject {
    @Published var items: [Item] { didSet { Storage.save(items, app: "Ticks", file: "items.json") } }

    init() {
        items = Storage.load([Item].self, app: "Ticks", file: "items.json")
            ?? [Item(text: "Reply to Anna about Friday"), Item(text: "Book the dentist"), Item(text: "Water the plants"),
                Item(text: "Buy oat milk", done: true, doneAt: Date())]
    }

    var open: [Item] { items.filter { !$0.done } }
    var completed: [Item] { items.filter(\.done).sorted { ($0.doneAt ?? .distantPast) > ($1.doneAt ?? .distantPast) } }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        withAnimation(.snappy) { items.insert(Item(text: trimmed), at: 0) }
    }

    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            items[i].done.toggle()
            items[i].doneAt = items[i].done ? Date() : nil
        }
        if items[i].done { NSSound(named: "Pop")?.play() }
    }

    func rename(_ id: UUID, to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if trimmed.isEmpty { delete(id) } else { items[i].text = trimmed }
    }

    func delete(_ id: UUID) {
        withAnimation(.snappy) { items.removeAll { $0.id == id } }
    }

    func clearCompleted() {
        withAnimation(.snappy) { items.removeAll(where: \.done) }
    }
}

extension Color {
    static let ticks = [Color(red: 0.33, green: 0.86, blue: 0.86), Color(red: 0.1, green: 0.52, blue: 0.84)]
}

// MARK: - Views

struct TicksView: View {
    @EnvironmentObject var list: Checklist
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ticks[1])
                TextField("Add an item and press Return", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($inputFocused)
                    .onSubmit {
                        list.add(draft)
                        draft = ""
                        inputFocused = true
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if list.items.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("Nothing to do. Type above to add the first item.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(list.open) { item in
                            ItemRow(item: item).transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if !list.completed.isEmpty {
                            HStack {
                                Text("Done").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear") { list.clearCompleted() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color.ticks[1])
                            }
                            .padding(.horizontal, 6)
                            .padding(.top, 10)
                            .padding(.bottom, 2)
                            ForEach(list.completed) { item in
                                ItemRow(item: item).transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
            Divider().opacity(0.5)
            PanelFooter(name: "Ticks") {
                Button("Clear Completed") { list.clearCompleted() }.disabled(list.completed.isEmpty)
                Button("Clear All", role: .destructive) { withAnimation { list.items.removeAll() } }
            }
        }
        .frame(width: 340, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: .popoverDidShow)) { _ in
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    private var header: some View {
        let total = list.items.count
        let done = list.items.count - list.open.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(list.open.count == 0 && total > 0 ? "All done" : "\(list.open.count) to do")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text(total == 0 ? "Ticks" : "\(done) of \(total) completed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            ZStack {
                Circle().stroke(.quaternary.opacity(0.7), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: total == 0 ? 0 : CGFloat(done) / CGFloat(total))
                    .stroke(LinearGradient(colors: Color.ticks, startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(total > 0 && done == total ? AnyShapeStyle(Color.ticks[1]) : AnyShapeStyle(.tertiary))
            }
            .frame(width: 36, height: 36)
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: done)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct ItemRow: View {
    @EnvironmentObject var list: Checklist
    let item: Item
    @State private var hovering = false
    @State private var editing = false
    @State private var text = ""
    @State private var burst = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if !item.done {
                    burst = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { burst = false }
                }
                list.toggle(item.id)
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(item.done ? Color.clear : Color.secondary.opacity(0.55), lineWidth: 1.5)
                    Circle()
                        .fill(LinearGradient(colors: Color.ticks, startPoint: .top, endPoint: .bottom))
                        .scaleEffect(item.done ? 1 : 0.2)
                        .opacity(item.done ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .scaleEffect(item.done ? 1 : 0.3)
                        .opacity(item.done ? 1 : 0)
                }
                .frame(width: 18, height: 18)
                // A little pop when an item is ticked.
                .scaleEffect(burst ? 1.3 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.45), value: burst)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            if editing {
                TextField("Item", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { list.rename(item.id, to: text); editing = false }
                    .onExitCommand { editing = false }
            } else {
                Text(item.text)
                    .font(.system(size: 13))
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        text = item.text
                        editing = true
                        DispatchQueue.main.async { focused = true }
                    }
            }
            if hovering && !editing {
                Button { list.delete(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.45 : (item.done ? 0 : 0.22))))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .contextMenu {
            Button(item.done ? "Mark as Not Done" : "Mark as Done") { list.toggle(item.id) }
            Button("Edit") { text = item.text; editing = true; DispatchQueue.main.async { focused = true } }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.text, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { list.delete(item.id) }
        }
    }
}

// MARK: - Icon

//: a check mark sweeping out of a round tick box

func appIcon() -> NSBitmapImageRep {
    render(0x63EBDF, 0x167FCF) { ctx in
        ctx.translateBy(x: 45, y: -25)
        // Three list rows behind, as soft white bars.
        ctx.setLineCap(.round)
        ctx.setLineWidth(44)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        for (i, w) in [270.0, 200, 240].enumerated() {
            let y = 690 - CGFloat(i) * 120
            ctx.move(to: CGPoint(x: 480, y: y)); ctx.addLine(to: CGPoint(x: 480 + w, y: y))
        }
        ctx.strokePath()
        // The tick box.
        let box = CGRect(x: 205, y: 330, width: 330, height: 330)
        ctx.saveGState()
        shadow(ctx, y: -16, blur: 32, alpha: 0.3)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: box)
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addEllipse(in: box)
        ctx.clip()
        gradient([rgb(0xFFFFFF), rgb(0xDDF3FA)], from: CGPoint(x: 0, y: box.maxY), to: CGPoint(x: 0, y: box.minY), in: ctx)
        ctx.restoreGState()
        // The check, overshooting the box like a quick pen stroke.
        ctx.saveGState()
        shadow(ctx, y: -10, blur: 20, alpha: 0.3)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(70)
        ctx.setStrokeColor(rgb(0x1478C8).cgColor)
        ctx.move(to: CGPoint(x: 285, y: 505))
        ctx.addLine(to: CGPoint(x: 375, y: 410))
        ctx.addQuadCurve(to: CGPoint(x: 700, y: 780), control: CGPoint(x: 520, y: 620))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
