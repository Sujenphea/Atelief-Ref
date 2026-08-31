// AtelierIngestion — generating fewer tiers than there are (096 · 4).
//
// `IngestPipeline` has always taken a `tiers:` argument and has always defaulted it to
// `ThumbnailTier.allCases`, and until now every caller in the program took the default.
// The phone does not: it reads exactly two thumbnail files — the grid tier and the detail
// tier — and has no canvas renderer to want the 128 px LOD, so `MobileIngest` builds its
// pipeline with `[.medium, .large]` and skips a decode, a JPEG encode and a file write per
// capture on a device with a jetsam ceiling.
//
// `ThumbnailTierAgreementTests` pins that the two tiers the phone READS are those two
// cases. Nothing pinned what a pipeline given a narrowed list actually WRITES, which is the
// other half of the same claim and the half that would fail silently: the grid would draw
// blank tiles over a library that is otherwise perfectly healthy.
//
// The phone's drain is not exercised here and cannot be — its scheduler is in an iOS app
// target. What is exercised is everything underneath it: the narrowed pipeline, the drain
// running through one with `.retainForExport`, and the property that makes the narrowing
// safe to take on this device only — that the tier left out is regenerated, without a
// second asset, by any later host that wants it.

import Foundation
import Testing

import AtelierCapture
import AtelierCaptureTestSupport
import AtelierCore
import AtelierLibraryPaths
@testable import AtelierIngestion

@Suite("Narrowed thumbnail tiers (096 4)")
struct NarrowedThumbnailTiersTests {
    /// What `MobileIngest.thumbnailTiers` is. Restated rather than imported, because the
    /// app target is not reachable from `swift test` — so this is a copy, and the first
    /// test below is what stops it being a copy of nothing.
    static let phoneTiers: [ThumbnailTier] = [.medium, .large]

    private static func input(_ bytes: Data, into env: TempPipeline) -> IngestInput {
        IngestInput(
            source: .data(bytes),
            provenance: SourceDraft(
                platform: .localPaste,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            collectionID: env.collectionID)
    }

    /// A pipeline over `env`'s own store and library, generating only `tiers`.
    private static func pipeline(
        _ env: TempPipeline, tiers: [ThumbnailTier]
    ) -> IngestPipeline {
        IngestPipeline(store: env.store, services: env.services, tiers: tiers)
    }

    // MARK: - The two tiers are the two the phone reads

    @Test("the phone's tier list is exactly the two sizes the phone resolves paths for")
    func theListMatchesWhatIsRead() {
        // The narrowing is only safe if the set generated CONTAINS everything read, and
        // only worth doing if it contains nothing else. Both directions, so a future tier
        // added to the reader without being added here fails, and so does the reverse.
        #expect(
            Set(Self.phoneTiers.map(\.rawValue))
                == [LibraryMediaPaths.gridThumbnailSize,
                    LibraryMediaPaths.detailThumbnailSize])
    }

    @Test("the tier the phone omits is one nothing on the phone resolves a path to")
    func theOmittedTierIsNotRead() {
        let omitted = Set(ThumbnailTier.allCases).subtracting(Self.phoneTiers)
        #expect(omitted == [.small])
        for tier in omitted {
            #expect(tier.rawValue != LibraryMediaPaths.gridThumbnailSize)
            #expect(tier.rawValue != LibraryMediaPaths.detailThumbnailSize)
        }
    }

    // MARK: - What a narrowed pipeline writes

