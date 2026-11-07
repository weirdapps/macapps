import AppKit
import Kit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sources and pages

/// One file the user dropped: a PDF, or an image turned into a one-page PDF.
/// The PDFDocument is only touched on `Binder.queue` after loading, so the class is safe to send there.
final class Source: Identifiable, @unchecked Sendable {
    let id = UUID()
    let name: String
    let url: URL?
    let document: PDFDocument
    let tint: Int
    let bytes: Int64
    let isImage: Bool
    /// Each page's size in points as it displays, its own rotation applied.
    let sizes: [CGSize]

    init(name: String, url: URL?, document: PDFDocument, tint: Int, bytes: Int64, isImage: Bool) {
        self.name = name
        self.url = url
        self.document = document
        self.tint = tint
        self.bytes = bytes
        self.isImage = isImage
        sizes = (0..<document.pageCount).map { i in
            guard let page = document.page(at: i) else { return CGSize(width: 612, height: 792) }
            let box = page.bounds(for: .cropBox).size
            return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
        }
    }

    var pageCount: Int { sizes.count }
    var bytesPerPage: Double { pageCount == 0 ? 0 : Double(bytes) / Double(pageCount) }
}

/// A page of the result: which source page it is and the quarter turns the user added.
struct PageItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceID: UUID
    let index: Int
    var rotation: Int

    init(sourceID: UUID, index: Int, rotation: Int = 0) {
        id = UUID()
        self.sourceID = sourceID
        self.index = index
        self.rotation = rotation
    }

    var thumbnailKey: String { "\(sourceID.uuidString)-\(index)" }
}

enum LoadError: LocalizedError, Equatable {
    case locked(String), unreadable(String), empty(String)

    var errorDescription: String? {
        switch self {
        case .locked(let name): "\(name) is password protected. Unlock it in Preview first."
        case .unreadable(let name): "\(name) is not a PDF or an image Binder can read."
        case .empty(let name): "\(name) has no pages."
        }
    }
}

// MARK: - Pure logic

enum Binder {
    /// Every PDFDocument read and write after loading happens here, off the main thread.
    static let queue = DispatchQueue(label: "com.weirdapps.binder.pdf", qos: .userInitiated)

