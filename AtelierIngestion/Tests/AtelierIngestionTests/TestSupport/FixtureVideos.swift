// AtelierIngestion — synthetic video fixtures (mirrors FixtureImages' philosophy)
//
// No committed binary fixtures: a tiny REAL H.264 MP4 is synthesized at runtime
// with AVAssetWriter, so the video-ingest tests stay hermetic (no ffmpeg, no
// opaque blob in the repo) and exercise the true AVFoundation metadata/poster
// paths — the whole point, since `CGImageSource` can't open a movie.
//
// ASYNC by necessity. This helper used to be synchronous, waiting on
// `finishWriting` with a `DispatchSemaphore` and spinning on `Thread.sleep`,
// on the reasoning that blocking is "fine (and simplest) in a test helper".
// That reasoning held under XCTest, which gave each test its own thread. It does
// not hold under swift-testing, which runs async tests on the SWIFT CONCURRENCY
// COOPERATIVE POOL — a pool with one thread per core, and no capacity to grow.
//
// Nine call sites across five suites make this video. Under `--parallel`, once
// enough of them are in flight, every cooperative thread is parked in
// `semaphore.wait()` and NO thread is left to run the `finishWriting` completion
// handler that would signal them. The whole test process deadlocks — not slowly,
// permanently: observed hanging for over an hour with 365 tests open, taking the
// entire `verify.sh` gate with it. Vision requests elsewhere in the suite blocked
// behind the same exhausted pool, which made this look like a Vision bug for as
// long as anyone looked at a sample instead of at the pool.
//
// So nothing here may block a thread. `finishWriting` is awaited, and the
// readiness spin yields with `Task.sleep` instead of sleeping the thread. The
// writer never crosses an isolation boundary — it is created, used and finished
// inside this one function — so being non-Sendable costs nothing.

import AVFoundation
import CoreVideo
import Foundation

enum FixtureVideos {
    enum FixtureError: Error { case setupFailed, writeFailed }

    /// A tiny real H.264 MP4 (`width×height`, `frames` frames at `fps`) as `Data`.
    /// Default ≈ 1s of 320×240 — enough for a decodable video track + poster.
    static func solidVideo(
        width: Int = 320, height: Int = 240, frames: Int = 12, fps: Int = 12
    ) async throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierVideoFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw FixtureError.setupFailed }
        writer.add(input)

        guard writer.startWriting() else { throw FixtureError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0 ..< frames {
            // YIELD, never sleep the thread — see the file header.
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            let buffer = try makePixelBuffer(
                width: width, height: height, seed: frame, pool: adaptor.pixelBufferPool)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FixtureError.writeFailed
            }
        }
        input.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else { throw FixtureError.writeFailed }

        return try Data(contentsOf: url)
    }

    /// A per-frame-varying solid pixel buffer (a flat mid-gray whose value shifts
    /// each frame, so the encoder has real content to compress).
    private static func makePixelBuffer(
        width: Int, height: Int, seed: Int, pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        }
        if pb == nil {
            CVPixelBufferCreate(
                nil, width, height, kCVPixelFormatType_32ARGB,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary, &pb)
        }
        guard let buffer = pb else { throw FixtureError.setupFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            memset(base, Int32(40 + (seed * 15) % 180), bytesPerRow * height)
        }
        return buffer
    }
}
