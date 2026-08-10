// AtelierCore — deleteAssetsRecoverable + restoreDeletedAssets (010 · delete-undo)
//
// The verbatim undelete: a recoverable delete captures the exact graph it removes
// (assets, sources, memberships+order, tag links, covers), and restore reinstates
// it with stable ids. Covers the round-trip MATRIX (multi-collection+order, tags,
// cover, shared source, deduped/unique blob, media-less kinds) and the FAILURE
// suite (collection-gone, dedup-key recreated, idempotency, redo, referenced set).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: delete-undo (backup + restore)")
struct ServicesDeleteUndoTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    private func assetDraft(hash: String, mime: String = "image/png") -> AssetDraft {
        AssetDraft(
            kind: .image, blobHash: hash, mimeType: mime,
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
    }

    private func sourceDraft(_ url: String) -> SourceDraft {
        SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
    }

    private func members(_ services: AppServices, _ c: UUID) async throws -> [UUID] {
        try await services.collectionItems(in: c, sort: .manual, includeArchived: false).map { $0.asset.id }
    }

    private func exists(_ services: AppServices, asset id: UUID) async -> Bool {
        (try? await services.getAsset(id: id)) != nil
    }

    // MARK: - Round-trip matrix

    @Test("single asset: delete captures it, restore brings back asset + source + membership")
    func singleRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "a1"), from: sourceDraft("u1"), into: c.id).asset

        let backup = try await services.deleteAssetsRecoverable([a.id])
        #expect(backup.assets.map(\.id) == [a.id])
        #expect(await exists(services, asset: a.id) == false)

        try await services.restoreDeletedAssets(backup)
        #expect(await exists(services, asset: a.id) == true)
        #expect(try await members(services, c.id) == [a.id])
        // Source came back (it was GC'd by the delete).
        #expect(try await services.getAsset(id: a.id).source.id == a.sourceId)
    }

    @Test("multi-collection membership + manual order restored exactly")
    func multiCollectionOrder() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c1 = try await services.createCollection(name: "A")
        let c2 = try await services.createCollection(name: "B")
        let x = try await services.ingest(assetDraft(hash: "a2"), from: sourceDraft("ux"), into: c1.id).asset
        let y = try await services.ingest(assetDraft(hash: "b2"), from: sourceDraft("uy"), into: c1.id).asset
        try await services.addAssets([x.id, y.id], to: c2.id)
        // Arrange c2 as [y, x] (reverse of insertion) so order restoration is testable.
        try await services.setCollectionSortMode(.manual, for: c2.id)
        try await services.setGridOrder(collectionID: c2.id, orderedAssetIDs: [y.id, x.id])

        let backup = try await services.deleteAssetsRecoverable([x.id, y.id])
        #expect(try await members(services, c1.id) == [])
        #expect(try await members(services, c2.id) == [])

        try await services.restoreDeletedAssets(backup)
        #expect(try await members(services, c1.id) == [x.id, y.id])
        #expect(try await members(services, c2.id) == [y.id, x.id]) // exact order
    }

    @Test("tags restored (link re-created; the tag itself always survived)")
    func tagsRestored() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "c3"), from: sourceDraft("ut"), into: c.id).asset
        _ = try await services.applyTag("brass", to: a.id, source: .user)

        let backup = try await services.deleteAssetsRecoverable([a.id])
        try await services.restoreDeletedAssets(backup)

        #expect(try await services.tags(for: a.id).map(\.name) == ["brass"])
    }

    @Test("collection cover restored when still cover-less")
    func coverRestored() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "cf"), from: sourceDraft("ucv"), into: c.id).asset
        try await services.setCollectionCover(collectionID: c.id, assetID: a.id)

        let backup = try await services.deleteAssetsRecoverable([a.id])
        #expect(try await services.getCollection(id: c.id).coverAssetID == nil) // SET NULL

        try await services.restoreDeletedAssets(backup)
        #expect(try await services.getCollection(id: c.id).coverAssetID == a.id)
    }

    @Test("shared source: deleting one asset keeps the source; restore doesn't double it")
    func sharedSourceNotDoubled() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "d1"), from: sourceDraft("shared"), into: c.id).asset
        // Give `a`'s source a second referencing asset directly — there's no public
        // source-dedup path, so construct the shared-source state that makes the
        // delete's source-GC skip (and restore's insert-if-absent matter).
        var b = a
        b.id = UUID()
        b.blobHash = "d2"
        try temp.database.write { db in try b.insert(db) }
        try await services.addAssets([b.id], to: c.id)

        let backup = try await services.deleteAssetsRecoverable([a.id]) // b keeps the source
        #expect(await exists(services, asset: b.id) == true) // source still referenced
        let sourcesBefore = try temp.database.read { try Source.fetchCount($0) }
        try await services.restoreDeletedAssets(backup)
        let sourcesAfter = try temp.database.read { try Source.fetchCount($0) }
        #expect(sourcesBefore == sourcesAfter) // insert-if-absent → no duplicate source
        #expect(await exists(services, asset: a.id) == true)
    }

    @Test("media-less kind (color) round-trips with no blob")
    func mediaLessRoundTrip() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let color = try await services.ingestContent(
            .color(hex: "#ff0000"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()), into: c.id).asset

        let backup = try await services.deleteAssetsRecoverable([color.id])
        #expect(await exists(services, asset: color.id) == false)
        try await services.restoreDeletedAssets(backup)
        #expect(await exists(services, asset: color.id) == true)
        #expect(try await services.getAsset(id: color.id).asset.content == .color(hex: "#ff0000"))
    }

    // MARK: - Failure suite

    @Test("a collection deleted after capture is skipped; the asset still restores")
    func collectionGoneSkipsMembership() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let keep = try await services.createCollection(name: "Keep")
        let gone = try await services.createCollection(name: "Gone")
        let a = try await services.ingest(assetDraft(hash: "ca"), from: sourceDraft("ucg"), into: keep.id).asset
        try await services.addAssets([a.id], to: gone.id)

        let backup = try await services.deleteAssetsRecoverable([a.id])
        try await services.deleteCollection(id: gone.id) // collection vanishes before undo

        try await services.restoreDeletedAssets(backup) // must not throw
        #expect(await exists(services, asset: a.id) == true)
        #expect(try await members(services, keep.id) == [a.id]) // surviving membership back
    }

    @Test("a dedup key recreated by a live capture is skipped, not duplicated")
    func dedupKeyRecreatedSkips() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        let a = try await services.ingestContent(.color(hex: "#00ff00"), from: source, into: c.id).asset

        let backup = try await services.deleteAssetsRecoverable([a.id])
        // A live capture re-creates the same color (new id, same dedup key).
        let b = try await services.ingestContent(.color(hex: "#00ff00"), from: source, into: c.id).asset
        #expect(b.id != a.id)

        try await services.restoreDeletedAssets(backup) // must not throw / duplicate
        #expect(await exists(services, asset: a.id) == false) // old id NOT resurrected
        let colorAssets = try temp.database.read {
            try Asset.filter(Column("dedup_key") == "#00ff00").fetchCount($0)
        }
        #expect(colorAssets == 1) // exactly the live-captured one
    }

    @Test("restore is idempotent — running it twice yields one set")
    func restoreIdempotent() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "1d"), from: sourceDraft("uid"), into: c.id).asset

        let backup = try await services.deleteAssetsRecoverable([a.id])
        try await services.restoreDeletedAssets(backup)
        try await services.restoreDeletedAssets(backup) // second run is a no-op
        #expect(try await members(services, c.id) == [a.id])
        #expect(try temp.database.read { try CollectionItem.fetchCount($0) } == 1)
    }

    @Test("redo cycle: delete → restore → delete again → restore again")
    func redoCycle() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        let a = try await services.ingest(assetDraft(hash: "ec"), from: sourceDraft("urc"), into: c.id).asset

        let backup = try await services.deleteAssetsRecoverable([a.id])
        try await services.restoreDeletedAssets(backup)
        #expect(await exists(services, asset: a.id) == true)

        _ = try await services.deleteAssets([a.id]) // redo (plain delete, no reap)
        #expect(await exists(services, asset: a.id) == false)
        try await services.restoreDeletedAssets(backup) // undo again from the SAME backup
        #expect(await exists(services, asset: a.id) == true)
        #expect(try await members(services, c.id) == [a.id])
    }

    @Test("referencedBlobHashes returns exactly the live non-null hashes")
    func referencedHashes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let c = try await services.createCollection(name: "Refs")
        _ = try await services.ingest(assetDraft(hash: "deadbeef"), from: sourceDraft("u1"), into: c.id)
        let gone = try await services.ingest(assetDraft(hash: "beefcafe"), from: sourceDraft("u2"), into: c.id).asset
        // A media-less asset contributes NO hash.
        _ = try await services.ingestContent(
            .color(hex: "#123456"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()), into: c.id)

        #expect(try await services.referencedBlobHashes() == ["deadbeef", "beefcafe"])
        _ = try await services.deleteAssets([gone.id])
        #expect(try await services.referencedBlobHashes() == ["deadbeef"])
    }
}