    static let imageTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .gif, .bmp, .webP, .image]

    /// Expands folders (one level, sorted by name like Finder) and keeps only PDFs and images.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles])) ?? []
                out += items.filter { isSupported($0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                out.append(url)
            }
        }
        return out
    }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .image)
    }

    /// Reads a PDF or an image into a source.
    static func load(_ url: URL, tint: Int) throws -> Source {
        let name = url.deletingPathExtension().lastPathComponent
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) ?? false {
            guard let doc = PDFDocument(url: url) else { throw LoadError.unreadable(url.lastPathComponent) }
            if doc.isLocked { throw LoadError.locked(url.lastPathComponent) }
            if doc.pageCount == 0 { throw LoadError.empty(url.lastPathComponent) }
            return Source(name: name, url: url, document: doc, tint: tint, bytes: bytes, isImage: false)
        }
        guard let image = NSImage(contentsOf: url), image.isValid, let page = imagePage(image) else {
            throw LoadError.unreadable(url.lastPathComponent)
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return Source(name: name, url: url, document: doc, tint: tint, bytes: bytes, isImage: true)
    }

    /// A page the size of the image in points, at least 72 dpi so phone photos do not become poster sized.
    static func imagePage(_ image: NSImage) -> PDFPage? {
        var size = image.size
        let longest = max(size.width, size.height)
        if longest > 1700 { size = CGSize(width: size.width * 1700 / longest, height: size.height * 1700 / longest) }
        guard size.width >= 1, size.height >= 1 else { return nil }
        let sized = NSImage(size: size)
        sized.addRepresentations(image.representations)
        return PDFPage(image: sized)
    }

    static func normalised(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Moves `ids` (keeping their order) to just before `target`, or to the end when `target` is nil.
    static func move(_ pages: [PageItem], ids: Set<UUID>, before target: UUID?) -> [PageItem] {
        let moving = pages.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return pages }
        if let target, ids.contains(target) {
            // Dropped onto one of the moved pages: gather them at the first one's place.
            var rest = pages.filter { !ids.contains($0.id) }
            let first = pages.firstIndex { ids.contains($0.id) }!
            let insert = pages[..<first].filter { !ids.contains($0.id) }.count
            rest.insert(contentsOf: moving, at: insert)
            return rest
        }
        var rest = pages.filter { !ids.contains($0.id) }
        let at = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        rest.insert(contentsOf: moving, at: at)
        return rest
    }

    static func rotate(_ pages: [PageItem], ids: Set<UUID>, by degrees: Int) -> [PageItem] {
        pages.map { p in
            guard ids.contains(p.id) else { return p }
            var p = p
            p.rotation = normalised(p.rotation + degrees)
            return p
        }
    }

    /// Estimated output size: each page costs its source's average bytes per page.
    static func estimate(_ pages: [PageItem], sources: [Source]) -> Int64 {
        let perPage = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.bytesPerPage) })
        return Int64(pages.reduce(0) { $0 + (perPage[$1.sourceID] ?? 0) })
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The output PDF for `pages`, each a copy of its source page with the added rotation.
    /// Returns nil if `cancel` turns true part way. Call on `queue`.
    static func build(_ pages: [PageItem], sources: [Source], cancel: CancelToken? = nil,
                      progress: ((Int) -> Void)? = nil) -> PDFDocument? {
        let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let out = PDFDocument()
        for (n, item) in pages.enumerated() {
            if cancel?.isCancelled ?? false { return nil }
            guard let page = byID[item.sourceID]?.document.page(at: item.index),
                  let copy = page.copy() as? PDFPage else { continue }
            copy.rotation = normalised(page.rotation + item.rotation)
            out.insert(copy, at: out.pageCount)
            progress?(n + 1)
        }
        return out
    }

    /// `name.pdf` in `folder`, or `name 2.pdf`, `name 3.pdf` when taken, so nothing is overwritten.
    static func uniqueURL(in folder: URL, name: String, ext: String = "pdf") -> URL {
        var url = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// File names for a split: `Base 07` for single pages (zero padded to the page count), `Base 1-3` for ranges.
    static func splitNames(_ groups: [[Int]], base: String, total: Int) -> [String] {
        let width = String(total).count
        return groups.map { g in
            if g.count == 1 {
                let s = String(g[0])
                return "\(base) \(String(repeating: "0", count: max(0, width - s.count)))\(s)"
            }
            return "\(base) \(g.first!)-\(g.last!)"
        }
    }
}

/// A cancel flag shared between the main thread and `Binder.queue`.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - Page ranges

enum Ranges {
    /// Parses "1-3, 5, 8-" into groups of 1-based page numbers for a document of `count` pages.
    /// "8-" runs to the end, "-3" from the start, "3-1" runs backwards. Returns an error message for anything else.
    static func parse(_ text: String, count: Int) -> Result<[[Int]], RangeError> {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.allSatisfy(\.isEmpty) else { return .failure(.empty) }
        var groups: [[Int]] = []
        for part in parts where !part.isEmpty {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count <= 2 else { return .failure(.invalid(part)) }
            func number(_ s: String, fallback: Int) -> Int? { s.isEmpty ? fallback : Int(s) }
            let lo: Int?, hi: Int?
            if ends.count == 1 {
                lo = Int(ends[0]); hi = lo
            } else {
                if ends[0].isEmpty && ends[1].isEmpty { return .failure(.invalid(part)) }
                lo = number(ends[0], fallback: 1)
                hi = number(ends[1], fallback: count)
            }
            guard let lo, let hi else { return .failure(.invalid(part)) }
            for n in [lo, hi] where n < 1 || n > count { return .failure(.outOfRange(n, count)) }
            groups.append(lo <= hi ? Array(lo...hi) : Array((hi...lo).reversed()))
        }
        return .success(groups)
    }
}

enum RangeError: Error, Equatable {
    case empty, invalid(String), outOfRange(Int, Int)

    var message: String {
        switch self {
        case .empty: "Type page numbers or ranges, like 1-3, 5."
        case .invalid(let part): "“\(part)” is not a page or a range."
        case .outOfRange(let n, let count): "There is no page \(n); the result has \(count) page\(count == 1 ? "" : "s")."
        }
    }
}

// MARK: - Model

