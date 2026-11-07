import AppKit
import PDFKit

enum SelfTest {
    private nonisolated(unsafe) static var failures = 0
    private nonisolated(unsafe) static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok { failures += 1; print("FAIL: \(name)") }
    }

    static func run() -> Int32 {
        MainActor.assumeIsolated { runAll() }
        print(failures == 0 ? "All \(checks) checks passed" : "\(failures) of \(checks) checks failed")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    private static func runAll() {
        ranges()
        pureEdits()
        names()
        files()
        modelEdits()
    }

    private static func ranges() {
        func groups(_ s: String, _ n: Int) -> [[Int]]? { try? Ranges.parse(s, count: n).get() }
        check(groups("1-3,5", 10) == [[1, 2, 3], [5]], "simple ranges")
        check(groups(" 2 , 4-4 ", 10) == [[2], [4]], "spaces and single page range")
        check(groups("8-", 10) == [[8, 9, 10]], "open ended range runs to the last page")
        check(groups("-3", 10) == [[1, 2, 3]], "open start range begins at page 1")
        check(groups("3-1", 10) == [[3, 2, 1]], "backwards range")
        check(groups("1,,2", 5) == [[1], [2]], "empty parts are skipped")
        check(Ranges.parse("", count: 5) == .failure(.empty), "empty text")
        check(Ranges.parse("0", count: 5) == .failure(.outOfRange(0, 5)), "page zero is out of range")
        check(Ranges.parse("2-9", count: 5) == .failure(.outOfRange(9, 5)), "page past the end")
        check(Ranges.parse("a", count: 5) == .failure(.invalid("a")), "letters rejected")
        check(Ranges.parse("1-2-3", count: 5) == .failure(.invalid("1-2-3")), "double dash rejected")
        check(Ranges.parse("-", count: 5) == .failure(.invalid("-")), "bare dash rejected")
    }

    private static func pureEdits() {
        let s = UUID()
        let p = (0..<5).map { PageItem(sourceID: s, index: $0) }
        let ids = p.map(\.id)
        func order(_ pages: [PageItem]) -> [Int] { pages.map(\.index) }
        check(order(Binder.move(p, ids: [ids[1], ids[3]], before: ids[0])) == [1, 3, 0, 2, 4], "move two pages to the front")
        check(order(Binder.move(p, ids: [ids[0]], before: nil)) == [1, 2, 3, 4, 0], "move to the end")
        check(order(Binder.move(p, ids: [ids[2]], before: ids[2])) == [0, 1, 2, 3, 4], "drop on itself changes nothing")
        check(order(Binder.move(p, ids: [ids[0], ids[4]], before: ids[4])) == [0, 4, 1, 2, 3], "drop on a moved page gathers them")
        check(order(Binder.move(p, ids: [ids[4]], before: ids[1])) == [0, 4, 1, 2, 3], "move a later page earlier")
        check(Binder.normalised(-90) == 270 && Binder.normalised(360) == 0 && Binder.normalised(450) == 90, "rotation normalising")
        let r = Binder.rotate(p, ids: [ids[1]], by: -90)
        check(r[1].rotation == 270 && r[0].rotation == 0, "rotate only the chosen page")
        check(Binder.rotate(r, ids: [ids[1]], by: 90)[1].rotation == 0, "rotate back to upright")
    }

    private static func names() {
        check(Binder.splitNames([[1], [12]], base: "Doc", total: 12) == ["Doc 01", "Doc 12"], "single page names are zero padded")
        check(Binder.splitNames([[1, 2, 3], [5]], base: "Doc", total: 9) == ["Doc 1-3", "Doc 5"], "range names")
        check(Binder.splitNames([[3, 2, 1]], base: "Doc", total: 9) == ["Doc 3-1"], "backwards range name")
        check(Binder.formatBytes(1_500_000).contains("MB"), "byte formatting")
    }

    @MainActor
    private static func files() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BinderSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pdfURL = dir.appendingPathComponent("Letter.pdf")
        check(DemoPDF.document(.letter, title: "Test", pages: 3).write(to: pdfURL), "write a test PDF")
        let pngURL = dir.appendingPathComponent("Plan.png")
        if let tiff = DemoPDF.floorPlan().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: pngURL)
        }
        let lockedURL = dir.appendingPathComponent("Locked.pdf")
        _ = DemoPDF.document(.report, title: "Secret", pages: 1)
            .write(to: lockedURL, withOptions: [.userPasswordOption: "a", .ownerPasswordOption: "b"])
        try? "hello".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let expanded = Binder.expand([dir])
        check(expanded.map(\.lastPathComponent) == ["Letter.pdf", "Locked.pdf", "Plan.png"], "folder expands to PDFs and images, sorted")

        guard let letter = try? Binder.load(pdfURL, tint: 0) else { check(false, "load a PDF"); return }
        check(letter.pageCount == 3 && !letter.isImage && letter.bytes > 0, "PDF source has its pages and size")
        guard let plan = try? Binder.load(pngURL, tint: 1) else { check(false, "load an image"); return }
        check(plan.pageCount == 1 && plan.isImage, "an image becomes one page")
        check(plan.sizes[0].width > plan.sizes[0].height, "a landscape image makes a landscape page")
        check((try? Binder.load(lockedURL, tint: 2)) == nil, "a locked PDF is refused")
        do { _ = try Binder.load(lockedURL, tint: 2) } catch { check(error as? LoadError == .locked("Locked.pdf"), "locked error names the file") }
        do { _ = try Binder.load(dir.appendingPathComponent("notes.txt"), tint: 3) } catch {
            check(error as? LoadError == .unreadable("notes.txt"), "a text file is unreadable")
        }

        // Build: letter page 3 rotated, then the plan, then letter page 1.
        var items = [PageItem(sourceID: letter.id, index: 2, rotation: 90), PageItem(sourceID: plan.id, index: 0),
                     PageItem(sourceID: letter.id, index: 0)]
        items[2].rotation = 270
        let out = Binder.build(items, sources: [letter, plan])
        check(out?.pageCount == 3, "built PDF has three pages")
        check(out?.page(at: 0)?.rotation == 90 && out?.page(at: 2)?.rotation == 270, "rotation is written to the pages")
        let outURL = Binder.uniqueURL(in: dir, name: "Letter")
        check(outURL.lastPathComponent == "Letter 2.pdf", "unique name avoids overwriting")
        check(out?.write(to: outURL) ?? false, "write the result")
        let back = PDFDocument(url: outURL)
        check(back?.pageCount == 3 && back?.page(at: 0)?.rotation == 90, "result reads back with its order and rotation")
        check(back?.page(at: 2)?.string?.contains("TEST") ?? false, "page text survives the copy")
        let token = CancelToken()
        token.cancel()
        check(Binder.build(items, sources: [letter, plan], cancel: token) == nil, "cancel stops a build")

        let estimate = Binder.estimate(items, sources: [letter, plan])
        check(estimate == Int64(letter.bytesPerPage * 2 + plan.bytesPerPage), "size estimate sums pages")

        // Split through the model, waiting for the background queue.
        let model = BinderModel()
        model.add([letter, plan])
        let split = dir.appendingPathComponent("split")
        try? FileManager.default.createDirectory(at: split, withIntermediateDirectories: true)
        if case .success(let groups) = Ranges.parse("1-2, 4", count: model.pages.count) {
            model.split(groups, into: split, base: "Part")
            Binder.queue.sync {}
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let a = PDFDocument(url: split.appendingPathComponent("Part 1-2.pdf"))
            let b = PDFDocument(url: split.appendingPathComponent("Part 4.pdf"))
            check(a?.pageCount == 2 && b?.pageCount == 1, "split by ranges writes one file per range")
            check(model.notice?.urls.count == 2 && model.job == nil, "split reports its files when done")
        } else {
            check(false, "parse split ranges")
        }
        check(BinderModel.renderThumbnail(letter, index: 0) != nil, "thumbnails render")
    }

    @MainActor
    private static func modelEdits() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let model = BinderModel()
        model.undoManager = undo
        func step(_ change: () -> Void) {
            undo.beginUndoGrouping()
            change()
            undo.endUndoGrouping()
        }
        let doc = DemoPDF.document(.letter, title: "Doc", pages: 4)
        let source = Source(name: "Doc", url: nil, document: doc, tint: 0, bytes: 4000, isImage: false)
        step { model.add([source]) }
        check(model.pages.count == 4 && model.selection.count == 4, "adding selects the new pages")
        check(model.estimatedBytes == 4000, "estimate of a whole file is its size")

        let ids = model.pages.map(\.id)
        model.click(ids[1], modifiers: [])
        model.click(ids[3], modifiers: .shift)
        check(model.selection == Set(ids[1...3]), "shift click selects a range")
        model.click(ids[2], modifiers: .command)
        check(model.selection == [ids[1], ids[3]], "command click toggles")

        step { model.delete() }
        check(model.pages.map(\.index) == [0, 2] && model.selection.isEmpty, "delete removes the selection")
        undo.undo()
        check(model.pages.map(\.index) == [0, 1, 2, 3], "undo brings deleted pages back")
        undo.redo()
        check(model.pages.map(\.index) == [0, 2], "redo deletes again")
        undo.undo()

        step { model.rotate(-90, ids: [ids[0]]) }
        check(model.pages[0].rotation == 270, "rotate left")
        undo.undo()
        check(model.pages[0].rotation == 0, "undo rotation")

        model.selection = [ids[0]]
        step { model.nudge(1) }
        check(model.pages.map(\.index) == [1, 0, 2, 3], "move later")
        undo.undo()
        check(model.pages.map(\.index) == [0, 1, 2, 3], "undo move")
        model.selectNone()
        step { model.reverse() }
        check(model.pages.map(\.index) == [3, 2, 1, 0], "reverse order of every page")
        undo.undo()

        step { model.delete(ids: [ids[2]]) }
        step { model.restorePages(of: source) }
        check(model.pages.count == 4 && model.pages.last?.index == 2, "restore puts back deleted pages")
        step { model.removeSource(source.id) }
        check(model.pages.isEmpty && model.sources.isEmpty, "remove a file and its pages")
        undo.undo()
        check(model.sources.count == 1 && model.pages.count == 4, "undo remove file")
        check(model.beginDrag(ids[0]) == [ids[0]] && model.selection == [ids[0]], "dragging an unselected page selects it")
        model.endDrag()
        check(model.dragging.isEmpty, "drag ends")
    }
}
