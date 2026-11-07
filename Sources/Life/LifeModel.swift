import AppKit
import Kit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct Notice: Equatable {
    var text: String
    var url: URL?
    var isError = false
}

/// The app's state: the board, the simulation clock, settings, and the pattern being placed.
@MainActor @Observable
final class LifeModel {
    static let shared = LifeModel(persist: !Desktop.isSnapshot)

    var board: Board {
        didSet { refresh() }
    }
    private(set) var image: CGImage?
    private(set) var population = 0
    private(set) var history: [Int] = [0]

    var isRunning = false {
        didSet { if isRunning != oldValue { schedule() } }
    }
    var speed: Double {
        didSet { save("speed", speed); if isRunning { schedule() } }
    }
    var density: Double {
        didSet { save("density", density) }
    }
    var rule: Rule {
        didSet { save("rule", rule.notation) }
    }
    var wrap: Bool {
        didSet { save("wrap", wrap) }
    }
    var showGrid: Bool {
        didSet { save("showGrid", showGrid) }
    }
    /// The library pattern chosen in the sidebar; choosing one starts placing it.
    var selectedPattern: String? {
        didSet {
            guard selectedPattern != oldValue else { return }
            placing = Library.entry(selectedPattern)?.pattern
        }
    }
    /// The pattern that follows the pointer until it is clicked onto the board.
    var placing: Pattern?
    var hover: Cell?
    var notice: Notice?

    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(persist: Bool) {
        self.persist = persist
        let d = UserDefaults.standard
        let size = persist ? GridSize.all.first { $0.width == d.integer(forKey: "columns") && $0.height == d.integer(forKey: "rows") } : nil
        let s = size ?? .standard
        board = Board(width: s.width, height: s.height)
        speed = persist && d.object(forKey: "speed") != nil ? d.double(forKey: "speed") : 20
        let savedDensity = persist && d.object(forKey: "density") != nil ? d.double(forKey: "density") : 0.3
        density = Self.densities.min { abs($0 - savedDensity) < abs($1 - savedDensity) } ?? 0.3
        rule = (persist ? d.string(forKey: "rule").flatMap(Rule.init) : nil) ?? .conway
        wrap = persist && d.object(forKey: "wrap") != nil ? d.bool(forKey: "wrap") : true
        showGrid = persist && d.object(forKey: "showGrid") != nil ? d.bool(forKey: "showGrid") : true
        refresh()
    }

    private func save(_ key: String, _ value: Any) {
        guard persist else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func refresh() {
        image = Renderer.image(board)
        population = board.grid.population
    }

    static let densities = [0.1, 0.2, 0.3, 0.4, 0.5]

    var size: GridSize { GridSize(width: board.grid.width, height: board.grid.height) }

    // MARK: Simulation

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isRunning, !Desktop.isSnapshot else { return }
        let t = Timer(timeInterval: 1 / max(1, speed), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func toggleRunning() {
        if !isRunning && population == 0 {
            show("The board is empty. Draw some cells or pick a pattern first.")
            return
        }
        isRunning.toggle()
    }

    func step() {
        var b = board
        b.step(rule: rule, wrap: wrap)
        board = b
        history.append(population)
        if history.count > 240 { history.removeFirst(history.count - 240) }
        if population == 0 { isRunning = false }
    }

    func faster() { speed = min(60, (speed * 1.5).rounded()) }
    func slower() { speed = max(1, (speed / 1.5).rounded()) }

    // MARK: Editing (undoable)

    /// Saves the board so the next edit can be undone.
    func checkpoint(_ action: String) {
        let saved = board
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(saved, action) }
        }
        undoManager?.setActionName(action)
    }

