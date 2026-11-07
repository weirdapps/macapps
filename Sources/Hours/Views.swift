import Charts
import Kit
import SwiftUI

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: HoursModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                switch model.mode {
                case .week: WeekView(model: model)
                case .totals: TotalsView(model: model)
                }
            }
            .frame(minWidth: 560, minHeight: 440)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Hours")
        .toolbar { toolbar }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .entry(let entry, let isNew): EntryEditor(model: model, entry: entry, isNew: isNew)
            case .project(let project, let isNew): ProjectEditor(model: model, project: project, isNew: isNew)
            }
        }
        .overlay(alignment: .bottom) {
            if let url = model.lastExport {
                ExportBanner(url: url) { model.lastExport = nil }
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.lastExport)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .help("Switch between the week and the totals per period")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            TimerToolbarButton(model: model)
            Button { model.newEntry() } label: { Label("New Entry", systemImage: "plus") }
                .help("Add an entry by hand (⌘N)")
            Button { model.exportCSV() } label: { Label("Export Timesheet", systemImage: "square.and.arrow.up") }
                .help("Export the time on screen as CSV (⇧⌘E)")
        }
    }
}

struct TimerToolbarButton: View {
    @ObservedObject var model: HoursModel

    var body: some View {
        if let running = model.running {
            Button { model.stop() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill").foregroundStyle(.red)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Timesheet.duration(running.duration(now: model.now()), withSeconds: true))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 4)
            }
            .help("Stop the timer (⌘.)")
        } else {
            Menu {
                ForEach(model.projects) { p in
                    Button { model.start(p.id) } label: { Label(p.name, systemImage: "circle.fill") }
                }
            } label: {
                Label("Start Timer", systemImage: "play.fill")
            } primaryAction: {
                model.toggleTimer()
            }
            .disabled(model.projects.isEmpty)
            .help("Start a timer (⌘T); hold to pick the project")
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: HoursModel

    var body: some View {
        let now = model.now()
        let byProject = Timesheet.secondsByProject(model.entries, in: model.exportInterval, now: now)
        List(selection: $model.filter) {
            Section("Projects") {
                SidebarRow(name: "All projects", color: nil, detail: nil,
                           value: Timesheet.duration(byProject.values.reduce(0, +)), isRunning: false)
                    .tag(SidebarItem.all)
                ForEach(model.projects) { p in
                    SidebarRow(name: p.name, color: Theme.color(p.color), detail: p.rate.map { model.money($0) + " an hour" },
                               value: Timesheet.duration(byProject[p.id] ?? 0), isRunning: model.running?.projectID == p.id)
                        .tag(SidebarItem.project(p.id))
                        .contextMenu {
                            Button("Start Timer") { model.start(p.id) }
                            Button("Edit Project…") { model.sheet = .project(p, isNew: false) }
                            Divider()
                            Button("Delete Project", role: .destructive) { confirmDelete(p) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.projects.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus").font(.system(size: 26)).foregroundStyle(Theme.gradient)
                    Text("Add a project to start tracking.").font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.sheet = .project(model.newProjectDraft(), isNew: true) } label: {
                    Label("New Project", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Add a project (⇧⌘N)")
                Spacer()
                Text(model.mode == .week ? "Week shown" : model.period.rawValue).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func confirmDelete(_ p: Project) {
        let count = model.entries.filter { $0.projectID == p.id }.count
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(p.name)\u{201D}?"
        alert.informativeText = count == 0 ? "The project has no entries." :
            "Its \(count) \(count == 1 ? "entry" : "entries") will be deleted too. You can undo this with ⌘Z."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { model.deleteProject(p.id) }
    }
}

struct SidebarRow: View {
    let name: String
    let color: Color?
    let detail: String?
    let value: String
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 9) {
            if let color {
                Circle().fill(color.gradient).frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
            } else {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11)).foregroundStyle(Theme.gradient).frame(width: 11)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 4)
            if isRunning {
                Image(systemName: "record.circle").font(.caption).foregroundStyle(.red)
                    .symbolEffect(.pulse)
                    .help("Timer running")
            }
            Text(value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let caption: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxHeight: .infinity, alignment: .leading)
        }
    }
}

struct ProjectDot: View {
    let color: Color
    var size: CGFloat = 10
    var body: some View { Circle().fill(color.gradient).frame(width: size, height: size) }
}

struct ExportBanner: View {
    let url: URL
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Exported \(url.lastPathComponent)").lineLimit(1).truncationMode(.middle)
            Button("Reveal in Finder") { revealInFinder([url]) }.buttonStyle(.link)
            Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 520)
    }
}

// MARK: - Week

struct WeekView: View {
    @ObservedObject var model: HoursModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.running == nil ? 60 : 1)) { _ in
            let now = model.now()
            let entries = model.visibleEntries
            let week = model.week
            let weekSeconds = Timesheet.seconds(entries, in: week, now: now)
            let byProject = Timesheet.secondsByProject(entries, in: week, now: now)
            let earned = Timesheet.earnings(byProject, projects: model.projects)
            let worked = Timesheet.days(in: week, calendar: model.calendar)
                .filter { Timesheet.seconds(entries, in: Timesheet.day($0, calendar: model.calendar), now: now) > 0 }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        TimerCard(model: model, now: now)
                        StatTile(title: model.week.contains(now) ? "This week" : "Week", value: Timesheet.duration(weekSeconds), symbol: "clock",
                                 caption: worked == 0 ? "No days tracked" :
                                    "Avg \(Timesheet.duration(weekSeconds / Double(worked))) over \(worked) \(worked == 1 ? "day" : "days")")
                            .frame(width: 170)
                        StatTile(title: "Earnings", value: model.money(earned), symbol: "banknote",
                                 caption: billableCaption(byProject))
                            .frame(width: 170)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    WeekChart(model: model, now: now, entries: entries)
                    DayEntries(model: model, now: now, entries: entries)
                }
                .padding(20)
            }
        }
        .navigationSubtitle(weekTitle)
    }

    private var weekTitle: String {
        let last = model.calendar.date(byAdding: .day, value: 6, to: model.weekStart)!
        let f = Date.FormatStyle().month(.abbreviated).day()
        return "\(model.weekStart.formatted(f)) to \(last.formatted(f.year()))"
    }

    private func billableCaption(_ byProject: [UUID: TimeInterval]) -> String {
        let billable = model.projects.filter { $0.rate != nil }.reduce(0) { $0 + (byProject[$1.id] ?? 0) }
        return billable == 0 ? "Nothing billable yet" : "\(Timesheet.duration(billable)) billable"
    }
}

