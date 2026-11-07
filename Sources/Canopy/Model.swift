import Foundation

// The parsed document: a flat, preorder table of nodes over the original bytes. Keys and scalar values stay as
// byte ranges into the source and are decoded only when shown, so a 100 MB file costs a few compact arrays.

enum JSONKind: UInt8, CaseIterable, Sendable {
    case object, array, string, number, bool, null

    var name: String {
        switch self {
        case .object: "Object"
        case .array: "Array"
        case .string: "String"
        case .number: "Number"
        case .bool: "Boolean"
        case .null: "Null"
        }
    }

    var badge: String {
        switch self {
        case .object: "{ }"
        case .array: "[ ]"
        case .string: "abc"
        case .number: "123"
        case .bool: "bool"
        case .null: "null"
        }
    }

    var isContainer: Bool { self == .object || self == .array }
}

struct JSONStats: Sendable, Equatable {
    var objects = 0, arrays = 0, strings = 0, numbers = 0, bools = 0, nulls = 0
    /// Container levels on the deepest path: `1` is 0, `[1]` is 1, `{"a":[1]}` is 2.
    var maxDepth = 0
    var bytes = 0
    var seconds = 0.0

    var nodes: Int { objects + arrays + strings + numbers + bools + nulls }

    func count(_ kind: JSONKind) -> Int {
        switch kind {
        case .object: objects
        case .array: arrays
        case .string: strings
        case .number: numbers
        case .bool: bools
        case .null: nulls
        }
    }
}

/// Where and why a parse failed, with the offending line for display.
struct ParseError: Error, Equatable, Sendable {
    var message: String
    var offset: Int
    var line = 1
    var column = 1
    /// The line around the error (a window of it when the line is long) and the caret's index in it.
    var excerpt = ""
    var caret = 0

    var location: String { "Line \(line), column \(column)" }
}

enum PathSegment: Equatable, Sendable {
    case key(String)
    case index(Int)
}

final class JSONTree: @unchecked Sendable {
    let bytes: [UInt8]
    /// True for JSON Lines: node 0 is a synthetic array holding one child per record.
    let isLines: Bool
    fileprivate(set) var kinds: [UInt8] = []
    fileprivate(set) var parents: [Int32] = []
    fileprivate(set) var keyStart: [Int32] = []
    fileprivate(set) var keyLen: [Int32] = []
    fileprivate(set) var valStart: [Int32] = []
    fileprivate(set) var valLen: [Int32] = []
    fileprivate(set) var position: [Int32] = []
    fileprivate(set) var childStart: [Int32] = []
    fileprivate(set) var childCount: [Int32] = []
    fileprivate(set) var children: [Int32] = []
    fileprivate(set) var stats = JSONStats()

    fileprivate static let keyEscaped: UInt8 = 1 << 3
    fileprivate static let valueEscaped: UInt8 = 1 << 4
    fileprivate static let isTrue: UInt8 = 1 << 5

    init(bytes: [UInt8], isLines: Bool) {
        self.bytes = bytes
        self.isLines = isLines
    }

    var count: Int { kinds.count }

    func kind(_ id: Int32) -> JSONKind { JSONKind(rawValue: kinds[Int(id)] & 7)! }
    func parent(_ id: Int32) -> Int32? { let p = parents[Int(id)]; return p < 0 ? nil : p }
    func childCount(_ id: Int32) -> Int { Int(childCount[Int(id)]) }
    func child(_ id: Int32, _ n: Int) -> Int32 { children[Int(childStart[Int(id)]) + n] }
    func childIDs(_ id: Int32) -> ArraySlice<Int32> {
        let s = Int(childStart[Int(id)])
        return children[s..<(s + Int(childCount[Int(id)]))]
    }
    /// The node's index among its parent's children.
    func position(_ id: Int32) -> Int { Int(position[Int(id)]) }

    /// The object key that names this node, nil for array elements and the root.
    func key(_ id: Int32) -> String? {
        let i = Int(id)
        guard keyStart[i] >= 0 else { return nil }
        return decode(Int(keyStart[i]), Int(keyLen[i]), escaped: kinds[i] & Self.keyEscaped != 0)
    }

