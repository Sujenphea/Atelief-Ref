// AtelierCore — moveAssets + collectionStackPreviews tests (009 · N1)
//
// The atomic triage verb and the Unsorted stack-row read, through the public
// surface. House style mirrors `ServicesDeleteTests`: temp DB fixture, unique
// (hash, url) per ingest so 18A dedup never collapses fixtures, async
// `#expect(throws:)` for the rollback paths.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

/// A valid (lowercase-hex, C8) blob hash derived deterministically from a
/// readable tag, so fixtures stay dedup-proof AND assertable by name.
private func hexHash(_ tag: String) -> String {
    tag.utf8.map { String(format: "%02x", $0) }.joined()
}

@Suite("Services: moveAssets (009 · N1)")
struct ServicesMoveTests {

    // MARK: Fixtures

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(url: String) -> SourceDraft {
        SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
    }

    /// Ingest a fresh, dedup-proof asset into `collectionID`; returns its id.
    /// The blob hash must be lowercase hex (C8), so the tag is hex-encoded.
    private func seedAsset(
        _ services: AppServices, into collectionID: UUID, tag: String
    ) async throws -> UUID {
        let result = try await services.ingest(
            assetDraft(hash: hexHash(tag)),
            from: sourceDraft(url: "https://example.com/\(tag)"),
            into: collectionID)
        return result.asset.id
    }

    private func memberAssetIDs(
        _ services: AppServices, of collectionID: UUID
    ) async throws -> Set<UUID> {
        Set(try await services.collectionItems(in: collectionID).map { $0.asset.id })
    }

    // MARK: Basic move

    @Test("move drops the source membership and adds the target membership")
    func basicMove() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")

        try await services.moveAssets([a], from: src.id, to: dst.id)

