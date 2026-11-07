import AVFoundation
import AppKit
import Kit
import SwiftUI
import UniformTypeIdentifiers

struct ImageFrame: Identifiable, Equatable {
    let id: UUID
    let name: String
    let image: CGImage
    var delay: Double

    init(id: UUID = UUID(), name: String, image: CGImage, delay: Double) {
        self.id = id
        self.name = name
        self.image = image
        self.delay = delay
    }

    static func == (a: ImageFrame, b: ImageFrame) -> Bool { a.id == b.id && a.delay == b.delay }
}

@MainActor
final class LoopModel: ObservableObject {
    enum Mode { case empty, video, images }

    @Published private(set) var mode: Mode = .empty
    @Published private(set) var sourceName = ""
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var isLoading = false
    private var sourceFolder: URL?

    // Video
    @Published private(set) var duration: Double = 0
    @Published var inPoint: Double = 0 { didSet { if inPoint != oldValue { schedulePreview() } } }
    @Published var outPoint: Double = 0 { didSet { if outPoint != oldValue { schedulePreview() } } }
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var poster: CGImage?
    private(set) var player: AVPlayer?
    private var asset: AVAsset?
    private var timeObserver: Any?

    // Images
    @Published private(set) var frames: [ImageFrame] = [] { didSet { if frames != oldValue { schedulePreview() } } }
    @Published var selection: UUID?
    weak var undoManager: UndoManager?
    private var reorderSnapshot: [ImageFrame]?

    // Output
    @Published var fps: Double = 15 { didSet { if fps != oldValue { schedulePreview() } } }
    @Published var width: Double = 480 { didSet { if width != oldValue { schedulePreview() } } }
    @Published var repeatMode: Repeat = .forever

    // Preview
    @Published private(set) var previewFrames: [CGImage] = []
    @Published private(set) var previewDelays: [Double] = []
    @Published private(set) var estimatedBytes: Int?
    @Published private(set) var isRenderingPreview = false
    @Published var previewPaused = false
    private var previewTask: Task<Void, Never>?

    // Export
    @Published private(set) var exportProgress: Double?
    @Published private(set) var lastExport: URL?
    @Published private(set) var lastExportBytes = 0
    @Published var errorMessage: String?
    private var exportTask: Task<Void, Never>?

    init() {}

    // MARK: Derived values

    var outputSize: CGSize { Timing.outputSize(source: sourceSize, width: width) }

    var widthRange: ClosedRange<Double> {
        let top = min(sourceSize.width, 1600)
        let bottom = min(120, top)
        return bottom...max(bottom + 10, top)
    }

    var videoTimes: [Double] { Timing.frameTimes(from: inPoint, to: outPoint, fps: fps) }

    var frameDelays: [Double] {
        switch mode {
        case .video: Timing.centiseconds(count: videoTimes.count, fps: fps).map { Double($0) / 100 }
        case .images: frames.map { Timing.gifDelay($0.delay) }
        case .empty: []
        }
    }

    var frameCount: Int {
        switch mode {
        case .video: videoTimes.count
        case .images: frames.count
        case .empty: 0
        }
    }

    var outputDuration: Double { frameDelays.reduce(0, +) }

    var isExporting: Bool { exportProgress != nil }
    var canExport: Bool { mode != .empty && frameCount > 0 && !isExporting && !isLoading }

    var selectedIndex: Int? { frames.firstIndex { $0.id == selection } }
    var selectedFrame: ImageFrame? { selectedIndex.map { frames[$0] } }

