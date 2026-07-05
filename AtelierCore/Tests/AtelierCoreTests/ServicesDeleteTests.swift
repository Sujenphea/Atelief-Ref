// AtelierCore — deleteAssets: cascade, source/blob GC, dedup-safety, idempotency
//
// The destructive counterpart to removeAssets (membership only). These exercise
// the whole-library delete through the public surface: the asset row and its
// dependents go, orphaned sources are GC'd, and the RECLAIMABLE blobs are
// reported dedup-safely (a hash still shared by another asset is never emitted).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: deleteAssets (cascade + GC + dedup)")
struct ServicesDeleteTests {

    // MARK: Fixtures

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String = "abc123", mime: String = "image/png") -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: mime,
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(
        url: String? = "https://example.com/a", platform: Platform = .web
    ) -> SourceDraft {
        SourceDraft(platform: platform, originalURL: url, capturedAt: Date())
    }

    private func assetCount(_ t: TempDatabase) throws -> Int {
        try t.database.read { try Asset.fetchCount($0) }
    }
    private func sourceCount(_ t: TempDatabase) throws -> Int {
        try t.database.read { try Source.fetchCount($0) }
    }
    private func itemCount(_ t: TempDatabase) throws -> Int {
        try t.database.read { try CollectionItem.fetchCount($0) }
    }
    private func tagCount(_ t: TempDatabase) throws -> Int {
        try t.database.read { try Tag.fetchCount($0) }
    }
    private func assetTagCount(_ t: TempDatabase) throws -> Int {
        try t.database.read { try AssetTag.fetchCount($0) }
    }

    // MARK: Happy path — full teardown of one asset

    @Test("deleteAssets removes the asset, its membership, its source; reports the blob")
    func deletesEverything() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)

        let orphans = try await services.deleteAssets([r.asset.id])

        #expect(try assetCount(temp) == 0)
        #expect(try itemCount(temp) == 0)   // membership CASCADEd
        #expect(try sourceCount(temp) == 0) // last-asset source GC'd
        #expect(orphans == [OrphanedBlob(blobHash: "abc123", mimeType: "image/png")])
    }

    @Test("delete cascades memberships across every folder the asset was in")
    func cascadesAllMemberships() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: a.id)
        try await services.addAssets([r.asset.id], to: b.id)
        #expect(try itemCount(temp) == 2)

        _ = try await services.deleteAssets([r.asset.id])
        #expect(try itemCount(temp) == 0)   // BOTH memberships gone
        #expect(try assetCount(temp) == 0)
    }

    // MARK: Dedup-safety — the load-bearing invariant

    @Test("shared blob hash: deleting one asset does NOT orphan the still-shared blob")
    func sharedHashNotOrphaned() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Same bytes, DIFFERENT provenance → two assets sharing one hash.
        let a = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://twitter.com/x"), into: c.id)
        let b = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://pinterest.com/y"), into: c.id)

        // Delete only the first — the blob is still referenced by the second.
        let orphans = try await services.deleteAssets([a.asset.id])
        #expect(orphans.isEmpty)                // NOT reclaimable — dedup-safe
        #expect(try assetCount(temp) == 1)      // b survives
        #expect(try sourceCount(temp) == 1)     // b's source survives; a's GC'd

        // Now delete the second — the last reference is gone, so it's reported.
        let orphans2 = try await services.deleteAssets([b.asset.id])
        #expect(orphans2 == [OrphanedBlob(blobHash: "deadbeef", mimeType: "image/png")])
        #expect(try assetCount(temp) == 0)
        #expect(try sourceCount(temp) == 0)
    }

    @Test("deleting both shared-hash assets at once orphans the blob exactly once")
    func bothSharedAtOnceOrphanOnce() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://twitter.com/x"), into: c.id)
        let b = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://pinterest.com/y"), into: c.id)

        let orphans = try await services.deleteAssets([a.asset.id, b.asset.id])
        #expect(orphans == [OrphanedBlob(blobHash: "deadbeef", mimeType: "image/png")])
        #expect(try assetCount(temp) == 0)
        #expect(try sourceCount(temp) == 0)
    }

    // MARK: "Delete is forgotten" — bulk-import ledger (known-sources == bytes in store)

    private func jobIngestedCount(_ services: AppServices, _ jobID: UUID) async throws -> Int {
        let jobs = try await services.listJobs()
        return jobs.first { $0.id == jobID }?.ingestedCount ?? -1
    }

    @Test("deleting a bulk-ingested asset forgets its job_item so a re-sweep re-ingests")
    func deleteForgetsLedger() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")

        // A pin ingested through a sweep: an asset + a ledger row sharing the blob hash.
        let r = try await services.ingest(
            assetDraft(hash: "a1b2"),
            from: sourceDraft(url: "https://pinterest.com/pin/A", platform: .pinterest),
            into: c.id)
        let job = try await services.createJob(platform: .pinterest, scope: "board:1")
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-A", status: .ingested, blobHash: "a1b2")

        // Before delete: the source is "known" (a re-sweep would skip it).
        #expect(try await services.knownSourceIDs(forJob: job.id).contains("pin-A"))
        #expect(try await jobIngestedCount(services, job.id) == 1)

        // Delete the asset → its blob orphans → the ledger row is forgotten.
        let orphans = try await services.deleteAssets([r.asset.id])
        #expect(orphans == [OrphanedBlob(blobHash: "a1b2", mimeType: "image/png")])
        #expect(try await services.knownSourceIDs(forJob: job.id).isEmpty)   // re-sweep re-ingests
        // The denormalized counter stays drift-free (recomputed in the same txn).
        #expect(try await jobIngestedCount(services, job.id) == 0)
    }

    @Test("forgetting is per-blob: a source_id sharing a still-referenced blob stays known")
    func sharedBlobStaysKnown() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // Two assets, same bytes, different provenance — one blob, two references.
        let a = try await services.ingest(
            assetDraft(hash: "5ade5f"),
            from: sourceDraft(url: "https://pinterest.com/x", platform: .pinterest), into: c.id)
        _ = try await services.ingest(
            assetDraft(hash: "5ade5f"),
            from: sourceDraft(url: "https://twitter.com/y", platform: .twitter), into: c.id)
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-X", status: .ingested, blobHash: "5ade5f")

        // Deleting only the first leaves the blob referenced → NOT orphaned → still known.
        let orphans = try await services.deleteAssets([a.asset.id])
        #expect(orphans.isEmpty)
        #expect(try await services.knownSourceIDs(forJob: job.id).contains("pin-X"))
        #expect(try await jobIngestedCount(services, job.id) == 1)
    }

    @Test("deleting a non-bulk asset (no ledger row) leaves job_item untouched")
    func deleteWithoutLedgerIsInert() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-keep", status: .ingested, blobHash: "b0b0")
        // An unrelated asset (different blob), captured outside any sweep.
        let r = try await services.ingest(
            assetDraft(hash: "c0ffee"), from: sourceDraft(), into: c.id)

        _ = try await services.deleteAssets([r.asset.id])
        // The ledger row for a DIFFERENT blob is untouched.
        #expect(try await services.knownSourceIDs(forJob: job.id).contains("pin-keep"))
        #expect(try await jobIngestedCount(services, job.id) == 1)
    }

    // MARK: reconcileOrphanedKnownItems — proactive known ⟺ blob-present GC
    //
    // deleteAssets forgets a blob's ledger rows the instant it orphans. But an asset
    // removed by ANY other path (a delete predating the forget feature, a future
    // non-deleteAssets caller) strands its job_item as stale-"known" — and a re-sweep
    // would dedup-skip that source forever despite the bytes being gone. The reconcile
    // sweep repairs that; these prove it forgets exactly the orphans, spares the live,
    // recomputes counts, and no-ops when clean.

    @Test("reconcile forgets a known item whose blob has no backing asset")
    func reconcileForgetsOrphan() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // A ledger row marked known, but no asset ever carried its blob — exactly the
        // stale state a pre-forget delete would leave behind.
        let job = try await services.createJob(platform: .pinterest, scope: "board:1")
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-A", status: .ingested, blobHash: "dead01")
        #expect(try await services.knownSourceIDs(forJob: job.id).contains("pin-A"))
        #expect(try await jobIngestedCount(services, job.id) == 1)

        let reconciled = try await services.reconcileOrphanedKnownItems()
        #expect(reconciled == [job.id])
        #expect(try await services.knownSourceIDs(forJob: job.id).isEmpty) // re-sweep re-ingests
        #expect(try await jobIngestedCount(services, job.id) == 0)         // count recomputed
    }

    @Test("reconcile spares a known item still backed by a live asset")
    func reconcileSparesLiveBacked() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(
            assetDraft(hash: "11ee"),
            from: sourceDraft(url: "https://pinterest.com/pin/A", platform: .pinterest),
            into: c.id)
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-A", status: .ingested, blobHash: "11ee")

        let reconciled = try await services.reconcileOrphanedKnownItems()
        #expect(reconciled.isEmpty)                                   // nothing orphaned
        #expect(try await services.knownSourceIDs(forJob: job.id).contains("pin-A"))
        #expect(try await jobIngestedCount(services, job.id) == 1)
        #expect(try assetCount(temp) == 1)
        _ = r
    }

    @Test("reconcile repairs an asset removed OUTSIDE deleteAssets, per-job scoped")
    func reconcileAfterExternalRemoval() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        // One job with a LIVE item and an ORPHAN item; a second job fully live.
        let gone = try await services.ingest(
            assetDraft(hash: "9a9a"),
            from: sourceDraft(url: "https://pinterest.com/pin/G", platform: .pinterest),
            into: c.id)
        _ = try await services.ingest(
            assetDraft(hash: "7b7b"),
            from: sourceDraft(url: "https://pinterest.com/pin/L", platform: .pinterest),
            into: c.id)
        let job1 = try await services.createJob(platform: .pinterest, scope: "board:1")
        try await services.recordJobItem(
            jobID: job1.id, sourceID: "pin-G", status: .ingested, blobHash: "9a9a")
        try await services.recordJobItem(
            jobID: job1.id, sourceID: "pin-L", status: .ingested, blobHash: "7b7b")
        let job2 = try await services.createJob(platform: .pinterest, scope: "board:2")
        try await services.recordJobItem(
            jobID: job2.id, sourceID: "pin-L", status: .deduped, blobHash: "7b7b")

        // Remove one asset WITHOUT going through deleteAssets → its blob orphans, but
        // its ledger rows are left stranded (the exact gap the reconcile closes).
        try await temp.database.write { db in
            _ = try Asset
                .filter(Column("blob_hash") == "9a9a")
                .deleteAll(db)
        }

        let reconciled = try await services.reconcileOrphanedKnownItems()
        #expect(reconciled == [job1.id])                              // only job1 lost a row
        #expect(try await services.knownSourceIDs(forJob: job1.id) == ["pin-L"]) // orphan gone
        #expect(try await jobIngestedCount(services, job1.id) == 1)   // recomputed 2 → 1
        #expect(try await services.knownSourceIDs(forJob: job2.id) == ["pin-L"]) // untouched
        #expect(try await jobIngestedCount(services, job2.id) == 1)
        _ = gone
    }

    @Test("reconcile is a no-op when every known item is backed (empty result)")
    func reconcileNoOpWhenClean() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(
            assetDraft(hash: "c0c0"),
            from: sourceDraft(url: "https://pinterest.com/pin/A", platform: .pinterest),
            into: c.id)
        let job = try await services.createJob(platform: .pinterest)
        try await services.recordJobItem(
            jobID: job.id, sourceID: "pin-A", status: .ingested, blobHash: "c0c0")

        #expect(try await services.reconcileOrphanedKnownItems().isEmpty)
        #expect(try await jobIngestedCount(services, job.id) == 1)
        _ = r
    }

    @Test("shared source: a source kept by another asset is NOT garbage-collected")
    func sharedSourceKept() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(assetDraft(hash: "aa11"), from: sourceDraft(), into: c.id)

        // Hand-craft a SECOND asset (distinct bytes) reusing the SAME source —
        // a shape the schema allows (1:N) but the ingest API never produces.
        let sourceKey = r.asset.sourceId
        let sibling = Asset(
            id: UUID(), kind: .image, blobHash: "bb22", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 100,
            downloadState: .downloaded, createdAt: Date(), sourceId: sourceKey)
        try temp.database.write { try sibling.insert($0) }
        #expect(try assetCount(temp) == 2)
        #expect(try sourceCount(temp) == 1)

        // Deleting the first must keep the source (the sibling still needs it).
        _ = try await services.deleteAssets([r.asset.id])
        #expect(try assetCount(temp) == 1)
        #expect(try sourceCount(temp) == 1)  // NOT GC'd — still referenced

        // Deleting the sibling finally frees the source.
        _ = try await services.deleteAssets([sibling.id])
        #expect(try sourceCount(temp) == 0)
    }

    // MARK: Cascade of dependents

    @Test("delete cascades tag links but leaves the tag row for other assets")
    func cascadesTagLinks() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let keep = try await services.ingest(
            assetDraft(hash: "cafe01"), from: sourceDraft(url: "https://a/1"), into: c.id)
        let drop = try await services.ingest(
            assetDraft(hash: "cafe02"), from: sourceDraft(url: "https://a/2"), into: c.id)
        _ = try await services.applyTag("mood", to: keep.asset.id, source: .user)
        _ = try await services.applyTag("mood", to: drop.asset.id, source: .user)
        #expect(try tagCount(temp) == 1)       // one shared tag
        #expect(try assetTagCount(temp) == 2)  // two links

        _ = try await services.deleteAssets([drop.asset.id])
        #expect(try assetTagCount(temp) == 1)  // drop's link CASCADEd
        #expect(try tagCount(temp) == 1)       // tag row survives (keep still uses it)
        let remaining = try await services.tags(for: keep.asset.id)
        #expect(remaining.map(\.name) == ["mood"])
    }

    @Test("deleting a folder's cover asset clears the cover (SET NULL)")
    func clearsCover() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        try await services.setCollectionCover(collectionID: c.id, assetID: r.asset.id)

        _ = try await services.deleteAssets([r.asset.id])
        let reloaded = try await services.getCollection(id: c.id)
        #expect(reloaded.coverAssetID == nil)  // SET NULL, folder itself survives
    }

    // MARK: Idempotency & batches

    @Test("deleteAssets on an unknown id is a no-op returning no orphans")
    func unknownIdNoOp() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let orphans = try await services.deleteAssets([UUID()])
        #expect(orphans.isEmpty)
        #expect(try assetCount(temp) == 0)
    }

    @Test("deleting the same asset twice is safe (second call is a no-op)")
    func doubleDeleteSafe() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)

        let first = try await services.deleteAssets([r.asset.id])
        let second = try await services.deleteAssets([r.asset.id])
        #expect(first.count == 1)
        #expect(second.isEmpty)   // already gone
        #expect(try assetCount(temp) == 0)
    }

    @Test("a batch of distinct assets is deleted in one call, orphans deduped by hash")
    func batchDelete() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(
            assetDraft(hash: "11ab"), from: sourceDraft(url: "https://a/1"), into: c.id)
        let b = try await services.ingest(
            assetDraft(hash: "22cd", mime: "image/jpeg"),
            from: sourceDraft(url: "https://a/2"), into: c.id)

        let orphans = try await services.deleteAssets([a.asset.id, b.asset.id])
        #expect(Set(orphans) == [
            OrphanedBlob(blobHash: "11ab", mimeType: "image/png"),
            OrphanedBlob(blobHash: "22cd", mimeType: "image/jpeg"),
        ])
        #expect(try assetCount(temp) == 0)
        #expect(try sourceCount(temp) == 0)
    }
}
