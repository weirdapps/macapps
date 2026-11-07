import AppKit
import Kit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case pencil, eraser, fill, eyedropper, line, rectangle

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pencil: "Pencil"
        case .eraser: "Eraser"
        case .fill: "Fill"
        case .eyedropper: "Eyedropper"
        case .line: "Line"
        case .rectangle: "Rectangle"
        }
    }

    var symbol: String {
        switch self {
        case .pencil: "pencil"
        case .eraser: "eraser"
        case .fill: "drop.fill"
        case .eyedropper: "eyedropper"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        }
    }

    var key: Character {
        switch self {
        case .pencil: "b"
        case .eraser: "e"
        case .fill: "g"
        case .eyedropper: "i"
        case .line: "l"
        case .rectangle: "r"
        }
    }

    /// The undo menu's name for one use of the tool.
    var action: String {
        switch self {
        case .pencil: "Draw"
        case .eraser: "Erase"
        case .fill: "Fill"
        case .eyedropper: "Pick Colour"
        case .line: "Draw Line"
        case .rectangle: "Draw Rectangle"
        }
    }
}

/// One window's editing state: the tool, colour, zoom and the stroke in progress. The picture lives in the document.
@MainActor
final class EditorState: ObservableObject {
    static let zoomLevels: [CGFloat] = [2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 28, 32, 40, 48, 64]
    static let exportScales = [1, 2, 4, 8, 16, 32]

    let document: PixelDocument
    weak var undoManager: UndoManager?

    @Published var tool: Tool = .pencil {
        didSet { if tool != .eyedropper && oldValue != .eyedropper { returnTool = nil } }
    }
    @Published var color = Palette.presets[9]
    @Published var recents: [RGBA] = []
    @Published var mirror = false
    @Published var showGrid = true
    /// Points per picture pixel; nil means fit the window.
    @Published var zoom: CGFloat?
    @Published var fitZoom: CGFloat = 24
    @Published var hover: Point?
    @Published var showingExport = false
    @Published var exportScale = 8
    @Published var notice: Notice?

    struct Notice: Equatable {
        var text: String
        var url: URL?
        var isError = false
    }

    private var strokeBase: PixelImage?
    private var strokeStart: Point?
    private var lastPoint: Point?
    private var strokeTool: Tool = .pencil
    private var returnTool: Tool?
    private let persists: Bool

    init(document: PixelDocument, persists: Bool = !Desktop.isSnapshot) {
        self.document = document
        self.persists = persists
        if persists {
            recents = (UserDefaults.standard.stringArray(forKey: "recentColors") ?? []).compactMap { RGBA(hex: $0) }
                .reduce(into: []) { list, c in if !c.isClear && !list.contains(c) && list.count < Palette.recentLimit { list.append(c) } }
            let scale = UserDefaults.standard.integer(forKey: "exportScale")
            if Self.exportScales.contains(scale) { exportScale = scale }
        }
    }

    var image: PixelImage { document.image }
    var pixelSize: CGFloat { zoom ?? fitZoom }
    var isStroking: Bool { strokeBase != nil }

    // MARK: Strokes

    /// Starts a stroke at picture coordinates `p`. Option turns any tool into the eyedropper for that click.
    func begin(at p: Point, option: Bool = false) {
        strokeTool = option ? .eyedropper : tool
        strokeBase = image
        strokeStart = p
        lastPoint = p
        apply(to: p)
    }

    func move(to p: Point) {
        guard strokeBase != nil, p != lastPoint else { return }
        apply(to: p)
        lastPoint = p
    }

    func end() {
        guard let base = strokeBase else { return }
        strokeBase = nil
        strokeStart = nil
        lastPoint = nil
        if strokeTool == .eyedropper {
            if tool == .eyedropper, let back = returnTool {
                tool = back
                returnTool = nil
            }
            return
        }
        if document.image != base {
            if strokeTool != .eraser { remember(color) }
            document.commit(from: base, action: strokeTool.action, undoManager: undoManager)
        }
    }

    private func apply(to p: Point) {
        guard var img = strokeBase else { return }
        switch strokeTool {
        case .pencil, .eraser:
            img = document.image
            let paint = strokeTool == .eraser ? RGBA.clear : color
            img.plot(PixelImage.line(lastPoint ?? p, p), paint, mirror: mirror)
        case .fill:
            img.fill(from: p, with: color)
            if mirror, img.contains(p) { img.fill(from: img.mirrored(p), with: color) }
        case .line:
            img.plot(PixelImage.line(strokeStart ?? p, p), color, mirror: mirror)
        case .rectangle:
            img.plot(PixelImage.rectangle(strokeStart ?? p, p), color, mirror: mirror)
        case .eyedropper:
            if image.contains(p), !image[p].isClear { color = image[p] }
            return
        }
        if img != document.image { document.image = img }
    }