enum Theme {
    static let top = Color(red: 0xE8 / 255, green: 0x45 / 255, blue: 0x5A / 255)
    static let bottom = Color(red: 0x8E / 255, green: 0x1D / 255, blue: 0x3B / 255)
    static let accent = LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Colour tags given to sources in the order they arrive.
    static let tags: [Color] = [
        Color(red: 0.91, green: 0.27, blue: 0.35), Color(red: 0.20, green: 0.52, blue: 0.96),
        Color(red: 0.98, green: 0.62, blue: 0.10), Color(red: 0.19, green: 0.70, blue: 0.45),
        Color(red: 0.58, green: 0.35, blue: 0.90), Color(red: 0.10, green: 0.68, blue: 0.75),
        Color(red: 0.93, green: 0.40, blue: 0.70), Color(red: 0.55, green: 0.45, blue: 0.33),
    ]
    static func tag(_ i: Int) -> Color { tags[i % tags.count] }
}

struct Job: Equatable {
    var title: String
    var done: Int
    var total: Int
}

struct Notice: Equatable {
    var text: String
    var urls: [URL]
}

@MainActor
final class BinderModel: ObservableObject {
    static let shared = BinderModel()

    @Published private(set) var sources: [Source] = []
    @Published private(set) var pages: [PageItem] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published var tileSize: Double = 150
    @Published var dropTarget: UUID?
    @Published var job: Job?
    @Published var notice: Notice?
    @Published var errorMessage: String?
    @Published var showingSplit = false
    /// The page the website snapshot shows hovered, with its buttons.
    var demoHover: UUID?

    weak var undoManager: UndoManager?
    var dragging: Set<UUID> = []
    private var anchor: UUID?
    private var nextTint = 0
    private var requested: Set<String> = []
    private var cancelToken: CancelToken?

    nonisolated static let thumbnailPixels: CGFloat = 400
    static let tileRange: ClosedRange<Double> = 100...260

    // MARK: Derived

    func source(_ id: UUID) -> Source? { sources.first { $0.id == id } }
    var estimatedBytes: Int64 { Binder.estimate(pages, sources: sources) }
    /// The selected pages, or every page when nothing is selected.
    var targets: Set<UUID> { selection.isEmpty ? Set(pages.map(\.id)) : selection }
    var hasSelection: Bool { !selection.isEmpty }
    var isBusy: Bool { job != nil }
    func pagesLeft(in source: Source) -> Int { pages.filter { $0.sourceID == source.id }.count }

    // MARK: Undoable edits

    private struct Snapshot: @unchecked Sendable {
        var sources: [Source]
        var pages: [PageItem]
        var selection: Set<UUID>
    }

    private var snapshot: Snapshot { Snapshot(sources: sources, pages: pages, selection: selection) }

    /// Applies a change and registers its undo (which registers the redo).
    private func commit(_ name: String, sources newSources: [Source]? = nil, pages newPages: [PageItem], selection newSelection: Set<UUID>? = nil) {
        let old = snapshot
        let new = Snapshot(sources: newSources ?? sources, pages: newPages,
                           selection: (newSelection ?? selection).intersection(newPages.map(\.id)))
        apply(new, undo: old, name: name)
    }

