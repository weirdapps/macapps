import AppKit
import Kit
import SwiftUI

// MARK: - Style

enum Theme {
    static let top: UInt32 = 0x9B6BFF
    static let bottom: UInt32 = 0x5A2FD1
    static let accent = Color(nsColor: rgb(0x7C4DFF))
    static let gradient = LinearGradient(colors: [Color(nsColor: rgb(top)), Color(nsColor: rgb(bottom))],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    /// One colour per main branch, in order around the map.
    static let branches: [UInt32] = [0xFF6B6B, 0xFF9F43, 0x20BF6B, 0x0FB9B1, 0x4B7BEC, 0xE056FD, 0xE5A50A, 0xFC5C9C]

    static func branch(_ index: Int) -> Color {
        Color(nsColor: rgb(branches[((index % branches.count) + branches.count) % branches.count]))
    }

    /// A lighter tint of a branch colour, for the top of filled topics.
    static func branchLight(_ index: Int) -> Color {
        Color(nsColor: rgb(branches[((index % branches.count) + branches.count) % branches.count])
            .blended(withFraction: 0.25, of: .white) ?? .white)
    }
}

/// Fonts and sizes per depth. Layout measures with exactly the fonts the views draw with.
enum Style {
    static func fontSize(_ depth: Int) -> CGFloat { depth == 0 ? 21 : depth == 1 ? 15 : 13.5 }

    static func font(_ depth: Int, scale: CGFloat = 1) -> NSFont {
        let size = fontSize(depth) * scale
        let weight: NSFont.Weight = depth == 0 ? .bold : depth == 1 ? .semibold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard depth <= 1, let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func padding(_ depth: Int) -> CGSize {
        depth == 0 ? CGSize(width: 24, height: 15) : depth == 1 ? CGSize(width: 16, height: 9) : CGSize(width: 11, height: 6)
    }

    static func maxTextWidth(_ depth: Int) -> CGFloat { depth == 0 ? 220 : depth == 1 ? 200 : 190 }

    static func cornerRadius(_ depth: Int, height: CGFloat) -> CGFloat {
        depth == 0 ? min(height / 2, 22) : depth == 1 ? min(height / 2, 15) : 8
    }

    /// Placeholder shown (and measured) for a topic with no text yet.
    static let placeholder = "Topic"

    static func measure(_ text: String, depth: Int) -> CGSize {
        let shown = text.isEmpty ? placeholder : text
        let rect = (shown as NSString).boundingRect(with: CGSize(width: maxTextWidth(depth), height: 10_000),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                    attributes: [.font: font(depth)])
        let pad = padding(depth)
        return CGSize(width: ceil(rect.width) + 4 + pad.width * 2, height: ceil(rect.height) + pad.height * 2)
    }
}

// MARK: - Layout

struct NodeFrame: Equatable {
    var center: CGPoint
    var size: CGSize
    var depth: Int
    var side: Int      // -1 left of the central topic, 1 right, 0 the central topic itself.
    var branch: Int    // Index of the main branch this topic belongs to; -1 for the central topic.
    var parent: UUID?
    var hidden: Int    // Topics hidden inside this collapsed topic.

    var rect: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the connector from the parent arrives.
    var inner: CGPoint { CGPoint(x: center.x - CGFloat(side) * size.width / 2, y: center.y) }

    /// Where connectors to children leave, on the side facing away from the centre.
    func outer(toward side: Int) -> CGPoint {
        let inset: CGFloat = depth == 0 ? 10 : 0
        return CGPoint(x: center.x + CGFloat(side) * (size.width / 2 - inset), y: center.y)
    }
}

enum Direction { case left, right, up, down }

/// A balanced two-sided tree: main branches split between right and left so both sides weigh about the same,
/// every branch stacked so no subtrees overlap, near edges of siblings aligned.
struct MapLayout {
    var frames: [UUID: NodeFrame] = [:]
    var order: [UUID] = [] // Visible topics, central topic first, depth first.
    var bounds: CGRect = .zero

    static func vGap(_ depth: Int) -> CGFloat { depth <= 1 ? 22 : depth == 2 ? 10 : 7 }
    static func hGap(_ parentDepth: Int) -> CGFloat { parentDepth == 0 ? 78 : 44 }

