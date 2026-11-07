import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tools and annotations

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, ellipse, line, highlighter, text, step, redact, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .step: "Step Number"
        case .redact: "Redact"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .step: "1.circle"
        case .redact: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .highlighter: "h"
        case .text: "t"
        case .step: "n"
        case .redact: "b"
        case .crop: "c"
        }
    }

    /// The annotation a drag with this tool creates.
    var kind: Kind? {
        switch self {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .line: .line
        case .highlighter: .highlighter
        case .text: .text
        case .step: .step
        case .redact: .redact
        case .select, .crop: nil
        }
    }
}

enum Kind: String {
    case arrow, rectangle, ellipse, line, highlighter, text, step, redact

    var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .highlighter: "Highlight"
        case .text: "Text"
        case .step: "Step"
        case .redact: "Redaction"
        }
    }

    /// Kinds whose geometry is the rectangle spanned by `start` and `end`.
    var isBoxed: Bool { self == .rectangle || self == .ellipse || self == .redact }
}

enum RedactStyle: String, CaseIterable, Identifiable {
    case pixelate, blur
    var id: String { rawValue }
    var title: String { self == .pixelate ? "Pixelate" : "Blur" }
}

struct RGBA: Equatable, Hashable {
    var r, g, b: Double

    init(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8) & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .systemRed
        r = Double(c.redComponent)
        g = Double(c.greenComponent)
        b = Double(c.blueComponent)
    }

    var hex: UInt32 { UInt32(r * 255 + 0.5) << 16 | UInt32(g * 255 + 0.5) << 8 | UInt32(b * 255 + 0.5) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var cg: CGColor { ns.cgColor }
    var color: Color { Color(nsColor: ns) }
    /// Relative luminance, 0 (black) to 1 (white).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    /// White or near black, whichever reads on top of this colour.
    var contrast: RGBA { luminance > 0.6 ? RGBA(hex: 0x1C1C1E) : RGBA(hex: 0xFFFFFF) }

    static let palette: [RGBA] = [0xFF3B30, 0xFF9500, 0xFFCC00, 0x34C759, 0x0A84FF, 0xAF52DE, 0x1C1C1E, 0xFFFFFF].map(RGBA.init(hex:))
}

enum Handle: Equatable {
    case start, end
    case corner(Int) // 0 top left, 1 top right, 2 bottom right, 3 bottom left.
}

/// One mark on the image. Coordinates are image pixels with the origin at the top left.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: RGBA
    var width: CGFloat
    var text = ""
    var style: RedactStyle = .pixelate

    var box: CGRect { Geometry.rect(start, end) }

    func moved(by d: CGSize) -> Annotation {
        var a = self
        a.start = CGPoint(x: start.x + d.width, y: start.y + d.height)
        a.end = CGPoint(x: end.x + d.width, y: end.y + d.height)
        a.points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        return a
    }

    func resized(_ handle: Handle, to p: CGPoint) -> Annotation {
        var a = self
        switch handle {
        case .start: a.start = p
        case .end: a.end = p
        case .corner(let i):
            let opposite = Geometry.corners(box)[(i + 2) % 4]
            a.start = opposite
            a.end = p
        }
        return a
    }
}

// MARK: - Geometry

