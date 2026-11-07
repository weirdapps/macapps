import Foundation

/// `Rename --selftest`: exercises the rule engine, the conflict planner and the renamer on temporary files.
enum SelfTest {
    static func run() -> Int32 {
        var passed = 0, failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            if ok { passed += 1 } else { failed += 1; print("FAIL: \(name) \(detail())") }
        }
        func expect(_ name: String, _ got: String, _ want: String) { check(name, got == want, "got \u{201C}\(got)\u{201D}, want \u{201C}\(want)\u{201D}") }
        func rule(_ kind: RuleKind, _ edit: (inout Rule) -> Void) -> Rule {
            var r = Rule(kind: kind)
            edit(&r)
            return r
        }
        let photo = FileMeta(name: "IMG_4012.JPG")

        // Splitting names.
        check("split ext", Engine.split("a.b.txt", isDirectory: false) == ("a.b", "txt"))
        check("split dotfile", Engine.split(".zshrc", isDirectory: false) == (".zshrc", ""))
        check("split folder", Engine.split("Project.v2", isDirectory: true) == ("Project.v2", ""))
        check("split sentence", Engine.split("Dr. Who notes", isDirectory: false) == ("Dr. Who notes", ""))

        // Replace.
        expect("replace plain", Engine.name(for: photo, rules: [rule(.replace) { $0.find = "img_"; $0.replacement = "Photo " }]), "Photo 4012.JPG")
        expect("replace match case", Engine.name(for: photo, rules: [rule(.replace) { $0.find = "img"; $0.matchCase = true; $0.replacement = "x" }]), "IMG_4012.JPG")
        expect("regex groups", Engine.name(for: FileMeta(name: "2024-05-17 report.pdf"),
                                           rules: [rule(.replace) { $0.regex = true; $0.find = "(\\d{4})-(\\d{2})-(\\d{2})"; $0.replacement = "$3.$2.$1" }]),
               "17.05.2024 report.pdf")
        expect("regex leaves extension", Engine.name(for: photo, rules: [rule(.replace) { $0.regex = true; $0.find = "G"; $0.replacement = "g" }]), "IMg_4012.JPG")
        check("regex error", rule(.replace) { $0.regex = true; $0.find = "(" }.regexError != nil)
        expect("bad regex is a no-op", Engine.name(for: photo, rules: [rule(.replace) { $0.regex = true; $0.find = "(" }]), "IMG_4012.JPG")

        // Insert.
        expect("prefix", Engine.name(for: photo, rules: [rule(.insert) { $0.text = "Trip "; $0.placement = .prefix }]), "Trip IMG_4012.JPG")
        expect("suffix", Engine.name(for: photo, rules: [rule(.insert) { $0.text = "_v2" }]), "IMG_4012_v2.JPG")
        expect("at index", Engine.name(for: photo, rules: [rule(.insert) { $0.text = "-"; $0.placement = .index; $0.position = 3 }]), "IMG-_4012.JPG")
        expect("at index clamps", Engine.name(for: FileMeta(name: "ab"), rules: [rule(.insert) { $0.text = "!"; $0.placement = .index; $0.position = 99 }]), "ab!")

        // Case.
        let messy = FileMeta(name: "my HOLIDAY photo.Jpg")
        expect("lower", Engine.name(for: messy, rules: [rule(.changeCase) { $0.caseStyle = .lower }]), "my holiday photo.Jpg")
        expect("upper", Engine.name(for: messy, rules: [rule(.changeCase) { $0.caseStyle = .upper }]), "MY HOLIDAY PHOTO.Jpg")
        expect("title", Engine.name(for: messy, rules: [rule(.changeCase) { $0.caseStyle = .title }]), "My Holiday Photo.Jpg")
        expect("sentence", Engine.name(for: messy, rules: [rule(.changeCase) { $0.caseStyle = .sentence }]), "My holiday photo.Jpg")

