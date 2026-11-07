import AVFoundation
import Foundation

/// `Trim --selftest`: the range maths, formatting, naming and container choice, then real passthrough
/// exports of a generated movie and a generated audio file in a temporary folder.
enum SelfTest {
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var passes = 0

    private static func check(_ ok: Bool, _ name: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(name)") }
    }

    static func run() -> Int32 {
        logic()
        media()
        MainActor.assumeIsolated { undo() }
        print(failures == 0 ? "All \(passes) checks passed" : "\(failures) of \(passes + failures) checks failed")
        return failures == 0 ? 0 : 1
    }

    // MARK: Pure logic

    private static func logic() {
        check(Timecode.string(0) == "0:00.00", "timecode zero")
        check(Timecode.string(61.25) == "1:01.25", "timecode minutes")
        check(Timecode.string(3725.5) == "1:02:05.50", "timecode hours")
        check(Timecode.string(59.999) == "0:59.99", "timecode rounds down")
        check(Timecode.string(-3) == "0:00.00" && Timecode.string(.nan) == "0:00.00", "timecode bad input")
        check(Timecode.short(90) == "1:30" && Timecode.short(3720) == "1:02:00", "short labels")
        check(Timecode.rulerStep(duration: 62, count: 8) == 10, "ruler step")
        check(Timecode.string(1e300) == Timecode.string(Timecode.maximum) && Timecode.short(.infinity) == "0:00",
              "timecode survives huge and infinite values")

        var r = TrimRange(duration: 60)
        check(r.start == 0 && r.end == 60 && r.isFull, "range starts full")
        r.setStart(-5)
        check(r.start == 0, "in point clamps at zero")
        r.setStart(12)
        r.setEnd(30)
        check(r.start == 12 && r.end == 30 && abs(r.length - 18) < 1e-9 && !r.isFull, "in and out set")
        r.setStart(45)
        check(abs(r.start - 29.9) < 1e-9, "in point stays before out point")
        r.setEnd(1)
        check(abs(r.end - 30) < 1e-9, "out point stays after in point")
        r.setEnd(99)
        check(r.end == 60, "out point clamps at duration")
        r.reset()
        check(r.isFull, "clear in and out")
        let tiny = TrimRange(duration: 0.05)
        check(tiny.minimumLength == 0.05 && tiny.length == 0.05, "clip shorter than minimum")
        let made = TrimRange(duration: 10, start: 2, end: 8)
        check(made.start == 2 && made.end == 8, "range init")
        check(abs(made.cmTimeRange.duration.seconds - 6) < 0.01, "range as CMTimeRange")

        check(SizeEstimate.passthrough(fileBytes: 100_000_000, duration: 60, length: 15) == 25_000_000, "passthrough size")
        check(SizeEstimate.passthrough(fileBytes: 100, duration: 0, length: 15) == 0, "size of empty clip")
        check(SizeEstimate.audio(bitsPerSecond: 128_000, length: 10) == 160_000, "audio size")

        let source = URL(fileURLWithPath: "/tmp/Clip.mov")
        check(OutputName.url(for: source, pathExtension: "mov", exists: { _ in false }).lastPathComponent == "Clip trimmed.mov", "output name")
        let taken: Set<String> = ["Clip trimmed.mov", "Clip trimmed 2.mov"]
        check(OutputName.url(for: source, pathExtension: "mov", exists: { taken.contains($0.lastPathComponent) }).lastPathComponent
              == "Clip trimmed 3.mov", "output name never overwrites")
        check(OutputName.url(for: source, pathExtension: "m4a", exists: { _ in false }).lastPathComponent == "Clip trimmed.m4a", "audio name")
        check(OutputName.url(for: URL(fileURLWithPath: "/tmp/Été à Kyōto 🎬.mov"), pathExtension: "mov", exists: { _ in false })
              .lastPathComponent == "Été à Kyōto 🎬 trimmed.mov", "unicode names")
        check(OutputName.url(for: source, pathExtension: "mov", exists: { _ in false }).deletingLastPathComponent().path == "/tmp",
              "output sits next to the original")

        check(MediaFormat.codecName("avc1") == "H.264" && MediaFormat.codecName("hvc1") == "HEVC"
              && MediaFormat.codecName("apcn") == "ProRes" && MediaFormat.codecName("aac ") == "AAC", "codec names")
        check(MediaFormat.fourCC(0x61766331) == "avc1", "four character code")
        let all: [AVFileType] = [.mov, .mp4, .m4a, .caf, .wav, .aiff]
        func pick(_ ext: String, audioOnly: Bool = false, video: Bool = true, codec: String = "aac ",
                  _ supported: [AVFileType] = all) -> AVFileType? {
            MediaFormat.chooseFileType(sourceExtension: ext, audioOnly: audioOnly, hasVideo: video, audioCodec: codec, supported: supported)
        }
        check(pick("mov") == .mov && pick("mp4") == .mp4, "movies keep their container")
        check(pick("mkv", [.mp4, .mov]) == .mov, "unknown movie falls back to MOV")
        check(pick("mov", audioOnly: true) == .m4a, "AAC audio only is M4A")
        check(pick("mov", audioOnly: true, codec: "lpcm") == .wav, "PCM audio only is WAV")
        check(pick("aiff", video: false, codec: "twos") == .aiff && pick("wav", video: false, codec: "lpcm") == .wav,
              "audio files keep their type")
        check(pick("mp3", video: false, codec: ".mp3", [.caf, .mov]) == .caf, "MP3 goes to CAF untouched")
        check(pick("mov", audioOnly: true, [.mov]) == nil, "audio never comes out as a movie")
        var acc = PeakAccumulator(samplesPerBucket: 3)
        let samples: [Float] = [0.1, -0.5, 0.2, 0.3, 0.9, -0.1, -0.4]
        samples.withUnsafeBufferPointer { acc.add($0) }
        check(acc.finish() == [0.5, 0.9, 0.4], "waveform peaks")
        check(PeakAccumulator.normalised([0.2, 0.4, 0.1, 0.8], buckets: 2) == [0.5, 1], "peaks normalised")
        check(PeakAccumulator.normalised([0.5], buckets: 3) == [1, 1, 1], "peaks stretched")

        let info = MediaInfo(duration: 10, fileBytes: 0, hasVideo: true, hasAudio: true, pixelSize: CGSize(width: 1920, height: 1080),
                             frameRate: 29.97, videoCodec: "H.264", audioCodec: "AAC", audioBitsPerSecond: 0)
        check(info.summary == "H.264, 1920×1080, 29.97 fps, AAC", "format summary")
    }