struct TimerCard: View {
    @ObservedObject var model: HoursModel
    let now: Date
    @State private var note = ""
    @State private var hovering = false

    var body: some View {
        Group {
            if let running = model.running, let p = model.project(running.projectID) {
                runningBody(running, p)
            } else {
                idleBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.snappy, value: model.running?.id)
    }

    private func runningBody(_ running: Entry, _ p: Project) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle().fill(Theme.color(p.color)).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    Text(p.name).font(.headline)
                    Text("since \(running.start.formatted(date: model.calendar.isDate(running.start, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
                Text(Timesheet.duration(running.duration(now: now), withSeconds: true))
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                TextField("What are you working on?", text: $note)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.16)))
                    .onAppear { note = running.note }
                    .onChange(of: running.id) { _, _ in note = model.running?.note ?? "" }
                    .onChange(of: note) { _, new in if new != model.running?.note { model.setRunningNote(new) } }
            }
            Spacer(minLength: 0)
            Button { model.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.bottom)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(.white))
                    .shadow(color: .black.opacity(0.2), radius: hovering ? 8 : 4, y: 2)
                    .scaleEffect(hovering ? 1.05 : 1)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 && !Desktop.isSnapshot }
            .animation(.snappy(duration: 0.15), value: hovering)
            .help("Stop the timer (⌘.)")
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gradient))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18)))
        .shadow(color: Theme.bottom.opacity(0.3), radius: 8, y: 3)
    }

    private var idleBody: some View {
        Card {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No timer running").font(.headline)
                    Text(model.projects.isEmpty ? "Add a project, then start a timer for it." :
                            "Pick a project and start the clock. Only one timer runs at a time.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.projects.isEmpty {
                        Menu {
                            ForEach(model.projects) { p in Button(p.name) { model.start(p.id) } }
                        } label: {
                            Text(model.defaultProjectID.flatMap { model.project($0)?.name } ?? "Project")
                        }
                        .fixedSize()
                        .help("Start a timer for another project")
                    }
                }
                Spacer(minLength: 0)
                Button {
                    if model.projects.isEmpty { model.sheet = .project(model.newProjectDraft(), isNew: true) } else { model.toggleTimer() }
                } label: {
                    Image(systemName: model.projects.isEmpty ? "plus" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Theme.gradient))
                        .shadow(color: Theme.bottom.opacity(0.35), radius: hovering ? 8 : 4, y: 2)
                        .scaleEffect(hovering ? 1.05 : 1)
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 && !Desktop.isSnapshot }
                .animation(.snappy(duration: 0.15), value: hovering)
                .help(model.projects.isEmpty ? "Add a project" : "Start the timer (⌘T)")
            }
        }
    }
}