        // Numbering.
        let files = (0..<12).map { FileMeta(name: "f\($0).txt") }
        let numbered = Engine.names(for: files, rules: [rule(.number) { $0.placement = .replace; $0.start = 8; $0.step = 2; $0.padding = 3 }])
        expect("number first", numbered[0], "008.txt")
        expect("number last", numbered[11], "030.txt")
        expect("number suffix", Engine.name(for: photo, index: 4, rules: [rule(.number) { $0.padding = 2; $0.separator = "-" }]), "IMG_4012-05.JPG")
        expect("number negative", Engine.name(for: photo, rules: [rule(.number) { $0.placement = .replace; $0.start = -3; $0.padding = 2 }]), "-03.JPG")

        // Typed values outside the steppers never trap or explode.
        expect("number overflow is skipped", Engine.name(for: photo, index: 3, rules: [rule(.number) { $0.start = Int.max; $0.step = 2 }]), "IMG_4012.JPG")
        expect("huge step is skipped", Engine.name(for: photo, index: 5, rules: [rule(.number) { $0.step = Int.max }]), "IMG_4012.JPG")
        expect("padding is capped", Engine.name(for: photo, rules: [rule(.number) { $0.placement = .replace; $0.padding = 1_000_000 }]),
               String(repeating: "0", count: Rule.maxPadding - 1) + "1.JPG")
        expect("min int start", Engine.name(for: photo, rules: [rule(.number) { $0.placement = .replace; $0.start = Int.min; $0.padding = 1 }]),
               "-9223372036854775808.JPG")

