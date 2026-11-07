import AppKit
import CryptoKit
import Foundation
import Kit
import SwiftUI

// MARK: - Values

struct ScanOptions: Codable, Equatable, Sendable {
    var skipHidden = true
    var skipPackages = true
    var minimumSize: Int64 = 1

    static let sizes: [(Int64, String)] = [
        (1, "Any size"), (10_000, "10 KB"), (100_000, "100 KB"), (1_000_000, "1 MB"),
        (10_000_000, "10 MB"), (100_000_000, "100 MB"),
    ]
}

struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let size: Int64
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
}

struct DuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String // Hex SHA-256 of the content.
    let size: Int64
    var files: [FileItem]

    var wasted: Int64 { size * Int64(max(files.count - 1, 0)) }
    var name: String { files.first?.name ?? "" }
}

enum KeepRule: String, CaseIterable, Identifiable, Codable, Sendable {
    case newest, oldest, shortestPath
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Keep Newest"
        case .oldest: "Keep Oldest"
        case .shortestPath: "Keep Shortest Path"
        }
    }

    var symbol: String {
        switch self {
        case .newest: "clock.arrow.circlepath"
        case .oldest: "clock"
        case .shortestPath: "folder"
        }
    }
}

enum GroupSort: String, CaseIterable, Identifiable, Sendable {
    case wasted, size, copies, name
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wasted: "Wasted Space"
        case .size: "File Size"
        case .copies: "Number of Copies"
        case .name: "Name"
        }
    }
}

enum ScanPhase: Int, CaseIterable, Sendable {
    case finding, sizing, quick, full

    var title: String {
        switch self {
        case .finding: "Finding files"
        case .sizing: "Matching sizes"
        case .quick: "Quick check"
        case .full: "Comparing contents"
        }
    }
}

struct ScanProgress: Sendable, Equatable {
    var phase: ScanPhase = .finding
    var done = 0
    var total = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var current = ""

    /// Nil while the work has no known end (walking the folders).
    var fraction: Double? {
        switch phase {
        case .finding, .sizing: nil
        case .quick: total > 0 ? Double(done) / Double(total) : nil
        case .full: bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : nil
        }
    }
}

struct ScanResult: Sendable {
    var groups: [DuplicateGroup]
    var filesScanned: Int
    var duration: TimeInterval
}

enum Fmt {
    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
    static func count(_ n: Int) -> String { n.formatted(.number) }
    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(count(n)) files" }
    static func copies(_ n: Int) -> String { "\(n) copies" }
    static func seconds(_ t: TimeInterval) -> String { t < 10 ? String(format: "%.1f s", t) : "\(Int(t.rounded())) s" }
}

// MARK: - Scanner

/// Finds identical files in three passes: equal sizes, then a hash of the first and last 16 KB, then a full SHA-256.
/// Synchronous and thread-agnostic; the app runs it on a detached task and passes `{ Task.isCancelled }`.
enum Scanner {
    static let window = 16 * 1024
    static let chunk = 1 << 20

    static func run(roots: [URL], options: ScanOptions, isCancelled: () -> Bool,
                    progress: (ScanProgress) -> Void) throws -> ScanResult {
        let started = Date()
        var p = ScanProgress()
        var lastReport = Date.distantPast
        func report(force: Bool = false) {
            let now = Date()
            if force || now.timeIntervalSince(lastReport) > 0.05 { lastReport = now; progress(p) }
        }
        func check() throws { if isCancelled() { throw CancellationError() } }

        // 1. Walk the folders.
        let files = try collect(roots: roots, options: options, check: check) { count, current in
            p.done = count
            p.current = current
            report()
        }
        try check()

        // 2. Equal sizes.
        p = ScanProgress(phase: .sizing, done: files.count)
        report(force: true)
        let sameSize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }
        let candidates = sameSize.flatMap { $0 }

