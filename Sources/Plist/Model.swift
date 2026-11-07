import Foundation

// MARK: - Values

/// The types an entry can have. Property lists use all but `null`; JSON uses containers, strings, numbers, booleans and null.
enum PType: String, CaseIterable, Identifiable, Sendable {
    case dictionary, array, boolean, data, date, number, string, null

    var id: String { rawValue }
    var isContainer: Bool { self == .dictionary || self == .array }

    static let plistTypes: [PType] = [.array, .dictionary, .boolean, .data, .date, .number, .string]
    static let jsonTypes: [PType] = [.array, .dictionary, .boolean, .number, .string, .null]

    func label(json: Bool) -> String {
        switch self {
        case .dictionary: json ? "Object" : "Dictionary"
        case .array: "Array"
        case .boolean: "Boolean"
        case .data: "Data"
        case .date: "Date"
        case .number: "Number"
        case .string: "String"
        case .null: "Null"
        }
    }

    var symbol: String {
        switch self {
        case .dictionary: "curlybraces"
        case .array: "list.number"
        case .boolean: "switch.2"
        case .data: "barcode"
        case .date: "calendar"
        case .number: "number"
        case .string: "textformat"
        case .null: "circle.slash"
        }
    }
}

enum PValue: Equatable, Sendable {
    case dictionary([PNode])
    case array([PNode])
    case string(String)
    case integer(Int)
    case real(Double)
    case boolean(Bool)
    case date(Date)
    case data(Data)
    case null

    var type: PType {
        switch self {
        case .dictionary: .dictionary
        case .array: .array
        case .string: .string
        case .integer, .real: .number
        case .boolean: .boolean
        case .date: .date
        case .data: .data
        case .null: .null
        }
    }

    /// The value as one line of text, the way the outline shows it.
    var text: String {
        switch self {
        case .dictionary(let c): c.count == 1 ? "1 key/value pair" : "\(c.count) key/value pairs"
        case .array(let c): c.count == 1 ? "1 item" : "\(c.count) items"
        case .string(let s): s
        case .integer(let i): String(i)
        case .real(let r): Format.real(r)
        case .boolean(let b): b ? "YES" : "NO"
        case .date(let d): Format.iso(d)
        case .data(let d): Format.hex(d)
        case .null: "null"
        }
    }

    /// Converts the value when the user picks another type, keeping what carries over.
    func converted(to type: PType) -> PValue {
        if type == self.type { return self }
        switch type {
        case .string:
            switch self {
            case .data(let d): return .string(String(data: d, encoding: .utf8) ?? Format.hex(d))
            case .dictionary, .array, .null: return .string("")
            default: return .string(text)
            }
        case .number:
            switch self {
            case .string(let s): return Format.number(s, preferReal: false) ?? .integer(0)
            case .boolean(let b): return .integer(b ? 1 : 0)
            case .date(let d): return .real(d.timeIntervalSince1970)
            default: return .integer(0)
            }
        case .boolean:
            switch self {
            case .string(let s): return .boolean(["yes", "true", "1", "on"].contains(s.trimmingCharacters(in: .whitespaces).lowercased()))
            case .integer(let i): return .boolean(i != 0)
            case .real(let r): return .boolean(r != 0)
            default: return .boolean(false)
            }
        case .date:
            switch self {
            case .string(let s): return .date(Format.date(s) ?? Date())
            case .integer(let i): return .date(Date(timeIntervalSince1970: TimeInterval(i)))
            case .real(let r): return .date(Date(timeIntervalSince1970: r))
            default: return .date(Date())
            }
        case .data:
            if case .string(let s) = self { return .data(Data(s.utf8)) }
            return .data(Data())
        case .array:
            if case .dictionary(let c) = self { return .array(c) }
            return .array([])
        case .dictionary:
            if case .array(let c) = self {
                return .dictionary(c.enumerated().map { PNode(id: $1.id, key: "Item \($0)", value: $1.value) })
            }
            return .dictionary([])
        case .null:
            return .null
        }
    }
}

/// One entry: a key (ignored inside arrays) and a value. The id keeps selection and expansion stable across edits and undo.
struct PNode: Identifiable, Equatable, Sendable {
    var id = UUID()
    var key: String
    var value: PValue