        #expect(try await memberAssetIDs(services, of: src.id) == [])
        #expect(try await memberAssetIDs(services, of: dst.id) == [a])
    }

    @Test("from == to is a no-op (membership untouched)")
    func moveOntoSelf() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let a = try await seedAsset(services, into: src.id, tag: "a")

        try await services.moveAssets([a], from: src.id, to: src.id)

        #expect(try await memberAssetIDs(services, of: src.id) == [a])
    }

    @Test("an empty batch is a no-op")
    func emptyBatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")

        try await services.moveAssets([], from: src.id, to: dst.id)

        #expect(try await memberAssetIDs(services, of: src.id) == [a])
        #expect(try await memberAssetIDs(services, of: dst.id) == [])
    }

    // MARK: Atomicity (rollback)

    @Test("a missing target collection throws notFound; nothing moves")
    func missingTargetRollsBack() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let a = try await seedAsset(services, into: src.id, tag: "a")
        let ghost = UUID()

        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.moveAssets([a], from: src.id, to: ghost)
        }
        #expect(try await memberAssetIDs(services, of: src.id) == [a])
    }

    @Test("a missing source collection throws notFound; the target gains nothing")
    func missingSourceRollsBack() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: dst.id, tag: "seed")
        _ = a
        let b = try await seedAsset(services, into: Collection.unsortedID, tag: "b")
        let ghost = UUID()

        await #expect(throws: AtelierError.notFound(entity: "collection", id: ghost)) {
            try await services.moveAssets([b], from: ghost, to: dst.id)
        }
        #expect(try await memberAssetIDs(services, of: dst.id).contains(b) == false)
    }

    @Test("one missing asset rolls back the WHOLE batch (first asset unmoved)")
    func missingAssetRollsBackBatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")
        let ghost = UUID()

        await #expect(throws: AtelierError.notFound(entity: "asset", id: ghost)) {
            try await services.moveAssets([a, ghost], from: src.id, to: dst.id)
        }
        #expect(try await memberAssetIDs(services, of: src.id) == [a])
        #expect(try await memberAssetIDs(services, of: dst.id) == [])
    }

    // MARK: Dedup + idempotence semantics (9A)

    @Test("already a member of the target: loses the source membership only, no duplicate")
    func dedupIntoTarget() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")
        try await services.addAssets([a], to: dst.id)

        try await services.moveAssets([a], from: src.id, to: dst.id)

        #expect(try await memberAssetIDs(services, of: src.id) == [])
        let dstItems = try await services.collectionItems(in: dst.id)
        #expect(dstItems.map { $0.asset.id } == [a])
    }

    @Test("not a member of the source: still lands in the target (idempotent-add, 9A)")
    func notInSourceStillAdds() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        // `a` lives in Unsorted, NOT in src — a stale drag payload.
        let a = try await seedAsset(services, into: Collection.unsortedID, tag: "a")

        try await services.moveAssets([a], from: src.id, to: dst.id)

        #expect(try await memberAssetIDs(services, of: dst.id) == [a])
        // The Unsorted membership goes with it: the asset is filed in `dst` now,
        // and "filed ⇒ not unsorted" (F3) holds however the membership was gained.
        #expect(!(try await memberAssetIDs(services, of: Collection.unsortedID).contains(a)))
    }

    @Test("duplicate ids in one batch land a single target membership")
    func duplicateIDsInBatch() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")

        try await services.moveAssets([a, a, a], from: src.id, to: dst.id)

        let dstItems = try await services.collectionItems(in: dst.id)
        #expect(dstItems.map { $0.asset.id } == [a])
        #expect(try await memberAssetIDs(services, of: src.id) == [])
    }

    // MARK: Reachable targets

    @Test("a subfolder is a valid move target (Move-to menu path)")
    func moveIntoSubfolder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let root = try await services.createCollection(name: "Root")
        let sub = try await services.createCollection(name: "Sub", parent: root.id)
        let a = try await seedAsset(services, into: root.id, tag: "a")

        try await services.moveAssets([a], from: root.id, to: sub.id)

        #expect(try await memberAssetIDs(services, of: root.id) == [])
        #expect(try await memberAssetIDs(services, of: sub.id) == [a])
    }

    @Test("Unsorted round-trip: triage out, un-triage back")
    func unsortedRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: Collection.unsortedID, tag: "a")

        try await services.moveAssets([a], from: Collection.unsortedID, to: dst.id)
        #expect(try await memberAssetIDs(services, of: Collection.unsortedID) == [])
        #expect(try await memberAssetIDs(services, of: dst.id) == [a])

        try await services.moveAssets([a], from: dst.id, to: Collection.unsortedID)
        #expect(try await memberAssetIDs(services, of: Collection.unsortedID) == [a])
        #expect(try await memberAssetIDs(services, of: dst.id) == [])
    }

    // MARK: Cover invariance

    @Test("moving the cover asset away keeps the cover (membership ≠ cover)")
    func coverSurvivesMove() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let a = try await seedAsset(services, into: src.id, tag: "a")
        try await services.setCollectionCover(collectionID: src.id, assetID: a)

        try await services.moveAssets([a], from: src.id, to: dst.id)

        let refreshed = try await services.getCollection(id: src.id)
        #expect(refreshed.coverAssetID == a)
    }

    // MARK: Manual-order append (17A)

    @Test("moved items land at the END of an arranged target, in batch order")
    func appendsToArrangedTarget() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let x = try await seedAsset(services, into: dst.id, tag: "x")
        let y = try await seedAsset(services, into: dst.id, tag: "y")
        try await services.setGridOrder(collectionID: dst.id, orderedAssetIDs: [x, y])
        let a = try await seedAsset(services, into: src.id, tag: "a")
        let b = try await seedAsset(services, into: src.id, tag: "b")

        try await services.moveAssets([a, b], from: src.id, to: dst.id)

        let order = try await services.collectionItems(in: dst.id, sort: .manual)
            .map { $0.asset.id }
        #expect(order == [x, y, a, b])
    }

    @Test("moved items land AFTER a never-arranged target's items (NULLs sort first)")
    func appendsToUnarrangedTarget() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let src = try await services.createCollection(name: "Src")
        let dst = try await services.createCollection(name: "Dst")
        let existing = try await seedAsset(services, into: dst.id, tag: "e")
        let a = try await seedAsset(services, into: src.id, tag: "a")

        try await services.moveAssets([a], from: src.id, to: dst.id)

        let order = try await services.collectionItems(in: dst.id, sort: .manual)
            .map { $0.asset.id }
        #expect(order == [existing, a])
    }
}

