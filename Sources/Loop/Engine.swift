import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The pure part of Loop: timing maths, GIF encoding through ImageIO, frame scaling and source loading.

enum Timing {
    static let fpsRange: ClosedRange<Double> = 5...30
    static let minimumRange = 0.2

    /// Sample times for a clip from `start` to `end` at `fps`, one per output frame.
    static func frameTimes(from start: Double, to end: Double, fps: Double) -> [Double] {
        guard fps > 0, end > start else { return [] }
        let count = max(1, Int(((end - start) * fps + 1e-6).rounded(.down)))
        return (0..<count).map { start + Double($0) / fps }
    }

    /// GIF delays are whole centiseconds. Spreading the rounding keeps the total exact, so 15 fps does not drift to 14.3.
    static func centiseconds(count: Int, fps: Double) -> [Int] {
        guard fps > 0 else { return [] }
        return (0..<count).map { i in
            Int((Double(i + 1) * 100 / fps).rounded()) - Int((Double(i) * 100 / fps).rounded())
        }
    }

    /// Rounds a delay in seconds to the nearest centisecond GIF can store, never below 0.02 s (browsers slow anything faster).
    static func gifDelay(_ seconds: Double) -> Double {
        max(2, (seconds * 100).rounded()) / 100
    }

    /// The output pixel size for `width`, keeping the source aspect and never enlarging it.
    static func outputSize(source: CGSize, width: Double) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        let w = max(1, min(width, source.width).rounded())
        return CGSize(width: w, height: max(1, (source.height * w / source.width).rounded()))
    }

    /// The largest rect of `size`'s aspect that fits centred in `box`.
    static func aspectFit(_ size: CGSize, in box: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (box.width - fitted.width) / 2, y: (box.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    /// `0:02.50` for 2.5 seconds.
    static func timecode(_ seconds: Double) -> String {
        let cs = Int((max(0, seconds) * 100).rounded())
        return String(format: "%d:%02d.%02d", cs / 6000, (cs / 100) % 60, cs % 100)
    }

    /// Scales the encoded size of a small sample up to the real export: by frame count and by pixel area.
    static func estimate(sampleBytes: Int, sampleFrames: Int, totalFrames: Int, sampleArea: Double, targetArea: Double) -> Int {
        guard sampleFrames > 0, sampleArea > 0 else { return 0 }
        let perFrame = Double(sampleBytes) / Double(sampleFrames)
        return Int(perFrame * Double(totalFrames) * targetArea / sampleArea)
    }

    /// Evenly spread indexes, at most `limit` of `count`, for previews of long clips.
    static func sample(count: Int, limit: Int) -> [Int] {
        guard count > limit, limit > 0 else { return Array(0..<count) }
        return (0..<limit).map { Int((Double($0) * Double(count) / Double(limit)).rounded(.down)) }
    }

    static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// How many times the GIF plays. ImageIO takes the total number of plays: it writes a NETSCAPE block repeating
/// plays minus one times, none at all for a single play, and 0 (forever) for 0.
enum Repeat: String, CaseIterable, Identifiable, Codable {
    case forever, once, twice, three, five

    var id: String { rawValue }

    var title: String {
        switch self {
        case .forever: "Forever"
        case .once: "Play once"
        case .twice: "2 times"
        case .three: "3 times"
        case .five: "5 times"
        }
    }

    /// The value for kCGImagePropertyGIFLoopCount.
    var loopCount: Int {
        switch self {
        case .forever: 0
        case .once: 1
        case .twice: 2
        case .three: 3
        case .five: 5
        }
    }
}

// MARK: - GIF

enum GIF {
    static func fileProperties(loopCount: Int?) -> CFDictionary {
        var gif: [CFString: Any] = [:]
        if let loopCount { gif[kCGImagePropertyGIFLoopCount] = loopCount }
        return [kCGImagePropertyGIFDictionary: gif] as CFDictionary
    }

    static func frameProperties(delay: Double) -> CFDictionary {
        let d = Timing.gifDelay(delay)
        return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: d,
                                                kCGImagePropertyGIFUnclampedDelayTime: d]] as CFDictionary
    }

    /// Encodes frames to GIF data in memory (used for size estimates and tests).
    static func encode(_ frames: [CGImage], delays: [Double], loopCount: Int?) -> Data? {
        let data = NSMutableData()
        guard !frames.isEmpty,
              let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil)
        else { return nil }
        CGImageDestinationSetProperties(destination, fileProperties(loopCount: loopCount))
        for (i, frame) in frames.enumerated() {
            CGImageDestinationAddImage(destination, frame, frameProperties(delay: i < delays.count ? delays[i] : 0.1))
        }
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Reads a GIF back: frames, their delays and the loop count (nil when the file has no loop block).
    static func read(_ data: Data) -> (frames: [CGImage], delays: [Double], loopCount: Int?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return read(source)
    }

    static func read(_ source: CGImageSource) -> (frames: [CGImage], delays: [Double], loopCount: Int?) {
        var frames: [CGImage] = [], delays: [Double] = []
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(image)
            delays.append(delay(source, at: i) ?? 0.1)
        }
        let file = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (file?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        return (frames, delays, loop)
    }

    /// The delay of an animated GIF or PNG frame.
    static func delay(_ source: CGImageSource, at index: Int) -> Double? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        for (key, unclamped, clamped) in [(kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
                                          (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime)] {
            if let dict = props[key] as? [CFString: Any] {
                if let d = dict[unclamped] as? Double, d > 0 { return d }
                if let d = dict[clamped] as? Double, d > 0 { return d }
            }
        }
        return nil
    }
}

