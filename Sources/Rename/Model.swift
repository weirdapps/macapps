import AppKit
import ImageIO
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rules

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case replace, insert, changeCase, number, date, trim, remove, fileExtension

    var id: String { rawValue }

    var title: String {
        switch self {
        case .replace: "Replace Text"
        case .insert: "Insert Text"
        case .changeCase: "Change Case"
        case .number: "Number"
        case .date: "Date"
        case .trim: "Trim"
        case .remove: "Remove Characters"
        case .fileExtension: "Extension"
        }
    }

    var symbol: String {
        switch self {
        case .replace: "arrow.left.arrow.right"
        case .insert: "text.insert"
        case .changeCase: "textformat"
        case .number: "number"
        case .date: "calendar"
        case .trim: "scissors"
        case .remove: "delete.left"
        case .fileExtension: "doc.badge.ellipsis"
        }
    }
}

enum Placement: String, Codable, CaseIterable, Identifiable {
    case prefix, suffix, index, replace
    var id: String { rawValue }
    var title: String {
        switch self {
        case .prefix: "Before"
        case .suffix: "After"
        case .index: "At"
        case .replace: "Replace"
        }
    }
}

enum CaseStyle: String, Codable, CaseIterable, Identifiable {
    case lower, upper, title, sentence
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lower: "lowercase"
        case .upper: "UPPERCASE"
        case .title: "Title Case"
        case .sentence: "Sentence case"
        }
    }
}

enum DateSource: String, Codable, CaseIterable, Identifiable {
    case created, modified, photo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .created: "Date created"
        case .modified: "Date modified"
        case .photo: "Photo taken (EXIF)"
        }
    }
}

enum ExtensionMode: String, Codable, CaseIterable, Identifiable {
    case lower, upper, set, remove
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lower: "lowercase"
        case .upper: "UPPERCASE"
        case .set: "Change to"
        case .remove: "Remove"
        }
    }
}

/// One step of the rename recipe. Every kind keeps its settings in the same flat struct, so switching
/// kinds or saving to JSON never loses anything.
struct Rule: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: RuleKind
    var enabled = true
    // Replace
    var find = ""
    var replacement = ""
    var regex = false
    var matchCase = false
    // Insert, number and date
    var text = ""
    var placement: Placement = .prefix
    var position = 0
    var separator = " "
    // Case
    var caseStyle: CaseStyle = .lower
    // Number
    var start = 1
    var step = 1
    var padding = 3
    // Date
    var dateSource: DateSource = .modified
    var dateFormat = "yyyy-MM-dd"
    // Trim
    var trimEnds = true
    var collapseSpaces = true
    var dropFirst = 0
    var dropLast = 0
    // Remove
    var characters = ""
    var digits = false
    var punctuation = false
    var spaces = false
    // Extension
    var extensionMode: ExtensionMode = .lower
    var newExtension = ""

    init(kind: RuleKind) {
        self.kind = kind
        if kind == .insert { placement = .suffix }
        if kind == .number { placement = .suffix }
    }

    /// The regex compile error, shown under the Find field.
    var regexError: String? {
        guard kind == .replace, regex, !find.isEmpty else { return nil }
        do { _ = try NSRegularExpression(pattern: find) } catch { return "Not a valid regular expression" }
        return nil
    }
}

/// What the rule engine needs to know about a file.
struct FileMeta {
    var name: String
    var isDirectory = false
    var created: Date?
    var modified: Date?
    var photoTaken: Date?
}

enum Engine {
    /// Splits a file name into base and extension. Folders, dot files and suffixes with spaces have no extension.
    static func split(_ name: String, isDirectory: Bool) -> (base: String, ext: String) {
        guard !isDirectory, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        if ext.isEmpty || ext.contains(" ") || ext.count > 12 { return (name, "") }
        return (String(name[..<dot]), ext)
    }

    static func join(_ base: String, _ ext: String) -> String { ext.isEmpty ? base : base + "." + ext }

