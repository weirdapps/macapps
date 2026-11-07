import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

/// One window's state: the loaded document, the selection, the search and the view mode.
@MainActor
final class ViewerModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case loading
        case failed(title: String, error: ParseError?, detail: String)
        case loaded
    }

    enum Mode: String, CaseIterable { case tree = "Tree", text = "Text" }

    /// How the outline opens a freshly loaded document.
    enum Expansion { case level(Int), nodes([Int32]) }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var tree: JSONTree?
    @Published private(set) var name = "Canopy"
    @Published private(set) var url: URL?
    @Published private(set) var loadingName = ""
    @Published var progress = 0.0
    @Published var mode: Mode = .tree { didSet { if mode != oldValue { modeChanged() } } }
    @Published var showInspector = true
    @Published private(set) var selected: Int32?
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var matches: [Int32] = []
    @Published private(set) var textMatches: [NSRange] = []
    @Published private(set) var matchIndex: Int?
    @Published private(set) var searching = false
    @Published private(set) var pretty: PrettyText?
    @Published var notice: Notice?
    @Published var focusSearch = 0

    struct Notice: Equatable {
        var message: String
        var reveal: URL?
    }

    var initialExpansion: Expansion = .level(2)
    /// Called with the file's URL whenever this window shows a new file, so window restoration reopens it.
    var onOpenURL: ((URL?) -> Void)?
    weak var outline: OutlineController?
    weak var window: NSWindow?
    /// The file this window shows or is reading, so a second request for it brings this window forward.
    private(set) var requestedURL: URL?
    weak var textPane: TextPaneController?

    private var parseProgress: ParseProgress?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var textTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    var isEmpty: Bool { phase == .empty }
    var hasDocument: Bool { tree != nil && phase == .loaded }
    var matchCount: Int { mode == .tree ? matches.count : textMatches.count }
    var subtitle: String {
        guard let tree, phase == .loaded else { return "" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(tree.stats.bytes), countStyle: .file)
        return "\(size), \(tree.stats.nodes.formatted()) values"
    }

    // MARK: Loading

    func open(_ url: URL) {
        requestedURL = url.standardizedFileURL
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let mode: JSONParser.Mode = ["jsonl", "ndjson", "jsonlines"].contains(ext) ? .lines : .auto
        start(name: name, url: url, mode: mode) {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values?.fileSize, size >= Int(Int32.max) {
                throw ParseError(message: "Files over 2 GB are not supported", offset: 0)
            }
            return JSONParser.utf8([UInt8](try Data(contentsOf: url, options: .mappedIfSafe)))
        }
    }

    func load(text: String, name: String) {
        requestedURL = nil
        start(name: name, url: nil, mode: .auto) { Array(text.utf8) }
    }

    func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show(Notice(message: "The clipboard has no text to read"))
            return
        }
        load(text: text, name: "Clipboard")
    }

    private func start(name: String, url: URL?, mode: JSONParser.Mode, read: @escaping @Sendable () throws -> [UInt8]) {
        cancelLoading()
        let progress = ParseProgress()
        parseProgress = progress
        loadingName = name
        self.progress = 0
        phase = .loading
        loadTask = Task {
            let poll = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    self.progress = progress.fraction
                }
            }
            let result: Result<JSONTree, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try JSONParser.parse(try read(), mode: mode, progress: progress)) } catch { return .failure(error) }
            }.value
            poll.cancel()
            guard !progress.isCancelled else { return }
            switch result {
            case .success(let tree):
                self.install(tree, name: name, url: url)
            case .failure(let error as ParseError):
                self.fail(name: name, url: url, title: "\(name) is not valid JSON", error: error)
            case .failure(let error):
                self.fail(name: name, url: url, title: "\(name) could not be opened", detail: error.localizedDescription)
            }
        }
    }

    func cancelLoading() {
        guard let parseProgress else { return }
        parseProgress.cancel()
        loadTask?.cancel()
        self.parseProgress = nil
        requestedURL = tree == nil ? nil : url?.standardizedFileURL
        if phase == .loading { phase = tree == nil ? .empty : .loaded }
    }

    private func fail(name: String, url: URL?, title: String, error: ParseError? = nil, detail: String = "") {
        parseProgress = nil
        self.name = name
        self.url = url
        tree = nil
        resetSearch()
        phase = .failed(title: title, error: error, detail: detail)
        onOpenURL?(url)
    }

    func install(_ tree: JSONTree, name: String, url: URL?) {
        parseProgress = nil
        self.tree = tree
        self.name = name
        self.url = url
        selected = nil
        pretty = nil
        resetSearch()
        initialExpansion = .level(Self.comfortableLevel(tree))
        phase = .loaded
        outline?.reload()
        if let url {
            Recents.add(url)
            onOpenURL?(url)
        }
        if mode == .text { refreshText() }
        if !query.isEmpty { scheduleSearch() }
    }

    /// The deepest level that still fits on a screen or two, so a small file opens fully and a huge one tidily.
    static func comfortableLevel(_ tree: JSONTree) -> Int {
        var level = 1, frontier: [Int32] = [0], rows = 1 + tree.childCount(0)
        while level < 6 {
            let next = frontier.flatMap { tree.childIDs($0).filter { tree.kind($0).isContainer } }
            let added = next.reduce(0) { $0 + tree.childCount($1) }
            guard !next.isEmpty, rows + added <= 60 else { break }
            rows += added
            frontier = next
            level += 1
        }
        return level
    }

    // MARK: Selection

    func select(_ id: Int32?, reveal: Bool = true) {
        guard selected != id else { return }
        selected = id
        if reveal, let id { outline?.reveal(id) }
        if mode == .text { refreshText() }
    }

    /// Called by the outline when the user changes the selection.
    func outlineSelected(_ id: Int32?) {
        guard selected != id else { return }
        selected = id
    }

    var focusID: Int32 { selected ?? 0 }

    func jsonPath(_ id: Int32? = nil) -> String {
        guard let tree else { return "$" }
        return JSONPathFormat.jsonPath(tree.segments(id ?? focusID))
    }

    func jqPath(_ id: Int32? = nil) -> String {
        guard let tree else { return "." }
        return JSONPathFormat.jq(tree.segments(id ?? focusID))
    }

    // MARK: Copy and export

    func copyValue(_ id: Int32? = nil) {
        guard let tree, !Desktop.isSnapshot else { return }
        let node = id ?? focusID
        let what = tree.kind(node).isContainer ? "Copied \(tree.kind(node).name.lowercased()) as JSON" : "Copied value"
        // Printing a big branch takes a moment: do it off the main thread so the window stays responsive.
        guard tree.rawRange(node).count > 1_000_000 else { copy(tree.copyText(node), what: what); return }
        show(Notice(message: "Copying…"))
        Task {
            let text = await Task.detached(priority: .userInitiated) { tree.copyText(node) }.value
            copy(text, what: what)
        }
    }

    func copyJSONPath(_ id: Int32? = nil) { copy(jsonPath(id), what: "Copied JSONPath") }
    func copyJQPath(_ id: Int32? = nil) { copy(jqPath(id), what: "Copied jq path") }

    private func copy(_ text: String, what: String) {
        guard !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(Notice(message: what))
    }

    func exportPretty() {
        guard let tree else { return }
        let node = focusID
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let base = (name as NSString).deletingPathExtension
        let part = node == 0 ? "" : " " + (tree.key(node) ?? "item \(tree.position(node))")
        panel.nameFieldStringValue = Self.exportName(base: base, part: part)
        if let url { panel.directoryURL = url.deletingLastPathComponent() }
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        Task {
            let ok = await Task.detached(priority: .userInitiated) {
                (try? Data(tree.render(node).bytes + [0x0A]).write(to: dest, options: .atomic)) != nil
            }.value
            show(ok ? Notice(message: "Saved \(dest.lastPathComponent)", reveal: dest) : Notice(message: "Could not save \(dest.lastPathComponent)"))
        }
    }

    /// The suggested export name: no slashes, colons or line breaks from the key, and not absurdly long.
    nonisolated static func exportName(base: String, part: String) -> String {
        let cleaned = String((base + part).map { "/:\n\r\t".contains($0) ? "-" : $0 }.prefix(120))
        return cleaned.trimmingCharacters(in: .whitespaces) + " pretty.json"
    }

    func show(_ notice: Notice) {
        withAnimation(.snappy) { self.notice = notice }
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(notice.reveal == nil ? 2.2 : 6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self.notice = nil }
        }
    }

    // MARK: Expansion

    func expandAll() { outline?.expand(toLevel: .max) }
    func collapseAll() { outline?.expand(toLevel: 1) }
    func expand(toLevel level: Int) { outline?.expand(toLevel: level) }

    // MARK: Search

    private func resetSearch() {
        searchTask?.cancel()
        matches = []
        textMatches = []
        matchIndex = nil
        searching = false
    }

    private func modeChanged() {
        if mode == .text { refreshText() } else { textPane?.highlight([], current: nil) }
        scheduleSearch(delay: false)
    }

    private func scheduleSearch(delay: Bool = true) {
        searchTask?.cancel()
        let q = query
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty, let tree else {
            matches = []
            textMatches = []
            matchIndex = nil
            searching = false
            outline?.refreshVisible()
            textPane?.highlight([], current: nil)
            return
        }
        searching = true
        let mode = mode
        let text = pretty?.string.string
        searchTask = Task {
            if delay { try? await Task.sleep(for: .milliseconds(tree.count > 200_000 ? 350 : 120)) }
            guard !Task.isCancelled else { return }
            if mode == .tree {
                let flag = CancelFlag()
                let hits = await withTaskCancellationHandler {
                    await Task.detached(priority: .userInitiated) { tree.search(q) { flag.isSet } }.value
                } onCancel: { flag.set() }
                guard !Task.isCancelled else { return }
                matches = hits
                matchIndex = nil
                searching = false
                outline?.refreshVisible()
                if !hits.isEmpty { step(1) }
            } else {
                let ranges = await Task.detached(priority: .userInitiated) { Self.ranges(of: q, in: text ?? "") }.value
                guard !Task.isCancelled else { return }
                textMatches = ranges
                matchIndex = nil
                searching = false
                if !ranges.isEmpty { step(1) } else { textPane?.highlight([], current: nil) }
            }
        }
    }

    nonisolated static func ranges(of query: String, in text: String, limit: Int = 10_000) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = [], from = 0
        while out.count < limit {
            let r = ns.range(of: query, options: [.caseInsensitive], range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { break }
            out.append(r)
            from = r.location + max(1, r.length)
        }
        return out
    }

    func findNext() { step(1) }
    func findPrevious() { step(-1) }

    private func step(_ delta: Int) {
        let n = matchCount
        guard n > 0 else { NSSound.beep(); return }
        let next = matchIndex.map { ($0 + delta + n) % n } ?? (delta > 0 ? 0 : n - 1)
        matchIndex = next
        if mode == .tree {
            select(matches[next])
        } else {
            textPane?.highlight(textMatches, current: next)
        }
    }

    // MARK: Text

    func refreshText() {
        guard let tree, mode == .text else { return }
        let focus = focusID
        // Already showing it: in full, or as the top of a text that had to stop at the size limit.
        if let pretty, pretty.tree === tree, pretty.node == focus || pretty.range(of: focus) != nil {
            textPane?.reveal(pretty.range(of: focus))
            return
        }
        textTask?.cancel()
        textTask = Task {
            let text = await Task.detached(priority: .userInitiated) { PrettyText.make(tree, focus: focus) }.value
            guard !Task.isCancelled else { return }
            pretty = text
            if !query.isEmpty { scheduleSearch(delay: false) }
        }
    }
}

