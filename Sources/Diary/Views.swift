import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(nsColor: rgb(0xE97A9A))
    static let bottom = Color(nsColor: rgb(0xA93A62))
    static let accent = Color(nsColor: rgb(0xC9527A))
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Tag text: the deep rose in light mode, a pale rose in dark mode so it stays readable.
    static let tagText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0xF4A9C0) : rgb(0xA93A62)
    })
}

struct ContentView: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        Group {
            if model.locked {
                LockView(model: model)
                    .transition(.opacity)
            } else {
                DiaryView(model: model)
                    .transition(.opacity)
            }
        }
        .tint(Theme.accent)
        .frame(minWidth: 780, minHeight: 520)
        .alert("Diary", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
    }
}

// MARK: - Main window

struct DiaryView: View {
    @ObservedObject var model: DiaryStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 272, ideal: 290, max: 340)
        } detail: {
            EditorView(model: model)
        }
        .navigationTitle("Diary")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button { model.step(days: -1) } label: { Label("Previous Day", systemImage: "chevron.left") }
                        .help("Previous day (⌘[)")
                    Button("Today") { model.goToday() }
                        .help("Go to today (⌘T)")
                    Button { model.step(days: 1) } label: { Label("Next Day", systemImage: "chevron.right") }
                        .help("Next day (⌘])")
                }
                Button { model.exportAll() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export all entries to Markdown (⇧⌘E)")
                    .disabled(!model.hasEntries)
                Button { model.lock() } label: { Label("Lock", systemImage: "lock") }
                    .help("Lock Diary (⌃⌘L)")
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }
}

// MARK: - Sidebar

/// The system search field, with Escape to clear and a way for the Search Entries menu item to focus it.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let focusRequest: Int

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        // The clear button sends the action, not a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.searched(_:))
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        field.focusRingType = .default
        field.refusesFirstResponder = Desktop.isSnapshot
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int

        init(text: Binding<String>, focusRequest: Int) {
            self.text = text
            self.focusRequest = focusRequest
        }

        @objc func searched(_ field: NSSearchField) {
            if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct Sidebar: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query, prompt: "Search entries", focusRequest: model.searchFocusRequest)
                .frame(height: 28)
                .padding(.horizontal, 14)
                .padding(.top, 4)
                .padding(.bottom, 12)
            ScrollView {
                sections
            }
        }
    }

    private var sections: some View {
            VStack(alignment: .leading, spacing: 16) {
                MonthCalendar(model: model)
                if model.isSearching {
                    SearchResults(model: model)
                } else {
                    StatsRow(stats: model.stats)
                    OnThisDay(model: model)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
    }
}

struct MonthCalendar: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        let month = model.visibleMonth
        let cells = Journal.monthGrid(year: month.year, month: month.month, calendar: model.calendar)
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(month.date(model.calendar).formatted(.dateTime.month(.wide).year()))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                Spacer()
                SmallIconButton(symbol: "chevron.left", help: "Previous month (⌥⌘[)") { model.step(months: -1) }
                SmallIconButton(symbol: "chevron.right", help: "Next month (⌥⌘])") { model.step(months: 1) }
            }
            .padding(.horizontal, 4)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(Journal.weekdaySymbols(model.calendar).enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(cells.count / 7), id: \.self) { row in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            if let day = cells[row * 7 + column] {
                                DayCell(day: day, entry: model.entry(day), selected: day == model.selected,
                                        isToday: day == model.today, future: model.isFuture(day)) { model.select(day) }
                            } else {
                                Color.clear.frame(height: 34)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

struct DayCell: View {
    let day: Day
    let entry: Entry?
    let selected: Bool
    let isToday: Bool
    let future: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(day.day)")
                    .font(.system(size: 12.5, weight: isToday || selected ? .bold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : isToday ? AnyShapeStyle(Theme.accent)
                        : future ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
                    .opacity(entry == nil ? 0 : 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0)))
                    .shadow(color: selected ? Theme.bottom.opacity(0.3) : .clear, radius: 3, y: 1.5)
            }
            .overlay {
                if isToday && !selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
    }

    private var dotColor: Color {
        if selected { return .white }
        return entry?.mood?.color ?? Color.secondary
    }

    private var help: String {
        guard let entry else { return future ? "Not yet" : "No entry" }
        var parts = ["\(entry.words) words"]
        if let mood = entry.mood { parts.insert(mood.name, at: 0) }
        return parts.joined(separator: ", ")
    }
}

struct SmallIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary.opacity(hovering ? 0.9 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct StatsRow: View {
    let stats: Stats

    var body: some View {
        HStack(spacing: 8) {
            StatTile(value: stats.entries, label: stats.entries == 1 ? "entry" : "entries", symbol: "book.closed.fill")
            StatTile(value: stats.words, label: "words", symbol: "text.word.spacing")
            StatTile(value: stats.streak, label: stats.streak == 1 ? "day streak" : "day streak", symbol: "flame.fill")
                .help("Longest streak: \(stats.longest) days")
        }
    }
}

struct StatTile: View {
    let value: Int
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.gradient)
            Text(value.formatted())
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary.opacity(0.35)))
    }
}

