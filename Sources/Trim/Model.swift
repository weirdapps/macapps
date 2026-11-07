import AVFoundation
import Foundation
import UniformTypeIdentifiers

// The pure parts of Trim: the in and out range, time and size formatting, output naming,
// container choice, waveform peaks, and the passthrough export itself.

/// The selected part of a clip, in seconds. The out point always stays at least `minimumLength` after the in point.
struct TrimRange: Equatable {
    var duration: Double
    var start: Double
    var end: Double

    init(duration: Double) {
        self.duration = max(0, duration)
        start = 0
        end = self.duration
    }

    init(duration: Double, start: Double, end: Double) {
        self.init(duration: duration)
        setEnd(end)
        setStart(start)
    }

    /// The shortest selection, a tenth of a second (or the whole clip when it is shorter than that).
    var minimumLength: Double { min(0.1, duration) }
    var length: Double { end - start }
    var isFull: Bool { start <= 0.0005 && end >= duration - 0.0005 }

    func clamp(_ t: Double) -> Double { min(max(t, 0), duration) }

    mutating func setStart(_ t: Double) { start = min(max(t, 0), max(0, end - minimumLength)) }
    mutating func setEnd(_ t: Double) { end = max(min(t, duration), min(duration, start + minimumLength)) }
    mutating func reset() { start = 0; end = duration }

    var cmTimeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
    }
}

enum Timecode {
    /// "0:12.40", or "1:02:05.50" past an hour: minutes, seconds and hundredths, rounded down so 59.999 never shows 60.
    static func string(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00.00" }
        let total = Int((max(0, seconds) * 100 + 0.0001).rounded(.down))
        let cs = total % 100, s = (total / 100) % 60, m = (total / 6000) % 60, h = total / 360_000
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, cs) }
        return String(format: "%d:%02d.%02d", m, s, cs)
    }

    /// Short ruler labels: "0:15", "1:30", "1:02:00".
    static func short(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A tidy ruler step that gives about `count` labels across `duration`.
    static func rulerStep(duration: Double, count: Int) -> Double {
        let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
        let raw = duration / Double(max(1, count))
        return steps.first { $0 >= raw } ?? steps.last!
    }
}

enum SizeEstimate {
    /// Passthrough copies the samples, so the output is the selected share of the file.
    static func passthrough(fileBytes: Int64, duration: Double, length: Double) -> Int64 {
        guard duration > 0 else { return 0 }
        return Int64((Double(fileBytes) * min(1, max(0, length / duration))).rounded())
    }

