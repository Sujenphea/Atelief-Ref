// AtelierCore — App Services invariant & failure tests (chunk 5, decision T11)
//
// The correctness-critical suite (004:111-113): provenance, dedup-by-hash (18A),
// many-to-many membership without blob duplication, the delete/cascade policy
// (17A) through the public surface, plus every `AtelierError` on its trigger and
// the GRDB→AtelierError mapping (C7).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: invariants & failures (T11)")
struct ServicesInvariantTests {

    // MARK: Fixtures

    /// A fresh store + services, plus the temp dir to clean up.
    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String = "abc123") -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(url: String? = "https://example.com/a", platform: Platform = .web) -> SourceDraft {
        SourceDraft(platform: platform, originalURL: url, capturedAt: Date())
    }

    private func assetCount(_ temp: TempDatabase) throws -> Int {
        try temp.database.read { try Asset.fetchCount($0) }
    }
    private func sourceCount(_ temp: TempDatabase) throws -> Int {
        try temp.database.read { try Source.fetchCount($0) }
    }
    private func itemCount(_ temp: TempDatabase) throws -> Int {
        try temp.database.read { try CollectionItem.fetchCount($0) }
    }

    // MARK: Happy path

    @Test("ingest creates source + asset + membership in one shot")
    func ingestCreates() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let result = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        #expect(result.wasDeduplicated == false)
        #expect(try assetCount(temp) == 1)
        #expect(try sourceCount(temp) == 1)
        #expect(try itemCount(temp) == 1)
    }

    // MARK: 18A dedup

    @Test("re-ingest of identical bytes + provenance into the same collection is a no-op")
    func dedupIdenticalNoOp() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let first = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        let second = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        #expect(first.wasDeduplicated == false)
        #expect(second.wasDeduplicated == true)
        #expect(second.asset.id == first.asset.id)
        #expect(try assetCount(temp) == 1)   // no duplicate asset
        #expect(try sourceCount(temp) == 1)  // no duplicate source
        #expect(try itemCount(temp) == 1)    // no duplicate membership
    }

    @Test("identical bytes but DIFFERENT provenance → two assets sharing the hash")
    func dedupDistinctProvenance() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://twitter.com/x"), into: c.id)
        let b = try await services.ingest(
            assetDraft(hash: "deadbeef"),
            from: sourceDraft(url: "https://pinterest.com/y"), into: c.id)
        #expect(a.wasDeduplicated == false)
        #expect(b.wasDeduplicated == false)
        #expect(a.asset.id != b.asset.id)
        #expect(try assetCount(temp) == 2)
        // Both assets carry the same content hash (shared blob, distinct provenance).
        let hashes = try temp.database.read { db in
            try String.fetchAll(db, Asset.select(Column("blob_hash")))
        }
        #expect(hashes == ["deadbeef", "deadbeef"])
    }

    @Test("dedup across collections: one asset, a membership in each")
    func dedupAcrossCollections() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")
        _ = try await services.ingest(assetDraft(), from: sourceDraft(), into: a.id)
        let second = try await services.ingest(assetDraft(), from: sourceDraft(), into: b.id)
        #expect(second.wasDeduplicated == true)
        #expect(try assetCount(temp) == 1)   // shared asset
        #expect(try itemCount(temp) == 2)    // one membership per collection
    }

    @Test("local_paste with no URL dedups by platform")
    func dedupLocalByPlatform() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let s = SourceDraft(platform: .localPaste, originalURL: nil, capturedAt: Date())
        _ = try await services.ingest(assetDraft(hash: "ff00"), from: s, into: c.id)
        let again = try await services.ingest(assetDraft(hash: "ff00"), from: s, into: c.id)
        #expect(again.wasDeduplicated == true)
        #expect(try assetCount(temp) == 1)
    }

    // MARK: Many-to-many

    @Test("one asset in two collections → 2 memberships, 1 asset row")
    func manyToMany() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let b = try await services.createCollection(name: "B")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: a.id)
        try await services.addAssets([r.asset.id], to: b.id)
        #expect(try assetCount(temp) == 1)
        #expect(try itemCount(temp) == 2)
    }

    @Test("addAssets is idempotent per asset")
    func addAssetsIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "A")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: a.id)
        try await services.addAssets([r.asset.id], to: a.id) // already a member
        #expect(try itemCount(temp) == 1)
    }

    // MARK: Cascade (17A) through the public surface

    @Test("deleteCollection cascades its memberships; asset + source survive")
    func deleteCascades() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        try await services.deleteCollection(id: c.id)
        #expect(try itemCount(temp) == 0)   // memberships gone (CASCADE)
        #expect(try assetCount(temp) == 1)  // asset survives
        #expect(try sourceCount(temp) == 1) // source survives
    }

    // MARK: Failure paths — every AtelierError on its trigger

    @Test("ingest into a missing collection throws notFound")
    func ingestMissingCollection() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.ingest(assetDraft(), from: sourceDraft(), into: ghost)
        }
    }

    @Test("rename / cover / placement / delete on missing rows throw notFound")
    func notFoundPaths() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.renameCollection(id: ghost, to: "x")
        }
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.deleteCollection(id: ghost)
        }
        let c = try await services.createCollection(name: "C")
        await #expect(throws: AtelierError.notFound(entity: "collection_item", id: ghost)) {
            try await services.setCanvasPlacement(
                collectionID: c.id, assetID: ghost, x: 0, y: 0, w: 1, h: 1, z: 0)
        }
    }

    @Test("setGridOrder with a non-member rolls back the whole batch")
    func gridOrderRollback() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        // The single ingest appended it at slot 0 — capture that so the assertion
        // tracks the atomicity invariant (rollback leaves the order UNCHANGED),
        // not a hardcoded pre-insert value.
        func storedOrder() throws -> Int? {
            try temp.database.read { db -> Int? in
                try CollectionItem
                    .filter(Column("asset_id") == r.asset.id.uuidString.lowercased())
                    .fetchOne(db)?.manualOrder
            }
        }
        let before = try storedOrder()
        #expect(before == 0)

        let ghost = UUID()
        await #expect(throws: AtelierError.notFound(entity: "collection_item", id: ghost)) {
            try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: [r.asset.id, ghost])
        }
        // The member's order must be untouched by the rolled-back batch.
        #expect(try storedOrder() == before)
    }

    @Test("createCollection rejects an empty name with invalidName")
    func createInvalidName() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        await #expect(throws: AtelierError.invalidName) {
            try await services.createCollection(name: "   ")
        }
    }

    @Test("ingest surfaces validation errors (bad dims / hash / url)")
    func ingestValidation() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        var bad = assetDraft()
        bad.width = 0
        await #expect(throws: AtelierError.invalidDimensions) {
            try await services.ingest(bad, from: sourceDraft(), into: c.id)
        }
        await #expect(throws: AtelierError.invalidBlobHash) {
            try await services.ingest(assetDraft(hash: "nothex!"), from: sourceDraft(), into: c.id)
        }
        await #expect(throws: AtelierError.missingOriginalURL(platform: .web)) {
            try await services.ingest(assetDraft(), from: sourceDraft(url: nil), into: c.id)
        }
    }

    // MARK: GRDB → AtelierError mapping (C7) — GRDB never leaks

    @Test("error mapping: AtelierError passes through; GRDB constraint → constraintViolation; other → persistenceFailure")
    func errorMapping() {
        #expect(AtelierError(mapping: AtelierError.invalidName) == .invalidName)
        let fk = DatabaseError(resultCode: .SQLITE_CONSTRAINT_FOREIGNKEY)
        #expect(AtelierError(mapping: fk) == .constraintViolation)
        struct Other: Error {}
        let mapped = AtelierError(mapping: Other())
        guard case .persistenceFailure(let detail) = mapped else {
            Issue.record("expected persistenceFailure, got \(mapped)")
            return
        }
        #expect(detail?.contains("Other") == true)
    }

    @Test("GRDB non-constraint errors carry SQLite detail in persistenceFailure (G10)")
    func persistenceFailureCarriesDetail() {
        let err = DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")
        let mapped = AtelierError(mapping: err)
        guard case .persistenceFailure(let detail) = mapped else {
            Issue.record("expected persistenceFailure, got \(mapped)")
            return
        }
        #expect(detail?.contains("FULL") == true || detail?.contains("disk is full") == true)
    }
}
