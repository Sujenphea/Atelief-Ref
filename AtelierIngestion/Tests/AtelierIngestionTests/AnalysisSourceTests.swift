// AtelierIngestion — which bytes an analysis pass reads (012)
//
// The one rule ``AnalysisSource`` exists to hold: an image is analyzed from its
// blob, a video from its POSTER. Getting this wrong is not a crash — it is handing
// an `.mp4` to ImageIO, which fails quietly per asset and leaves video permanently
// un-analyzed, which is exactly the state this replaced.

import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("AnalysisSource")
struct AnalysisSourceTests {

    /// Ingest a real video through the pipeline (blob + poster tiers on disk) and
    /// return its asset.
    private func ingestVideo(_ env: TempPipeline) async throws -> Asset {
        let mp4 = try FixtureVideos.solidVideo(width: 320, height: 240)
        let outcome = await env.pipeline.ingest(IngestInput(
            source: .data(mp4),
            provenance: SourceDraft(platform: .localPaste, capturedAt: Date()),
            collectionID: env.collectionID))
        guard case .ingested(let asset, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            throw CocoaError(.fileNoSuchFile)
        }
        return asset
    }

    private func ingestImage(_ env: TempPipeline) async throws -> Asset {
        let png = try FixtureImages.solidColorImage(width: 64, height: 64, red: 10, green: 120, blue: 200)
        let outcome = await env.pipeline.ingest(IngestInput(
            source: .data(png),
            provenance: SourceDraft(platform: .localPaste, capturedAt: Date()),
            collectionID: env.collectionID))
        guard case .ingested(let asset, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            throw CocoaError(.fileNoSuchFile)
        }
        return asset
    }

    @Test("a video is read from its poster JPEG, not its movie bytes")
    func videoReadsPoster() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let video = try await ingestVideo(env)
        let hash = try #require(video.blobHash)

        let data = try AnalysisSource.imageData(for: video, in: env.store)

        // It is the poster tier byte-for-byte — not the movie, and not a re-render.
        let poster = try env.store.readThumbnail(
            hash: hash, size: ThumbnailTier.large.rawValue, fileExtension: "jpg")
        #expect(data == poster)
        let movie = try env.store.readBlob(hash: hash, fileExtension: "mp4")
        #expect(data != movie)

        // And it is decodable, which the movie bytes would not have been.
        #expect(throws: Never.self) {
            _ = try ImageDecoding.thumbnailCGImage(from: data, maxPixelSize: 256)
        }
    }

    @Test("an image is read from its blob")
    func imageReadsBlob() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let image = try await ingestImage(env)
        let hash = try #require(image.blobHash)

        let data = try AnalysisSource.imageData(for: image, in: env.store)
        #expect(data == (try env.store.readBlob(hash: hash, fileExtension: "png")))
    }

    /// A video whose poster tier is gone fails as a typed miss rather than by
    /// handing the movie to ImageIO — the batch counts it and moves on, and the
    /// error names the asset instead of blaming a decode.
    @Test("a video with no poster on disk fails without falling back to the movie")
    func videoWithoutPosterFails() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let video = try await ingestVideo(env)
        let hash = try #require(video.blobHash)

        for tier in ThumbnailTier.allCases {
            try? FileManager.default.removeItem(
                at: env.store.thumbnailURL(hash: hash, size: tier.rawValue, fileExtension: "jpg"))
        }

        #expect(throws: (any Error).self) {
            _ = try AnalysisSource.imageData(for: video, in: env.store)
        }
    }

    @Test("an asset with no blob at all is a typed miss")
    func mediaLessIsTypedMiss() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let color = try await env.services.ingestContent(
            .color(hex: "#336699"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: env.collectionID).asset

        #expect(throws: AnalysisSourceError.noImageBytes(color.id)) {
            _ = try AnalysisSource.imageData(for: color, in: env.store)
        }
    }
}