    /// A string's decoded text, or a scalar's literal text. Empty for containers. `maxBytes` reads only the start
    /// of a long string, for display.
    func scalarText(_ id: Int32, maxBytes: Int = .max) -> String {
        let i = Int(id)
        switch kind(id) {
        case .string:
            return decode(Int(valStart[i]), min(Int(valLen[i]), maxBytes), escaped: kinds[i] & Self.valueEscaped != 0)
        case .number: return String(decoding: bytes[Int(valStart[i])..<Int(valStart[i] + valLen[i])], as: UTF8.self)
        case .bool: return kinds[i] & Self.isTrue != 0 ? "true" : "false"
        case .null: return "null"
        case .object, .array: return ""
        }
    }

    /// The node's source text, as it appears in the file.
    func rawRange(_ id: Int32) -> Range<Int> {
        let i = Int(id)
        var lo = Int(valStart[i]), hi = lo + Int(valLen[i])
        if kind(id) == .string { lo -= 1; hi += 1 }
        return lo..<hi
    }

    func depth(_ id: Int32) -> Int {
        var d = 0, p = parents[Int(id)]
        while p >= 0 { d += 1; p = parents[Int(p)] }
        return d
    }

    func ancestors(_ id: Int32) -> [Int32] {
        var chain: [Int32] = [], p = parents[Int(id)]
        while p >= 0 { chain.append(p); p = parents[Int(p)] }
        return chain.reversed()
    }

    func segments(_ id: Int32) -> [PathSegment] {
        var segs: [PathSegment] = [], n = id
        while let p = parent(n) {
            segs.append(kind(p) == .object ? .key(key(n) ?? "") : .index(position(n)))
            n = p
        }
        return segs.reversed()
    }

    // MARK: Decoding

    private func decode(_ start: Int, _ len: Int, escaped: Bool) -> String {
        bytes.withUnsafeBufferPointer { buf in
            let slice = UnsafeBufferPointer(rebasing: buf[start..<(start + len)])
            return escaped ? Self.unescape(slice) : String(decoding: slice, as: UTF8.self)
        }
    }

    static func unescape(_ s: UnsafeBufferPointer<UInt8>) -> String {
        var out: [UInt8] = []
        unescape(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Decodes a string's escapes into UTF-8 bytes, appending to `out`.
    static func unescape(_ s: UnsafeBufferPointer<UInt8>, into out: inout [UInt8]) {
        out.reserveCapacity(out.count + s.count)
        var i = 0
        func hex4(_ at: Int) -> UInt32? {
            guard at + 4 <= s.count else { return nil }
            var v: UInt32 = 0
            for k in 0..<4 {
                let c = s[at + k]
                let d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x41...0x46: d = UInt32(c - 0x37)
                case 0x61...0x66: d = UInt32(c - 0x57)
                default: return nil
                }
                v = v << 4 | d
            }
            return v
        }
        while i < s.count {
            let c = s[i]
            guard c == 0x5C, i + 1 < s.count else { out.append(c); i += 1; continue }
            let e = s[i + 1]
            i += 2
            switch e {
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard var v = hex4(i) else { break }
                i += 4
                if (0xD800...0xDBFF).contains(v), i + 6 <= s.count, s[i] == 0x5C, s[i + 1] == 0x75,
                   let lo = hex4(i + 2), (0xDC00...0xDFFF).contains(lo) {
                    v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                    i += 6
                }
                let scalar = Unicode.Scalar(v) ?? "\u{FFFD}"
                out.append(contentsOf: UTF8.encode(scalar)!)
            default: out.append(e) // \" \\ \/
            }
        }
    }
}

// MARK: - Paths

enum JSONPathFormat {
    private static func isIdentifier(_ s: String, allowDollar: Bool) -> Bool {
        guard let first = s.unicodeScalars.first else { return false }
        func ok(_ c: Unicode.Scalar, first: Bool) -> Bool {
            if c.isASCII, CharacterSet.letters.contains(c) || c == "_" || (allowDollar && c == "$") { return true }
            return !first && ("0"..."9").contains(c)
        }
        return ok(first, first: true) && s.unicodeScalars.dropFirst().allSatisfy { ok($0, first: false) }
    }

