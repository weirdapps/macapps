import AppKit
import Foundation
import Kit
import SwiftUI

// MARK: - Bytes

/// The read-only bytes of a file, memory-mapped so a multi-gigabyte file costs nothing until a page is touched.
final class ByteSource: @unchecked Sendable {
    let data: NSData
    var count: Int { data.length }

    init(data: NSData) { self.data = data }

    /// Files up to this size are copied into memory instead of mapped.
    static let mapThreshold = 64 << 20

    static func open(_ url: URL) throws -> ByteSource {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw HexError("This file no longer exists.")
        }
        if isDirectory.boolValue { throw HexError("Hex opens files, not folders.") }
        do {
            // Small files are read into memory, so another app truncating them cannot crash the viewer. Big ones are
            // mapped, which keeps a multi-gigabyte file instant.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
            return ByteSource(data: try NSData(contentsOf: url, options: size <= mapThreshold ? [] : [.alwaysMapped]))
        } catch {
            throw HexError("Hex could not read this file. \(error.localizedDescription)")
        }
    }

    subscript(i: Int) -> UInt8 { data.bytes.load(fromByteOffset: i, as: UInt8.self) }

    /// The bytes in `range`, clamped to the file.
    func bytes(_ range: Range<Int>) -> [UInt8] {
        let lo = max(0, range.lowerBound), hi = min(count, range.upperBound)
        guard lo < hi else { return [] }
        return Array(UnsafeRawBufferPointer(start: data.bytes + lo, count: hi - lo))
    }

    /// The first offset of `needle` whose start lies in `starts`, scanning forwards or backwards.
    /// Works in chunks so a search through gigabytes can report progress and stop when `cancelled` says so.
    func find(_ needle: [UInt8], starts: Range<Int>, backwards: Bool,
              cancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in }) -> Int? {
        let n = needle.count
        guard n > 0, n <= count else { return nil }
        let lo = max(0, starts.lowerBound), hi = min(count - n + 1, starts.upperBound)
        guard lo < hi else { return nil }
        let base = data.bytes.assumingMemoryBound(to: UInt8.self)
        let first = needle[0]
        let chunk = 8 << 20
        let total = Double(hi - lo)
        return needle.withUnsafeBufferPointer { nb -> Int? in
            if !backwards {
                var i = lo
                while i < hi {
                    let end = min(hi, i + chunk)
                    while i < end {
                        guard let hit = memchr(base + i, Int32(first), end - i) else { i = end; break }
                        let at = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                        if memcmp(base + at, nb.baseAddress!, n) == 0 { return at }
                        i = at + 1
                    }
                    if cancelled() { return nil }
                    progress(Double(i - lo) / total)
                }
            } else {
                var i = hi - 1
                while i >= lo {
                    let end = max(lo, i - chunk + 1)
                    while i >= end {
                        if base[i] == first, memcmp(base + i, nb.baseAddress!, n) == 0 { return i }
                        i -= 1
                    }
                    if cancelled() { return nil }
                    progress(Double(hi - 1 - i) / total)
                }
            }
            return nil
        }
    }
}

struct HexError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Formatting and parsing

enum HexFormat {
    static let digits = Array("0123456789ABCDEF")
    /// Two uppercase hex digits for every byte value, built once.
    static let byteStrings: [String] = (0..<256).map { String([digits[$0 >> 4], digits[$0 & 15]]) }

    /// Hex digits the offset column needs: 8, or more for files past 4 GB, always even.
    static func offsetDigits(forCount count: Int) -> Int {
        var digits = 1, v = max(0, count - 1)
        while v > 15 { v >>= 4; digits += 1 }
        return max(8, digits + digits % 2)
    }