struct OnThisDay: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        let past = model.onThisDay(model.selected)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "On this day", symbol: "clock.arrow.circlepath")
            if past.isEmpty {
                Text("Nothing from earlier years on \(model.selected.date(model.calendar).formatted(.dateTime.day().month(.wide))) yet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(past) { entry in
                    EntryCard(entry: entry, title: ago(entry), query: "") { model.select(entry.day) }
                }
            }
        }
    }

    private func ago(_ entry: Entry) -> String {
        let years = model.selected.year - entry.day.year
        return years == 1 ? "1 year ago, \(entry.day.year)" : "\(years) years ago, \(entry.day.year)"
    }
}

struct SearchResults: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        let results = model.results
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: results.count == 1 ? "1 entry" : "\(results.count) entries", symbol: "magnifyingglass")
            if results.isEmpty {
                Text("No entries match \u{201C}\(model.query.trimmingCharacters(in: .whitespaces))\u{201D}.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                ForEach(results.prefix(60)) { entry in
                    EntryCard(entry: entry, title: entry.day.date(model.calendar).formatted(.dateTime.day().month(.abbreviated).year()),
                              query: model.query, selected: entry.day == model.selected) { model.select(entry.day) }
                }
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }
}

struct EntryCard: View {
    let entry: Entry
    let title: String
    let query: String
    var selected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    Spacer()
                    if let mood = entry.mood {
                        Image(systemName: mood.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(mood.color)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                Text(Journal.snippet(entry.text, query: query, radius: 60))
                    .font(.system(size: 12, design: .serif))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.quaternary.opacity(hovering ? 0.7 : 0.35))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.2)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        let day = model.selected
        Group {
            if model.isFuture(day) {
                ContentUnavailableView {
                    Label("Not written yet", systemImage: "calendar.badge.clock")
                } description: {
                    Text("\(Journal.longDate(day, calendar: model.calendar)) is still ahead. Come back that day to write it.")
                } actions: {
                    Button("Go to Today") { model.goToday() }.buttonStyle(.borderedProminent)
                }
            } else {
                page(day)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func page(_ day: Day) -> some View {
        let entry = model.entries[day]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(day.date(model.calendar).formatted(.dateTime.weekday(.wide)))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        if day == model.today {
                            Text("Today")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2.5)
                                .background(Capsule().fill(Theme.gradient))
                        }
                    }
                    Text(day.date(model.calendar).formatted(.dateTime.day().month(.wide).year()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                MoodPicker(mood: entry?.mood) { model.setMood($0, for: day) }
            }
            TagRow(tags: entry?.tags ?? [], add: { model.addTags($0, to: day) }, remove: { model.removeTag($0, from: day) })
                .id(day)
                .padding(.top, 14)
            Divider().padding(.top, 14).padding(.bottom, 10)
            ZStack(alignment: .topLeading) {
                TextEditor(text: Binding(get: { model.entries[day]?.text ?? "" }, set: { model.setText($0, for: day) }))
                    .font(.system(size: 15, design: .serif))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    // The text view insets its line fragments by 5 points; pull it back so text lines up with the date.
                    .padding(.leading, -5)
                    .id(day)
                if (entry?.text ?? "").isEmpty {
                    Text(day == model.today ? "What is on your mind today?" : "What happened on this day?")
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            HStack {
                Text(footer(entry))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                if let entry {
                    Text("Edited \(entry.modified.formatted(date: entry.modified.isSameDay(as: Date()) ? .omitted : .abbreviated, time: .shortened))")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
        }
        .padding(.horizontal, 40)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private func footer(_ entry: Entry?) -> String {
        let words = entry?.words ?? 0
        return words == 1 ? "1 word" : "\(words) words"
    }
}

extension Date {
    func isSameDay(as other: Date) -> Bool { Calendar.current.isDate(self, inSameDayAs: other) }
}

struct MoodPicker: View {
    let mood: Mood?
    let set: (Mood?) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                ForEach(Mood.allCases) { option in
                    MoodButton(mood: option, selected: option == mood) {
                        withAnimation(.snappy(duration: 0.2)) { set(option == mood ? nil : option) }
                    }
                }
            }
            Text(mood.map { "Feeling \($0.name.lowercased())" } ?? "How was the day?")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }
}

struct MoodButton: View {
    let mood: Mood
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: mood.symbol)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(selected ? .monochrome : .hierarchical)
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(mood.color))
                .frame(width: 32, height: 32)
                .background {
                    Circle()
                        .fill(selected ? AnyShapeStyle(mood.color.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.9 : 0.45)))
                        .shadow(color: selected ? mood.color.opacity(0.4) : .clear, radius: 4, y: 2)
                }
                .scaleEffect(selected ? 1.08 : (hovering ? 1.04 : 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(mood.name)
        .accessibilityLabel(mood.name)
    }
}

struct TagRow: View {
    let tags: [String]
    let add: (String) -> Void
    let remove: (String) -> Void
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                TagChip(tag: tag) { withAnimation(.snappy(duration: 0.18)) { remove(tag) } }
            }
            HStack(spacing: 4) {
                Image(systemName: "number").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                TextField("Add tag", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 90)
                    .onSubmit {
                        withAnimation(.snappy(duration: 0.18)) { add(draft) }
                        draft = ""
                    }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
        }
    }
}

