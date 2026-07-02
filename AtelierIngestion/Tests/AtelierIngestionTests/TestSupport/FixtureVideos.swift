// AtelierIngestion — synthetic video fixtures (mirrors FixtureImages' philosophy)
//
// No committed binary fixtures: a tiny REAL H.264 MP4 is synthesized at runtime
// with AVAssetWriter, so the video-ingest tests stay hermetic (no ffmpeg, no
// opaque blob in the repo) and exercise the true AVFoundation metadata/poster
// paths — the whole point, since `CGImageSource` can't open a movie.
//
// Synchronous by design: `finishWriting` is awaited with a semaphore, which is
// fine (and simplest) in a test helper — it avoids threading a non-Sendable
// writer through an async continuation.

import AVFoundation
import CoreVideo
import Foundation

enum FixtureVideos {
    enum FixtureError: Error { case setupFailed, writeFailed }

    /// A tiny real H.264 MP4 (`width×height`, `frames` frames at `fps`) as `Data`.
    /// Default ≈ 1s of 320×240 — enough for a decodable video track + poster.
    static func solidVideo(
        width: Int = 320, height: Int = 240, frames: Int = 12, fps: Int = 12
    ) throws -> Data {
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
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let buffer = try makePixelBuffer(
                width: width, height: height, seed: frame, pool: adaptor.pixelBufferPool)
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw FixtureError.writeFailed
            }
        }
        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
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