    static func hex(_ value: Int, digits: Int) -> String {
        let s = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - s.count)) + s
    }

    /// The ASCII column's character for a byte: printable ASCII as itself, everything else as a dot.
    static func ascii(_ b: UInt8) -> Character { (0x20...0x7E).contains(b) ? Character(UnicodeScalar(b)) : "." }

    /// "DE AD BE EF".
    static func hexString(_ bytes: [UInt8]) -> String { bytes.map { byteStrings[Int($0)] }.joined(separator: " ") }

    /// Text for the clipboard: UTF-8 when the bytes are valid UTF-8, else the ASCII column. Control characters other than
    /// tab and line breaks become dots either way.
    static func text(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) {
            return String(String.UnicodeScalarView(s.unicodeScalars.map { sc in
                sc.value < 0x20 && sc != "\t" && sc != "\n" && sc != "\r" || sc.value == 0x7F ? "." : sc
            }))
        }
        return String(bytes.map(ascii))
    }

    /// Hex bytes typed by a person: "DE AD be ef", "0xDEADBEEF", "de,ad". Nil unless it is a whole number of bytes.
    static func parseHexBytes(_ input: String) -> [UInt8]? {
        var s = input.lowercased().replacingOccurrences(of: "0x", with: "")
        s.removeAll { $0.isWhitespace || $0 == "," || $0 == ":" || $0 == "-" }
        guard !s.isEmpty, s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
        return out
    }

    /// An offset typed into Jump to Offset: decimal, hex with 0x, an h suffix or any a to f digit, and + or - for a move
    /// relative to `current`. Nil when it is not a number or lies outside a file of `count` bytes.
    static func parseOffset(_ input: String, current: Int, count: Int) -> Int? {
        var s = input.trimmingCharacters(in: .whitespaces).lowercased()
        s.removeAll { $0 == "_" || $0 == " " || $0 == "," }
        var sign = 0
        if s.hasPrefix("+") { sign = 1; s.removeFirst() } else if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        var radix = 10
        if s.hasPrefix("0x") { radix = 16; s.removeFirst(2) } else if s.hasSuffix("h") { radix = 16; s.removeLast() }
        if s.contains(where: { ("a"..."f").contains($0) }) { radix = 16 }
        guard !s.isEmpty, let value = Int(s, radix: radix) else { return nil }
        let result: Int
        if sign == 0 {
            result = value
        } else {
            let (moved, overflow) = current.addingReportingOverflow(sign * value)
            guard !overflow else { return nil }
            result = moved
        }
        guard count > 0, (0..<count).contains(result) else { return nil }
        return result
    }

    static func size(_ count: Int) -> String {
        count < 1024 ? "\(count) bytes" : ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - Inspector

struct InspectorRow: Identifiable, Equatable {
    let name: String
    let value: String
    var id: String { name }
}

enum Inspector {
    /// The user's locale, or a fixed English one for the website screenshot.
    static let locale = Desktop.isSnapshot ? Locale(identifier: "en_US") : Locale.current

    static func count(_ n: Int) -> String { n.formatted(.number.locale(locale)) }

    /// The selection start read as every common type, from up to 8 `bytes` starting there. A type needing more
    /// bytes than remain in the file shows a dash.
    static func rows(_ bytes: [UInt8], bigEndian: Bool) -> [InspectorRow] {
        func raw(_ n: Int) -> UInt64? {
            guard bytes.count >= n else { return nil }
            let slice = bytes.prefix(n)
            return (bigEndian ? Array(slice) : slice.reversed()).reduce(0) { $0 << 8 | UInt64($1) }
        }
        func show(_ v: String?) -> String { v ?? "-" }
        let fmt = IntegerFormatStyle<Int64>(locale: locale)
        let ufmt = IntegerFormatStyle<UInt64>(locale: locale)
        return [
            InspectorRow(name: "Int8", value: show(raw(1).map { "\(Int8(bitPattern: UInt8($0)))" })),
            InspectorRow(name: "UInt8", value: show(raw(1).map { "\($0)" })),
            InspectorRow(name: "Int16", value: show(raw(2).map { fmt.format(Int64(Int16(bitPattern: UInt16($0)))) })),
            InspectorRow(name: "UInt16", value: show(raw(2).map { ufmt.format($0) })),
            InspectorRow(name: "Int32", value: show(raw(4).map { fmt.format(Int64(Int32(bitPattern: UInt32($0)))) })),
            InspectorRow(name: "UInt32", value: show(raw(4).map { ufmt.format($0) })),
            InspectorRow(name: "Int64", value: show(raw(8).map { fmt.format(Int64(bitPattern: $0)) })),
            InspectorRow(name: "UInt64", value: show(raw(8).map { ufmt.format($0) })),
            InspectorRow(name: "Float", value: show(raw(4).map { number(Double(Float(bitPattern: UInt32($0)))) })),
            InspectorRow(name: "Double", value: show(raw(8).map { number(Double(bitPattern: $0)) })),
            InspectorRow(name: "Binary", value: show(bytes.first.map(binary))),
        ]
    }

    static func number(_ v: Double) -> String {
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
        if v == 0 { return "0" }
        if abs(v) >= 1e-4 && abs(v) < 1e15 {
            return v.formatted(.number.precision(.significantDigits(1...10)).grouping(.never).locale(locale))
        }
        return v.formatted(.number.notation(.scientific).precision(.significantDigits(1...8)).locale(locale))
    }

    static func binary(_ b: UInt8) -> String {
        let s = String(b, radix: 2)
        let padded = String(repeating: "0", count: 8 - s.count) + s
        return padded.prefix(4) + " " + padded.suffix(4)
    }

    /// The selection as UTF-8 text, or nil when it is not valid UTF-8. When `truncated` says the bytes are only the
    /// start of a longer selection, a character cut off at the end is dropped rather than failing the whole decode.
    static func utf8(_ bytes: [UInt8], truncated: Bool = false) -> String? {
        guard !bytes.isEmpty else { return nil }
        for drop in 0...(truncated ? min(3, bytes.count - 1) : 0) {
            if let s = String(bytes: bytes.dropLast(drop), encoding: .utf8) { return HexFormat.text(Array(s.utf8)) }
        }
        return nil
    }
}

// MARK: - Bookmarks

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var offset: Int
    var length: Int
    var name: String
}