        // Dates.
        let taken = FileItem.parseExif("2026:06:14 09:12:30")
        check("exif parse", taken != nil)
        let modified = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2025, month: 1, day: 2, hour: 3, minute: 4, second: 5).date!
        let dated = FileMeta(name: "IMG_1.HEIC", modified: modified, photoTaken: taken)
        expect("photo date", Engine.name(for: dated, rules: [rule(.date) { $0.dateSource = .photo; $0.placement = .replace; $0.dateFormat = "yyyyMMdd_HHmmss" }]), "20260614_091230.HEIC")
        expect("modified date prefix", Engine.name(for: dated, rules: [rule(.date) { $0.dateSource = .modified }]), "2025-01-02 IMG_1.HEIC")
        expect("date slashes made safe", Engine.name(for: dated, rules: [rule(.date) { $0.dateSource = .modified; $0.placement = .replace; $0.dateFormat = "dd/MM HH:mm" }]), "02-01 03.04.HEIC")
        expect("photo falls back", Engine.name(for: FileMeta(name: "a.png", modified: modified), rules: [rule(.date) { $0.dateSource = .photo; $0.placement = .replace; $0.dateFormat = "yyyy" }]), "2025.png")
        expect("missing date skipped", Engine.name(for: FileMeta(name: "a.png"), rules: [rule(.date) { $0.dateSource = .created }]), "a.png")

        // Trim and remove.
        expect("trim", Engine.name(for: FileMeta(name: "  draft   final  .txt"), rules: [rule(.trim) { _ in }]), "draft final.txt")
        expect("trim counts", Engine.name(for: photo, rules: [rule(.trim) { $0.dropFirst = 4; $0.dropLast = 1 }]), "401.JPG")
        expect("remove chars", Engine.name(for: FileMeta(name: "song (1) [live].mp3"), rules: [rule(.remove) { $0.characters = "()[]" }]), "song 1 live.mp3")
        expect("remove digits and spaces", Engine.name(for: FileMeta(name: "a 1 b 2.txt"), rules: [rule(.remove) { $0.digits = true; $0.spaces = true }]), "ab.txt")

        // Extension.
        expect("ext lower", Engine.name(for: photo, rules: [rule(.fileExtension) { $0.extensionMode = .lower }]), "IMG_4012.jpg")
        expect("ext set", Engine.name(for: photo, rules: [rule(.fileExtension) { $0.extensionMode = .set; $0.newExtension = ".jpeg" }]), "IMG_4012.jpeg")
        expect("ext remove", Engine.name(for: photo, rules: [rule(.fileExtension) { $0.extensionMode = .remove }]), "IMG_4012")
        expect("ext skips folders", Engine.name(for: FileMeta(name: "Album", isDirectory: true), rules: [rule(.fileExtension) { $0.extensionMode = .set; $0.newExtension = "x" }]), "Album")

        // Stacking and disabled rules.
        let stack = [rule(.replace) { $0.regex = true; $0.find = "^IMG_\\d+"; $0.replacement = "Lisbon" },
                     rule(.number) { $0.padding = 3 },
                     rule(.date) { $0.dateSource = .photo },
                     rule(.fileExtension) { $0.extensionMode = .lower },
                     rule(.insert) { $0.enabled = false; $0.text = "NO" }]
        expect("stacked", Engine.name(for: dated, index: 6, rules: stack), "2026-06-14 Lisbon 007.heic")

        // Validation.
        check("empty invalid", Engine.problem(with: ".txt", original: "a.txt") != nil)
        check("slash invalid", Engine.problem(with: "a/b", original: "a") != nil)
        check("normal valid", Engine.problem(with: "b.txt", original: "a.txt") == nil)

        // Planning.
        let ids = (0..<6).map { _ in UUID() }
        let none: (String, String) -> Bool = { _, _ in false }
        var plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "a", target: "b"),
                                 PlanEntry(id: ids[1], folder: "/d", original: "b", target: "a")], exists: none)
        check("swap allowed", plan[ids[0]] == .rename && plan[ids[1]] == .rename)
        plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "a", target: "x"),
                             PlanEntry(id: ids[1], folder: "/d", original: "b", target: "X")], exists: none)
        check("duplicate target, case folded", plan[ids[0]]?.isProblem == true && plan[ids[1]]?.isProblem == true)
        plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "a", target: "c"),
                             PlanEntry(id: ids[1], folder: "/e", original: "b", target: "c")], exists: none)
        check("same name in two folders", plan[ids[0]] == .rename && plan[ids[1]] == .rename)
        plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "a", target: "taken")], exists: { $1 == "taken" })
        check("exists on disk", plan[ids[0]]?.isProblem == true)
        plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "photo.jpg", target: "Photo.jpg")], exists: { _, _ in true })
        check("case only rename", plan[ids[0]] == .rename)
        // c is blocked by the disk, so it keeps its name, which blocks b from taking it, which blocks a.
        plan = Planner.plan([PlanEntry(id: ids[0], folder: "/d", original: "a", target: "b"),
                             PlanEntry(id: ids[1], folder: "/d", original: "b", target: "c"),
                             PlanEntry(id: ids[2], folder: "/d", original: "c", target: "d"),
                             PlanEntry(id: ids[3], folder: "/d", original: "e", target: "e")], exists: { $1 == "d" })
        check("cascading conflicts", plan[ids[0]]?.isProblem == true && plan[ids[1]]?.isProblem == true && plan[ids[2]]?.isProblem == true)
        check("unchanged", plan[ids[3]] == .unchanged)

        // Renaming real files, then undoing.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("rename-selftest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in [("a.txt", "A"), ("b.txt", "B"), ("photo.jpg", "P")] {
                try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            func url(_ n: String) -> URL { dir.appendingPathComponent(n) }
            func read(_ n: String) -> String { (try? String(contentsOf: url(n), encoding: .utf8)) ?? "" }
            let batch = [Move(from: url("a.txt"), to: url("b.txt")), Move(from: url("b.txt"), to: url("a.txt")),
                         Move(from: url("photo.jpg"), to: url("Photo.jpg"))]
            try Renamer.perform(batch)
            check("swap on disk", read("a.txt") == "B" && read("b.txt") == "A")
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            check("case change on disk", names.contains("Photo.jpg") && !names.contains("photo.jpg"), names.description)
            check("no temporary files left", !names.contains { $0.hasPrefix(".rename-") })
            try Renamer.perform(batch.reversed().map(\.inverse))
            let restored = try fm.contentsOfDirectory(atPath: dir.path)
            check("undo restores", read("a.txt") == "A" && read("b.txt") == "B" && restored.contains("photo.jpg"))
            var threw = false
            do { try Renamer.perform([Move(from: url("a.txt"), to: url("c.txt")), Move(from: url("missing"), to: url("d"))]) } catch { threw = true }
            check("failure throws", threw)
            check("failure rolls back", read("a.txt") == "A" && !fm.fileExists(atPath: url("c.txt").path))

            // Dropping folders: a plain folder adds its visible items, a package stays one item.
            let album = url("Album"), app = url("Tool.app"), rtfd = url("Notes.rtfd")
            for d in [album, app.appendingPathComponent("Contents"), rtfd] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
            for f in [album.appendingPathComponent("2.jpg"), album.appendingPathComponent("10.jpg"), album.appendingPathComponent(".hidden"),
                      app.appendingPathComponent("Contents/Info.plist"), rtfd.appendingPathComponent("TXT.rtf")] {
                fm.createFile(atPath: f.path, contents: Data())
            }
            let folder = RenameModel.collect([album]).map(\.lastPathComponent)
            check("folder adds its items in name order", folder == ["2.jpg", "10.jpg"], folder.description)
            let packages = RenameModel.collect([app, rtfd, url("gone.txt")]).map(\.lastPathComponent)
            check("packages stay whole", packages == ["Tool.app", "Notes.rtfd"], packages.description)
        } catch {
            check("temporary files", false, error.localizedDescription)
        }

        // The model end to end: apply, undo, redo and the toolbar's undo.
        MainActor.assumeIsolated {
            let dir = fm.temporaryDirectory.appendingPathComponent("rename-model-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: dir) }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["one.txt", "two.txt"] { fm.createFile(atPath: dir.appendingPathComponent(n).path, contents: Data()) }
            func listing() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
            let model = RenameModel(persist: false)
            let undo = UndoManager()
            undo.groupsByEvent = false
            model.undoManager = undo
            model.items = ["one.txt", "two.txt"].map { FileItem.load(dir.appendingPathComponent($0)) }
            model.rules = [rule(.insert) { $0.text = "x-"; $0.placement = .prefix }]
            check("model preview", model.rows.map(\.newName) == ["x-one.txt", "x-two.txt"] && model.renameCount == 2)
            undo.beginUndoGrouping()
            model.apply()
            undo.endUndoGrouping()
            check("model apply", listing() == ["x-one.txt", "x-two.txt"], listing().description)
            check("model follows files", model.items.map(\.name) == ["x-one.txt", "x-two.txt"])
            undo.undo()
            check("undo manager undo", listing() == ["one.txt", "two.txt"], listing().description)
            undo.redo()
            check("undo manager redo", listing() == ["x-one.txt", "x-two.txt"], listing().description)
            model.undoLastBatch()
            check("undo last batch", listing() == ["one.txt", "two.txt"] && model.lastBatch.isEmpty, listing().description)

            // An undo that fails (a file moved away meanwhile) changes nothing and keeps the batch.
            undo.beginUndoGrouping()
            model.apply()
            undo.endUndoGrouping()
            try? fm.moveItem(at: dir.appendingPathComponent("x-two.txt"), to: dir.appendingPathComponent("moved.txt"))
            undo.undo()
            check("failed undo keeps the batch", !model.lastBatch.isEmpty && model.errorMessage != nil)
            check("failed undo changes nothing", listing() == ["moved.txt", "x-one.txt"], listing().description)

            // Moving with a selection that is no longer in the list is a no-op, not a crash.
            model.selection = [UUID()]
            let before = model.items.map(\.id)
            model.moveSelection(-1)
            model.moveSelection(1)
            check("stale selection move", model.items.map(\.id) == before)
        }

        // Rules survive a JSON round trip.
        if let data = try? JSONEncoder().encode(stack), let back = try? JSONDecoder().decode([Rule].self, from: data) {
            check("rules round trip", back == stack)
        } else {
            check("rules round trip", false)
        }

        print("\(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }
}