    var children: [PNode]? {
        get {
            switch value {
            case .dictionary(let c), .array(let c): c
            default: nil
            }
        }
        set {
            guard let newValue else { return }
            switch value {
            case .dictionary: value = .dictionary(newValue)
            case .array: value = .array(newValue)
            default: break
            }
        }
    }

    var isDictionary: Bool { value.type == .dictionary }

    /// Equal keys and values all the way down, ignoring ids.
    func isSame(as other: PNode) -> Bool {
        key == other.key && Self.sameValue(value, other.value)
    }

    static func sameValue(_ a: PValue, _ b: PValue) -> Bool {
        switch (a, b) {
        case (.dictionary(let x), .dictionary(let y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.isSame(as: $1) }
        case (.array(let x), .array(let y)):
            x.count == y.count && zip(x, y).allSatisfy { sameValue($0.value, $1.value) }
        case (.real(let x), .real(let y)):
            x == y || (x.isNaN && y.isNaN)
        case (.date(let x), .date(let y)):
            abs(x.timeIntervalSince(y)) < 1
        default:
            a == b
        }
    }

    /// The same content with dictionary keys sorted, for comparing with formats that do not keep order.
    func sorted() -> PNode {
        var copy = self
        switch value {
        case .dictionary(let c): copy.value = .dictionary(c.map { $0.sorted() }.sorted { $0.key < $1.key })
        case .array(let c): copy.value = .array(c.map { $0.sorted() })
        default: break
        }
        return copy
    }

    /// Every entry in the tree, this one included.
    var count: Int { 1 + (children ?? []).reduce(0) { $0 + $1.count } }
}

// MARK: - Tree editing

extension PNode {
    func node(_ id: UUID) -> PNode? {
        if self.id == id { return self }
        for child in children ?? [] {
            if let found = child.node(id) { return found }
        }
        return nil
    }

    /// Applies `body` to the entry with `id`. Returns false when there is none.
    @discardableResult
    mutating func modify(_ id: UUID, _ body: (inout PNode) -> Void) -> Bool {
        if self.id == id {
            body(&self)
            return true
        }
        guard var c = children else { return false }
        for i in c.indices {
            if c[i].modify(id, body) {
                children = c
                return true
            }
        }
        return false
    }

    /// The parent's id and the index of `id` among its children.
    func location(of id: UUID) -> (parent: UUID, index: Int)? {
        guard let c = children else { return nil }
        if let i = c.firstIndex(where: { $0.id == id }) { return (self.id, i) }
        for child in c {
            if let found = child.location(of: id) { return found }
        }
        return nil
    }

    /// The chain of entries from this one down to `id`.
    func path(to id: UUID) -> [PNode]? {
        if self.id == id { return [self] }
        for child in children ?? [] {
            if let rest = child.path(to: id) { return [self] + rest }
        }
        return nil
    }