    /// `$.store.book[0]['first name']`
    static func jsonPath(_ segs: [PathSegment]) -> String {
        var out = "$"
        for seg in segs {
            switch seg {
            case .index(let n): out += "[\(n)]"
            case .key(let k):
                if isIdentifier(k, allowDollar: true) { out += "." + k } else {
                    let escaped = k.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                    out += "['\(escaped)']"
                }
            }
        }
        return out
    }

    /// `.store.book[0]."first name"`, or `.` for the root.
    static func jq(_ segs: [PathSegment]) -> String {
        var out = ""
        for seg in segs {
            switch seg {
            case .index(let n): out += out.isEmpty ? ".[\(n)]" : "[\(n)]"
            case .key(let k):
                if isIdentifier(k, allowDollar: false) { out += "." + k } else {
                    let escaped = k.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    out += ".\"\(escaped)\""
                }
            }
        }
        return out.isEmpty ? "." : out
    }
}

// MARK: - Parser

/// Progress and cancellation shared between the parsing thread and the UI.
final class ParseProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _fraction = 0.0
    private var _cancelled = false

    var fraction: Double {
        get { lock.withLock { _fraction } }
        set { lock.withLock { _fraction = newValue } }
    }
    var isCancelled: Bool { lock.withLock { _cancelled } }
    func cancel() { lock.withLock { _cancelled = true } }
}

struct ParseCancelled: Error {}

enum JSONParser {
    enum Mode { case json, lines, auto }

    /// Parses JSON, or JSON Lines (one value per line). `.auto` falls back to JSON Lines when a document holds
    /// several values on separate lines.
    static func parse(_ bytes: [UInt8], mode: Mode = .auto, progress: ParseProgress? = nil) throws -> JSONTree {
        let start = Date()
        let tree: JSONTree
        do {
            tree = try run(bytes, lines: mode == .lines, progress: progress)
        } catch let error as ParseError where mode == .auto && error.message == ParseError.trailingMessage {
            // Several values, one per line: JSON Lines. Report the JSON Lines error if that fails too.
            do { tree = try run(bytes, lines: true, progress: progress) } catch let e as ParseError {
                throw located(e, in: bytes)
            }
        } catch let error as ParseError {
            throw located(error, in: bytes)
        }
        tree.stats.bytes = bytes.count
        tree.stats.seconds = Date().timeIntervalSince(start)
        return tree
    }

    private static func run(_ bytes: [UInt8], lines: Bool, progress: ParseProgress?) throws -> JSONTree {
        let tree = JSONTree(bytes: bytes, isLines: lines)
        try bytes.withUnsafeBufferPointer { buf in
            var p = Parser(b: buf, tree: tree, progress: progress)
            if lines { try p.parseLines() } else { try p.parseDocument() }
        }
        return tree
    }

    /// Fills in the line, column and excerpt of an error from its byte offset.
    static func located(_ error: ParseError, in bytes: [UInt8]) -> ParseError {
        var e = error
        let offset = min(max(0, error.offset), bytes.count)
        var line = 1, lineStart = 0
        bytes.withUnsafeBufferPointer { b in
            for i in 0..<offset where b[i] == 0x0A { line += 1; lineStart = i + 1 }
        }
        var lineEnd = offset
        while lineEnd < bytes.count, bytes[lineEnd] != 0x0A, bytes[lineEnd] != 0x0D { lineEnd += 1 }
        let before = String(decoding: bytes[lineStart..<offset], as: UTF8.self)
        let after = String(decoding: bytes[offset..<lineEnd], as: UTF8.self)
        e.line = line
        e.column = before.count + 1
        let head = String(before.suffix(48)), tail = String(after.prefix(48))
        e.excerpt = (head.count < before.count ? "…" : "") + head + tail + (tail.count < after.count ? "…" : "")
        e.excerpt = e.excerpt.replacingOccurrences(of: "\t", with: " ")
        e.caret = head.count + (head.count < before.count ? 1 : 0)
        return e
    }
}

extension ParseError {
    static let trailingMessage = "Unexpected text after the JSON value"
}

private struct Parser {
    let b: UnsafeBufferPointer<UInt8>
    let tree: JSONTree
    let progress: ParseProgress?
    var i = 0
    var nextCheck = 1 << 22
    var stack: [Frame] = []
    var pending: [Int32] = []
    var depthOffset = 0

