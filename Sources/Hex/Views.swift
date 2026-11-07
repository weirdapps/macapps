import AppKit
import Kit
import SwiftUI

enum Theme {
    static let amber = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgb(0xFBBF24) : rgb(0xF59E0B) }
    static let amberText = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgb(0xFCD34D) : rgb(0xB45309) }
    static let teal = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgb(0x2DD4BF) : rgb(0x0F766E) }
    static let tealText = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) == .darkAqua ? rgb(0x5EEAD4) : rgb(0x0F6A73) }
    static let accent = Color(nsColor: amber)
    static let gradient = LinearGradient(colors: [Color(nsColor: rgb(0x0F4C5C)), Color(nsColor: rgb(0x05222B))],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - Window

/// A viewer window. Its scene value is the file's URL, so windows reopen with their files after a relaunch.
struct ViewerWindow: View {
    @Binding var url: URL?
    @StateObject private var model = HexModel()
    @State private var windowID = UUID()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ViewerContent(model: model)
            .onAppear {
                OpenRouter.shared.openWindow = openWindow
                OpenRouter.shared.register(model)
                if let url { model.load(url) } else { registerEmpty() }
            }
            .onChange(of: url) { _, new in
                guard let new else { return }
                OpenRouter.shared.unregister(windowID)
                if new != model.url { model.load(new) }
            }
            .onDisappear {
                OpenRouter.shared.unregister(windowID)
                OpenRouter.shared.unregister(model)
            }
    }

    private func registerEmpty() {
        let binding = $url
        OpenRouter.shared.registerEmpty(windowID) { binding.wrappedValue = $0 }
    }
}

struct ViewerContent: View {
    @ObservedObject var model: HexModel
    @State private var targeted = false

    var body: some View {
        Group {
            if model.url == nil {
                DropZone(symbol: "hexagon", title: "Open a File",
                         message: "Drop any file here, or choose one. Hex shows every byte and never changes one.",
                         button: "Open\u{2026}", tint: Theme.accent, isTargeted: targeted) { OpenRouter.shared.choose() }
            } else {
                viewer
            }
        }
        .frame(minWidth: 720, minHeight: 420)
        .dropDestination(for: URL.self) { urls, _ in
            OpenRouter.shared.open(urls)
            return true
        } isTargeted: { targeted = $0 }
        .navigationTitle(model.url?.lastPathComponent ?? "Hex")
        .navigationSubtitle(model.source.map { HexFormat.size($0.count) } ?? "")
        .modifier(ProxyIcon(url: Desktop.isSnapshot ? nil : model.url))
        .toolbar { toolbar }
        .sheet(isPresented: $model.showJump) { JumpSheet(model: model) }
        .focusedSceneObject(model)
    }