/// A thread-safe flag that a long search polls to stop early.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The pretty printed, syntax coloured text: the whole document when it fits, else the selected node.
final class PrettyText: @unchecked Sendable {
    static let limit = 4_000_000

    let tree: JSONTree
    /// The node printed at the top: the root, or the selection when the whole document is too big to show.
    let node: Int32
    let string: NSAttributedString
    let truncated: Bool
    private let rendered: JSONTree.Rendered

    private init(tree: JSONTree, node: Int32, rendered: JSONTree.Rendered) {
        self.tree = tree
        self.node = node
        self.rendered = rendered
        truncated = rendered.truncated
        var text = String(decoding: rendered.bytes, as: UTF8.self)
        if rendered.truncated { text += "\n…" }
        string = Self.colorize(text)
    }

    static func make(_ tree: JSONTree, focus: Int32) -> PrettyText {
        // Whether `focus` was printed in full in a rendering of `node`. Checked before colouring, which is the slow part.
        func shows(_ r: JSONTree.Rendered, from node: Int32) -> Bool {
            let k = Int(focus) - Int(node)
            return k >= 0 && k < r.starts.count && r.ends[k] >= 0
        }
        let whole = tree.render(0, limit: limit, track: true)
        if focus == 0 || shows(whole, from: 0) { return PrettyText(tree: tree, node: 0, rendered: whole) }
        // Too big to show whole: the largest branch around the selection that fits.
        for candidate in tree.ancestors(focus).dropFirst() where tree.rawRange(candidate).count < limit / 3 {
            let part = tree.render(candidate, limit: limit, track: true)
            if shows(part, from: candidate) { return PrettyText(tree: tree, node: candidate, rendered: part) }
        }
        return PrettyText(tree: tree, node: focus, rendered: tree.render(focus, limit: limit, track: true))
    }

