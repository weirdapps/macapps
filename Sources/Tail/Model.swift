import AppKit
import Foundation
import Kit
import SwiftUI

// MARK: - Lines

/// Splits a byte stream into lines, holding back an unfinished last line until its newline arrives.
/// Works on bytes, so a UTF-8 character split across two reads still decodes correctly.
struct LineSplitter {
    private(set) var partial = Data()

    mutating func feed(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var buffer = partial
        buffer.append(data)
        var lines: [String] = []
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            lines.append(Self.decode(buffer[start..<newline]))
            start = buffer.index(after: newline)
        }
        partial = Data(buffer[start...])
        return lines
    }

    /// Returns the unfinished line, if any, and forgets it.
    mutating func flush() -> String? {
        guard !partial.isEmpty else { return nil }
        defer { partial = Data() }
        return Self.decode(partial)
    }

    mutating func reset() { partial = Data() }

    /// UTF-8 (invalid bytes become U+FFFD), without a trailing carriage return or terminal colour codes.
    static func decode(_ bytes: Data) -> String {
        var bytes = bytes
        if bytes.last == 0x0D { bytes.removeLast() }
        let text = String(decoding: bytes, as: UTF8.self)
        return text.contains("\u{1B}") ? stripEscapes(text) : text
    }

    /// Removes ANSI escape sequences such as `ESC[31m`.
    static func stripEscapes(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var iterator = text.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            guard scalar == "\u{1B}" else { out.unicodeScalars.append(scalar); continue }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameters, then one final byte in @...~.
                while let c = iterator.next(), !(0x40...0x7E).contains(c.value) {}
            }
        }
        return out
    }
}

// MARK: - Reading the tail

/// Reads the last lines of a file by walking backwards from its end, so a 1 GB log costs only its tail.
enum TailReader {
    struct Result: Equatable {
        var lines: [String]
        /// True when the whole file was read, so the first line is complete.
        var reachedStart: Bool
        var size: UInt64
    }

    static let chunkSize = 64 << 10
    static let maxBytes = 32 << 20

    static func read(url: URL, lines count: Int, chunk: Int = chunkSize, maxBytes: Int = maxBytes) throws -> Result {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
        return read(fd: fd, size: UInt64(info.st_size), lines: count, chunk: chunk, maxBytes: maxBytes)
    }

    static func read(fd: Int32, size: UInt64, lines count: Int, chunk: Int = chunkSize, maxBytes: Int = maxBytes) -> Result {
        guard count > 0, size > 0 else { return Result(lines: [], reachedStart: true, size: size) }
        var position = size
        var chunks: [Data] = []
        var newlines = 0
        var total = 0
        // One newline more than the lines wanted proves the first of them is complete.
        while position > 0, newlines <= count, total < maxBytes {
            let length = Int(min(UInt64(chunk), position))
            position -= UInt64(length)
            let data = pread(fd, offset: position, count: length)
            guard data.count == length else { break }
            newlines += data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            total += length
            chunks.append(data)
        }
        var data = Data(capacity: total)
        for piece in chunks.reversed() { data.append(piece) }
        var splitter = LineSplitter()
        var lines = splitter.feed(data)
        if let last = splitter.flush() { lines.append(last) }
        if position > 0, !lines.isEmpty { lines.removeFirst() }
        if lines.count > count { lines.removeFirst(lines.count - count) }
        return Result(lines: lines, reachedStart: position == 0, size: size)
    }

