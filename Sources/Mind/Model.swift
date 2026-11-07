import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tree

/// One topic of a mind map and everything that branches from it.
struct Node: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var collapsed = false
    var children: [Node] = []

    init(_ text: String, collapsed: Bool = false, children: [Node] = []) {
        self.text = text
        self.collapsed = collapsed
        self.children = children
    }

    private enum CodingKeys: String, CodingKey { case id, text, collapsed, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        children = try c.decodeIfPresent([Node].self, forKey: .children) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(text, forKey: .text)
        if collapsed { try c.encode(true, forKey: .collapsed) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
    }

    /// Every topic below this one, collapsed or not.
    var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    func contains(_ id: UUID) -> Bool { self.id == id || children.contains { $0.contains(id) } }

    func find(_ id: UUID) -> Node? {
        if self.id == id { return self }
        for child in children { if let hit = child.find(id) { return hit } }
        return nil
    }

    /// Child indexes from this node down to `id`.
    func path(to id: UUID) -> [Int]? {
        if self.id == id { return [] }
        for (i, child) in children.enumerated() {
            if let rest = child.path(to: id) { return [i] + rest }
        }
        return nil
    }

    subscript(path: [Int]) -> Node {
        get { path.isEmpty ? self : children[path[0]][Array(path.dropFirst())] }
        set {
            if path.isEmpty { self = newValue } else { children[path[0]][Array(path.dropFirst())] = newValue }
        }
    }

    /// A copy with fresh ids throughout, for pasting a subtree twice.
    var withNewIDs: Node {
        var copy = Node(text, collapsed: collapsed, children: children.map(\.withNewIDs))
        copy.id = UUID()
        return copy
    }
}

/// A whole document: one central topic. Edits are value-type mutations, so undo is a snapshot swap.
struct MindMap: Codable, Equatable {
    var version = 1
    var root: Node

    static var blank: MindMap { MindMap(root: Node("Central topic")) }

    var count: Int { 1 + root.descendantCount }

    func node(_ id: UUID) -> Node? { root.find(id) }

    func parent(of id: UUID) -> Node? {
        guard let path = root.path(to: id), !path.isEmpty else { return nil }
        return root[Array(path.dropLast())]
    }

    func depth(of id: UUID) -> Int? { root.path(to: id)?.count }

    @discardableResult
    mutating func update(_ id: UUID, _ change: (inout Node) -> Void) -> Bool {
        guard let path = root.path(to: id) else { return false }
        change(&root[path])
        return true
    }

    /// Adds a child at the end (or at `index`) and expands the parent so the new topic shows.
    @discardableResult
    mutating func addChild(to parent: UUID, _ node: Node = Node(""), at index: Int? = nil) -> UUID? {
        var added: UUID?
        update(parent) { p in
            p.collapsed = false
            let i = min(max(index ?? p.children.count, 0), p.children.count)
            p.children.insert(node, at: i)
            added = node.id
        }
        return added
    }

    /// Adds a sibling right after `id`; the central topic has no siblings, so it gets a child.
    @discardableResult
    mutating func addSibling(after id: UUID, _ node: Node = Node("")) -> UUID? {
        guard let path = root.path(to: id), let last = path.last else { return addChild(to: id, node) }
        let parentPath = Array(path.dropLast())
        root[parentPath].children.insert(node, at: last + 1)
        return node.id
    }

    /// Removes a topic and its branch; returns what to select next (next sibling, previous sibling, parent).
    @discardableResult
    mutating func remove(_ id: UUID) -> UUID? {
        guard let path = root.path(to: id), let last = path.last else { return nil }
        let parentPath = Array(path.dropLast())
        var parent = root[parentPath]
        parent.children.remove(at: last)
        root[parentPath] = parent
        if last < parent.children.count { return parent.children[last].id }
        if last > 0 { return parent.children[last - 1].id }
        return parent.id
    }

    /// Re-parents `id` under `newParent`. Refuses the central topic and moves into the topic's own branch.
    @discardableResult
    mutating func move(_ id: UUID, to newParent: UUID, at index: Int? = nil) -> Bool {
        guard id != root.id, let moving = node(id), !moving.contains(newParent), node(newParent) != nil else { return false }
        if parent(of: id)?.id == newParent, index == nil { return false }
        remove(id)
        return addChild(to: newParent, moving, at: index) != nil
    }

    mutating func setText(_ id: UUID, _ text: String) { update(id) { $0.text = text } }

    mutating func toggleCollapsed(_ id: UUID) {
        update(id) { n in if !n.children.isEmpty { n.collapsed.toggle() } }
    }

