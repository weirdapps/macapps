import AppKit
import Kit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BinderModel
    @Environment(\.undoManager) private var undoManager
    @State private var targeted = false

    var body: some View {
        NavigationSplitView {
            SourceList(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            Group {
                if model.pages.isEmpty {
                    DropZone(symbol: "doc.on.doc", title: model.sources.isEmpty ? "Drop PDFs or images" : "No pages left",
                             message: model.sources.isEmpty
                                ? "Every page appears here to reorder, rotate and delete. Then export one PDF or split it into files."
                                : "Undo to bring pages back, or drop more files.",
                             button: "Choose Files…", tint: Theme.top, isTargeted: targeted) { model.openPanel() }
                        .dropDestination(for: URL.self) { urls, _ in
                            model.add(urls)
                            return true
                        } isTargeted: { targeted = $0 }
                } else {
                    PageGrid(model: model)
                }
            }
            .frame(minWidth: 460)
            .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(model: model) }
        }
        .navigationTitle("Binder")
        .navigationSubtitle(model.pages.isEmpty ? "" : "\(model.pages.count) page\(model.pages.count == 1 ? "" : "s")")
        .toolbar { Toolbar(model: model) }
        .sheet(isPresented: $model.showingSplit) { SplitSheet(model: model) }
        .alert(model.errorTitle, isPresented: Binding(get: { model.errorMessage != nil },
                                                                   set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, value in model.undoManager = value }
        .frame(minWidth: 720, minHeight: 460)
    }
}

// MARK: - Toolbar

struct Toolbar: ToolbarContent {
    @ObservedObject var model: BinderModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.openPanel() } label: { Label("Add Files", systemImage: "plus") }
                .help("Add PDFs or images (⌘O)")
        }
        ToolbarItemGroup {
            Button { model.rotate(-90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                .help("Rotate left (⌘L)").disabled(model.pages.isEmpty)
            Button { model.rotate(90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                .help("Rotate right (⌘R)").disabled(model.pages.isEmpty)
            Button { model.delete() } label: { Label("Delete", systemImage: "trash") }
                .help("Delete the selected pages (⌫)")
                .disabled(!model.hasSelection)
        }
        ToolbarItem {
            Button { model.showingSplit = true } label: { Label("Split", systemImage: "scissors") }
                .help("Split into several PDFs (⇧⌘S)")
                .disabled(model.pages.isEmpty || model.isBusy)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.exportPanel() } label: { Label("Export PDF", systemImage: "square.and.arrow.up") }
                .help("Export every page as one PDF (⌘S)")
                .disabled(model.pages.isEmpty || model.isBusy)
        }
    }
}

// MARK: - Sidebar

struct SourceList: View {
    @ObservedObject var model: BinderModel

    var body: some View {
        List {
            Section("Files") {
                ForEach(model.sources) { source in
                    SourceRow(source: source, left: model.pagesLeft(in: source))
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(source: source.id) }
                        .contextMenu {
                            Button("Select Its Pages") { model.select(source: source.id) }
                            Button("Restore Deleted Pages") { model.restorePages(of: source) }
                                .disabled(model.pagesLeft(in: source) == source.pageCount)
                            if let url = source.url {
                                Button("Show in Finder") { revealInFinder([url]) }
                            }
                            Divider()
                            Button("Remove from Binder") { model.removeSource(source.id) }
                        }
                        .help("Click to select this file's pages")
                }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in model.add(await PageDrop.urls(from: providers)) }
            return true
        }
        .overlay {
            if model.sources.isEmpty {
                Text("Files you add are listed here, each with its own colour.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
            }
        }
    }
}

struct SourceRow: View {
    let source: Source
    let left: Int

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.tag(source.tint).gradient)
                Image(systemName: source.isImage ? "photo" : "doc.text")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        let pages = left == source.pageCount
            ? "\(left) page\(left == 1 ? "" : "s")"
            : "\(left) of \(source.pageCount) pages"
        return "\(pages) · \(Binder.formatBytes(source.bytes))"
    }
}