    static func pread(_ fd: Int32, offset: UInt64, count: Int) -> Data {
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { Darwin.pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard read > 0 else { return Data() }
        data.count = read
        return data
    }
}

// MARK: - Following

/// Follows one path like `tail -F`: new lines as they are written, truncation, rotation and files that vanish and return.
/// A file system event source gives instant updates; a slow poll catches what events miss (a new file at the same path).
/// All state lives on a private serial queue; `handler` is called on that queue.
final class Follower: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case loaded(lines: [String], reachedStart: Bool, size: UInt64)
        case appended([String], size: UInt64)
        case truncated
        case rotated
        case missing
    }

    let path: String
    private let initialLines: Int
    private let pollInterval: Double
    private let staleAfter: Double
    private let handler: @Sendable (Event) -> Void
    private let queue = DispatchQueue(label: "Tail.Follower")
    private var fd: Int32 = -1
    private var inode: UInt64 = 0
    private var offset: UInt64 = 0
    private var splitter = LineSplitter()
    private var partialSince: Date?
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var hasLoaded = false
    private var isMissing = false

    /// Catching up on more than this many new bytes at once reads only their tail.
    static let maxCatchUp: UInt64 = 16 << 20
    private static let readChunk = 1 << 20

    init(path: String, initialLines: Int, pollInterval: Double = 1, staleAfter: Double = 1,
         handler: @escaping @Sendable (Event) -> Void) {
        self.path = path
        self.initialLines = initialLines
        self.pollInterval = pollInterval
        self.staleAfter = staleAfter
        self.handler = handler
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.openFile()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.pollInterval, repeating: self.pollInterval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.closeFile()
        }
    }

    private func openFile() {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            if !isMissing { isMissing = true; handler(.missing) }
            return
        }
        var info = stat()
        fstat(fd, &info)
        self.fd = fd
        inode = UInt64(info.st_ino)
        isMissing = false
        splitter.reset()
        partialSince = nil
        let size = UInt64(info.st_size)
        if hasLoaded {
            // A new file at the path: rotation, or the file came back. Its lines are all new.
            handler(.rotated)
            offset = 0
            readNew()
        } else {
            hasLoaded = true
            let tail = TailReader.read(fd: fd, size: size, lines: initialLines)
            offset = size
            handler(.loaded(lines: tail.lines, reachedStart: tail.reachedStart, size: size))
        }
        watch(fd)
    }

    private func watch(_ fd: Int32) {
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke],
                                                               queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if source.data.contains(.delete) || source.data.contains(.rename) || source.data.contains(.revoke) {
                self.poll()
            } else {
                self.readNew()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func closeFile() {
        source?.cancel()
        source = nil
        fd = -1
    }

    /// Reads whatever was appended since the last read, noticing truncation on the way.
    private func readNew() {
        guard fd >= 0 else { return }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let size = UInt64(info.st_size)
        if size < offset {
            splitter.reset()
            partialSince = nil
            offset = 0
            handler(.truncated)
        }
        guard size > offset else { return }
        if size - offset > Self.maxCatchUp {
            let tail = TailReader.read(fd: fd, size: size, lines: initialLines)
            splitter.reset()
            partialSince = nil
            offset = size
            handler(.appended(tail.lines, size: size))
            return
        }
        var lines: [String] = []
        while offset < size {
            let data = TailReader.pread(fd, offset: offset, count: Int(min(UInt64(Self.readChunk), size - offset)))
            if data.isEmpty { break }
            offset += UInt64(data.count)
            lines += splitter.feed(data)
        }
        partialSince = splitter.partial.isEmpty ? nil : Date()
        if !lines.isEmpty { handler(.appended(lines, size: size)) }
    }

    /// Checks the path itself: gone, replaced by a new file, or just grown without an event.
    private func poll() {
        var info = stat()
        if stat(path, &info) != 0 {
            if fd >= 0 { readNew(); closeFile() }
            if !isMissing { isMissing = true; handler(.missing) }
            return
        }
        if fd < 0 { openFile(); return }
        if UInt64(info.st_ino) != inode {
            readNew()
            closeFile()
            openFile()
            return
        }
        readNew()
        // A line without its newline yet: show it once the writer has paused for a moment.
        if let since = partialSince, Date().timeIntervalSince(since) >= staleAfter, let line = splitter.flush() {
            partialSince = nil
            handler(.appended([line], size: offset))
        }
    }
}

// MARK: - Highlighting and filtering

enum Tone: String, Codable, CaseIterable, Identifiable, Sendable {
    case red, orange, yellow, green, mint, teal, blue, purple, pink, gray

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .mint: .systemMint
        case .teal: .systemTeal
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .gray: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

struct HighlightRule: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var word: String
    var tone: Tone
    var isEnabled = true

