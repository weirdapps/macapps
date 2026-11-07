import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(hex: 0xFFA41B)
    static let bottom = Color(hex: 0xF0541E)
    static let accent = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let card = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: StreakModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let habit = model.selected {
                HabitDetail(model: model, habit: habit)
            } else {
                ContentUnavailableView {
                    Label(model.habits.isEmpty ? "No habits yet" : "No habit selected", systemImage: "flame")
                } description: {
                    Text(model.habits.isEmpty ? "Add a habit, then tick it off each day to grow a streak."
                        : "Pick a habit in the sidebar to see its year.")
                } actions: {
                    if model.habits.isEmpty {
                        Button("New Habit") { model.editing = EditorState() }
                            .buttonStyle(.borderedProminent).tint(Theme.bottom).controlSize(.large)
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .toolbar { Toolbar(model: model) }
        .sheet(item: $model.editing) { state in
            HabitEditor(model: model, state: state)
        }
        .confirmationDialog("Delete \(model.selected?.name ?? "habit")?", isPresented: $model.confirmingDelete) {
            Button("Delete Habit", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("Its check-ins and notes go too. You can undo this.")
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: model.selection) { model.selectedDay = model.today }
    }
}

struct Toolbar: ToolbarContent {
    @ObservedObject var model: StreakModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.editing = EditorState() } label: { Label("New Habit", systemImage: "plus") }
                .help("New habit (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            ControlGroup {
                Button { model.shiftYear(-1) } label: { Label("Previous Year", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack).help("Previous year (⌘[)")
                Button { model.shiftYear(1) } label: { Label("Next Year", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward).help("Next year (⌘])")
            }
            .disabled(model.selected == nil)
            Menu {
                RangeMenuItems(model: model)
            } label: {
                Text(model.rangeTitle).monospacedDigit()
            }
            .disabled(model.selected == nil)
            .help("Choose the period the grid shows")
            Button { model.toggleToday() } label: {
                let done = model.selected.map { $0.done.contains(model.today) } ?? false
                Label("Check Off Today", systemImage: done ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .disabled(model.selected == nil)
            .help("Check off today (⌘T)")
        }
    }
}

struct RangeMenuItems: View {
    @ObservedObject var model: StreakModel

    var body: some View {
        Picker("Period", selection: $model.range) {
            Text("Past 12 Months").tag(HeatRange.pastYear)
            Divider()
            ForEach(Array(stride(from: model.currentYear, through: model.earliestYear, by: -1)), id: \.self) { y in
                Text(String(y)).tag(HeatRange.year(y))
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: StreakModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Habits") {
                ForEach(model.habits) { habit in
                    HabitRow(model: model, habit: habit)
                        .tag(habit.id)
                        .contextMenu {
                            Button(habit.done.contains(model.today) ? "Uncheck Today" : "Check Off Today") {
                                model.toggle(habit.id, on: model.today)
                            }
                            Divider()
                            Button("Edit Habit…") { model.editing = EditorState(habit) }
                            Button("Delete Habit…") {
                                model.selection = habit.id
                                model.confirmingDelete = true
                            }
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.habits.isEmpty {
                Text("Your habits appear here.").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

struct HabitRow: View {
    @ObservedObject var model: StreakModel
    let habit: Habit
    @State private var hovering = false

    var body: some View {
        let stats = model.stats(habit)
        let doneToday = habit.done.contains(model.today)
        HStack(spacing: 10) {
            HabitBadge(habit: habit, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 9))
                        .foregroundStyle(stats.current > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                    Text("\(stats.current) \(habit.target.unit(stats.current))")
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { model.toggle(habit.id, on: model.today) } label: {
                Image(systemName: doneToday ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(doneToday ? AnyShapeStyle(habit.tint.color) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(doneToday ? "Uncheck today" : "Check off today")
        }
        .padding(.vertical, 3)
        .animation(.snappy, value: doneToday)
    }
}

struct HabitBadge: View {
    let habit: Habit
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(habit.tint.color.gradient)
            if habit.iconIsSymbol {
                Image(systemName: habit.icon)
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(habit.icon).font(.system(size: size * 0.56))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: habit.tint.color.opacity(0.3), radius: size * 0.08, y: size * 0.04)
    }
}

// MARK: - Detail

struct HabitDetail: View {
    @ObservedObject var model: StreakModel
    let habit: Habit

    var body: some View {
        let stats = model.stats(habit)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(stats)
                HStack(spacing: 12) {
                    StatCard(title: "Current streak", symbol: "flame.fill", value: stats.current,
                             unit: habit.target.unit(stats.current), tint: habit.tint.color)
                    StatCard(title: "Longest streak", symbol: "trophy.fill", value: stats.longest,
                             unit: habit.target.unit(stats.longest), tint: habit.tint.color)
                    RateCard(rate: stats.rate, tint: habit.tint.color)
                }
                HStack(alignment: .top, spacing: 12) {
                    WeekCard(model: model, habit: habit, stats: stats)
                    DayCard(model: model, habit: habit)
                        .frame(width: 270)
                }
                .fixedSize(horizontal: false, vertical: true)
                HeatmapCard(model: model, habit: habit)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(habit.name)
    }

    private func header(_ stats: Stats) -> some View {
        let doneToday = habit.done.contains(model.today)
        return HStack(spacing: 14) {
            HabitBadge(habit: habit, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(habit.name).font(.system(size: 24, weight: .bold, design: .rounded)).lineLimit(1)
                Text(subtitle(stats)).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.toggle(habit.id, on: model.today) } label: {
                Label(doneToday ? "Done today" : "Check off today",
                      systemImage: doneToday ? "checkmark.circle.fill" : "circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PillButtonStyle(doneToday ? [habit.tint.color.opacity(0.75), habit.tint.color]
                                                   : [Theme.top, Theme.bottom]))
            .animation(.snappy, value: doneToday)
        }
    }

    private func subtitle(_ stats: Stats) -> String {
        let since = model.format(habit.created, "dMMMMyyyy")
        return "\(habit.target.label), since \(since)"
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct CardTitle: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
    }
}

struct StatCard: View {
    let title: String
    let symbol: String
    let value: Int
    let unit: String
    let tint: Color

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardTitle(text: title, symbol: symbol, tint: tint)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(value)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(unit).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                }
            }
        }
        .animation(.snappy, value: value)
    }
}

struct RateCard: View {
    let rate: Double
    let tint: Color

    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle(text: "Last 30 days", symbol: "chart.bar.fill", tint: tint)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(Int((rate * 100).rounded()))")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("%").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 6)
                    Circle().trim(from: 0, to: rate)
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 40, height: 40)
            }
        }
        .animation(.snappy, value: rate)
    }
}

// MARK: - This week

struct WeekCard: View {
    @ObservedObject var model: StreakModel
    let habit: Habit
    let stats: Stats

    var body: some View {
        let start = model.today.weekStart(firstWeekday: model.firstWeekday)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    CardTitle(text: "This week")
                    Spacer()
                    Text(progress(start)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        DayDot(model: model, habit: habit, day: start.adding(i))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func progress(_ start: Day) -> String {
        switch habit.target {
        case .daily:
            let elapsed = model.today.n - start.n + 1
            return "\(stats.thisWeek) of \(elapsed) \(elapsed == 1 ? "day" : "days") so far"
        case .weekly(let n):
            return stats.thisWeek >= n ? "Goal met: \(stats.thisWeek) of \(n)" : "\(stats.thisWeek) of \(n) this week"
        }
    }
}

struct DayDot: View {
    @ObservedObject var model: StreakModel
    let habit: Habit
    let day: Day
    @State private var hovering = false

    var body: some View {
        let done = habit.done.contains(day)
        let isToday = day == model.today
        let future = day > model.today
        let selected = day == model.selectedDay
        VStack(spacing: 6) {
            Text(model.weekdaySymbol(day))
                .font(.system(size: 11, weight: isToday ? .bold : .medium))
                .foregroundStyle(isToday ? AnyShapeStyle(habit.tint.color) : AnyShapeStyle(.secondary))
            Button {
                model.selectedDay = day
                model.toggle(habit.id, on: day)
            } label: {
                ZStack {
                    Circle()
                        .fill(done ? AnyShapeStyle(habit.tint.color.gradient)
                            : AnyShapeStyle(Color.primary.opacity(hovering && !future ? 0.1 : 0.05)))
                    if isToday && !done {
                        Circle().strokeBorder(habit.tint.color, lineWidth: 2)
                    }
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Text("\(day.ymd.day)").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(future ? .tertiary : .primary)
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(future)
            .onHover { hovering = $0 }
            .help(model.format(day, "EEEEdMMMM"))
            Circle().fill(selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear)).frame(width: 4, height: 4)
        }
        .animation(.snappy(duration: 0.2), value: done)
    }
}

// MARK: - Day note

struct DayCard: View {
    @ObservedObject var model: StreakModel
    let habit: Habit
    @State private var text = ""
    /// The habit and day the text field holds, so switching either never writes one day's note onto another.
    @State private var loaded: NoteKey?

    struct NoteKey: Equatable {
        let id: Habit.ID
        let day: Day
    }

    var body: some View {
        let day = model.selectedDay
        let done = habit.done.contains(day)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.format(day, "EEEEdMMMM")).font(.system(size: 13, weight: .semibold))
                        Text(model.relative(day)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Done", isOn: Binding(get: { done }, set: { _ in model.toggle(habit.id, on: day) }))
                        .toggleStyle(.checkbox)
                        .disabled(day > model.today)
                }
                TextField("Add a note for this day", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
        }
        .onChange(of: NoteKey(id: habit.id, day: day), initial: true) { _, key in
            loaded = key
            text = habit.note(key.day)
        }
        .onChange(of: text) {
            if let loaded { model.setNote(text, id: loaded.id, on: loaded.day) }
        }
    }
}

// MARK: - Year grid

struct HeatmapCard: View {
    @ObservedObject var model: StreakModel
    let habit: Habit
    @State private var width: CGFloat = 700
    @State private var hovered: Day?

    private let labelWidth: CGFloat = 30
    private let monthHeight: CGFloat = 16

    var body: some View {
        let grid = HeatGrid(range: model.range, today: model.today, firstWeekday: model.firstWeekday)
        let pitch = max(9, min(17, floor((width - labelWidth) / CGFloat(grid.columns) * 2) / 2))
        let count = habit.done.filter { $0 >= grid.start && $0 <= grid.end }.count
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(text: model.range == .pastYear ? "Past 12 months" : "Year \(model.rangeTitle)")
                    Text("\(count) check-ins").font(.system(size: 12)).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Text(hoverText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                canvas(grid: grid, pitch: pitch)
                    .frame(width: labelWidth + pitch * CGFloat(grid.columns), height: monthHeight + pitch * 7, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                legend
            }
        }
    }

    private var hoverText: String {
        guard let day = hovered else { return "Click a day to see it, double-click to tick it" }
        let done = habit.done.contains(day) ? "done" : (day > model.today ? "ahead" : "missed")
        let note = habit.note(day).isEmpty ? "" : ", with a note"
        return "\(model.format(day, "EEEdMMMyyyy")): \(done)\(note)"
    }

    private func canvas(grid: HeatGrid, pitch: CGFloat) -> some View {
        let gap = max(2, (pitch * 0.2).rounded())
        let cell = pitch - gap
        let tint = habit.tint.color
        let done = habit.done
        let notes = Set(habit.notes.keys)
        let created = habit.created
        let today = model.today
        let selected = model.selectedDay
        let hovered = hovered
        let months = grid.monthStarts()
        let monthSymbols = model.calendar.shortStandaloneMonthSymbols
        let weekdayLabels = (0..<7).map { model.weekdaySymbol(grid.first.adding($0)) }

        return Canvas { ctx, _ in
            for (i, label) in weekdayLabels.enumerated() where i % 2 == 0 {
                let y = monthHeight + CGFloat(i) * pitch + cell / 2
                ctx.draw(Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary),
                         at: CGPoint(x: 0, y: y), anchor: .leading)
            }
            var lastX: CGFloat = -100
            for m in months {
                let x = labelWidth + CGFloat(m.column) * pitch
                guard x - lastX > 26 else { continue }
                lastX = x
                ctx.draw(Text(monthSymbols[m.month - 1]).font(.system(size: 9.5)).foregroundStyle(.secondary),
                         at: CGPoint(x: x, y: 0), anchor: .topLeading)
            }
            for c in 0..<grid.columns {
                for r in 0..<7 {
                    guard let day = grid.day(column: c, row: r) else { continue }
                    let rect = CGRect(x: labelWidth + CGFloat(c) * pitch, y: monthHeight + CGFloat(r) * pitch, width: cell, height: cell)
                    let path = Path(roundedRect: rect, cornerRadius: cell * 0.24, style: .continuous)
                    if done.contains(day) {
                        ctx.fill(path, with: .color(tint))
                    } else {
                        ctx.fill(path, with: .color(.primary.opacity(day > today || day < created ? 0.025 : 0.07)))
                    }
                    if notes.contains(day.iso) {
                        let dot = CGRect(x: rect.midX - cell * 0.14, y: rect.midY - cell * 0.14, width: cell * 0.28, height: cell * 0.28)
                        ctx.fill(Path(ellipseIn: dot), with: .color(done.contains(day) ? .white : tint))
                    }
                    if day == selected || day == hovered {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: cell * 0.3, style: .continuous),
                                   with: .color(.primary.opacity(day == selected ? 0.7 : 0.35)), lineWidth: 1.5)
                    } else if day == today {
                        ctx.stroke(Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: cell * 0.3, style: .continuous),
                                   with: .color(tint), lineWidth: 1.5)
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): self.hovered = day(at: p, grid: grid, pitch: pitch)
            case .ended: self.hovered = nil
            }
        }
        .onTapGesture(count: 2, coordinateSpace: .local) { p in
            if let d = day(at: p, grid: grid, pitch: pitch), d <= today {
                model.selectedDay = d
                model.toggle(habit.id, on: d)
            }
        }
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            if let d = day(at: p, grid: grid, pitch: pitch) { model.selectedDay = d }
        }
    }

    private func day(at p: CGPoint, grid: HeatGrid, pitch: CGFloat) -> Day? {
        let c = Int(floor((p.x - labelWidth) / pitch)), r = Int(floor((p.y - monthHeight) / pitch))
        guard p.x >= labelWidth, p.y >= monthHeight, (0..<grid.columns).contains(c), (0..<7).contains(r) else { return nil }
        return grid.day(column: c, row: r)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Color.primary.opacity(0.07), "Missed")
            swatch(habit.tint.color, "Done")
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(habit.tint.color)
                    Circle().fill(.white).frame(width: 3.5, height: 3.5)
                }
                .frame(width: 11, height: 11)
                Text("Note")
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(habit.tint.color, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
                Text("Today")
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(color).frame(width: 11, height: 11)
            Text(label)
        }
    }
}

