import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let top = Color(red: 0x56 / 255, green: 0xCC / 255, blue: 0xF2 / 255)
    static let bottom = Color(red: 0x2F / 255, green: 0x80 / 255, blue: 0xED / 255)
    static let accent = bottom
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct ContentView: View {
    @ObservedObject var model: RenameModel
    @Environment(\.undoManager) private var undoManager
    @State private var importing = false
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 0) {
            RulesPanel(model: model)
                .frame(width: 330)
            Divider()
            VStack(spacing: 0) {
                if model.items.isEmpty {
                    DropZone(symbol: "character.cursor.ibeam", title: "Drop files to rename",
                             message: "Drop files, or a folder to rename what is inside it. Nothing changes until you press Rename.",
                             button: "Add Files\u{2026}", tint: Theme.accent, isTargeted: targeted) { importing = true }
                } else {
                    FileTable(model: model)
                }
                Divider()
                BottomBar(model: model)
            }
            .frame(minWidth: 420)
        }
        .frame(minWidth: 780, minHeight: 480)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .renameOpen)) { _ in importing = true }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .alert("Could not rename", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text((model.errorMessage ?? "") + " Nothing was changed.")
        }
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { importing = true } label: { Label("Add Files", systemImage: "plus") }
                .help("Add files or folders (\u{2318}O)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(SortKey.allCases) { key in
                    Button("Sort by \(key.title)") { model.sort(by: key) }
                }
                Divider()
                Button("Reverse Order") { model.reverse() }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort the list; numbering follows its order")
            .disabled(model.items.isEmpty)
            Button { model.moveSelection(-1) } label: { Label("Move Up", systemImage: "chevron.up") }
                .help("Move the selected files up (\u{2325}\u{2318}\u{2191})")
                .disabled(!model.canMoveUp)
            Button { model.moveSelection(1) } label: { Label("Move Down", systemImage: "chevron.down") }
                .help("Move the selected files down (\u{2325}\u{2318}\u{2193})")
                .disabled(!model.canMoveDown)
            Button { model.removeSelected() } label: { Label("Remove", systemImage: "minus.circle") }
                .help("Remove the selected files from the list (\u{232B})")
                .disabled(model.selection.isEmpty)
            Button { model.undoLastBatch() } label: { Label("Undo Rename", systemImage: "arrow.uturn.backward") }
                .help("Put back the names from the last rename (\u{2325}\u{2318}Z)")
                .disabled(model.lastBatch.isEmpty)
        }
    }
}

extension Notification.Name {
    static let renameOpen = Notification.Name("RenameOpen")
}

// MARK: - Table

struct FileTable: View {
    @ObservedObject var model: RenameModel

