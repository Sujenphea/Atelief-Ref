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

    @Test("setGridOrder IGNORES a non-member and orders the rest (14A)")
    func gridOrderIgnoresNonMembers() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        func storedOrder() throws -> Int? {
            try temp.database.read { db -> Int? in
                try CollectionItem
                    .filter(Column("asset_id") == r.asset.id.uuidString.lowercased())
                    .fetchOne(db)?.manualOrder
            }
        }
        #expect(try storedOrder() == 0)

        // This THREW `.notFound(entity: "collection_item")` and rolled the whole
        // batch back until 14A. It no longer does: an id that is not a member has
        // no position to be given, and every caller was pre-reading the membership
        // set to strip exactly these before calling — a full collection read in
        // front of every drag, computing what the statement now does for free.
        let ghost = UUID()
        try await services.setGridOrder(
            collectionID: c.id, orderedAssetIDs: [ghost, r.asset.id])
        // The member took its INDEX in the list, not a compacted position: the
        // ghost's slot 0 is left as a gap, because only the relative order is
        // meaningful and closing gaps would move rows the caller never mentioned.
        #expect(try storedOrder() == 1)
    }

    @Test("setGridOrder still throws notFound for a collection that does not exist")
    func gridOrderMissingCollection() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        let r = try await services.ingest(assetDraft(), from: sourceDraft(), into: c.id)
        let ghostCollection = UUID()
        // Naming a folder that isn't there is a different mistake from naming an
        // item that left one, and it is still reported.
        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghostCollection)) {
            try await services.setGridOrder(
                collectionID: ghostCollection, orderedAssetIDs: [r.asset.id])
        }
    }

    @Test("setGridOrder with an empty list is a no-op, even for a missing collection")
    func gridOrderEmptyList() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        // No ids means nothing to order, so there is nothing to look up and
        // nothing to complain about — the shape a caller reaches when its own
        // filter emptied the list.
        try await services.setGridOrder(collectionID: UUID(), orderedAssetIDs: [])
    }

    @Test("setGridOrder leaves unlisted members' order untouched")
    func gridOrderLeavesUnlistedAlone() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        // Distinct hashes AND urls — 18A dedup would otherwise fold these into
        // one asset with one membership, and the assertions would be about that.
        let a = try await services.ingest(
            assetDraft(hash: "aaa1"), from: sourceDraft(url: "https://e/a"), into: c.id).asset.id
        let b = try await services.ingest(
            assetDraft(hash: "bbb2"), from: sourceDraft(url: "https://e/b"), into: c.id).asset.id
        let unlisted = try await services.ingest(
            assetDraft(hash: "ccc3"), from: sourceDraft(url: "https://e/c"), into: c.id).asset.id
        func storedOrder(_ id: UUID) throws -> Int? {
            try temp.database.read { db -> Int? in
                try CollectionItem
                    .filter(Column("asset_id") == id.uuidString.lowercased())
                    .fetchOne(db)?.manualOrder
            }
        }
        #expect(try storedOrder(unlisted) == 2)

        // The `CASE` has no arm for `unlisted`, so without the `IN (…)` guard the
        // UPDATE would match its row and write the CASE's implicit NULL — silently
        // dropping it to the front of the grid. This is that guard's test.
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: [b, a])
        #expect(try storedOrder(b) == 0)
        #expect(try storedOrder(a) == 1)
        #expect(try storedOrder(unlisted) == 2)
    }

    @Test("setGridOrder takes a duplicated id's LAST position")
    func gridOrderDuplicateIDs() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        let a = try await services.ingest(
            assetDraft(hash: "aaa1"), from: sourceDraft(url: "https://e/a"), into: c.id).asset.id
        let b = try await services.ingest(
            assetDraft(hash: "bbb2"), from: sourceDraft(url: "https://e/b"), into: c.id).asset.id
        // What the per-row loop did (each assignment overwrote the previous), kept
        // deliberately: `ImportReplay` dedups before calling and documents this
        // exact rule as the reason.
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: [a, b, a])
        func storedOrder(_ id: UUID) throws -> Int? {
            try temp.database.read { db -> Int? in
                try CollectionItem
                    .filter(Column("asset_id") == id.uuidString.lowercased())
                    .fetchOne(db)?.manualOrder
            }
        }
        #expect(try storedOrder(a) == 2)
        #expect(try storedOrder(b) == 1)
    }

    @Test("setGridOrder spans more than one chunk correctly")
    func gridOrderAcrossChunks() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "C")
        // One more than the chunk size, so the reorder is split across two
        // statements. The chunk exists because SQLite caps how many variables one
        // statement may bind (`SQLITE_MAX_VARIABLE_NUMBER`) and each id spends
        // three of them — `WHEN ? THEN ?` plus its slot in the `IN (…)` list — so
        // an unbounded grid would eventually produce a statement the engine
        // refuses to prepare. The seam between chunks is what this asserts.
        let count = AppServices.gridOrderChunkSize + 1
        var ids: [UUID] = []
        for i in 0..<count {
            ids.append(try await services.ingest(
                assetDraft(hash: String(format: "%040x", i)),
                from: sourceDraft(url: "https://e/\(i)"), into: c.id).asset.id)
        }
        let reversed = Array(ids.reversed())
        try await services.setGridOrder(collectionID: c.id, orderedAssetIDs: reversed)

        let items = try await services.collectionItems(in: c.id, includeArchived: false)
        #expect(items.map(\.asset.id) == reversed)
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
