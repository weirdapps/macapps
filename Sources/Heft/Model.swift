import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File kinds

enum FileKind: Int, CaseIterable, Identifiable {
    case video, images, audio, documents, code, archives, apps, other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .images: "Images"
        case .audio: "Audio"
        case .documents: "Documents"
        case .code: "Code and data"
        case .archives: "Archives"
        case .apps: "Apps"
        case .other: "Other"
        }
    }

    var short: String {
        switch self {
        case .code: "Code"
        case .apps: "App"
        default: title
        }
    }

    var hex: UInt32 {
        switch self {
        case .video: 0x8B5CF6
        case .images: 0x14B8A6
        case .audio: 0xEC4899
        case .documents: 0x3B82F6
        case .code: 0x22A95B
        case .archives: 0xE0A21A
        case .apps: 0xEF5A3C
        case .other: 0x8A94A6
        }
    }

    var color: Color { Color(nsColor: rgb(hex)) }
    var top: Color { Color(nsColor: rgb(hex).blended(withFraction: 0.22, of: .white) ?? rgb(hex)) }
    var bottom: Color { Color(nsColor: rgb(hex).blended(withFraction: 0.16, of: .black) ?? rgb(hex)) }

    /// Extensions UTType does not place where a person would expect.
    private static let overrides: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        for e in ["swift", "py", "js", "mjs", "cjs", "jsx", "tsx", "rb", "go", "rs", "c", "h", "cc", "cpp", "hpp", "m", "mm",
                  "java", "kt", "sh", "zsh", "json", "yml", "yaml", "toml", "html", "css", "scss", "sql", "csv", "tsv",
                  "plist", "xml", "lock", "map", "o", "a", "dylib", "sqlite", "db", "parquet", "ipynb"] { map[e] = .code }
        for e in ["zip", "gz", "tgz", "tar", "xz", "bz2", "7z", "rar", "zst", "dmg", "iso", "img", "pkg", "xip", "sparseimage",
                  "sparsebundle", "ipsw"] { map[e] = .archives }
        for e in ["heic", "heif", "raw", "cr3", "nef", "arw", "dng", "psd", "webp", "avif", "svg"] { map[e] = .images }
        for e in ["mov", "mp4", "m4v", "mkv", "avi", "webm", "braw"] { map[e] = .video }
        for e in ["mp3", "m4a", "wav", "aif", "aiff", "flac", "caf", "ogg", "opus"] { map[e] = .audio }
        for e in ["pdf", "pages", "key", "numbers", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "epub"] { map[e] = .documents }
        map["app"] = .apps
        return map
    }()

    static func classify(extension raw: String) -> FileKind {
        let ext = raw.lowercased()
        if ext.isEmpty { return .other }
        if let kind = overrides[ext] { return kind }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json) || type.conforms(to: .xml) { return .code }
        if type.conforms(to: .text) || type.conforms(to: .pdf) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet)
            || type.conforms(to: .compositeContent) { return .documents }
        return .other
    }
}

/// Thread safe memo of extension to kind, so a scan asks UTType once per extension.
final class KindCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: FileKind] = [:]

    func kind(of name: String) -> FileKind {
        let ext = (name as NSString).pathExtension
        lock.lock()
        if let k = map[ext] { lock.unlock(); return k }
        lock.unlock()
        let k = FileKind.classify(extension: ext)
        lock.lock(); map[ext] = k; lock.unlock()
        return k
    }
}

