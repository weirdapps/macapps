import AppKit
import Foundation

/// `Mind --selftest`: the tree edits, the file format, the Markdown outline, the layout and undo.
@MainActor
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name)") }
        }

        // Tree edits.
        var m = MindMap.blank
        let a = m.addChild(to: m.root.id, Node("A"))!
        let b = m.addChild(to: m.root.id, Node("B"))!
        let a1 = m.addChild(to: a, Node("A1"))!
        let a2 = m.addSibling(after: a1, Node("A2"))!
        check(m.count == 5, "count after adds")
        check(m.node(a)?.children.map(\.text) == ["A1", "A2"], "sibling goes right after")
        check(m.parent(of: a2)?.id == a && m.depth(of: a2) == 2, "parent and depth")
        check(m.addSibling(after: m.root.id, Node("C")) != nil && m.root.children.count == 3, "sibling of centre adds a child")

        m.toggleCollapsed(a)
        check(m.node(a)?.collapsed == true, "collapse")
        m.toggleCollapsed(a1)
        check(m.node(a1)?.collapsed == false, "a leaf never collapses")
        m.addChild(to: a, Node("A3"))
        check(m.node(a)?.collapsed == false, "adding a child expands")

        check(!m.move(a, to: a1), "cannot move into own branch")
        check(!m.move(m.root.id, to: b), "cannot move the centre")
        check(m.move(a1, to: b) && m.parent(of: a1)?.id == b, "re-parent")
        check(m.node(a)?.children.map(\.text) == ["A2", "A3"], "old parent keeps the rest")

        var r = m
        let next = r.remove(a2)
        check(next == r.node(a)?.children.first?.id && r.node(a2) == nil, "delete selects next sibling")
        let up = r.remove(r.node(a)!.children[0].id)
        check(up == a, "deleting an only child selects the parent")
        check(r.remove(r.root.id) == nil && r.count == m.count - 2, "the centre cannot be deleted")

        m.setAllCollapsed(true)
        check(m.node(a)?.collapsed == true && m.root.collapsed == false, "collapse all keeps the centre open")
        m.setAllCollapsed(false)
        check(m.node(a)?.collapsed == false, "expand all")

        // File format.
        if let data = try? m.encoded(), let back = try? MindMap.decode(data) {
            check(back == m, "JSON round trip")
        } else {
            check(false, "JSON round trip")
        }
        let minimal = #"{"version":1,"root":{"text":"Hi","children":[{"text":"Kid"}]}}"#
        check((try? MindMap.decode(Data(minimal.utf8)))?.root.children.first?.text == "Kid", "lenient decode")
        check((try? MindMap.decode(Data("nope".utf8))) == nil, "rejects junk")

        // Markdown.
        var md = MindMap(root: Node("Trip", children: [Node("Pack", children: [Node("Socks")]), Node("Book")]))
        let expected = "# Trip\n\n- Pack\n  - Socks\n- Book\n"
        check(Outline.markdown(md) == expected, "markdown export")
        let parsed = Outline.map(fromMarkdown: expected, title: "x")
        check(parsed.root.text == "Trip" && parsed.root.children.map(\.text) == ["Pack", "Book"]
              && parsed.root.children[0].children.first?.text == "Socks", "markdown import")
        md.root.children[0].text = "Pack\nlight"
        check(Outline.markdown(md).contains("- Pack light\n"), "newlines flattened on export")

        let messy = """
        # Plan
        ## Goals
        * [ ] Ship it
        \t1. First
        \t2) Second
        ## Risks ##
        + Weather

        ---
        """
        let pm = Outline.map(fromMarkdown: messy, title: "x")
        check(pm.root.text == "Plan" && pm.root.children.map(\.text) == ["Goals", "Risks"], "headings nest")
        check(pm.root.children[0].children.first?.text == "Ship it"
              && pm.root.children[0].children[0].children.map(\.text) == ["First", "Second"], "bullets, boxes, numbers, tabs")
        check(pm.root.children[1].children.first?.text == "Weather", "bullets under a later heading")
        let plain = Outline.map(fromMarkdown: "Milk\nEggs\n  Free range", title: "Shopping")
        check(plain.root.text == "Shopping" && plain.root.children.count == 2
              && plain.root.children[1].children.first?.text == "Free range", "plain indented lines, file name as centre")
        check(Outline.forest("- 2026 plans").first?.text == "2026 plans", "a year is not a list number")

        // Layout.
        let demo = MindMap.demo
        let layout = MapLayout.make(demo) { Style.measure($0.text, depth: $1) }
        let rects = layout.order.map { layout.frames[$0]!.rect }
        var overlaps = 0
        for i in rects.indices { for j in rects.indices where j > i && rects[i].insetBy(dx: 1, dy: 1).intersects(rects[j]) { overlaps += 1 } }
        check(overlaps == 0, "no topics overlap")
        let sides = demo.root.children.map { layout.frames[$0.id]!.side }
        check(sides.contains(1) && sides.contains(-1), "branches on both sides")
        let right = layout.order.filter { layout.frames[$0]!.side == 1 }.map { layout.frames[$0]!.rect }
        let left = layout.order.filter { layout.frames[$0]!.side == -1 }.map { layout.frames[$0]!.rect }
        let rh = right.reduce(CGRect.null) { $0.union($1) }.height, lh = left.reduce(CGRect.null) { $0.union($1) }.height
        check(abs(rh - lh) < max(rh, lh) * 0.35, "sides roughly balanced")
        check(right.allSatisfy { $0.minX > 0 } && left.allSatisfy { $0.maxX < 0 }, "each side stays on its side")
        let channels = demo.root.children[2]
        check(layout.frames[channels.children[0].id] == nil && layout.frames[channels.id]?.hidden == 4, "collapsed hides children")
        check(abs(layout.frames[demo.root.id]!.center.y) < 0.01, "centre at the origin")
        check(MapLayout.balancedSplit([10]) == 1 && MapLayout.balancedSplit([10, 10]) == 1
              && MapLayout.balancedSplit([10, 10, 10, 30]) == 3, "balanced split")

        // Navigation.
        let firstRight = demo.root.children.first { layout.frames[$0.id]!.side == 1 }!
        let firstLeft = demo.root.children.first { layout.frames[$0.id]!.side == -1 }!
        check(layout.frames[layout.neighbour(of: demo.root.id, .right, in: demo)!]!.side == 1, "right from centre")
        check(layout.neighbour(of: firstLeft.children[0].id, .right, in: demo) == firstLeft.id, "inward goes to parent")
        check(layout.neighbour(of: firstRight.children[0].id, .down, in: demo) == firstRight.children[1].id, "down to sibling")
        check(layout.neighbour(of: firstRight.children[0].id, .up, in: demo) == nil, "nothing above the top")
        let lastOfFirst = firstRight.children.last!.id
        check(layout.neighbour(of: lastOfFirst, .down, in: demo) == demo.root.children[1].children.first?.id,
              "down crosses to the next branch")

        // Viewport.
        var vp = Viewport(size: CGSize(width: 800, height: 600))
        vp.fit(layout.bounds)
        let fitted = vp.screen(layout.bounds)
        check(fitted.minX >= 0 && fitted.maxX <= 800 && fitted.minY >= 0 && fitted.maxY <= 600, "fit shows everything")
        let anchor = CGPoint(x: 120, y: 90), before = vp.world(anchor)
        vp.zoom(to: vp.scale * 2, around: anchor)
        let after = vp.world(anchor)
        check(abs(before.x - after.x) < 0.001 && abs(before.y - after.y) < 0.001, "zoom keeps the point under the pointer")
        vp.zoom(to: 99, around: anchor)
        check(vp.scale == Viewport.scales.upperBound, "zoom is clamped")

        // Undo through the editor.
        let doc = MindDocument()
        let editor = Editor(document: doc)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.undoManager = undo
        undo.beginUndoGrouping()
        editor.addChild()
        editor.draft = "Idea"
        editor.commitEditing(refocus: false)
        undo.endUndoGrouping()
        check(doc.map.root.children.map(\.text) == ["Idea"], "Tab, type, Return adds a topic")
        undo.undo()
        check(doc.map.root.children.isEmpty, "undo removes it in one step")
        undo.redo()
        check(doc.map.root.children.first?.text == "Idea" && editor.selection == doc.map.root.children[0].id, "redo")
        editor.addSibling()
        editor.cancelEditing()
        check(doc.map.root.children.count == 1, "Escape drops a new empty topic")
        editor.beginEditing(editor.selection, initial: "N")
        check(editor.draft == "N" && !editor.selectAllOnEdit, "typing a letter starts editing with it")
        undo.beginUndoGrouping()
        editor.draft = "Next"
        editor.commitEditing(refocus: false)
        undo.endUndoGrouping()
        check(doc.map.root.children.first?.text == "Next", "rename")
        undo.undo()
        check(doc.map.root.children.first?.text == "Idea", "undo rename")

        // Export renders.
        if let png = Editor.png(of: demo), let image = NSBitmapImageRep(data: png) {
            check(image.pixelsWide > 1000 && image.pixelsHigh > 500, "PNG export renders at 2x")
        } else {
            check(false, "PNG export renders")
        }

        // Odd input found in review.
        let noVersion = #"{"root":{"text":"Solo"}}"#
        check((try? MindMap.decode(Data(noVersion.utf8)))?.root.text == "Solo", "a file without a version opens")
        check((try? MindMap.decode(Data()))?.root.text == MindMap.blank.root.text, "an empty file opens as a blank map")
        check((try? MindMap.decode(Data("  \n".utf8)))?.count == 1, "a whitespace file opens as a blank map")
        let dupID = UUID().uuidString
        let dups = #"{"root":{"text":"R","children":[{"id":"\#(dupID)","text":"A"},{"id":"\#(dupID)","text":"B"}]}}"#
        if let dm = try? MindMap.decode(Data(dups.utf8)) {
            check(Set([dm.root.id] + dm.root.children.map(\.id)).count == 3, "duplicate ids in a file are made unique")
        } else {
            check(false, "duplicate ids in a file are made unique")
        }
        let big = (0..<20_000).map { "- Item \($0)" }.joined(separator: "\n")
        let t0 = Date()
        let bigForest = Outline.forest("# Big\n" + big)
        let importTime = Date().timeIntervalSince(t0)
        check(bigForest.first?.children.count == 20_000 && importTime < 1.5, "a 20,000 line outline imports fast (\(Int(importTime * 1000)) ms)")
        var wide = MindMap.blank
        for i in 0..<3_000 { wide.root.children.append(Node("Topic number \(i)")) }
        let t1 = Date()
        let wideLayout = MapLayout.make(wide) { Style.measure($0.text, depth: $1) }
        let layoutTime = Date().timeIntervalSince(t1)
        check(wideLayout.order.count == 3_001 && layoutTime < 0.5, "a 3,000 topic map lays out fast (\(Int(layoutTime * 1000)) ms)")
        check(Editor.png(of: wide) != nil, "a very tall map still exports a PNG")
        check(Outline.forest("- 🎉 Party\n  - Ελληνικά").first?.children.first?.text == "Ελληνικά", "unicode outline")
        var vp2 = Viewport(size: CGSize(width: 1040, height: 660))
        vp2.fit(CGRect(x: -400, y: -250, width: 800, height: 500))
        check(vp2.scale == 1, "fit snaps to 100% when the map nearly fits")

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
