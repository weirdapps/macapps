import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum Theme {
    static let light = Color(red: 0.95, green: 0.61, blue: 0.29)
    static let deep = Color(red: 0.69, green: 0.29, blue: 0.12)
    static let accent = LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let sideWidth: CGFloat = 264
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var model: HeftModel

    var body: some View {
        Group {
            switch model.phase {
            case .empty: EmptyStateView(model: model)
            case .scanning: ScanningView(model: model)
            case .ready:
                if let folder = model.current { ReadyView(model: model, folder: folder) } else { EmptyStateView(model: model) }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(model.root?.name ?? "Heft")
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true })
            else { return false }
            model.scan(url)
            return true
        } isTargeted: { model.isTargeted = $0 }
        .confirmationDialog("Move \u{201C}\(model.pendingTrash?.name ?? "")\u{201D} to the Trash?",
                            isPresented: Binding(get: { model.pendingTrash != nil }, set: { if !$0 { model.pendingTrash = nil } }),
                            presenting: model.pendingTrash) { node in
            Button("Move to Trash", role: .destructive) { model.confirmTrash(node) }
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
        } message: { node in
            Text("\(Bytes.format(node.size)) comes back when you empty the Trash.")
        }
        .alert("Could not move to the Trash", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { model.goUp() } label: { Label("Enclosing Folder", systemImage: "chevron.left") }
                .help("Go to the enclosing folder (\u{2318}\u{2191})")
                .disabled(!model.canGoUp)
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show as a treemap or as a list")
            .disabled(model.phase != .ready)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.chooseFolder() } label: { Label("Open Folder", systemImage: "folder.badge.plus") }
                .help("Choose a folder to scan (\u{2318}O)")
            Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Scan the folder again (\u{2318}R)")
                .disabled(!model.canRescan && !model.isDemo)
            Button { model.reveal() } label: { Label("Reveal in Finder", systemImage: "magnifyingglass") }
                .help("Reveal the selection in Finder (\u{21E7}\u{2318}R)")
                .disabled(model.phase != .ready)
            Button { model.requestTrash() } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move the selection to the Trash (\u{2318}\u{232B})")
                .disabled(!model.canTrash)
        }
    }
}

// MARK: - Empty and scanning

struct EmptyStateView: View {
    @ObservedObject var model: HeftModel

    var body: some View {
        VStack(spacing: 0) {
            DropZone(symbol: "square.split.2x2", title: "See what fills a folder",
                     message: "Drop a folder here or choose one. Heft adds up every file and shows where the space went.",
                     button: "Choose Folder\u{2026}", tint: Theme.deep, isTargeted: model.isTargeted) { model.chooseFolder() }
            HStack(spacing: 10) {
                Text("Or scan").font(.system(size: 12)).foregroundStyle(.secondary)
                quick("Home", "house", FileManager.default.homeDirectoryForCurrentUser)
                quick("Downloads", "arrow.down.circle", FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
                quick("Applications", "square.grid.3x3", URL(fileURLWithPath: "/Applications"))
            }
            .padding(.bottom, 26)
        }
    }

    private func quick(_ title: String, _ symbol: String, _ url: URL?) -> some View {
        Button { if let url { model.scan(url) } } label: { Label(title, systemImage: symbol) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

struct ScanningView: View {
    @ObservedObject var model: HeftModel

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            VStack(spacing: 6) {
                Text("Scanning \u{201C}\(model.scanName)\u{201D}").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(Bytes.format(model.scannedBytes))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: model.scannedBytes)
                Text("\(model.scannedFiles.formatted()) files")
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Text(model.scanPath)
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 460)
            }
            Button("Cancel") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

struct ReadyView: View {
    @ObservedObject var model: HeftModel
    let folder: Node

    var body: some View {
        VStack(spacing: 0) {
            Breadcrumbs(model: model, folder: folder)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch model.viewMode {
                    case .treemap: TreemapView(model: model, folder: folder).padding(10)
                    case .list: OutlineView(model: model, folder: folder)
                    }
                }
                .id(ObjectIdentifier(folder))
                .transition(.opacity)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SidePanel(model: model, folder: folder).frame(width: Theme.sideWidth)
            }
            Divider()
            StatusBar(model: model, folder: folder)
        }
    }
}

struct Breadcrumbs: View {
    @ObservedObject var model: HeftModel
    let folder: Node

