import CoreGraphics
import Foundation

// MARK: - Cells and rules

struct Cell: Hashable, Sendable {
    var x: Int
    var y: Int
}

/// A Life-like rule: which neighbour counts give birth to a dead cell and which keep a live one alive.
struct Rule: Hashable, Sendable {
    /// Bit n set: a dead cell with n live neighbours is born.
    var birth: UInt16
    /// Bit n set: a live cell with n live neighbours survives.
    var survive: UInt16

    static let conway = Rule(birth: 1 << 3, survive: 1 << 2 | 1 << 3)

    static let presets: [(name: String, rule: Rule)] = [
        ("Conway's Life", .conway),
        ("HighLife", Rule("B36/S23")!),
        ("Day and Night", Rule("B3678/S34678")!),
        ("Seeds", Rule("B2/S")!),
        ("Life Without Death", Rule("B3/S012345678")!),
        ("Maze", Rule("B3/S12345")!),
    ]

    init(birth: UInt16, survive: UInt16) {
        self.birth = birth
        self.survive = survive
    }

    /// Parses `B3/S23` (any case, slash optional) or the older survival/birth form `23/3`.
    init?(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        func mask<S: StringProtocol>(_ s: S) -> UInt16? {
            var m: UInt16 = 0
            for c in s {
                guard let d = c.wholeNumberValue, d <= 8 else { return nil }
                m |= 1 << d
            }
            return m
        }
        if t.hasPrefix("B") {
            var rest = t.dropFirst()
            let b = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(b.count)
            if rest.hasPrefix("/") { rest = rest.dropFirst() }
            guard rest.hasPrefix("S"), let bm = mask(b), let sm = mask(rest.dropFirst()) else { return nil }
            self.init(birth: bm, survive: sm)
        } else {
            let parts = t.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let sm = mask(parts[0]), let bm = mask(parts[1]) else { return nil }
            self.init(birth: bm, survive: sm)
        }
    }

    var notation: String {
        func digits(_ m: UInt16) -> String { (0...8).filter { m >> $0 & 1 == 1 }.map(String.init).joined() }
        return "B\(digits(birth))/S\(digits(survive))"
    }

    var name: String { Rule.presets.first { $0.rule == self }?.name ?? notation }
}

// MARK: - Grid