    // MARK: Tools and colours

    func select(_ new: Tool) {
        if new == .eyedropper, tool != .eyedropper { returnTool = tool }
        tool = new
    }

    func pick(_ c: RGBA) {
        color = c
        if tool == .eraser || tool == .eyedropper { tool = returnTool ?? .pencil }
    }

    func remember(_ c: RGBA) {
        recents = Palette.remember(c, in: recents)
        if persists { UserDefaults.standard.set(recents.map(\.hex8), forKey: "recentColors") }
    }

    var colorBinding: Binding<Color> {
        Binding(get: { self.color.color }, set: { self.color = RGBA(NSColor($0)) })
    }

    // MARK: Zoom

    static func fit(_ image: PixelImage, in size: CGSize) -> CGFloat {
        let s = min((size.width - 64) / CGFloat(image.width), (size.height - 64) / CGFloat(image.height))
        return max(2, min(64, s.rounded(.down)))
    }

    func zoomIn() {
        zoom = Self.zoomLevels.first { $0 > pixelSize } ?? Self.zoomLevels.last
    }

    func zoomOut() {
        zoom = Self.zoomLevels.last { $0 < pixelSize } ?? Self.zoomLevels.first
    }

    func zoomToFit() { zoom = nil }

    // MARK: Picture-wide edits

    func resize(to side: Int) {
        guard image.width != side || image.height != side else { return }
        document.replace(with: image.resized(width: side, height: side), action: "Change Canvas Size", undoManager: undoManager)
    }

    func clear() {
        guard !image.isBlank else { return }
        document.replace(with: PixelImage(width: image.width, height: image.height), action: "Clear Canvas", undoManager: undoManager)
    }

    // MARK: Files

    func importPNG() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .gif, .bmp]
        panel.message = "Choose a small image, up to 64 × 64 pixels (or a Pixel export at any scale)."
        if panel.runModal() == .OK, let url = panel.url { importImage(at: url) }
    }

    func importImage(at url: URL) {
        // A dropped Pixel document opens in its own window, as Finder would open it.
        if url.pathExtension.lowercased() == "pixel" {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { Task { @MainActor in self.notice = Notice(text: error.localizedDescription, isError: true) } }
            }
            return
        }
        do {
            let imported = try PixelImage.importing(contentsOf: url)
            document.replace(with: imported, action: "Import Image", undoManager: undoManager)
            zoom = nil
            notice = Notice(text: "Imported \(url.lastPathComponent) at \(imported.width) × \(imported.height).")
        } catch {
            notice = Notice(text: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, isError: true)
        }
    }

    func export(named base: String) {
        showingExport = false
        if persists { UserDefaults.standard.set(exportScale, forKey: "exportScale") }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = exportScale == 1 ? "\(base).png" : "\(base)@\(exportScale)x.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try image.pngData(scale: exportScale).write(to: url, options: .atomic)
            let w = image.width * exportScale, h = image.height * exportScale
            notice = Notice(text: "Exported \(url.lastPathComponent), \(w) × \(h) px.", url: url)
        } catch {
            notice = Notice(text: error.localizedDescription, isError: true)
        }
    }
}

// MARK: - Demo

extension PixelImage {
    /// A tabby cat, for the website screenshot and the first look.
    static var demoCat: PixelImage {
        let half = [
            "........",
            ".k......",
            ".kk.....",
            ".kpk....",
            ".kppkkkk",
            ".kooodoo",
            "kooooodo",
            "kookwooo",
            "kookkooo",
            "kooooowp",
            "kppoowkw",
            "koooowww",
            ".koooooo",
            "..kkoooo",
            "....kkkk",
            "........",
        ]
        let rows = half.map { $0 + String($0.reversed()) }
        return PixelImage(rows: rows, colors: [
            "k": RGBA(0x2B1B3A), "o": RGBA(0xFFA300), "d": RGBA(0xAB5236),
            "p": RGBA(0xFF77A8), "w": RGBA(0xFFF1E8),
        ])
    }
}
