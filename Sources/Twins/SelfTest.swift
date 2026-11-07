import Foundation

/// `Twins --selftest`: exercises the scanner on temporary files and the selection rules. Exits 0 when all pass.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ ok: Bool, _ what: String) {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(what)") }
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("twins-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        func write(_ path: String, _ data: Data) {
            let url = dir.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
        let hello = Data("hello twins".utf8)
        write("a.txt", hello)
        write("b.txt", hello)
        write("sub/c.txt", hello)
        write("d.txt", Data("other twins".utf8)) // Same size, different content.
        write(".hidden.txt", hello)
        write("Thing.app/Contents/inner.txt", hello)
        write("empty1", Data())
        write("empty2", Data())
        var big = Data((0..<200_000).map { UInt8($0 % 251) })
        write("big1.bin", big)
        write("deep/big2.bin", big)
        big[100_000] ^= 0xFF // Same head and tail, different middle: only the full hash can tell.
        write("big3.bin", big)
        write("tiny.txt", Data("hi".utf8))
        write("tiny copy.txt", Data("hi".utf8))
        try? fm.linkItem(at: dir.appendingPathComponent("a.txt"), to: dir.appendingPathComponent("hardlink.txt"))
        try? fm.createSymbolicLink(at: dir.appendingPathComponent("link.txt"), withDestinationURL: dir.appendingPathComponent("a.txt"))

        // SHA-256 known vector.
        write("abc", Data("abc".utf8))
        let abc = try? Scanner.sha256(of: dir.appendingPathComponent("abc"))
        check(abc == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 of abc")
        let partial = try? Scanner.partialHash(of: dir.appendingPathComponent("abc"), size: 3)
        check(partial == abc, "partial hash of a small file is its full hash")
        try? fm.removeItem(at: dir.appendingPathComponent("abc"))

        let options = ScanOptions()
        func scan(_ o: ScanOptions, roots: [URL]? = nil) -> ScanResult? {
            try? Scanner.run(roots: roots ?? [dir], options: o, isCancelled: { false }, progress: { _ in })
        }
        // A hard link is the same file as a.txt; whichever the walk meets first stands for both.
        func names(_ g: DuplicateGroup) -> Set<String> { Set(g.files.map { $0.name == "hardlink.txt" ? "a.txt" : $0.name }) }

        if let r = scan(options) {
            check(r.groups.count == 3, "three groups by default (got \(r.groups.count))")
            let helloGroup = r.groups.first { $0.size == Int64(hello.count) }
            check(helloGroup.map(names) == ["a.txt", "b.txt", "c.txt"], "hello group skips hidden, package, hard link and symlink")
            check(r.groups.contains { names($0) == ["big1.bin", "big2.bin"] }, "full hash separates a file that differs in the middle")
            check(r.groups.contains { names($0) == ["tiny.txt", "tiny copy.txt"] }, "tiny files match")
            check(!r.groups.contains { $0.size == 0 }, "empty files are ignored")
            check(r.groups.first?.size == 200_000, "groups sorted by wasted space")
            check(helloGroup?.wasted == Int64(hello.count) * 2, "wasted is size times extra copies")
            check(r.groups.first?.id.count == 64, "group id is a SHA-256 hex digest")
            check(r.groups.allSatisfy { g in g.files.map(\.id) == g.files.map(\.id).sorted() }, "files in a group sorted by path")
        } else { check(false, "default scan ran") }

        var all = options
        all.skipHidden = false
        all.skipPackages = false
        let helloAll = scan(all)?.groups.first { $0.size == Int64(hello.count) }
        check(helloAll.map(names) == ["a.txt", "b.txt", "c.txt", ".hidden.txt", "inner.txt"], "hidden and package files when asked")

        var big100k = options
        big100k.minimumSize = 100_000
        check(scan(big100k)?.groups.count == 1, "minimum size filters small files")

        let overlapping = scan(options, roots: [dir, dir.appendingPathComponent("sub"), dir])
        check(overlapping?.groups.first { $0.size == Int64(hello.count) }?.files.count == 3, "overlapping roots count files once")
        check(Scanner.normalized([URL(fileURLWithPath: "/a/b"), URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/ab")]).map(\.path)
            == ["/a", "/ab"], "nested roots collapse, sibling prefixes do not")

        let cancelled: ScanResult?
        do { cancelled = try Scanner.run(roots: [dir], options: options, isCancelled: { true }, progress: { _ in }) } catch { cancelled = nil }
        check(cancelled == nil, "cancelling stops the scan")

        var phases = Set<Int>()
        _ = try? Scanner.run(roots: [dir], options: options, isCancelled: { false }, progress: { phases.insert($0.phase.rawValue) })
        check(phases.isSuperset(of: [1, 2, 3]), "progress reports every hashing phase")

        // Keep rules.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func item(_ path: String, _ day: Double) -> FileItem {
            FileItem(url: URL(fileURLWithPath: path), size: 10, modified: t0.addingTimeInterval(day * 86_400))
        }
        let group = DuplicateGroup(id: "x", size: 10, files: [
            item("/Users/a/Downloads/Old/photo.jpg", 1), item("/Users/a/Pictures/photo.jpg", 5), item("/Users/a/photo copy.jpg", 3),
        ])
        check(Scanner.keeper(of: group, rule: .newest).url.path == "/Users/a/Pictures/photo.jpg", "keep newest")
        check(Scanner.keeper(of: group, rule: .oldest).url.path == "/Users/a/Downloads/Old/photo.jpg", "keep oldest")
        check(Scanner.keeper(of: group, rule: .shortestPath).url.path == "/Users/a/photo copy.jpg", "keep shortest path")
        let tie = DuplicateGroup(id: "y", size: 10, files: [item("/x/long/name.txt", 0), item("/x/name.txt", 0)])
        check(Scanner.keeper(of: tie, rule: .newest).url.path == "/x/name.txt", "date ties fall back to the shortest path")
        let marked = Scanner.autoSelect([group, tie], rule: .newest)
        check(marked.count == 3 && !marked.contains("/Users/a/Pictures/photo.jpg"), "auto select marks all but one per group")
        check(Scanner.wouldEmpty(tie, marking: tie.files[1], marked: ["/x/long/name.txt"]), "marking the last copy is refused")
        check(!Scanner.wouldEmpty(group, marking: group.files[0], marked: []), "marking one of three is allowed")

        let left = Scanner.removing(["/Users/a/photo copy.jpg", "/x/name.txt"], from: [group, tie])
        check(left.count == 1 && left[0].files.count == 2, "removing drops groups left with one copy")
        check(left[0].wasted == 10, "wasted updates after removal")

        // Sorting and formatting.
        let sorted = Scanner.sort([tie, group], by: .copies)
        check(sorted.first?.id == "x", "sort by copies")
        check(Scanner.sort([group, tie], by: .name).first?.id == "y", "sort by name")
        check(Fmt.files(1) == "1 file" && Fmt.files(2) == "2 files", "file counts")
        check(Fmt.seconds(4.25) == "4.2 s" || Fmt.seconds(4.25) == "4.3 s", "seconds format")
        check(ScanProgress(phase: .full, bytesDone: 50, bytesTotal: 200).fraction == 0.25, "full phase fraction by bytes")
        check(ScanProgress(phase: .finding, done: 10).fraction == nil, "finding phase is indeterminate")

        print("\(passed) checks passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
