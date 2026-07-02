// AtelierServer tests — a throwaway ingestion environment + image fixtures.
//
// Mirrors AtelierIngestion's `makeTempPipeline`: one temp dir holding a real
// migrated SQLite library + a content-addressed MediaStore + a collection + a
// wired IngestPipeline/IngestCoordinator. AtelierServer's TestSupport can't reach
// AtelierIngestion's (test targets aren't products), so we build a small one here.

import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        try await services.collectionItems(in: collectionID)
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

// MARK: - Image fixtures

enum ServerFixtures {
    /// A valid `width × height` PNG (deterministic solid fill).
    static func png(width: Int = 16, height: Int = 16) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// The base64 of a valid PNG — the `image` field of a well-formed request.
    static func pngBase64(width: Int = 16, height: Int = 16) -> String {
        png(width: width, height: height).base64EncodedString()
    }

    /// Non-image bytes (UTF-8 text) — a valid base64 payload that is NOT an image,
    /// to drive `IngestError.unsupportedType`.
    static func nonImageBase64() -> String {
        Data("not an image".utf8).base64EncodedString()
    }

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

    /// The base64-JSON value for the `X-Atelier-Provenance` header of a video POST.
    static func provenanceHeader(
        platform: String = "twitter", collectionId: UUID? = nil
    ) -> String {
        let header = VideoCaptureHeader(
            provenance: ProvenanceDTO(
                platform: platform,
                originalURL: "https://x.com/designer/status/42",
                authorHandle: "@designer",
                rawMetadata: .object(["tweetId": .string("42")])),
            collectionId: collectionId)
        return try! JSONEncoder().encode(header).base64EncodedString()
    }
}

// MARK: - Request builders

extension CaptureRequest {
    /// A well-formed capture with rich provenance.
    static func sample(
        image: String = ServerFixtures.pngBase64(),
        platform: String = "twitter",
        collectionId: UUID? = nil
    ) -> CaptureRequest {
        CaptureRequest(
            image: image,
            provenance: ProvenanceDTO(
                platform: platform,
                originalURL: "https://x.com/designer/status/42",
                authorHandle: "@designer",
                authorName: "A Designer",
                title: "a reference",
                rawMetadata: .object(["likes": .number(9)])),
            collectionId: collectionId)
    }

    func jsonData() -> Data { try! JSONEncoder().encode(self) }
}