struct WeekChart: View {
    @ObservedObject var model: HoursModel
    let now: Date
    let entries: [Entry]

    struct Bar: Identifiable {
        let id: String
        let day: String
        let project: String
        let color: Color
        let hours: Double
    }

    var body: some View {
        let cal = model.calendar
        let days = Timesheet.days(in: model.week, calendar: cal)
        let keys = days.map { $0.formatted(.dateTime.weekday(.abbreviated)) + " " + $0.formatted(.dateTime.day()) }
        let projects = model.projects.filter { p in entries.contains { $0.projectID == p.id } }
        let byDay = Timesheet.secondsByDay(entries, in: model.week, now: now, calendar: cal)
        var bars: [Bar] = []
        var totals: [TimeInterval] = []
        for (i, day) in days.enumerated() {
            let byProject = byDay[day] ?? [:]
            totals.append(byProject.values.reduce(0, +))
            for p in projects where (byProject[p.id] ?? 0) > 0 {
                bars.append(Bar(id: "\(i)-\(p.id)", day: keys[i], project: p.name, color: Theme.color(p.color), hours: byProject[p.id]! / 3600))
            }
        }
        let weekProjects = projects.filter { p in bars.contains { $0.project == p.name } }
        let maxHours = max(8, (totals.max() ?? 0) / 3600)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    WeekNavigator(model: model)
                    Spacer()
                    HStack(spacing: 12) {
                        ForEach(weekProjects) { p in
                            HStack(spacing: 5) {
                                ProjectDot(color: Theme.color(p.color), size: 8)
                                Text(p.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day), y: .value("Hours", bar.hours), width: .ratio(0.46))
                        .foregroundStyle(bar.color.gradient)
                        .opacity(cal.isDate(model.selectedDay, inSameDayAs: days[keys.firstIndex(of: bar.day) ?? 0]) ? 1 : 0.8)
                }
                .chartXScale(domain: keys)
                .chartYScale(domain: 0...(maxHours.rounded(.up)))
                .chartXAxis(.hidden)
                .chartYAxis {
                    // No labels: they would shift the bars off the day columns below, which carry the totals.
                    AxisMarks(position: .leading, values: .stride(by: maxHours > 12 ? 4 : 2)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    }
                }
                .chartLegend(.hidden)
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geo[frame].origin.x
                                if let key: String = proxy.value(atX: x), let i = keys.firstIndex(of: key) {
                                    withAnimation(.snappy) { model.selectedDay = days[i] }
                                }
                            }
                    }
                }
                .overlay {
                    if bars.isEmpty {
                        Text(model.filterProject == nil ? "No time tracked this week" : "No time on this project this week")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 150)
                HStack(spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                        DayColumn(day: day, total: totals[i], isSelected: cal.isDate(day, inSameDayAs: model.selectedDay),
                                  isToday: cal.isDate(day, inSameDayAs: now)) {
                            withAnimation(.snappy) { model.selectedDay = day }
                        }
                    }
                }
            }
        }
    }
}

struct DayColumn: View {
    let day: Date
    let total: TimeInterval
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : isToday ? AnyShapeStyle(Theme.bottom) : AnyShapeStyle(.secondary))
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(total > 0 ? Timesheet.duration(total) : "0:00")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9)) : total > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.5 : 0))))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && !Desktop.isSnapshot }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

struct DayEntries: View {
    @ObservedObject var model: HoursModel
    let now: Date
    let entries: [Entry]

    var body: some View {
        let cal = model.calendar
        let day = Timesheet.day(model.selectedDay, calendar: cal)
        let dayEntries = entries.filter { Timesheet.seconds(of: $0, in: day, now: now) > 0 || (cal.isDate($0.start, inSameDayAs: day.start) && $0.isRunning) }
            .sorted { $0.start < $1.start }
        let total = Timesheet.seconds(dayEntries, in: day, now: now)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.selectedDay.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.headline)
                Text(Timesheet.duration(total)).font(.headline).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button { model.newEntry() } label: { Label("Add Entry", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .disabled(model.projects.isEmpty)
            }
            .padding(.horizontal, 4)
            if dayEntries.isEmpty {
                Card {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock").font(.title2).foregroundStyle(Theme.gradient)
                        Text("Nothing tracked on this day. Start a timer or add an entry by hand.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(dayEntries.enumerated()), id: \.element.id) { i, entry in
                        if i > 0 { Divider().padding(.leading, 30) }
                        EntryRow(model: model, entry: entry, day: day, now: now)
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
            }
        }
    }
}

struct EntryRow: View {
    @ObservedObject var model: HoursModel
    let entry: Entry
    let day: DateInterval
    let now: Date
    @State private var hovering = false