    /// Collapses (or expands) every topic that has children, keeping the central topic open when collapsing.
    mutating func setAllCollapsed(_ collapsed: Bool) {
        func walk(_ n: inout Node, depth: Int) {
            if !n.children.isEmpty { n.collapsed = collapsed && depth > 0 }
            for i in n.children.indices { walk(&n.children[i], depth: depth + 1) }
        }
        walk(&root, depth: 0)
    }

    // MARK: Files

    static func decode(_ data: Data) throws -> MindMap {
        try JSONDecoder().decode(MindMap.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Markdown outline

enum Outline {
    /// The whole map as a Markdown outline: the central topic as a heading, branches as nested bullets.
    static func markdown(_ map: MindMap) -> String {
        var out = "# \(clean(map.root.text))\n"
        if !map.root.children.isEmpty {
            out += "\n"
            for child in map.root.children { bullets(child, depth: 0, into: &out) }
        }
        return out
    }

    /// One branch as nested bullets, for the clipboard.
    static func markdown(branch: Node) -> String {
        var out = ""
        bullets(branch, depth: 0, into: &out)
        return out
    }

    private static func bullets(_ node: Node, depth: Int, into out: inout String) {
        out += String(repeating: "  ", count: depth) + "- " + clean(node.text) + "\n"
        for child in node.children { bullets(child, depth: depth + 1, into: &out) }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Parses headings, bullets, numbered items and indented plain lines into a forest of topics.
    /// Headings nest by level; bullets nest by indentation and sit under the heading above them.
    static func forest(_ text: String) -> [Node] {
        var roots: [Node] = []
        var stack: [(key: Int, path: [Int])] = [] // Path into `roots`: first index is the root, then child indexes.

        func insert(_ node: Node, key: Int) {
            while let top = stack.last, top.key >= key { stack.removeLast() }
            if let top = stack.last {
                var parent = roots[top.path[0]]
                let sub = Array(top.path.dropFirst())
                parent[sub].children.append(node)
                roots[top.path[0]] = parent
                stack.append((key, top.path + [parent[sub].children.count - 1]))
            } else {
                roots.append(node)
                stack.append((key, [roots.count - 1]))
            }
        }

        for raw in text.components(separatedBy: .newlines) {
            let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = expanded.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "=" || $0 == "_" }) { continue }
            let indent = expanded.prefix { $0 == " " }.count
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix { $0 == "#" }.count
                var title = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                while title.hasSuffix("#") { title.removeLast() }
                title = title.trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty { insert(Node(title), key: level) }
                continue
            }
            let title = stripMarker(trimmed)
            if !title.isEmpty { insert(Node(title), key: 100 + indent) }
        }
        return roots
    }

    /// A map from a Markdown outline: a single top item is the central topic, otherwise `title` is.
    static func map(fromMarkdown text: String, title: String) -> MindMap {
        let items = forest(text)
        if items.count == 1 { return MindMap(root: items[0]) }
        return MindMap(root: Node(title.isEmpty ? "Central topic" : title, children: items))
    }

    private static func stripMarker(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*+•".contains(first), s.dropFirst().first == " " || s.count == 1 {
            s = s.dropFirst()
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3 {
                let rest = s.dropFirst(digits.count)
                if let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " {
                    s = rest.dropFirst()
                }
            }
        }
        var out = s.trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where out.hasPrefix(box) { out = String(out.dropFirst(box.count)) }
        return out
    }
}

// MARK: - Document

extension UTType {
    static let mindMap = UTType(exportedAs: "com.weirdapps.mind", conformingTo: .json)
}

enum MindError: Error { case corrupt }

final class MindDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }

    @Published var map: MindMap

    init(map: MindMap = .blank) {
        self.map = map
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw MindError.corrupt }
        map = try MindMap.decode(data)
    }

    func snapshot(contentType: UTType) throws -> MindMap { map }

    func fileWrapper(snapshot: MindMap, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }
}

// MARK: - Demo

extension MindMap {
    /// The map shown on the website.
    static let demo: MindMap = {
        func n(_ t: String, _ kids: [String] = [], collapsed: Bool = false) -> Node {
            Node(t, collapsed: collapsed, children: kids.map { Node($0) })
        }
        return MindMap(root: Node("Product launch", children: [
            n("Audience", ["Early adopters", "Small studios", "Teachers", "Students"]),
            n("Message", ["One clear promise", "Short demo video", "Before and after"]),
            n("Channels", ["Newsletter", "Product Hunt", "Podcasts", "Press kit"], collapsed: true),
            n("Timeline", ["Private beta", "Launch day", "First update", "Retrospective"]),
            n("Pricing", ["Free trial", "One-time purchase", "Education discount"]),
            n("Risks", ["Server load", "Late reviews", "Scope creep"]),
        ]))
    }()

    static var demoSelection: UUID {
        demo.root.children[1].children[1].id
    }
}
