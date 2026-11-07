import AppKit
import Kit
import SwiftUI

enum Theme {
    static let top = Color(red: 0x7A / 255, green: 0x5C / 255, blue: 0xFF / 255)
    static let bottom = Color(red: 0x3B / 255, green: 0x22 / 255, blue: 0xC9 / 255)
    static let gradient = LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    static let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func color(_ m: HTTPMethod) -> Color {
        switch m {
        case .GET: Color(red: 0.13, green: 0.62, blue: 0.38)
        case .POST: Color(red: 0.93, green: 0.52, blue: 0.1)
        case .PUT: Color(red: 0.16, green: 0.45, blue: 0.9)
        case .PATCH: Color(red: 0.55, green: 0.36, blue: 0.95)
        case .DELETE: Color(red: 0.86, green: 0.2, blue: 0.24)
        case .HEAD, .OPTIONS: Color(red: 0.45, green: 0.5, blue: 0.58)
        }
    }

    static func color(status: Int?) -> Color {
        switch status ?? 0 {
        case 200..<300: Color(red: 0.13, green: 0.62, blue: 0.38)
        case 300..<400: Color(red: 0.16, green: 0.45, blue: 0.9)
        case 400..<500: Color(red: 0.93, green: 0.52, blue: 0.1)
        case 500...: Color(red: 0.86, green: 0.2, blue: 0.24)
        default: .secondary
        }
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) }
    }

    static let keyColor = dynamic(0x5532D6, 0xB7A4FF)
    static let stringColor = dynamic(0xC41A16, 0xFF8170)
    static let numberColor = dynamic(0x1C00CF, 0xD9C97C)
    static let literalColor = dynamic(0x9B2393, 0xFF7AB2)

    /// JSON with syntax colour; plain text past 400 KB so huge bodies stay fast.
    static func highlighted(_ text: String) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor]
        guard text.utf8.count < 400_000 else { return NSAttributedString(string: text, attributes: base) }
        let out = NSMutableAttributedString()
        for t in JSONFormat.tokens(text) {
            var a = base
            switch t.kind {
            case .key: a[.foregroundColor] = keyColor
            case .string: a[.foregroundColor] = stringColor
            case .number: a[.foregroundColor] = numberColor
            case .literal: a[.foregroundColor] = literalColor
            case .punctuation: a[.foregroundColor] = NSColor.secondaryLabelColor
            case .space: break
            }
            out.append(NSAttributedString(string: t.text, attributes: a))
        }
        return out
    }

    static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: Store

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 340)
        } detail: {
            if model.current != nil {
                RequestDetail(model: model)
            } else {
                ContentUnavailableView {
                    Label("No Request Selected", systemImage: "paperplane")
                } description: {
                    Text("Choose a request in the sidebar, or press \u{2318}N to start a new one.")
                } actions: {
                    Button("New Request") { model.newRequest() }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.newRequest() } label: { Label("New Request", systemImage: "square.and.pencil") }
                    .help("New request (\u{2318}N)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                EnvironmentMenu(model: model)
                Button { model.copyCurl() } label: {
                    Label("Copy as curl", systemImage: model.copied ? "checkmark" : "terminal")
                        .contentTransition(.symbolEffect(.replace))
                }
                .help("Copy as curl (\u{21E7}\u{2318}C)")
                .disabled(model.current == nil)
            }
        }
        .sheet(isPresented: $model.showEnvironments) { EnvironmentsSheet(model: model) }
    }
}

struct EnvironmentMenu: View {
    @ObservedObject var model: Store