    var body: some View {
        HStack(spacing: 2) {
            let chain = folder.lineage
            ForEach(Array(chain.enumerated()), id: \.offset) { i, node in
                if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary) }
                Crumb(node: node, isLast: i == chain.count - 1, isRoot: i == 0) {
                    withAnimation(.snappy) { model.zoom = node; model.selected = nil }
                }
            }
            Spacer(minLength: 12)
            Text("\(Bytes.format(folder.size)) in \(folder.count.formatted()) files")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
}

struct Crumb: View {
    let node: Node
    let isLast: Bool
    let isRoot: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isRoot ? "internaldrive" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isLast ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                Text(node.name).font(.system(size: 12, weight: isLast ? .semibold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary.opacity(hovering ? 0.7 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isLast ? .primary : .secondary)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(isLast ? node.name : "Go back to \u{201C}\(node.name)\u{201D}")
    }
}

// MARK: - Treemap

/// Layout memo, so hovering does not redo the squarifying.
final class TileCache {
    private var key: (ObjectIdentifier, CGSize, Int)?
    private(set) var tiles: [Tile] = []
    private(set) var version = 0

    func tiles(for folder: Node, size: CGSize, revision: Int) -> [Tile] {
        let k = (ObjectIdentifier(folder), size, revision)
        if let key, key.0 == k.0, key.1 == k.1, key.2 == k.2 { return tiles }
        key = k
        tiles = Treemap.layout(folder, in: CGRect(origin: .zero, size: size))
        version += 1
        return tiles
    }
}

struct TreemapView: View {
    @ObservedObject var model: HeftModel
    let folder: Node
    @State private var hover: CGPoint?
    @State private var cache = TileCache()