enum BookmarkStore {
    static let file = "bookmarks.json"

    static func load(for path: String) -> [Bookmark] {
        Storage.load([String: [Bookmark]].self, app: "Hex", file: file)?[path] ?? []
    }

    static func save(_ bookmarks: [Bookmark], for path: String) {
        guard !Desktop.isSnapshot else { return }
        var all = Storage.load([String: [Bookmark]].self, app: "Hex", file: file) ?? [:]
        let new = bookmarks.isEmpty ? nil : bookmarks
        guard all[path] != new else { return }
        all[path] = new
        Storage.save(all, app: "Hex", file: file)
    }
}

// MARK: - Window model

enum Column { case hex, text }
enum FindMode: String, CaseIterable { case text = "Text", hex = "Hex" }

/// One window's file, selection, bookmarks and search.
@MainActor
final class HexModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var source: ByteSource?
    @Published private(set) var error: String?
    @Published var anchor = 0
    @Published var cursor = 0
    @Published var column: Column = .hex
    @Published var bookmarks: [Bookmark] = [] { didSet { if persists, let url { BookmarkStore.save(bookmarks, for: url.path) } } }
    @Published var showInspector = true
    @Published var showFind = false
    @Published var findText = ""
    @Published var findMode: FindMode = .text
    @Published private(set) var findStatus: String?
    @Published private(set) var searchProgress: Double?
    @Published var showJump = false
    @Published private(set) var findFocusToken = 0
    @Published var bigEndian = !Desktop.isSnapshot && UserDefaults.standard.bool(forKey: "bigEndian") {
        didSet { if persists, !Desktop.isSnapshot { UserDefaults.standard.set(bigEndian, forKey: "bigEndian") } }
    }
    @Published var editingBookmark: Bookmark.ID?
    /// Bumped when the grid should scroll the cursor into view (a jump, a find, a bookmark).
    @Published private(set) var revealToken = 0
    /// Bumped when the grid should take keyboard focus back.
    @Published private(set) var focusToken = 0

    private var searchTask: Task<Void, Never>?
    /// The window showing the grid, so opening the same file again brings it forward.
    weak var window: NSWindow?
    /// False for demo and test models, which never write bookmarks to disk.
    private var persists = true

    var count: Int { source?.count ?? 0 }
    var hasBytes: Bool { count > 0 }
    var selection: ClosedRange<Int> { min(anchor, cursor)...max(anchor, cursor) }
    var selectionLength: Int { hasBytes ? selection.count : 0 }

    init() {}

    init(demo: [UInt8], name: String, cursor: Int, length: Int, bookmarks: [Bookmark]) {
        persists = false
        url = URL(fileURLWithPath: "/tmp/\(name)")
        source = ByteSource(data: NSData(bytes: demo, length: demo.count))
        anchor = cursor
        self.cursor = cursor + length - 1
        self.bookmarks = bookmarks
        bigEndian = true
    }

    func load(_ url: URL) {
        searchTask?.cancel()
        self.url = url
        do {
            source = try ByteSource.open(url)
            error = nil
        } catch {
            source = nil
            self.error = error.localizedDescription
        }
        anchor = 0
        cursor = 0
        findStatus = nil
        bookmarks = BookmarkStore.load(for: url.path)
        revealToken += 1
    }

    // MARK: Selection

    func select(_ range: ClosedRange<Int>, reveal: Bool = true) {
        guard hasBytes else { return }
        anchor = min(max(0, range.lowerBound), count - 1)
        cursor = min(max(0, range.upperBound), count - 1)
        if reveal { revealToken += 1 }
    }

    func selectAll() {
        guard hasBytes else { return }
        select(0...count - 1, reveal: false)
    }

    var selectedBytes: [UInt8] { source?.bytes(selection.lowerBound..<(selection.upperBound + 1)) ?? [] }

    /// At most `limit` bytes from the start of the selection, without copying the rest of a huge selection.
    func selectedBytes(prefix limit: Int) -> [UInt8] {
        source?.bytes(selection.lowerBound..<(selection.lowerBound + min(limit, selection.count))) ?? []
    }

    /// Up to 8 bytes from the selection start, for the value inspector.
    var inspectedBytes: [UInt8] { source?.bytes(selection.lowerBound..<(selection.lowerBound + 8)) ?? [] }

    // MARK: Copy

    static let copyLimit = 32 << 20

    func copy(as column: Column? = nil) {
        guard hasBytes, !Desktop.isSnapshot else { return }
        guard selectionLength <= Self.copyLimit else {
            NSSound.beep()
            findStatus = "Select 32 MB or less to copy."
            return
        }
        let bytes = selectedBytes
        let text = (column ?? self.column) == .hex ? HexFormat.hexString(bytes) : HexFormat.text(bytes)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Jump

    func jump(to input: String) -> Bool {
        guard let offset = HexFormat.parseOffset(input, current: cursor, count: count) else { return false }
        select(offset...offset)
        focusToken += 1
        return true
    }

    // MARK: Find

    var needle: [UInt8]? {
        switch findMode {
        case .text: findText.isEmpty ? nil : Array(findText.utf8)
        case .hex: HexFormat.parseHexBytes(findText)
        }
    }

    func beginFind() {
        showFind = true
        findFocusToken += 1
    }

    func useSelectionForFind() {
        guard hasBytes else { return }
        let bytes = selectedBytes(prefix: 256)
        if let s = String(bytes: bytes, encoding: .utf8), !s.contains(where: { $0.isASCII && $0.asciiValue! < 0x20 }) {
            findMode = .text
            findText = s
        } else {
            findMode = .hex
            findText = HexFormat.hexString(bytes)
        }
        beginFind()
    }

    /// Searches from just past the selection (or just before it), wrapping once around the file.
    func find(backwards: Bool = false) {
        guard let source, hasBytes else { return }
        guard let needle else {
            findStatus = findText.isEmpty ? nil : "Type whole bytes, like DE AD BE EF."
            if !findText.isEmpty { NSSound.beep() }
            return
        }
        searchTask?.cancel()
        let start = selection.lowerBound, n = source.count
        findStatus = nil
        searchProgress = n > (64 << 20) ? 0 : nil
        searchTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (Int?, Bool) in
                var lastReport = 0.0
                let report: (Double) -> Void = { p in
                    guard p - lastReport > 0.02 else { return }
                    lastReport = p
                    Task { @MainActor in if self?.searchProgress != nil { self?.searchProgress = p } }
                }
                let cancelled = { Task.isCancelled }
                if !backwards {
                    if let hit = source.find(needle, starts: (start + 1)..<n, backwards: false, cancelled: cancelled, progress: report) {
                        return (hit, false)
                    }
                    return (source.find(needle, starts: 0..<(start + 1), backwards: false, cancelled: cancelled), true)
                } else {
                    if let hit = source.find(needle, starts: 0..<start, backwards: true, cancelled: cancelled, progress: report) {
                        return (hit, false)
                    }
                    return (source.find(needle, starts: start..<n, backwards: true, cancelled: cancelled), true)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.searchProgress = nil
            if let hit = result.0 {
                self.column = self.findMode == .hex ? .hex : .text
                self.select(hit...(hit + needle.count - 1))
                self.findStatus = result.1 ? "Wrapped around" : nil
            } else {
                NSSound.beep()
                self.findStatus = "Not found"
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchProgress = nil
    }

    func closeFind() {
        cancelSearch()
        showFind = false
        findStatus = nil
        focusToken += 1
    }

    // MARK: Bookmarks

    func addBookmark() {
        guard hasBytes else { return }
        let sel = selection
        if let existing = bookmarks.first(where: { $0.offset == sel.lowerBound && $0.length == sel.count }) {
            editingBookmark = existing.id
            return
        }
        let mark = Bookmark(offset: sel.lowerBound, length: sel.count,
                            name: "Bookmark \(bookmarks.count + 1)")
        bookmarks.append(mark)
        bookmarks.sort { $0.offset < $1.offset }
        editingBookmark = mark.id
        showInspector = true
    }

    func go(to mark: Bookmark) {
        select(mark.offset...(mark.offset + max(1, mark.length) - 1))
        focusToken += 1
    }

    func finishRename() {
        editingBookmark = nil
        if let i = bookmarks.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            bookmarks[i].name = "Bookmark \(i + 1)"
        }
        focusToken += 1
    }

    func remove(_ mark: Bookmark) { bookmarks.removeAll { $0.id == mark.id } }

    func goToBookmark(next: Bool) {
        let at = selection.lowerBound
        let target = next ? bookmarks.first { $0.offset > at } ?? bookmarks.first
                          : bookmarks.last { $0.offset < at } ?? bookmarks.last
        if let target { go(to: target) } else { NSSound.beep() }
    }

    /// True when byte `i` lies inside a bookmark, for the grid's markers.
    func isBookmarked(_ i: Int) -> Bool {
        bookmarks.contains { i >= $0.offset && i < $0.offset + max(1, $0.length) }
    }
}

// MARK: - Opening files

/// Routes files from Finder, the Dock and Open to windows: an empty window takes the first, others open new windows.
@MainActor
final class OpenRouter {
    static let shared = OpenRouter()
    var openWindow: OpenWindowAction?
    private var emptyWindows: [(id: UUID, claim: (URL) -> Void)] = []
    private var pending: [URL] = []
    private let viewers = NSHashTable<HexModel>.weakObjects()

    func register(_ model: HexModel) {
        viewers.add(model)
        // Files that arrived before any window existed (a launch from Finder into restored windows).
        if !pending.isEmpty {
            DispatchQueue.main.async {
                let urls = self.pending
                self.pending.removeAll()
                self.open(urls)
            }
        }
    }

    func registerEmpty(_ id: UUID, claim: @escaping (URL) -> Void) {
        emptyWindows.removeAll { $0.id == id }
        emptyWindows.append((id, claim))
        if !pending.isEmpty {
            let urls = pending
            pending.removeAll()
            open(urls)
        }
    }

    func unregister(_ id: UUID) { emptyWindows.removeAll { $0.id == id } }

    func unregister(_ model: HexModel) { viewers.remove(model) }

    func open(_ urls: [URL]) {
        for url in urls {
            if let open = viewers.allObjects.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
                open.window?.makeKeyAndOrderFront(nil)
            } else if !emptyWindows.isEmpty {
                emptyWindows.removeFirst().claim(url)
            } else if let openWindow {
                openWindow(value: url)
            } else {
                pending.append(url)
            }
        }
    }

    /// Shows an open panel and routes the chosen files.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose any file. Hex reads it without changing a byte."
        if panel.runModal() == .OK { open(panel.urls) }
    }
}
