import Foundation

/// `Life --selftest`: checks the rules, the bit-sliced step against a plain one, known patterns and RLE.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ ok: Bool, _ name: String) {
        checks += 1
        if !ok {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    /// The textbook step, one cell at a time.
    static func naiveStep(_ g: LifeGrid, rule: Rule, wrap: Bool) -> LifeGrid {
        var out = LifeGrid(width: g.width, height: g.height)
        for y in 0..<g.height {
            for x in 0..<g.width {
                var n = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        var nx = x + dx, ny = y + dy
                        if wrap {
                            nx = (nx + g.width) % g.width
                            ny = (ny + g.height) % g.height
                        }
                        if g[nx, ny] { n += 1 }
                    }
                }
                let alive = g[x, y]
                out[x, y] = alive ? rule.survive >> n & 1 == 1 : rule.birth >> n & 1 == 1
            }
        }
        return out
    }

    static func grid(_ pattern: Pattern, _ w: Int, _ h: Int, at x: Int, _ y: Int) -> LifeGrid {
        var g = LifeGrid(width: w, height: h)
        _ = g.stamp(pattern, at: Cell(x: x, y: y), wrap: false)
        return g
    }

    static func run(_ g: LifeGrid, _ n: Int, rule: Rule = .conway, wrap: Bool = false) -> LifeGrid {
        var g = g
        for _ in 0..<n { g = g.stepped(rule: rule, wrap: wrap) }
        return g
    }

    static func lib(_ name: String) -> Pattern { Library.entry(name)!.pattern }

    static func run() -> Int32 {
        // Rules.
        check(Rule("B3/S23") == .conway, "B3/S23 parses as Conway")
        check(Rule("b3/s23") == .conway, "rule parsing ignores case")
        check(Rule("B3S23") == .conway, "rule parsing allows a missing slash")
        check(Rule("23/3") == .conway, "survival/birth notation parses")
        check(Rule("B36/S23")?.notation == "B36/S23", "HighLife notation round trips")
        check(Rule("B2/S")?.survive == 0, "Seeds has no survival")
        check(Rule("B9/S23") == nil && Rule("hello") == nil && Rule("") == nil, "bad rules are rejected")
        check(Rule.conway.name == "Conway's Life", "preset names")

        // The fast step agrees with the textbook one, across word boundaries, edges and rules.
        var agree = true
        for (i, size) in [(70, 33), (64, 10), (128, 7), (5, 5), (130, 20), (65, 3)].enumerated() {
            for wrap in [false, true] {
                for rule in [Rule.conway, Rule("B36/S23")!, Rule("B3678/S34678")!, Rule("B2/S")!] {
                    var g = LifeGrid(width: size.0, height: size.1)
                    g.randomize(density: 0.35, seed: UInt64(i * 31 + 7))
                    for _ in 0..<12 {
                        let fast = g.stepped(rule: rule, wrap: wrap), slow = naiveStep(g, rule: rule, wrap: wrap)
                        if fast != slow { agree = false }
                        g = fast
                    }
                }
            }
        }
        check(agree, "bit-sliced step matches the cell by cell step")

        // Still lifes and oscillators.
        let block = Pattern(name: "Block", width: 2, height: 2, cells: [Cell(x: 0, y: 0), Cell(x: 1, y: 0), Cell(x: 0, y: 1), Cell(x: 1, y: 1)])
        check(run(grid(block, 8, 8, at: 3, 3), 5) == grid(block, 8, 8, at: 3, 3), "block is still")
        let blinker = try? Pattern.parse("3o!")
        let b0 = grid(blinker!, 9, 9, at: 3, 4)
        check(run(b0, 1) != b0 && run(b0, 2) == b0, "blinker has period 2")
        let pulsar = grid(lib("Pulsar"), 25, 25, at: 6, 6)
        check(run(pulsar, 3) == pulsar && run(pulsar, 1) != pulsar, "pulsar has period 3")
        let penta = grid(lib("Pentadecathlon"), 30, 24, at: 10, 10)
        check(run(penta, 15) == penta && run(penta, 5) != penta, "pentadecathlon has period 15")

        // Spaceships.
        let glider = lib("Glider")
        check(run(grid(glider, 20, 20, at: 5, 5), 4) == grid(glider, 20, 20, at: 6, 6), "glider moves one cell diagonally in 4 generations")
        let torus = grid(glider, 10, 10, at: 2, 2)
        check(run(torus, 40, wrap: true) == torus, "glider wraps around a 10 by 10 torus in 40 generations")
        check(run(torus, 40, wrap: false) != torus, "a walled board does not wrap")
        let lwss = grid(lib("Lightweight spaceship"), 30, 12, at: 12, 4)
        let moved = run(lwss, 4)
        check(moved == grid(lib("Lightweight spaceship"), 30, 12, at: 10, 4) || moved == grid(lib("Lightweight spaceship"), 30, 12, at: 14, 4),
              "lightweight spaceship moves two cells in 4 generations")

        // Gun and methuselah.
        let gun = grid(lib("Gosper glider gun"), 100, 70, at: 2, 2)
        check(gun.population == 36 && run(gun, 30).population == 41 && run(gun, 60).population == 46, "gun fires a glider every 30 generations")
        let diehard = grid(lib("Diehard"), 120, 90, at: 56, 44)
        check(run(diehard, 129).population > 0 && run(diehard, 130).population == 0, "diehard vanishes at generation 130")

        // Library populations.
        let expected = ["Glider": 5, "Lightweight spaceship": 9, "Middleweight spaceship": 11, "Heavyweight spaceship": 13,
                        "Pulsar": 48, "Pentadecathlon": 12, "Gosper glider gun": 36, "R-pentomino": 5, "Acorn": 7, "Diehard": 7]
        check(Library.entries.allSatisfy { expected[$0.pattern.name] == $0.pattern.cells.count }, "library patterns have their known populations")
        check(lib("Gosper glider gun").width == 36 && lib("Gosper glider gun").height == 9, "gun is 36 by 9")
        check(lib("Pulsar").width == 13 && lib("Pulsar").height == 13, "pulsar is 13 by 13")

        // RLE parsing.
        let g = try? Pattern.parse("bo$2bo$3o!")
        check(g?.cells == [Cell(x: 1, y: 0), Cell(x: 2, y: 1), Cell(x: 0, y: 2), Cell(x: 1, y: 2), Cell(x: 2, y: 2)], "glider RLE cells")
        let file = """
            #N Gosper glider gun
            #C A comment line
            #O Bill Gosper
            x = 36, y = 9, rule = B3/S23
            24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$
            10bo5bo7bo$11bo3bo$12b2o!
            """
        let parsed = try? Pattern.parse(file)
        check(parsed?.name == "Gosper glider gun" && parsed?.rule == .conway && parsed?.cells.count == 36 && parsed?.width == 36,
              "RLE with comments, header and wrapped lines")
        check((try? Pattern.parse("x = 3, y = 3, rule = B36/S23:T100,100\nbo$2bo$3o!"))?.rule == Rule("B36/S23"), "rule with a bounded grid suffix")
        let plain = try? Pattern.parse("!Name: Glider\n.O.\n..O\nOOO\n")
        check(plain?.cells == g?.cells && plain?.name == "Glider", "plain text format")
        check((try? Pattern.parse("Hello, world")) == nil, "prose is rejected")
        check((try? Pattern.parse("x = 3, y = 3\n3b!")) == nil, "a pattern with no cells is rejected")
        check((try? Pattern.parse("3o$2$o2bo!"))?.cells.count == 5 && (try? Pattern.parse("3o$2$o2bo!"))?.height == 4, "multi-row skips")

        // RLE writing.
        var round = true, short = true
        for seed in 1...6 {
            var grid = LifeGrid(width: 90, height: 40)
            grid.randomize(density: 0.3, seed: UInt64(seed))
            guard let p = Pattern.capture(grid) else { round = false; continue }
            let text = p.rle()
            if text.split(separator: "\n").contains(where: { $0.count > 70 }) { short = false }
            if (try? Pattern.parse(text))?.cells != p.cells { round = false }
        }
        check(round, "RLE export parses back to the same cells")
        check(short, "RLE lines stay within 70 characters")
        check(lib("Glider").rle().hasSuffix("x = 3, y = 3, rule = B3/S23\nbo$2bo$3o!\n"), "glider RLE text")
        check(Pattern(name: "x", width: 0, height: 0, cells: [Cell(x: 0, y: 0), Cell(x: 0, y: 3)]).rle().contains("o3$o!"), "empty rows collapse")

        // Geometry.
        var r = lib("Gosper glider gun")
        for _ in 0..<4 { r = r.rotated() }
        check(r == lib("Gosper glider gun"), "four quarter turns are the identity")
        check(lib("Gosper glider gun").rotated().width == 9, "rotation swaps width and height")
        var edge = LifeGrid(width: 20, height: 20)
        check(edge.stamp(glider, at: Cell(x: 18, y: 18), wrap: true).count == 5 && edge.population == 5, "stamping wraps on a torus")
        var wall = LifeGrid(width: 20, height: 20)
        check(wall.stamp(glider, at: Cell(x: 18, y: 18), wrap: false).count == 1, "stamping clips at walls")
        let big = grid(lib("Pulsar"), 30, 30, at: 3, 3).resized(width: 64, height: 40)
        check(big.population == 48 && big.width == 64, "resizing keeps cells")
        check(Pattern.capture(grid(glider, 40, 40, at: 17, 9)) == glider.renamed("Untitled"), "capture crops to the live cells")

        // Ages and random fill.
        var board = Board(grid: grid(block, 8, 8, at: 2, 2))
        for _ in 0..<3 { board.step(rule: .conway, wrap: false) }
        check(board.age(2, 2) == 4 && board.age(0, 0) == 0 && board.generation == 3, "cells age while they live")
        var soup = LifeGrid(width: 200, height: 150)
        soup.randomize(density: 0.25, seed: 42)
        check(abs(Double(soup.population) / 30_000 - 0.25) < 0.02, "random fill honours the density")
        check(Renderer.palette[1] != Renderer.palette[200] && Renderer.palette[0] == 0, "age palette")
        check(Renderer.image(board)?.width == 8, "board renders to an image")

        // Hostile or odd input: refused quickly, never parsed into millions of cells.
        let flood = String(repeating: "99999o$", count: 5_000) + "!"
        let floodStart = Date()
        var floodError: Error?
        do { _ = try Pattern.parse(flood) } catch { floodError = error }
        check((floodError as? Pattern.ParseError) == .tooLarge && Date().timeIntervalSince(floodStart) < 0.5, "a flood of cells is refused quickly")
        check((try? Pattern.parse("99999b99999b99999bo!")) == nil, "a cell far off the board is refused")
        check((try? Pattern.parse(String(repeating: "99999$", count: 50) + "o!")) == nil, "a cell far below the board is refused")
        check((try? Pattern.parse("")) == nil && (try? Pattern.parse("\n\n  \n")) == nil, "empty text is rejected")
        check((try? Pattern.parse("x = 3, y = 3\nbo$2bo$3o\n!"))?.cells.count == 5, "a closing ! on its own line")
        check((try? Pattern.parse("bo$2bo$3o!\u{00E9}\u{1F600}")) != nil, "text after the closing ! is ignored")
        check((try? Pattern.parse("b\u{1F600}o!")) == nil, "emoji inside the cells are rejected")

        // Opening files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LifeSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latin = dir.appendingPathComponent("latin.rle"), empty = dir.appendingPathComponent("empty.rle")
        // "#O Jürgen" in Latin-1: the 0xFC byte is not valid UTF-8.
        try? (Data("#O J".utf8) + Data([0xFC]) + Data("rgen\nx = 3, y = 3\nbo$2bo$3o!\n".utf8)).write(to: latin)
        try? Data().write(to: empty)
        check((try? Pattern.parse(LifeModel.readPattern(latin)))?.cells.count == 5, "a file with Latin-1 comments opens")
        check((try? Pattern.parse(LifeModel.readPattern(empty))) == nil, "an empty file is rejected")
        check((try? LifeModel.readPattern(dir.appendingPathComponent("missing.rle"))) == nil, "a missing file throws")

        // Board sizes for opened patterns.
        let small = GridSize.all[1], largest = GridSize.all.last!
        check(LifeModel.boardSize(for: glider, current: small) == small, "a pattern that fits keeps the board size")
        let wide = Pattern(name: "w", width: 398, height: 10, cells: [Cell(x: 0, y: 0), Cell(x: 397, y: 9)])
        check(LifeModel.boardSize(for: wide, current: small) == largest, "a pattern 398 wide opens on the 400 board")
        check(LifeModel.boardSize(for: lib("Gosper glider gun"), current: GridSize.all[0]) == GridSize.all[0], "the gun fits the smallest board")
        let huge = Pattern(name: "h", width: 401, height: 3, cells: [Cell(x: 400, y: 0)])
        check(LifeModel.boardSize(for: huge, current: small) == nil, "a pattern wider than 400 is refused")

        // A whole frame at the top speed: step, age every cell and render the image.
        var frameBoard = Board(width: 400, height: 300)
        frameBoard.grid.randomize(density: 0.3, seed: 5)
        let frameStart = Date()
        for _ in 0..<60 {
            frameBoard.step(rule: .conway, wrap: true)
            _ = Renderer.image(frameBoard)
        }
        let frameTime = Date().timeIntervalSince(frameStart)
        check(frameTime < 0.6, "60 full frames of 400 by 300 fit in a second (took \(String(format: "%.3f", frameTime)) s)")

        // Speed: the largest board at 60 generations a second has time to spare.
        var large = LifeGrid(width: 400, height: 300)
        large.randomize(density: 0.3, seed: 9)
        let start = Date()
        for _ in 0..<60 { large = large.stepped(rule: .conway, wrap: true) }
        let elapsed = Date().timeIntervalSince(start)
        check(elapsed < 0.5, "60 steps of 400 by 300 take under half a second (took \(String(format: "%.3f", elapsed)) s)")

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }
}

extension Pattern {
    func renamed(_ name: String) -> Pattern {
        var p = self
        p.name = name
        return p
    }
}