    /// New names for `files` in list order. Formatters and regexes are built once per call.
    static func names(for files: [FileMeta], rules: [Rule]) -> [String] {
        let active = rules.filter(\.enabled)
        var formatters: [UUID: DateFormatter] = [:]
        var regexes: [UUID: NSRegularExpression] = [:]
        for rule in active {
            if rule.kind == .date {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = rule.dateFormat
                formatters[rule.id] = f
            }
            if rule.kind == .replace, rule.regex, !rule.find.isEmpty,
               let re = try? NSRegularExpression(pattern: rule.find, options: rule.matchCase ? [] : [.caseInsensitive]) {
                regexes[rule.id] = re
            }
        }
        return files.enumerated().map { index, file in
            var (base, ext) = split(file.name, isDirectory: file.isDirectory)
            for rule in active {
                apply(rule, base: &base, ext: &ext, file: file, index: index, formatter: formatters[rule.id], regex: regexes[rule.id])
            }
            return join(base, ext)
        }
    }

    static func name(for file: FileMeta, index: Int = 0, rules: [Rule]) -> String {
        var files = Array(repeating: FileMeta(name: ""), count: index)
        files.append(file)
        return names(for: files, rules: rules)[index]
    }

    private static func place(_ value: String, in base: inout String, rule: Rule) {
        switch rule.placement {
        case .prefix: base = base.isEmpty ? value : value + rule.separator + base
        case .suffix: base = base.isEmpty ? value : base + rule.separator + value
        case .replace: base = value
        case .index:
            let i = min(max(rule.position, 0), base.count)
            base.insert(contentsOf: value, at: base.index(base.startIndex, offsetBy: i))
        }
    }

    private static func apply(_ rule: Rule, base: inout String, ext: inout String, file: FileMeta, index: Int,
                              formatter: DateFormatter?, regex: NSRegularExpression?) {
        switch rule.kind {
        case .replace:
            guard !rule.find.isEmpty else { return }
            if rule.regex {
                guard let regex else { return }
                base = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base),
                                                      withTemplate: rule.replacement)
            } else {
                base = base.replacingOccurrences(of: rule.find, with: rule.replacement,
                                                 options: rule.matchCase ? [] : [.caseInsensitive])
            }
        case .insert:
            guard !rule.text.isEmpty else { return }
            switch rule.placement {
            case .prefix: base = rule.text + base
            case .suffix: base += rule.text
            case .replace: base = rule.text
            case .index:
                let i = min(max(rule.position, 0), base.count)
                base.insert(contentsOf: rule.text, at: base.index(base.startIndex, offsetBy: i))
            }
        case .changeCase:
            switch rule.caseStyle {
            case .lower: base = base.lowercased()
            case .upper: base = base.uppercased()
            case .title: base = base.capitalized
            case .sentence:
                let lower = base.lowercased()
                base = lower.prefix(1).uppercased() + lower.dropFirst()
            }
        case .number:
            let n = rule.start + index * rule.step
            var digits = String(abs(n))
            if digits.count < rule.padding { digits = String(repeating: "0", count: rule.padding - digits.count) + digits }
            place(n < 0 ? "-" + digits : digits, in: &base, rule: rule)
        case .date:
            let date: Date? = switch rule.dateSource {
            case .created: file.created
            case .modified: file.modified
            case .photo: file.photoTaken ?? file.modified
            }
            guard let date, let formatter, !rule.dateFormat.isEmpty else { return }
            // A slash or colon can never be part of a file name; a date format often has them.
            let value = formatter.string(from: date).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            place(value, in: &base, rule: rule)
        case .trim:
            if rule.dropFirst > 0 { base = String(base.dropFirst(rule.dropFirst)) }
            if rule.dropLast > 0 { base = String(base.dropLast(rule.dropLast)) }
            if rule.collapseSpaces {
                base = base.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            }
            if rule.trimEnds { base = base.trimmingCharacters(in: .whitespacesAndNewlines) }
        case .remove:
            let set = Set(rule.characters)
            base = String(base.filter { ch in
                !(set.contains(ch) || (rule.digits && ch.isNumber) || (rule.punctuation && (ch.isPunctuation || ch.isSymbol))
                    || (rule.spaces && ch.isWhitespace))
            })
        case .fileExtension:
            guard !file.isDirectory else { return }
            switch rule.extensionMode {
            case .lower: ext = ext.lowercased()
            case .upper: ext = ext.uppercased()
            case .remove: ext = ""
            case .set:
                var value = rule.newExtension.trimmingCharacters(in: .whitespaces)
                while value.hasPrefix(".") { value.removeFirst() }
                ext = value
            }
        }
    }

    /// Why `name` cannot be used as a file name, or nil when it can.
    static func problem(with name: String, original: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "The new name is empty" }
        if name == "." || name == ".." { return "Not a valid file name" }
        if name.contains("/") || name.contains(":") { return "Names cannot contain / or :" }
        if name.utf8.count > 255 { return "The new name is too long" }
        if name.hasPrefix("."), !original.hasPrefix(".") { return "A leading dot would hide the file" }
        return nil
    }
}