        // 3. Head and tail. Small files are read whole here, so this hash is already final for them.
        p = ScanProgress(phase: .quick, total: candidates.count)
        report(force: true)
        var quick: [String: [FileItem]] = [:]
        for file in candidates {
            try check()
            p.current = file.name
            if let h = try? partialHash(of: file.url, size: file.size) { quick["\(file.size):\(h)", default: []].append(file) }
            p.done += 1
            report()
        }
        // 4. Full SHA-256 for the larger files still matching.
        var final: [String: [FileItem]] = [:]
        var needFull: [FileItem] = []
        for (key, group) in quick where group.count > 1 {
            if group[0].size <= Int64(2 * window) {
                final[String(key.split(separator: ":").last!), default: []] += group
            } else {
                needFull += group
            }
        }
        p = ScanProgress(phase: .full, total: needFull.count, bytesTotal: needFull.reduce(0) { $0 + $1.size })
        report(force: true)
        for file in needFull {
            try check()
            p.current = file.name
            let base = p.bytesDone
            let hash = try? sha256(of: file.url, check: check) { read in
                p.bytesDone = base + read
                report()
            }
            p.bytesDone = base + file.size
            p.done += 1
            if let hash { final[hash, default: []].append(file) }
        }
        try check()
        p.current = ""
        report(force: true)