    private func apply(_ new: Snapshot, undo old: Snapshot, name: String) {
        withAnimation(.snappy(duration: 0.28)) {
            sources = new.sources
            pages = new.pages
            selection = new.selection
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.apply(old, undo: new, name: name) }
        }
        undoManager?.setActionName(name)
    }

    /// Adds files (folders expand) at `index`, or at the end. Unreadable files are reported together.
    func add(_ urls: [URL], at index: Int? = nil) {
        var added: [Source] = []
        var problems: [String] = []
        for url in Binder.expand(urls) {
            do {
                added.append(try Binder.load(url, tint: nextTint))
                nextTint += 1
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if !problems.isEmpty { errorMessage = problems.joined(separator: "\n") }
        add(added, at: index)
    }

    func add(_ added: [Source], at index: Int? = nil) {
        guard !added.isEmpty else { return }
        let newPages = added.flatMap { s in (0..<s.pageCount).map { PageItem(sourceID: s.id, index: $0) } }
        var all = pages
        all.insert(contentsOf: newPages, at: min(index ?? all.count, all.count))
        let count = newPages.count
        commit(count == 1 ? "Add Page" : "Add Pages", sources: sources + added, pages: all, selection: Set(newPages.map(\.id)))
    }

    func rotate(_ degrees: Int, ids: Set<UUID>? = nil) {
        let ids = ids ?? targets
        guard !ids.isEmpty else { return }
        commit(degrees < 0 ? "Rotate Left" : "Rotate Right", pages: Binder.rotate(pages, ids: ids, by: degrees))
    }

    func delete(ids: Set<UUID>? = nil) {
        let ids = ids ?? selection
        guard !ids.isEmpty else { return }
        commit(ids.count == 1 ? "Delete Page" : "Delete Pages", pages: pages.filter { !ids.contains($0.id) })
    }

    func move(_ ids: Set<UUID>, before target: UUID?) {
        let moved = Binder.move(pages, ids: ids, before: target)
        guard moved != pages else { return }
        commit(ids.count == 1 ? "Move Page" : "Move Pages", pages: moved, selection: ids)
    }

    /// Moves the selection one place earlier or later.
    func nudge(_ step: Int) {
        guard hasSelection else { return }
        let positions = pages.indices.filter { selection.contains(pages[$0].id) }
        if step < 0 {
            guard let first = positions.first, first > 0 else { return }
            move(selection, before: pages[first - 1].id)
        } else {
            guard let last = positions.last, last < pages.count - 1 else { return }
            move(selection, before: last + 2 < pages.count ? pages[last + 2].id : nil)
        }
    }

    func reverse() {
        let ids = targets
        let positions = pages.indices.filter { ids.contains(pages[$0].id) }
        guard positions.count > 1 else { return }
        var out = pages
        for (slot, item) in zip(positions, positions.reversed().map { pages[$0] }) { out[slot] = item }
        commit("Reverse Order", pages: out)
    }

    func removeSource(_ id: UUID) {
        commit("Remove File", sources: sources.filter { $0.id != id }, pages: pages.filter { $0.sourceID != id })
    }

    /// Puts back every page of a source that was deleted, at the end.
    func restorePages(of source: Source) {
        let present = Set(pages.filter { $0.sourceID == source.id }.map(\.index))
        let missing = (0..<source.pageCount).filter { !present.contains($0) }.map { PageItem(sourceID: source.id, index: $0) }
        guard !missing.isEmpty else { return }
        commit("Restore Pages", pages: pages + missing, selection: Set(missing.map(\.id)))
    }

    func clear() {
        guard !sources.isEmpty else { return }
        commit("Remove All", sources: [], pages: [], selection: [])
    }

    // MARK: Selection

    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let anchor, let a = pages.firstIndex(where: { $0.id == anchor }),
                  let b = pages.firstIndex(where: { $0.id == id }) {
            selection = Set(pages[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(pages.map(\.id)) }
    func selectNone() { selection = [] }
    func select(source id: UUID) { selection = Set(pages.filter { $0.sourceID == id }.map(\.id)) }

    /// Moves the selection with the arrow keys; with shift it extends.
    func step(_ delta: Int, extend: Bool) {
        guard !pages.isEmpty else { return }
        let current = anchor.flatMap { a in pages.firstIndex { $0.id == a } } ?? (delta > 0 ? -1 : pages.count)
        let next = max(0, min(pages.count - 1, current + delta))
        let id = pages[next].id
        if extend { selection.insert(id) } else { selection = [id] }
        anchor = id
    }

    // MARK: Drag and drop

    /// The pages a drag that starts on `id` carries: the selection if `id` is in it, otherwise just `id`.
    func beginDrag(_ id: UUID) -> Set<UUID> {
        if !selection.contains(id) { selection = [id]; anchor = id }
        dragging = selection
        return dragging
    }

    func endDrag() {
        dragging = []
        dropTarget = nil
    }

    // MARK: Thumbnails

    func requestThumbnail(_ item: PageItem) {
        let key = item.thumbnailKey
        guard thumbnails[key] == nil, !requested.contains(key), let source = source(item.sourceID) else { return }
        requested.insert(key)
        let index = item.index
        Binder.queue.async {
            let image = Self.renderThumbnail(source, index: index)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { BinderModel.store(image, key: key, in: self) }
            }
        }
    }

    private static func store(_ image: NSImage?, key: String, in model: BinderModel) {
        if let image { model.thumbnails[key] = image }
    }

    nonisolated static func renderThumbnail(_ source: Source, index: Int) -> NSImage? {
        guard let page = source.document.page(at: index) else { return nil }
        return page.thumbnail(of: NSSize(width: thumbnailPixels, height: thumbnailPixels), for: .cropBox)
    }

    /// Renders every thumbnail now, for the snapshot and tests.
    func renderAllThumbnails() {
        for item in pages {
            if let s = source(item.sourceID), let img = Self.renderThumbnail(s, index: item.index) { thumbnails[item.thumbnailKey] = img }
        }
    }

    // MARK: Export

    var suggestedName: String {
        let names = Set(pages.map(\.sourceID))
        if names.count == 1, let s = source(pages[0].sourceID) { return s.name + " edited" }
        return sources.first.map { $0.name + " combined" } ?? "Binder"
    }

    func exportPDF(to url: URL) {
        run(title: "Exporting", groups: [pages], names: [url], reveal: url) { count in
            "Saved \(url.lastPathComponent), \(count) page\(count == 1 ? "" : "s")"
        }
    }

    /// Writes one file per group of 1-based positions into `folder`.
    func split(_ groups: [[Int]], into folder: URL, base: String) {
        let items = groups.map { g in g.map { pages[$0 - 1] } }
        let names = Binder.splitNames(groups, base: base, total: pages.count)
        var used: Set<String> = []
        let urls = names.map { name -> URL in
            var url = Binder.uniqueURL(in: folder, name: name)
            var n = 2
            while used.contains(url.path) { url = Binder.uniqueURL(in: folder, name: "\(name) \(n)"); n += 1 }
            used.insert(url.path)
            return url
        }
        run(title: "Splitting", groups: items, names: urls, reveal: nil) { _ in
            "Saved \(urls.count) file\(urls.count == 1 ? "" : "s") in \(folder.lastPathComponent)"
        }
    }

    private func run(title: String, groups: [[PageItem]], names: [URL], reveal: URL?, message: @escaping @Sendable (Int) -> String) {
        guard job == nil else { return }
        let total = groups.reduce(0) { $0 + $1.count }
        let token = CancelToken()
        cancelToken = token
        job = Job(title: title, done: 0, total: total)
        notice = nil
        let sources = sources
        Binder.queue.async {
            var done = 0
            var written: [URL] = []
            var failure: String?
            for (group, url) in zip(groups, names) {
                let base = done
                guard let doc = Binder.build(group, sources: sources, cancel: token, progress: { n in
                    let value = base + n
                    if value % 5 == 0 || value == total {
                        DispatchQueue.main.async { MainActor.assumeIsolated { self.job?.done = value } }
                    }
                }) else { break }
                done += group.count
                if doc.write(to: url) { written.append(url) } else { failure = "Could not write \(url.lastPathComponent)."; break }
            }
            let cancelled = token.isCancelled
            let finalWritten = written
            let finalFailure = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = self
                    model.job = nil
                    model.cancelToken = nil
                    if let finalFailure { model.errorMessage = finalFailure }
                    if !finalWritten.isEmpty {
                        let text = cancelled ? "Stopped after \(finalWritten.count) file\(finalWritten.count == 1 ? "" : "s")" : message(total)
                        withAnimation(.snappy) { model.notice = Notice(text: text, urls: finalWritten) }
                    }
                }
            }
        }
    }

    func cancelJob() { cancelToken?.cancel() }

    // MARK: Panels

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose PDFs, images or a folder of them"
        panel.prompt = "Add"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func exportPanel() {
        guard !pages.isEmpty, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"
        panel.canCreateDirectories = true
        if let folder = sources.first?.url?.deletingLastPathComponent() { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { exportPDF(to: url) }
    }

    func splitPanel(_ groups: [[Int]], base: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Split Here"
        panel.message = "Choose a folder for the \(groups.count) new PDF\(groups.count == 1 ? "" : "s")"
        if let folder = sources.first?.url?.deletingLastPathComponent() { panel.directoryURL = folder }
        if panel.runModal() == .OK, let url = panel.url { split(groups, into: url, base: base) }
    }
}
