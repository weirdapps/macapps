import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(nsColor: rgb(0xFFB86B))
    static let bottom = Color(nsColor: rgb(0xF2683C))
    static let accent = Color(nsColor: Palette.accent)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let defaultFontSize = 15.0
}

struct ContentView: View {
    @ObservedObject var model: FigureModel
    @AppStorage("fontSize") private var fontSize = Theme.defaultFontSize

    var body: some View {
        NavigationSplitView {
            SheetList(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 320)
        } detail: {
            if let sheet = model.current {
                EditorPane(model: model, sheet: sheet, fontSize: fontSize)
                    .id(sheet.id)
            } else {
                ContentUnavailableView("No Sheet", systemImage: "equal.square",
                                       description: Text("Press ⌘N to start a new sheet."))
            }
        }
        .tint(Theme.accent)
        .frame(minWidth: 720, minHeight: 440)
        .confirmationDialog("Delete this sheet?", isPresented: Binding(
            get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })) {
            Button("Delete", role: .destructive) { if let id = model.pendingDelete { model.delete(id) } }
            Button("Cancel", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("The sheet and its lines are removed. This cannot be undone.")
        }
    }
}

// MARK: - Sidebar

struct SheetList: View {
    @ObservedObject var model: FigureModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sheets) { sheet in
                SheetRow(sheet: sheet, selected: model.selection == sheet.id)
                    .tag(sheet.id)
                    .contextMenu {
                        Button("Duplicate") { model.selection = sheet.id; model.duplicate() }
                        Divider()
                        Button("Delete…", role: .destructive) { model.requestDelete(sheet.id) }
                    }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.requestDelete() }
        .toolbar {
            ToolbarItem {
                Button { model.newSheet() } label: { Label("New Sheet", systemImage: "square.and.pencil") }
                    .help("New sheet (⌘N)")
            }
        }
    }
}

struct SheetRow: View {
    let sheet: Sheet
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sheet.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(sheet.modified, format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(.secondary)
                if let r = sheet.lastResult {
                    Text(r)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.accent))
                        .lineLimit(1)
                }
            }
            .font(.system(size: 11.5))
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor pane

struct EditorPane: View {
    @ObservedObject var model: FigureModel
    let sheet: Sheet
    let fontSize: Double

    var body: some View {
        VStack(spacing: 0) {
            SheetEditor(text: model.binding(for: sheet.id), fontSize: fontSize, focus: !Desktop.isSnapshot) { value in
                model.copy(value)
            }
            Divider()
            StatusBar(model: model, sheet: sheet)
        }
        .navigationTitle(sheet.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.copyWithResults() } label: { Label("Copy with Results", systemImage: "doc.on.doc") }
                    .help("Copy the sheet with its results (⌥⇧⌘C)")
                Button { model.showReference.toggle() } label: { Label("Reference", systemImage: "function") }
                    .help("What you can type (⌘/)")
                    .popover(isPresented: $model.showReference, arrowEdge: .bottom) { ReferenceView() }
            }
        }
    }
}

struct StatusBar: View {
    @ObservedObject var model: FigureModel
    let sheet: Sheet

    var body: some View {
        let results = Engine.evaluate(sheet.text)
        let lines = sheet.text.isEmpty ? 0 : results.count
        let answered = results.filter { $0.value != nil }.count
        HStack(spacing: 8) {
            Text("\(lines) \(lines == 1 ? "line" : "lines")  ·  \(answered) \(answered == 1 ? "result" : "results")")
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
            if let flash = model.flash {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    Text(flash.text).lineLimit(1).truncationMode(.middle)
                    if let url = flash.url {
                        Button("Show in Finder") { revealInFinder([url]) }
                            .buttonStyle(.link)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                Text("Click a result to copy it")
                    .transition(.opacity)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .animation(.snappy, value: lines)
    }
}

// MARK: - Reference

struct ReferenceView: View {
    struct Topic: Identifiable {
        let title: String
        let examples: [String]
        var id: String { title }
    }

    static let groups: [Topic] = [
        Topic(title: "Arithmetic", examples: ["(2 + 3) × 4", "2^10", "17 mod 5"]),
        Topic(title: "Percentages", examples: ["20% of 150", "150 + 10%", "25% off $80"]),
        Topic(title: "Variables and lines", examples: ["rent = 950", "prev, ans", "sum, total, average"]),
        Topic(title: "Units", examples: ["10 km in mi", "70 kg in lb", "200 C in F", "90 min in h"]),
        Topic(title: "Functions", examples: ["sqrt(2)", "round(3.14159, 2)", "sin(30°)", "log(1000)"]),
        Topic(title: "Notes", examples: ["# a heading or comment", "Groceries: $64.20"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you can type").font(.system(size: 15, weight: .bold, design: .rounded))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                ForEach(Self.groups) { group in
                    GridRow {
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            .gridCellColumns(2)
                    }
                    .padding(.top, 6)
                    ForEach(group.examples, id: \.self) { example in
                        GridRow {
                            Text(example).font(.system(size: 13).monospacedDigit())
                            Text(Engine.result(example) ?? "")
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Theme.accent)
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
            Text("sum and total add the lines above, up to a blank line or heading.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 330)
    }
}