        let groups = final.compactMap { key, files -> DuplicateGroup? in
            guard files.count > 1 else { return nil }
            return DuplicateGroup(id: key, size: files[0].size, files: files.sorted { $0.url.path < $1.url.path })
        }
        return ScanResult(groups: sort(groups, by: .wasted), filesScanned: files.count, duration: Date().timeIntervalSince(started))
    }

    /// Regular files under `roots`, each counted once: symlinks are skipped, hard links and overlapping roots deduplicated.
    static func collect(roots: [URL], options: ScanOptions, check: () throws -> Void,
                        found: (Int, String) -> Void) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var mask: FileManager.DirectoryEnumerationOptions = []
        if options.skipHidden { mask.insert(.skipsHiddenFiles) }
        if options.skipPackages { mask.insert(.skipsPackageDescendants) }
        var seen = Set<String>() // "device:inode"
        var result: [FileItem] = []
        let minimum = max(options.minimumSize, 1) // Empty files are all alike and free nothing.

        for root in normalized(roots) {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: mask,
                                                              errorHandler: { _, _ in true }) else { continue }
            while let url = walker.nextObject() as? URL {
                try check()
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isSymbolicLink != true, v.isRegularFile == true,
                      let size = v.fileSize.map(Int64.init), size >= minimum else { continue }
                var st = stat()
                guard lstat(url.path, &st) == 0, seen.insert("\(st.st_dev):\(st.st_ino)").inserted else { continue }
                result.append(FileItem(url: url, size: size, modified: v.contentModificationDate ?? .distantPast))
                if result.count % 64 == 0 { found(result.count, url.lastPathComponent) }
            }
        }
        found(result.count, "")
        return result
    }

    /// Standardized roots with any root inside another root dropped.
    static func normalized(_ roots: [URL]) -> [URL] {
        let paths = Set(roots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        return paths.sorted().filter { path in
            !paths.contains { other in other != path && (other == "/" || path.hasPrefix(other + "/")) }
        }.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// SHA-256 of the first and last `window` bytes, or of the whole file when it is at most twice that.
    static func partialHash(of url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        if size <= Int64(2 * window) {
            hasher.update(data: try handle.readToEnd() ?? Data())
        } else {
            hasher.update(data: try handle.read(upToCount: window) ?? Data())
            try handle.seek(toOffset: UInt64(size) - UInt64(window))
            hasher.update(data: try handle.read(upToCount: window) ?? Data())
        }
        return hex(hasher.finalize())
    }

    static func sha256(of url: URL, check: () throws -> Void = {}, read: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try check()
            let more = try autoreleasepool { () -> Bool in
                guard let data = try handle.read(upToCount: chunk), !data.isEmpty else { return false }
                hasher.update(data: data)
                total += Int64(data.count)
                return true
            }
            if !more { break }
            read(total)
        }
        return hex(hasher.finalize())
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    // MARK: Pure helpers

    static func sort(_ groups: [DuplicateGroup], by sort: GroupSort) -> [DuplicateGroup] {
        groups.sorted { a, b in
            switch sort {
            case .wasted: a.wasted != b.wasted ? a.wasted > b.wasted : a.name < b.name
            case .size: a.size != b.size ? a.size > b.size : a.name < b.name
            case .copies: a.files.count != b.files.count ? a.files.count > b.files.count : a.wasted > b.wasted
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// The copy a rule keeps. Ties fall back to the shortest path, then alphabetical order, so the result is stable.
    static func keeper(of group: DuplicateGroup, rule: KeepRule) -> FileItem {
        func shorter(_ a: FileItem, _ b: FileItem) -> Bool {
            let ca = a.url.pathComponents.count, cb = b.url.pathComponents.count
            if ca != cb { return ca < cb }
            if a.url.path.count != b.url.path.count { return a.url.path.count < b.url.path.count }
            return a.url.path < b.url.path
        }
        return group.files.min { a, b in
            switch rule {
            case .newest: a.modified != b.modified ? a.modified > b.modified : shorter(a, b)
            case .oldest: a.modified != b.modified ? a.modified < b.modified : shorter(a, b)
            case .shortestPath: shorter(a, b)
            }
        }!
    }

    /// Every copy except the one `rule` keeps, in every group.
    static func autoSelect(_ groups: [DuplicateGroup], rule: KeepRule) -> Set<String> {
        var marked = Set<String>()
        for group in groups {
            let keep = keeper(of: group, rule: rule)
            for file in group.files where file.id != keep.id { marked.insert(file.id) }
        }
        return marked
    }

    /// The groups without `paths`, dropping any group left with a single copy.
    static func removing(_ paths: Set<String>, from groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.compactMap { group in
            var g = group
            g.files.removeAll { paths.contains($0.id) }
            return g.files.count > 1 ? g : nil
        }
    }

    /// True when marking `file` would leave its group with no copy at all.
    static func wouldEmpty(_ group: DuplicateGroup, marking file: FileItem, marked: Set<String>) -> Bool {
        group.files.allSatisfy { $0.id == file.id || marked.contains($0.id) }
    }
}

// MARK: - Model

@MainActor
final class TwinsModel: ObservableObject {
    enum Stage { case idle, scanning, results }

    @Published var stage: Stage = .idle
    @Published var roots: [URL] = []
    @Published var progress = ScanProgress()
    @Published var groups: [DuplicateGroup] = []
    @Published var marked: Set<String> = []
    @Published var selection: DuplicateGroup.ID?
    @Published var search = ""
    @Published var sort: GroupSort = .wasted
    @Published var filesScanned = 0
    @Published var duration: TimeInterval = 0
    @Published var freed: Int64 = 0
    @Published var confirmingTrash = false
    @Published var problem: String?
    @Published var quickLook: URL?
    @Published var options = ScanOptions() { didSet { save() } }
    @Published var rule: KeepRule = .newest { didSet { save() } }

    weak var undoManager: UndoManager?
    private var work: Task<ScanResult, Error>?
    private var token = 0
    private var stageBeforeScan: Stage = .idle

    private struct Settings: Codable { var options: ScanOptions; var rule: KeepRule }

    init() {
        guard !Desktop.isSnapshot, let s = Storage.load(Settings.self, app: "Twins", file: "settings.json") else { return }
        options = s.options
        rule = s.rule
    }

    private func save() {
        guard !Desktop.isSnapshot else { return }
        Storage.save(Settings(options: options, rule: rule), app: "Twins", file: "settings.json")
    }

    // MARK: Derived

    var visibleGroups: [DuplicateGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? groups : groups.filter { $0.files.contains { $0.url.path.localizedCaseInsensitiveContains(q) } }
        return Scanner.sort(shown, by: sort)
    }

    var selectedGroup: DuplicateGroup? { groups.first { $0.id == selection } }
    var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }
    var duplicateFiles: Int { groups.reduce(0) { $0 + $1.files.count } }
    var markedFiles: [FileItem] { groups.flatMap(\.files).filter { marked.contains($0.id) } }
    var markedBytes: Int64 { markedFiles.reduce(0) { $0 + $1.size } }
    var isScanning: Bool { stage == .scanning }
    var rootNames: String { ListFormatter.localizedString(byJoining: roots.map { FileManager.default.displayName(atPath: $0.path) }) }

    func markedCount(in group: DuplicateGroup) -> Int { group.files.filter { marked.contains($0.id) }.count }

    // MARK: Folders

    func chooseFolders(adding: Bool = false) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Scan"
        panel.message = adding ? "Choose more folders to include in the scan." : "Choose the folders to look for duplicates in."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        roots = adding ? Scanner.normalized(roots + panel.urls) : Scanner.normalized(panel.urls)
        scan()
    }

    /// Folders dropped on the window: added to the current scan when results are showing, a fresh scan otherwise.
    func drop(_ urls: [URL]) -> Bool {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard !folders.isEmpty, !isScanning else { return false }
        roots = Scanner.normalized(stage == .results ? roots + folders : folders)
        scan()
        return true
    }

    // MARK: Scanning

    func scan() {
        guard !roots.isEmpty else { chooseFolders(); return }
        work?.cancel()
        token += 1
        let t = token
        if stage != .scanning { stageBeforeScan = stage }
        stage = .scanning
        progress = ScanProgress()
        let roots = roots, options = options
        let job = Task.detached(priority: .userInitiated) { [weak self] in
            try Scanner.run(roots: roots, options: options, isCancelled: { Task.isCancelled }) { p in
                Task { @MainActor in self?.apply(p, token: t) }
            }
        }
        work = job
        Task { [weak self] in
            let result = await job.result
            self?.finish(result, token: t)
        }
    }

    func cancelScan() {
        guard isScanning else { return }
        work?.cancel()
        token += 1
        stage = stageBeforeScan == .results ? .results : .idle
    }

    private func apply(_ p: ScanProgress, token t: Int) {
        guard t == token, stage == .scanning else { return }
        progress = p
    }

    private func finish(_ result: Result<ScanResult, Error>, token t: Int) {
        guard t == token else { return }
        work = nil
        switch result {
        case .success(let r):
            groups = r.groups
            filesScanned = r.filesScanned
            duration = r.duration
            marked = Scanner.autoSelect(r.groups, rule: rule)
            selection = visibleGroups.first?.id
            freed = 0
            undoManager?.removeAllActions(withTarget: self)
            withAnimation(.snappy) { stage = .results }
        case .failure:
            stage = stageBeforeScan == .results ? .results : .idle
        }
    }

    func reset() {
        cancelScan()
        groups = []
        marked = []
        roots = []
        stage = .idle
    }

    // MARK: Selection

    func apply(rule: KeepRule) {
        self.rule = rule
        withAnimation(.snappy) { marked = Scanner.autoSelect(groups, rule: rule) }
    }

    func deselectAll() { withAnimation(.snappy) { marked = [] } }

    func toggle(_ file: FileItem, in group: DuplicateGroup) {
        if marked.contains(file.id) {
            marked.remove(file.id)
        } else if Scanner.wouldEmpty(group, marking: file, marked: marked) {
            NSSound.beep() // One copy of every file always stays.
        } else {
            marked.insert(file.id)
        }
    }

    func keepOnly(_ file: FileItem, in group: DuplicateGroup) {
        withAnimation(.snappy) {
            for f in group.files { if f.id == file.id { marked.remove(f.id) } else { marked.insert(f.id) } }
        }
    }

    func quickLookSelected() { quickLook = selectedGroup?.files.first?.url }

    // MARK: Trash

    func requestTrash() { if !marked.isEmpty { confirmingTrash = true } }

    func trashMarked() {
        let before = (groups, marked)
        var moved: [(URL, URL)] = []
        var failed: [String] = []
        var bytes: Int64 = 0
        for file in markedFiles {
            var out: NSURL?
            do {
                try FileManager.default.trashItem(at: file.url, resultingItemURL: &out)
                moved.append((file.url, (out as URL?) ?? file.url))
                bytes += file.size
            } catch {
                failed.append(file.name)
            }
        }
        let removed = Set(moved.map(\.0.path))
        withAnimation(.snappy) {
            groups = Scanner.removing(removed, from: groups)
            marked.subtract(removed)
            freed += bytes
            if selectedGroup == nil { selection = visibleGroups.first?.id }
        }
        if !moved.isEmpty {
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/dock/drag to trash.aif",
                    byReference: true)?.play()
            undoManager?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.putBack(moved, groups: before.0, marked: before.1, bytes: bytes) }
            }
            undoManager?.setActionName("Move to Trash")
        }
        if !failed.isEmpty {
            problem = "\(Fmt.files(failed.count)) could not be moved to the Trash: \(failed.prefix(5).joined(separator: ", "))\(failed.count > 5 ? "…" : "")."
        }
    }

    /// Undo: moves trashed files back and restores the groups as they were, minus anything that could not come back.
    private func putBack(_ moved: [(URL, URL)], groups old: [DuplicateGroup], marked oldMarked: Set<String>, bytes: Int64) {
        var lost = Set<String>()
        for (original, trashed) in moved {
            do { try FileManager.default.moveItem(at: trashed, to: original) } catch { lost.insert(original.path) }
        }
        withAnimation(.snappy) {
            groups = Scanner.removing(lost, from: old)
            marked = oldMarked.subtracting(lost)
            freed = max(0, freed - bytes)
            if selectedGroup == nil { selection = visibleGroups.first?.id }
        }
        if !lost.isEmpty { problem = "\(Fmt.files(lost.count)) could not be put back. Look for them in the Trash." }
    }
}
