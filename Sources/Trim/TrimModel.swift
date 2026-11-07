import AVFoundation
import AppKit
import Kit
import SwiftUI

/// One open clip: its player, the in and out range, the timeline pictures and the export.
@MainActor
final class TrimModel: ObservableObject {
    enum ExportState: Equatable {
        case idle
        case exporting(Double)
        case done(URL, reencoded: Bool)
        case failed(String)
    }

    @Published private(set) var url: URL?
    @Published private(set) var info: MediaInfo?
    @Published var range = TrimRange(duration: 0)
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var rate: Float = 0
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var isLoading = false
    @Published private(set) var exportState = ExportState.idle
    @Published var audioOnly = false
    @Published var alert: String?

    /// Demo content for the website snapshot: no player, no files.
    private(set) var isDemo = false
    private(set) var player: AVPlayer?
    private var asset: AVURLAsset?
    private var timeObserver: Any?
    private var boundaryObserver: Any?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var seekTarget: Double?
    private var isSeeking = false
    private var openGeneration = 0
    private var exportGeneration = 0
    /// Off in the self test, so its temporary files never land in File > Open Recent.
    var recordsRecents = !Desktop.isSnapshot
    let undoManager = UndoManager()

    static let thumbnailCount = 14
    static let waveformBuckets = 360

    var hasClip: Bool { info != nil }
    var isPlaying: Bool { rate != 0 }
    var isExporting: Bool { if case .exporting = exportState { true } else { false } }
    var duration: Double { info?.duration ?? 0 }
    var frameDuration: Double { (info?.frameRate ?? 0) > 0 ? 1 / info!.frameRate : 0.1 }

    var estimatedBytes: Int64 {
        guard let info else { return 0 }
        if exportsAudioOnly {
            return SizeEstimate.audio(bitsPerSecond: info.audioBitsPerSecond > 0 ? info.audioBitsPerSecond : 256_000, length: range.length)
        }
        return SizeEstimate.passthrough(fileBytes: info.fileBytes, duration: info.duration, length: range.length)
    }

    var lastExport: URL? { if case .done(let url, _) = exportState { url } else { nil } }
    var canExport: Bool { hasClip && !isExporting && (!exportsAudioOnly || info?.hasAudio == true) }
    /// Audio only applies to movies; an audio file always exports as audio.
    var exportsAudioOnly: Bool { audioOnly && info?.hasVideo == true }

    // MARK: Opening

