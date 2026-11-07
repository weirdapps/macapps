import AppKit
import Foundation

/// `Heft --selftest`: the treemap maths, kinds, the scanner on a temporary folder, and tree edits.
enum SelfTest {
    private static var failures = 0
    private static var passed = 0

    private static func check(_ ok: Bool, _ name: String) {
        if ok { passed += 1 } else { failures += 1; print("FAIL: \(name)") }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 0.01) -> Bool { abs(a - b) <= eps * max(1, abs(b)) }

    static func run() -> Int32 {
        squarify()
        kinds()
        layout()
        scanner()
        edits()
        print("\(passed) passed, \(failures) failed")
        return failures == 0 ? 0 : 1
    }

    private static func squarify() {
        let rect = CGRect(x: 10, y: 20, width: 600, height: 400)
        let values: [Double] = [6, 6, 4, 3, 2, 2, 1]
        let rects = Treemap.squarify(values, in: rect)
        let total = values.reduce(0, +)
        check(rects.count == values.count, "squarify returns one rect per value")
        check(near(rects.reduce(0) { $0 + $1.width * $1.height }, rect.width * rect.height), "squarify fills the whole rect")
        check(zip(values, rects).allSatisfy { near($1.width * $1.height, rect.width * rect.height * CGFloat($0 / total)) },
              "squarify areas are proportional to values")
        check(rects.allSatisfy { rect.insetBy(dx: -0.01, dy: -0.01).contains($0) }, "squarify stays inside the rect")
        var overlap = false
        for i in rects.indices { for j in rects.indices where j > i { if rects[i].insetBy(dx: 0.01, dy: 0.01).intersects(rects[j].insetBy(dx: 0.01, dy: 0.01)) { overlap = true } } }
        check(!overlap, "squarify rects do not overlap")
        let squares = Treemap.squarify([1, 1, 1, 1], in: CGRect(x: 0, y: 0, width: 100, height: 100))
        check(squares.allSatisfy { near($0.width, 50) && near($0.height, 50) }, "four equal values make four squares")
        let many = Treemap.squarify((1...60).map { 100.0 / Double($0) }, in: CGRect(x: 0, y: 0, width: 800, height: 500))
        let worst = many.map { max($0.width / $0.height, $0.height / $0.width) }.max() ?? 0
        check(worst < 6, "squarify keeps aspect ratios reasonable (worst \(String(format: "%.1f", worst)))")
        check(Treemap.squarify([], in: rect).isEmpty, "squarify of nothing is empty")
        check(Treemap.squarify([5], in: rect) == [rect], "one value fills the rect")
        let zeros = Treemap.squarify([3, 0, 1], in: rect)
        check(zeros[1].width * zeros[1].height == 0 && near(zeros[0].width * zeros[0].height, rect.width * rect.height * 0.75),
              "zero values get no area")
    }

    private static func kinds() {
        let cases: [(String, FileKind)] = [("jpg", .images), ("HEIC", .images), ("mov", .video), ("mp4", .video), ("mp3", .audio),
                                           ("wav", .audio), ("pdf", .documents), ("docx", .documents), ("txt", .documents),
                                           ("swift", .code), ("json", .code), ("zip", .archives), ("dmg", .archives),
                                           ("app", .apps), ("qqqzz", .other), ("", .other)]
        for (ext, kind) in cases { check(FileKind.classify(extension: ext) == kind, "\(ext.isEmpty ? "no extension" : ext) is \(kind.title)") }
        check(Bytes.format(1_500_000) == ByteCountFormatter.string(fromByteCount: 1_500_000, countStyle: .file), "bytes use Finder's units")
        check(share(1, of: 2) == "50%" && share(1, of: 20) == "5.0%" && share(1, of: 100_000) == "<0.1%" && share(1, of: 0) == "0%",
              "shares format as percentages")
    }