    init(model: HeftModel, folder: Node) {
        self.model = model
        self.folder = folder
        _hover = State(initialValue: model.demoHover)
    }

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(for: folder, size: geo.size, revision: model.revision)
            let hovered = hover.flatMap { Treemap.hit(tiles, $0) }
            ZStack(alignment: .topLeading) {
                TreemapCanvas(tiles: tiles, version: cache.version, selected: model.selected.map(ObjectIdentifier.init),
                              highlight: model.highlightKind)
                    .equatable()
                if let h = hovered {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(h.isFrame ? 0.08 : 0.2))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        .frame(width: h.rect.width, height: h.rect.height)
                        .offset(x: h.rect.minX, y: h.rect.minY)
                        .allowsHitTesting(false)
                }
                if let h = hovered, let p = hover {
                    // Beside the pointer, flipped left or up near the far edges.
                    let left = p.x > geo.size.width - 270, up = p.y > geo.size.height - 80
                    Color.clear.frame(width: 1, height: 1)
                        .overlay(alignment: Alignment(horizontal: left ? .trailing : .leading, vertical: up ? .bottom : .top)) {
                            HoverCard(tile: h, total: folder.size).fixedSize()
                        }
                        .offset(x: p.x + (left ? -12 : 14), y: p.y + (up ? -12 : 18))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !Desktop.isSnapshot else { return } // The website shot keeps its fixed pointer.
                switch phase {
                case .active(let p): hover = p
                case .ended: hover = nil
                }
            }
            .gesture(SpatialTapGesture(count: 2).onEnded { v in doubleClick(Treemap.hit(tiles, v.location)) })
            .simultaneousGesture(SpatialTapGesture().onEnded { v in click(Treemap.hit(tiles, v.location), at: v.location) })
            .contextMenu {
                if let node = hovered?.node {
                    NodeMenu(model: model, node: node)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func click(_ tile: Tile?, at point: CGPoint) {
        guard let tile else { model.select(nil); return }
        if tile.isFrame, let header = tile.header, header.contains(point), let node = tile.node {
            model.open(node)
            return
        }
        withAnimation(.snappy(duration: 0.18)) { model.select(tile.node) }
    }

    private func doubleClick(_ tile: Tile?) {
        guard let node = tile?.node else { return }
        if node.isFolder && !node.children.isEmpty { model.open(node) } else if let parent = node.parent, parent !== folder { model.open(parent) }
    }
}

/// Context menu items for one file or folder, shared by the treemap and the list.
struct NodeMenu: View {
    @ObservedObject var model: HeftModel
    let node: Node

    var body: some View {
        if node.isFolder && !node.children.isEmpty {
            Button("Open \u{201C}\(node.name)\u{201D}") { model.open(node) }
            Divider()
        }
        Button("Reveal in Finder") { model.reveal(node) }
        Button("Copy Path") { model.copyPath(node) }
        Divider()
        Button("Move to Trash\u{2026}") { model.requestTrash(node) }
    }
}

struct TreemapCanvas: View, Equatable {
    let tiles: [Tile]
    let version: Int
    let selected: ObjectIdentifier?
    let highlight: FileKind?

    static func == (a: Self, b: Self) -> Bool { a.version == b.version && a.selected == b.selected && a.highlight == b.highlight }

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.06)))
            var selectedRect: CGRect?
            for tile in tiles {
                if let n = tile.node, ObjectIdentifier(n) == selected { selectedRect = tile.rect }
                draw(tile, in: &ctx)
            }
            if let r = selectedRect {
                let path = Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4, style: .continuous)
                var glow = ctx
                glow.addFilter(.shadow(color: Theme.light.opacity(0.9), radius: 8))
                glow.stroke(path, with: .color(Theme.light), lineWidth: 3)
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 2.5, dy: 2.5), cornerRadius: 3, style: .continuous), with: .color(.white), lineWidth: 1.5)
            }
        }
    }

    private func draw(_ tile: Tile, in ctx: inout GraphicsContext) {
        let r = tile.rect
        if tile.isFrame {
            let path = Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5, style: .continuous)
            ctx.fill(path, with: .color(.primary.opacity(0.07 + 0.03 * Double(min(tile.depth, 3)))))
            if let header = tile.header, let node = tile.node {
                let font = Font.system(size: 10.5, weight: .semibold)
                let sizeText = ctx.resolve(Text(Bytes.format(node.size)).font(.system(size: 10)).foregroundStyle(.secondary))
                let sizeWidth = sizeText.measure(in: header.size).width
                let room = header.width - 14 - (sizeWidth + 8 < header.width * 0.5 ? sizeWidth + 8 : 0)
                let name = fitted(node.name, font: font, width: room, ctx: ctx)
                ctx.draw(Text(name).font(font).foregroundStyle(.primary.opacity(0.8)),
                         at: CGPoint(x: header.minX + 7, y: header.midY + 0.5), anchor: .leading)
                if sizeWidth + 8 < header.width * 0.5 {
                    ctx.draw(sizeText, at: CGPoint(x: header.maxX - 7, y: header.midY + 0.5), anchor: .trailing)
                }
            }
            return
        }
        let inset = r.insetBy(dx: min(1, r.width / 4), dy: min(1, r.height / 4))
        let radius = min(4, inset.width / 3, inset.height / 3)
        let path = Path(roundedRect: inset, cornerRadius: radius, style: .continuous)
        var c = ctx
        if let highlight, tile.fillKind != highlight { c.opacity = 0.22 }
        if let kind = tile.fillKind {
            c.fill(path, with: .linearGradient(Gradient(colors: [kind.top, kind.bottom]),
                                              startPoint: CGPoint(x: inset.minX, y: inset.minY), endPoint: CGPoint(x: inset.maxX, y: inset.maxY)))
            if tile.node?.isFolder == true {
                c.stroke(Path(roundedRect: inset.insetBy(dx: 1.5, dy: 1.5), cornerRadius: max(radius - 1, 0)), with: .color(.white.opacity(0.35)),
                         style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        } else {
            // Many small items: their main kind, faded, with fine stripes.
            let kind = tile.othersKind ?? .other
            c.fill(path, with: .color(kind.color.opacity(0.4)))
            var stripes = c
            stripes.clip(to: path)
            var lines = Path()
            var x = inset.minX - inset.height
            while x < inset.maxX {
                lines.move(to: CGPoint(x: x, y: inset.maxY))
                lines.addLine(to: CGPoint(x: x + inset.height, y: inset.minY))
                x += 5
            }
            stripes.stroke(lines, with: .color(.white.opacity(0.28)), lineWidth: 1)
        }
        guard inset.width >= 60, inset.height >= 28 else { return }
        let font = Font.system(size: 11, weight: .semibold)
        let name = fitted(tile.title, font: font, width: inset.width - 12, ctx: c)
        let ink: Color = tile.fillKind == nil ? .primary.opacity(0.7) : .white
        var label = c
        if tile.fillKind != nil { label.addFilter(.shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)) }
        label.draw(Text(name).font(font).foregroundStyle(ink), at: CGPoint(x: inset.minX + 6, y: inset.minY + 5), anchor: .topLeading)
        if inset.height >= 44 {
            label.draw(Text(Bytes.format(tile.bytes)).font(.system(size: 10, weight: .medium)).foregroundStyle(ink.opacity(0.8)),
                       at: CGPoint(x: inset.minX + 6, y: inset.minY + 20), anchor: .topLeading)
        }
    }

    /// `text`, cut with an ellipsis to fit `width`.
    private func fitted(_ text: String, font: Font, width: CGFloat, ctx: GraphicsContext) -> String {
        func w(_ s: String) -> CGFloat { ctx.resolve(Text(s).font(font)).measure(in: CGSize(width: 10_000, height: 100)).width }
        if width <= 8 { return "" }
        if w(text) <= width { return text }
        var lo = 0, hi = text.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if w(String(text.prefix(mid)) + "\u{2026}") <= width { lo = mid } else { hi = mid - 1 }
        }
        return lo == 0 ? "" : String(text.prefix(lo)) + "\u{2026}"
    }
}

