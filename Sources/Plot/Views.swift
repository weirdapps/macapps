import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(nsColor: rgb(0x4FC3F7))
    static let bottom = Color(nsColor: rgb(0x1E6FD9))
    static let accent = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let cellWidth: CGFloat = 112
    static let labelWidth: CGFloat = 128
    static let rowHeight: CGFloat = 26
    static let gutter: CGFloat = 36
}

struct ContentView: View {
    @ObservedObject var model: PlotModel
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 320)
        } detail: {
            Group {
                if let id = model.selection, model.chart(id) != nil {
                    ChartEditor(model: model, id: id)
                } else {
                    ContentUnavailableView {
                        Label("No Chart", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Make a new chart with ⌘N, or drop a CSV file here.")
                    } actions: {
                        Button("New Chart") { model.newChart() }.buttonStyle(.borderedProminent).tint(Theme.bottom)
                    }
                }
            }
            .frame(minWidth: 460)
            .inspector(isPresented: $model.showInspector) {
                Group {
                    if let id = model.selection, model.chart(id) != nil {
                        Inspector(model: model, id: id)
                    } else {
                        Text("No chart selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .inspectorColumnWidth(min: 240, ideal: 256, max: 320)
            }
            .toolbar { DetailToolbar(model: model) }
        }
        .frame(minWidth: 760, minHeight: 480)
        .overlay(alignment: .bottom) { ToastView(model: model) }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { ["csv", "tsv", "txt", "tab"].contains($0.pathExtension.lowercased()) }
            guard !files.isEmpty else { return false }
            model.importFiles(files)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.bottom, lineWidth: 3)
                    .background(Theme.bottom.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $model.editingText) {
            if let id = model.selection { TextEditorSheet(model: model, id: id) }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: PlotModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Charts") {
                ForEach(model.charts) { chart in
                    SidebarRow(chart: chart)
                        .tag(chart.id)
                        .contextMenu {
                            Button("Duplicate") { model.duplicate(chart.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(chart.id) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.delete(model.selection) }
        .overlay {
            if model.charts.isEmpty {
                ContentUnavailableView("No Charts", systemImage: "chart.bar", description: Text("Press ⌘N to start one."))
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.newChart() } label: { Label("New Chart", systemImage: "plus") }
                    .help("New chart (⌘N)")
            }
        }
    }
}

struct SidebarRow: View {
    let chart: PlotChart

    var body: some View {
        HStack(spacing: 10) {
            let colors = chart.palette.colors
            Image(systemName: chart.kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [colors[min(1, colors.count - 1)], colors[0]], startPoint: .top, endPoint: .bottom)))
            VStack(alignment: .leading, spacing: 1) {
                Text(chart.title.isEmpty ? "Untitled Chart" : chart.title).lineLimit(1)
                Text(chart.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Toolbar

struct DetailToolbar: ToolbarContent {
    @ObservedObject var model: PlotModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Chart Type", selection: Binding(
                get: { model.selected?.kind ?? .bar },
                set: { kind in model.update(model.selection, action: "Change Chart Type") { $0.kind = kind } }
            )) {
                ForEach(ChartKind.allCases) { kind in
                    Label(kind.menuName, systemImage: kind.symbol).tag(kind).help("\(kind.menuName) chart")
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(model.selected == nil)
            .help("Chart type (⌘1 to ⌘6)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.pasteFromClipboard() } label: { Label("Paste Data", systemImage: "doc.on.clipboard") }
                .help("Replace the data with the table on the clipboard (⇧⌘V)")
            Button { copyChart(model) } label: { Label("Copy Image", systemImage: "photo.on.rectangle") }
                .help("Copy the chart as an image (⌥⌘C)")
                .disabled(model.selected?.isPlottable != true)
            Menu {
                Button("Export PNG…") { if let c = model.selected { Exporter.export(c, pdf: false, model: model) } }
                Button("Export PDF…") { if let c = model.selected { Exporter.export(c, pdf: true, model: model) } }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .help("Export the chart as PNG or PDF (⇧⌘E)")
            .disabled(model.selected?.isPlottable != true)
            Button { withAnimation(.snappy) { model.showInspector.toggle() } } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

@MainActor
func copyChart(_ model: PlotModel) {
    guard let chart = model.selected, chart.isPlottable else { return }
    if Exporter.copy(chart) { model.show(Toast(message: "Copied the chart as an image")) }
}

// MARK: - Editor

struct ChartEditor: View {
    @ObservedObject var model: PlotModel
    let id: PlotChart.ID

    var body: some View {
        if let chart = model.chart(id) {
            // The grid grows with its rows up to a third of the window; the chart takes the rest.
            GeometryReader { geo in
                let wanted = 70 + CGFloat(chart.table.rows.count + 2) * Theme.rowHeight
                let gridHeight = min(max(wanted, 150), max(150, geo.size.height * 0.36))
                VStack(spacing: 0) {
                    ChartCard(model: model, chart: chart)
                    Divider()
                    DataGrid(model: model, id: id, table: chart.table, palette: chart.palette)
                        .frame(height: gridHeight)
                }
            }
        }
    }
}

struct ChartCard: View {
    @ObservedObject var model: PlotModel
    let chart: PlotChart

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            Group {
                if chart.isPlottable {
                    ChartCanvas(chart: chart)
                } else {
                    ContentUnavailableView {
                        Label("Paste numbers to plot", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(chart.kind == .pie
                             ? "A pie needs positive numbers in the first series."
                             : "Copy cells from Numbers or Excel and paste them here. The first column holds labels, the others hold series.")
                    } actions: {
                        Button("Paste from Clipboard") { model.pasteFromClipboard() }
                            .buttonStyle(.borderedProminent).tint(Theme.bottom)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            .padding(16)
        }
        .contentShape(Rectangle())
        .onPasteCommand(of: [.utf8PlainText, .plainText, .tabSeparatedText, .commaSeparatedText]) { _ in
            model.pasteFromClipboard()
        }
        .contextMenu {
            Button("Copy Image") { copyChart(model) }
            Button("Export PNG…") { Exporter.export(chart, pdf: false, model: model) }
            Button("Export PDF…") { Exporter.export(chart, pdf: true, model: model) }
            Divider()
            Button("Paste Data") { model.pasteFromClipboard() }
        }
    }
}

// MARK: - Data grid

struct DataGrid: View {
    @ObservedObject var model: PlotModel
    let id: PlotChart.ID
    let table: DataTable
    let palette: PaletteName

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Data").font(.system(size: 13, weight: .semibold))
                Text("\(table.filledRows.count) rows · \(table.columnCount - 1) series")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button { model.update(id, action: "Add Row") { $0.table.addRow() } } label: { Label("Row", systemImage: "plus") }
                    .help("Add a row")
                Button { model.update(id, action: "Add Series") { $0.table.addColumn() } } label: { Label("Series", systemImage: "plus") }
                    .help("Add a series column")
                Button { model.editingText = true } label: { Label("Edit as Text", systemImage: "text.alignleft") }
                    .help("Edit the data as CSV or TSV text (⌥⌘T)")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    if table.rows.count > 120 {
                        LazyVStack(alignment: .leading, spacing: 0) { rows }
                    } else {
                        VStack(alignment: .leading, spacing: 0) { rows }
                    }
                }
                .padding(.bottom, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var colors: [Color] { palette.colors(table.columnCount) }

    private func width(_ column: Int) -> CGFloat { column == 0 ? Theme.labelWidth : Theme.cellWidth }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Theme.gutter, height: Theme.rowHeight)
            ForEach(0..<table.columnCount, id: \.self) { c in
                HStack(spacing: 6) {
                    if c > 0 {
                        Circle().fill(colors[(c - 1) % colors.count]).frame(width: 8, height: 8)
                    }
                    TextField(c == 0 ? "Labels" : "Series", text: cellBinding(header: c))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(c == 0 ? .leading : .trailing)
                }
                .padding(.horizontal, 8)
                .frame(width: width(c), height: Theme.rowHeight)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .overlay(alignment: .trailing) { Rectangle().fill(.separator.opacity(0.5)).frame(width: 0.5) }
                .contextMenu {
                    if c > 0 {
                        Button("Delete Series", role: .destructive) {
                            model.update(id, action: "Delete Series") { $0.table.removeColumn(c) }
                        }
                        .disabled(table.columnCount <= 2)
                    }
                    Button("Add Series") { model.update(id, action: "Add Series") { $0.table.addColumn() } }
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 0.5) }
    }

    /// The table's rows plus one spare row to type into.
    private var rows: some View {
        ForEach(0...table.rows.count, id: \.self) { r in
            HStack(spacing: 0) {
                Text(r < table.rows.count ? "\(r + 1)" : "")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.gutter, height: Theme.rowHeight)
                ForEach(0..<table.columnCount, id: \.self) { c in
                    GridCell(text: cellBinding(row: r, column: c), isLabel: c == 0, width: width(c))
                }
            }
            .background(r % 2 == 1 ? Color(nsColor: .alternatingContentBackgroundColors.last ?? .clear).opacity(0.6) : .clear)
            .contextMenu {
                if r < table.rows.count {
                    Button("Delete Row", role: .destructive) { model.update(id, action: "Delete Row") { $0.table.removeRow(r) } }
                }
                Button("Add Row") { model.update(id, action: "Add Row") { $0.table.addRow() } }
            }
        }
    }

    private func cellBinding(row: Int, column: Int) -> Binding<String> {
        Binding(
            get: { row < table.rows.count && column < table.rows[row].count ? table.rows[row][column] : "" },
            set: { value in model.update(id) { $0.table.set(row: row, column: column, to: value) } }
        )
    }

    private func cellBinding(header column: Int) -> Binding<String> {
        Binding(
            get: { column < table.headers.count ? table.headers[column] : "" },
            set: { value in model.update(id) { if column < $0.table.headers.count { $0.table.headers[column] = value } } }
        )
    }
}

struct GridCell: View {
    @Binding var text: String
    let isLabel: Bool
    let width: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let invalid = !isLabel && !text.trimmingCharacters(in: .whitespaces).isEmpty && Number.parse(text) == nil
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(isLabel ? .system(size: 12) : .system(size: 12).monospacedDigit())
            .foregroundStyle(invalid ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .multilineTextAlignment(isLabel ? .leading : .trailing)
            .focused($focused)
            .padding(.horizontal, 8)
            .frame(width: width, height: Theme.rowHeight)
            .background(focused ? Theme.bottom.opacity(0.08) : .clear)
            .overlay {
                if focused {
                    Rectangle().strokeBorder(Theme.bottom, lineWidth: 1.5)
                } else {
                    Rectangle().fill(.separator.opacity(0.35)).frame(width: 0.5).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .help(invalid ? "Not a number, so it is left out of the chart" : "")
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var model: PlotModel
    let id: PlotChart.ID

    var body: some View {
        if let chart = model.chart(id) {
            Form {
                Section("Type") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                        ForEach(ChartKind.allCases) { kind in
                            KindTile(kind: kind, selected: chart.kind == kind) {
                                model.update(id, action: "Change Chart Type") { $0.kind = kind }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    if chart.kind == .pie {
                        note("A pie shows the first series; each row is a slice.")
                    } else if chart.kind == .scatter && !chart.table.labelsAreNumeric {
                        note("The first column holds text, so points sit at row numbers.")
                    }
                }
                Section("Labels") {
                    TextField("Title", text: model.binding(id, \.title), prompt: Text("Chart title"))
                    if chart.kind != .pie {
                        TextField("X axis", text: model.binding(id, \.xLabel), prompt: Text("None"))
                        TextField("Y axis", text: model.binding(id, \.yLabel), prompt: Text("None"))
                    }
                }
                Section("Style") {
                    Picker("Colours", selection: model.binding(id, \.palette, action: "Change Colours")) {
                        ForEach(PaletteName.allCases) { Text($0.name).tag($0) }
                    }
                    HStack(spacing: 4) {
                        ForEach(Array(chart.palette.colors.prefix(8).enumerated()), id: \.offset) { _, color in
                            RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color).frame(height: 14)
                        }
                    }
                    Toggle("Legend", isOn: model.binding(id, \.showLegend, action: "Toggle Legend"))
                    Toggle("Value labels", isOn: model.binding(id, \.showValues, action: "Toggle Value Labels"))
                }
                Section("Export") {
                    HStack(spacing: 8) {
                        Button { copyChart(model) } label: { Text("Copy").frame(maxWidth: .infinity) }
                        Button { Exporter.export(chart, pdf: false, model: model) } label: { Text("PNG…").frame(maxWidth: .infinity) }
                        Button { Exporter.export(chart, pdf: true, model: model) } label: { Text("PDF…").frame(maxWidth: .infinity) }
                    }
                    .disabled(!chart.isPlottable)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }
}

struct KindTile: View {
    let kind: ChartKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: kind.symbol).font(.system(size: 16, weight: .medium)).frame(height: 20)
                Text(kind.name).font(.system(size: 10.5, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary.opacity(hovering ? 0.9 : 0.45)))
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: selected)
        .help("\(kind.menuName) chart (⌘\(String(kind.shortcut.character)))")
    }
}

// MARK: - Text editing and toast

struct TextEditorSheet: View {
    @ObservedObject var model: PlotModel
    let id: PlotChart.ID
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit data as text").font(.system(size: 15, weight: .semibold))
            Text("Comma, semicolon or tab separated. The first row names the series; the first column holds labels.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .frame(minWidth: 480, minHeight: 280)
            HStack {
                if error {
                    Label("No numbers found in this text.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    guard let table = DataTable.parse(text) else { error = true; return }
                    model.update(id, action: "Edit Data") { $0.table = table }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { text = model.chart(id)?.table.text() ?? "" }
    }
}

struct ToastView: View {
    @ObservedObject var model: PlotModel

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 10) {
                Image(systemName: toast.url == nil ? "info.circle.fill" : "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(toast.message).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                if let url = toast.url {
                    Button("Show in Finder") { revealInFinder([url]) }.buttonStyle(.link).font(.system(size: 12.5))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
