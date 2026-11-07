import AVFoundation
import AppKit
import Foundation
import ImageIO
import Kit
import UniformTypeIdentifiers

/// `Loop --selftest`: checks timing maths, GIF round trips, image loading and a real video export pipeline.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var checks = 0

    private static func check(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL: \(name)")
        }
    }

    static func run() -> Int32 {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LoopSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        timing()
        gif(dir)
        images(dir)
        video(dir)

        print(failures == 0 ? "All \(checks) checks passed." : "\(failures) of \(checks) checks failed.")
        return failures == 0 ? 0 : 1
    }

    private static func timing() {
        let times = Timing.frameTimes(from: 0, to: 2, fps: 10)
        check(times.count == 20, "2 s at 10 fps is 20 frames")
        check(times.first == 0 && abs((times.last ?? 0) - 1.9) < 1e-9, "frame times run from in point by 1/fps")
        check(Timing.frameTimes(from: 1.0, to: 1.3, fps: 10).count == 3, "0.3 s at 10 fps survives float rounding")
        check(Timing.frameTimes(from: 3, to: 2, fps: 10).isEmpty, "an empty range has no frames")
        check(Timing.frameTimes(from: 0, to: 0.05, fps: 5).count == 1, "a tiny range still makes one frame")

        let cs = Timing.centiseconds(count: 15, fps: 15)
        check(cs.reduce(0, +) == 100, "15 frames at 15 fps add up to exactly 1 s")
        check(Set(cs).isSubset(of: [6, 7]), "15 fps delays alternate 6 and 7 centiseconds")
        check(Timing.centiseconds(count: 30, fps: 30).reduce(0, +) == 100, "30 fps does not drift")
        check(Timing.gifDelay(0.004) == 0.02, "delays never drop below 0.02 s")
        check(Timing.gifDelay(0.256) == 0.26, "delays round to centiseconds")

        check(Timing.outputSize(source: CGSize(width: 1920, height: 1080), width: 480) == CGSize(width: 480, height: 270),
              "1080p at 480 px wide is 480 by 270")
        check(Timing.outputSize(source: CGSize(width: 300, height: 200), width: 800) == CGSize(width: 300, height: 200),
              "output never enlarges the source")
        check(Timing.outputSize(source: CGSize(width: 1000, height: 1), width: 100).height == 1, "height is at least 1 px")
        let fit = Timing.aspectFit(CGSize(width: 200, height: 100), in: CGSize(width: 100, height: 100))
        check(fit == CGRect(x: 0, y: 25, width: 100, height: 50), "aspect fit centres a wide image")

        check(Timing.timecode(2.5) == "0:02.50", "timecode of 2.5 s")
        check(Timing.timecode(75.256) == "1:15.26", "timecode past a minute")
        check(Timing.timecode(-3) == "0:00.00", "negative times clamp to zero")

        check(Timing.estimate(sampleBytes: 1000, sampleFrames: 10, totalFrames: 40, sampleArea: 100, targetArea: 400) == 16000,
              "estimate scales by frames and area")
        check(Timing.sample(count: 10, limit: 72) == Array(0..<10), "short clips preview every frame")
        let picks = Timing.sample(count: 300, limit: 72)
        check(picks.count == 72 && picks.first == 0 && (picks.last ?? 0) < 300 && picks == picks.sorted(), "long clips sample evenly")
        check(Repeat.forever.loopCount == 0 && Repeat.once.loopCount == 1 && Repeat.three.loopCount == 3, "repeat maps to loop counts")
    }

    private static func solid(_ color: UInt32, size: CGSize) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(rgb(color).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    private static func gif(_ dir: URL) {
        let size = CGSize(width: 40, height: 30)
        let frames = [0xFF0000, 0x00FF00, 0x0000FF].map { solid(UInt32($0), size: size) }
        guard let data = GIF.encode(frames, delays: [0.1, 0.2, 0.5], loopCount: 0), let back = GIF.read(data) else {
            check(false, "GIF encodes and reads back")
            return
        }
        check(back.frames.count == 3, "GIF keeps 3 frames")
        check(back.frames.first?.width == 40 && back.frames.first?.height == 30, "GIF keeps the frame size")
        check(back.delays.map { ($0 * 100).rounded() } == [10, 20, 50], "GIF keeps each frame's delay")
        check(back.loopCount == 0, "Forever writes loop count 0")

        // The NETSCAPE block holds repeats after the first play; a single play has no block.
        func netscape(_ data: Data?) -> Int? {
            guard let data, let r = data.range(of: Data("NETSCAPE2.0".utf8)) else { return nil }
            let b = [UInt8](data[r.upperBound..<(r.upperBound + 4)])
            return Int(b[2]) | Int(b[3]) << 8
        }
        check(netscape(GIF.encode(frames, delays: [], loopCount: Repeat.forever.loopCount)) == 0, "Forever repeats endlessly")
        check(netscape(GIF.encode(frames, delays: [], loopCount: Repeat.once.loopCount)) == nil, "Play once writes no repeat block")
        check(netscape(GIF.encode(frames, delays: [], loopCount: Repeat.twice.loopCount)) == 1, "2 times repeats once after the first play")
        check(netscape(GIF.encode(frames, delays: [], loopCount: Repeat.five.loopCount)) == 4, "5 times repeats four times")

        let url = dir.appendingPathComponent("stream.gif")
        if let writer = GIFWriter(url: url, frameCount: 3, loopCount: 0) {
            frames.forEach { writer.add($0, delay: 0.05) }
            check(writer.finish(), "streamed GIF finalizes")
            let loaded = Loader.frames(at: url)
            check(loaded.count == 3 && abs(loaded[0].delay - 0.05) < 0.001, "an animated GIF opens as its frames and delays")
        } else { check(false, "GIF writer opens a file") }

        let wide = solid(0xFFFFFF, size: CGSize(width: 200, height: 100))
        let fitted = Render.fit(wide, size: CGSize(width: 64, height: 64))
        check(fitted?.width == 64 && fitted?.height == 64, "render fits into the exact output size")
    }

    private static func images(_ dir: URL) {
        let url = dir.appendingPathComponent("still.png")
        let image = solid(0x2FA84F, size: CGSize(width: 120, height: 80))
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            _ = CGImageDestinationFinalize(dest)
        }
        let frames = Loader.frames(at: url)
        check(frames.count == 1 && frames[0].image.width == 120 && frames[0].delay == Loader.defaultDelay,
              "a still image opens as one frame with the default delay")
        check(Loader.kind(of: url) == .image, "PNG is an image")
        check(Loader.kind(of: URL(fileURLWithPath: "/tmp/clip.mov")) == .movie, "MOV is a movie")
        check(Loader.kind(of: URL(fileURLWithPath: "/tmp/clip.mp4")) == .movie, "MP4 is a movie")
        check(Loader.kind(of: URL(fileURLWithPath: "/tmp/notes.txt")) == .other, "text is neither")
    }

    /// Writes a 2 s, 10 fps test clip with AVAssetWriter, then trims and exports it through the real pipeline.
    private static func video(_ dir: URL) {
        let movie = dir.appendingPathComponent("clip.mov")
        let gif = dir.appendingPathComponent("clip.gif")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: (info: Video.Info?, bytes: Int, frames: Int, cancelled: Bool, preview: PreviewResult?) = (nil, 0, 0, false, nil)
        Task.detached {
            defer { done.signal() }
            guard writeMovie(to: movie, size: CGSize(width: 320, height: 180), frames: 20, fps: 10) else { return }
            let asset = AVURLAsset(url: movie)
            guard let info = try? await Video.info(asset) else { return }
            outcome.info = info
            let times = Timing.frameTimes(from: 0.5, to: 1.5, fps: 8)
            let size = Timing.outputSize(source: info.size, width: 160)
            let job = RenderJob(source: .video(asset, times: times), size: size,
                                delays: Timing.centiseconds(count: times.count, fps: 8).map { Double($0) / 100 },
                                loopCount: 0, fps: 8)
            outcome.preview = try? await Preview.build(job, sourceSize: info.size)
            outcome.bytes = (try? await Exporter.run(job, to: gif) { _ in }) ?? 0
            outcome.frames = GIF.read((try? Data(contentsOf: gif)) ?? Data())?.frames.count ?? 0
            // A cancelled export leaves no file behind.
            let cancelled = dir.appendingPathComponent("cancelled.gif")
            let task = Task { try await Exporter.run(job, to: cancelled) { _ in } }
            task.cancel()
            _ = try? await task.value
            outcome.cancelled = !FileManager.default.fileExists(atPath: cancelled.path)
        }
        done.wait()
        check(outcome.info != nil, "a written test movie opens")
        if let info = outcome.info {
            check(abs(info.duration - 2) < 0.15, "the test movie lasts 2 s")
            check(info.size == CGSize(width: 320, height: 180), "video size is read from the track")
        }
        check(outcome.preview?.frames.count == 8, "preview renders every frame of a short range")
        check(outcome.preview?.frames.first?.width == 160, "preview frames are at most the preview width")
        check((outcome.preview?.estimatedBytes ?? 0) > 0, "preview estimates a file size")
        check(outcome.bytes > 0, "export writes a GIF")
        check(outcome.frames == 8, "1 s at 8 fps exports 8 frames")
        check(outcome.cancelled, "cancelling an export leaves no file")
    }

    private static func writeMovie(to url: URL, size: CGSize, frames: Int, fps: Int32) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                   bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                ctx.setFillColor(NSColor(hue: CGFloat(i) / CGFloat(frames), saturation: 0.8, brightness: 0.9, alpha: 1).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: CGRect(x: CGFloat(i) * 12, y: 60, width: 60, height: 60))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}