enum Bytes {
    static func format(_ bytes: Int64) -> String {
        bytes <= 0 ? "0 bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Tree

/// One file or folder. Paths are derived from the parent chain, so a million nodes stay light.
final class Node: Identifiable, @unchecked Sendable {
    let name: String
    let isFolder: Bool
    let kind: FileKind
    var size: Int64 = 0
    /// Files inside (1 for a file or an app bundle).
    var count = 0
    /// Largest first.
    var children: [Node] = []
    weak var parent: Node?
    /// Bytes per `FileKind`, folders only.
    var kindSizes: [Int64] = []
    var unreadable = false
    /// Set on the scanned root only.
    var rootURL: URL?

    init(name: String, isFolder: Bool, kind: FileKind, size: Int64 = 0) {
        self.name = name
        self.isFolder = isFolder
        self.kind = kind
        self.size = size
        self.count = isFolder ? 0 : 1
    }

    var url: URL {
        if let rootURL { return rootURL }
        guard let parent else { return URL(fileURLWithPath: name) }
        return parent.url.appendingPathComponent(name, isDirectory: isFolder)
    }

    /// From the scanned root down to this node.
    var lineage: [Node] {
        var out: [Node] = [self]
        var p = parent
        while let n = p { out.append(n); p = n.parent }
        return out.reversed()
    }

    func isDescendant(of other: Node) -> Bool {
        var p = parent
        while let n = p { if n === other { return true }; p = n.parent }
        return false
    }

    func kindSize(_ k: FileKind) -> Int64 {
        if isFolder { return kindSizes.isEmpty ? 0 : kindSizes[k.rawValue] }
        return k == kind ? size : 0
    }

    /// The kind holding most bytes: the colour of a folder drawn as one block.
    var dominantKind: FileKind {
        guard isFolder else { return kind }
        return FileKind.allCases.max { kindSize($0) < kindSize($1) } ?? .other
    }

    var kindLabel: String { isFolder ? "Folder" : kind.short }

    /// Sums sizes, counts and kinds from the children and sorts them largest first.
    func aggregate() {
        var sizes = [Int64](repeating: 0, count: FileKind.allCases.count)
        var total: Int64 = 0, files = 0
        for c in children {
            c.parent = self
            total += c.size
            files += c.count
            if c.isFolder {
                for k in 0..<sizes.count where !c.kindSizes.isEmpty { sizes[k] += c.kindSizes[k] }
            } else {
                sizes[c.kind.rawValue] += c.size
            }
        }
        children.sort { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        size = total
        count = files
        kindSizes = sizes
    }

    /// Removes this node from the tree (after it went to the Trash) and takes its bytes off every ancestor.
    func detach() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var p: Node? = parent
        while let n = p {
            n.size -= size
            n.count -= count
            if !n.kindSizes.isEmpty { for k in FileKind.allCases { n.kindSizes[k.rawValue] -= kindSize(k) } }
            p = n.parent
        }
        self.parent = nil
    }

    func find(_ id: ObjectIdentifier) -> Node? {
        if ObjectIdentifier(self) == id { return self }
        for c in children where c.isFolder || ObjectIdentifier(c) == id {
            if let hit = c.find(id) { return hit }
        }
        return nil
    }

    func child(named name: String) -> Node? { children.first { $0.name == name } }
}

// MARK: - Scanning

final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var files = 0
    private var bytes: Int64 = 0
    private var path = ""
    private var skipped = 0
    private var cancelled = false
    let kinds = KindCache()

    func add(files f: Int, bytes b: Int64, path p: String) {
        lock.lock(); files += f; bytes += b; path = p; lock.unlock()
    }

    func skip() { lock.lock(); skipped += 1; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var snapshot: (files: Int, bytes: Int64, path: String, skipped: Int) {
        lock.lock(); defer { lock.unlock() }
        return (files, bytes, path, skipped)
    }
}

enum Scanner {
    static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isVolumeKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    /// Walks `url` and returns its tree with allocated sizes, or nil when cancelled. Unreadable folders are kept, empty and flagged.
    static func scan(_ url: URL, progress: ScanProgress) -> Node? {
        let root = Node(name: FileManager.default.displayName(atPath: url.path), isFolder: true, kind: .other)
        root.rootURL = url
        scanFolder(root, at: url, depth: 0, progress: progress)
        return progress.isCancelled ? nil : root
    }

    private static func allocated(_ v: URLResourceValues) -> Int64 {
        Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    private static func scanFolder(_ node: Node, at url: URL, depth: Int, progress: ScanProgress) {
        if progress.isCancelled { return }
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            node.unreadable = true
            progress.skip()
            node.aggregate()
            return
        }
        let keySet = Set(keys)
        var kids: [Node] = []
        var folders: [(Node, URL)] = []
        var files = 0
        var bytes: Int64 = 0
        kids.reserveCapacity(items.count)
        for item in items {
            guard let v = try? item.resourceValues(forKeys: keySet) else { continue }
            let name = item.lastPathComponent
            if v.isDirectory == true && v.isSymbolicLink != true {
                if v.isVolume == true { continue } // Another volume mounted inside: not this folder's bytes.
                if v.isPackage == true && item.pathExtension.lowercased() == "app" {
                    let app = Node(name: name, isFolder: false, kind: .apps, size: treeSize(item, progress: progress))
                    kids.append(app)
                    files += 1
                    bytes += app.size
                } else {
                    let folder = Node(name: name, isFolder: true, kind: .other)
                    kids.append(folder)
                    folders.append((folder, item))
                }
            } else {
                let file = Node(name: name, isFolder: false, kind: progress.kinds.kind(of: name), size: allocated(v))
                kids.append(file)
                files += 1
                bytes += file.size
            }
        }
        progress.add(files: files, bytes: bytes, path: url.path)
        if depth < 2 && folders.count > 1 {
            let list = folders
            DispatchQueue.concurrentPerform(iterations: list.count) { i in
                scanFolder(list[i].0, at: list[i].1, depth: depth + 1, progress: progress)
            }
        } else {
            for (folder, u) in folders { scanFolder(folder, at: u, depth: depth + 1, progress: progress) }
        }
        node.children = kids
        node.aggregate()
    }

    /// Total allocated bytes of a bundle, without keeping its contents.
    private static func treeSize(_ url: URL, progress: ScanProgress) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            if progress.isCancelled { break }
            if let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) { total += allocated(v) }
        }
        return total
    }
}