// MARK: - Grid

struct PageGrid: View {
    @ObservedObject var model: BinderModel
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 0

    private enum Layout {
        static let gutter: CGFloat = 22
        static let spacing: CGFloat = 12
    }

    /// How many tiles fit in a row, the way the adaptive grid lays them out; up and down arrows step by this.
    private var columns: Int {
        let minimum = model.tileSize + 20
        return max(1, Int((width - 2 * Layout.gutter + Layout.spacing) / (minimum + Layout.spacing)))
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.tileSize + 20, maximum: model.tileSize + 50),
                                         spacing: Layout.spacing, alignment: .top)],
                      spacing: 18) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { position, page in
                    PageTile(model: model, page: page, position: position + 1) { focused = true }
                }
            }
            .padding(.horizontal, Layout.gutter)
            .padding(.vertical, 20)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background {
            Color(nsColor: .underPageBackgroundColor).opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { model.selectNone(); focused = true }
        }
        .onDrop(of: [.fileURL, .plainText], delegate: PageDrop(model: model, target: nil))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.delete) { model.delete(); return .handled }
        .onKeyPress(.deleteForward) { model.delete(); return .handled }
        .onKeyPress(.escape) { model.selectNone(); return .handled }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let step = press.key == .leftArrow ? -1 : 1
            if press.modifiers.contains(.command) { model.nudge(step) } else { model.step(step, extend: press.modifiers.contains(.shift)) }
            return .handled
        }
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            model.step(press.key == .upArrow ? -columns : columns, extend: press.modifiers.contains(.shift))
            return .handled
        }
    }
}

struct PageTile: View {
    @ObservedObject var model: BinderModel
    let page: PageItem
    let position: Int
    /// Gives the grid keyboard focus, so arrows and Delete work after a click.
    var focus: () -> Void = {}
    @State private var hovering = false