    static let defaults: [HighlightRule] = [
        HighlightRule(word: "FATAL", tone: .red),
        HighlightRule(word: "ERROR", tone: .red),
        HighlightRule(word: "CRITICAL", tone: .red),
        HighlightRule(word: "WARN", tone: .orange),
        HighlightRule(word: "WARNING", tone: .orange),
        HighlightRule(word: "NOTICE", tone: .purple),
        HighlightRule(word: "INFO", tone: .blue),
        HighlightRule(word: "DEBUG", tone: .gray),
        HighlightRule(word: "TRACE", tone: .gray),
    ]
}

/// Highlight rules compiled to whole-word, any-case patterns. The first enabled rule that matches gives a line its tone.
struct Highlighter {
    private let compiled: [(regex: NSRegularExpression, tone: Tone)]

    init(rules: [HighlightRule]) {
        compiled = rules.compactMap { rule in
            let word = rule.word.trimmingCharacters(in: .whitespaces)
            guard rule.isEnabled, !word.isEmpty else { return nil }
            let pattern = "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, rule.tone)
        }
    }

    func tone(of line: String) -> Tone? {
        let range = NSRange(line.startIndex..., in: line)
        return compiled.first { $0.regex.firstMatch(in: line, range: range) != nil }?.tone
    }

    func matches(in line: String) -> [(range: NSRange, tone: Tone)] {
        let range = NSRange(line.startIndex..., in: line)
        return compiled.flatMap { rule in rule.regex.matches(in: line, range: range).map { ($0.range, rule.tone) } }
    }
}

/// The filter field: everything, a plain any-case substring, or a regular expression.
enum LineMatcher {
    case all
    case plain(String)
    case regex(NSRegularExpression)
    case invalid

    init(text: String, isRegex: Bool) {
        if text.isEmpty {
            self = .all
        } else if isRegex {
            if let regex = try? NSRegularExpression(pattern: text, options: .caseInsensitive) { self = .regex(regex) } else { self = .invalid }
        } else {
            self = .plain(text)
        }
    }

    var isActive: Bool {
        switch self {
        case .plain, .regex: true
        case .all, .invalid: false
        }
    }

    var isInvalid: Bool { if case .invalid = self { true } else { false } }

    /// An invalid pattern hides nothing, so a half-typed expression never blanks the view.
    func matches(_ line: String) -> Bool {
        switch self {
        case .all, .invalid: true
        case .plain(let text): line.range(of: text, options: .caseInsensitive) != nil
        case .regex(let regex): regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
    }

    func ranges(in line: String) -> [NSRange] {
        switch self {
        case .all, .invalid:
            return []
        case .plain(let text):
            var out: [NSRange] = []
            let ns = line as NSString
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let found = ns.range(of: text, options: .caseInsensitive, range: search)
                if found.location == NSNotFound || found.length == 0 { break }
                out.append(found)
                search = NSRange(location: found.upperBound, length: ns.length - found.upperBound)
            }
            return out
        case .regex(let regex):
            return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).map(\.range).filter { $0.length > 0 }
        }
    }
}

// MARK: - One open log

struct LogLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    var isNotice = false
    var tone: Tone?
}

@MainActor
final class LogSource: ObservableObject, Identifiable {
    enum State: Equatable {
        case loading, following, waiting
    }

    let id = UUID()
    let url: URL
    @Published private(set) var lines: [LogLine] = []
    /// The lines the filter lets through, plus notices. Ids only ever grow, so views can append by id.
    @Published private(set) var visible: [LogLine] = []
    @Published private(set) var state = State.loading
    @Published private(set) var isPaused = false
    @Published private(set) var pendingCount = 0
    @Published private(set) var errorCount = 0
    @Published private(set) var size: UInt64 = 0
    /// Lines that arrived while auto-scroll was off.
    @Published private(set) var unseen = 0
    /// Auto-scroll: on while the view sits at the bottom, off once the user scrolls up.
    @Published var follow = true { didSet { if follow { unseen = 0 } } }
    /// Bumped when the visible lines change other than by appending or trimming, so the view redraws them all.
    @Published private(set) var rebuildToken = 0
    @Published private(set) var scrollRequest = 0