    /// Where a node's value sits in `string`, if it was printed in full.
    func range(of id: Int32) -> NSRange? {
        let k = Int(id) - Int(node)
        guard k >= 0, k < rendered.starts.count, rendered.ends[k] >= 0 else { return nil }
        let start = Int(rendered.starts[k]), end = Int(rendered.ends[k])
        // Byte offsets to UTF-16 offsets: one unit per UTF-8 lead byte, two for 4-byte sequences.
        var units = 0, location = 0
        rendered.bytes.withUnsafeBufferPointer { b in
            for i in 0..<end {
                if i == start { location = units }
                let c = b[i]
                if c & 0xC0 != 0x80 { units += c >= 0xF0 ? 2 : 1 }
            }
        }
        if start == end { location = units }
        return NSRange(location: location, length: units - location)
    }

    static func colorize(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ])
        let u = Array(text.utf16)
        let keyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        var i = 0
        out.beginEditing()
        while i < u.count {
            let c = u[i]
            if c == 0x22 {
                let s = i
                i += 1
                while i < u.count, u[i] != 0x22 { i += u[i] == 0x5C ? 2 : 1 }
                i = min(i + 1, u.count)
                var j = i
                while j < u.count, u[j] == 0x20 { j += 1 }
                let range = NSRange(location: s, length: i - s)
                if j < u.count, u[j] == 0x3A {
                    out.addAttributes([.foregroundColor: Theme.keyColor, .font: keyFont], range: range)
                } else {
                    out.addAttribute(.foregroundColor, value: TypeStyle.color(.string), range: range)
                }
            } else if c == 0x2D || (0x30...0x39).contains(c) {
                let s = i
                while i < u.count, let ch = Unicode.Scalar(u[i]), "0123456789+-.eE".unicodeScalars.contains(ch) { i += 1 }
                out.addAttribute(.foregroundColor, value: TypeStyle.color(.number), range: NSRange(location: s, length: i - s))
            } else if c == 0x74 || c == 0x66 || c == 0x6E {
                let s = i
                while i < u.count, (0x61...0x7A).contains(u[i]) { i += 1 }
                let kind: JSONKind = c == 0x6E ? .null : .bool
                out.addAttribute(.foregroundColor, value: TypeStyle.color(kind), range: NSRange(location: s, length: i - s))
            } else if c == 0x7B || c == 0x7D || c == 0x5B || c == 0x5D || c == 0x2C || c == 0x3A {
                out.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: i, length: 1))
                i += 1
            } else {
                i += 1
            }
        }
        out.endEditing()
        return out
    }
}