// MARK: - Planning

enum RowStatus: Equatable {
    case unchanged, rename, conflict(badge: String, reason: String), invalid(String)

    var isProblem: Bool {
        switch self {
        case .conflict, .invalid: true
        default: false
        }
    }

    var reason: String? {
        switch self {
        case .conflict(_, let s), .invalid(let s): s
        default: nil
        }
    }

    /// One word for the table.
    var badge: String? {
        switch self {
        case .conflict(let b, _): b
        case .invalid: "Invalid"
        default: nil
        }
    }
}

struct PlanEntry {
    var id: UUID
    var folder: String
    var original: String
    var target: String
}

enum Planner {
    /// APFS and HFS+ volumes are case insensitive by default, so names are compared folded.
    static func key(_ folder: String, _ name: String) -> String {
        folder + "/" + name.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Decides which entries can be renamed. A file whose target is taken, or shared with another file,
    /// is a conflict and keeps its name; that can free or block others, so it repeats until nothing changes.
    static func plan(_ entries: [PlanEntry], exists: (String, String) -> Bool) -> [UUID: RowStatus] {
        var status: [UUID: RowStatus] = [:]
        var changing = Set<UUID>()
        for e in entries {
            if e.target == e.original {
                status[e.id] = .unchanged
            } else if let problem = Engine.problem(with: e.target, original: e.original) {
                status[e.id] = .invalid(problem)
            } else {
                changing.insert(e.id)
                status[e.id] = .rename
            }
        }
        let listed = Set(entries.map { key($0.folder, $0.original) })
        while true {
            let staying = Set(entries.filter { !changing.contains($0.id) }.map { key($0.folder, $0.original) })
            var counts: [String: Int] = [:]
            for e in entries where changing.contains(e.id) { counts[key(e.folder, e.target), default: 0] += 1 }
            var blocked: [(UUID, String, String)] = []
            for e in entries where changing.contains(e.id) {
                let k = key(e.folder, e.target)
                if counts[k, default: 0] > 1 {
                    blocked.append((e.id, "Duplicate", "Another file would get the same name"))
                } else if staying.contains(k), k != key(e.folder, e.original) {
                    blocked.append((e.id, "Taken", "A file in the list keeps this name"))
                } else if !listed.contains(k), exists(e.folder, e.target) {
                    blocked.append((e.id, "Exists", "A file with this name already exists"))
                }
            }
            if blocked.isEmpty { break }
            for (id, badge, reason) in blocked {
                changing.remove(id)
                status[id] = .conflict(badge: badge, reason: reason)
            }
        }
        return status
    }
}

// MARK: - Renaming

struct Move: Codable, Equatable {
    var from: URL
    var to: URL
    var inverse: Move { Move(from: to, to: from) }
}

struct RenameError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum Renamer {
    /// Renames all or nothing. Every file first moves to a temporary name in its own folder, then to its
    /// target, so swaps (a to b, b to a) and case-only changes work. On any failure everything moves back.
    static func perform(_ moves: [Move], fileManager fm: FileManager = .default) throws {
        guard !moves.isEmpty else { return }
        let token = UUID().uuidString.prefix(8)
        let temps = moves.enumerated().map { i, m in
            m.from.deletingLastPathComponent().appendingPathComponent(".rename-\(token)-\(i)")
        }
        var parked: [Int] = []
        var placed: [Int] = []
        func rollBack() {
            for i in placed.reversed() { try? fm.moveItem(at: moves[i].to, to: temps[i]) }
            for i in parked.reversed() { try? fm.moveItem(at: temps[i], to: moves[i].from) }
        }
        do {
            for (i, m) in moves.enumerated() {
                guard fm.fileExists(atPath: m.from.path) else {
                    throw RenameError(message: "\u{201C}\(m.from.lastPathComponent)\u{201D} is no longer there.")
                }
                try fm.moveItem(at: m.from, to: temps[i])
                parked.append(i)
            }
            for (i, m) in moves.enumerated() {
                if fm.fileExists(atPath: m.to.path) {
                    throw RenameError(message: "\u{201C}\(m.to.lastPathComponent)\u{201D} already exists.")
                }
                try fm.moveItem(at: temps[i], to: m.to)
                placed.append(i)
            }
        } catch {
            rollBack()
            if let error = error as? RenameError { throw error }
            throw RenameError(message: error.localizedDescription)
        }
    }
}

// MARK: - Files

struct FileItem: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var isDirectory = false
    var created: Date?
    var modified: Date?
    var photoTaken: Date?
    var size: Int64 = 0