    private var viewer: some View {
        VStack(spacing: 0) {
            if model.showFind {
                FindBar(model: model)
                Divider()
            }
            if let error = model.error {
                ContentUnavailableView("Can\u{2019}t Open File", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !model.hasBytes {
                ContentUnavailableView("Empty File", systemImage: "doc", description: Text("This file has no bytes to show."))
            } else {
                HexGrid(model: model)
            }
            Divider()
            StatusBar(model: model)
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorPanel(model: model)
                .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showJump = true } label: { Label("Jump to Offset", systemImage: "arrow.down.to.line") }
                .help("Jump to an offset (\u{2318}L)")
                .disabled(!model.hasBytes)
            Button { model.beginFind() } label: { Label("Find", systemImage: "magnifyingglass") }
                .help("Find text or hex bytes (\u{2318}F)")
                .disabled(!model.hasBytes)
            Button { model.addBookmark() } label: { Label("Add Bookmark", systemImage: "bookmark") }
                .help("Bookmark the selection (\u{2318}D)")
                .disabled(!model.hasBytes)
            Button { model.showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show or hide the inspector (\u{2325}\u{2318}I)")
                .disabled(model.url == nil)
        }
    }
}

private struct ProxyIcon: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

// MARK: - Find bar

struct FindBar: View {
    @ObservedObject var model: HexModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Picker("Find", selection: $model.findMode) {
                ForEach(FindMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Search for text (as UTF-8) or for hex bytes")

            TextField(model.findMode == .text ? "Find text" : "Find hex bytes, like DE AD BE EF", text: $model.findText)
                .textFieldStyle(.roundedBorder)
                .font(model.findMode == .hex ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
                .focused($focused)
                .onSubmit { model.find() }

            Group {
                if let progress = model.searchProgress {
                    ProgressView(value: progress).frame(width: 90)
                    Button("Stop") { model.cancelSearch() }.controlSize(.small)
                } else if let status = model.findStatus {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .fixedSize()

            ControlGroup {
                Button { model.find(backwards: true) } label: { Image(systemName: "chevron.left") }
                    .help("Find previous (\u{21E7}\u{2318}G)")
                Button { model.find() } label: { Image(systemName: "chevron.right") }
                    .help("Find next (\u{2318}G)")
            }
            .fixedSize()
            .disabled(model.needle == nil)

            Button("Done") { model.closeFind() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = !Desktop.isSnapshot }
        .onChange(of: model.findFocusToken) { focused = true }
        .onExitCommand { model.closeFind() }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: HexModel

    var body: some View {
        HStack(spacing: 14) {
            Label("Read only", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
            if model.hasBytes {
                Text("Offset \(Text("0x" + HexFormat.hex(model.selection.lowerBound, digits: HexFormat.offsetDigits(forCount: model.count))).foregroundStyle(.primary)) (\(model.selection.lowerBound))")
                    .contentTransition(.numericText())
                Text(model.selectionLength == 1 ? "1 byte selected" : "\(Inspector.count(model.selectionLength)) bytes selected")
                    .contentTransition(.numericText())
            }
            Spacer()
            if let source = model.source {
                Text(source.count < 1024 ? HexFormat.size(source.count)
                     : "\(HexFormat.size(source.count)) (\(Inspector.count(source.count)) bytes)")
            }
        }
        .font(.system(size: 11.5))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.snappy(duration: 0.15), value: model.selection)
    }
}

// MARK: - Inspector

struct InspectorPanel: View {
    @ObservedObject var model: HexModel

    var body: some View {
        Form {
            if model.hasBytes {
                Section("Selection") {
                    LabeledContent("Offset") { mono("0x" + HexFormat.hex(model.selection.lowerBound, digits: 1)) + Text("  (\(model.selection.lowerBound))").foregroundStyle(.secondary) }
                    LabeledContent("Length") { mono(model.selectionLength == 1 ? "1 byte" : "\(Inspector.count(model.selectionLength)) bytes") }
                }
                Section {
                    Picker("Byte order", selection: $model.bigEndian) {
                        Text("Little").tag(false)
                        Text("Big").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach(Inspector.rows(model.inspectedBytes, bigEndian: model.bigEndian)) { row in
                            GridRow {
                                Text(row.name).foregroundStyle(.secondary)
                                mono(row.value)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Values")
                }
                Section("UTF-8") {
                    let bytes = model.selectedBytes(prefix: 512)
                    if let text = Inspector.utf8(bytes, truncated: model.selectionLength > bytes.count) {
                        Text(text + (model.selectionLength > 512 ? "\u{2026}" : ""))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(5)
                            .textSelection(.enabled)
                    } else {
                        Text("Not valid UTF-8").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                if model.bookmarks.isEmpty {
                    Text("Select some bytes and press \u{2318}D to bookmark them.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($model.bookmarks) { $mark in
                        BookmarkRow(model: model, mark: $mark)
                    }
                }
            } header: {
                HStack {
                    Text("Bookmarks")
                    Spacer()
                    Button { model.addBookmark() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Bookmark the selection (\u{2318}D)")
                        .disabled(!model.hasBytes)
                }
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 12))
    }

    private func mono(_ s: String) -> Text {
        Text(s).font(.system(size: 12, design: .monospaced)).monospacedDigit()
    }
}

struct BookmarkRow: View {
    @ObservedObject var model: HexModel
    @Binding var mark: Bookmark
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: Theme.teal))
            VStack(alignment: .leading, spacing: 1) {
                if model.editingBookmark == mark.id {
                    TextField("Name", text: $mark.name, prompt: Text("Name"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { model.finishRename() }
                        .onAppear { focused = !Desktop.isSnapshot }
                        .onChange(of: focused) { _, now in if !now, model.editingBookmark == mark.id { model.editingBookmark = nil } }
                } else {
                    Text(mark.name).lineLimit(1)
                }
                Text("0x" + HexFormat.hex(mark.offset, digits: 1) + (mark.length > 1 ? "  \(mark.length) bytes" : ""))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if hovering {
                Button { model.remove(mark) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Remove bookmark")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.editingBookmark = mark.id }
        .onTapGesture { model.go(to: mark) }
        .contextMenu {
            Button("Go to Bookmark") { model.go(to: mark) }
            Button("Rename") { model.editingBookmark = mark.id }
            Divider()
            Button("Remove Bookmark") { model.remove(mark) }
        }
    }
}

// MARK: - Jump sheet

struct JumpSheet: View {
    @ObservedObject var model: HexModel
    @State private var text = ""
    @State private var invalid = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to Offset").font(.system(size: 15, weight: .semibold, design: .rounded))
            TextField("Offset", text: $text, prompt: Text("0x1F40 or 8000"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .onSubmit(go)
                .onChange(of: text) { invalid = false }
            Text(invalid ? "That offset is not in this file (0 to \(model.count - 1))."
                         : "Decimal, or hex with 0x. Start with + or - to move from the cursor.")
                .font(.system(size: 11.5))
                .foregroundStyle(invalid ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Jump", action: go).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func go() {
        if model.jump(to: text) { dismiss() } else { invalid = true; NSSound.beep() }
    }
}
