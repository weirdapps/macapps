import AppKit
import Kit
import MapKit
import SwiftUI

struct Photo: Identifiable {
    let id = UUID()
    let url: URL
    var fileSize: Int64 = 0
    var thumbnail: NSImage?
    var report: PhotoReport?
    var loading = true
    var result: CleanResult?
    var error: String?

    var name: String { url.lastPathComponent }
    var flags: Set<PrivacyFlag> { report?.flags ?? [] }

    var summary: String {
        guard let r = report else { return loading ? "Reading\u{2026}" : "Not a readable image" }
        return "\(r.pixelWidth) \u{00D7} \(r.pixelHeight), " + Format.bytes(fileSize)
    }
}

enum Prefs {
    static let suffix = "suffix"
    static let useFolder = "useFolder"
    static let folder = "folderPath"
    static let defaultSuffix = "-clean"

    static var outputFolder: URL? {
        let d = UserDefaults.standard
        guard d.bool(forKey: useFolder), let path = d.string(forKey: folder), FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var nameSuffix: String {
        let s = UserDefaults.standard.string(forKey: suffix)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? defaultSuffix : s
    }
}

@MainActor
final class ScrubModel: ObservableObject {
    static let shared = ScrubModel()

    struct Job {
        var title: String
        var done: Int
        var total: Int
    }

    @Published var photos: [Photo] = []
    @Published var selection: Set<Photo.ID> = []
    @Published var job: Job?
    @Published var maps: [Photo.ID: NSImage] = [:]
    @Published var mapsUnavailable: Set<Photo.ID> = []
    @Published var showImporter = false
    @Published var notice: String?
    private var work: Task<Void, Never>?
    private var mapRequests: Set<Photo.ID> = []

    var selected: [Photo] { photos.filter { selection.contains($0.id) } }
    var cleanedOutputs: [URL] { (selection.isEmpty ? photos : selected).compactMap { $0.result?.output } }
    var isBusy: Bool { job != nil }

    /// What an action applies to: the selection, or every photo when nothing is selected or `all` is asked for.
    func targets(all: Bool) -> [Photo] {
        (all || selection.isEmpty ? photos : selected).filter { $0.report != nil }
    }

    func canClean(_ mode: ScrubMode, all: Bool) -> Bool {
        !isBusy && targets(all: all).contains { mode == .all ? !$0.flags.isEmpty : $0.flags.contains(.location) }
    }

    // MARK: Adding

    func add(_ urls: [URL]) {
        guard !Desktop.isSnapshot else { return }
        let known = Set(photos.map { $0.url.standardizedFileURL.path })
        let files = Scrubber.imageFiles(in: urls).filter { !known.contains($0.standardizedFileURL.path) }
        guard !files.isEmpty else {
            if !urls.isEmpty, known.isEmpty || Scrubber.imageFiles(in: urls).isEmpty { notice = "No photos found there." }
            return
        }
        let new = files.map { Photo(url: $0) }
        photos += new
        if selection.isEmpty, let first = new.first { selection = [first.id] }
        for photo in new { load(photo.id, url: photo.url) }
    }

    private func load(_ id: Photo.ID, url: URL) {
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (PhotoReport?, CGImage?, Int64) in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return (MetadataReader.read(url), MetadataReader.thumbnail(url, maxPixels: 700), size)
            }.value
            guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
            photos[i].report = loaded.0
            photos[i].fileSize = loaded.2
            photos[i].loading = false
            if let cg = loaded.1 { photos[i].thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }

    func remove(_ ids: Set<Photo.ID>) {
        withAnimation(.snappy) {
            photos.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        }
    }

    func removeAll() {
        cancel()
        withAnimation(.snappy) {
            photos = []
            selection = []
        }
    }

    // MARK: Cleaning

    func clean(_ mode: ScrubMode, all: Bool = false) {
        let list = targets(all: all).filter { mode == .all ? !$0.flags.isEmpty : $0.flags.contains(.location) }
        guard !list.isEmpty, !isBusy, !Desktop.isSnapshot else { return }
        let suffix = Prefs.nameSuffix, folder = Prefs.outputFolder
        job = Job(title: mode == .all ? "Removing metadata" : "Removing location", done: 0, total: list.count)
        notice = nil
        work = Task {
            var cleaned = 0, failed = 0
            for photo in list {
                if Task.isCancelled { break }
                let url = photo.url
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CleanResult, Error> in
                    Result { try Scrubber.clean(url, mode: mode, to: Scrubber.outputURL(for: url, suffix: suffix, folder: folder)) }
                }.value
                if let i = photos.firstIndex(where: { $0.id == photo.id }) {
                    switch outcome {
                    case .success(let r):
                        photos[i].result = r
                        photos[i].error = nil
                        cleaned += 1
                    case .failure(let e):
                        photos[i].error = e.localizedDescription
                        failed += 1
                    }
                }
                job?.done += 1
            }
            let stopped = Task.isCancelled
            withAnimation(.snappy) {
                job = nil
                var parts = ["\(cleaned) cleaned \(cleaned == 1 ? "copy" : "copies") saved and verified"]
                if failed > 0 { parts.append("\(failed) failed") }
                if stopped { parts.append("stopped early") }
                if list.count > 1 || failed > 0 || stopped { notice = parts.joined(separator: ", ") + "." }
            }
            work = nil
        }
    }

    func cancel() { work?.cancel() }

    func revealOutputs() {
        let urls = cleanedOutputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { revealInFinder(urls) }
    }

    // MARK: Maps

    func requestMap(for photo: Photo) {
        guard let c = photo.report?.coordinate, maps[photo.id] == nil, !Desktop.isSnapshot, mapRequests.insert(photo.id).inserted else { return }
        let id = photo.id
        MapSnapshot.make(c) { [weak self] image in
            guard let self else { return }
            if let image { self.maps[id] = image } else { self.mapsUnavailable.insert(id) }
        }
    }
}

enum MapSnapshot {
    static let size = NSSize(width: 640, height: 280)

    /// A static picture of the area around `c`, centred on it, for the Location card. Calls back on the main thread.
    @MainActor
    static func make(_ c: Coordinate, appearance: NSAppearance? = nil, done: @escaping @MainActor (NSImage?) -> Void) {
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                            latitudinalMeters: 1400, longitudinalMeters: 1400 * size.width / size.height)
        options.size = size
        if let appearance = appearance ?? NSApp?.effectiveAppearance { options.appearance = appearance }
        MKMapSnapshotter(options: options).start(with: .main) { snapshot, _ in
            let image = snapshot?.image
            MainActor.assumeIsolated { done(image) }
        }
    }
}
