import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let cyan = Color(red: 0x22 / 255, green: 0xD3 / 255, blue: 0xEE / 255)
    static let deep = Color(red: 0x08 / 255, green: 0x91 / 255, blue: 0xB2 / 255)
    static let gradient = [cyan, deep]
    static let stage = Color(red: 0.055, green: 0.06, blue: 0.075)
}

struct ContentView: View {
    @ObservedObject var model: CueModel
    @ObservedObject private var prompter = PromptController.shared
    @Environment(\.undoManager) private var undoManager
    @State private var dropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 320)
        } detail: {
            HStack(spacing: 0) {
                if let id = model.selection, let script = model.binding(for: id) {
                    EditorView(script: script, wpm: model.settings.wordsPerMinute)
                        .id(id)
                } else {
                    ContentUnavailableView {
                        Label("No script selected", systemImage: "text.alignleft")
                    } description: {
                        Text("Create a script with Command N, or drop a text file on the sidebar.")
                    } actions: {
                        Button("New Script") { model.newScript() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                InspectorView(model: model, script: model.selected)
                    .frame(width: 300)
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.newScript() } label: { Label("New Script", systemImage: "square.and.pencil") }
                    .help("New script (⌘N)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $model.settings.mirror) {
                    Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Mirror the prompt for a beam splitter (⇧⌘M)")
                Button { start() } label: { Label("Start Prompting", systemImage: "play.fill") }
                    .help("Start prompting (⌘↩)")
                    .disabled(model.selected == nil)
            }
        }
        .fileImporter(isPresented: $model.isImporting, allowedContentTypes: [.plainText, .text], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Scripts") {
                ForEach(model.scripts) { script in
                    ScriptRow(script: script, wpm: model.settings.wordsPerMinute)
                        .tag(script.id)
                        .contextMenu {
                            Button("Start Prompting") { PromptController.shared.start(script, model: model) }
                            Button("Duplicate") { model.duplicate(script.id) }
                            Button("Export as Text…") { model.export(script.id) }
                            Divider()
                            Button("Delete", role: .destructive) { model.delete(script.id, undo: undoManager) }
                        }
                }
                .onMove { model.scripts.move(fromOffsets: $0, toOffset: $1) }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.scripts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.page.badge.magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                    Text("No scripts yet").font(.headline).foregroundStyle(.secondary)
                    Text("Press ⌘N or drop a text file here.").font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cyan, lineWidth: 2).padding(6)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.importFiles(urls) > 0 } isTargeted: { dropTargeted = $0 }
    }

    private func start() {
        guard let script = model.selected else { return }
        PromptController.shared.start(script, model: model)
    }
}

struct ScriptRow: View {
    let script: Script
    let wpm: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(script.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            HStack(spacing: 6) {
                Text("\(script.words) words")
                Text("·")
                Text(Metrics.clock(Metrics.duration(words: script.words, wpm: wpm)))
            }
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor

struct EditorView: View {
    @Binding var script: Script
    let wpm: Int

    var body: some View {
        let words = script.words
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Title", text: $script.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                HStack(spacing: 8) {
                    StatChip(symbol: "text.word.spacing", text: "\(words) words")
                    StatChip(symbol: "timer", text: "About \(Metrics.spoken(Metrics.duration(words: words, wpm: wpm))) at \(wpm) wpm")
                    Spacer()
                    Text(script.modified, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider().padding(.horizontal, 28).opacity(0.6)
            TextEditor(text: $script.text)
                .font(.system(size: 15))
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 23)
                .padding(.vertical, 12)
        }
        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct StatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @ObservedObject var model: CueModel
    @ObservedObject private var prompter = PromptController.shared
    let script: Script?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    PreviewCard(text: script?.text ?? "", settings: model.settings)
                        .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
                }
                Section("Scrolling") {
                    SliderRow(title: "Speed", value: $model.settings.speed, range: PromptSettings.speedRange, step: 0.5) {
                        String(format: "%.1f", $0)
                    }
                    Toggle("Count down 3, 2, 1", isOn: $model.settings.countdown)
                }
                Section("Text") {
                    SliderRow(title: "Size", value: $model.settings.fontSize, range: PromptSettings.fontRange, step: 4) { "\(Int($0)) pt" }
                    SliderRow(title: "Margins", value: $model.settings.margin, range: PromptSettings.marginRange, step: 0.01) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                    Toggle("Mirror horizontally", isOn: $model.settings.mirror)
                }
                Section("Reading line") {
                    Toggle("Show marker", isOn: $model.settings.showReadingLine)
                    SliderRow(title: "Position", value: $model.settings.readingLine, range: PromptSettings.lineRange, step: 0.01) {
                        "\(Int(($0 * 100).rounded()))% down"
                    }
                }
                Section("Timing") {
                    Stepper(value: $model.settings.wordsPerMinute, in: PromptSettings.wpmRange, step: 5) {
                        LabeledContent("Pace", value: "\(model.settings.wordsPerMinute) wpm").monospacedDigit()
                    }
                    LabeledContent("Estimated length",
                                   value: Metrics.spoken(Metrics.duration(words: script?.words ?? 0, wpm: model.settings.wordsPerMinute)))
                        .monospacedDigit()
                }
                Section("Display") {
                    Picker("Prompt on", selection: $model.settings.displayID) {
                        Text("Main display").tag(UInt32(0))
                        if !Desktop.isSnapshot {
                            ForEach(NSScreen.screens.dropFirst(), id: \.displayID) { screen in
                                Text(screen.localizedName).tag(screen.displayID)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .tint(Theme.deep)
            Divider()
            Button {
                if prompter.isActive { prompter.stop() } else if let script { prompter.start(script, model: model) }
            } label: {
                Label(prompter.isActive ? "Stop Prompting" : "Start Prompting", systemImage: prompter.isActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(Theme.gradient))
            .disabled(script == nil)
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range).tint(Theme.deep)
                .labelsHidden()
        }
    }
}

/// The prompt as it will look on the chosen display, scaled to fit the inspector.
struct PreviewCard: View {
    let text: String
    let settings: PromptSettings

    var body: some View {
        let screen = Desktop.isSnapshot ? CGSize(width: 1440, height: 900) : (NSScreen.prompt(settings.displayID)?.frame.size ?? CGSize(width: 1440, height: 900))
        GeometryReader { geo in
            let scale = geo.size.width / screen.width
            PromptStage(text: text, settings: settings, offset: 0, size: screen)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.black.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
        .animation(.snappy, value: settings)
        .accessibilityLabel("Prompt preview")
    }
}

/// The window as the website shows it, with fixed demo scripts.
struct DemoRoot: View {
    @StateObject private var model = CueModel.demo

    var body: some View { ContentView(model: model) }
}