    private(set) var maxLines: Int
    private var pending: [LogLine] = []
    private var nextID = 0
    private var matcher = LineMatcher.all
    private var highlighter: Highlighter
    private var follower: Follower?

    static let maxLineLength = 8000

    var name: String { url.lastPathComponent }
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }

    init(url: URL, maxLines: Int, highlighter: Highlighter) {
        self.url = url
        self.maxLines = maxLines
        self.highlighter = highlighter
    }

    func start() {
        let follower = Follower(path: url.path, initialLines: maxLines) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        self.follower = follower
        follower.start()
    }

    func stop() {
        follower?.stop()
        follower = nil
    }

    func handle(_ event: Follower.Event) {
        switch event {
        case .loaded(let lines, let reachedStart, let size):
            self.size = size
            state = .following
            if !reachedStart {
                ingest(["Showing the end of a \(sizeText) file. Earlier lines are not loaded."], notice: true)
            }
            ingest(lines)
        case .appended(let lines, let size):
            self.size = size
            state = .following
            ingest(lines)
        case .truncated:
            size = 0
            ingest(["The file was truncated. Following it from the start."], notice: true)
        case .rotated:
            state = .following
            ingest(["A new file replaced this one, probably log rotation. Following the new file."], notice: true)
        case .missing:
            state = .waiting
            ingest([hasContent ? "The file was moved or deleted. Waiting for it to come back."
                    : "This file does not exist yet. Waiting for it to appear."], notice: true)
        }
    }

    private var hasContent: Bool { !lines.isEmpty || !pending.isEmpty }

    func ingest(_ texts: [String], notice: Bool = false) {
        guard !texts.isEmpty else { return }
        let new = texts.map { raw -> LogLine in
            let text = raw.utf8.count > Self.maxLineLength ? String(raw.prefix(Self.maxLineLength)) + " [line cut]" : raw
            defer { nextID += 1 }
            return LogLine(id: nextID, text: text, isNotice: notice, tone: notice ? nil : highlighter.tone(of: text))
        }
        if isPaused {
            pending += new
            if pending.count > maxLines { pending.removeFirst(pending.count - maxLines) }
            pendingCount = pending.count
        } else {
            append(new)
        }
    }

    private func append(_ new: [LogLine]) {
        lines += new
        errorCount += new.count(where: { $0.tone == .red })
        visible += new.filter { $0.isNotice || matcher.matches($0.text) }
        if !follow { unseen += new.count }
        trim()
    }

    private func trim() {
        guard lines.count > maxLines else { return }
        let drop = lines.count - maxLines
        errorCount -= lines[..<drop].count(where: { $0.tone == .red })
        lines.removeFirst(drop)
        let first = lines[0].id
        let hidden = visible.firstIndex { $0.id >= first } ?? visible.count
        visible.removeFirst(hidden)
    }

    func setMaxLines(_ value: Int) {
        maxLines = value
        trim()
    }

    func apply(matcher: LineMatcher) {
        self.matcher = matcher
        visible = lines.filter { $0.isNotice || matcher.matches($0.text) }
        rebuildToken += 1
    }

    func apply(highlighter: Highlighter) {
        self.highlighter = highlighter
        func retone(_ line: LogLine) -> LogLine {
            var line = line
            if !line.isNotice { line.tone = highlighter.tone(of: line.text) }
            return line
        }
        lines = lines.map(retone)
        pending = pending.map(retone)
        visible = lines.filter { $0.isNotice || matcher.matches($0.text) }
        errorCount = lines.count(where: { $0.tone == .red })
        rebuildToken += 1
    }

    func togglePause() {
        if isPaused {
            isPaused = false
            let held = pending
            pending = []
            pendingCount = 0
            append(held)
        } else {
            isPaused = true
        }
    }

    func clear() {
        lines = []
        visible = []
        pending = []
        pendingCount = 0
        errorCount = 0
        unseen = 0
        rebuildToken += 1
    }

    func jumpToBottom() {
        follow = true
        scrollRequest += 1
    }
}

// MARK: - The window's model

@MainActor
final class TailModel: ObservableObject {
    static let shared = TailModel(persistent: !Desktop.isSnapshot)

