import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

enum ItemState: Equatable {
    case loading, ready, queued, working, done
    case failed(String)
}

struct ImageItem: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var info: ImageInfo?
    var thumbnail: NSImage?
    var state: ItemState = .loading
    var output: ShrinkOutput?

    var name: String { url.lastPathComponent }
    var saved: Int64? { output.flatMap { out in info.map { $0.bytes - out.bytes } } }
}

private struct Job: Sendable {
    let id: UUID
    let source: URL
    let destination: URL
    let type: UTType
}

@MainActor
final class ShrinkModel: ObservableObject {
    static let shared = ShrinkModel()

    @Published var items: [ImageItem] = []
    @Published var selection = Set<ImageItem.ID>()
    @Published var showSettings = true
    @Published var settings: ShrinkSettings {
        didSet { if persists, settings != oldValue { Storage.save(settings, app: "Shrink", file: "settings.json") } }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var completed = 0
    @Published private(set) var batchTotal = 0
    @Published private(set) var isAdding = false

    weak var undoManager: UndoManager?
    private let persists: Bool
    private var runTask: Task<Void, Never>?

    init() {
        persists = !Desktop.isSnapshot
        settings = persists ? Storage.load(ShrinkSettings.self, app: "Shrink", file: "settings.json") ?? ShrinkSettings() : ShrinkSettings()
    }

    init(items: [ImageItem], settings: ShrinkSettings) {
        persists = false
        self.items = items
        self.settings = settings
    }

    // MARK: Totals

    var doneItems: [ImageItem] { items.filter { $0.state == .done && $0.output != nil } }
    var totalBytes: Int64 { items.compactMap(\.info?.bytes).reduce(0, +) }
    var doneOriginalBytes: Int64 { doneItems.compactMap(\.info?.bytes).reduce(0, +) }
    var doneNewBytes: Int64 { doneItems.compactMap(\.output?.bytes).reduce(0, +) }
    var savedBytes: Int64 { doneOriginalBytes - doneNewBytes }
    var savedPercent: Int { Shrinker.percentSaved(original: doneOriginalBytes, new: doneNewBytes) }
    var processable: [ImageItem] { items.filter { $0.info != nil } }
    var hasOutputs: Bool { items.contains { $0.output != nil } }
    var failedCount: Int { items.filter { if case .failed = $0.state { true } else { false } }.count }

    // MARK: Adding

    func add(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isAdding = true
        Task {
            let files = await Task.detached(priority: .userInitiated) { Shrinker.expand(urls) }.value
            var known = Set(items.map { $0.url.standardizedFileURL.path.lowercased() })
            let fresh = files.filter { known.insert($0.path.lowercased()).inserted }.map { ImageItem(url: $0) }
            withAnimation(.snappy) { items.append(contentsOf: fresh) }
            isAdding = false
            for item in fresh { load(item.id, url: item.url) }
        }
    }

    private func load(_ id: UUID, url: URL) {
        Task {
            let (info, thumb) = await Task.detached(priority: .utility) {
                (Shrinker.info(of: url), Shrinker.thumbnail(of: url, maxPixel: 128))
            }.value
            update(id) {
                $0.info = info
                $0.thumbnail = thumb.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                $0.state = info == nil ? .failed("This file could not be read as an image.") : .ready
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout ImageItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
    }

    func openImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.jpeg, .png, .heic, .heif, .tiff, .webP]
        panel.prompt = "Add"
        panel.message = "Choose images or folders of images to shrink."
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in self?.add(urls) }
        }
    }

    func chooseOutputFolder(then action: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Shrunk images are saved in this folder. Originals stay where they are."
        if let folder = settings.folderURL { panel.directoryURL = folder }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.settings.folderPath = url.path
                self?.settings.location = .folder
                action?()
            }
        }
    }

    // MARK: Removing, with undo

    func remove(_ ids: Set<ImageItem.ID>) {
        guard !isRunning else { return }
        let removed = items.enumerated().filter { ids.contains($0.element.id) }.map { ($0.offset, $0.element) }
        guard !removed.isEmpty else { return }
        withAnimation(.snappy) { items.removeAll { ids.contains($0.id) } }
        selection.subtract(ids)
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(removed) }
        }
        undoManager?.setActionName(removed.count == 1 ? "Remove Image" : "Remove Images")
    }

    func clear() { remove(Set(items.map(\.id))) }

    private func restore(_ removed: [(Int, ImageItem)]) {
        withAnimation(.snappy) {
            for (index, item) in removed { items.insert(item, at: min(index, items.count)) }
        }
        let ids = Set(removed.map(\.1.id))
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.remove(ids) }
        }
    }

    // MARK: Processing

    func shrinkAll() {
        guard !isRunning else { return }
        if settings.location == .folder && settings.folderURL == nil {
            chooseOutputFolder { [weak self] in self?.shrinkAll() }
            return
        }
        let candidates = processable
        guard !candidates.isEmpty else { return }
        // Plan every destination first, on one thread, so two images in a batch never claim the same name.
        // Every image in the list counts as an original, not only the ones in this batch.
        let entries = candidates.compactMap { item in
            item.info.map { (source: item.url,
                             type: Shrinker.outputType(sourceType: $0.type, hasAlpha: $0.hasAlpha, format: settings.format),
                             previous: item.output?.url) }
        }
        let others = items.filter { $0.info == nil }.map(\.url)
        let destinations = Shrinker.plan(entries, reserved: others, settings: settings) { FileManager.default.fileExists(atPath: $0.path) }
        var jobs: [Job] = []
        for (item, (entry, dest)) in zip(candidates, zip(entries, destinations)) {
            jobs.append(Job(id: item.id, source: entry.source, destination: dest, type: entry.type))
            update(item.id) { $0.state = .queued }
        }
        let settings = settings
        completed = 0
        batchTotal = jobs.count
        withAnimation(.snappy) { isRunning = true }
        let width = max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))

        runTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func start(_ job: Job) {
                    group.addTask {
                        guard !Task.isCancelled else { return }
                        await self.mark(job.id, .working)
                        let result = Result { try Shrinker.shrink(job.source, to: job.destination, type: job.type, settings: settings) }
                        await self.finish(job.id, result)
                    }
                }
                while next < min(width, jobs.count) { start(jobs[next]); next += 1 }
                while await group.next() != nil {
                    if Task.isCancelled { continue }
                    if next < jobs.count { start(jobs[next]); next += 1 }
                }
            }
            self.endRun()
        }
    }

    func cancel() { runTask?.cancel() }

    private func mark(_ id: UUID, _ state: ItemState) { update(id) { $0.state = state } }

    private func finish(_ id: UUID, _ result: Result<ShrinkOutput, Error>) {
        update(id) {
            switch result {
            case .success(let output):
                $0.output = output
                $0.state = .done
            case .failure(let error):
                $0.state = .failed(error.localizedDescription)
            }
        }
        completed += 1
    }

    private func endRun() {
        // Images the cancel reached before they started go back to how they were.
        for i in items.indices where items[i].state == .queued || items[i].state == .working {
            items[i].state = items[i].output == nil ? .ready : .done
        }
        runTask = nil
        withAnimation(.snappy) { isRunning = false }
        if !Desktop.isSnapshot, completed > 0, !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Finder

    /// Reveals the outputs of `ids` (or of everything when `ids` is empty), falling back to the originals.
    func reveal(_ ids: Set<ImageItem.ID> = []) {
        let chosen = ids.isEmpty ? items : items.filter { ids.contains($0.id) }
        let outputs = chosen.compactMap(\.output?.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        let urls = outputs.isEmpty ? chosen.map(\.url) : outputs
        if !urls.isEmpty { revealInFinder(urls) }
    }

    func revealOriginals(_ ids: Set<ImageItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.url)
        if !urls.isEmpty { revealInFinder(urls) }
    }
}