    var body: some View {
        Menu {
            Picker("Environment", selection: $model.workspace.activeEnvironment) {
                Text("No Environment").tag(UUID?.none)
                ForEach(model.workspace.environments) { Text($0.name).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Manage Environments\u{2026}") { model.showEnvironments = true }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                Text(model.activeEnvironment?.name ?? "No Environment")
            }
        }
        .help("Environment: the variables used in {{name}}")
        .fixedSize()
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @ObservedObject var model: Store
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        List(selection: $model.selection) {
            ForEach($model.workspace.collections) { $collection in
                Section(isExpanded: Binding(get: { !collapsed.contains(collection.id) },
                                            set: { if $0 { collapsed.remove(collection.id) } else { collapsed.insert(collection.id) } })) {
                    ForEach(collection.requests) { r in
                        RequestRow(request: r, selected: model.selection == .request(r.id))
                            .tag(SidebarItem.request(r.id))
                            .contextMenu { requestMenu(r, in: collection) }
                    }
                    if collection.requests.isEmpty {
                        Text("No requests yet").foregroundStyle(.tertiary).font(.system(size: 12))
                    }
                } header: {
                    if model.renaming == collection.id {
                        RenameField(name: $collection.name) { model.renaming = nil }
                    } else {
                        Text(collection.name)
                            .contextMenu {
                                Button("New Request") { model.newRequest(in: collection.id) }
                                Button("Rename") { model.renaming = collection.id }
                                Divider()
                                Button("Delete Collection", role: .destructive) { model.deleteCollection(collection.id) }
                            }
                    }
                }
            }
            if !model.history.isEmpty {
                Section("History") {
                    ForEach(model.history.prefix(60)) { e in
                        HistoryRow(entry: e, selected: model.selection == .history(e.id))
                            .tag(SidebarItem.history(e.id))
                            .contextMenu {
                                Button("Save to Collection") { model.selection = .history(e.id); model.saveToCollection() }
                                Button("Remove from History") { model.selection = .history(e.id); model.deleteSelected() }
                                Divider()
                                Button("Clear History") { model.clearHistory() }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.deleteSelected() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 2) {
                Menu {
                    Button("New Request") { model.newRequest() }
                    Button("New Collection") { model.newCollection() }
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a request or a collection")
                Spacer()
                Text("\(model.workspace.collections.reduce(0) { $0 + $1.requests.count }) requests")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func requestMenu(_ r: APIRequest, in collection: RequestCollection) -> some View {
        Button("Duplicate") { model.selection = .request(r.id); model.duplicate() }
        if model.workspace.collections.count > 1 {
            Menu("Move To") {
                ForEach(model.workspace.collections.filter { $0.id != collection.id }) { c in
                    Button(c.name) { model.move(r.id, to: c.id) }
                }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteRequest(r.id) }
    }
}

struct RenameField: View {
    @Binding var name: String
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Collection name", text: $name)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit(done)
            .onAppear { focused = true }
            .onChange(of: focused) { _, f in if !f { done() } }
    }
}

struct MethodBadge: View {
    let method: HTTPMethod
    var selected = false

    var body: some View {
        Text(method == .DELETE ? "DEL" : method == .OPTIONS ? "OPT" : method.rawValue)
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            
            .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.9)) : AnyShapeStyle(Theme.color(method)))
            .frame(width: 38, alignment: .leading)
    }
}

struct RequestRow: View {
    let request: APIRequest
    var selected = false

    var body: some View {
        HStack(spacing: 4) {
            MethodBadge(method: request.method, selected: selected)
            Text(request.name.isEmpty ? "Untitled" : request.name).lineLimit(1)
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    var selected = false

    private var path: String {
        guard let u = URL(string: entry.url) else { return entry.url }
        let p = u.path.isEmpty ? "/" : u.path
        return (u.host ?? "") + p
    }

    var body: some View {
        HStack(spacing: 4) {
            MethodBadge(method: entry.request.method, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(path).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if let s = entry.status {
                        Circle().fill(Theme.color(status: s)).frame(width: 6, height: 6)
                        Text("\(s)").monospacedDigit()
                        Text(Format.duration(entry.duration)).monospacedDigit()
                    } else {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 9))
                        Text("Failed")
                    }
                    Spacer(minLength: 0)
                    Text(entry.date, format: Calendar.current.isDateInToday(entry.date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Detail

struct RequestDetail: View {
    @ObservedObject var model: Store

    var body: some View {
        let request = model.currentBinding
        VStack(spacing: 0) {
            URLBar(model: model, request: request)
            Divider()
            HSplitView {
                RequestEditor(model: model, request: request)
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                ResponsePane(model: model)
                    .frame(minWidth: 320, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct URLBar: View {
    @ObservedObject var model: Store
    @Binding var request: APIRequest
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Request name", text: $request.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .fixedSize()
                Text(model.currentCollection?.name ?? "History")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                Spacer()
                if model.currentHistory != nil {
                    Button("Save to Collection") { model.saveToCollection() }
                        .controlSize(.small)
                        .help("Keep this request in a collection (\u{2325}\u{2318}S)")
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Menu {
                        ForEach(HTTPMethod.allCases) { m in
                            Button(m.rawValue) { request.method = m }
                        }
                    } label: {
                        Text(request.method.rawValue)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(Theme.color(request.method))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .help("HTTP method")
                    Divider().frame(height: 18)
                    TextField("https://api.example.com/path or {{base}}/path", text: $request.url)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($urlFocused)
                        .onSubmit { model.send() }
                        .padding(.horizontal, 9)
                }
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(urlFocused ? AnyShapeStyle(Theme.top.opacity(0.7)) : AnyShapeStyle(.quaternary), lineWidth: urlFocused ? 1.5 : 1))

                SendButton(model: model)
            }
            ResolvedLine(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct SendButton: View {
    @ObservedObject var model: Store

    var body: some View {
        Button {
            if model.isSending { model.cancel() } else { model.send() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.isSending ? "xmark" : "paperplane.fill").font(.system(size: 11, weight: .bold))
                Text(model.isSending ? "Cancel" : "Send")
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(PillButtonStyle(model.isSending ? [Color.gray.opacity(0.8), Color.gray] : [Theme.top, Theme.bottom]))
        .help(model.isSending ? "Cancel (\u{2318}.)" : "Send (\u{2318}\u{21A9})")
    }
}

/// The URL as it will be sent, shown when it uses variables or params, with any unknown variable called out.
struct ResolvedLine: View {
    @ObservedObject var model: Store

    var body: some View {
        if let r = model.current {
            let missing = Template.unresolved(in: ([r.url] + r.params.map(\.value) + r.headers.map(\.value)).joined(separator: " "), model.variables)
            if !missing.isEmpty {
                Label("Not defined in \(model.activeEnvironment?.name ?? "any environment"): \(missing.map { "{{\($0)}}" }.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else if case .success(let b)? = model.built, b.url != r.url {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    Text(b.url).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                .font(.system(size: 10))
            }
        }
    }
}

// MARK: - Request editor

struct TabBar<Tab: Hashable>: View {
    let tabs: [(Tab, String, Int?)]
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.0) { tab, title, count in
                Button { withAnimation(.snappy(duration: 0.2)) { selection = tab } } label: {
                    HStack(spacing: 5) {
                        Text(title)
                        if let count, count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(selection == tab ? Theme.bottom : .secondary)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(selection == tab ? Theme.top.opacity(0.16) : Color.secondary.opacity(0.12)))
                        }
                    }
                    .font(.system(size: 12, weight: selection == tab ? .semibold : .medium))
                    .foregroundStyle(selection == tab ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selection == tab ? AnyShapeStyle(.quaternary.opacity(0.7)) : AnyShapeStyle(.clear)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct RequestEditor: View {
    @ObservedObject var model: Store
    @Binding var request: APIRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TabBar(tabs: [(EditorTab.params, "Params", request.params.filter { $0.enabled && !$0.key.isEmpty }.count),
                              (.headers, "Headers", request.headers.filter { $0.enabled && !$0.key.isEmpty }.count),
                              (.body, "Body", nil)],
                       selection: $model.editorTab)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            Divider().opacity(0.6)
            switch model.editorTab {
            case .params:
                PairTable(pairs: $request.params, keyTitle: "Parameter", valueTitle: "Value", hint: "Query parameters are added to the URL and encoded for you.")
            case .headers:
                PairTable(pairs: $request.headers, keyTitle: "Header", valueTitle: "Value", hint: "Use {{name}} in any value to pull it from the environment.")
            case .body:
                BodyEditor(model: model, request: $request)
            }
        }
    }
}

/// An editable key and value table with an always-present blank row at the end for adding.
struct PairTable: View {
    @Binding var pairs: [Pair]
    let keyTitle: String
    let valueTitle: String
    var hint: String? = nil
    @State private var blankID = UUID()

    private var rows: [Pair] { pairs + [Pair(id: blankID)] }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 30)
                    Text(keyTitle).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    Text(valueTitle).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    Color.clear.frame(width: 28)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                Divider().opacity(0.6)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, _ in
                    PairRow(pair: binding(index), isBlank: index == pairs.count, keyTitle: keyTitle) {
                        pairs.remove(at: index)
                    }
                    Divider().opacity(0.4)
                }
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.top, 10)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 10)
        }
    }

    private func binding(_ index: Int) -> Binding<Pair> {
        if index < pairs.count { return $pairs[index] }
        let id = blankID
        return Binding(get: { Pair(id: id) }, set: { new in
            guard !new.isBlank else { return }
            pairs.append(new)
            blankID = UUID()
        })
    }
}

struct PairRow: View {
    @Binding var pair: Pair
    let isBlank: Bool
    let keyTitle: String
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: $pair.enabled).labelsHidden().toggleStyle(.checkbox)
                .frame(width: 30).opacity(isBlank ? 0 : 1).disabled(isBlank)
            TextField(isBlank ? "Add \(keyTitle.lowercased())" : keyTitle, text: $pair.key)
                .padding(.horizontal, 8)
            Divider().frame(height: 18).opacity(0.6)
            TextField(isBlank ? "" : "Value", text: $pair.value)
                .padding(.horizontal, 8)
            Button(action: delete) {
                Image(systemName: "minus.circle.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 28)
            .opacity(!isBlank && hovering ? 1 : 0)
            .disabled(isBlank)
            .help("Remove")
        }
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(pair.enabled ? .primary : .tertiary)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear)))
        .onHover { hovering = $0 }
    }
}

struct BodyEditor: View {
    @ObservedObject var model: Store
    @Binding var request: APIRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Body", selection: $request.bodyKind) {
                    ForEach(BodyKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if request.bodyKind == .json {
                    Button("Format") { model.formatBody() }
                        .controlSize(.small)
                        .disabled(!model.canFormatBody)
                        .help("Re-indent the JSON (\u{2303}I)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            switch request.bodyKind {
            case .none:
                ContentUnavailableView("No Body", systemImage: "doc", description: Text("Pick JSON, Form or Raw to send a body with this request."))
            case .json:
                CodeEditor(text: $request.body, json: true)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                Divider().opacity(0.6)
                JSONStatus(text: request.body)
            case .raw:
                CodeEditor(text: $request.body)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            case .form:
                PairTable(pairs: $request.form, keyTitle: "Field", valueTitle: "Value", hint: "Sent as application/x-www-form-urlencoded.")
            }
        }
    }
}

struct JSONStatus: View {
    let text: String

    var body: some View {
        let error = JSONFormat.validate(text)
        HStack(spacing: 6) {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                Text("Empty body").foregroundStyle(.secondary)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Valid JSON").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Response

struct ResponsePane: View {
    @ObservedObject var model: Store

    var body: some View {
        VStack(spacing: 0) {
            switch model.currentResponse {
            case .idle:
                if let e = model.currentHistory, let status = e.status {
                    placeholder("clock.arrow.circlepath", "Sent \(e.date.formatted(date: .abbreviated, time: .shortened))",
                                "It returned \(status) \(Format.reason(status)) in \(Format.duration(e.duration)). Send it again to see the body.")
                } else {
                    placeholder("paperplane", "Ready to Send", "Press \u{2318}\u{21A9} to send the request. The response shows up here.")
                }
            case .loading:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.regular)
                    Text("Waiting for the server\u{2026}").foregroundStyle(.secondary)
                    Button("Cancel") { model.cancel() }.keyboardShortcut(".", modifiers: .command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder("exclamationmark.triangle", "Request Failed", message)
            case .done(let r):
                ResponseView(model: model, result: r)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func placeholder(_ symbol: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 38, weight: .light)).foregroundStyle(Theme.gradient)
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 300)
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ResponseView: View {
    @ObservedObject var model: Store
    let result: HTTPResult

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatusPill(status: result.status)
                Metric(symbol: "timer", value: Format.duration(result.duration))
                Metric(symbol: "arrow.down.circle", value: Format.size(result.body.count))
                Spacer(minLength: 4)
                if let saved = model.savedResponse {
                    Button { revealInFinder([saved]) } label: { Label("Reveal", systemImage: "folder") }
                        .controlSize(.small)
                        .help("Show the saved response in Finder")
                        .transition(.opacity)
                }
                Button { model.copyBody() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy the body")
                Button { model.saveResponse() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless).help("Save the response (\u{2318}S)")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            Divider().opacity(0.6)
            HStack {
                TabBar(tabs: [(ResponseTab.pretty, "Pretty", nil), (.raw, "Raw", nil), (.headers, "Headers", result.headers.count)],
                       selection: $model.responseTab)
                Spacer()
                Text(result.contentType.split(separator: ";").first.map(String.init) ?? "")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            switch model.responseTab {
            case .pretty, .raw: bodyView
            case .headers: HeadersList(headers: result.headers)
            }
        }
    }

    @ViewBuilder private var bodyView: some View {
        if result.body.isEmpty {
            ContentUnavailableView("Empty Body", systemImage: "doc", description: Text("The server sent no content."))
        } else if let text = result.text {
            if model.responseTab == .pretty, result.isJSON, let pretty = JSONFormat.pretty(text) {
                CodeViewer(content: Theme.highlighted(pretty))
            } else {
                CodeViewer(content: Theme.plain(text))
            }
        } else {
            ContentUnavailableView("Binary Data", systemImage: "doc.zipper",
                                   description: Text("\(Format.size(result.body.count)) of \(result.contentType.isEmpty ? "binary data" : result.contentType). Save it to open it in another app."))
        }
    }
}

struct StatusPill: View {
    let status: Int

    var body: some View {
        let color = Theme.color(status: status)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(status)").monospacedDigit()
            Text(Format.reason(status)).fontWeight(.medium)
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
        .contentTransition(.numericText())
    }
}

struct Metric: View {
    let symbol: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(.tertiary)
            Text(value).monospacedDigit().contentTransition(.numericText())
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
    }
}

struct HeadersList: View {
    let headers: [Header]

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach(headers, id: \.self) { h in
                    GridRow {
                        Text(h.name).foregroundStyle(Color(nsColor: Theme.keyColor)).fontWeight(.medium)
                        Text(h.value).foregroundStyle(.primary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .padding(14)
        }
    }
}

// MARK: - Text views

/// A plain-text code editor: monospaced, no smart quotes or dashes, with undo.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var json = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isRichText = false
        tv.font = Theme.mono
        tv.textColor = .labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.string = text
        tv.delegate = context.coordinator
        scroll.drawsBackground = false
        colour(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = scroll.documentView as! NSTextView
        if tv.string != text {
            let selection = tv.selectedRanges
            tv.string = text
            tv.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
        colour(tv)
    }

    /// Syntax colour for JSON bodies, applied as attributes so typing and undo are untouched.
    func colour(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: Theme.mono, .foregroundColor: NSColor.labelColor], range: full)
        if json, storage.length < 200_000 {
            let coloured = Theme.highlighted(tv.string)
            coloured.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(coloured.length, storage.length))) { value, range, _ in
                if let value { storage.addAttribute(.foregroundColor, value: value, range: range) }
            }
        }
        storage.endEditing()
        tv.typingAttributes = [.font: Theme.mono, .foregroundColor: NSColor.labelColor]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.colour(tv)
        }
    }
}

/// A read-only, selectable text view for response bodies; fast with long text.
struct CodeViewer: NSViewRepresentable {
    let content: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.textStorage?.setAttributedString(content)
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if tv.textStorage?.isEqual(to: content) == false {
            tv.textStorage?.setAttributedString(content)
            tv.scroll(.zero)
        }
    }
}

// MARK: - Environments

struct EnvironmentsSheet: View {
    @ObservedObject var model: Store
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selected) {
                        ForEach(model.workspace.environments) { env in
                            HStack {
                                Text(env.name)
                                Spacer()
                                if env.id == model.workspace.activeEnvironment {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.top).font(.system(size: 11, weight: .bold))
                                }
                            }
                            .tag(env.id)
                        }
                    }
                    .listStyle(.sidebar)
                    Divider()
                    HStack(spacing: 4) {
                        Button { add() } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
                            .help("Add an environment")
                        Button { remove() } label: { Image(systemName: "minus").frame(width: 20, height: 18) }
                            .disabled(selected == nil)
                            .help("Delete the selected environment")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 190)
                Divider()
                if let i = model.workspace.environments.firstIndex(where: { $0.id == selected }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Name", text: $model.workspace.environments[i].name)
                                .textFieldStyle(.plain)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                            Spacer()
                            Button(model.workspace.activeEnvironment == selected ? "Active" : "Use This Environment") {
                                model.workspace.activeEnvironment = selected
                            }
                            .disabled(model.workspace.activeEnvironment == selected)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        PairTable(pairs: $model.workspace.environments[i].variables, keyTitle: "Variable", valueTitle: "Value",
                                  hint: "Write {{variable}} in a URL, param, header or body to use its value.")
                    }
                } else {
                    ContentUnavailableView("No Environment", systemImage: "globe",
                                           description: Text("Add one with + to keep values like {{base}} or {{token}} in one place."))
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 660, height: 420)
        .onAppear { selected = model.workspace.activeEnvironment ?? model.workspace.environments.first?.id }
    }

    private func add() {
        let env = RequestEnvironment(name: "New Environment", variables: [Pair(key: "base", value: "http://localhost:3000")])
        model.workspace.environments.append(env)
        if model.workspace.activeEnvironment == nil { model.workspace.activeEnvironment = env.id }
        selected = env.id
    }

    private func remove() {
        guard let id = selected else { return }
        model.workspace.environments.removeAll { $0.id == id }
        if model.workspace.activeEnvironment == id { model.workspace.activeEnvironment = nil }
        selected = model.workspace.environments.first?.id
    }
}