    private static func layout() {
        let root = Demo.tree()
        check(root.size > 100_000_000_000 && root.count > 1_000, "demo tree is a believable home folder")
        check(root.kindSizes.reduce(0, +) == root.size, "kind totals add up to the folder size")
        check(zip(root.children, root.children.dropFirst()).allSatisfy { $0.size >= $1.size }, "children are sorted largest first")
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 560)
        let tiles = Treemap.layout(root, in: bounds)
        check(!tiles.isEmpty, "layout makes tiles")
        check(tiles.allSatisfy { bounds.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) }, "tiles stay inside the treemap")
        let top = tiles.filter { $0.depth == 0 }
        check(near(top.reduce(0) { $0 + $1.rect.width * $1.rect.height }, bounds.width * bounds.height), "top level tiles cover the treemap")
        if let movies = tiles.first(where: { $0.node?.name == "Movies" }) {
            let p = CGPoint(x: movies.rect.midX, y: movies.rect.maxY - 3)
            let hit = Treemap.hit(tiles, p)
            check(hit?.node.map { $0 === movies.node! || $0.isDescendant(of: movies.node!) } ?? false, "hit testing finds the deepest tile")
            check(movies.isFrame && movies.header != nil, "a big folder is drawn as a frame with a title")
        } else {
            check(false, "Movies has a tile")
        }
        let crowd = Demo.folder("crowd", [Demo.file("big.mov", 1e9)] + (1...2000).map { Demo.file("tiny \($0).txt", 1000) })
        let crowdTiles = Treemap.layout(crowd, in: CGRect(x: 0, y: 0, width: 300, height: 200))
        check(crowdTiles.contains { $0.node == nil && $0.othersCount == 2000 }, "tiny items gather into one block")
        check(crowdTiles.count < 10, "tiny items do not make thousands of tiles")
    }

    private static func scanner() {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("heft-selftest-\(UUID().uuidString)")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.appendingPathComponent("locked").path)
            try? fm.removeItem(at: base)
        }
        do {
            let sub = base.appendingPathComponent("photos")
            let deep = sub.appendingPathComponent("2026")
            try fm.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data(count: 300_000).write(to: deep.appendingPathComponent("a.jpg"))
            try Data(count: 120_000).write(to: sub.appendingPathComponent("b.png"))
            try Data(count: 50_000).write(to: base.appendingPathComponent("notes.txt"))
            try Data(count: 10).write(to: base.appendingPathComponent("tiny.swift"))
            let app = base.appendingPathComponent("Tool.app/Contents")
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
            try Data(count: 80_000).write(to: app.appendingPathComponent("binary"))
            try fm.createSymbolicLink(at: base.appendingPathComponent("loop"), withDestinationURL: sub)
            let locked = base.appendingPathComponent("locked")
            try fm.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data(count: 5_000).write(to: locked.appendingPathComponent("secret.bin"))
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        } catch {
            check(false, "could not build the test folder: \(error)")
            return
        }
        func alloc(_ path: String) -> Int64 {
            Int64((try? base.appendingPathComponent(path).resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        let progress = ScanProgress()
        guard let root = Scanner.scan(base, progress: progress) else { check(false, "scan finished"); return }
        let expectedFiles = alloc("photos/2026/a.jpg") + alloc("photos/b.png") + alloc("notes.txt") + alloc("tiny.swift")
        let appSize = alloc("Tool.app/Contents/binary")
        let link = root.child(named: "loop")
        check(link != nil && link!.isFolder == false && link!.size < 10_000, "symlinks are not followed")
        check(root.size == expectedFiles + appSize + (link?.size ?? 0), "root size is the sum of allocated sizes")
        check(root.child(named: "photos")?.size == alloc("photos/2026/a.jpg") + alloc("photos/b.png"), "folder sizes add up their contents")
        check(root.child(named: "photos")?.child(named: "2026")?.child(named: "a.jpg")?.kind == .images, "files get their kind")
        let tool = root.child(named: "Tool.app")
        check(tool?.isFolder == false && tool?.kind == .apps && tool?.size == appSize, "app bundles count as one app")
        check(root.child(named: "locked")?.unreadable == true && progress.snapshot.skipped == 1, "unreadable folders are flagged and skipped")
        check(root.count == 6, "file count includes every file, app and link (got \(root.count))")
        check(root.kindSize(.images) == alloc("photos/2026/a.jpg") + alloc("photos/b.png"), "image total is right")
        check(root.children.first?.name == "photos", "largest child comes first")
        let a = root.child(named: "photos")?.child(named: "2026")?.child(named: "a.jpg")
        check(a?.url.standardizedFileURL.path == base.appendingPathComponent("photos/2026/a.jpg").standardizedFileURL.path, "paths come from the parent chain")
        check(a.map { root.find(ObjectIdentifier($0)) === $0 } ?? false, "find locates a node by identity")
        check(progress.snapshot.files >= 6, "progress counts files")

        let cancelled = ScanProgress()
        cancelled.cancel()
        check(Scanner.scan(base, progress: cancelled) == nil, "a cancelled scan returns nothing")
    }

    private static func edits() {
        let root = Demo.tree()
        guard let movies = root.child(named: "Movies"), let film = movies.child(named: "Naxos sailing 4K.mov") else {
            check(false, "demo has the film")
            return
        }
        let before = (root.size, root.count, root.kindSize(.video), movies.size)
        film.detach()
        check(movies.child(named: film.name) == nil, "detached node leaves its folder")
        check(root.size == before.0 - film.size && movies.size == before.3 - film.size, "detaching takes bytes off every ancestor")
        check(root.count == before.1 - 1, "detaching takes the file off the count")
        check(root.kindSize(.video) == before.2 - film.size, "detaching updates kind totals")
        check(film.lineage.count == 1, "a detached node has no parent")
        check(movies.lineage.map(\.name) == ["dimitris", "Movies"], "lineage runs from the root down")
    }
}