struct HoverCard: View {
    let tile: Tile
    let total: Int64

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(tile.fillKind.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.quaternary))
                .frame(width: 10, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(maxWidth: 210, alignment: .leading)
                HStack(spacing: 6) {
                    Text(Bytes.format(tile.bytes)).monospacedDigit()
                    Text("\u{00B7}")
                    Text(share(tile.bytes, of: total))
                    if let n = tile.node, n.isFolder { Text("\u{00B7}"); Text("\(n.count.formatted()) files") }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

func share(_ part: Int64, of whole: Int64) -> String {
    guard whole > 0 else { return "0%" }
    let p = Double(part) / Double(whole) * 100
    return p < 0.1 ? "<0.1%" : p < 10 ? String(format: "%.1f%%", p) : String(format: "%.0f%%", p)
}

// MARK: - Outline list

struct OutlineRow: Identifiable {
    let node: Node
    let order: [KeyPathComparator<OutlineRow>]

    var id: ObjectIdentifier { ObjectIdentifier(node) }
    var name: String { node.name }
    var size: Int64 { node.size }
    var count: Int { node.count }
    var kindName: String { node.kindLabel }
    var children: [OutlineRow]? {
        guard node.isFolder, !node.children.isEmpty else { return nil }
        return node.children.map { OutlineRow(node: $0, order: order) }.sorted(using: order)
    }
}

@MainActor
enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: Node) -> NSImage {
        let ext = node.isFolder ? "/" : (node.name as NSString).pathExtension.lowercased()
        if let image = cache[ext] { return image }
        let type: UTType = node.isFolder ? .folder : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[ext] = image
        return image
    }
}

struct OutlineView: View {
    @ObservedObject var model: HeftModel
    let folder: Node
    @State private var order = [KeyPathComparator(\OutlineRow.size, order: .reverse)]

    var body: some View {
        let rows = folder.children.map { OutlineRow(node: $0, order: order) }.sorted(using: order)
        let selection = Binding<ObjectIdentifier?>(
            get: { model.selected.map(ObjectIdentifier.init) },
            set: { id in model.select(id.flatMap { folder.find($0) }) })
        Table(rows, children: \.children, selection: selection, sortOrder: $order) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    Image(nsImage: Icons.icon(for: row.node)).resizable().frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    if row.node.unreadable {
                        Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary).help("Heft could not read this folder")
                    }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("Size", value: \.size) { row in
                Text(Bytes.format(row.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 86, max: 120)
            TableColumn("Share") { row in
                ShareBar(fraction: folder.size > 0 ? Double(row.size) / Double(folder.size) : 0, kind: row.node.dominantKind)
            }
            .width(min: 80, ideal: 130, max: 200)
            TableColumn("Files", value: \.count) { row in
                Text(row.count.formatted()).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 100)
            TableColumn("Kind", value: \.kindName) { row in Text(row.kindName).foregroundStyle(.secondary) }
                .width(min: 60, ideal: 80, max: 120)
        }
        .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
            if let id = ids.first, let node = folder.find(id) { NodeMenu(model: model, node: node) }
        } primaryAction: { ids in
            if let id = ids.first, let node = folder.find(id) {
                if node.isFolder { model.open(node) } else { model.reveal(node) }
            }
        }
    }
}