/// A bit-packed grid: each row is `stride` 64-bit words, bit i of word w is column 64w + i.
/// Bits past `width` are always zero.
struct LifeGrid: Equatable, Sendable {
    let width: Int
    let height: Int
    let stride: Int
    private(set) var words: [UInt64]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        stride = (self.width + 63) / 64
        words = [UInt64](repeating: 0, count: stride * self.height)
    }

    var lastMask: UInt64 {
        let r = width % 64
        return r == 0 ? ~0 : (1 << UInt64(r)) - 1
    }

    subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, y >= 0, x < width, y < height else { return false }
            return words[y * stride + x >> 6] >> UInt64(x & 63) & 1 == 1
        }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let bit: UInt64 = 1 << UInt64(x & 63)
            if newValue { words[y * stride + x >> 6] |= bit } else { words[y * stride + x >> 6] &= ~bit }
        }
    }

    var population: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    /// Calls `body` with the column and row of every live cell, row by row.
    func forEachLive(_ body: (Int, Int) -> Void) {
        for y in 0..<height {
            for w in 0..<stride {
                var word = words[y * stride + w]
                while word != 0 {
                    body(w * 64 + word.trailingZeroBitCount, y)
                    word &= word - 1
                }
            }
        }
    }

    /// The next generation, computed 64 cells at a time with a bit-sliced neighbour counter.
    func stepped(rule: Rule, wrap: Bool) -> LifeGrid {
        var next = LifeGrid(width: width, height: height)
        let n = stride, mask = lastMask
        let top = width - 1, topWord = top >> 6, topBit = UInt64(top & 63)
        // For every word, the row shifted so each bit holds its west (x - 1) or east (x + 1) neighbour.
        var west = [UInt64](repeating: 0, count: words.count)
        var east = [UInt64](repeating: 0, count: words.count)
        for y in 0..<height {
            let o = y * n
            for w in 0..<n {
                var l = words[o + w] << 1
                if w > 0 { l |= words[o + w - 1] >> 63 }
                var r = words[o + w] >> 1
                if w + 1 < n { r |= words[o + w + 1] << 63 }
                west[o + w] = l
                east[o + w] = r
            }
            west[o + n - 1] &= mask
            if wrap {
                west[o] |= words[o + topWord] >> topBit & 1
                east[o + topWord] |= (words[o] & 1) << topBit
            }
        }
        let births = (0...8).filter { rule.birth >> $0 & 1 == 1 }
        let survivals = (0...8).filter { rule.survive >> $0 & 1 == 1 }
        for y in 0..<height {
            let up = y > 0 ? y - 1 : (wrap ? height - 1 : -1)
            let down = y < height - 1 ? y + 1 : (wrap ? 0 : -1)
            for w in 0..<n {
                let i = y * n + w
                var s0: UInt64 = 0, s1: UInt64 = 0, s2: UInt64 = 0, s3: UInt64 = 0
                @inline(__always) func add(_ x: UInt64) {
                    let c0 = s0 & x
                    s0 ^= x
                    let c1 = s1 & c0
                    s1 ^= c0
                    let c2 = s2 & c1
                    s2 ^= c1
                    s3 |= c2
                }
                if up >= 0 {
                    let u = up * n + w
                    add(west[u]); add(words[u]); add(east[u])
                }
                add(west[i]); add(east[i])
                if down >= 0 {
                    let d = down * n + w
                    add(west[d]); add(words[d]); add(east[d])
                }
                @inline(__always) func equals(_ k: Int) -> UInt64 {
                    (k & 1 != 0 ? s0 : ~s0) & (k & 2 != 0 ? s1 : ~s1) & (k & 4 != 0 ? s2 : ~s2) & (k & 8 != 0 ? s3 : ~s3)
                }
                var born: UInt64 = 0, stay: UInt64 = 0
                for k in births { born |= equals(k) }
                for k in survivals { stay |= equals(k) }
                let cur = words[i]
                var v = (born & ~cur) | (stay & cur)
                if w == n - 1 { v &= mask }
                next.words[i] = v
            }
        }
        return next
    }

    /// A grid of a new size with this one's cells centred in it.
    func resized(width newWidth: Int, height newHeight: Int) -> LifeGrid {
        var out = LifeGrid(width: newWidth, height: newHeight)
        let dx = (out.width - width) / 2, dy = (out.height - height) / 2
        forEachLive { x, y in out[x + dx, y + dy] = true }
        return out
    }

    /// Ors a pattern's cells in with its top left corner at `origin`, wrapping or clipping at the edges.
    mutating func stamp(_ pattern: Pattern, at origin: Cell, wrap: Bool) -> [Cell] {
        var placed: [Cell] = []
        for c in pattern.cells {
            var x = origin.x + c.x, y = origin.y + c.y
            if wrap {
                x = ((x % width) + width) % width
                y = ((y % height) + height) % height
            }
            guard x >= 0, y >= 0, x < width, y < height else { continue }
            self[x, y] = true
            placed.append(Cell(x: x, y: y))
        }
        return placed
    }

    /// Fills every cell at random with the given probability of being alive.
    mutating func randomize(density: Double, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        var rng = SplitMix64(seed: seed)
        let threshold = UInt64(max(0, min(1, density)) * Double(1 << 53))
        for y in 0..<height {
            for x in 0..<width { self[x, y] = rng.next() >> 11 < threshold }
        }
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Board

/// The grid plus how long each cell has lived and the generation count: everything undo restores.
struct Board: Equatable, Sendable {
    var grid: LifeGrid
    var ages: [UInt8]
    var generation = 0

    init(width: Int, height: Int) {
        grid = LifeGrid(width: width, height: height)
        ages = [UInt8](repeating: 0, count: grid.width * grid.height)
    }

    init(grid: LifeGrid) {
        self.grid = grid
        ages = [UInt8](repeating: 0, count: grid.width * grid.height)
        grid.forEachLive { x, y in ages[y * grid.width + x] = 1 }
    }

    mutating func step(rule: Rule, wrap: Bool) {
        let next = next(rule: rule, wrap: wrap)
        var fresh = [UInt8](repeating: 0, count: ages.count)
        let w = grid.width
        next.forEachLive { x, y in
            let a = ages[y * w + x]
            fresh[y * w + x] = a == 255 ? 255 : a + 1
        }
        grid = next
        ages = fresh
        generation += 1
    }

    private func next(rule: Rule, wrap: Bool) -> LifeGrid { grid.stepped(rule: rule, wrap: wrap) }

    func age(_ x: Int, _ y: Int) -> UInt8 { ages[y * grid.width + x] }

    mutating func set(_ x: Int, _ y: Int, _ alive: Bool) {
        guard x >= 0, y >= 0, x < grid.width, y < grid.height else { return }
        grid[x, y] = alive
        ages[y * grid.width + x] = alive ? max(1, ages[y * grid.width + x]) : 0
    }

    mutating func stamp(_ pattern: Pattern, at origin: Cell, wrap: Bool) {
        for c in grid.stamp(pattern, at: origin, wrap: wrap) where ages[c.y * grid.width + c.x] == 0 {
            ages[c.y * grid.width + c.x] = 1
        }
    }

    mutating func resize(width: Int, height: Int) {
        let g = generation
        self = Board(grid: grid.resized(width: width, height: height))
        generation = g
    }
}

// MARK: - Patterns and RLE

struct Pattern: Equatable, Sendable {
    var name: String
    var width: Int
    var height: Int
    /// Live cells, relative to the top left corner, sorted by row then column.
    var cells: [Cell]
    var rule: Rule?

    init(name: String, width: Int, height: Int, cells: [Cell], rule: Rule? = nil) {
        self.name = name
        self.cells = Array(Set(cells)).sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        self.width = max(width, (self.cells.map(\.x).max() ?? -1) + 1)
        self.height = max(height, (self.cells.map(\.y).max() ?? -1) + 1)
        self.rule = rule
    }

    /// A library pattern from a known good RLE string.
    init(_ name: String, rle: String) {
        self = try! Pattern.parse(rle)
        self.name = name
    }

    /// Turned a quarter clockwise.
    func rotated() -> Pattern {
        Pattern(name: name, width: height, height: width, cells: cells.map { Cell(x: height - 1 - $0.y, y: $0.x) }, rule: rule)
    }

    /// The live cells of a grid, cropped to their bounding box. Nil for an empty grid.
    static func capture(_ grid: LifeGrid, name: String = "Untitled", rule: Rule? = nil) -> Pattern? {
        var cells: [Cell] = []
        grid.forEachLive { x, y in cells.append(Cell(x: x, y: y)) }
        guard let minX = cells.map(\.x).min(), let minY = cells.map(\.y).min() else { return nil }
        let shifted = cells.map { Cell(x: $0.x - minX, y: $0.y - minY) }
        return Pattern(name: name, width: 0, height: 0, cells: shifted, rule: rule)
    }

    enum ParseError: LocalizedError {
        case notAPattern
        case empty

        var errorDescription: String? {
            switch self {
            case .notAPattern: "That is not an RLE or plain text Life pattern."
            case .empty: "That pattern has no live cells."
            }
        }
    }

    /// Reads RLE (`x = 3, y = 3, rule = B3/S23` then `bo$2bo$3o!`) or LifeWiki plain text (`.O.` rows).
    static func parse(_ text: String) throws -> Pattern {
        let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var name = "Untitled"
        for line in lines where line.hasPrefix("#N") || line.hasPrefix("!Name:") {
            let n = line.hasPrefix("#N") ? line.dropFirst(2) : line.dropFirst(6)
            let trimmed = n.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { name = trimmed }
        }
        let body = lines.filter { !$0.hasPrefix("#") && !$0.hasPrefix("!") && !$0.isEmpty }
        // Plain text: every remaining line only holds dots and O or * marks.
        let plainSet = Set(".Oo*")
        if !body.isEmpty, body.allSatisfy({ $0.allSatisfy { plainSet.contains($0) } }),
           body.contains(where: { $0.contains(".") || $0.contains("O") || $0.contains("*") }),
           !(body.count == 1 && body[0].allSatisfy { $0 == "o" }) {
            var cells: [Cell] = []
            for (y, line) in lines.filter({ !$0.hasPrefix("!") && !$0.hasPrefix("#") }).enumerated() {
                for (x, c) in line.enumerated() where c == "O" || c == "o" || c == "*" { cells.append(Cell(x: x, y: y)) }
            }
            guard let minX = cells.map(\.x).min(), let minY = cells.map(\.y).min() else { throw ParseError.empty }
            return Pattern(name: name, width: 0, height: 0, cells: cells.map { Cell(x: $0.x - minX, y: $0.y - minY) })
        }

        var width = 0, height = 0
        var rule: Rule?
        var data = ""
        var sawHeader = false
        for line in body {
            if !sawHeader, data.isEmpty, line.hasPrefix("x") || line.hasPrefix("X") {
                sawHeader = true
                for part in line.split(separator: ",") {
                    let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "x": width = Int(kv[1]) ?? 0
                    case "y": height = Int(kv[1]) ?? 0
                    case "rule": rule = Rule(String(kv[1].prefix { $0 != ":" }))
                    default: break
                    }
                }
            } else {
                data += line
            }
        }
        let allowed = Set("0123456789bo$!.ABCDEFGHIJKLMNOPQRSTUVWXYZ \t")
        guard data.contains(where: { "bo$".contains($0) }) || sawHeader,
              data.allSatisfy({ allowed.contains($0) }) else { throw ParseError.notAPattern }

        var cells: [Cell] = []
        var x = 0, y = 0, count = 0
        loop: for c in data {
            switch c {
            case "0"..."9":
                count = count * 10 + c.wholeNumberValue!
                guard count < 100_000 else { throw ParseError.notAPattern }
            case "b", ".":
                x += max(count, 1); count = 0
            case "$":
                y += max(count, 1); x = 0; count = 0
            case "!":
                break loop
            case " ", "\t":
                continue
            default: // o, or any multi-state letter: alive.
                for _ in 0..<max(count, 1) { cells.append(Cell(x: x, y: y)); x += 1 }
                count = 0
            }
        }
        guard !cells.isEmpty else { throw ParseError.empty }
        return Pattern(name: name, width: width, height: height, cells: cells, rule: rule)
    }

    /// RLE text with a header, lines kept to 70 characters.
    func rle(comment: String? = nil) -> String {
        var tokens: [String] = []
        func emit(_ n: Int, _ tag: Character) {
            guard n > 0 else { return }
            tokens.append(n == 1 ? String(tag) : "\(n)\(tag)")
        }
        let rows = Dictionary(grouping: cells, by: \.y)
        var pendingRows = 0
        var first = true
        for y in 0..<height {
            guard let row = rows[y]?.map(\.x).sorted() else { pendingRows += 1; continue }
            if !first { emit(pendingRows + 1, "$") }
            first = false
            pendingRows = 0
            var x = 0, i = 0
            while i < row.count {
                emit(row[i] - x, "b")
                var run = 1
                while i + run < row.count, row[i + run] == row[i] + run { run += 1 }
                emit(run, "o")
                x = row[i] + run
                i += run
            }
        }
        tokens.append("!")
        var lines: [String] = []
        if name != "Untitled" { lines.append("#N \(name)") }
        if let comment { lines.append("#C \(comment)") }
        lines.append("x = \(width), y = \(height), rule = \((rule ?? .conway).notation)")
        var line = ""
        for t in tokens {
            if line.count + t.count > 70 { lines.append(line); line = "" }
            line += t
        }
        lines.append(line)
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Library

struct LibraryEntry: Identifiable {
    let category: String
    let pattern: Pattern
    let note: String
    var id: String { pattern.name }
}

enum Library {
    static let entries: [LibraryEntry] = [
        LibraryEntry(category: "Spaceships", pattern: Pattern("Glider", rle: "bo$2bo$3o!"), note: "Glides diagonally, period 4"),
        LibraryEntry(category: "Spaceships", pattern: Pattern("Lightweight spaceship", rle: "bo2bo$o4b$o3bo$4o!"), note: "Flies sideways, period 4"),
        LibraryEntry(category: "Spaceships", pattern: Pattern("Middleweight spaceship", rle: "3bo2b$bo3bo$o5b$o4bo$5o!"),
                     note: "Flies sideways, period 4"),
        LibraryEntry(category: "Spaceships", pattern: Pattern("Heavyweight spaceship", rle: "3b2o2b$bo4bo$o6b$o5bo$6o!"),
                     note: "Flies sideways, period 4"),
        LibraryEntry(category: "Oscillators", pattern: Pattern("Pulsar", rle: """
            2b3o3b3o2$o4bobo4bo$o4bobo4bo$o4bobo4bo$2b3o3b3o2$2b3o3b3o$o4bobo4bo$o4bobo4bo$o4bobo4bo2$2b3o3b3o!
            """), note: "Period 3 oscillator"),
        LibraryEntry(category: "Oscillators", pattern: Pattern("Pentadecathlon", rle: "2bo4bo2b$2ob4ob2o$2bo4bo!"), note: "Period 15 oscillator"),
        LibraryEntry(category: "Guns", pattern: Pattern("Gosper glider gun", rle: """
            24bo$22bobo$12b2o6b2o12b2o$11bo3bo4b2o12b2o$2o8bo5bo3b2o$2o8bo3bob2o4bobo$10bo5bo7bo$11bo3bo$12b2o!
            """), note: "A glider every 30 generations"),
        LibraryEntry(category: "Methuselahs", pattern: Pattern("R-pentomino", rle: "b2o$2o$bo!"), note: "Settles at generation 1,103"),
        LibraryEntry(category: "Methuselahs", pattern: Pattern("Acorn", rle: "bo5b$3bo3b$2o2b3o!"), note: "Grows for 5,206 generations"),
        LibraryEntry(category: "Methuselahs", pattern: Pattern("Diehard", rle: "6bob$2o6b$bo3b3o!"), note: "Gone after 130 generations"),
    ]

    static var categories: [String] {
        var seen: [String] = []
        for e in entries where !seen.contains(e.category) { seen.append(e.category) }
        return seen
    }

    static func entry(_ id: String?) -> LibraryEntry? { entries.first { $0.id == id } }
}

// MARK: - Sizes

struct GridSize: Hashable, Identifiable {
    let width: Int
    let height: Int
    var id: String { label }
    var label: String { "\(width) \u{00D7} \(height)" }

    static let all = [
        GridSize(width: 64, height: 48), GridSize(width: 120, height: 90), GridSize(width: 160, height: 120),
        GridSize(width: 200, height: 150), GridSize(width: 300, height: 225), GridSize(width: 400, height: 300),
    ]
    static let standard = all[1]
}

// MARK: - Rendering

/// Paints a board into a one pixel per cell image: dead cells transparent, live cells coloured by age.
enum Renderer {
    /// Newborn cells are almost white mint; long lived ones settle into deep teal.
    static let palette: [UInt32] = {
        let stops: [(Double, UInt32)] = [(1, 0xE8FFF5), (2, 0xA8FFD8), (4, 0x6EF7BE), (10, 0x3EDB9F), (30, 0x22B183), (90, 0x178A69), (255, 0x13765C)]
        return (0..<256).map { age -> UInt32 in
            guard age > 0 else { return 0 }
            let a = Double(age)
            var i = 0
            while i < stops.count - 2, a > stops[i + 1].0 { i += 1 }
            let (a0, c0) = stops[i], (a1, c1) = stops[i + 1]
            let t = max(0, min(1, (log(a) - log(a0)) / (log(a1) - log(a0))))
            func ch(_ c: UInt32, _ s: UInt32) -> Double { Double((c >> s) & 0xFF) }
            func mix(_ s: UInt32) -> UInt32 { UInt32((ch(c0, s) + (ch(c1, s) - ch(c0, s)) * t).rounded()) }
            return mix(16) | mix(8) << 8 | mix(0) << 16 | 0xFF << 24
        }
    }()

    static func image(_ board: Board) -> CGImage? {
        let w = board.grid.width, h = board.grid.height
        var pixels = [UInt32](repeating: 0, count: w * h)
        board.grid.forEachLive { x, y in pixels[y * w + x] = palette[Int(board.ages[y * w + x])] }
        let data = pixels.withUnsafeBytes { Data($0) } as CFData
        guard let provider = CGDataProvider(data: data), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