    @Published var sources: [LogSource] = []
    @Published var selection: LogSource.ID? { didSet { save() } }
    @Published var filterText = "" { didSet { if filterText != oldValue { applyFilter() } } }
    @Published var isRegex = false { didSet { if isRegex != oldValue { applyFilter() } } }
    @Published var rules: [HighlightRule] { didSet { if rules != oldValue { applyRules() } } }
    @Published var wrap: Bool { didSet { defaults(set: wrap, "wrap") } }
    @Published var fontSize: Double { didSet { defaults(set: fontSize, "fontSize") } }
    @Published var maxLines: Int {
        didSet {
            defaults(set: maxLines, "maxLines")
            sources.forEach { $0.setMaxLines(maxLines) }
        }
    }

    private(set) var matcher = LineMatcher.all
    private(set) var highlighter: Highlighter
    private let persistent: Bool

    static let lineChoices = [1_000, 5_000, 10_000, 50_000, 100_000]
    static let fontRange = 9.0...24.0

    struct Saved: Codable {
        var paths: [String]
        var selected: String?
    }

    init(persistent: Bool) {
        self.persistent = persistent
        let store = UserDefaults.standard
        let rules = persistent ? Storage.load([HighlightRule].self, app: "Tail", file: "rules.json") ?? HighlightRule.defaults
            : HighlightRule.defaults
        self.rules = rules
        highlighter = Highlighter(rules: rules)
        wrap = persistent ? store.object(forKey: "wrap") as? Bool ?? false : false
        fontSize = persistent ? store.object(forKey: "fontSize") as? Double ?? 12 : 12
        let lines = persistent ? store.integer(forKey: "maxLines") : 0
        maxLines = Self.lineChoices.contains(lines) ? lines : 10_000
        if persistent, let saved = Storage.load(Saved.self, app: "Tail", file: "files.json") {
            open(saved.paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) })
            selection = sources.first { $0.url.path == saved.selected }?.id ?? sources.first?.id
        }
    }

    var selected: LogSource? { sources.first { $0.id == selection } }

    func open(_ urls: [URL]) {
        var last: LogSource?
        for url in urls {
            var isDirectory: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let path = url.standardizedFileURL.path
            if let existing = sources.first(where: { $0.url.path == path }) { last = existing; continue }
            let source = LogSource(url: URL(fileURLWithPath: path), maxLines: maxLines, highlighter: highlighter)
            source.apply(matcher: matcher)
            sources.append(source)
            if persistent { source.start() }
            last = source
        }
        if let last { selection = last.id }
        save()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Log"
        panel.prompt = "Follow"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        if selection == nil { panel.directoryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?.appendingPathComponent("Logs") }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self?.open(panel.urls) }
        }
    }

    func close(_ source: LogSource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        source.stop()
        sources.remove(at: index)
        if selection == source.id {
            selection = sources.isEmpty ? nil : sources[min(index, sources.count - 1)].id
        }
        save()
    }

    func selectNeighbour(_ step: Int) {
        guard !sources.isEmpty else { return }
        let index = sources.firstIndex { $0.id == selection } ?? 0
        selection = sources[(index + step + sources.count) % sources.count].id
    }

    func toggleFollow(_ source: LogSource) {
        if source.follow { source.follow = false } else { source.jumpToBottom() }
    }

    func resetRules() { rules = HighlightRule.defaults }

    func addRule() { rules.append(HighlightRule(word: "", tone: .green)) }

    private func applyFilter() {
        matcher = LineMatcher(text: filterText, isRegex: isRegex)
        sources.forEach { $0.apply(matcher: matcher) }
    }

    private func applyRules() {
        highlighter = Highlighter(rules: rules)
        sources.forEach { $0.apply(highlighter: highlighter) }
        if persistent { Storage.save(rules, app: "Tail", file: "rules.json") }
    }

    private func save() {
        guard persistent else { return }
        Storage.save(Saved(paths: sources.map(\.url.path), selected: selected?.url.path), app: "Tail", file: "files.json")
    }

    private func defaults(set value: Any, _ key: String) {
        if persistent { UserDefaults.standard.set(value, forKey: key) }
    }
}