    @discardableResult
    mutating func insert(_ node: PNode, in parent: UUID, at index: Int) -> Bool {
        modify(parent) { p in
            guard var c = p.children else { return }
            c.insert(node, at: max(0, min(index, c.count)))
            p.children = c
        }
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> PNode? {
        guard let loc = location(of: id) else { return nil }
        var removed: PNode?
        modify(loc.parent) { p in
            guard var c = p.children else { return }
            removed = c.remove(at: loc.index)
            p.children = c
        }
        return removed
    }

    /// Moves `id` up (negative) or down (positive) among its siblings. Returns false at either end.
    @discardableResult
    mutating func move(_ id: UUID, by offset: Int) -> Bool {
        guard let loc = location(of: id) else { return false }
        var moved = false
        modify(loc.parent) { p in
            guard var c = p.children else { return }
            let target = loc.index + offset
            guard c.indices.contains(target) else { return }
            c.swapAt(loc.index, target)
            p.children = c
            moved = true
        }
        return moved
    }

    /// "New item", or "New item 2" and up when that key is taken.
    static func uniqueKey(_ base: String, in siblings: [PNode]) -> String {
        let keys = Set(siblings.map(\.key))
        if !keys.contains(base) { return base }
        var n = 2
        while keys.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: - Outline rows

struct Row: Identifiable, Equatable {
    let id: UUID
    let depth: Int
    let key: String
    let value: PValue
    let isRoot: Bool
    let inArray: Bool
    let index: Int
    let isExpanded: Bool
    let isDuplicate: Bool

    var type: PType { value.type }
}

enum Outline {
    /// The visible rows: the root, then the children of every expanded container. With a filter, only entries that match,
    /// their ancestors (opened so the match shows) and, when a matching container is open, its contents.
    static func rows(_ root: PNode, expanded: Set<UUID>, filter: String) -> [Row] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        var keep = Set<UUID>(), open = Set<UUID>(), hits = Set<UUID>()
        if !query.isEmpty { _ = mark(root, query: query, keep: &keep, open: &open, hits: &hits) }
        var out: [Row] = []

        func visit(_ node: PNode, depth: Int, inArray: Bool, index: Int, duplicate: Bool, insideHit: Bool) {
            let isRoot = depth == 0
            guard query.isEmpty || isRoot || insideHit || keep.contains(node.id) else { return }
            let isOpen = isRoot || expanded.contains(node.id) || open.contains(node.id)
            out.append(Row(id: node.id, depth: depth, key: node.key, value: node.value, isRoot: isRoot, inArray: inArray,
                           index: index, isExpanded: isOpen && node.children != nil, isDuplicate: duplicate))
            guard isOpen, let c = node.children else { return }
            let dupes = node.isDictionary ? duplicates(c) : []
            for (i, child) in c.enumerated() {
                visit(child, depth: depth + 1, inArray: !node.isDictionary, index: i, duplicate: dupes.contains(child.key),
                      insideHit: insideHit || (hits.contains(node.id) && expanded.contains(node.id)))
            }
        }
        visit(root, depth: 0, inArray: false, index: 0, duplicate: false, insideHit: false)
        return out
    }

    private static func mark(_ node: PNode, query: String, keep: inout Set<UUID>, open: inout Set<UUID>, hits: inout Set<UUID>) -> Bool {
        var below = false
        for child in node.children ?? [] where mark(child, query: query, keep: &keep, open: &open, hits: &hits) {
            below = true
        }
        if below { open.insert(node.id) }
        let own = node.key.localizedCaseInsensitiveContains(query)
            || (node.children == nil && node.value.text.localizedCaseInsensitiveContains(query))
        if own { hits.insert(node.id) }
        if own || below { keep.insert(node.id) }
        return own || below
    }

    static func duplicates(_ c: [PNode]) -> Set<String> {
        var seen = Set<String>(), dupes = Set<String>()
        for n in c where !seen.insert(n.key).inserted { dupes.insert(n.key) }
        return dupes
    }
}

// MARK: - Text formats

enum Format {
    static func iso(_ d: Date) -> String { d.formatted(.iso8601) }

    static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? Date.ISO8601FormatStyle().parse(t)) ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(t))
    }

    static func real(_ r: Double) -> String {
        if r.isNaN { return "nan" }
        if r.isInfinite { return r > 0 ? "+infinity" : "-infinity" }
        return "\(r)"
    }

    /// A number typed by the user. Integers stay integers unless the text has a fraction or the value was real already.
    static func number(_ s: String, preferReal: Bool) -> PValue? {
        let t = s.trimmingCharacters(in: .whitespaces)
        switch t.lowercased() {
        case "nan": return .real(.nan)
        case "inf", "+inf", "infinity", "+infinity": return .real(.infinity)
        case "-inf", "-infinity": return .real(-.infinity)
        default: break
        }
        if !preferReal, let i = Int(t) { return .integer(i) }
        if let r = Double(t) { return .real(r) }
        return nil
    }

    /// Bytes as Xcode shows them: `<48656c6c 6f>`.
    static func hex(_ d: Data) -> String {
        var out = "<"
        for (i, byte) in d.enumerated() {
            if i > 0 && i % 4 == 0 { out += " " }
            out += String(format: "%02x", byte)
        }
        return out + ">"
    }

    /// Parses hex digits, ignoring spaces and angle brackets. Nil for anything else or an odd count of digits.
    static func parseHex(_ s: String) -> Data? {
        let digits = s.filter { !$0.isWhitespace && $0 != "<" && $0 != ">" }
        guard digits.count % 2 == 0 else { return nil }
        var data = Data(capacity: digits.count / 2)
        var it = digits.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let byte = UInt8(String([a, b]), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