    // MARK: Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose a video, or several images in the order they should play."
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self.open(panel.urls, replacing: true) }
        }
    }

    func showAddImagesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.begin { response in
            guard response == .OK else { return }
            MainActor.assumeIsolated { self.addImages(panel.urls) }
        }
    }

    /// Opens dropped or chosen files: a video replaces whatever is open, images add to an image strip.
    func open(_ urls: [URL], replacing: Bool = false) {
        guard !isExporting else { return }
        if let movie = urls.first(where: { Loader.kind(of: $0) == .movie }) {
            loadVideo(movie)
            return
        }
        let images = urls.filter { Loader.kind(of: $0) == .image }
        guard !images.isEmpty else {
            errorMessage = "Loop makes GIFs from videos (MOV, MP4) and images (PNG, JPEG, HEIC, GIF)."
            return
        }
        if mode == .images && !replacing { addImages(images) } else { loadImages(images) }
    }

    func reset() {
        previewTask?.cancel()
        exportTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        asset = nil
        mode = .empty
        sourceName = ""
        sourceFolder = nil
        sourceSize = .zero
        duration = 0
        inPoint = 0
        outPoint = 0
        currentTime = 0
        isPlaying = false
        thumbnails = []
        poster = nil
        frames = []
        selection = nil
        previewFrames = []
        previewDelays = []
        estimatedBytes = nil
        isLoading = false
        lastExport = nil
        undoManager?.removeAllActions(withTarget: self)
    }

    private func loadVideo(_ url: URL) {
        reset()
        mode = .video
        sourceName = url.deletingPathExtension().lastPathComponent
        sourceFolder = url.deletingLastPathComponent()
        isLoading = true
        let asset = AVURLAsset(url: url)
        self.asset = asset
        Task {
            do {
                let info = try await Video.info(asset)
                guard self.asset === asset else { return }
                duration = info.duration
                sourceSize = info.size
                width = min(480, info.size.width)
                inPoint = 0
                outPoint = min(info.duration, 5)
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = true
                player.actionAtItemEnd = .pause
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak model = self] time in
                    MainActor.assumeIsolated { model?.tick(time.seconds) }
                }
                self.player = player
                isLoading = false
                schedulePreview()
                let thumbs = await Video.thumbnails(asset, duration: info.duration, count: 16, height: 120)
                guard self.asset === asset else { return }
                thumbnails = thumbs
                poster = thumbs.first
            } catch {
                guard self.asset === asset else { return }
                reset()
                errorMessage = "\(url.lastPathComponent) could not be read as a video."
            }
        }
    }

    private func loadImages(_ urls: [URL]) {
        reset()
        mode = .images
        sourceName = urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Animation"
        sourceFolder = urls.first?.deletingLastPathComponent()
        addImages(urls, registerUndo: false)
    }

    private func addImages(_ urls: [URL], registerUndo: Bool = true) {
        let sorted = urls.filter { Loader.kind(of: $0) == .image }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !sorted.isEmpty else { return }
        if mode != .images { loadImages(sorted); return }
        isLoading = true
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> [ImageFrameSeed] in
                sorted.flatMap { url in
                    Loader.frames(at: url).map { ImageFrameSeed(name: url.deletingPathExtension().lastPathComponent, image: $0.image, delay: $0.delay) }
                }
            }.value
            isLoading = false
            guard mode == .images else { return }
            guard !loaded.isEmpty else {
                errorMessage = "None of those images could be read."
                if frames.isEmpty { reset() }
                return
            }
            let added = loaded.map { ImageFrame(name: $0.name, image: $0.image, delay: $0.delay) }
            if frames.isEmpty, let first = added.first {
                sourceSize = CGSize(width: first.image.width, height: first.image.height)
                width = min(480, sourceSize.width)
            }
            if registerUndo { replaceFrames(frames + added, action: "Add Images") } else { frames += added }
            selection = selection ?? added.first?.id
        }
    }

    // MARK: Video playback and range

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentTime = seconds
        if isPlaying, seconds >= outPoint - 0.005 { seek(to: inPoint) }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime < inPoint || currentTime >= outPoint - 0.05 { seek(to: inPoint) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let t = Timing.clamp(seconds, 0...max(duration, 0))
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setIn(_ seconds: Double) {
        inPoint = Timing.clamp(seconds, 0...max(0, outPoint - Timing.minimumRange))
    }

    func setOut(_ seconds: Double) {
        outPoint = Timing.clamp(seconds, min(duration, inPoint + Timing.minimumRange)...duration)
    }

    func setInAtPlayhead() { setIn(currentTime) }
    func setOutAtPlayhead() { setOut(currentTime) }

    func useWholeClip() {
        inPoint = 0
        outPoint = duration
    }

    // MARK: Image frames (undoable)

    private func replaceFrames(_ new: [ImageFrame], action: String) {
        let old = frames
        frames = new
        if let id = selection, !new.contains(where: { $0.id == id }) { selection = new.first?.id }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.replaceFrames(old, action: action) }
        }
        undoManager?.setActionName(action)
    }

    func deleteSelectedFrame() {
        guard let i = selectedIndex else { return }
        var new = frames
        new.remove(at: i)
        let next = new.isEmpty ? nil : new[min(i, new.count - 1)].id
        replaceFrames(new, action: "Delete Frame")
        selection = next
    }

    func moveSelectedFrame(by offset: Int) {
        guard let i = selectedIndex else { return }
        let j = i + offset
        guard frames.indices.contains(j) else { return }
        var new = frames
        new.swapAt(i, j)
        replaceFrames(new, action: "Move Frame")
    }

    func setDelay(_ delay: Double, for id: UUID) {
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        let value = Timing.gifDelay(Timing.clamp(delay, 0.02...10))
        guard frames[i].delay != value else { return }
        var new = frames
        new[i].delay = value
        replaceFrames(new, action: "Change Delay")
    }

    func applySelectedDelayToAll() {
        guard let delay = selectedFrame?.delay else { return }
        replaceFrames(frames.map { var f = $0; f.delay = delay; return f }, action: "Set All Delays")
    }

    /// Drag to reorder: moves happen live while dragging and become one undo step when dropped.
    func beginReorder() { reorderSnapshot = frames }

    func liveMove(_ id: UUID, to target: UUID) {
        guard let from = frames.firstIndex(where: { $0.id == id }),
              let to = frames.firstIndex(where: { $0.id == target }), from != to else { return }
        frames.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func endReorder() {
        guard let snapshot = reorderSnapshot else { return }
        reorderSnapshot = nil
        guard snapshot.map(\.id) != frames.map(\.id) else { return }
        let moved = frames
        frames = snapshot
        replaceFrames(moved, action: "Reorder Frames")
    }

    // MARK: Preview

    private func renderJob() -> RenderJob? {
        switch mode {
        case .video:
            guard let asset else { return nil }
            return RenderJob(source: .video(asset, times: videoTimes), size: outputSize, delays: frameDelays,
                             loopCount: repeatMode.loopCount, fps: fps)
        case .images:
            return RenderJob(source: .images(frames.map(\.image)), size: outputSize, delays: frameDelays,
                             loopCount: repeatMode.loopCount, fps: fps)
        case .empty:
            return nil
        }
    }

    private func schedulePreview() {
        guard !Desktop.isSnapshot else { return }
        previewTask?.cancel()
        guard let job = renderJob(), job.source.count > 0, !isLoading else {
            if mode == .empty || frameCount == 0 {
                previewFrames = []
                previewDelays = []
                estimatedBytes = nil
            }
            return
        }
        let sourceSize = sourceSize
        isRenderingPreview = true
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let inner = Task.detached(priority: .userInitiated) { try await Preview.build(job, sourceSize: sourceSize) }
            let result = await withTaskCancellationHandler { try? await inner.value } onCancel: { inner.cancel() }
            guard !Task.isCancelled, let self else { return }
            isRenderingPreview = false
            if let result {
                previewFrames = result.frames
                previewDelays = result.delays
                estimatedBytes = result.estimatedBytes
            }
        }
    }

    // MARK: Export

    func beginExport() {
        guard canExport else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = sourceName + ".gif"
        panel.canCreateDirectories = true
        if let sourceFolder { panel.directoryURL = sourceFolder }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self.export(to: url) }
        }
    }

    func export(to url: URL) {
        guard let job = renderJob(), job.source.count > 0 else { return }
        if isPlaying { togglePlay() }
        exportProgress = 0
        lastExport = nil
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                if self?.exportProgress != nil { self?.exportProgress = fraction }
            }
        }
        let inner = Task.detached(priority: .userInitiated) { try await Exporter.run(job, to: url, progress: report) }
        exportTask = Task { [weak self] in
            let result = await withTaskCancellationHandler { await inner.result } onCancel: { inner.cancel() }
            guard let self else { return }
            exportProgress = nil
            switch result {
            case .success(let bytes):
                lastExport = url
                lastExportBytes = bytes
            case .failure(let error):
                if !(error is CancellationError) { errorMessage = "The GIF could not be written to \(url.lastPathComponent)." }
            }
        }
    }

    func cancelExport() { exportTask?.cancel() }

    func revealLastExport() {
        if let lastExport { revealInFinder([lastExport]) }
    }
}