    struct Frame {
        var id: Int32
        var isObject: Bool
        var count: Int32 = 0
        var afterComma = false
        var pendingStart: Int
    }

    init(b: UnsafeBufferPointer<UInt8>, tree: JSONTree, progress: ParseProgress?) {
        self.b = b
        self.tree = tree
        self.progress = progress
        // A rough node count, so the columns grow without repeated copying on big files.
        let estimate = max(16, b.count / 16)
        tree.kinds.reserveCapacity(estimate)
        tree.parents.reserveCapacity(estimate)
        tree.keyStart.reserveCapacity(estimate)
        tree.keyLen.reserveCapacity(estimate)
        tree.valStart.reserveCapacity(estimate)
        tree.valLen.reserveCapacity(estimate)
        tree.position.reserveCapacity(estimate)
        tree.childStart.reserveCapacity(estimate)
        tree.childCount.reserveCapacity(estimate)
        tree.children.reserveCapacity(estimate)
    }

    func fail(_ message: String, at offset: Int? = nil) -> ParseError {
        ParseError(message: message, offset: offset ?? i)
    }

    mutating func skipBOM() {
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { i = 3 }
    }

    mutating func skipWhitespace() {
        while i < b.count {
            let c = b[i]
            guard c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 else { return }
            i += 1
        }
    }

    mutating func parseDocument() throws {
        guard b.count < Int(Int32.max) else { throw fail("Files over 2 GB are not supported", at: 0) }
        skipBOM()
        skipWhitespace()
        guard i < b.count else { throw fail("The document is empty") }
        try parseValue(parent: -1, position: 0, key: nil)
        let end = i
        skipWhitespace()
        if i < b.count {
            let crossedLine = b[end..<i].contains(0x0A)
            throw fail(crossedLine ? ParseError.trailingMessage : "Unexpected text after the JSON value; expected the end of the document")
        }
    }

    mutating func parseLines() throws {
        guard b.count < Int(Int32.max) else { throw fail("Files over 2 GB are not supported", at: 0) }
        skipBOM()
        // Node 0 holds the records.
        appendNode(kind: .array, parent: -1, position: 0, key: nil, valStart: Int32(i), valLen: Int32(b.count - i), flags: 0)
        depthOffset = 1
        var records: Int32 = 0
        while true {
            skipWhitespace()
            guard i < b.count else { break }
            try parseValue(parent: 0, position: records, key: nil)
            records += 1
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0D { i += 1 }
            if i < b.count, b[i] != 0x0A { throw fail("Expected a new line after record \(records)") }
        }
        guard records > 0 else { throw fail("The document is empty") }
        tree.stats.arrays += 1
        tree.stats.maxDepth = max(tree.stats.maxDepth, 1)
        tree.childStart[0] = Int32(tree.children.count)
        tree.childCount[0] = Int32(pending.count)
        tree.children.append(contentsOf: pending)
        pending.removeAll()
    }

    @inline(__always)
    mutating func appendNode(kind: JSONKind, parent: Int32, position: Int32, key: (Int32, Int32, Bool)?,
                             valStart: Int32, valLen: Int32, flags: UInt8) {
        var k = kind.rawValue | flags
        if let key, key.2 { k |= JSONTree.keyEscaped }
        tree.kinds.append(k)
        tree.parents.append(parent)
        tree.keyStart.append(key?.0 ?? -1)
        tree.keyLen.append(key?.1 ?? 0)
        tree.valStart.append(valStart)
        tree.valLen.append(valLen)
        tree.position.append(position)
        tree.childStart.append(0)
        tree.childCount.append(0)
    }