    @Test("a pipeline given two tiers writes those two files and no third")
    func narrowedPipelineWritesOnlyItsTiers() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 300, height: 200, format: .png)
        let outcome = await Self.pipeline(env, tiers: Self.phoneTiers)
            .ingest(Self.input(bytes, into: env))

        guard case .ingested(let asset, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        let hash = try #require(asset.blobHash)

        // Present: the two the grid and the item screen open.
        #expect(env.store.hasThumbnail(
            hash: hash, size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg"))
        #expect(env.store.hasThumbnail(
            hash: hash, size: LibraryMediaPaths.detailThumbnailSize, fileExtension: "jpg"))
        // Absent: the LOD tier only a canvas asks for.
        #expect(!env.store.hasThumbnail(
            hash: hash, size: ThumbnailTier.small.rawValue, fileExtension: "jpg"))
        // And nothing else at all — a count, so a fourth file appearing from anywhere
        // fails this rather than being invisible to three `hasThumbnail` calls.
        #expect(env.thumbnailFiles().count == 2)

        // The blob is untouched by any of this: narrowing is about derivatives.
        #expect(env.store.hasBlob(hash: hash, fileExtension: "png"))
        #expect(env.blobFiles().count == 1)
    }

    @Test("the default is still every tier — narrowing is the caller's, not the pipeline's")
    func theDefaultIsUnchanged() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 300, height: 200, format: .png)
        // `env.pipeline` is built with no `tiers:` argument, which is what every macOS
        // caller does. This is the line that fails if someone "helpfully" narrows the
        // default to match the phone.
        let outcome = await env.pipeline.ingest(Self.input(bytes, into: env))

        guard case .ingested(let asset, _) = outcome else {
            Issue.record("expected .ingested, got \(outcome)")
            return
        }
        let hash = try #require(asset.blobHash)
        for tier in ThumbnailTier.allCases {
            #expect(env.store.hasThumbnail(
                hash: hash, size: tier.rawValue, fileExtension: "jpg"))
        }
        #expect(env.thumbnailFiles().count == ThumbnailTier.allCases.count)
    }

    // MARK: - The tier that was skipped is not lost

    @Test("a full-tier host fills in the missing tier without forking a second asset")
    func theOmittedTierIsRecoverable() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let bytes = try FixtureImages.solidImage(width: 256, height: 256, format: .png)

        // First: the phone's narrowed pipeline.
        let first = await Self.pipeline(env, tiers: Self.phoneTiers)
            .ingest(Self.input(bytes, into: env))
        guard case .ingested(let phoneAsset, let firstDedup) = first else {
            Issue.record("expected .ingested, got \(first)")
            return
        }
        #expect(firstDedup == false)
        #expect(env.thumbnailFiles().count == 2)

        // Then: a host that wants every tier, over the same bytes and provenance. This is
        // the shape of a capture crossing to the Mac — except that the real crossing sends
        // the inbox's ORIGINAL payload, so the Mac never depends on what the phone wrote.
        let second = await env.pipeline.ingest(Self.input(bytes, into: env))
        guard case .ingested(let macAsset, let secondDedup) = second else {
            Issue.record("expected .ingested, got \(second)")
            return
        }

        // 18A dedup: the same asset, not a second one — the narrowing does not fork.
        #expect(secondDedup == true)
        #expect(macAsset.id == phoneAsset.id)
        #expect(env.blobFiles().count == 1)

        // P14 regenerated only what was missing, and now all three are there.
        #expect(env.thumbnailFiles().count == ThumbnailTier.allCases.count)
        let hash = try #require(phoneAsset.blobHash)
        #expect(env.store.hasThumbnail(
            hash: hash, size: ThumbnailTier.small.rawValue, fileExtension: "jpg"))
    }

    // MARK: - The phone's drain, as far as a host can run it

    @Test("the phone's drain: two tiers on disk, and the record kept for the export")
    func thePhonesDrainInFull() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }
        let layout = InboxLayout(libraryRoot: env.root)

        // Everything `MobileIngest.makeDrain` builds, with the app's two constants: a
        // narrowed pipeline, a coordinator at the phone's width, and the retention that
        // says this library is a waypoint rather than the destination.
        let drain = InboxDrain(
            libraryRoot: env.root,
            coordinator: IngestCoordinator(
                pipeline: Self.pipeline(env, tiers: Self.phoneTiers), maxConcurrent: 2),
            retention: .retainForExport)

        let id = UUID()
        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 40, height: 30), id: id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(await drain.drainOnce() == DrainSummary(ingested: 1))

        // It is in the library, with the two tiers the grid and the item screen open.
        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        let hash = try #require(items.first?.asset.blobHash)
        #expect(env.store.hasThumbnail(
            hash: hash, size: LibraryMediaPaths.gridThumbnailSize, fileExtension: "jpg"))
        #expect(env.store.hasThumbnail(
            hash: hash, size: LibraryMediaPaths.detailThumbnailSize, fileExtension: "jpg"))
        #expect(env.thumbnailFiles().count == 2)

        // And it is still owed to the Mac: out of the pending set so no later pass runs it
        // twice, still on disk because `InboxArchive` reads both sets.
        #expect(try layout.pendingRecordURLs().isEmpty)
        #expect(try layout.ingestedRecordURLs().count == 1)
        #expect(FileManager.default.fileExists(
            atPath: layout.ingestedRecordURL(for: id).path))
    }

    @Test("a second pass over a drained inbox finds nothing and changes nothing")
    func theSecondPassIsANoOp() async throws {
        let env = try await makeTempPipeline()
        defer { env.cleanup() }

        let drain = InboxDrain(
            libraryRoot: env.root,
            coordinator: IngestCoordinator(
                pipeline: Self.pipeline(env, tiers: Self.phoneTiers), maxConcurrent: 2),
            retention: .retainForExport)

        try InboxWriter(libraryRoot: env.root).write(
            .sample(collectionId: env.collectionID),
            payload: CaptureFixtures.png(width: 40, height: 30),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(await drain.drainOnce() == DrainSummary(ingested: 1))
        // The phone drains at launch AND on every foreground, so this is the case it is in
        // nearly always: the pass that finds an inbox it has already emptied. Retention
        // moved the record out of `pendingRecordURLs()`, so there is nothing to re-run —
        // if it were still pending, every foreground would re-decode the whole backlog.
        #expect(await drain.drainOnce() == DrainSummary())

        let items = try await env.services.collectionItems(
            in: env.collectionID, includeArchived: false)
        #expect(items.count == 1)
        #expect(env.blobFiles().count == 1)
        #expect(env.thumbnailFiles().count == 2)
    }
}