    private func restore(_ saved: Board, _ action: String) {
        let current = board
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(current, action) }
        }
        undoManager?.setActionName(action)
        board = saved
        history = [population]
    }

    func paint(_ cells: [Cell], alive: Bool) {
        var b = board
        for c in cells { b.set(c.x, c.y, alive) }
        board = b
        history[history.count - 1] = population
    }

    func clear() {
        guard population > 0 || board.generation > 0 else { return }
        checkpoint("Clear")
        board = Board(width: board.grid.width, height: board.grid.height)
        history = [0]
        isRunning = false
    }

    func randomize() {
        checkpoint("Random Fill")
        var g = LifeGrid(width: board.grid.width, height: board.grid.height)
        g.randomize(density: density)
        board = Board(grid: g)
        history = [population]
    }

    func resize(to size: GridSize) {
        guard size != self.size else { return }
        checkpoint("Change Size")
        var b = board
        b.resize(width: size.width, height: size.height)
        board = b
        history = [population]
        save("columns", size.width)
        save("rows", size.height)
    }

    /// The top left corner that centres the placing pattern on the pointer.
    func placementOrigin(for pattern: Pattern, at cell: Cell) -> Cell {
        Cell(x: cell.x - pattern.width / 2, y: cell.y - pattern.height / 2)
    }

    func stamp(at cell: Cell) {
        guard let pattern = placing else { return }
        checkpoint("Place \(pattern.name)")
        var b = board
        b.stamp(pattern, at: placementOrigin(for: pattern, at: cell), wrap: wrap)
        board = b
        history[history.count - 1] = population
    }

    func rotatePlacing() { placing = placing?.rotated() }

    func cancelPlacing() {
        selectedPattern = nil
        placing = nil
    }

    // MARK: Files and the pasteboard

    static let rleType = UTType(filenameExtension: "rle", conformingTo: .plainText) ?? .plainText

    func show(_ text: String, url: URL? = nil, isError: Bool = false) {
        notice = Notice(text: text, url: url, isError: isError)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(url == nil ? 3 : 6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.rleType, .plainText]
        panel.message = "Choose an RLE or plain text Life pattern."
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Replaces the board with a pattern file, growing the grid if the pattern needs it.
    func open(_ url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var pattern = try Pattern.parse(text)
            if pattern.name == "Untitled" { pattern.name = url.deletingPathExtension().lastPathComponent }
            load(pattern)
        } catch {
            show("Could not open \(url.lastPathComponent). \(error.localizedDescription)", isError: true)
        }
    }

    func load(_ pattern: Pattern) {
        let fits = GridSize.all.first { $0.width >= pattern.width + 4 && $0.height >= pattern.height + 4 }
        let current = size
        let target = current.width >= pattern.width && current.height >= pattern.height ? current : fits
        guard let target else {
            show("\(pattern.name) is \(pattern.width) \u{00D7} \(pattern.height), larger than the biggest board.", isError: true)
            return
        }
        checkpoint("Open \(pattern.name)")
        isRunning = false
        cancelPlacing()
        var b = Board(width: target.width, height: target.height)
        b.stamp(pattern, at: Cell(x: (target.width - pattern.width) / 2, y: (target.height - pattern.height) / 2), wrap: false)
        board = b
        history = [population]
        if let r = pattern.rule { rule = r }
        save("columns", target.width)
        save("rows", target.height)
        show("Opened \(pattern.name)")
    }

    func exportPanel() {
        guard let pattern = Pattern.capture(board.grid, rule: rule) else {
            show("The board is empty, so there is nothing to export.", isError: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.rleType]
        panel.nameFieldStringValue = "Life pattern.rle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try pattern.rle(comment: "Generation \(board.generation), made with Life").write(to: url, atomically: true, encoding: .utf8)
            show("Exported \(url.lastPathComponent)", url: url)
        } catch {
            show("Could not export. \(error.localizedDescription)", isError: true)
        }
    }

    func copyRLE() {
        guard let pattern = Pattern.capture(board.grid, rule: rule) else {
            show("The board is empty, so there is nothing to copy.", isError: true)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pattern.rle(), forType: .string)
        show("Copied \(pattern.cells.count) cells as RLE")
    }

    /// Pasted RLE follows the pointer like a library pattern, ready to be clicked into place.
    func pasteRLE() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            show("The clipboard holds no text.", isError: true)
            return
        }
        do {
            var pattern = try Pattern.parse(text)
            if pattern.name == "Untitled" { pattern.name = "Pasted pattern" }
            guard pattern.width <= board.grid.width, pattern.height <= board.grid.height else {
                show("That pattern is larger than the board. Choose a bigger size first.", isError: true)
                return
            }
            selectedPattern = nil
            placing = pattern
            if let r = pattern.rule, r != rule { rule = r }
        } catch {
            show(error.localizedDescription, isError: true)
        }
    }

    // MARK: Demo

    /// The board shown on the website: a gun streaming gliders past oscillators and a settling soup.
    static func demo() -> LifeModel {
        let m = LifeModel(persist: false)
        var b = Board(width: 120, height: 90)
        func put(_ name: String, _ x: Int, _ y: Int, rotations: Int = 0) {
            var p = Library.entry(name)!.pattern
            for _ in 0..<rotations { p = p.rotated() }
            b.stamp(p, at: Cell(x: x, y: y), wrap: false)
        }
        put("Gosper glider gun", 2, 2)
        put("Pulsar", 100, 5)
        put("Pentadecathlon", 106, 34, rotations: 1)
        put("Acorn", 22, 66)
        m.wrap = false
        m.board = b
        var hist: [Int] = []
        for _ in 0..<240 {
            m.board.step(rule: .conway, wrap: false)
            hist.append(m.board.grid.population)
        }
        m.history = Array(hist.suffix(160))
        m.population = m.board.grid.population
        m.isRunning = true
        m.speed = 24
        m.placing = Library.entry("Glider")!.pattern
        m.selectedPattern = "Glider"
        m.hover = Cell(x: 84, y: 22)
        return m
    }
}