    /// Opens a clip. The current clip stays open until the new one has loaded, so a file Trim can't read
    /// leaves the window as it was, and when opens overlap only the latest one wins.
    func open(_ url: URL) {
        guard !isDemo else { return }
        openGeneration += 1
        let generation = openGeneration
        isLoading = true
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        Task {
            do {
                let info = try await MediaInfo.load(asset)
                guard generation == self.openGeneration else { return }
                self.cancelExport()
                self.tearDown()
                self.asset = asset
                self.url = url
                self.info = info
                self.range = TrimRange(duration: info.duration)
                self.audioOnly = false
                self.exportState = .idle
                self.undoManager.removeAllActions()
                self.attachPlayer(AVPlayer(playerItem: AVPlayerItem(asset: asset)))
                self.isLoading = false
                if self.recordsRecents { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
                self.analyse(asset, info: info)
            } catch {
                guard generation == self.openGeneration else { return }
                self.isLoading = false
                self.alert = (error as? TrimError)?.errorDescription ?? TrimError.unreadable.errorDescription
            }
        }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video or audio file to trim"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func tearDown() {
        analysisTask?.cancel()
        removeBoundary()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        thumbnails = []
        waveform = []
        currentTime = 0
        rate = 0
    }

    private func attachPlayer(_ player: AVPlayer) {
        player.actionAtItemEnd = .pause
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                if !self.isSeeking { self.currentTime = min(self.duration, max(0, time.seconds)) }
                if self.rate != player.rate { self.rate = player.rate }
            }
        }
    }

    private func analyse(_ asset: AVURLAsset, info: MediaInfo) {
        let count = Self.thumbnailCount, buckets = Self.waveformBuckets
        analysisTask = Task { [weak self] in
            if info.hasVideo {
                let images = await Analysis.thumbnails(for: asset, duration: info.duration, count: count, height: 64)
                if !Task.isCancelled { self?.thumbnails = images }
            } else {
                let peaks = await Analysis.waveform(for: asset, duration: info.duration, buckets: buckets)
                if !Task.isCancelled { self?.waveform = peaks }
            }
        }
    }

    // MARK: Transport

    /// Seeks frame accurately, chasing the latest target so scrubbing never queues up stale seeks.
    func seek(to t: Double) {
        let target = min(max(0, t), duration)
        currentTime = target
        guard let player else { return }
        seekTarget = target
        guard !isSeeking else { return }
        isSeeking = true
        chase(player)
    }

    private func chase(_ player: AVPlayer) {
        guard let target = seekTarget else { isSeeking = false; return }
        seekTarget = nil
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.chase(player) }
        }
    }

    func togglePlay() {
        guard let player else { return }
        removeBoundary()
        if player.rate != 0 { player.pause() } else {
            if currentTime >= duration - 0.05 { seek(to: range.start) }
            player.rate = 1
        }
        rate = player.rate
    }

    /// J: play backwards, faster with each press. Formats that can't play in reverse step back a second instead.
    func playBackward() {
        guard let player else { return }
        removeBoundary()
        if player.currentItem?.canPlayReverse == true {
            player.rate = player.rate < 0 ? max(player.rate * 2, -8) : -1
        } else {
            player.pause()
            seek(to: currentTime - 1)
        }
        rate = player.rate
    }

    /// L: play forwards, faster with each press.
    func playForward() {
        guard let player else { return }
        removeBoundary()
        if currentTime >= duration - 0.05 { seek(to: range.start) }
        player.rate = player.rate > 0 ? min(player.rate * 2, 8) : 1
        rate = player.rate
    }

    func pause() {
        player?.pause()
        rate = 0
    }

    func step(_ frames: Int) {
        guard let player else { return }
        pause()
        if info?.hasVideo == true, let item = player.currentItem, item.canStepForward, item.canStepBackward {
            item.step(byCount: frames)
            currentTime = min(duration, max(0, currentTime + Double(frames) * frameDuration))
        } else {
            seek(to: currentTime + Double(frames) * frameDuration)
        }
    }

    func jump(_ seconds: Double) {
        pause()
        seek(to: currentTime + seconds)
    }

    /// Plays from the in point and stops at the out point.
    func playSelection() {
        guard let player else { return }
        removeBoundary()
        seek(to: range.start)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: range.end, preferredTimescale: 600))],
                                                          queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pause()
                self.removeBoundary()
                self.seek(to: self.range.end)
            }
        }
        player.rate = 1
        rate = 1
    }

    private func removeBoundary() {
        if let boundaryObserver, let player { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
    }

    // MARK: In and out

    func setIn() { edit("Set In Point") { $0.setStart(self.currentTime) } }
    func setOut() { edit("Set Out Point") { $0.setEnd(self.currentTime) } }
    func clearRange() { edit("Clear In and Out") { $0.reset() } }
    func goToIn() { pause(); seek(to: range.start) }
    func goToOut() { pause(); seek(to: range.end) }

    /// Changes the range as one undoable step.
    func edit(_ name: String, _ change: (inout TrimRange) -> Void) {
        var next = range
        change(&next)
        commit(from: range, to: next, name: name)
    }

    /// Registers undo for a change already shown (a handle drag ends here with the range it started from).
    func commit(from old: TrimRange, to new: TrimRange, name: String) {
        withAnimation(.snappy(duration: 0.2)) { range = new }
        guard old != new else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.commit(from: new, to: old, name: name)
        }
        undoManager.setActionName(name)
    }

    // MARK: Export

    func export() {
        guard canExport, let asset, let source = url else { return }
        pause()
        let audioOnly = exportsAudioOnly
        let timeRange = range.cmTimeRange
        exportState = .exporting(0)
        exportGeneration += 1
        let generation = exportGeneration
        exportTask = Task {
            var destination: URL?
            do {
                let plan = try await Exporter.plan(for: asset, audioOnly: audioOnly)
                let folder = source.deletingLastPathComponent()
                let writable = FileManager.default.isWritableFile(atPath: folder.path)
                let fallback = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                let url = OutputName.url(for: source, pathExtension: plan.pathExtension, in: writable ? folder : fallback)
                destination = url
                try await Exporter.run(plan, range: timeRange, to: url) { progress in
                    Task { @MainActor in if generation == self.exportGeneration { self.showProgress(progress) } }
                }
                guard generation == exportGeneration else { return }
                exportState = .done(url, reencoded: plan.reencodes)
            } catch is CancellationError {
                if let destination { try? FileManager.default.removeItem(at: destination) }
                // A newer export may already be running; only the current one owns the state.
                if generation == exportGeneration { exportState = .idle }
            } catch {
                guard generation == exportGeneration else { return }
                exportState = .failed((error as? TrimError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func showProgress(_ progress: Double) {
        if case .exporting(let old) = exportState, progress > old { exportState = .exporting(progress) }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        // Show idle at once; the cancelled task cleans up its partial file in the background.
        if isExporting { exportGeneration += 1; exportState = .idle }
    }

    func revealExport() {
        if let lastExport { revealInFinder([lastExport]) }
    }

    func dismissExportResult() {
        if !isExporting { exportState = .idle }
    }
}

// MARK: - Demo

extension TrimModel {
    /// A one minute 4K clip with a selection and the playhead inside it, for the website.
    static var demo: TrimModel {
        let model = TrimModel()
        model.isDemo = true
        model.url = URL(fileURLWithPath: "/Users/demo/Movies/Lisbon Sunset.mov")
        model.info = MediaInfo(duration: 62.48, fileBytes: 386_400_000, hasVideo: true, hasAudio: true,
                               pixelSize: CGSize(width: 3840, height: 2160), frameRate: 29.97,
                               videoCodec: "HEVC", audioCodec: "AAC", audioBitsPerSecond: 192_000)
        model.range = TrimRange(duration: 62.48, start: 9.36, end: 41.12)
        model.currentTime = 22.4
        return model
    }
}