    /// Parses one complete value (containers included, iteratively, so deep nesting cannot overflow the stack).
    mutating func parseValue(parent: Int32, position: Int32, key: (Int32, Int32, Bool)?) throws {
        let base = stack.count
        try begin(parent: parent, position: position, key: key)
        while stack.count > base {
            var f = stack[stack.count - 1]
            skipWhitespace()
            guard i < b.count else { throw fail(f.isObject ? "Unexpected end of file; expected '}'" : "Unexpected end of file; expected ']'") }
            let c = b[i]
            let close: UInt8 = f.isObject ? 0x7D : 0x5D
            if c == close {
                if f.afterComma { throw fail("Trailing comma before '\(f.isObject ? "}" : "]")'") }
                closeContainer()
                continue
            }
            if f.count > 0, !f.afterComma {
                guard c == 0x2C else {
                    throw fail(f.isObject ? "Expected ',' or '}' after a property" : "Expected ',' or ']' after an element")
                }
                i += 1
                stack[stack.count - 1].afterComma = true
                continue
            }
            var childKey: (Int32, Int32, Bool)?
            if f.isObject {
                guard c == 0x22 else { throw fail(f.count == 0 && !f.afterComma ? "Expected a string key or '}'" : "Expected a string key in double quotes") }
                let (s, l, e) = try scanString()
                skipWhitespace()
                guard i < b.count, b[i] == 0x3A else { throw fail("Expected ':' after the key") }
                i += 1
                skipWhitespace()
                guard i < b.count else { throw fail("Unexpected end of file; expected a value") }
                childKey = (s, l, e)
            }
            f.count += 1
            f.afterComma = false
            stack[stack.count - 1] = f
            try begin(parent: f.id, position: f.count - 1, key: childKey)
        }
    }

    mutating func closeContainer() {
        let f = stack.removeLast()
        let id = Int(f.id)
        tree.valLen[id] = Int32(i + 1) - tree.valStart[id]
        tree.childStart[id] = Int32(tree.children.count)
        tree.childCount[id] = Int32(pending.count - f.pendingStart)
        tree.children.append(contentsOf: pending[f.pendingStart...])
        pending.removeSubrange(f.pendingStart...)
        i += 1
    }

    mutating func begin(parent: Int32, position: Int32, key: (Int32, Int32, Bool)?) throws {
        if i >= nextCheck {
            nextCheck = i + (1 << 22)
            if let progress {
                if progress.isCancelled { throw ParseCancelled() }
                progress.fraction = Double(i) / Double(max(1, b.count))
            }
        }
        let id = Int32(tree.kinds.count)
        if parent >= 0 { pending.append(id) }
        let c = b[i]
        switch c {
        case 0x7B, 0x5B:
            let isObject = c == 0x7B
            appendNode(kind: isObject ? .object : .array, parent: parent, position: position, key: key,
                       valStart: Int32(i), valLen: 0, flags: 0)
            if isObject { tree.stats.objects += 1 } else { tree.stats.arrays += 1 }
            stack.append(Frame(id: id, isObject: isObject, pendingStart: pending.count))
            tree.stats.maxDepth = max(tree.stats.maxDepth, stack.count + depthOffset)
            i += 1
        case 0x22:
            let (s, l, e) = try scanString()
            appendNode(kind: .string, parent: parent, position: position, key: key, valStart: s, valLen: l,
                       flags: e ? JSONTree.valueEscaped : 0)
            tree.stats.strings += 1
        case 0x2D, 0x30...0x39:
            let s = i
            try scanNumber()
            appendNode(kind: .number, parent: parent, position: position, key: key, valStart: Int32(s), valLen: Int32(i - s), flags: 0)
            tree.stats.numbers += 1
        case 0x74, 0x66, 0x6E:
            let s = i
            let word: [UInt8] = c == 0x74 ? Array("true".utf8) : c == 0x66 ? Array("false".utf8) : Array("null".utf8)
            guard i + word.count <= b.count, (0..<word.count).allSatisfy({ b[i + $0] == word[$0] }) else {
                throw fail("Unknown word; expected true, false or null")
            }
            i += word.count
            if c == 0x6E {
                appendNode(kind: .null, parent: parent, position: position, key: key, valStart: Int32(s), valLen: 4, flags: 0)
                tree.stats.nulls += 1
            } else {
                appendNode(kind: .bool, parent: parent, position: position, key: key, valStart: Int32(s), valLen: Int32(word.count),
                           flags: c == 0x74 ? JSONTree.isTrue : 0)
                tree.stats.bools += 1
            }
        case 0x27: throw fail("Strings need double quotes, not single quotes")
        case 0x7D, 0x5D: throw fail("Expected a value before '\(c == 0x7D ? "}" : "]")'")
        case 0x2C: throw fail("Expected a value before ','")
        default: throw fail("Expected a value")
        }
    }

    /// Scans a string starting at its opening quote; returns the content range and whether it has escapes.
    mutating func scanString() throws -> (Int32, Int32, Bool) {
        let open = i
        i += 1
        let start = i
        var escaped = false
        while true {
            guard i < b.count else { throw fail("Unterminated string", at: open) }
            let c = b[i]
            if c == 0x22 { break }
            if c == 0x5C {
                escaped = true
                guard i + 1 < b.count else { throw fail("Unterminated string", at: open) }
                switch b[i + 1] {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: i += 2
                case 0x75:
                    guard i + 6 <= b.count, (2..<6).allSatisfy({ Self.isHex(b[i + $0]) }) else {
                        throw fail("Invalid \\u escape; expected four hex digits")
                    }
                    i += 6
                default: throw fail("Invalid escape sequence")
                }
                continue
            }
            if c < 0x20 { throw fail(c == 0x0A ? "Unterminated string (line break inside a string)" : "Control character inside a string") }
            i += 1
        }
        let len = i - start
        i += 1
        return (Int32(start), Int32(len), escaped)
    }

    static func isHex(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) || (0x41...0x46).contains(c) || (0x61...0x66).contains(c) }
    static func isDigit(_ c: UInt8) -> Bool { (0x30...0x39).contains(c) }

    mutating func scanNumber() throws {
        if b[i] == 0x2D { i += 1 }
        guard i < b.count, Self.isDigit(b[i]) else { throw fail("Invalid number; expected a digit") }
        if b[i] == 0x30 {
            i += 1
            if i < b.count, Self.isDigit(b[i]) { throw fail("Numbers cannot have leading zeros") }
        } else {
            while i < b.count, Self.isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == 0x2E {
            i += 1
            guard i < b.count, Self.isDigit(b[i]) else { throw fail("Invalid number; expected a digit after '.'") }
            while i < b.count, Self.isDigit(b[i]) { i += 1 }
        }
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            guard i < b.count, Self.isDigit(b[i]) else { throw fail("Invalid number; expected a digit in the exponent") }
            while i < b.count, Self.isDigit(b[i]) { i += 1 }
        }
    }
}