    private var source: Source? { model.source(page.sourceID) }
    private var selected: Bool { model.selection.contains(page.id) }
    private var showsHover: Bool { hovering || model.demoHover == page.id }
    private var box: CGSize { CGSize(width: model.tileSize, height: model.tileSize * 1.3) }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Theme.top.opacity(0.09)) : (showsHover ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(Color.clear)))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                    .opacity(selected ? 1 : 0)
                thumbnail
                    .padding(10)
            }
            .frame(width: box.width + 20, height: box.height + 20)
            .overlay(alignment: .topTrailing) {
                if showsHover && model.dragging.isEmpty { tileButtons.padding(6).transition(.opacity.combined(with: .scale(0.9))) }
            }
            .overlay(alignment: .leading) {
                if model.dropTarget == page.id {
                    Capsule().fill(Theme.accent).frame(width: 4).padding(.vertical, 8).offset(x: -9)
                        .transition(.opacity)
                }
            }
            caption
        }
        .contentShape(Rectangle())
        .onHover { inside in
            guard !Desktop.isSnapshot else { return }
            hovering = inside
            // Hover events only arrive outside a drag, so a drag still marked here was cancelled elsewhere.
            if inside, !model.dragging.isEmpty, NSEvent.pressedMouseButtons == 0 { model.endDrag() }
        }
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.18), value: model.dropTarget)
        .onTapGesture {
            model.click(page.id, modifiers: NSEvent.modifierFlags)
            focus()
        }
        .onDrag {
            _ = model.beginDrag(page.id)
            return NSItemProvider(object: (model.dragPayload ?? "") as NSString)
        } preview: {
            DragPreview(count: model.dragging.count, image: model.thumbnails[page.thumbnailKey])
        }
        .onDrop(of: [.fileURL, .plainText], delegate: PageDrop(model: model, target: page.id))
        .contextMenu {
            Button("Rotate Left") { model.rotate(-90, ids: ids) }
            Button("Rotate Right") { model.rotate(90, ids: ids) }
            Divider()
            if let source { Button("Select Pages from \(source.name)") { model.select(source: source.id) } }
            Divider()
            Button(ids.count == 1 ? "Delete Page" : "Delete \(ids.count) Pages") { model.delete(ids: ids) }
        }
        .task(id: page.thumbnailKey) { model.requestThumbnail(page) }
    }

    /// What a hover button or the context menu acts on: the selection if this page is in it.
    private var ids: Set<UUID> { selected ? model.selection : [page.id] }

    private var thumbnail: some View {
        let base = source?.sizes[safe: page.index] ?? CGSize(width: 612, height: 792)
        let quarter = page.rotation % 180 != 0
        let aspect = quarter ? base.height / base.width : base.width / base.height
        let fitted = aspect > box.width / box.height
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        let unrotated = quarter ? CGSize(width: fitted.height, height: fitted.width) : fitted
        return ZStack {
            Rectangle().fill(.white)
            if let image = model.thumbnails[page.thumbnailKey] {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: unrotated.width, height: unrotated.height)
        .rotationEffect(.degrees(Double(page.rotation)))
        .frame(width: fitted.width, height: fitted.height)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.tag(source?.tint ?? 0)).frame(height: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
        .frame(width: box.width, height: box.height)
        .animation(.snappy(duration: 0.3), value: page.rotation)
    }

    private var caption: some View {
        HStack(spacing: 5) {
            Text("\(position)")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 7).padding(.vertical, 1.5)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear)))
            if let source {
                HStack(spacing: 4) {
                    Circle().fill(Theme.tag(source.tint)).frame(width: 7, height: 7)
                    Text(source.isImage ? "Image" : "Page \(page.index + 1)")
                        .lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: box.width + 20)
        .help(source.map { "\($0.name), page \(page.index + 1) of \($0.pageCount)" } ?? "")
    }

    private var tileButtons: some View {
        HStack(spacing: 2) {
            TileButton(symbol: "rotate.left", help: "Rotate left") { model.rotate(-90, ids: ids) }
            TileButton(symbol: "rotate.right", help: "Rotate right") { model.rotate(90, ids: ids) }
            TileButton(symbol: "trash", help: "Delete") { model.delete(ids: ids) }
        }
        .padding(3)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }
}

struct TileButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct DragPreview: View {
    let count: Int
    let image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) } else { Rectangle().fill(.white) }
            }
            .frame(width: 80, height: 100)
            .background(.white)
            .shadow(radius: 3)
            if count > 1 {
                Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.top))
                    .offset(x: 8, y: -8)
            }
        }
        .padding(10)
    }
}