    var name: String { url.lastPathComponent }
    var folder: String { url.deletingLastPathComponent().path }
    var meta: FileMeta { FileMeta(name: name, isDirectory: isDirectory, created: created, modified: modified, photoTaken: photoTaken) }

    /// Reads dates, size and, for images, the EXIF capture date. Runs off the main thread.
    static func load(_ url: URL) -> FileItem {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey, .contentTypeKey]
        let values = try? url.resourceValues(forKeys: keys)
        var item = FileItem(url: url, isDirectory: values?.isDirectory ?? false, created: values?.creationDate,
                            modified: values?.contentModificationDate, size: Int64(values?.fileSize ?? 0))
        if let type = values?.contentType, type.conforms(to: .image) { item.photoTaken = exifDate(url) }
        return item
    }

    static func exifDate(_ url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        guard let text = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String else { return nil }
        return parseExif(text)
    }

    static func parseExif(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: text)
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, created, modified, photo, size
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: "Name"
        case .created: "Date Created"
        case .modified: "Date Modified"
        case .photo: "Date Taken"
        case .size: "Size"
        }
    }
}

struct Row: Identifiable, Equatable {
    var id: UUID
    var number: Int
    var original: String
    var newName: String
    var status: RowStatus
    var date: Date?
    var isDirectory: Bool
}

// MARK: - Model

@MainActor
final class RenameModel: ObservableObject {
    @Published var items: [FileItem] = [] { didSet { refresh() } }
    @Published var rules: [Rule] = [] { didSet { refresh(); save() } }
    @Published var selection = Set<UUID>()
    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastBatch: [Move] = []
    @Published var loading = 0
    @Published var notice: String?
    @Published var errorMessage: String?

    weak var undoManager: UndoManager?
    private let persist: Bool
    private let exists: (String, String) -> Bool
    private var noticeTask: Task<Void, Never>?