struct ShareBar: View {
    let fraction: Double
    let kind: FileKind

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary.opacity(0.6))
                    Capsule().fill(LinearGradient(colors: [kind.top, kind.bottom], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(g.size.width * fraction, fraction > 0 ? 3 : 0))
                }
            }
            .frame(height: 6)
            Text(share(Int64(fraction * 10_000), of: 10_000))
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Side panel

struct SidePanel: View {
    @ObservedObject var model: HeftModel
    let folder: Node

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(Bytes.format(folder.size))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText())
                if let root = model.root, root !== folder {
                    Text("\(share(folder.size, of: root.size)) of \u{201C}\(root.name)\u{201D}")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("\(folder.count.formatted()) files").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            KindStrip(folder: folder, kinds: kinds)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)

            Text("BY KIND").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                .padding(.horizontal, 16).padding(.bottom, 4)
            VStack(spacing: 1) {
                ForEach(kinds) { kind in
                    KindRow(kind: kind, bytes: folder.kindSize(kind), total: folder.size, model: model)
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 10)
            Divider().opacity(0.6)
            SelectionCard(model: model)
                .padding(14)
        }
    }

    private var kinds: [FileKind] {
        FileKind.allCases.filter { folder.kindSize($0) > 0 }.sorted { folder.kindSize($0) > folder.kindSize($1) }
    }
}

/// All kinds as one stacked bar.
struct KindStrip: View {
    let folder: Node
    let kinds: [FileKind]

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1.5) {
                ForEach(kinds) { kind in
                    Rectangle().fill(LinearGradient(colors: [kind.top, kind.bottom], startPoint: .top, endPoint: .bottom))
                        .frame(width: max((g.size.width - 1.5 * CGFloat(kinds.count - 1)) * fraction(kind), 1.5))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
    }

    private func fraction(_ kind: FileKind) -> CGFloat {
        folder.size > 0 ? CGFloat(Double(folder.kindSize(kind)) / Double(folder.size)) : 0
    }
}

struct KindRow: View {
    let kind: FileKind
    let bytes: Int64
    let total: Int64
    @ObservedObject var model: HeftModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(LinearGradient(colors: [kind.top, kind.bottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: 10)
                Text(kind.title).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Bytes.format(bytes)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                Capsule().fill(kind.color.opacity(0.85))
                    .frame(width: max(g.size.width * (total > 0 ? Double(bytes) / Double(total) : 0), 2))
            }
            .frame(height: 3)
            .padding(.leading, 17)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.quaternary.opacity(hovering ? 0.6 : 0)))
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            withAnimation(.snappy(duration: 0.15)) { model.highlightKind = h ? kind : (model.highlightKind == kind ? nil : model.highlightKind) }
        }
        .help("\(share(bytes, of: total)) of this folder. Point here to light up these files in the treemap.")
    }
}

struct SelectionCard: View {
    @ObservedObject var model: HeftModel

    var body: some View {
        if let node = model.selected {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(nsImage: Icons.icon(for: node)).resizable().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                        Text(detail(node)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack(spacing: 8) {
                    Button { model.reveal() } label: { Label("Reveal", systemImage: "magnifyingglass") }
                    Button(role: .destructive) { model.requestTrash() } label: { Label("Trash", systemImage: "trash") }
                        .disabled(!model.canTrash)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.click.2").font(.system(size: 20)).foregroundStyle(.tertiary)
                Text("Click a block to select it. Double-click a folder to open it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
    }

    private func detail(_ node: Node) -> String {
        var parts = [Bytes.format(node.size), node.kindLabel]
        if node.isFolder { parts.append("\(node.count.formatted()) files") }
        return parts.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @ObservedObject var model: HeftModel
    let folder: Node

    var body: some View {
        HStack(spacing: 8) {
            if let s = model.selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                Text(path(of: s)).lineLimit(1).truncationMode(.head)
            } else {
                Text("Hover a block for its size. Click a folder\u{2019}s title to open it.").foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if model.skipped > 0 {
                Label("\(model.skipped) \(model.skipped == 1 ? "folder" : "folders") could not be read", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .help("Heft skips folders macOS does not let it read. Their contents are not counted.")
            }
            Text("Scanned in \(String(format: "%.1f", model.duration)) s").foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(height: 26)
    }

    private func path(of node: Node) -> String {
        node.lineage.map(\.name).joined(separator: " \u{203A} ")
    }
}
