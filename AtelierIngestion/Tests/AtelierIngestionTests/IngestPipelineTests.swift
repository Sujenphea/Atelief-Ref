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
        // A byte-backed asset always has a hash (003 · O1 made it optional).
        let hash = try #require(asset.blobHash)

        // Blob on disk (A2) at the content-addressed path.
        #expect(env.store.hasBlob(hash: hash, fileExtension: "png"))
        // All three thumbnail tiers present.
        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: hash, size: tier.rawValue, fileExtension: "jpg"))
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
                hash: try #require(detail.asset.blobHash),
                fileExtension: fileExtension(forMIME: try #require(detail.asset.mimeType))))
        }
    }

    // MARK: - Media-less content path (003 · C3)

    @Test("a media-less content input → ingested asset, NO blob / thumbnail work")
    func contentInputIngests() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let input = IngestInput(
            content: .color(hex: "#4488cc"),
            provenance: SourceDraft(platform: .localPaste, capturedAt: Date()),
            collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        guard case .ingested(let asset, let deduplicated) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        #expect(deduplicated == false)
        #expect(asset.kind == .color)
        #expect(asset.blobHash == nil)          // no bytes → no blob
        #expect(asset.content == .color(hex: "#4488cc"))
        // Nothing written to the blob store — the content path skips it entirely.
        #expect(env.blobFiles().isEmpty)
        // Reachable via the read API.
        let items = try await env.services.collectionItems(in: env.collectionID)
        #expect(items.map(\.asset.id) == [asset.id])
    }

    @Test("an invalid content draft folds to .failed(.persistence(...)) — batch-safe")
    func invalidContentFailsCleanly() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let input = IngestInput(
            content: .color(hex: "not a color"),
            provenance: SourceDraft(platform: .localPaste, capturedAt: Date()),
            collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        guard case .failed(let error) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(error == .persistence(.invalidColor))
        // Nothing persisted.
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.isEmpty)
    }

    // MARK: - Media-less + card image (003 · C3, Option 3 — hybrid)

    /// A twitter provenance draft (the tweet permalink is aligned in the funnel).
    static func twitterProvenance(_ url: String) -> SourceDraft {
        SourceDraft(
            platform: .twitter, originalURL: url, authorHandle: "@ava",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("a tweet WITH a card image → blob + tiers on disk AND tweet content identity")
    func contentWithBytesIngestsTweetWithBlob() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let card = try FixtureImages.solidImage(width: 1200, height: 675, format: .png)
        let input = IngestInput(
            content: .tweet(tweetID: "https://x.com/ava/status/900", text: "a brass lamp",
                            authorHandle: "@ava",
                            media: [TweetMedia(url: "https://pbs.example/a.jpg")]),
            image: .data(card),
            provenance: Self.twitterProvenance("https://x.com/ava/status/900"),
            collectionID: env.collectionID)
        let outcome = await env.pipeline.ingest(input)

        guard case .ingested(let asset, let deduplicated) = outcome else {
            Issue.record("expected .ingested, got \(outcome)"); return
        }
        #expect(deduplicated == false)
        #expect(asset.kind == .tweet)
        #expect(asset.dedupKey == "900")
        // The card image is a real blob (dims + mime from the bytes).
        let hash = try #require(asset.blobHash)
        #expect(asset.width == 1200 && asset.height == 675)
        #expect(asset.mimeType == "image/png")
        #expect(env.store.hasBlob(hash: hash, fileExtension: "png"))
        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: hash, size: tier.rawValue, fileExtension: "jpg"))
        }
        // The projection surfaces the blob AS the tweet's card image.
        if case .tweet(let t) = asset.content {
            #expect(t.cardImageBlobHash == hash)
            #expect(t.text == "a brass lamp")
        } else {
            Issue.record("expected .tweet content")
        }
    }

    @Test("re-capturing a tweet with a DIFFERENT card image dedups + reclaims the orphan blob")
    func contentWithBytesDedupReclaimsOrphan() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let cardA = try FixtureImages.solidImage(width: 4, height: 3, format: .png)
        let cardB = try FixtureImages.solidImage(width: 8, height: 6, format: .png)
        func tweetInput(_ card: Data) -> IngestInput {
            IngestInput(
                content: .tweet(tweetID: "901", text: "one"),
                image: .data(card),
                provenance: Self.twitterProvenance("https://x.com/ava/status/901"),
                collectionID: env.collectionID)
        }

        let a = await env.pipeline.ingest(tweetInput(cardA))
        guard case .ingested(let assetA, _) = a else { Issue.record("A not ingested"); return }
        #expect(env.blobFiles().count == 1)            // card A stored

        // Same tweet id, different card bytes → dedup to A; card B is unreferenced.
        let b = await env.pipeline.ingest(tweetInput(cardB))
        guard case .ingested(let assetB, let dedupB) = b else { Issue.record("B not ingested"); return }
        #expect(dedupB == true)
        #expect(assetB.id == assetA.id)
        #expect(assetB.blobHash == assetA.blobHash)    // first card image retained
        // The orphan (card B) was reclaimed — only card A remains on disk.
        #expect(env.blobFiles().count == 1)
        #expect(env.store.hasBlob(
            hash: try #require(assetA.blobHash), fileExtension: "png"))
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
        let hash = try #require(asset.blobHash)

        // Delete the medium tier's thumbnail file.
        let mediumURL = env.store.thumbnailURL(
            hash: hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg")
        try FileManager.default.removeItem(at: mediumURL)
        #expect(!env.store.hasThumbnail(
            hash: hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg"))

        // Re-ingest: the missing tier is regenerated; still one asset (dedup).
        let second = await env.pipeline.ingest(Self.input(bytes, into: env))
        guard case .ingested(_, let dedup) = second else {
            Issue.record("expected .ingested")
            return
        }
        #expect(dedup == true)

        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: hash, size: tier.rawValue, fileExtension: "jpg"))
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
        #expect(env.store.hasBlob(hash: try #require(asset.blobHash), fileExtension: "jpeg"))
    }

    // MARK: - Phase timing (16A)

    /// A thread-safe collector for the pipeline's timing sink.
    final class TimingCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var _timings: [IngestTiming] = []
        func record(_ t: IngestTiming) { lock.lock(); _timings.append(t); lock.unlock() }
        var timings: [IngestTiming] { lock.lock(); defer { lock.unlock() }; return _timings }
    }

    @Test("timing sink reports tiers generated once, then 0 on the P14 short-circuit")
    func timingSink() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let collector = TimingCollector()
        let pipeline = IngestPipeline(
            store: env.store, services: env.services,
            timing: { collector.record($0) })
        let bytes = try FixtureImages.solidImage(width: 120, height: 120, format: .png)

        _ = await pipeline.ingest(Self.input(bytes, into: env))
        let first = try #require(collector.timings.first)
        #expect(first.blobExisted == false)
        #expect(first.tiersGenerated == ThumbnailTier.allCases.count) // all tiers made
        #expect(first.totalMillis >= 0)
        #expect(first.thumbnailMillis >= 0)

        // Re-ingest the SAME bytes: blob + every tier already on disk → no thumbnail
        // work at all (P14). This is the fast path the timing log confirms is cheap.
        _ = await pipeline.ingest(Self.input(bytes, into: env))
        let second = try #require(collector.timings.last)
        #expect(second.blobExisted == true)
        #expect(second.tiersGenerated == 0)
    }

    // MARK: - Orphan-blob reclaim (G2)

    @Test("DB failure after a new blob write reclaims the orphan blob")
    func reclaimOrphanBlobOnPersistFailure() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 140, height: 100, format: .png)
        let hash = ContentHasher.hash(bytes)
        let missingCollection = UUID()
        let input = IngestInput(
            source: .data(bytes),
            provenance: Self.pasteProvenance(),
            collectionID: missingCollection)

        let outcome = await env.pipeline.ingest(input)
        guard case .failed = outcome else {
            Issue.record("expected .failed for missing collection, got \(outcome)")
            return
        }
        #expect(!env.store.hasBlob(hash: hash, fileExtension: "png"))
        #expect(env.blobFiles().isEmpty)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.isEmpty)
    }

    @Test("DB failure on a shared (dedup) blob does not delete it")
    func sharedBlobSurvivesPersistFailure() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 160, height: 110, format: .png)
        let first = await env.pipeline.ingest(Self.input(bytes, into: env))
        guard case .ingested(let asset, _) = first else {
            Issue.record("expected first ingest to succeed")
            return
        }
        let hash = try #require(asset.blobHash)
        #expect(env.store.hasBlob(hash: hash, fileExtension: "png"))

        // Same bytes into a nonexistent collection → persist fails after P14 sees
        // the existing blob; must NOT removeBlob the shared content.
        let bad = IngestInput(
            source: .data(bytes),
            provenance: Self.pasteProvenance(),
            collectionID: UUID())
        let second = await env.pipeline.ingest(bad)
        guard case .failed = second else {
            Issue.record("expected .failed, got \(second)")
            return
        }
        #expect(env.store.hasBlob(hash: hash, fileExtension: "png"))
        #expect(env.blobFiles().count == 1)
        let all = try await env.services.searchAssets(text: nil)
        #expect(all.count == 1)
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