    static func make(_ map: MindMap, measure: (Node, Int) -> CGSize) -> MapLayout {
        var layout = MapLayout()
        var sizes: [UUID: CGSize] = [:]
        var heights: [UUID: CGFloat] = [:]

        func block(_ nodes: [Node], depth: Int) -> CGFloat {
            guard !nodes.isEmpty else { return 0 }
            return nodes.reduce(0) { $0 + heights[$1.id]! } + vGap(depth) * CGFloat(nodes.count - 1)
        }

        @discardableResult
        func measureAll(_ node: Node, _ depth: Int) -> CGFloat {
            let size = measure(node, depth)
            sizes[node.id] = size
            var height = size.height
            if !node.collapsed, !node.children.isEmpty {
                node.children.forEach { measureAll($0, depth + 1) }
                height = max(height, block(node.children, depth: depth + 1))
            }
            heights[node.id] = height
            return height
        }

        func place(_ node: Node, depth: Int, side: Int, branch: Int, parent: NodeFrame, parentID: UUID, top: CGFloat) {
            let size = sizes[node.id]!, height = heights[node.id]!
            let x = parent.center.x + CGFloat(side) * (parent.size.width / 2 + hGap(depth - 1) + size.width / 2)
            let frame = NodeFrame(center: CGPoint(x: x, y: top + height / 2), size: size, depth: depth, side: side,
                                  branch: branch, parent: parentID, hidden: node.collapsed ? node.descendantCount : 0)
            layout.frames[node.id] = frame
            layout.order.append(node.id)
            guard !node.collapsed else { return }
            var y = frame.center.y - block(node.children, depth: depth + 1) / 2
            for child in node.children {
                place(child, depth: depth + 1, side: side, branch: branch, parent: frame, parentID: node.id, top: y)
                y += heights[child.id]! + vGap(depth + 1)
            }
        }

        let root = map.root
        measureAll(root, 0)
        let rootFrame = NodeFrame(center: .zero, size: sizes[root.id]!, depth: 0, side: 0, branch: -1, parent: nil,
                                  hidden: root.collapsed ? root.descendantCount : 0)
        layout.frames[root.id] = rootFrame
        layout.order.append(root.id)

        if !root.collapsed {
            let kids = root.children
            let split = balancedSplit(kids.map { heights[$0.id]! })
            for (side, range) in [(1, 0..<split), (-1, split..<kids.count)] {
                let group = Array(kids[range])
                var y = -block(group, depth: 1) / 2
                for (offset, child) in group.enumerated() {
                    place(child, depth: 1, side: side, branch: range.lowerBound + offset, parent: rootFrame,
                          parentID: root.id, top: y)
                    y += heights[child.id]! + vGap(1)
                }
            }
        }

        layout.bounds = layout.order.reduce(CGRect.null) { $0.union(layout.frames[$1]!.rect) }
        return layout
    }

    /// How many of the main branches go on the right: the split that best balances the two sides' heights,
    /// favouring the right when it is a tie.
    static func balancedSplit(_ heights: [CGFloat]) -> Int {
        let total = heights.reduce(0, +)
        var best = heights.count, bestDiff = CGFloat.infinity, running = total
        for k in stride(from: heights.count, through: 0, by: -1) {
            if k < heights.count { running -= heights[k] }
            let diff = abs(running - (total - running))
            if diff < bestDiff - 0.5 { best = k; bestDiff = diff }
        }
        return best
    }

    /// The topic under a point, ignoring `excluded`, with a little slack around each topic.
    func node(at point: CGPoint, excluding excluded: Set<UUID> = [], slack: CGFloat = 8) -> UUID? {
        order.reversed().first { id in
            !excluded.contains(id) && frames[id]!.rect.insetBy(dx: -slack, dy: -slack).contains(point)
        }
    }

    /// The topic an arrow key moves to: outward goes to the nearest child, inward to the parent,
    /// up and down to the nearest topic at the same depth on the same side.
    func neighbour(of id: UUID, _ direction: Direction, in map: MindMap) -> UUID? {
        guard let f = frames[id] else { return nil }
        switch direction {
        case .left, .right:
            let outward = direction == .right ? 1 : -1
            if f.side == -outward { return f.parent }
            let kids = (map.node(id)?.children ?? []).compactMap { c in frames[c.id].map { (c.id, $0) } }
                .filter { $0.1.side == outward }
            return kids.min { abs($0.1.center.y - f.center.y) < abs($1.1.center.y - f.center.y) }?.0
        case .up, .down:
            guard f.depth > 0 else { return nil }
            let candidates = order.compactMap { other -> (UUID, NodeFrame)? in
                guard other != id, let o = frames[other], o.depth == f.depth, o.side == f.side else { return nil }
                let above = o.center.y < f.center.y - 0.5, below = o.center.y > f.center.y + 0.5
                return (direction == .up ? above : below) ? (other, o) : nil
            }
            func cost(_ o: NodeFrame) -> CGFloat { abs(o.center.y - f.center.y) + abs(o.center.x - f.center.x) * 0.3 }
            return candidates.min { cost($0.1) < cost($1.1) }?.0
        }
    }

    /// All visible topics in the branch starting at `id`, `id` included.
    func branch(of id: UUID, in map: MindMap) -> Set<UUID> {
        guard let node = map.node(id) else { return [] }
        var out: Set<UUID> = []
        func walk(_ n: Node) {
            out.insert(n.id)
            n.children.forEach(walk)
        }
        walk(node)
        return out.intersection(frames.keys)
    }
}

/// Maps the map's own coordinates (central topic at the origin) to the canvas and back.
struct Viewport: Equatable {
    var size: CGSize
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    static let scales: ClosedRange<CGFloat> = 0.25...3

    func screen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: size.width / 2 + offset.width + p.x * scale, y: size.height / 2 + offset.height + p.y * scale)
    }

    func world(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - size.width / 2 - offset.width) / scale, y: (p.y - size.height / 2 - offset.height) / scale)
    }

    func screen(_ r: CGRect) -> CGRect {
        let o = screen(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    /// Zooms to `newScale` keeping the point under `anchor` (a canvas point) still.
    mutating func zoom(to newScale: CGFloat, around anchor: CGPoint) {
        let w = world(anchor)
        scale = min(max(newScale, Self.scales.lowerBound), Self.scales.upperBound)
        offset = CGSize(width: anchor.x - size.width / 2 - w.x * scale, height: anchor.y - size.height / 2 - w.y * scale)
    }

    /// Fits `bounds` in the canvas with a margin, never enlarging past 140%.
    mutating func fit(_ bounds: CGRect, margin: CGFloat = 56) {
        guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else { return }
        let s = min((size.width - margin * 2) / bounds.width, (size.height - margin * 2) / bounds.height, 1.4)
        scale = min(max(s, Self.scales.lowerBound), Self.scales.upperBound)
        offset = CGSize(width: -bounds.midX * scale, height: -bounds.midY * scale)
    }
}