    var body: some View {
        let p = model.project(entry.projectID)
        let cal = model.calendar
        let piece = Timesheet.seconds(of: entry, in: day, now: now)
        let crosses = !cal.isDate(entry.start, inSameDayAs: entry.end ?? now)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.color(p?.color ?? 0).gradient).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(p?.name ?? "Unknown project").font(.system(size: 13, weight: .semibold))
                Text(entry.note.isEmpty ? "No note" : entry.note).font(.callout)
                    .foregroundStyle(entry.note.isEmpty ? .tertiary : .secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if hovering && !Desktop.isSnapshot {
                HStack(spacing: 2) {
                    rowButton("play.fill", help: "Continue this task") { model.start(entry.projectID, note: entry.note) }
                        .disabled(entry.isRunning)
                    rowButton("pencil", help: "Edit entry") { model.sheet = .entry(entry, isNew: false) }
                    rowButton("trash", help: "Delete entry") { model.deleteEntry(entry.id) }
                }
                .transition(.opacity)
            }
            HStack(spacing: 5) {
                if crosses {
                    Image(systemName: "moon.stars.fill").font(.caption).foregroundStyle(.indigo)
                        .help("Runs past midnight; this day counts \(Timesheet.duration(piece)) of \(Timesheet.duration(entry.duration(now: now)))")
                }
                Text(timeRange(crosses: crosses)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(Timesheet.duration(piece, withSeconds: entry.isRunning))
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(entry.isRunning ? AnyShapeStyle(Theme.bottom) : AnyShapeStyle(.primary))
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(hovering ? 0.35 : 0)).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 && !Desktop.isSnapshot }
        .animation(.snappy(duration: 0.15), value: hovering)
        .onTapGesture(count: 2) { model.sheet = .entry(entry, isNew: false) }
        .contextMenu {
            Button("Edit Entry…") { model.sheet = .entry(entry, isNew: false) }
            Button("Continue") { model.start(entry.projectID, note: entry.note) }.disabled(entry.isRunning)
            Divider()
            Button("Delete Entry", role: .destructive) { model.deleteEntry(entry.id) }
        }
    }

    private func timeRange(crosses: Bool) -> String {
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        let start = crosses && !model.calendar.isDate(entry.start, inSameDayAs: day.start)
            ? entry.start.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : entry.start.formatted(t)
        let end = entry.end.map { e in
            crosses && !model.calendar.isDate(e, inSameDayAs: day.start) ? e.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : e.formatted(t)
        } ?? "now"
        return "\(start) \u{2192} \(end)"
    }

