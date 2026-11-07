import AppKit
import Kit
import SwiftUI

/// A window: one document (or none yet), restored with its file on relaunch.
struct ViewerWindow: View {
    @Binding var url: URL?
    @StateObject private var model = ViewerModel()
    @Environment(\.openWindow) private var openWindow

    /// Reopens the file this window showed before the app quit, unless something else is already loading.
    private func restore() {
        if let url, model.isEmpty { model.open(url) }
    }

    var body: some View {
        ContentView(model: model)
            .navigationTitle(model.name)
            .navigationSubtitle(model.subtitle)
            .modifier(DocumentProxy(url: model.url))
            .focusedSceneObject(model)
            .background(WindowReader { model.window = $0 })
            // Files from Finder and Open With arrive here: shown in this window when it is empty, else in a new one.
            .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
            .onOpenURL { opened in
                restore()
                Router.shared.open([opened], preferring: model)
            }
            .onAppear {
                model.onOpenURL = { url = $0 }
                restore()
                Router.shared.register(model, openWindow: openWindow)
            }
    }
}

/// Hands the hosting NSWindow to the model, so the router can bring it forward.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

private struct DocumentProxy: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
        if let url { content.navigationDocument(url) } else { content }
    }
}

struct ContentView: View {
    @ObservedObject var model: ViewerModel
    @State private var dropTargeted = false

    var body: some View {
        Group {
            switch model.phase {
            case .empty: EmptyState(model: model, targeted: dropTargeted)
            case .loading: LoadingView(model: model)
            case .failed(let title, let error, let detail): FailureView(model: model, title: title, error: error, detail: detail)
            case .loaded: LoadedView(model: model)
            }
        }
        .frame(minWidth: 720, minHeight: 440)
        .background(Color(nsColor: .textBackgroundColor))
        .tint(Theme.accent)
        .toolbar { ViewerToolbar(model: model) }
        .modifier(SearchField(model: model))
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            model.open(first)
            Router.shared.open(Array(urls.dropFirst()))
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

/// The toolbar search field, focused by Edit > Find.
private struct SearchField: ViewModifier {
    @ObservedObject var model: ViewerModel
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let field = content
            .searchable(text: $model.query, placement: .toolbar, prompt: model.mode == .tree ? "Search keys and values" : "Search text")
            .onSubmit(of: .search) { model.findNext() }
        if #available(macOS 15.0, *) {
            field
                .searchFocused($focused)
                .onChange(of: model.focusSearch) { focused = true }
        } else {
            field
        }
    }
}

struct ViewerToolbar: ToolbarContent {
    @ObservedObject var model: ViewerModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $model.mode) {
                Label("Tree", systemImage: "list.bullet.indent").tag(ViewerModel.Mode.tree)
                Label("Text", systemImage: "text.alignleft").tag(ViewerModel.Mode.text)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the tree or the pretty printed text")
            .disabled(!model.hasDocument)
        }
        ToolbarItem(placement: .navigation) {
            Menu {
                Button("Expand All") { model.expandAll() }
                Button("Collapse All") { model.collapseAll() }
                Divider()
                ForEach(1...5, id: \.self) { level in
                    Button("Expand to Level \(level)") { model.expand(toLevel: level) }
                }
            } label: {
                Label("Expand", systemImage: "arrow.up.and.down.text.horizontal")
            } primaryAction: {
                model.expandAll()
            }
            .help("Expand all; hold for levels")
            .disabled(!model.hasDocument || model.mode != .tree)
        }
        ToolbarItem(placement: .navigation) {
            Button { model.collapseAll() } label: { Label("Collapse All", systemImage: "rectangle.compress.vertical") }
                .help("Collapse all")
                .disabled(!model.hasDocument || model.mode != .tree)
        }
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: 6) {
                if model.hasDocument, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Group {
                        if model.searching {
                            ProgressView().controlSize(.small)
                        } else if model.matchCount == 0 {
                            Text("No matches")
                        } else {
                            Text("\((model.matchIndex ?? 0) + 1) of \(model.matchCount.formatted())")
                                .contentTransition(.numericText())
                        }
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
                ControlGroup {
                    Button { model.findPrevious() } label: { Label("Previous", systemImage: "chevron.up") }
                        .help("Previous match (⇧⌘G)")
                    Button { model.findNext() } label: { Label("Next", systemImage: "chevron.down") }
                        .help("Next match (⌘G)")
                }
                .disabled(model.matchCount == 0)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation(.snappy) { model.showInspector.toggle() } } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help(model.showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
            .disabled(!model.hasDocument)
        }
    }
}

// MARK: - States

private struct EmptyState: View {
    @ObservedObject var model: ViewerModel
    let targeted: Bool
    @State private var recents = Recents.all