// MARK: - Treemap layout

struct Tile {
    var rect: CGRect
    var node: Node?
    var depth: Int
    /// A folder drawn as a frame with its contents inside.
    var isFrame = false
    var header: CGRect?
    /// For the block that stands for many small items.
    var othersCount = 0
    var othersBytes: Int64 = 0
    /// The kind holding most of those small items' bytes.
    var othersKind: FileKind?

    var bytes: Int64 { node?.size ?? othersBytes }
    var title: String { node?.name ?? "\(othersCount.formatted()) smaller items" }
    var fillKind: FileKind? { node.map { $0.dominantKind } }
}

enum Treemap {
    static let headerHeight: CGFloat = 18
    static let minArea: CGFloat = 24

    /// Squarified treemap (Bruls, Huizing, van Wijk): rectangles for `values` (largest first) that tile `rect`, areas proportional.
    static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: CGRect(origin: rect.origin, size: .zero), count: values.count)
        let total = values.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { max($0, 0) * scale }
        let order = areas.indices.filter { areas[$0] > 0 }
        var free = rect
        var i = 0
        let n = order.count
        func worst(_ sum: Double, _ hi: Double, _ lo: Double, _ side: Double) -> Double {
            let s2 = side * side, sum2 = sum * sum
            return max(s2 * hi / sum2, sum2 / (s2 * lo))
        }
        while i < n {
            let side = Double(min(free.width, free.height))
            let first = areas[order[i]]
            var sum = first, hi = first, lo = first
            var current = worst(sum, hi, lo, side)
            var j = i + 1
            while j < n {
                let a = areas[order[j]]
                let next = worst(sum + a, max(hi, a), min(lo, a), side)
                if next > current { break }
                sum += a; hi = max(hi, a); lo = min(lo, a); current = next
                j += 1
            }
            // The last row takes whatever is left, so rounding never leaves a gap.
            let last = j == n
            if free.width >= free.height {
                let w = last ? free.width : CGFloat(sum / Double(free.height))
                var y = free.minY
                for k in order[i..<j] {
                    let h = CGFloat(areas[k] / sum) * free.height
                    result[k] = CGRect(x: free.minX, y: y, width: w, height: h)
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(free.width - w, 0), height: free.height)
            } else {
                let h = last ? free.height : CGFloat(sum / Double(free.width))
                var x = free.minX
                for k in order[i..<j] {
                    let w = CGFloat(areas[k] / sum) * free.width
                    result[k] = CGRect(x: x, y: free.minY, width: w, height: h)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(free.height - h, 0))
            }
            i = j
        }
        return result
    }

    /// Tiles for the contents of `folder`, parents before children, nested up to `maxDepth` folders deep.
    static func layout(_ folder: Node, in rect: CGRect, maxDepth: Int = 4) -> [Tile] {
        var tiles: [Tile] = []
        place(folder, in: rect, depth: 0, maxDepth: maxDepth, into: &tiles)
        return tiles
    }

    private static func place(_ folder: Node, in rect: CGRect, depth: Int, maxDepth: Int, into tiles: inout [Tile]) {
        guard folder.size > 0, rect.width > 1, rect.height > 1 else { return }
        let perByte = Double(rect.width * rect.height) / Double(folder.size)
        var shown: [Node] = []
        var restBytes: Int64 = 0, restCount = 0
        var restKinds = [Int64](repeating: 0, count: FileKind.allCases.count)
        for c in folder.children where c.size > 0 {
            if restCount == 0 && shown.count < 600 && CGFloat(Double(c.size) * perByte) >= minArea {
                shown.append(c)
            } else {
                restBytes += c.size
                restCount += 1
                for k in FileKind.allCases { restKinds[k.rawValue] += c.kindSize(k) }
            }
        }
        if restCount == 1, let single = folder.children.first(where: { c in c.size > 0 && !shown.contains { $0 === c } }) {
            shown.append(single)
            restBytes = 0
            restCount = 0
        }
        var values = shown.map { Double($0.size) }
        if restBytes > 0 { values.append(Double(restBytes)) }
        let rects = squarify(values, in: rect)
        for (k, r) in rects.enumerated() {
            guard r.width >= 0.5, r.height >= 0.5 else { continue }
            if k == shown.count {
                let kind = FileKind.allCases.max { restKinds[$0.rawValue] < restKinds[$1.rawValue] }
                tiles.append(Tile(rect: r, node: nil, depth: depth, othersCount: restCount, othersBytes: restBytes, othersKind: kind))
                continue
            }
            let node = shown[k]
            if node.isFolder && !node.children.isEmpty && depth < maxDepth && r.width >= 16 && r.height >= 16 {
                let header = r.width >= 54 && r.height >= 40
                var tile = Tile(rect: r, node: node, depth: depth, isFrame: true)
                var inner = r.insetBy(dx: 2, dy: 2)
                if header {
                    tile.header = CGRect(x: r.minX, y: r.minY, width: r.width, height: headerHeight)
                    inner = CGRect(x: inner.minX, y: r.minY + headerHeight, width: inner.width, height: max(inner.maxY - r.minY - headerHeight, 0))
                }
                tiles.append(tile)
                place(node, in: inner, depth: depth + 1, maxDepth: maxDepth, into: &tiles)
            } else {
                tiles.append(Tile(rect: r, node: node, depth: depth))
            }
        }
    }

    /// The deepest tile under `point`.
    static func hit(_ tiles: [Tile], _ point: CGPoint) -> Tile? {
        tiles.last { $0.rect.contains(point) }
    }
}