    init(persist: Bool = !Desktop.isSnapshot, exists: @escaping (String, String) -> Bool = RenameModel.diskExists) {
        self.persist = persist
        self.exists = exists
        if persist, let saved = Storage.load([Rule].self, app: "Rename", file: "rules.json") {
            rules = saved
        } else {
            rules = [Rule(kind: .replace)]
        }
        refresh()
    }

    nonisolated static func diskExists(_ folder: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name))
    }

    var renameCount: Int { rows.filter { $0.status == .rename }.count }
    var problemCount: Int { rows.filter { $0.status.isProblem }.count }

    private func save() {
        if persist { Storage.save(rules, app: "Rename", file: "rules.json") }
    }

    private func refresh() {
        let names = Engine.names(for: items.map(\.meta), rules: rules)
        let entries = zip(items, names).map { PlanEntry(id: $0.id, folder: $0.folder, original: $0.name, target: $1) }
        let status = Planner.plan(entries, exists: exists)
        let next = zip(items, names).enumerated().map { i, pair in
            Row(id: pair.0.id, number: i + 1, original: pair.0.name, newName: pair.1, status: status[pair.0.id] ?? .unchanged,
                date: pair.0.modified, isDirectory: pair.0.isDirectory)
        }
        if next != rows { rows = next }
    }

    // MARK: Files

    /// Adds files; a folder adds the visible items inside it, sorted by name.
    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        loading += 1
        Task.detached(priority: .userInitiated) {
            var found: [URL] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue, !url.pathExtension.lowercased().hasSuffix("app"),
                   let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                              options: [.skipsHiddenFiles]) {
                    found += children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                } else {
                    found.append(url)
                }
            }
            var seen = known
            let fresh = found.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }.map(FileItem.load)
            await MainActor.run {
                self.items += fresh
                self.loading -= 1
            }
        }
    }

    func removeSelected() {
        items.removeAll { selection.contains($0.id) }
        selection = []
    }

    func clear() {
        items = []
        selection = []
    }

    func sort(by key: SortKey, ascending: Bool = true) {
        let sorted = items.sorted { a, b in
            let order: ComparisonResult = switch key {
            case .name: a.name.localizedStandardCompare(b.name)
            case .created: Self.compare(a.created, b.created)
            case .modified: Self.compare(a.modified, b.modified)
            case .photo: Self.compare(a.photoTaken ?? a.modified, b.photoTaken ?? b.modified)
            case .size: a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
            }
            if order == .orderedSame { return a.name.localizedStandardCompare(b.name) == .orderedAscending }
            return ascending ? order == .orderedAscending : order == .orderedDescending
        }
        withAnimation(.snappy) { items = sorted }
    }

    private static func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        (a ?? .distantPast).compare(b ?? .distantPast)
    }

    func reverse() { withAnimation(.snappy) { items.reverse() } }

    /// Moves the selected files one place up (-1) or down (+1), keeping their relative order.
    func moveSelection(_ delta: Int) {
        guard !selection.isEmpty else { return }
        var list = items
        let indices = list.indices.filter { selection.contains(list[$0].id) }
        if delta < 0 {
            guard indices.first! > 0 else { return }
            for i in indices { list.swapAt(i, i - 1) }
        } else {
            guard indices.last! < list.count - 1 else { return }
            for i in indices.reversed() { list.swapAt(i, i + 1) }
        }
        withAnimation(.snappy) { items = list }
    }

    var canMoveUp: Bool { !selection.isEmpty && !(items.first.map { selection.contains($0.id) } ?? true) }
    var canMoveDown: Bool { !selection.isEmpty && !(items.last.map { selection.contains($0.id) } ?? true) }

    // MARK: Rules

    func addRule(_ kind: RuleKind) {
        withAnimation(.snappy) { rules.append(Rule(kind: kind)) }
    }

    func deleteRule(_ id: UUID) {
        withAnimation(.snappy) { rules.removeAll { $0.id == id } }
    }

    func moveRule(_ id: UUID, by delta: Int) {
        guard let i = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(i + delta) else { return }
        withAnimation(.snappy) { rules.swapAt(i, i + delta) }
    }

    func resetRules() {
        withAnimation(.snappy) { rules = [Rule(kind: .replace)] }
    }

    // MARK: Renaming

    func apply() {
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let moves = rows.compactMap { row -> Move? in
            guard row.status == .rename, let item = byID[row.id] else { return nil }
            return Move(from: item.url, to: item.url.deletingLastPathComponent().appendingPathComponent(row.newName))
        }
        guard !moves.isEmpty else { return }
        if run(moves) {
            lastBatch = moves
            show("Renamed \(moves.count) \(moves.count == 1 ? "file" : "files").")
        }
    }

    /// Reverts the last batch from the toolbar or the File menu.
    func undoLastBatch() {
        guard !lastBatch.isEmpty else { return }
        let batch = lastBatch
        undoManager?.removeAllActions(withTarget: self)
        if run(batch.reversed().map(\.inverse), register: false) {
            lastBatch = []
            show("Restored \(batch.count) original \(batch.count == 1 ? "name" : "names").")
        }
    }

    /// Performs `moves`, updates the list and registers the inverse with the window's undo manager.
    @discardableResult
    private func run(_ moves: [Move], register: Bool = true) -> Bool {
        do {
            try Renamer.perform(moves)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let map = Dictionary(moves.map { ($0.from.standardizedFileURL.path, $0.to) }, uniquingKeysWith: { a, _ in a })
        items = items.map { item in
            guard let to = map[item.url.standardizedFileURL.path] else { return item }
            var item = item
            item.url = to
            return item
        }
        if register, let undoManager {
            let inverse = moves.reversed().map(\.inverse)
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.run(inverse)
                    model.lastBatch = model.lastBatch == moves ? [] : inverse
                }
            }
            undoManager.setActionName("Rename \(moves.count) \(moves.count == 1 ? "File" : "Files")")
        }
        return true
    }

    func revealSelected() {
        let chosen = items.filter { selection.contains($0.id) }.map(\.url)
        revealInFinder(chosen.isEmpty ? items.map(\.url) : chosen)
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { notice = text }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { self?.notice = nil }
        }
    }
}

