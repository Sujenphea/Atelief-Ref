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