// MARK: - App model

enum ViewMode: String, CaseIterable, Identifiable {
    case treemap, list
    var id: String { rawValue }
    var title: String { self == .treemap ? "Treemap" : "List" }
    var symbol: String { self == .treemap ? "square.split.2x2" : "list.bullet.indent" }
}

@MainActor
final class HeftModel: ObservableObject {
    enum Phase { case empty, scanning, ready }

    @Published var phase: Phase = .empty
    /// The scanned folder.
    @Published var root: Node?
    /// The folder on screen.
    @Published var zoom: Node?
    @Published var selected: Node?
    /// Bumped when the tree changes in place (an item went to the Trash).
    @Published var revision = 0
    @Published var viewMode: ViewMode = .treemap {
        didSet { if !isDemo { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") } }
    }
    @Published var highlightKind: FileKind?
    @Published var pendingTrash: Node?
    @Published var errorMessage: String?
    @Published var isTargeted = false

    @Published var scanName = ""
    @Published var scannedFiles = 0
    @Published var scannedBytes: Int64 = 0
    @Published var scanPath = ""
    @Published private(set) var skipped = 0
    @Published private(set) var duration: TimeInterval = 0

    let isDemo: Bool
    /// A pointer position the snapshot shows hovering.
    var demoHover: CGPoint?
    private var progress: ScanProgress?
    private var timer: Timer?
    private var scanURL: URL?

    init(demo: Bool = false) {
        isDemo = demo
        if !demo, let raw = UserDefaults.standard.string(forKey: "viewMode"), let mode = ViewMode(rawValue: raw) { viewMode = mode }
    }

    static var demo: HeftModel {
        let m = HeftModel(demo: true)
        let root = Demo.tree()
        m.root = root
        m.zoom = root
        m.selected = root.child(named: "Movies")?.child(named: "Naxos sailing 4K.mov")
        m.phase = .ready
        m.duration = 2.4
        m.skipped = 3
        m.demoHover = CGPoint(x: 700, y: 110)
        return m
    }

    var current: Node? { zoom ?? root }
    var isScanning: Bool { phase == .scanning }
    var canRescan: Bool { scanURL != nil && !isScanning }
    var canGoUp: Bool { zoom != nil && zoom !== root }
    var canOpenSelected: Bool { selected.map { $0.isFolder && !$0.children.isEmpty } ?? false }
    var canReveal: Bool { selected != nil || current != nil }
    var canTrash: Bool {
        guard let s = selected, let root, s !== root, !isScanning else { return false }
        if let zoom, s === zoom || zoom.isDescendant(of: s) { return false }
        return true
    }

    // MARK: Scanning

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to see what fills it."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.scan(url) }
        }
    }