    /// Audio only: the audio tracks' data rate (bits per second) over the selection.
    static func audio(bitsPerSecond: Double, length: Double) -> Int64 {
        Int64((max(0, bitsPerSecond) * max(0, length) / 8).rounded())
    }

    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum OutputName {
    static let suffix = "trimmed"

    /// "Clip.mov" becomes "Clip trimmed.mov", then "Clip trimmed 2.mov" and so on, next to the original.
    static func url(for source: URL, pathExtension ext: String, in directory: URL? = nil,
                    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = n == 1 ? "\(base) \(suffix)" : "\(base) \(suffix) \(n)"
            let candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

enum MediaFormat {
    /// A readable codec name for a format description's four character code.
    static func codecName(_ fourCC: String) -> String {
        switch fourCC.trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "ap4h", "ap4x", "apch", "apcn", "apcs", "apco": "ProRes"
        case "mp4v": "MPEG-4"
        case "jpeg", "mjpa", "mjpb": "Motion JPEG"
        case "av01": "AV1"
        case "aac", "mp4a": "AAC"
        case "alac": "Apple Lossless"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32": "PCM"
        case ".mp3": "MP3"
        case "ac-3": "AC-3"
        case "ec-3": "E-AC-3"
        case "opus": "Opus"
        case "fLaC", "flac": "FLAC"
        default: fourCC.uppercased()
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? "?"
    }

    /// The container to write, always one the passthrough session accepts. Movies keep their own container.
    /// Audio keeps its file type when it is an audio file, and otherwise goes where its codec belongs:
    /// AAC and Apple Lossless into M4A, PCM into WAV, anything else (MP3, AC-3) into CAF, untouched.
    static func chooseFileType(sourceExtension: String, audioOnly: Bool, hasVideo: Bool, audioCodec: String,
                               supported: [AVFileType]) -> AVFileType? {
        let source = UTType(filenameExtension: sourceExtension.lowercased()).map { AVFileType(rawValue: $0.identifier) }
        var preferred: [AVFileType] = []
        if hasVideo && !audioOnly {
            preferred = [source, .mov, .mp4, .m4v].compactMap { $0 }
        } else {
            if !hasVideo, let source { preferred.append(source) }
            switch codecName(audioCodec) {
            case "AAC", "Apple Lossless": preferred.append(.m4a)
            case "PCM": preferred += [.wav, .aiff]
            default: break
            }
            preferred.append(.caf)
            // Audio never comes out as a movie.
            preferred.removeAll { [.mov, .mp4, .m4v].contains($0) }
        }
        return preferred.first { supported.contains($0) }
    }

    static func pathExtension(for type: AVFileType) -> String {
        switch type {
        case .mov: "mov"
        case .mp4: "mp4"
        case .m4v: "m4v"
        case .m4a: "m4a"
        case .caf: "caf"
        case .wav: "wav"
        case .aiff: "aiff"
        default: UTType(type.rawValue)?.preferredFilenameExtension ?? "mov"
        }
    }
}

/// Folds a stream of samples into a fixed number of peak values (0 to 1), one per bucket.
struct PeakAccumulator {
    let samplesPerBucket: Int
    private(set) var peaks: [Float] = []
    private var current: Float = 0
    private var count = 0

    init(samplesPerBucket: Int) { self.samplesPerBucket = max(1, samplesPerBucket) }

    mutating func add(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            current = max(current, abs(sample))
            count += 1
            if count == samplesPerBucket {
                peaks.append(min(1, current))
                current = 0
                count = 0
            }
        }
    }

    mutating func finish() -> [Float] {
        if count > 0 { peaks.append(min(1, current)); count = 0; current = 0 }
        return peaks
    }

    /// Resamples peaks to exactly `buckets` values, taking the loudest of each group, then normalises the loudest to 1.
    static func normalised(_ peaks: [Float], buckets: Int) -> [Float] {
        guard !peaks.isEmpty, buckets > 0 else { return Array(repeating: 0, count: max(0, buckets)) }
        var out = [Float](repeating: 0, count: buckets)
        for (i, p) in peaks.enumerated() {
            let b = min(buckets - 1, i * buckets / peaks.count)
            out[b] = max(out[b], p)
        }
        // Fill gaps when there were fewer peaks than buckets.
        if peaks.count < buckets {
            for b in 0..<buckets { out[b] = peaks[min(peaks.count - 1, b * peaks.count / buckets)] }
        }
        let top = out.max() ?? 0
        return top > 0 ? out.map { $0 / top } : out
    }
}

// MARK: - Reading and exporting

enum TrimError: LocalizedError {
    case unreadable
    case noAudio
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: "Trim can't read this file. Try a QuickTime movie, an MP4 or an audio file."
        case .noAudio: "This clip has no audio track to export."
        case .unsupported: "This file can't be copied without re-encoding."
        }
    }
}

/// What a clip holds, read once when it opens.
struct MediaInfo: Equatable {
    var duration: Double
    var fileBytes: Int64
    var hasVideo: Bool
    var hasAudio: Bool
    var pixelSize: CGSize
    var frameRate: Double
    var videoCodec: String
    var audioCodec: String
    var audioBitsPerSecond: Double

    /// "H.264, 1920×1080, 29.97 fps, AAC"
    var summary: String {
        var parts: [String] = []
        if hasVideo {
            parts.append(videoCodec)
            if pixelSize.width > 0 { parts.append("\(Int(pixelSize.width))×\(Int(pixelSize.height))") }
            if frameRate > 0 {
                let rate = frameRate.rounded() == frameRate ? String(Int(frameRate)) : String(format: "%.2f", frameRate)
                parts.append("\(rate) fps")
            }
        }
        if hasAudio { parts.append(audioCodec) }
        return parts.joined(separator: ", ")
    }

    static func load(_ asset: AVURLAsset) async throws -> MediaInfo {
        guard try await asset.load(.isReadable) else { throw TrimError.unreadable }
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard duration.isFinite, duration > 0, !videos.isEmpty || !audios.isEmpty else { throw TrimError.unreadable }
        var info = MediaInfo(duration: duration, fileBytes: 0, hasVideo: !videos.isEmpty, hasAudio: !audios.isEmpty,
                             pixelSize: .zero, frameRate: 0, videoCodec: "", audioCodec: "", audioBitsPerSecond: 0)
        let values = try? asset.url.resourceValues(forKeys: [.fileSizeKey])
        info.fileBytes = Int64(values?.fileSize ?? 0)
        if let video = videos.first {
            let (size, transform, rate, formats) = try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let shown = size.applying(transform)
            info.pixelSize = CGSize(width: abs(shown.width), height: abs(shown.height))
            info.frameRate = (Double(rate) * 100).rounded() / 100
            info.videoCodec = formats.first.map { MediaFormat.codecName(MediaFormat.fourCC(CMFormatDescriptionGetMediaSubType($0))) } ?? "Video"
        }
        for audio in audios {
            let (rate, formats) = try await audio.load(.estimatedDataRate, .formatDescriptions)
            info.audioBitsPerSecond += Double(rate)
            if info.audioCodec.isEmpty, let format = formats.first {
                info.audioCodec = MediaFormat.codecName(MediaFormat.fourCC(CMFormatDescriptionGetMediaSubType(format)))
            }
        }
        if info.hasAudio && info.audioCodec.isEmpty { info.audioCodec = "Audio" }
        return info
    }
}