// MARK: - Printing

extension JSONTree {
    struct Rendered {
        var bytes: [UInt8]
        var truncated: Bool
        /// With `track`, where each printed node starts and ends in `bytes`, indexed by `id - root`. Printing
        /// follows document order, so the printed nodes are exactly the ids from the root up to `starts.count`.
        var starts: [Int32] = []
        var ends: [Int32] = []
    }

    /// Pretty prints a node (2-space indent, keys and strings exactly as in the source). With `indent` nil, prints
    /// it on one line. Stops after `limit` bytes and reports whether it did.
    func render(_ id: Int32, indent: Int? = 2, limit: Int = .max, track: Bool = false) -> Rendered {
        var out: [UInt8] = []
        out.reserveCapacity(min(limit, rawRange(id).count * 2 + 16))
        var starts: [Int32] = [], ends: [Int32] = []
        let colon: [UInt8] = indent == nil ? [0x3A] : [0x3A, 0x20]
        func newline(_ level: Int) {
            guard let indent else { return }
            out.append(0x0A)
            out.append(contentsOf: repeatElement(0x20, count: level * indent))
        }
        func writeKey(_ n: Int32) {
            let i = Int(n)
            guard keyStart[i] >= 0 else { return }
            out.append(0x22)
            out.append(contentsOf: bytes[Int(keyStart[i])..<Int(keyStart[i] + keyLen[i])])
            out.append(0x22)
            out.append(contentsOf: colon)
        }
        func ended(_ n: Int32) {
            if track { ends[Int(n - id)] = Int32(out.count) }
        }
        // Opens a node; returns true when it is a non-empty container that needs a frame.
        func open(_ n: Int32) -> Bool {
            if track { starts.append(Int32(out.count)); ends.append(-1) }
            let k = kind(n)
            guard k.isContainer else { out.append(contentsOf: bytes[rawRange(n)]); ended(n); return false }
            if childCount(n) == 0 { out.append(contentsOf: k == .object ? [0x7B, 0x7D] : [0x5B, 0x5D]); ended(n); return false }
            out.append(k == .object ? 0x7B : 0x5B)
            return true
        }
        func finish(_ truncated: Bool) -> Rendered {
            if truncated { out.removeLast(out.count - limit) }
            return Rendered(bytes: out, truncated: truncated, starts: starts, ends: ends)
        }
        var stack: [(id: Int32, next: Int)] = []
        if open(id) { stack.append((id, 0)) }
        while let top = stack.last {
            if out.count > limit { return finish(true) }
            let n = childCount(top.id)
            if top.next < n {
                if top.next > 0 { out.append(0x2C) }
                newline(stack.count)
                let c = child(top.id, top.next)
                stack[stack.count - 1].next += 1
                if kind(top.id) == .object { writeKey(c) }
                if open(c) { stack.append((c, 0)) }
            } else {
                stack.removeLast()
                newline(stack.count)
                out.append(kind(top.id) == .object ? 0x7D : 0x5D)
                ended(top.id)
            }
        }
        return finish(out.count > limit)
    }