    // MARK: Real exports

    private static func media() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TrimSelfTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let movie = dir.appendingPathComponent("Clip.mov")
        let audio = dir.appendingPathComponent("Tone.m4a")
        let made = wait { try await makeMovie(at: movie, seconds: 2) } == true
        check(made, "generate a test movie")
        check((try? makeTone(at: audio, seconds: 3)) != nil, "generate a test tone")

        if made {
            let asset = AVURLAsset(url: movie)
            let info = wait { try await MediaInfo.load(asset) }
            check(info?.hasVideo == true && info?.hasAudio == false && info?.videoCodec == "H.264", "read movie info")
            check(abs((info?.duration ?? 0) - 2) < 0.1 && info?.pixelSize == CGSize(width: 320, height: 180), "movie duration and size")
            let out = OutputName.url(for: movie, pathExtension: "mov")
            let exported = wait { () -> Double in
                let plan = try await Exporter.plan(for: asset, audioOnly: false)
                guard plan.preset == AVAssetExportPresetPassthrough, plan.fileType == .mov else { return -1 }
                try await Exporter.run(plan, range: TrimRange(duration: 2, start: 0.5, end: 1.5).cmTimeRange, to: out) { _ in }
                return try await AVURLAsset(url: out).load(.duration).seconds
            }
            check(abs((exported ?? 0) - 1) < 0.1, "passthrough movie trim is one second")
            check(out.lastPathComponent == "Clip trimmed.mov" && FileManager.default.fileExists(atPath: movie.path), "original kept")
            let thumbs = wait { await Analysis.thumbnails(for: asset, duration: 2, count: 4, height: 32) }
            check(thumbs?.count == 4, "filmstrip thumbnails")
            let noAudio = wait { () -> Bool in
                do { _ = try await Exporter.plan(for: asset, audioOnly: true); return false } catch TrimError.noAudio { return true }
            }
            check(noAudio == true, "audio only refuses a silent movie")
            let cancelled = wait { () -> Bool in
                let plan = try await Exporter.plan(for: asset, audioOnly: false)
                let target = dir.appendingPathComponent("Cancelled.mov")
                let task = Task { try await Exporter.run(plan, range: TrimRange(duration: 2).cmTimeRange, to: target) { _ in } }
                task.cancel()
                do { try await task.value; return false } catch { return !FileManager.default.fileExists(atPath: target.path) }
            }
            check(cancelled == true, "cancel leaves no file")
        }
        if made { MainActor.assumeIsolated { modelFlow(movie: movie, dir: dir) } }