/// Recently opened files, newest first, for File > Open Recent.
enum Recents {
    static let key = "recentFiles"
    static var all: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        guard !Desktop.isSnapshot else { return }
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: key)
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        NotificationCenter.default.post(name: .recentsChanged, object: nil)
    }
}

extension Notification.Name {
    static let recentsChanged = Notification.Name("CanopyRecentsChanged")
}

/// File paths given on the command line. Skips the executable, `--flags`, and `-Key value` pairs that AppKit reads
/// as defaults, and keeps only files that exist.
enum CommandLineFiles {
    static func urls(_ arguments: [String], exists: (String) -> Bool = CommandLineFiles.isFile) -> [URL] {
        var out: [URL] = [], skipNext = false
        for arg in arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-") {
                skipNext = !arg.hasPrefix("--") && !arg.hasPrefix("-psn_")
                continue
            }
            let url = URL(fileURLWithPath: arg).standardizedFileURL
            if exists(url.path), !out.contains(url) { out.append(url) }
        }
        return out
    }

    static func isFile(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && !dir.boolValue
    }
}

/// Routes files from Finder, the command line and menus to an empty window, or to a new one.
@MainActor
final class Router {
    static let shared = Router()
    private var openWindow: OpenWindowAction?
    private var models: [WeakModel] = []
    private var pending: [URL] = []

    private struct WeakModel { weak var model: ViewerModel? }

    func register(_ model: ViewerModel, openWindow: OpenWindowAction) {
        self.openWindow = openWindow
        models.removeAll { $0.model == nil }
        models.append(WeakModel(model: model))
        let queued = pending
        pending = []
        open(queued)
    }

    func open(_ urls: [URL], preferring model: ViewerModel? = nil) {
        for url in urls {
            if let existing = models.compactMap(\.model).first(where: { $0.requestedURL == url.standardizedFileURL }) {
                existing.window?.makeKeyAndOrderFront(nil)
            } else if let model, model.isEmpty {
                model.open(url)
            } else if let empty = models.compactMap(\.model).first(where: \.isEmpty) {
                empty.open(url)
            } else if let openWindow {
                openWindow(id: "viewer", value: url)
            } else {
                pending.append(url)
            }
        }
    }

    func showOpenPanel(preferring model: ViewerModel?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "jsonl") ?? .json, UTType(filenameExtension: "ndjson") ?? .json, .plainText]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose JSON or JSON Lines files"
        guard panel.runModal() == .OK else { return }
        open(panel.urls, preferring: model)
    }
}
