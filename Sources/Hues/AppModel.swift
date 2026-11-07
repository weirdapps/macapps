import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

struct Toast: Equatable {
    var id = UUID()
    var message: String
    var symbol: String
    var reveal: URL?
}

enum CopyFormat { case hex, rgb, hsl }

@MainActor
final class HuesModel: ObservableObject {
    static let shared = HuesModel(store: Desktop.isSnapshot ? nil : .standard)

    @Published private(set) var bitmap: Bitmap?
    @Published private(set) var extraction: Extraction?
    @Published private(set) var swatches: [Swatch] = []
    @Published private(set) var name = ""
    @Published private(set) var isWorking = false
    @Published private(set) var history: [SavedPalette] = []
    @Published var historySelection: UUID?
    @Published var hovered: UUID?
    @Published var selected: UUID?
    @Published var picking = false
    @Published var copiedID: UUID?
    @Published var toast: Toast?
    @Published var confirmClear = false
    /// A fixed loupe position (unit image coordinates) for the website snapshot.
    @Published var demoLoupe: CGPoint?
    @Published var count: Int {
        didSet {
            guard count != oldValue else { return }
            if store != nil { UserDefaults.standard.set(count, forKey: "count") }
            recompute()
        }
    }

    private(set) var currentID: UUID?
    private var sample: Bitmap?
    private var maskBitmap: Bitmap?
    private var maskMap: Extraction?
    private var masks: [UUID: CGImage] = [:]
    private var job: Task<Void, Never>?
    let store: HistoryStore?
    weak var undoManager: UndoManager?

    init(store: HistoryStore?) {
        self.store = store
        let saved = store == nil ? 0 : UserDefaults.standard.integer(forKey: "count")
        count = Extractor.range.contains(saved) ? saved : 8
        history = store?.load() ?? []
    }

    var hasContent: Bool { bitmap != nil || !swatches.isEmpty }
    var displayName: String { (name as NSString).deletingPathExtension }
    var extractedCount: Int { swatches.filter { !$0.isPicked }.count }
    var pickedCount: Int { swatches.filter(\.isPicked).count }
    var target: Swatch? { swatches.first { $0.id == selected } ?? swatches.first { $0.id == hovered } ?? swatches.first }

    /// The dimming mask for the hovered extracted colour, looked up by id so removing another colour never shifts it.
    var hoverMask: CGImage? {
        guard let id = hovered, swatches.contains(where: { $0.id == id }), let map = maskMap ?? extraction,
              let i = map.index(of: id) else { return nil }
        if let cached = masks[id] { return cached }
        let mask = Extractor.mask(map, index: i)
        masks[id] = mask
        return mask
    }

