// AtelierIngestion — video ingest tests (build-order video capture, checkpoint C)
//
// `CGImageSource` cannot open a movie container (an MP4 yields a source with a
// NIL type), so a video needs the AVFoundation metadata + poster paths. These
// exercise them end-to-end against a hermetic, runtime-synthesized H.264 MP4:
//   • MediaProbe sniffs movie vs. still,
//   • ImageMetadata.videoMetadata reports .video + display dims + duration,
//   • ThumbnailGenerator.makeVideoPoster renders a decodable, bounded poster,
//   • the pipeline stores the VIDEO blob + poster-derived thumbnail tiers and
//     persists a .video asset carrying its duration.

import AVFoundation
import Foundation
import ImageIO
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("VideoIngest")
struct VideoIngestTests {
    static func provenance() -> SourceDraft {
        SourceDraft(
            platform: .twitter,
            originalURL: "https://x.com/a/status/1",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawMetadata: .object(["tweetId": .string("1")]))
    }

    // MARK: - Sniffing

    @Test("MediaProbe: an MP4 sniffs as a movie; images / junk do not")
    func sniff() async throws {
        let mp4 = try await FixtureVideos.solidVideo()
        #expect(MediaProbe.looksLikeMovie(mp4))
        #expect(MediaProbe.movieContainer(mp4).mime == "video/mp4")

        let png = try FixtureImages.solidImage(width: 16, height: 16, format: .png)
        #expect(!MediaProbe.looksLikeMovie(png))
        #expect(!MediaProbe.looksLikeMovie(FixtureImages.nonImageBytes()))
        #expect(!MediaProbe.looksLikeMovie(FixtureImages.zeroBytes))
        // A HEIC image is also an `ftyp` box but must NOT be taken for a movie.
        if let heic = try? FixtureImages.heicImage(width: 16, height: 16) {
            #expect(!MediaProbe.looksLikeMovie(heic))
        }
    }

    // MARK: - Metadata (AVFoundation path)

    @Test("videoMetadata → .video, display dims, duration from the container")
    func metadata() async throws {
        let mp4 = try await FixtureVideos.solidVideo(width: 320, height: 240, frames: 12, fps: 12)
        let meta = try await ImageMetadata.videoMetadata(from: mp4)

        #expect(meta.kind == .video)
        #expect(meta.mimeType == "video/mp4")
        #expect(meta.fileExtension == "mp4")
        #expect(meta.width == 320)
        #expect(meta.height == 240)
        // ~1s (12 frames @ 12fps); allow generous slack for container rounding.
        let duration = try #require(meta.duration)
        #expect(duration > 0.5 && duration < 2.0)
    }

    // MARK: - Poster

    @Test("makeVideoPoster → a decodable JPEG bounded to the requested size")
    func poster() async throws {
        let mp4 = try await FixtureVideos.solidVideo(width: 320, height: 240)
        let jpeg = try await ThumbnailGenerator.makeVideoPoster(from: mp4, maxPixelSize: 128)

        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let type = try #require(CGImageSourceGetType(source) as String?)
        #expect(UTType(type) == .jpeg)
        let props = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let w = try #require((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let h = try #require((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        #expect(max(w, h) <= 128)   // bounded to the requested max edge
        #expect(min(w, h) > 0)
    }

    // MARK: - End-to-end pipeline

    @Test("ingest a video → .video asset, video blob + poster tiers, duration set")
    func endToEnd() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let mp4 = try await FixtureVideos.solidVideo(width: 320, height: 240)
        let input = IngestInput(
            source: .data(mp4), provenance: Self.provenance(), collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        guard case .ingested(let asset, let deduplicated) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        #expect(deduplicated == false)
        #expect(asset.kind == .video)
        #expect(asset.mimeType == "video/mp4")
        #expect(asset.width == 320)
        #expect(asset.height == 240)
        #expect(asset.fileSize == mp4.count)
        #expect((asset.duration ?? 0) > 0.5)

        // The VIDEO bytes are the blob (stored under .mp4), and every thumbnail
        // tier exists (rendered from the poster frame).
        let hash = try #require(asset.blobHash)
        #expect(env.store.hasBlob(hash: hash, fileExtension: "mp4"))
        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: hash, size: tier.rawValue, fileExtension: "jpg"))
        }

        // Reachable via the read API in the target collection.
        let items = try await env.services.collectionItems(in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(items.first?.asset.kind == .video)
    }

    @Test("re-ingesting the same video dedups (one blob, P14 short-circuit)")
    func dedup() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let mp4 = try await FixtureVideos.solidVideo(width: 240, height: 240)
        let input = IngestInput(
            source: .data(mp4), provenance: Self.provenance(), collectionID: env.collectionID)

        _ = await env.pipeline.ingest(input)
        let second = await env.pipeline.ingest(input)
        guard case .ingested(_, let deduplicated) = second else {
            Issue.record("expected .ingested on re-capture")
            return
        }
        #expect(deduplicated == true)
        #expect(env.blobFiles().count == 1)   // one video blob, not two
    }
}