// MARK: - Demo

extension RenameModel {
    static var demo: RenameModel {
        let folder = URL(fileURLWithPath: "/Users/demo/Pictures/Lisbon")
        let model = RenameModel(persist: false) { _, name in name == "2026-06-15 Lisbon 007.jpg" }
        let base = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 6, day: 14, hour: 9, minute: 12).date!
        let names = ["IMG_4012.JPG", "IMG_4013.JPG", "IMG_4017.JPG", "IMG_4018.JPG", "IMG_4021.HEIC", "IMG_4022.JPG",
                     "IMG_4030.JPG", "IMG_4031.JPG", "IMG_4035.HEIC", "IMG_4040.JPG", "IMG_4041.JPG", "IMG_4046.JPG",
                     "IMG_4050.JPG", "IMG_4052.JPG", "IMG_4057.JPG", "IMG_4061.HEIC", "IMG_4064.JPG", "IMG_4070.JPG",
                     "IMG_4072.JPG", "IMG_4075.JPG"]
        model.items = names.enumerated().map { i, name in
            let taken = base.addingTimeInterval(Double(i) * 3600 * 4.3)
            return FileItem(url: folder.appendingPathComponent(name), created: taken, modified: taken, photoTaken: taken,
                            size: Int64(2_400_000 + i * 91_000))
        }
        var replace = Rule(kind: .replace)
        replace.find = "^IMG_\\d+"
        replace.replacement = "Lisbon"
        replace.regex = true
        var number = Rule(kind: .number)
        number.padding = 3
        var date = Rule(kind: .date)
        date.dateSource = .photo
        var ext = Rule(kind: .fileExtension)
        ext.extensionMode = .lower
        model.rules = [replace, number, date, ext]
        model.selection = [model.items[2].id]
        return model
    }
}