    func prettyString(_ id: Int32) -> String { String(decoding: render(id).bytes, as: UTF8.self) }

    /// What Copy Value puts on the clipboard: a string's text, a scalar's literal, a container's pretty JSON.
    func copyText(_ id: Int32) -> String { kind(id).isContainer ? prettyString(id) : scalarText(id) }

    /// One line describing a container's size, like "12 keys" or "1 item".
    func summary(_ id: Int32) -> String {
        let n = childCount(id)
        switch kind(id) {
        case .object: return n == 1 ? "1 key" : "\(n.formatted()) keys"
        case .array:
            if isLines && id == 0 { return n == 1 ? "1 record" : "\(n.formatted()) records" }
            return n == 1 ? "1 item" : "\(n.formatted()) items"
        default: return ""
        }
    }
}

// MARK: - Search

extension JSONTree {
    /// Nodes whose key or value contains `query`, ignoring case, in document order.
    func search(_ query: String, isCancelled: () -> Bool = { false }) -> [Int32] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var hits: [Int32] = []
        let ascii = q.utf8.allSatisfy { $0 < 0x80 }
        let needle = Array(q.lowercased().utf8)
        var scratch: [UInt8] = []
        bytes.withUnsafeBufferPointer { buf in
            func contains(_ hay: UnsafeBufferPointer<UInt8>) -> Bool {
                guard hay.count >= needle.count else { return false }
                let first = needle[0]
                for s in 0...(hay.count - needle.count) where Self.lower(hay[s]) == first {
                    var k = 1
                    while k < needle.count, Self.lower(hay[s + k]) == needle[k] { k += 1 }
                    if k == needle.count { return true }
                }
                return false
            }
            // Matches an ASCII query against source bytes, decoding escapes first when there are any.
            func matches(_ start: Int32, _ len: Int32, escaped: Bool) -> Bool {
                let raw = UnsafeBufferPointer(rebasing: buf[Int(start)..<Int(start + len)])
                guard escaped else { return contains(raw) }
                scratch.removeAll(keepingCapacity: true)
                Self.unescape(raw, into: &scratch)
                return scratch.withUnsafeBufferPointer { contains($0) }
            }
            for n in 0..<count {
                if n & 0xFFFF == 0, isCancelled() { hits = []; return }
                let id = Int32(n)
                let flags = kinds[n]
                let kind = JSONKind(rawValue: flags & 7)!
                var hit = false
                if keyStart[n] >= 0 {
                    hit = ascii ? matches(keyStart[n], keyLen[n], escaped: flags & Self.keyEscaped != 0)
                        : key(id)!.range(of: q, options: [.caseInsensitive]) != nil
                }
                if !hit, !kind.isContainer {
                    // Strings by their text; numbers, booleans and null by their literal.
                    hit = ascii ? matches(valStart[n], valLen[n], escaped: kind == .string && flags & Self.valueEscaped != 0)
                        : scalarText(id).range(of: q, options: [.caseInsensitive]) != nil
                }
                if hit { hits.append(id) }
            }
        }
        return hits
    }

    @inline(__always) static func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c + 32 : c }
}