    private func rowButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                .background(Circle().fill(.quaternary.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Totals

struct TotalsView: View {
    @ObservedObject var model: HoursModel

    struct Row: Identifiable {
        let project: Project
        let seconds: TimeInterval
        var id: UUID { project.id }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.running == nil ? 60 : 1)) { _ in
            let now = model.now()
            let interval = model.periodInterval
            let entries = model.visibleEntries
            let byProject = Timesheet.secondsByProject(entries, in: interval, now: now)
            let rows = model.projects.compactMap { p in byProject[p.id].map { Row(project: p, seconds: $0) } }
                .sorted { $0.seconds > $1.seconds }
            let total = rows.reduce(0) { $0 + $1.seconds }
            let earned = Timesheet.earnings(byProject, projects: model.projects)
            let count = entries.filter { Timesheet.seconds(of: $0, in: interval, now: now) > 0 }.count
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    periodBar(interval)
                    HStack(spacing: 14) {
                        StatTile(title: "Time", value: Timesheet.duration(total), symbol: "clock",
                                 caption: String(format: "%.2f hours", total / 3600))
                        StatTile(title: "Earnings", value: model.money(earned), symbol: "banknote",
                                 caption: total > 0 ? "Avg \(model.money(earned / (total / 3600))) an hour" : "No time in this period")
                        StatTile(title: "Entries", value: "\(count)", symbol: "list.bullet",
                                 caption: "\(rows.count) \(rows.count == 1 ? "project" : "projects")")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    if !rows.isEmpty { PeriodChart(model: model, interval: interval, now: now, entries: entries) }
                    if rows.isEmpty {
                        Card {
                            ContentUnavailableView("No time in this period", systemImage: "chart.pie",
                                                   description: Text("Pick another period, or track some time first."))
                                .frame(maxWidth: .infinity, minHeight: 200)
                        }
                    } else {
                        Card {
                            HStack(alignment: .center, spacing: 24) {
                                Chart(rows) { row in
                                    SectorMark(angle: .value("Hours", row.seconds), innerRadius: .ratio(0.62), angularInset: 1.5)
                                        .foregroundStyle(Theme.color(row.project.color).gradient)
                                        .cornerRadius(3)
                                }
                                .chartLegend(.hidden)
                                .frame(width: 170, height: 170)
                                .overlay {
                                    VStack(spacing: 0) {
                                        Text(Timesheet.duration(total)).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                                        Text("total").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                VStack(spacing: 0) {
                                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                        if i > 0 { Divider() }
                                        ProjectTotalRow(model: model, row: row, total: total)
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button { model.exportCSV() } label: { Label("Export Timesheet…", systemImage: "square.and.arrow.up") }
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.bottom)
                            .disabled(rows.isEmpty)
                    }
                }
                .padding(20)
            }
        }
        .navigationSubtitle("")
    }

    private func periodBar(_ interval: DateInterval) -> some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $model.period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if model.period == .custom {
                DatePicker("From", selection: $model.customStart, displayedComponents: .date).fixedSize()
                DatePicker("to", selection: $model.customEnd, displayedComponents: .date).fixedSize()
            } else {
                let last = model.calendar.date(byAdding: .second, value: -1, to: interval.end)!
                Text("\(interval.start.formatted(.dateTime.month(.abbreviated).day())) to \(last.formatted(.dateTime.month(.abbreviated).day().year()))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct ProjectTotalRow: View {
    @ObservedObject var model: HoursModel
    let row: TotalsView.Row
    let total: TimeInterval

    var body: some View {
        let share = total > 0 ? row.seconds / total : 0
        HStack(spacing: 12) {
            ProjectDot(color: Theme.color(row.project.color))
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(row.project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(share.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary.opacity(0.5))
                        Capsule().fill(Theme.color(row.project.color).gradient).frame(width: max(4, geo.size.width * share))
                    }
                }
                .frame(height: 5)
            }
            Text(Timesheet.duration(row.seconds)).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            Text(row.project.rate.map { model.money($0 * row.seconds / 3600) } ?? "Not billed")
                .font(.callout).monospacedDigit()
                .foregroundStyle(row.project.rate == nil ? .tertiary : .secondary)
                .frame(width: 96, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

// MARK: - Editors

struct EntryEditor: View {
    @ObservedObject var model: HoursModel
    @State var entry: Entry
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let end = entry.end ?? model.now()
        let valid = end > entry.start
        VStack(spacing: 0) {
            Form {
                Picker("Project", selection: $entry.projectID) {
                    ForEach(model.projects) { p in
                        Label { Text(p.name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Theme.color(p.color)) }.tag(p.id)
                    }
                }
                DatePicker("Start", selection: $entry.start, displayedComponents: [.date, .hourAndMinute])
                if entry.isRunning {
                    LabeledContent("End") { Text("Running").foregroundStyle(.secondary) }
                } else {
                    DatePicker("End", selection: Binding(get: { entry.end ?? entry.start }, set: { entry.end = $0 }),
                               displayedComponents: [.date, .hourAndMinute])
                }
                LabeledContent("Duration") {
                    Text(valid ? Timesheet.duration(end.timeIntervalSince(entry.start)) : "End is before start")
                        .monospacedDigit()
                        .foregroundStyle(valid ? .primary : Color.red)
                }
                TextField("Note", text: $entry.note, prompt: Text("What did you work on?"))
            }
            .formStyle(.grouped)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { model.deleteEntry(entry.id); dismiss() }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Entry" : "Save") { model.saveEntry(entry); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
    }
}

struct ProjectEditor: View {
    @ObservedObject var model: HoursModel
    @State var project: Project
    let isNew: Bool
    @State private var billed = false
    @State private var rateText = ""
    @Environment(\.dismiss) private var dismiss

    /// An empty rate means zero; anything else must read as a number.
    private var rateIsValid: Bool {
        !billed || rateText.trimmingCharacters(in: .whitespaces).isEmpty || Timesheet.parseRate(rateText) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $project.name, prompt: Text("Client or project"))
                LabeledContent("Color") {
                    HStack(spacing: 7) {
                        ForEach(Theme.palette.indices, id: \.self) { i in
                            Button { project.color = i } label: {
                                Circle().fill(Theme.color(i).gradient).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(.primary.opacity(project.color == i ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 3)
                }
                Toggle("Billed by the hour", isOn: $billed)
                if billed {
                    LabeledContent("Hourly rate") {
                        HStack(spacing: 6) {
                            TextField("Rate", text: $rateText, prompt: Text("0"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text(model.currency).foregroundStyle(.secondary)
                        }
                    }
                    if !rateIsValid {
                        Text("Type the rate as a number, like 85 or 72.50.").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add Project" : "Save") {
                    project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.rate = billed ? Timesheet.parseRate(rateText) ?? 0 : nil
                    model.saveProject(project)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !rateIsValid)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420)
        .onAppear {
            billed = project.rate != nil
            rateText = project.rate.map { $0.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)) } ?? ""
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: HoursModel

    var body: some View {
        Form {
            Picker("Currency", selection: $model.currency) {
                ForEach(Theme.currencies, id: \.self) { code in
                    Text("\(code)  \(Locale.current.localizedString(forCurrencyCode: code) ?? "")").tag(code)
                }
            }
            Text("Used for hourly rates, earnings and the exported timesheet.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct WeekNavigator: View {
    @ObservedObject var model: HoursModel

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy) { model.moveWeek(-1) } } label: { Image(systemName: "chevron.left") }
                .help("Previous week (⌘[)")
            Button("Today") { withAnimation(.snappy) { model.goToToday() } }
                .help("Go to this week (⇧⌘T)")
                .disabled(model.week.contains(model.now()) && model.calendar.isDate(model.selectedDay, inSameDayAs: model.now()))
            Button { withAnimation(.snappy) { model.moveWeek(1) } } label: { Image(systemName: "chevron.right") }
                .help("Next week (⌘])")
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }
}

/// Daily totals across a period, stacked by project.
struct PeriodChart: View {
    @ObservedObject var model: HoursModel
    let interval: DateInterval
    let now: Date
    let entries: [Entry]

    struct Bar: Identifiable {
        let id: String
        let day: Date
        let color: Color
        let hours: Double
    }

    var body: some View {
        let cal = model.calendar
        let dayCount = Timesheet.days(in: interval, calendar: cal).count
        // Past three months one bar per day gets too thin to read, so long custom ranges show months.
        let byMonth = dayCount > 92
        var sums: [Date: [UUID: TimeInterval]] = [:]
        for (day, byProject) in Timesheet.secondsByDay(entries, in: interval, now: now, calendar: cal) {
            let key = byMonth ? cal.dateInterval(of: .month, for: day)?.start ?? day : day
            for (id, s) in byProject { sums[key, default: [:]][id, default: 0] += s }
        }
        // Whole months on the axis, so the first and last month bars sit inside the plot.
        let domain = byMonth
            ? (cal.dateInterval(of: .month, for: interval.start)?.start ?? interval.start)...(cal.dateInterval(of: .month, for: interval.end.addingTimeInterval(-1))?.end ?? interval.end)
            : interval.start...interval.end
        var bars: [Bar] = []
        for (key, byProject) in sums {
            for p in model.projects where (byProject[p.id] ?? 0) > 0 {
                bars.append(Bar(id: "\(key.timeIntervalSince1970)-\(p.id)", day: key, color: Theme.color(p.color), hours: byProject[p.id]! / 3600))
            }
        }
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(byMonth ? "By month" : "By day").font(.headline)
                Chart(bars) { bar in
                    BarMark(x: .value("Day", bar.day, unit: byMonth ? .month : .day), y: .value("Hours", bar.hours),
                            width: .ratio(dayCount > 14 ? 0.7 : 0.5))
                        .foregroundStyle(bar.color.gradient)
                }
                .chartXScale(domain: domain)
                .chartXAxis {
                    if byMonth {
                        AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day, count: dayCount > 14 ? 7 : 1)) { _ in
                            AxisValueLabel(format: dayCount > 14 ? .dateTime.month(.abbreviated).day() : .dateTime.weekday(.abbreviated), centered: true)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        AxisValueLabel { if let h = value.as(Double.self) { Text("\(Int(h))h") } }
                    }
                }
                .frame(height: 150)
            }
        }
    }
}