    // MARK: Loading

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image to pull a palette from"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        // Only files on this Mac: a web link dropped from a browser would mean a silent download.
        guard url.isFileURL else {
            show("Drop an image file, not a link", symbol: "exclamationmark.triangle")
            return
        }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            let image = ImageLoader.cgImage(url: url)
            await MainActor.run {
                guard let image else {
                    self.isWorking = false
                    self.show("Could not read \(url.lastPathComponent)", symbol: "exclamationmark.triangle")
                    return
                }
                self.load(image, name: url.lastPathComponent)
            }
        }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL])?.first {
            open(url)
        } else if let image = NSImage(pasteboard: pb), let cg = ImageLoader.cgImage(image) {
            load(cg, name: "Pasted image")
        } else {
            show("The clipboard has no image", symbol: "doc.on.clipboard")
        }
    }

    /// Analyses `image` off the main thread. With `id` and `saved`, restores a palette from history exactly as it was left.
    func load(_ image: CGImage, name: String, id: UUID? = nil, saved: [Swatch]? = nil) {
        job?.cancel()
        isWorking = true
        let count = count
        let isNew = id == nil
        job = Task.detached(priority: .userInitiated) {
            guard let display = Bitmap(image, maxSide: 1600), let sample = Bitmap(display.image, maxSide: 220) else {
                await MainActor.run {
                    self.isWorking = false
                    self.show("Could not read \(name)", symbol: "exclamationmark.triangle")
                }
                return
            }
            let extraction = saved.map { Extractor.fixed(sample, swatches: $0) } ?? Extractor.extract(sample, count: count)
            let maskBitmap = Bitmap(display.image, maxSide: 720)
            let map = maskBitmap.map { Extractor.assign($0, to: extraction) }
            let transparent = display.hasTransparency
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.maskBitmap = maskBitmap
                self.apply(display: display, sample: sample, extraction: extraction, map: map, name: name, picks: [])
                if let saved { self.swatches = saved }
                self.currentID = id ?? UUID()
                self.historySelection = self.currentID
                if isNew, let store = self.store, let currentID = self.currentID {
                    store.saveImage(display.image, id: currentID, transparent: transparent)
                }
                self.record()
            }
        }
    }

    /// Synchronous load for the snapshot and the self test.
    func loadNow(_ image: CGImage, name: String) {
        guard let display = Bitmap(image, maxSide: 1600), let sample = Bitmap(display.image, maxSide: 220) else { return }
        let extraction = Extractor.extract(sample, count: count)
        maskBitmap = Bitmap(display.image, maxSide: 720)
        apply(display: display, sample: sample, extraction: extraction, map: maskBitmap.map { Extractor.assign($0, to: extraction) },
              name: name, picks: [])
        currentID = UUID()
        historySelection = currentID
    }

    private func apply(display: Bitmap, sample: Bitmap, extraction: Extraction, map: Extraction?, name: String, picks: [Swatch]) {
        bitmap = display
        self.sample = sample
        self.extraction = extraction
        maskMap = map
        masks = [:]
        self.name = name
        withAnimation(.snappy) { swatches = extraction.swatches + picks }
        hovered = nil
        selected = nil
        isWorking = false
        undoManager?.removeAllActions(withTarget: self)
    }

    private func recompute() {
        guard let sample else { return }
        let count = count, picks = swatches.filter(\.isPicked), maskBitmap = maskBitmap
        job?.cancel()
        job = Task.detached(priority: .userInitiated) {
            let extraction = Extractor.extract(sample, count: count)
            let map = maskBitmap.map { Extractor.assign($0, to: extraction) }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.extraction = extraction
                self.maskMap = map
                self.masks = [:]
                withAnimation(.snappy) { self.swatches = extraction.swatches + picks }
                self.record()
            }
        }
    }

    // MARK: Editing

    func color(atUnit p: CGPoint) -> RGB? {
        guard let bitmap else { return nil }
        let x = min(Int(p.x * CGFloat(bitmap.width)), bitmap.width - 1), y = min(Int(p.y * CGFloat(bitmap.height)), bitmap.height - 1)
        return bitmap.color(x: x, y: y)
    }

    func addPick(atUnit p: CGPoint) {
        guard let c = color(atUnit: p) else { return }
        let swatch = Swatch(color: c, share: nil, point: p)
        setSwatches(swatches + [swatch], action: "Pick Colour")
        selected = swatch.id
    }

    func remove(_ id: UUID?) {
        guard let id, swatches.contains(where: { $0.id == id }) else { return }
        setSwatches(swatches.filter { $0.id != id }, action: "Remove Colour")
        if selected == id { selected = nil }
        if hovered == id { hovered = nil }
    }

    private func setSwatches(_ new: [Swatch], action: String) {
        let old = swatches
        withAnimation(.snappy) { swatches = new }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.setSwatches(old, action: action) }
        }
        undoManager?.setActionName(action)
        record()
    }

    func moreColours() { count = min(count + 1, Extractor.range.upperBound) }
    func fewerColours() { count = max(count - 1, Extractor.range.lowerBound) }

    // MARK: Copy and export

    func copy(_ swatch: Swatch, as format: CopyFormat = .hex) {
        let text = switch format {
        case .hex: swatch.color.hex
        case .rgb: "rgb(\(ColorMath.rgbText(swatch.color)))"
        case .hsl: "hsl(\(ColorMath.hslText(swatch.color).replacingOccurrences(of: "\u{00B0}", with: "")))"
        }
        write(text)
        selected = swatch.id
        withAnimation(.snappy) { copiedID = swatch.id }
        show("Copied \(text)", symbol: "checkmark.circle.fill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.copiedID == swatch.id { withAnimation(.snappy) { self?.copiedID = nil } }
        }
    }

    func copyPalette(_ format: ExportFormat) {
        guard !swatches.isEmpty else { return }
        write(Exporter.text(format, swatches, name: name))
        show("Copied palette as \(format.title)", symbol: "checkmark.circle.fill")
    }

    private func write(_ text: String) {
        guard !Desktop.isSnapshot else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func export(_ format: ExportFormat) {
        guard !swatches.isEmpty, let data = Exporter.data(format, swatches, name: name) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(displayName.isEmpty ? "Palette" : displayName) palette.\(format.fileExtension)"
        if let type = UTType(filenameExtension: format.fileExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            show("Saved \(url.lastPathComponent)", symbol: "checkmark.circle.fill", reveal: url)
        } catch {
            show("Could not save: \(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    func show(_ message: String, symbol: String, reveal: URL? = nil) {
        let toast = Toast(message: message, symbol: symbol, reveal: reveal)
        withAnimation(.snappy) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + (reveal == nil ? 1.8 : 5)) { [weak self] in
            if self?.toast?.id == toast.id { withAnimation(.snappy) { self?.toast = nil } }
        }
    }

    // MARK: History

    private func record() {
        guard let currentID, !swatches.isEmpty else { return }
        let item = SavedPalette(id: currentID, name: name, date: Date(), count: count, swatches: swatches)
        var items = history
        let dropped = HistoryStore.upsert(item, into: &items)
        history = items
        guard let store else { return }
        dropped.forEach(store.removeImage)
        store.save(items)
    }

    func restore(_ id: UUID) {
        guard id != currentID, let item = history.first(where: { $0.id == id }) else { return }
        if let image = store?.loadImage(id) {
            if count != item.count {
                // Set without triggering a recompute of the image we are leaving.
                sample = nil
                count = item.count
            }
            load(image, name: item.name, id: id, saved: item.swatches)
        } else {
            // The image is gone: show the saved colours on their own.
            job?.cancel()
            bitmap = nil
            sample = nil
            maskBitmap = nil
            maskMap = nil
            extraction = nil
            name = item.name
            currentID = id
            withAnimation(.snappy) { swatches = item.swatches }
        }
    }

    func deleteHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        store?.removeImage(id)
        store?.save(history)
        if historySelection == id { historySelection = nil }
        // The palette on screen stays, but further edits must not bring a deleted entry (now without its image) back.
        if currentID == id { currentID = nil }
    }

    func clearHistory() {
        history.forEach { store?.removeImage($0.id) }
        history = []
        store?.save([])
        historySelection = nil
        currentID = nil
    }

    // MARK: Demo

    /// Walks down from `start` to the first strong colour edge, so the demo loupe straddles two colours.
    private func edge(from start: CGPoint) -> CGPoint? {
        guard let bitmap else { return nil }
        let x = Int(start.x * CGFloat(bitmap.width))
        var previous: Lab?
        for y in Int(start.y * CGFloat(bitmap.height))..<bitmap.height {
            guard let c = bitmap.color(x: x, y: y) else { continue }
            let lab = ColorMath.lab(c)
            if let previous, lab.distance2(previous) > 60 { return CGPoint(x: start.x, y: CGFloat(y) / CGFloat(bitmap.height)) }
            previous = lab
        }
        return nil
    }

    static var demo: HuesModel {
        let model = HuesModel(store: nil)
        let base = Date(timeIntervalSinceReferenceDate: 784_000_000)
        model.history = [DemoScene.lagoon, .forest].enumerated().map { i, scene in
            let sample = Bitmap(scene.image(width: 300, height: 205), maxSide: 220)!
            let swatches = Extractor.extract(sample, count: 7).swatches
            return SavedPalette(id: UUID(), name: scene.name, date: base.addingTimeInterval(Double(-(i + 1)) * 86_400 * 2),
                                count: 7, swatches: swatches)
        }
        model.loadNow(DemoScene.sunset.image(width: 1000, height: 1080), name: DemoScene.sunset.name)
        let sun = CGPoint(x: 0.62, y: 0.51)
        if let c = model.color(atUnit: sun) {
            model.swatches.append(Swatch(color: c, share: nil, point: sun))
        }
        model.history.insert(SavedPalette(id: model.currentID!, name: model.name, date: base, count: model.count,
                                          swatches: model.swatches), at: 0)
        model.selected = model.swatches.first?.id
        model.demoLoupe = model.edge(from: CGPoint(x: 0.39, y: 0.40)) ?? CGPoint(x: 0.39, y: 0.45)
        model.picking = true
        return model
    }
}