@Suite("Services: collectionStackPreviews (009 · N1)")
struct ServicesStackPreviewTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String) -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(url: String) -> SourceDraft {
        SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
    }

    /// Seed one image asset with a controlled `added_at` so recency ordering is
    /// deterministic under test (ingest stamps "now", which can tie).
    private func seedAsset(
        _ services: AppServices, _ temp: TempDatabase,
        into collectionID: UUID, tag: String, addedAt: Date
    ) async throws -> String {
        let hash = hexHash(tag)
        _ = try await services.ingest(
            assetDraft(hash: hash),
            from: sourceDraft(url: "https://example.com/\(tag)"),
            into: collectionID)
        try temp.database.write { db in
            try db.execute(sql: """
                UPDATE collection_item SET added_at = ?
                WHERE asset_id IN (SELECT id FROM asset WHERE blob_hash = ?)
                """, arguments: [addedAt, hash])
        }
        return hash
    }

    @Test("0 / 1 / 3 / 5-item collections fan 0 / 1 / 3 / 3 hashes, newest first")
    func fanCountsAndRecency() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let empty = try await services.createCollection(name: "A-Empty")
        let one = try await services.createCollection(name: "B-One")
        let three = try await services.createCollection(name: "C-Three")
        let five = try await services.createCollection(name: "D-Five")

        let base = Date(timeIntervalSince1970: 1_000_000)
        _ = try await seedAsset(services, temp, into: one.id, tag: "one-0", addedAt: base)
        for i in 0..<3 {
            _ = try await seedAsset(
                services, temp, into: three.id, tag: "three-\(i)",
                addedAt: base.addingTimeInterval(Double(i)))
        }
        for i in 0..<5 {
            _ = try await seedAsset(
                services, temp, into: five.id, tag: "five-\(i)",
                addedAt: base.addingTimeInterval(Double(i)))
        }

        let previews = try await services.collectionStackPreviews(limit: 3)
        let byID = Dictionary(uniqueKeysWithValues: previews.map { ($0.collection.id, $0) })

        #expect(byID[empty.id]?.itemCount == 0)
        #expect(byID[empty.id]?.recentBlobHashes == [])
        #expect(byID[one.id]?.itemCount == 1)
        #expect(byID[one.id]?.recentBlobHashes == [hexHash("one-0")])
        #expect(byID[three.id]?.itemCount == 3)
        #expect(byID[three.id]?.recentBlobHashes == [
            hexHash("three-2"), hexHash("three-1"), hexHash("three-0"),
        ])
        #expect(byID[five.id]?.itemCount == 5)
        #expect(byID[five.id]?.recentBlobHashes == [
            hexHash("five-4"), hexHash("five-3"), hexHash("five-2"),
        ])
    }

    @Test("roots only: subfolders and Unsorted are excluded; order is name,id")
    func rootOnlyFilterAndOrder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let b = try await services.createCollection(name: "Beta")
        let a = try await services.createCollection(name: "Alpha")
        _ = try await services.createCollection(name: "Child", parent: b.id)

        let previews = try await services.collectionStackPreviews()

        #expect(previews.map { $0.collection.id } == [a.id, b.id])
        #expect(!previews.contains { $0.collection.id == Collection.unsortedID })
    }

    @Test("includeUnsorted: the Unsorted root gets its own card")
    func includeUnsortedRoot() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let a = try await services.createCollection(name: "Alpha")

        let previews = try await services.collectionStackPreviews(includeUnsorted: true)
        let ids = previews.map { $0.collection.id }

        #expect(ids.contains(Collection.unsortedID))
        #expect(ids.contains(a.id))
    }

    @Test("a media-less item is counted but fans no thumbnail")
    func mediaLessCountedNotFanned() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Palette")
        _ = try await services.ingestContent(
            .color(hex: "#FF0000"),
            from: SourceDraft(platform: .localPaste, originalURL: nil, capturedAt: Date()),
            into: c.id)
        _ = try await seedAsset(
            services, temp, into: c.id, tag: "img",
            addedAt: Date(timeIntervalSince1970: 1_000_000))

        let previews = try await services.collectionStackPreviews()
        let card = previews.first { $0.collection.id == c.id }

        #expect(card?.itemCount == 2)
        #expect(card?.recentBlobHashes == [hexHash("img")])
    }

    @Test("a deleted asset leaves a hole the fan skips over")
    func deletedAssetHole() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Holes")
        let base = Date(timeIntervalSince1970: 1_000_000)
        var assetIDs: [UUID] = []
        for i in 0..<4 {
            _ = try await seedAsset(
                services, temp, into: c.id, tag: "h-\(i)",
                addedAt: base.addingTimeInterval(Double(i)))
        }
        assetIDs = try await services.collectionItems(in: c.id)
            .sorted { $0.item.addedAt > $1.item.addedAt }
            .map { $0.asset.id }
        // Delete the second-newest — the fan should skip to the third.
        _ = try await services.deleteAssets([assetIDs[1]])

        let previews = try await services.collectionStackPreviews(limit: 3)
        let card = previews.first { $0.collection.id == c.id }

        #expect(card?.itemCount == 3)
        #expect(card?.recentBlobHashes == [hexHash("h-3"), hexHash("h-1"), hexHash("h-0")])
    }

    /// The pairing guard. `itemCount` and `recentBlobHashes` come from two
    /// separate queries that must agree about which rows exist; when they drift,
    /// a card reads "12 items" and shows 9. With every item byte-backed and
    /// fewer than `limit` of them, the two numbers are the SAME number, so a
    /// predicate applied to one query and not the other fails here.
    @Test("count and fan agree when every item is byte-backed and under the limit")
    func countAgreesWithFan() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Paired")
        let base = Date(timeIntervalSince1970: 1_000_000)
        for i in 0..<3 {
            _ = try await seedAsset(
                services, temp, into: c.id, tag: "p-\(i)",
                addedAt: base.addingTimeInterval(Double(i)))
        }

        let card = try await services.collectionStackPreviews(limit: 5)
            .first { $0.collection.id == c.id }

        #expect(card?.itemCount == 3)
        #expect(card?.recentBlobHashes.count == card?.itemCount)
    }

    /// The count query is scoped to the roots being rendered, so a subfolder's
    /// items must not be attributed to the parent — the count is DIRECT items.
    @Test("a subfolder's items stay out of its root's count and fan")
    func subfolderItemsDoNotLeakUp() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let root = try await services.createCollection(name: "Root")
        let child = try await services.createCollection(name: "Child", parent: root.id)
        let base = Date(timeIntervalSince1970: 1_000_000)
        _ = try await seedAsset(services, temp, into: root.id, tag: "mine", addedAt: base)
        for i in 0..<2 {
            _ = try await seedAsset(
                services, temp, into: child.id, tag: "theirs-\(i)",
                addedAt: base.addingTimeInterval(Double(i + 1)))
        }

        let previews = try await services.collectionStackPreviews()
        let card = previews.first { $0.collection.id == root.id }

        #expect(!previews.contains { $0.collection.id == child.id })
        #expect(card?.itemCount == 1)
        #expect(card?.recentBlobHashes == [hexHash("mine")])
    }

    @Test("no root collections besides Unsorted → empty result")
    func emptyLibrary() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let previews = try await services.collectionStackPreviews()
        #expect(previews.isEmpty)
    }
}