struct TagChip: View {
    let tag: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text("#" + tag)
                .font(.system(size: 12, weight: .medium))
            if hovering {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Remove tag")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .foregroundStyle(Theme.tagText)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.top.opacity(0.16)))
        .onHover { value in withAnimation(.snappy(duration: 0.15)) { hovering = value } }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min(width, $0) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Lock

struct LockView: View {
    @ObservedObject var model: DiaryStore

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.gradient).frame(width: 84, height: 84)
                    .shadow(color: Theme.bottom.opacity(0.35), radius: 12, y: 5)
                Image(systemName: "lock.fill").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(spacing: 6) {
                Text("Diary is locked").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Unlock with Touch ID or your Mac password to read and write.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Button { model.unlock() } label: {
                Label("Unlock", systemImage: "touchid").padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            if let message = model.lockMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard model.promptToUnlock, !Desktop.isSnapshot else { return }
            model.promptToUnlock = false
            model.unlock()
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: DiaryStore
    @AppStorage(Prefs.lockEnabled) private var lockEnabled = false
    @AppStorage(Prefs.lockOnSleep) private var lockOnSleep = true

    var body: some View {
        Form {
            Section {
                Toggle("Require Touch ID or password to open Diary", isOn: $lockEnabled)
                    .disabled(!DiaryStore.canAuthenticate && !lockEnabled)
                Toggle("Lock when the Mac sleeps or the screen locks", isOn: $lockOnSleep)
                    .disabled(!lockEnabled)
            } header: {
                Text("Privacy")
            } footer: {
                Text(DiaryStore.canAuthenticate
                     ? (model.locked ? "Unlock Diary to change these settings." : "Lock Diary from the File menu at any time with ⌃⌘L.")
                     : "Set a login password for this Mac to use the lock.")
                    .foregroundStyle(.secondary)
            }
            Section("Storage") {
                LabeledContent("Entries") {
                    Text("Saved only on this Mac").foregroundStyle(.secondary)
                }
                Button("Show Diary Data in Finder") {
                    let file = Storage.url(app: DiaryStore.appName, file: DiaryStore.file)
                    revealInFinder([FileManager.default.fileExists(atPath: file.path) ? file : file.deletingLastPathComponent()])
                }
            }
        }
        .formStyle(.grouped)
        // While the diary is locked nobody may switch the lock off or go looking for the file.
        .disabled(model.locked)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