enum Geometry {
    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// With Shift held: lines snap to 45 degree steps, boxes become squares.
    static func constrain(_ start: CGPoint, _ end: CGPoint, kind: Kind) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        if kind.isBoxed {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        }
        let len = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
    }

    /// A tapered arrow as one filled shape: thin at the tail, a wide head at `b`.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return path }
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let headLength = min(len * 0.6, w * 4.2 + 6)
        let headHalf = headLength * 0.62
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let tail = w * 0.3, neck = w * 0.6
        func at(_ p: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: p.x + nx * s, y: p.y + ny * s) }
        path.move(to: at(a, tail))
        path.addLine(to: at(base, neck))
        path.addLine(to: at(base, headHalf))
        path.addLine(to: b)
        path.addLine(to: at(base, -headHalf))
        path.addLine(to: at(base, -neck))
        path.addLine(to: at(a, -tail))
        path.closeSubpath()
        return path
    }

    /// A smooth path through freehand points (quadratic curves through the midpoints).
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count < 3 {
            points.dropFirst().forEach { path.addLine(to: $0) }
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func fontSize(_ width: CGFloat) -> CGFloat { width * 4.5 + 6 }
    static func stepRadius(_ width: CGFloat) -> CGFloat { width * 2.4 + 9 }
    static func highlighterWidth(_ width: CGFloat) -> CGFloat { width * 4.5 }

    static func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: size) ?? base
    }

    static func textSize(_ text: String, width: CGFloat) -> CGSize {
        let shown = text.isEmpty ? " " : text
        let s = (shown as NSString).size(withAttributes: [.font: font(size: fontSize(width))])
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    /// The area a mark covers, for selection outlines and hit testing.
    static func bounds(_ a: Annotation) -> CGRect {
        switch a.kind {
        case .rectangle, .ellipse, .redact: return a.box
        case .arrow, .line: return rect(a.start, a.end)
        case .highlighter:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .zero }
            let pad = highlighterWidth(a.width) / 2
            return CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        case .text: return CGRect(origin: a.start, size: textSize(a.text, width: a.width))
        case .step:
            let r = stepRadius(a.width)
            return CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
        }
    }

    static func handles(_ a: Annotation) -> [(Handle, CGPoint)] {
        switch a.kind {
        case .arrow, .line: return [(.start, a.start), (.end, a.end)]
        case .rectangle, .ellipse, .redact: return corners(a.box).enumerated().map { (.corner($0.offset), $0.element) }
        case .highlighter, .text, .step: return []
        }
    }

    static func handleHit(_ a: Annotation, _ p: CGPoint, _ tolerance: CGFloat) -> Handle? {
        handles(a).first { distance($0.1, p) <= tolerance }?.0
    }

    /// Outlined shapes hit on their stroke, so a new mark can be drawn inside a box; solid ones hit anywhere inside.
    static func hit(_ a: Annotation, _ p: CGPoint, _ tolerance: CGFloat) -> Bool {
        let t = tolerance + a.width / 2
        switch a.kind {
        case .arrow, .line:
            return distance(p, toSegment: a.start, a.end) <= t + (a.kind == .arrow ? a.width : 0)
        case .rectangle:
            let r = a.box
            return r.insetBy(dx: -t, dy: -t).contains(p) && !r.insetBy(dx: t, dy: t).contains(p)
        case .ellipse:
            let r = a.box
            let rx = max(r.width / 2, 0.5), ry = max(r.height / 2, 0.5)
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let radial = hypot(nx, ny)
            return abs(radial - 1) * min(rx, ry) <= t
        case .highlighter:
            let reach = highlighterWidth(a.width) / 2 + tolerance
            guard a.points.count > 1 else { return a.points.first.map { distance($0, p) <= reach } ?? false }
            return zip(a.points, a.points.dropFirst()).contains { distance(p, toSegment: $0, $1) <= reach }
        case .text, .step, .redact:
            return bounds(a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }
}

// MARK: - Board

struct Toast: Equatable {
    var id = UUID()
    var message: String
    var reveal: URL?
}

/// Everything about the open image and its marks. Marks stay vector objects until export.
@MainActor
final class Board: ObservableObject {
    static let shared = Board(persist: true)

    @Published private(set) var image: CGImage?
    @Published private(set) var imageName = "Screenshot"
    @Published var annotations: [Annotation] = []
    @Published var selection: UUID?
    @Published var crop: CGRect?
    @Published var pendingCrop: CGRect?
    @Published private(set) var editingID: UUID?
    @Published var toast: Toast?
    @Published var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            endEditing()
            if tool == .crop {
                selection = nil
                pendingCrop = crop ?? fullRect
            } else {
                pendingCrop = nil
            }
            if tool != .crop { save("tool", tool.rawValue) }
        }
    }
    @Published private(set) var color = RGBA.palette[0]
    @Published private(set) var width: Double = 4
    @Published private(set) var redactStyle: RedactStyle = .pixelate

    /// Points per image pixel the image was captured at: 2 for a Retina screenshot.
    private(set) var pixelScale: CGFloat = 1
    private(set) var effects = Renderer.Effects()
    private(set) var sourceURL: URL?
    weak var undoManager: UndoManager?
    private let persist: Bool

    init(persist: Bool = false) {
        self.persist = persist && !Desktop.isSnapshot
        guard self.persist else { return }
        let d = UserDefaults.standard
        if let t = d.string(forKey: "tool").flatMap(Tool.init(rawValue:)) { tool = t }
        if d.object(forKey: "color") != nil { color = RGBA(hex: UInt32(d.integer(forKey: "color"))) }
        if d.object(forKey: "width") != nil { width = min(10, max(1, d.double(forKey: "width"))) }
        if let s = d.string(forKey: "redactStyle").flatMap(RedactStyle.init(rawValue:)) { redactStyle = s }
    }

    private func save(_ key: String, _ value: Any) {
        if persist { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: Geometry

    var fullRect: CGRect { image.map { CGRect(x: 0, y: 0, width: $0.width, height: $0.height) } ?? .zero }
    /// The part of the image on screen: everything while cropping, the crop otherwise.
    var region: CGRect { tool == .crop ? fullRect : (crop ?? fullRect) }
    /// Image pixels per unit of stroke width, so marks look the same on a small and a 5K image.
    var unit: CGFloat { image.map { max(1, CGFloat(max($0.width, $0.height)) / 1400) } ?? 1 }

    func annotation(_ id: UUID?) -> Annotation? { annotations.first { $0.id == id } }
    var selected: Annotation? { annotation(selection) }

    /// Steps number themselves in the order they were placed, so deleting one renumbers the rest.
    func stepNumber(_ id: UUID) -> Int {
        var n = 0
        for a in annotations where a.kind == .step {
            n += 1
            if a.id == id { return n }
        }
        return n
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> UUID? {
        annotations.last { Geometry.hit($0, p, tolerance) }?.id
    }

    private func replace(_ id: UUID, _ transform: (Annotation) -> Annotation) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i] = transform(annotations[i])
    }

    // MARK: Undo

    struct State: Equatable {
        var annotations: [Annotation]
        var crop: CGRect?
    }

    var state: State {
        get { State(annotations: annotations, crop: crop) }
        set {
            annotations = newValue.annotations
            crop = newValue.crop
            if annotation(selection) == nil { selection = nil }
            if annotation(editingID) == nil { editingID = nil }
        }
    }

    private var pending: State?

    /// Starts a change that spans several events (a drag, a text edit, a slider); `commitChange` records it once.
    func beginChange() {
        if pending == nil { pending = state }
    }

    func commitChange(_ name: String) {
        guard let old = pending else { return }
        pending = nil
        record(old, name)
    }

    func change(_ name: String, _ body: () -> Void) {
        let old = state
        body()
        record(old, name)
    }

    private func record(_ old: State, _ name: String) {
        guard old != state, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { board in
            MainActor.assumeIsolated {
                let current = board.state
                board.state = old
                board.record(current, name)
            }
        }
        undoManager.setActionName(name)
    }

    // MARK: Loading

    func load(_ image: CGImage, name: String, pixelScale: CGFloat = 1, url: URL? = nil) {
        endEditing()
        self.image = image
        imageName = name
        sourceURL = url
        self.pixelScale = max(1, pixelScale)
        annotations = []
        selection = nil
        crop = nil
        pending = nil
        if tool == .crop { tool = .arrow }
        effects = Renderer.effects(for: image)
        undoManager?.removeAllActions(withTarget: self)
    }

    @discardableResult
    func load(url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            flash("Not an image Arrow can open")
            return false
        }
        load(cg, name: url.deletingPathExtension().lastPathComponent, pixelScale: Self.pixelScale(of: source), url: url)
        return true
    }

    @discardableResult
    func load(data: Data, name: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
        load(cg, name: name, pixelScale: Self.pixelScale(of: source))
        return true
    }

    static func pixelScale(of source: CGImageSource) -> CGFloat {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        return max(1, (dpi / 72).rounded())
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a screenshot or any image to mark up."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { _ = self.load(url: url) }
        }
    }

    /// Loads an image from the clipboard: image data, or an image file copied in Finder.
    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard = .general) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) {
            return load(url: url)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), load(data: data, name: "Pasted image") { return true }
        }
        flash("The clipboard has no image")
        return false
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.load(url: url) } }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { _ = self.load(data: data, name: "Dropped image") } }
            }
            return true
        }
        return false
    }

    // MARK: Style

    func setColor(_ c: RGBA) {
        color = c
        save("color", Int(c.hex))
        if let id = selection { change("Change Color") { replace(id) { var a = $0; a.color = c; return a } } }
    }

    /// Live while a slider moves; the caller brackets it with `beginChange` and `commitChange`.
    func setWidth(_ w: Double) {
        width = w
        save("width", w)
        let px = CGFloat(w) * unit
        if let id = selection { replace(id) { var a = $0; a.width = px; return a } }
    }

    func setRedactStyle(_ s: RedactStyle) {
        redactStyle = s
        save("redactStyle", s.rawValue)
        if let id = selection, selected?.kind == .redact {
            change("Change Redaction") { replace(id) { var a = $0; a.style = s; return a } }
        }
    }

    /// Selecting a mark shows its colour and width, like Preview.
    private func adoptStyle(of a: Annotation) {
        if a.kind != .redact { color = a.color }
        width = min(10, max(1, (a.width / unit).rounded()))
        if a.kind == .redact { redactStyle = a.style }
    }

    // MARK: Pointer

    private enum DragOp {
        case idle
        case create(UUID)
        case move(UUID, Annotation, CGPoint)
        case resize(UUID, Handle, Annotation)
        case placeText(CGPoint)
        case cropNew(CGPoint)
        case cropMove(CGRect, CGPoint)
        case cropResize(Int, CGRect)
    }

    private var op = DragOp.idle
    private var wasSelected = false

    /// `p` is in image pixels; `tolerance` is how far off a click may land, in image pixels.
    func pointerDown(_ p: CGPoint, tolerance: CGFloat) {
        endEditing()
        guard image != nil else { return }
        if tool == .crop {
            let r = pendingCrop ?? fullRect
            if let i = Geometry.corners(r).firstIndex(where: { Geometry.distance($0, p) <= tolerance * 2 }) {
                op = .cropResize(i, r)
            } else if r.contains(p) && r != fullRect {
                op = .cropMove(r, p)
            } else {
                op = .cropNew(p)
            }
            return
        }
        beginChange()
        if let a = selected, let h = Geometry.handleHit(a, p, tolerance * 1.5) {
            op = .resize(a.id, h, a)
            return
        }
        if let id = hitTest(p, tolerance: tolerance), let a = annotation(id) {
            wasSelected = selection == id
            selection = id
            adoptStyle(of: a)
            op = .move(id, a, p)
            return
        }
        selection = nil
        guard let kind = tool.kind else { op = .idle; return }
        if kind == .text { op = .placeText(p); return }
        let a = Annotation(kind: kind, start: p, end: p, points: [p], color: color, width: CGFloat(width) * unit, style: redactStyle)
        annotations.append(a)
        selection = a.id
        op = .create(a.id)
    }

    func pointerDragged(_ p: CGPoint, shift: Bool = false) {
        let full = fullRect
        switch op {
        case .idle, .placeText: break
        case .create(let id):
            replace(id) { a in
                var a = a
                switch a.kind {
                case .highlighter:
                    if let last = a.points.last, Geometry.distance(last, p) >= 1.5 { a.points.append(p) }
                case .step:
                    a.start = p
                    a.end = p
                default:
                    a.end = shift ? Geometry.constrain(a.start, p, kind: a.kind) : p
                }
                return a
            }
        case .move(let id, let original, let origin):
            replace(id) { _ in original.moved(by: CGSize(width: p.x - origin.x, height: p.y - origin.y)) }
        case .resize(let id, let handle, let original):
            var target = p
            if shift {
                let anchor: CGPoint
                switch handle {
                case .start: anchor = original.end
                case .end: anchor = original.start
                case .corner(let i): anchor = Geometry.corners(original.box)[(i + 2) % 4]
                }
                target = Geometry.constrain(anchor, p, kind: original.kind)
            }
            replace(id) { _ in original.resized(handle, to: target) }
        case .cropNew(let s):
            pendingCrop = Geometry.rect(s, p).intersection(full)
        case .cropMove(let r, let origin):
            var moved = r.offsetBy(dx: p.x - origin.x, dy: p.y - origin.y)
            moved.origin.x = min(max(moved.minX, full.minX), full.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, full.minY), full.maxY - moved.height)
            pendingCrop = moved
        case .cropResize(let i, let r):
            pendingCrop = Geometry.rect(Geometry.corners(r)[(i + 2) % 4], p).intersection(full)
        }
    }

    func pointerUp(moved: Bool) {
        let finished = op
        op = .idle
        switch finished {
        case .idle:
            commitChange("Select")
        case .create(let id):
            if let a = annotation(id), a.kind != .step, isTooSmall(a) {
                annotations.removeAll { $0.id == id }
                selection = nil
            }
            commitChange("Add \(annotation(id)?.kind.title ?? "Mark")")
        case .move(let id, let a, _):
            if !moved, a.kind == .text, tool == .text || wasSelected {
                startEditing(id)
            } else {
                commitChange("Move")
            }
        case .resize:
            commitChange("Resize")
        case .placeText(let p):
            let w = CGFloat(width) * unit
            let origin = CGPoint(x: p.x, y: p.y - Geometry.fontSize(w) * 0.6)
            let a = Annotation(kind: .text, start: origin, end: origin, color: color, width: w)
            annotations.append(a)
            selection = a.id
            startEditing(a.id)
        case .cropNew, .cropMove, .cropResize:
            if let r = pendingCrop, r.width < 8 || r.height < 8 { pendingCrop = crop ?? fullRect }
        }
    }

    private func isTooSmall(_ a: Annotation) -> Bool {
        let minimum = 3 * unit
        switch a.kind {
        case .arrow, .line: return Geometry.distance(a.start, a.end) < minimum
        case .rectangle, .ellipse, .redact: return a.box.width < minimum || a.box.height < minimum
        case .highlighter: return a.points.count < 2
        case .text, .step: return false
        }
    }

    // MARK: Text

    func startEditing(_ id: UUID) {
        beginChange()
        selection = id
        editingID = id
    }

    func setText(_ text: String) {
        guard let id = editingID else { return }
        replace(id) { var a = $0; a.text = text; return a }
    }

    func endEditing() {
        guard let id = editingID else { return }
        editingID = nil
        if let a = annotation(id), a.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.removeAll { $0.id == id }
            selection = nil
        }
        commitChange("Edit Text")
    }

    // MARK: Commands

    func deleteSelection() {
        guard let id = selection else { return }
        change("Delete") { annotations.removeAll { $0.id == id } }
        selection = nil
    }

    func removeAll() {
        guard !annotations.isEmpty else { return }
        change("Remove All Marks") { annotations.removeAll() }
        selection = nil
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard let id = selection else { return }
        change("Move") { replace(id) { $0.moved(by: CGSize(width: dx, height: dy)) } }
    }

    /// Escape: cancels a crop, ends text editing, or clears the selection.
    func escape() {
        if tool == .crop { tool = .select } else if editingID != nil { endEditing() } else { selection = nil }
    }

    func applyCrop() {
        guard tool == .crop, let r = pendingCrop else { return }
        let full = fullRect
        let clean = r.integral.intersection(full)
        change("Crop") { crop = (clean == full || clean.isEmpty) ? nil : clean }
        tool = .select
    }

    func resetCrop() {
        guard crop != nil else { return }
        change("Reset Crop") { crop = nil }
        if tool == .crop { pendingCrop = fullRect }
    }

    // MARK: Output

    func rendered() -> CGImage? {
        guard let image else { return nil }
        let area = (crop ?? fullRect).integral.intersection(fullRect)
        return Renderer.export(image: image, annotations: annotations, region: area, effects: effects, numbers: stepNumbers)
    }

    var stepNumbers: [UUID: Int] {
        var map: [UUID: Int] = [:]
        var n = 0
        for a in annotations where a.kind == .step {
            n += 1
            map[a.id] = n
        }
        return map
    }

    func pngData() -> Data? {
        rendered().flatMap { Renderer.png($0, pixelScale: pixelScale) }
    }

    func copyImage() {
        endEditing()
        guard let png = pngData(), let cg = rendered() else { return }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: CGFloat(cg.width) / pixelScale, height: CGFloat(cg.height) / pixelScale)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = rep.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        flash("Copied to the clipboard")
    }

    func exportPanel() {
        endEditing()
        guard image != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(imageName) marked up.png"
        panel.canCreateDirectories = true
        if let folder = sourceURL?.deletingLastPathComponent() { panel.directoryURL = folder }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let data = self.pngData() else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    self.flash("Saved \(url.lastPathComponent)", reveal: url)
                } catch {
                    self.flash("Could not save: \(error.localizedDescription)")
                }
            }
        }
    }

    func flash(_ message: String, reveal: URL? = nil) {
        let t = Toast(message: message, reveal: reveal)
        withAnimation(.snappy) { toast = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reveal == nil ? 2 : 5)) {
            MainActor.assumeIsolated {
                if self.toast?.id == t.id { withAnimation(.snappy) { self.toast = nil } }
            }
        }
    }
}