/// Streams frames into a GIF file, so a long export never holds every frame in memory.
final class GIFWriter {
    private let destination: CGImageDestination

    init?(url: URL, frameCount: Int, loopCount: Int?) {
        guard frameCount > 0,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        else { return nil }
        self.destination = destination
        CGImageDestinationSetProperties(destination, GIF.fileProperties(loopCount: loopCount))
    }

    func add(_ image: CGImage, delay: Double) {
        CGImageDestinationAddImage(destination, image, GIF.frameProperties(delay: delay))
    }

    func finish() -> Bool { CGImageDestinationFinalize(destination) }
}

// MARK: - Frames

enum Render {
    /// Draws `image` aspect-fit and centred into a canvas of exactly `size` pixels.
    static func fit(_ image: CGImage, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: Timing.aspectFit(CGSize(width: image.width, height: image.height), in: size))
        return ctx.makeImage()
    }
}

enum MediaKind { case movie, image, other }

enum Loader {
    static let defaultDelay = 0.25
    static let maxPixel = 2000

    static func kind(of url: URL) -> MediaKind {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return .movie }
        if type.conforms(to: .image) { return .image }
        return .other
    }

    /// The frames in an image file: every frame of an animated GIF or PNG with its delay, otherwise the one picture.
    static func frames(at url: URL) -> [(image: CGImage, delay: Double)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        if count > 1, GIF.delay(source, at: 0) != nil {
            return (0..<count).compactMap { i in
                guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { return nil }
                return (image, GIF.delay(source, at: i) ?? 0.1)
            }
        }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return [] }
        return [(image, defaultDelay)]
    }
}

enum Video {
    struct Info { let duration: Double; let size: CGSize }

    struct Unreadable: Error {}

    static func info(_ asset: AVAsset) async throws -> Info {
        let duration = try await asset.load(.duration).seconds
        guard let track = try await asset.loadTracks(withMediaType: .video).first, duration.isFinite, duration > 0 else {
            throw Unreadable()
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        return Info(duration: duration, size: CGSize(width: abs(shown.width).rounded(), height: abs(shown.height).rounded()))
    }

    /// An image generator that returns frames of at least `size` in both dimensions, upright.
    static func generator(_ asset: AVAsset, size: CGSize, fps: Double) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let side = max(size.width, size.height)
        generator.maximumSize = CGSize(width: side, height: side)
        let tolerance = CMTime(seconds: 0.5 / max(fps, 1), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    static func thumbnails(_ asset: AVAsset, duration: Double, count: Int, height: Double) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: height * 3, height: height)
        var images: [CGImage] = []
        for i in 0..<count {
            let t = duration * (Double(i) + 0.5) / Double(count)
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(image)
            }
        }
        return images
    }
}