    var body: some View {
        DropZone(symbol: "curlybraces.square", title: "Open a JSON file",
                 message: "Drop a .json or .jsonl file here, even one of hundreds of megabytes.",
                 button: "Open…", tint: Theme.accent, isTargeted: targeted) {
            Router.shared.showOpenPanel(preferring: model)
        }
        .overlay(alignment: .top) {
            // Sits just under the drop zone's Open button, which is centred in the window.
            GeometryReader { geo in
                VStack(spacing: 18) {
                    Button("Paste JSON from the Clipboard") { model.pasteFromClipboard() }
                        .buttonStyle(.link)
                        .font(.system(size: 12.5))
                    if !recents.isEmpty {
                        VStack(spacing: 2) {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            ForEach(recents.prefix(4), id: \.self) { url in
                                RecentRow(url: url) { model.open(url) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .offset(y: geo.size.height / 2 + 88)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentsChanged)) { _ in recents = Recents.all }
    }
}

private struct RecentRow: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(Theme.accent)
                Text(url.lastPathComponent).foregroundStyle(.primary)
                Text(url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: 380)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct LoadingView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "curlybraces")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.gradient)
                .symbolEffect(.pulse)
            Text("Reading \(model.loadingName)").font(.system(size: 15, weight: .semibold, design: .rounded))
            ProgressView(value: model.progress).frame(width: 260).tint(Theme.accent)
            Text(model.progress.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Button("Cancel") { model.cancelLoading() }.keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    @ObservedObject var model: ViewerModel
    let title: String
    let error: ParseError?
    let detail: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange.gradient)
            VStack(spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold, design: .rounded))
                if let error {
                    Text("\(error.location): \(error.message)").foregroundStyle(.secondary)
                } else {
                    Text(detail).foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)
            if let error, !error.excerpt.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(error.line)").foregroundStyle(.tertiary)
                        Text(error.excerpt).foregroundStyle(.primary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(error.line)").hidden()
                        Text(String(repeating: " ", count: error.caret) + "^").foregroundStyle(.red).bold()
                    }
                }
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize()
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.4)))
            }
            HStack(spacing: 10) {
                Button("Open Another File…") { Router.shared.showOpenPanel(preferring: nil) }
                Button("Paste from Clipboard") { model.pasteFromClipboard() }
            }
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Document