/// Drops on a tile insert before it; drops on the grid's background go to the end.
/// Pages dragged inside the window move; files from Finder are added at that place.
struct PageDrop: DropDelegate {
    let model: BinderModel
    let target: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL]) || !model.dragging.isEmpty
    }

    func dropEntered(info: DropInfo) { model.dropTarget = target }
    func dropExited(info: DropInfo) { if model.dropTarget == target { model.dropTarget = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.dragging.isEmpty ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        if !model.dragging.isEmpty && !info.hasItemsConforming(to: [.fileURL]) {
            // Move only when the text dropped is this drag's own, never text from another app.
            guard let provider = info.itemProviders(for: [.plainText]).first else { model.endDrag(); return false }
            let model = model, target = target
            Task { @MainActor in
                let text: String? = await withCheckedContinuation { done in
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in done.resume(returning: (value as? NSString).map { $0 as String }) }
                }
                model.dropPages(payload: text, before: target)
            }
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { model.endDrag(); return false }
        let index = target.flatMap { t in model.pages.firstIndex { $0.id == t } }
        model.endDrag()
        let model = model
        Task { @MainActor in
            let urls = await PageDrop.urls(from: providers)
            model.add(urls, at: index)
        }
        return true
    }

    nonisolated static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var out: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { done in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in done.resume(returning: url) }
            }
            if let url { out.append(url) }
        }
        return out
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: BinderModel

    var body: some View {
        HStack(spacing: 12) {
            if let job = model.job {
                ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                    .progressViewStyle(.linear).tint(Theme.top).frame(width: 160)
                Text("\(job.title) \(job.done) of \(job.total)").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { model.cancelJob() }.controlSize(.small)
            } else if let notice = model.notice {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.top)
                Text(notice.text).lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") { revealInFinder(notice.urls) }.controlSize(.small)
                Button { withAnimation(.snappy) { model.notice = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Dismiss")
            } else {
                summary
            }
            Spacer(minLength: 12)
            if !model.pages.isEmpty {
                Text("About \(Binder.formatBytes(model.estimatedBytes))")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .help("Estimated size of the exported PDF")
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: $model.tileSize, in: BinderModel.tileRange).controlSize(.mini).tint(Theme.top).frame(width: 90)
                    Image(systemName: "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .help("Thumbnail size (⌘= and ⌘-)")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .animation(.snappy, value: model.pages.count)
    }

    @ViewBuilder private var summary: some View {
        if model.pages.isEmpty {
            Text("PDF, PNG, JPEG, HEIC and TIFF files, or a folder of them").foregroundStyle(.secondary)
        } else {
            let files = Set(model.pages.map(\.sourceID)).count
            Text("\(model.pages.count) page\(model.pages.count == 1 ? "" : "s") from \(files) file\(files == 1 ? "" : "s")")
                .monospacedDigit().contentTransition(.numericText())
            if model.hasSelection {
                Text("\(model.selection.count) selected").monospacedDigit().foregroundStyle(Theme.top)
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - Split sheet

struct SplitSheet: View {
    @ObservedObject var model: BinderModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("splitMode") private var mode = SplitMode.everyPage
    @AppStorage("splitRanges") private var ranges = "1-3, 5"
    @State private var base = ""

    enum SplitMode: String, CaseIterable { case everyPage, ranges }

    private var parsed: Result<[[Int]], RangeError> {
        mode == .everyPage ? .success(model.pages.indices.map { [$0 + 1] }) : Ranges.parse(ranges, count: model.pages.count)
    }

    private var groups: [[Int]]? { try? parsed.get() }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "scissors").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Split into PDFs").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Page numbers follow the order in the window.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Form {
                Picker("Split", selection: $mode) {
                    Text("Every page as its own file").tag(SplitMode.everyPage)
                    Text("By page ranges").tag(SplitMode.ranges)
                }
                .pickerStyle(.radioGroup)
                TextField("Ranges", text: $ranges, prompt: Text("1-3, 5, 8-"))
                    .disabled(mode != .ranges)
                    .font(.system(.body, design: .monospaced))
                TextField("File names", text: $base, prompt: Text(model.suggestedName))
            }
            .formStyle(.columns)
            Group {
                switch parsed {
                case .success(let g):
                    Label(preview(g), systemImage: "doc.on.doc").foregroundStyle(.secondary)
                case .failure(let error):
                    Label(error.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .lineLimit(2)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder…") {
                    guard let groups else { return }
                    let name = fileName
                    dismiss()
                    DispatchQueue.main.async { model.splitPanel(groups, base: name) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.top)
                .disabled(groups == nil)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    /// The base name as it will be written, with characters Finder refuses replaced.
    private var fileName: String { Binder.safeFileName(base, fallback: model.suggestedName) }

    private func preview(_ groups: [[Int]]) -> String {
        let names = Binder.splitNames(groups, base: fileName, total: model.pages.count)
        let shown = names.prefix(2).map { $0 + ".pdf" }.joined(separator: ", ")
        return "Makes \(groups.count) PDF\(groups.count == 1 ? "" : "s"): \(shown)\(names.count > 2 ? " and \(names.count - 2) more" : "")"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