private struct ImageFrameSeed: @unchecked Sendable {
    let name: String
    let image: CGImage
    let delay: Double
}

// MARK: - Demo

extension LoopModel {
    /// A sunset harbour clip drawn in code, for the website screenshot.
    static func demo() -> LoopModel {
        let model = LoopModel()
        model.mode = .video
        model.sourceName = "Harbour at dusk"
        model.sourceSize = CGSize(width: 1920, height: 1080)
        model.duration = 8
        model.fps = 15
        model.width = 480
        model.inPoint = 2.2
        model.outPoint = 5.4
        model.currentTime = 3.6
        model.thumbnails = (0..<16).map { DemoArt.frame(at: 8 * (Double($0) + 0.5) / 16, size: CGSize(width: 214, height: 120)) }
        model.poster = DemoArt.frame(at: 3.6, size: CGSize(width: 1280, height: 720))
        let times = model.videoTimes
        let small = Timing.outputSize(source: model.sourceSize, width: Preview.width)
        model.previewFrames = times.map { DemoArt.frame(at: $0, size: small) }
        model.previewDelays = model.frameDelays
        let bytes = GIF.encode(model.previewFrames, delays: model.previewDelays, loopCount: 0)?.count ?? 0
        model.estimatedBytes = Timing.estimate(sampleBytes: bytes, sampleFrames: times.count, totalFrames: times.count,
                                               sampleArea: small.width * small.height,
                                               targetArea: model.outputSize.width * model.outputSize.height)
        return model
    }
}

