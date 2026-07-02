// AtelierIngestion — single-image pipeline tests (chunk 4, A2 / P14 / C8)
//
// End-to-end for ONE image: blob + all thumbnail tiers on disk, asset persisted
// with correct byte-derived facts, the A2 invariant (every persisted asset's
// blob exists), the P14 short-circuit / idempotent retry (dedup, one blob/row,
// regenerate only a purged tier), and the C8 failure mapping (corrupt /
// non-image / missing file → typed `.failed`, nothing partial persisted).

import Foundation
import Testing
import AtelierCore
@testable import AtelierIngestion

@Suite("IngestPipeline")
struct IngestPipelineTests {
    /// A `local_paste` provenance draft (no `originalURL`; dedup matches on
    /// platform + blob hash).
    static func pasteProvenance() -> SourceDraft {
        SourceDraft(platform: .localPaste, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Build an in-memory `.data` input for `bytes` into `env`'s collection.
    static func input(_ bytes: Data, into env: TempPipeline) -> IngestInput {
        IngestInput(
            source: .data(bytes),
            provenance: pasteProvenance(),
            collectionID: env.collectionID)
    }

    // MARK: - End-to-end

    @Test("ingest one image → blob + all tiers on disk + persisted asset")
    func endToEnd() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 300, height: 200, format: .png)
        let outcome = await env.pipeline.ingest(Self.input(bytes, into: env))

        guard case .ingested(let asset, let deduplicated) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        #expect(deduplicated == false)

        // Blob on disk (A2) at the content-addressed path.
        #expect(env.store.hasBlob(hash: asset.blobHash, fileExtension: "png"))
        // All three thumbnail tiers present.
        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: asset.blobHash, size: tier.rawValue, fileExtension: "jpg"))
        }

        // Asset persisted with correct byte-derived facts.
        #expect(asset.width == 300)
        #expect(asset.height == 200)
        #expect(asset.mimeType == "image/png")
        #expect(asset.kind == .image)
        #expect(asset.fileSize == bytes.count)

        // Reachable via the read API, in the target collection.
        let items = try await env.services.collectionItems(in: env.collectionID)
        #expect(items.count == 1)
        #expect(items.first?.asset.id == asset.id)
        #expect(items.first?.asset.blobHash == asset.blobHash)

        // A2 invariant: every persisted asset's blob exists on disk.
        let all = try await env.services.searchAssets(text: nil)
        for detail in all {
            #expect(env.store.hasBlob(
                hash: detail.asset.blobHash,
                fileExtension: fileExtension(forMIME: detail.asset.mimeType)))
        }
    }

    // MARK: - P14 short-circuit / idempotent retry

    @Test("re-ingesting the same bytes+provenance dedups: one blob, one asset")
    func idempotentRetryDedups() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 128, height: 128, format: .png)

        let first = await env.pipeline.ingest(Self.input(bytes, into: env))
        let second = await env.pipeline.ingest(Self.input(bytes, into: env))

        guard case .ingested(let a1, let d1) = first,
              case .ingested(let a2, let d2) = second else {
            Issue.record("expected both .ingested, got \(first), \(second)")
            return
        }
        #expect(d1 == false)
        #expect(d2 == true)             // second is a dedup hit (18A + P14)
        #expect(a1.id == a2.id)          // same resolved asset

        // Exactly ONE blob file and ONE asset row.
        #expect(env.blobFiles().count == 1)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.count == 1)
        let items = try await env.services.collectionItems(in: env.collectionID)
        #expect(items.count == 1)
    }

    @Test("purging one thumbnail tier then re-ingesting regenerates ONLY it")
    func regeneratesOnlyMissingTier() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 256, height: 256, format: .png)
        let first = await env.pipeline.ingest(Self.input(bytes, into: env))
        guard case .ingested(let asset, _) = first else {
            Issue.record("expected .ingested")
            return
        }

        // Delete the medium tier's thumbnail file.
        let mediumURL = env.store.thumbnailURL(
            hash: asset.blobHash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg")
        try FileManager.default.removeItem(at: mediumURL)
        #expect(!env.store.hasThumbnail(
            hash: asset.blobHash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg"))

        // Re-ingest: the missing tier is regenerated; still one asset (dedup).
        let second = await env.pipeline.ingest(Self.input(bytes, into: env))
        guard case .ingested(_, let dedup) = second else {
            Issue.record("expected .ingested")
            return
        }
        #expect(dedup == true)

        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: asset.blobHash, size: tier.rawValue, fileExtension: "jpg"))
        }
        #expect(env.blobFiles().count == 1)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.count == 1)             // no duplicate asset
    }

    // MARK: - Failure mapping (C8)

    @Test("corrupt image → .failed(.decodeFailed), nothing persisted")
    func corruptFailsDecode() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.corruptImage()
        let outcome = await env.pipeline.ingest(Self.input(bytes, into: env))

        guard case .failed(let error) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(error == .decodeFailed || error == .unreadableSource)

        // No blob, no asset for a failure.
        #expect(env.blobFiles().isEmpty)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.isEmpty)
    }

    @Test("non-image bytes → .failed with an IngestError, nothing persisted")
    func nonImageFails() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let outcome = await env.pipeline.ingest(Self.input(FixtureImages.nonImageBytes(), into: env))

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(env.blobFiles().isEmpty)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.isEmpty)
    }

    @Test("missing file URL → .failed(.unreadableSource)")
    func missingFileURLFails() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let missing = env.root.appendingPathComponent("does-not-exist.png")
        let input = IngestInput(
            source: .fileURL(missing),
            provenance: Self.pasteProvenance(),
            collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        #expect({ if case .failed(.unreadableSource) = outcome { return true }; return false }())
        #expect(env.blobFiles().isEmpty)
    }

    @Test("file URL input ingests just like in-memory bytes")
    func fileURLIngests() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 200, height: 100, format: .jpeg)
        let fileURL = env.root.appendingPathComponent("drag.jpg")
        try bytes.write(to: fileURL)

        let input = IngestInput(
            source: .fileURL(fileURL),
            provenance: Self.pasteProvenance(),
            collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        guard case .ingested(let asset, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        #expect(asset.width == 200)
        #expect(asset.height == 100)
        #expect(env.store.hasBlob(hash: asset.blobHash, fileExtension: "jpeg"))
    }

    // MARK: - Helpers

    /// The canonical file extension the store used for a blob of `mime`, matching
    /// `ImageMetadata`'s `preferredFilenameExtension`.
    private func fileExtension(forMIME mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/jpeg": return "jpeg"
        case "image/heic": return "heic"
        default: return ""
        }
    }
}