    func scan(_ url: URL, restoring path: [String] = []) {
        guard !isDemo else { return }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scanURL = url
        scanName = FileManager.default.displayName(atPath: url.path)
        scannedFiles = 0
        scannedBytes = 0
        scanPath = url.path
        phase = .scanning
        let start = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull(p) }
        }
        Task.detached(priority: .userInitiated) {
            let tree = Scanner.scan(url, progress: p)
            await MainActor.run { self.finish(tree, progress: p, started: start, restoring: path) }
        }
    }

    private func pull(_ p: ScanProgress) {
        guard p === progress else { return }
        let s = p.snapshot
        scannedFiles = s.files
        scannedBytes = s.bytes
        scanPath = s.path
    }

    private func finish(_ tree: Node?, progress p: ScanProgress, started: Date, restoring path: [String]) {
        guard p === progress else { return }
        timer?.invalidate()
        timer = nil
        progress = nil
        guard let tree else {
            phase = root == nil ? .empty : .ready
            return
        }
        var target = tree
        for name in path { if let next = target.child(named: name), next.isFolder { target = next } else { break } }
        root = tree
        zoom = target
        selected = nil
        skipped = p.snapshot.skipped
        duration = Date().timeIntervalSince(started)
        revision += 1
        withAnimation(.snappy) { phase = .ready }
    }

    func cancelScan() { progress?.cancel() }

    func rescan() {
        guard let scanURL, !isScanning else { return }
        let path = (zoom?.lineage ?? []).dropFirst().map(\.name)
        scan(scanURL, restoring: Array(path))
    }

    // MARK: Navigation

    func open(_ node: Node) {
        guard node.isFolder, !node.children.isEmpty else { return }
        withAnimation(.snappy) {
            zoom = node
            if let s = selected, !(s.isDescendant(of: node)) { selected = nil }
        }
    }

    func goUp() {
        guard let zoom, let parent = zoom.parent else { return }
        withAnimation(.snappy) {
            selected = zoom
            self.zoom = parent
        }
    }

    func goToTop() {
        guard let root else { return }
        withAnimation(.snappy) { zoom = root; selected = nil }
    }

    func openSelected() { if let selected { open(selected) } }

    func select(_ node: Node?) { selected = node }

    // MARK: Actions

    func reveal(_ node: Node? = nil) {
        guard !isDemo, let n = node ?? selected ?? current else { return }
        revealInFinder([n.url])
    }

    func requestTrash(_ node: Node? = nil) {
        if let node { selected = node }
        guard canTrash else { return }
        pendingTrash = selected
    }

    func confirmTrash(_ node: Node) {
        pendingTrash = nil
        guard !isDemo else { return }
        do {
            try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
            if selected === node { selected = nil }
            node.detach()
            revision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyPath(_ node: Node) {
        guard !isDemo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.url.path, forType: .string)
    }
}

// MARK: - Demo data

enum Demo {
    struct Random {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func size(_ lo: Double, _ hi: Double) -> Int64 { Int64(lo + (hi - lo) * next() * next()) }
    }

    static let MB = 1_000_000.0
    static let GB = 1_000_000_000.0

    static func file(_ name: String, _ size: Double) -> Node {
        Node(name: name, isFolder: false, kind: FileKind.classify(extension: (name as NSString).pathExtension), size: Int64(size))
    }

    static func folder(_ name: String, _ kids: [Node]) -> Node {
        let n = Node(name: name, isFolder: true, kind: .other)
        n.children = kids
        n.aggregate()
        return n
    }

    static func many(_ r: inout Random, _ stem: String, _ ext: String, _ count: Int, _ lo: Double, _ hi: Double) -> [Node] {
        (1...count).map { i in Node(name: "\(stem) \(i).\(ext)", isFolder: false, kind: FileKind.classify(extension: ext), size: r.size(lo, hi)) }
    }