        let tone = AVURLAsset(url: audio)
        let out = OutputName.url(for: audio, pathExtension: "m4a")
        let result = wait { () -> (Double, Bool) in
            let plan = try await Exporter.plan(for: tone, audioOnly: false)
            guard plan.fileType == .m4a else { return (-1, true) }
            try await Exporter.run(plan, range: TrimRange(duration: 3, start: 1, end: 2).cmTimeRange, to: out) { _ in }
            return (try await AVURLAsset(url: out).load(.duration).seconds, plan.reencodes)
        }
        check(abs((result?.0 ?? 0) - 1) < 0.1, "passthrough audio trim is one second")
        check(result?.1 == false, "AAC audio is not re-encoded")
        let peaks = wait { await Analysis.waveform(for: tone, duration: 3, buckets: 50) }
        check(peaks?.count == 50 && (peaks?.max() ?? 0) > 0.99, "waveform of the tone")
    }

    private static func makeTone(at url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.5) }
        try file.write(from: buffer)
    }

    private static func makeMovie(at url: URL, seconds: Int) async throws -> Bool {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { return false }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 4 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    // MARK: Undo

    @MainActor
    private static func undo() {
        let model = TrimModel()
        model.undoManager.groupsByEvent = false
        model.range = TrimRange(duration: 20)
        model.undoManager.beginUndoGrouping()
        model.edit("Set In Point") { $0.setStart(5) }
        model.undoManager.endUndoGrouping()
        check(model.range.start == 5 && model.undoManager.undoActionName == "Set In Point", "edit registers undo")
        model.undoManager.undo()
        check(model.range.start == 0, "undo restores the in point")
        model.undoManager.redo()
        check(model.range.start == 5, "redo sets it again")
        check(model.estimatedBytes == 0 && !model.canExport, "no clip, nothing to export")
    }

    // MARK: The model with real files

    /// Runs the main run loop until `done` holds or the time runs out, so the model's main actor tasks can finish.
    @MainActor
    private static func spin(_ seconds: Double = 10, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    private static func modelFlow(movie: URL, dir: URL) {
        let model = TrimModel()
        model.recordsRecents = false
        model.open(movie)
        spin { !model.isLoading }
        check(model.hasClip && model.player != nil && model.url == movie, "open a movie")

        // A file Trim can't read leaves the open clip as it was.
        let empty = dir.appendingPathComponent("Empty.mov")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        model.open(empty)
        spin { !model.isLoading }
        check(model.alert != nil, "an empty file shows an alert")
        check(model.hasClip && model.player != nil && model.url == movie, "a failed open keeps the current clip")
        model.alert = nil

        // Overlapping opens: the latest one wins, whichever finishes first.
        let copy = dir.appendingPathComponent("Second take.mov")
        try? FileManager.default.copyItem(at: movie, to: copy)
        model.open(empty)
        model.open(copy)
        spin { !model.isLoading }
        spin(0.5) { false }
        check(model.url == copy && model.alert == nil, "the latest open wins")

        // Cancel, then export again at once: the cancelled export must not reset the new one.
        model.edit("Set In Point") { $0.setStart(0.5) }
        model.export()
        model.cancelExport()
        check(model.exportState == .idle, "cancel shows idle at once")
        model.export()
        spin { !model.isExporting }
        spin(0.5) { false }
        if case .done(let url, false) = model.exportState {
            check(url.lastPathComponent == "Second take trimmed.mov" && FileManager.default.fileExists(atPath: url.path)
                  && FileManager.default.fileExists(atPath: copy.path), "export after a cancel finishes, original kept")
        } else {
            check(false, "export after a cancel finishes, original kept (state \(model.exportState))")
        }
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Second take trimmed 2.mov").path),
              "the cancelled export left no file")
        model.pause()
    }

    // MARK: Helpers

    private final class Box<T>: @unchecked Sendable { var value: T? }

    /// Runs async work to completion from the synchronous self test.
    private static func wait<T>(_ body: @escaping @Sendable () async throws -> T) -> T? {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = try? await body()
            done.signal()
        }
        done.wait()
        return box.value
    }
}