    var body: some View {
        Table(model.rows, selection: $model.selection) {
            TableColumn("#") { row in
                Text("\(row.number)").monospacedDigit().foregroundStyle(.tertiary)
            }
            .width(min: 26, ideal: 30, max: 44)
            TableColumn("Original Name") { row in
                HStack(spacing: 6) {
                    Image(systemName: row.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(row.isDirectory ? AnyShapeStyle(Theme.top) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                    Text(row.original).lineLimit(1).truncationMode(.middle)
                }
            }
            .width(min: 140, ideal: 190)
            TableColumn("New Name") { row in
                NewNameCell(row: row)
            }
            .width(min: 160, ideal: 250)
            TableColumn("Modified") { row in
                Text(row.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 90, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Reveal in Finder") { model.selection = ids; model.revealSelected() }
            Button("Remove from List") { model.selection = ids; model.removeSelected() }
        }
    }
}

struct NewNameCell: View {
    let row: Row

    var body: some View {
        HStack(spacing: 6) {
            switch row.status {
            case .unchanged:
                Image(systemName: "equal").foregroundStyle(.tertiary).frame(width: 16)
                Text(row.newName).foregroundStyle(.secondary)
            case .rename:
                Image(systemName: "arrow.right").foregroundStyle(Theme.accent).fontWeight(.semibold).frame(width: 16)
                Text(row.newName).fontWeight(.medium).foregroundStyle(.primary)
            case .conflict, .invalid:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).frame(width: 16)
                Text(row.newName.isEmpty ? "(empty)" : row.newName).foregroundStyle(.red).fontWeight(.medium)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                Text(row.status.badge ?? "")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.red.opacity(0.12)))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .help(row.status.reason ?? row.newName)
    }
}

// MARK: - Bottom bar

struct BottomBar: View {
    @ObservedObject var model: RenameModel

    var body: some View {
        HStack(spacing: 12) {
            if model.loading > 0 {
                ProgressView().controlSize(.small)
                Text("Reading files\u{2026}").foregroundStyle(.secondary)
            } else if let notice = model.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
                if !model.lastBatch.isEmpty {
                    Button("Undo") { model.undoLastBatch() }.buttonStyle(.link)
                }
            } else {
                summary
            }
            Spacer()
            Button {
                model.apply()
            } label: {
                Text(model.renameCount == 0 ? "Rename" : "Rename \(model.renameCount) \(model.renameCount == 1 ? "File" : "Files")")
                    .contentTransition(.numericText())
            }
            .buttonStyle(PillButtonStyle([Theme.top, Theme.bottom]))
            .disabled(model.renameCount == 0)
            .opacity(model.renameCount == 0 ? 0.45 : 1)
            .help("Rename every file with an arrow; files with a warning keep their names (\u{2318}R)")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.snappy, value: model.renameCount)
    }

    private var summary: some View {
        HStack(spacing: 14) {
            stat("\(model.items.count)", model.items.count == 1 ? "file" : "files", .secondary)
            stat("\(model.renameCount)", "to rename", Theme.accent)
            if model.problemCount > 0 {
                stat("\(model.problemCount)", model.problemCount == 1 ? "conflict, keeps its name" : "conflicts, keep their names", .red)
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: some ShapeStyle) -> some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(tint).contentTransition(.numericText())
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rules

struct RulesPanel: View {
    @ObservedObject var model: RenameModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Rules").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("applied top to bottom").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(RuleKind.allCases) { kind in
                        Button { model.addRule(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Image(systemName: "plus").fontWeight(.semibold)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .focusEffectDisabled()
                .help("Add a rule")
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            if model.rules.isEmpty {
                ContentUnavailableView("No rules", systemImage: "list.bullet.rectangle",
                                       description: Text("Add a rule with the plus button to start building new names."))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($model.rules) { $rule in
                            RuleCard(rule: $rule, model: model)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RuleCard: View {
    @Binding var rule: Rule
    @ObservedObject var model: RenameModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if rule.enabled {
                editor
                    .controlSize(.small)
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.05), radius: hovering ? 4 : 2, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: rule.enabled)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: rule.kind.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(rule.enabled ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.5))))
            Text(rule.kind.title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rule.enabled ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: $rule.enabled).toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
                .help(rule.enabled ? "Turn this rule off" : "Turn this rule on")
            Menu {
                Button("Move Up") { model.moveRule(rule.id, by: -1) }.disabled(model.rules.first?.id == rule.id)
                Button("Move Down") { model.moveRule(rule.id, by: 1) }.disabled(model.rules.last?.id == rule.id)
                Divider()
                Button("Delete Rule", role: .destructive) { model.deleteRule(rule.id) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Move or delete this rule")
        }
    }

    @ViewBuilder
    private var editor: some View {
        switch rule.kind {
        case .replace:
            VStack(alignment: .leading, spacing: 7) {
                field("Find", $rule.find, prompt: rule.regex ? "Pattern, like IMG_(\\d+)" : "Text to find")
                if let error = rule.regexError {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.leading, 62)
                }
                field("With", $rule.replacement, prompt: rule.regex ? "Use $1 for the first group" : "Replacement")
                HStack(spacing: 14) {
                    Toggle("Regular expression", isOn: $rule.regex)
                    Toggle("Match case", isOn: $rule.matchCase)
                }
                .padding(.leading, 62)
            }
        case .insert:
            VStack(alignment: .leading, spacing: 7) {
                field("Text", $rule.text, prompt: "Text to insert")
                placementRow([.prefix, .suffix, .index, .replace])
            }
        case .changeCase:
            labeled("Case") {
                Picker("", selection: $rule.caseStyle) {
                    ForEach(CaseStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
            }
        case .number:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    labeled("Start") { stepper($rule.start, range: -9999...999_999) }
                    labeled("Step", width: 34) { stepper($rule.step, range: 1...1000) }
                }
                HStack(spacing: 10) {
                    labeled("Digits") { stepper($rule.padding, range: 1...8) }
                    labeled("Join", width: 34) { separatorField }
                }
                placementRow([.prefix, .suffix, .index, .replace])
            }
        case .date:
            VStack(alignment: .leading, spacing: 7) {
                labeled("From") {
                    Picker("", selection: $rule.dateSource) {
                        ForEach(DateSource.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                }
                labeled("Format") {
                    HStack(spacing: 4) {
                        TextField("", text: $rule.dateFormat, prompt: Text("yyyy-MM-dd")).textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                        Menu {
                            ForEach(["yyyy-MM-dd", "yyyyMMdd", "yyyy-MM-dd HH.mm.ss", "yyyyMMdd_HHmmss", "dd.MM.yyyy", "MMMM yyyy"], id: \.self) { f in
                                Button(f) { rule.dateFormat = f }
                            }
                        } label: { Image(systemName: "chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .help("Common formats")
                    }
                }
                HStack(spacing: 10) {
                    placementPicker([.prefix, .suffix, .replace])
                    labeled("Join", width: 34) { separatorField }
                }
                .padding(.leading, 62)
                if rule.dateSource == .photo {
                    Text("Files without EXIF use their modification date.")
                        .font(.caption).foregroundStyle(.secondary).padding(.leading, 62)
                }
            }
        case .trim:
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 14) {
                    Toggle("Spaces at the ends", isOn: $rule.trimEnds)
                    Toggle("Double spaces", isOn: $rule.collapseSpaces)
                }
                HStack(spacing: 10) {
                    labeled("First", width: 34) { stepper($rule.dropFirst, range: 0...255) }
                    labeled("Last", width: 34) { stepper($rule.dropLast, range: 0...255) }
                    Text("characters").foregroundStyle(.secondary).font(.system(size: 11))
                }
            }
        case .remove:
            VStack(alignment: .leading, spacing: 7) {
                field("Remove", $rule.characters, prompt: "Characters, like ()[]#")
                HStack(spacing: 12) {
                    Toggle("Digits", isOn: $rule.digits)
                    Toggle("Symbols", isOn: $rule.punctuation)
                    Toggle("Spaces", isOn: $rule.spaces)
                }
                .padding(.leading, 62)
            }
        case .fileExtension:
            labeled("Make") {
                HStack(spacing: 6) {
                    Picker("", selection: $rule.extensionMode) {
                        ForEach(ExtensionMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if rule.extensionMode == .set {
                        TextField("", text: $rule.newExtension, prompt: Text("jpg")).textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private func labeled<V: View>(_ label: String, width: CGFloat = 54, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary).font(.system(size: 11.5)).frame(width: width, alignment: .trailing)
            content()
        }
    }

    private func field(_ label: String, _ text: Binding<String>, prompt: String) -> some View {
        labeled(label) {
            TextField("", text: text, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }

    private func stepper(_ value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 3) {
            TextField("", value: value, format: .number.grouping(.never)).textFieldStyle(.roundedBorder)
                .monospacedDigit().frame(width: 46)
            Stepper("", value: value, in: range).labelsHidden()
        }
    }

    private var separatorField: some View {
        Picker("", selection: $rule.separator) {
            Text("Space").tag(" ")
            Text("Dash").tag("-")
            Text("Underscore").tag("_")
            Text("Dot").tag(".")
            Text("Nothing").tag("")
        }
        .labelsHidden()
        .fixedSize()
        .help("What goes between the name and the inserted value")
    }

    private func placementPicker(_ options: [Placement]) -> some View {
        Picker("", selection: $rule.placement) {
            ForEach(options) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func placementRow(_ options: [Placement]) -> some View {
        HStack(spacing: 8) {
            placementPicker(options)
            if rule.placement == .index {
                Text("character").foregroundStyle(.secondary).font(.system(size: 11.5))
                stepper($rule.position, range: 0...255)
            } else {
                Text(rule.placement == .replace ? "the whole name" : "the name").foregroundStyle(.secondary).font(.system(size: 11.5))
            }
        }
        .padding(.leading, 62)
    }
}