private struct LoadedView: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Group {
                    if model.mode == .tree {
                        TreeOutline(model: model)
                    } else {
                        TextPane(model: model)
                            .overlay { if model.pretty == nil { ProgressView().controlSize(.small) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) { NoticeToast(model: model) }
                Divider()
                PathBar(model: model)
            }
            if model.showInspector {
                Divider()
                Inspector(model: model)
                    .frame(width: 284)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

private struct NoticeToast: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        if let notice = model.notice {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(notice.message).font(.system(size: 12, weight: .medium))
                if let url = notice.reveal {
                    Button("Show in Finder") { revealInFinder([url]) }.buttonStyle(.link).font(.system(size: 12))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .padding(.bottom, 14)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The selection's path as clickable crumbs, with copy buttons.
private struct PathBar: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        HStack(spacing: 10) {
            if let tree = model.tree {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) {
                        let chain = tree.ancestors(model.focusID) + [model.focusID]
                        ForEach(Array(chain.enumerated()), id: \.offset) { index, id in
                            if index > 0 {
                                Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Crumb(title: crumbTitle(tree, id), kind: tree.kind(id), current: id == model.focusID) {
                                model.select(id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollBounceBehavior(.basedOnSize)
                if model.mode == .text, let pretty = model.pretty {
                    if pretty.truncated {
                        Text("Showing the first 4 MB; select a smaller node to see it all")
                            .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).fixedSize()
                    } else if pretty.node != 0 {
                        Text("The file is too large to show whole; showing \(model.jsonPath(pretty.node))")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button { model.copyJSONPath() } label: { Label("JSONPath", systemImage: "doc.on.doc") }
                    .help("Copy the JSONPath (⌥⌘C)")
                Button { model.copyJQPath() } label: { Label("jq", systemImage: "terminal") }
                    .help("Copy the jq path (⌥⇧⌘C)")
                    .padding(.trailing, 10)
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11.5))
        .frame(height: 30)
        .background(.bar)
    }

    private func crumbTitle(_ tree: JSONTree, _ id: Int32) -> String {
        guard let parent = tree.parent(id) else { return "$" }
        return tree.kind(parent) == .object ? (tree.key(id) ?? "") : "[\(tree.position(id))]"
    }
}

private struct Crumb: View {
    let title: String
    let kind: JSONKind
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Circle().fill(TypeStyle.swiftUI(kind)).frame(width: 6, height: 6)
                Text(title).font(.system(size: 11.5, weight: current ? .semibold : .regular, design: .monospaced))
                    .foregroundStyle(current ? .primary : .secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.quaternary.opacity(hovering ? 0.7 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Inspector

private struct Inspector: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        if let tree = model.tree {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    SelectionSection(model: model, tree: tree, id: model.focusID)
                    Divider().opacity(0.6)
                    StatsSection(tree: tree)
                }
                .padding(18)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        }
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

struct TypeBadge: View {
    let kind: JSONKind
    var size: CGFloat = 1

    var body: some View {
        Text(kind.badge)
            .font(.system(size: 9.5 * size, weight: .bold, design: .monospaced))
            .foregroundStyle(TypeStyle.swiftUI(kind))
            .frame(width: 32 * size, height: 16 * size)
            .background(RoundedRectangle(cornerRadius: 4.5 * size, style: .continuous).fill(TypeStyle.swiftUI(kind).opacity(0.14)))
    }
}

private struct SelectionSection: View {
    @ObservedObject var model: ViewerModel
    let tree: JSONTree
    let id: Int32

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Selection")
            HStack(spacing: 10) {
                TypeBadge(kind: tree.kind(id), size: 1.25)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).truncationMode(.middle)
                    Text(kindLine).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Text(preview)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(tree.kind(id).isContainer ? AnyShapeStyle(.secondary) : AnyShapeStyle(TypeStyle.swiftUI(tree.kind(id))))
                .lineLimit(7)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.quaternary.opacity(0.35)))
            PathRow(title: "JSONPath", value: model.jsonPath(id)) { model.copyJSONPath(id) }
            PathRow(title: tree.isLines ? "jq (with -s)" : "jq", value: model.jqPath(id)) { model.copyJQPath(id) }
            Button { model.copyValue(id) } label: {
                Label("Copy Value", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle([Color(nsColor: rgb(0x3DB26E)), Color(nsColor: rgb(Theme.bottom))]))
            .padding(.top, 2)
            .help("Copy the value; objects and arrays copy as JSON (⇧⌘C)")
        }
    }

    private var title: String {
        guard let parent = tree.parent(id) else { return model.name }
        return tree.kind(parent) == .object ? (tree.key(id) ?? "") : "Item \(tree.position(id))"
    }

    private var kindLine: String {
        let kind = tree.kind(id)
        if kind.isContainer { return "\(kind.name), \(tree.summary(id))" }
        if kind == .string { return "String, \(tree.scalarText(id).count.formatted()) characters" }
        return kind.name
    }

    private var preview: String {
        let kind = tree.kind(id)
        if kind.isContainer {
            let r = tree.render(id, indent: nil, limit: 600)
            return String(decoding: r.bytes, as: UTF8.self) + (r.truncated ? "…" : "")
        }
        let text = tree.scalarText(id)
        return text.count > 2000 ? String(text.prefix(2000)) + "…" : (text.isEmpty ? " " : text)
    }
}

private struct PathRow: View {
    let title: String
    let value: String
    let copy: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copy) { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
                    .buttonStyle(.borderless)
                    .opacity(hovering ? 1 : 0.55)
                    .help("Copy \(title)")
            }
        }
        .onHover { hovering = $0 }
    }
}

private struct StatsSection: View {
    let tree: JSONTree

    var body: some View {
        let s = tree.stats
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Document")
            CompositionBar(stats: s)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(JSONKind.allCases, id: \.self) { kind in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(TypeStyle.swiftUI(kind)).frame(width: 7, height: 7)
                            Text(kind == .bool ? "Booleans" : kind.name + "s")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(s.count(kind).formatted()).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Max depth").foregroundStyle(.secondary)
                    Text(s.maxDepth.formatted()).monospacedDigit()
                }
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(s.bytes), countStyle: .file)).monospacedDigit()
                }
                GridRow {
                    Text("Parsed in").foregroundStyle(.secondary)
                    Text(s.seconds < 0.001 ? "under 1 ms" : s.seconds < 1 ? "\(Int((s.seconds * 1000).rounded())) ms" : String(format: "%.1f s", s.seconds)).monospacedDigit()
                }
            }
            .font(.system(size: 12))
        }
    }
}

/// A thin stacked bar of how the document's values split by type.
private struct CompositionBar: View {
    let stats: JSONStats

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(JSONKind.allCases.filter { stats.count($0) > 0 }, id: \.self) { kind in
                    Rectangle()
                        .fill(TypeStyle.swiftUI(kind).gradient)
                        .frame(width: max(3, (geo.size.width - 12) * CGFloat(stats.count(kind)) / CGFloat(max(1, stats.nodes))))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}
