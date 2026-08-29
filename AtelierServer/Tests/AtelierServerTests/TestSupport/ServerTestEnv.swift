// AtelierServer tests — a throwaway ingestion environment + the video fixture.
//
// Mirrors AtelierIngestion's `makeTempPipeline`: one temp dir holding a real
// migrated SQLite library + a content-addressed MediaStore + a collection + a
// wired IngestPipeline/IngestCoordinator. AtelierServer's TestSupport can't reach
// AtelierIngestion's (test targets aren't products), so we build a small one here.
//
// The image fixtures + request builders left for `AtelierCaptureTestSupport`
// (092 · S0) — which is that same constraint solved properly, as a product both
// packages' test targets can depend on rather than a copy in each.

import AVFoundation
import CoreVideo
import Foundation

import AtelierCore
import AtelierIngestion
@testable import AtelierServer

/// A complete capture environment: services + store + a target collection + a
/// coordinator, all under one temp directory the caller tears down.
struct ServerTestEnv {
    let services: AppServices
    let store: MediaStore
    let collectionID: UUID
    let coordinator: IngestCoordinator
    let root: URL

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// The items currently in the target collection (to assert persistence).
    func items() async throws -> [CollectionItemDetail] {
        try await services.collectionItems(in: collectionID, includeArchived: false)
    }
}

func makeServerTestEnv(maxConcurrent: Int = 4) async throws -> ServerTestEnv {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("AtelierServerTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let store = MediaStore(root: root)
    let dbPath = root.appendingPathComponent("library.sqlite").path
    let services = try AppServices(databasePath: dbPath)
    let collection = try await services.createCollection(name: "Capture Test")

    let pipeline = IngestPipeline(store: store, services: services)
    let coordinator = IngestCoordinator(pipeline: pipeline, maxConcurrent: maxConcurrent)

    return ServerTestEnv(
        services: services, store: store, collectionID: collection.id,
        coordinator: coordinator, root: root)
}

// MARK: - Video fixtures
//
// The image bytes + request builders that used to live here moved to
// `AtelierCaptureTestSupport` (092 · S0), where the capture contract's other
// consumer can reach them. What is left is the one fixture that is genuinely
// server-shaped: a video body is streamed as raw bytes over HTTP and has no
// inbox counterpart, so nothing outside this package needs it.

enum ServerFixtures {
    /// A tiny real H.264 MP4 (synthesized via AVAssetWriter, no committed binary)
    /// — the raw body of a `POST /ingest-video`.
    static func mp4(width: Int = 240, height: Int = 180, frames: Int = 10, fps: Int = 10) -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtelierServerVideoFixtures", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0 ..< frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buffer = pb!
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(
                CVPixelBufferGetBaseAddress(buffer),
                Int32(40 + (frame * 15) % 180),
                CVPixelBufferGetBytesPerRow(buffer) * height)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(
                value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        return try! Data(contentsOf: url)
    }
}