    /// A believable home folder.
    static func tree() -> Node {
        var r = Random(state: 42)
        let movies = folder("Movies", [
            file("Naxos sailing 4K.mov", 18.4 * GB),
            file("Volleyball finals.mov", 11.2 * GB),
            folder("Drone footage", many(&r, "DJI", "mp4", 14, 0.6 * GB, 4.2 * GB)),
            folder("Screen Recordings", many(&r, "Recording", "mov", 18, 0.1 * GB, 1.4 * GB)),
            folder("Final Cut Projects", [folder("Render Files", many(&r, "Render", "mov", 9, 0.8 * GB, 2.6 * GB)),
                                          file("Naxos edit.fcpxml", 4 * MB)]),
        ])
        let photos = folder("Photos Library.photoslibrary", [
            folder("originals", (2019...2026).map { y in folder("\(y)", many(&r, "IMG", "heic", 60, 1.5 * MB, 9 * MB) + many(&r, "IMG", "mov", 4, 40 * MB, 420 * MB)) }),
            folder("resources", many(&r, "derivative", "jpg", 40, 2 * MB, 40 * MB)),
            file("Photos.sqlite", 1.4 * GB),
        ])
        let pictures = folder("Pictures", [photos,
                                           folder("Exports", many(&r, "Export", "jpg", 36, 4 * MB, 30 * MB)),
                                           folder("RAW", many(&r, "DSC", "arw", 80, 40 * MB, 70 * MB))])
        func repo(_ name: String, _ ext: String, _ scale: Double) -> Node {
            folder(name, [folder("node_modules", (1...14).map { folder("package \($0)", many(&r, "index", "js", 12, 20_000, 3 * MB * scale)) }),
                          folder(".git", [folder("objects", many(&r, "pack", "pack", 4, 20 * MB, 600 * MB * scale))]),
                          folder("Sources", many(&r, "File", ext, 40, 4_000, 120_000)),
                          folder("build", many(&r, "artifact", "o", 24, 1 * MB, 60 * MB * scale))])
        }
        let developer = folder("Developer", [repo("macapps", "swift", 1.4), repo("etorotrade", "py", 1), repo("second-brain", "py", 0.8),
                                             folder("datasets", many(&r, "census", "parquet", 12, 80 * MB, 900 * MB) + many(&r, "export", "csv", 8, 20 * MB, 300 * MB))])
        let library = folder("Library", [
            folder("Developer", [folder("Xcode", [folder("DerivedData", (1...10).map { folder("Project \($0)", many(&r, "module", "o", 20, 10 * MB, 220 * MB)) })]),
                                 folder("CoreSimulator", [folder("Devices", many(&r, "device", "img", 6, 1.2 * GB, 4 * GB))])]),
            folder("Caches", (1...12).map { folder("com.app.\($0)", many(&r, "cache", "db", 10, 4 * MB, 260 * MB)) }),
            folder("Application Support", [folder("Steam", many(&r, "depot", "bin", 8, 0.4 * GB, 3 * GB)),
                                           folder("MobileSync", [folder("Backup", many(&r, "chunk", "bin", 30, 50 * MB, 500 * MB))])]),
            folder("Mail", many(&r, "mailbox", "mbox", 20, 20 * MB, 400 * MB)),
        ])
        let music = folder("Music", [folder("Logic", many(&r, "Take", "wav", 40, 40 * MB, 380 * MB)),
                                     folder("Music", many(&r, "Track", "m4a", 160, 4 * MB, 14 * MB))])
        let downloads = folder("Downloads", [file("Xcode_27.xip", 12.1 * GB), file("Blender 5.dmg", 0.9 * GB),
                                             file("macOS 27 Installer.dmg", 14.8 * GB), file("Dataset.zip", 2.2 * GB)]
                               + many(&r, "Statement", "pdf", 40, 0.2 * MB, 6 * MB) + many(&r, "Photo", "jpg", 30, 1 * MB, 12 * MB))
        let documents = folder("Documents", [folder("Decks", many(&r, "Board update", "key", 14, 40 * MB, 400 * MB)),
                                             folder("Papers", many(&r, "Paper", "pdf", 80, 0.5 * MB, 30 * MB)),
                                             folder("Budgets", many(&r, "Budget", "xlsx", 30, 1 * MB, 40 * MB))])
        let apps = folder("Applications", [file("Final Cut Pro.app", 6.8 * GB), file("Logic Pro.app", 3.1 * GB),
                                           file("Xcode Beta.app", 9.2 * GB), file("Blender.app", 1.6 * GB)])
        let root = folder("dimitris", [movies, library, pictures, developer, music, downloads, documents, apps,
                                       folder("Desktop", many(&r, "Screenshot", "png", 40, 0.5 * MB, 6 * MB))])
        root.rootURL = URL(fileURLWithPath: "/Users/dimitris")
        return root
    }
}