// MARK: - Rendering jobs

/// What to turn into frames: a span of a video, or a list of pictures.
enum FrameSource: @unchecked Sendable {
    case video(AVAsset, times: [Double])
    case images([CGImage])

    var count: Int {
        switch self {
        case .video(_, let times): times.count
        case .images(let images): images.count
        }
    }
}

struct RenderJob: @unchecked Sendable {
    var source: FrameSource
    var size: CGSize
    var delays: [Double]
    var loopCount: Int?
    var fps: Double
}

/// Produces frame `i` of a job at the job's exact size.
final class FrameProducer {
    private let job: RenderJob
    private let generator: AVAssetImageGenerator?

    init(_ job: RenderJob) {
        self.job = job
        if case .video(let asset, _) = job.source {
            generator = Video.generator(asset, size: job.size, fps: job.fps)
        } else {
            generator = nil
        }
    }

    func frame(_ i: Int) async throws -> CGImage {
        let raw: CGImage
        switch job.source {
        case .video(_, let times):
            guard let generator else { throw Video.Unreadable() }
            raw = try await generator.image(at: CMTime(seconds: times[i], preferredTimescale: 600)).image
        case .images(let images):
            raw = images[i]
        }
        guard let fitted = Render.fit(raw, size: job.size) else { throw Video.Unreadable() }
        return fitted
    }
}

struct PreviewResult: @unchecked Sendable {
    var frames: [CGImage]
    var delays: [Double]
    var estimatedBytes: Int
}

enum Preview {
    static let width = 280.0
    static let sampleLimit = 72

    /// Small frames for the live preview, plus a size estimate from encoding them.
    /// `job.size` is the export size; the preview renders the same frames smaller.
    static func build(_ job: RenderJob, sourceSize: CGSize) async throws -> PreviewResult {
        let total = job.source.count
        guard total > 0 else { return PreviewResult(frames: [], delays: [], estimatedBytes: 0) }
        var small = job
        small.size = Timing.outputSize(source: sourceSize, width: min(job.size.width, width))
        let picks = Timing.sample(count: total, limit: sampleLimit)
        let producer = FrameProducer(small)
        var frames: [CGImage] = []
        for i in picks {
            try Task.checkCancellation()
            frames.append(try await producer.frame(i))
        }
        let totalDuration = job.delays.reduce(0) { $0 + Timing.gifDelay($1) }
        let delays = picks.count == total ? picks.map { job.delays[$0] } : Array(repeating: totalDuration / Double(picks.count), count: picks.count)
        let bytes = GIF.encode(frames, delays: delays, loopCount: job.loopCount)?.count ?? 0
        let estimate = Timing.estimate(sampleBytes: bytes, sampleFrames: frames.count, totalFrames: total,
                                       sampleArea: small.size.width * small.size.height,
                                       targetArea: job.size.width * job.size.height)
        return PreviewResult(frames: frames, delays: delays, estimatedBytes: estimate)
    }
}

enum Exporter {
    struct Failed: Error {}

    /// Writes the GIF to a temporary file, then moves it into place, so a cancelled export leaves nothing behind.
    /// Returns the size of the written file in bytes.
    static func run(_ job: RenderJob, to url: URL, progress: @Sendable (Double) -> Void) async throws -> Int {
        let count = job.source.count
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Loop-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let writer = GIFWriter(url: temp, frameCount: count, loopCount: job.loopCount) else { throw Failed() }
        let producer = FrameProducer(job)
        for i in 0..<count {
            try Task.checkCancellation()
            let frame = try await producer.frame(i)
            writer.add(frame, delay: job.delays[i])
            progress(Double(i + 1) / Double(count))
        }
        try Task.checkCancellation()
        guard writer.finish() else { throw Failed() }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: temp, to: url)
        return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