// MARK: - Editor

struct HabitEditor: View {
    @ObservedObject var model: StreakModel
    @State var state: EditorState
    @Environment(\.dismiss) private var dismiss
    @State private var emoji = ""

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HabitBadge(habit: preview, size: 44)
                Text(state.id == nil ? "New Habit" : "Edit Habit").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)
            Form {
                TextField("Name", text: $state.name, prompt: Text("Read 20 pages"))
                Section("Icon") {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(EditorState.symbols, id: \.self) { symbol in
                            Button { state.icon = symbol } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 15, weight: .medium))
                                    .frame(width: 34, height: 30)
                                    .foregroundStyle(state.icon == symbol ? .white : .primary)
                                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(state.icon == symbol ? AnyShapeStyle(state.tint.color.gradient)
                                            : AnyShapeStyle(Color.primary.opacity(0.06))))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(symbol)
                        }
                    }
                    TextField("Or an emoji", text: $emoji, prompt: Text("🌙"))
                        .onChange(of: emoji) {
                            if let first = emoji.first(where: \.isEmoji) {
                                state.icon = String(first)
                                if emoji != String(first) { emoji = String(first) }
                            }
                        }
                }
                Section("Colour") {
                    HStack(spacing: 8) {
                        ForEach(Tint.allCases, id: \.self) { tint in
                            Button { state.tint = tint } label: {
                                Circle().fill(tint.color.gradient)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(.white, lineWidth: state.tint == tint ? 2.5 : 0).padding(1))
                                    .overlay(Circle().strokeBorder(tint.color, lineWidth: state.tint == tint ? 1.5 : 0).padding(-2))
                            }
                            .buttonStyle(.plain)
                            .help(tint.name)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("Goal") {
                    Picker("Goal", selection: $state.weekly) {
                        Text("Every day").tag(false)
                        Text("Times a week").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if state.weekly {
                        Stepper(value: $state.perWeek, in: 1...6) {
                            Text(Target.weekly(state.perWeek).label).monospacedDigit()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(state.id == nil ? "Add Habit" : "Save") {
                    model.save(state)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if state.icon.first?.isEmoji == true { emoji = state.icon } }
    }

    private var preview: Habit {
        Habit(name: state.name, icon: state.icon, tint: state.tint, target: .daily, created: model.today)
    }
}

// MARK: - Formatting

extension StreakModel {
    func format(_ day: Day, _ template: String) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: day.date(in: calendar))
    }

    func weekdaySymbol(_ day: Day) -> String { calendar.shortStandaloneWeekdaySymbols[day.weekday - 1] }

    func relative(_ day: Day) -> String {
        switch today.n - day.n {
        case 0: "Today"
        case 1: "Yesterday"
        case -1: "Tomorrow"
        case let k where k > 1: "\(k) days ago"
        case let k: "In \(-k) days"
        }
    }
}

extension Character {
    /// Pictographs and emoji sequences, not plain digits or letters (which carry the emoji property too).
    var isEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && (unicodeScalars.count > 1 || first.value > 0x238C))
    }
}