enum DemoArt {
    /// One frame of the demo clip: a sailboat crossing a harbour at sunset.
    static func frame(at t: Double, size: CGSize) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = size.width / 1280
        ctx.scaleBy(x: s, y: s)
        let horizon: CGFloat = 300
        func grad(_ colors: [UInt32], _ from: CGPoint, _ to: CGPoint) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: colors.map { rgb($0).cgColor } as CFArray, locations: nil)!
            ctx.drawLinearGradient(g, start: from, end: to, options: [])
        }
        // Sky.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon, width: 1280, height: 420))
        grad([0x2B1B4A, 0x8E3B6B, 0xF2795B, 0xFFC56E], CGPoint(x: 0, y: 720), CGPoint(x: 0, y: horizon))
        ctx.restoreGState()
        // Sun, sinking slowly.
        let sunY = horizon + 70 - CGFloat(t) * 6
        ctx.setFillColor(rgb(0xFFE7A3).cgColor)
        ctx.setShadow(offset: .zero, blur: 60, color: rgb(0xFFB347, 0.9).cgColor)
        ctx.fillEllipse(in: CGRect(x: 760, y: sunY, width: 150, height: 150))
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        // Far hills.
        ctx.setFillColor(rgb(0x4A2A55, 0.85).cgColor)
        ctx.move(to: CGPoint(x: 0, y: horizon))
        ctx.addCurve(to: CGPoint(x: 520, y: horizon), control1: CGPoint(x: 160, y: horizon + 90), control2: CGPoint(x: 330, y: horizon + 40))
        ctx.addCurve(to: CGPoint(x: 1280, y: horizon), control1: CGPoint(x: 800, y: horizon + 20), control2: CGPoint(x: 1100, y: horizon + 110))
        ctx.closePath()
        ctx.fillPath()
        // Sea.
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: 0, width: 1280, height: horizon))
        grad([0xC9616B, 0x5B2E5E, 0x1E1838], CGPoint(x: 0, y: horizon), CGPoint(x: 0, y: 0))
        // Sun glitter on the water.
        for i in 0..<9 {
            let y = horizon - 18 - CGFloat(i) * 30
            let wobble = CGFloat(sin(t * 3 + Double(i))) * 16
            let width = 160 - CGFloat(i) * 12
            ctx.setFillColor(rgb(0xFFD58A, 0.55 - Double(i) * 0.05).cgColor)
            ctx.fill(CGRect(x: 835 - width / 2 + wobble, y: y, width: width, height: 6))
        }
        ctx.restoreGState()
        // The boat sails left to right.
        let x = 80 + CGFloat(t) * 120
        let bob = CGFloat(sin(t * 2.4)) * 5
        let base = CGPoint(x: x, y: 190 + bob)
        ctx.setFillColor(rgb(0x1B1430).cgColor)
        ctx.move(to: CGPoint(x: base.x - 110, y: base.y + 22))
        ctx.addLine(to: CGPoint(x: base.x + 120, y: base.y + 22))
        ctx.addLine(to: CGPoint(x: base.x + 80, y: base.y - 14))
        ctx.addLine(to: CGPoint(x: base.x - 80, y: base.y - 14))
        ctx.closePath()
        ctx.fillPath()
        ctx.fill(CGRect(x: base.x - 3, y: base.y + 22, width: 6, height: 250))
        ctx.setFillColor(rgb(0xFFF4E6).cgColor)
        ctx.move(to: CGPoint(x: base.x + 8, y: base.y + 270))
        ctx.addLine(to: CGPoint(x: base.x + 8, y: base.y + 36))
        ctx.addLine(to: CGPoint(x: base.x + 118, y: base.y + 36))
        ctx.closePath()
        ctx.fillPath()
        ctx.setFillColor(rgb(0xFFE1C7).cgColor)
        ctx.move(to: CGPoint(x: base.x - 8, y: base.y + 240))
        ctx.addLine(to: CGPoint(x: base.x - 8, y: base.y + 36))
        ctx.addLine(to: CGPoint(x: base.x - 90, y: base.y + 36))
        ctx.closePath()
        ctx.fillPath()
        // Reflection of the boat.
        ctx.setFillColor(rgb(0x120E22, 0.45).cgColor)
        ctx.fill(CGRect(x: base.x - 90, y: base.y - 40, width: 180, height: 18))
        return ctx.makeImage()!
    }
}