enum Exporter {
    struct Plan {
        let asset: AVAsset
        let preset: String
        let fileType: AVFileType
        /// True only when no container takes the audio as it is, so it is converted to AAC.
        let reencodes: Bool
        var pathExtension: String { MediaFormat.pathExtension(for: fileType) }
    }

    /// Works out how to write the range: passthrough into the source's container, or, for a movie's audio only,
    /// its audio tracks alone into the container that fits their codec.
    static func plan(for asset: AVURLAsset, audioOnly: Bool) async throws -> Plan {
        var source: AVAsset = asset
        let audios = try await asset.loadTracks(withMediaType: .audio)
        let hasVideo = !(try await asset.loadTracks(withMediaType: .video)).isEmpty
        let audioCodec = try await audios.first?.load(.formatDescriptions).first
            .map { MediaFormat.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
        if audioOnly && hasVideo {
            guard !audios.isEmpty else { throw TrimError.noAudio }
            let composition = AVMutableComposition()
            let full = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
            for audio in audios {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try track.insertTimeRange(full, of: audio, at: .zero)
            }
            source = composition
        }
        let ext = asset.url.pathExtension
        let candidates: [AVFileType] = [.mov, .mp4, .m4v, .m4a, .caf, .wav, .aiff]
            + [UTType(filenameExtension: ext.lowercased()).map { AVFileType(rawValue: $0.identifier) }].compactMap { $0 }
        var supported: [AVFileType] = []
        for type in candidates where await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: source, outputFileType: type) {
            supported.append(type)
        }
        if let type = MediaFormat.chooseFileType(sourceExtension: ext, audioOnly: audioOnly, hasVideo: hasVideo,
                                                 audioCodec: audioCodec, supported: supported) {
            return Plan(asset: source, preset: AVAssetExportPresetPassthrough, fileType: type, reencodes: false)
        }
        if audioOnly || !hasVideo, await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetAppleM4A, with: source, outputFileType: .m4a) {
            return Plan(asset: source, preset: AVAssetExportPresetAppleM4A, fileType: .m4a, reencodes: true)
        }
        throw TrimError.unsupported
    }

    /// Writes `range` of the plan's asset to `url`. Cancelling the calling task cancels the export and removes the partial file.
    static func run(_ plan: Plan, range: CMTimeRange, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: plan.asset, presetName: plan.preset) else { throw TrimError.unsupported }
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = false
        do {
            if #available(macOS 15, *) {
                let monitor = Task {
                    for await state in session.states(updateInterval: 0.1) {
                        if case .exporting(let p) = state { progress(p.fractionCompleted) }
                    }
                }
                defer { monitor.cancel() }
                try await session.export(to: url, as: plan.fileType)
            } else {
                try await legacyExport(session, to: url, fileType: plan.fileType, progress: progress)
            }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw Task.isCancelled ? CancellationError() : error
        }
    }

    @available(macOS, deprecated: 15)
    private static func legacyExport(_ session: AVAssetExportSession, to url: URL, fileType: AVFileType,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        session.outputURL = url
        session.outputFileType = fileType
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        if Task.isCancelled || session.status == .cancelled { throw CancellationError() }
        if session.status != .completed { throw session.error ?? TrimError.unsupported }
    }
}

enum Analysis {
    /// Evenly spaced thumbnails for the filmstrip, `count` of them, each about `height` points tall at 2x.
    static func thumbnails(for asset: AVAsset, duration: Double, count: Int, height: CGFloat) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 4, height: height * 2)
        let tolerance = CMTime(seconds: max(0.05, duration / Double(max(1, count)) / 4), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { i in
            CMTime(seconds: duration * (Double(i) + 0.5) / Double(count), preferredTimescale: 600)
        }
        var images: [(Double, CGImage)] = []
        for await result in generator.images(for: times) {
            if Task.isCancelled { break }
            if let image = try? result.image { images.append((result.requestedTime.seconds, image)) }
        }
        return images.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Peak values for the waveform: the first audio track, mixed to mono at a low sample rate and folded into `buckets`.
    static func waveform(for asset: AVAsset, duration: Double, buckets: Int) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }
        var accumulator = PeakAccumulator(samplesPerBucket: max(1, Int(duration * rate) / max(1, buckets * 4)))
        while !Task.isCancelled, let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= 4 else { continue }
            var samples = [Float](repeating: 0, count: length / 4)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / 4 * 4, destination: $0.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            samples.withUnsafeBufferPointer { accumulator.add($0) }
        }
        reader.cancelReading()
        return PeakAccumulator.normalised(accumulator.finish(), buckets: buckets)
    }
}
