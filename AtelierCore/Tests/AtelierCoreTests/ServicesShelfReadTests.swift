// AtelierCore — the archive predicate at every read funnel (023 · A)
//
// `ServicesShelfTests` covers the WRITE verbs. This file covers the other half,
// which fails for a different reason: a read that MISAPPLIES the predicate.
// Every browsing surface gets its own case — hiding an item from the grid and
// leaving it in search is not "mostly working", it is the bug the shelf exists
// to not have.
//
// The cover / stack-preview cases are why A0 extracted those queries first: the
// predicate is written once per side and asserted twice, on both the collection
// and the space, because a pair that disagrees is how a card comes to read
// "12 items" while fanning 9.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Services: the archive predicate at the read funnels (023 · A)")
struct ServicesShelfReadTests {

    private func makeServices() throws -> (services: AppServices, temp: TempDatabase) {
        let temp = try makeTempDatabase()
        return (AppServices(database: temp.database), temp)
    }

    /// One asset with a controllable `title`, which lands in `source_fts` so the
    /// search cases have real free text to match on.
    @discardableResult
    private func seedAsset(
        _ services: AppServices, into collectionID: UUID, title: String? = nil
    ) async throws -> UUID {
        let unique = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let draft = AssetDraft(
            kind: .image, blobHash: unique, mimeType: "image/png",
            width: 100, height: 100, duration: nil, fileSize: 10,
            downloadState: .downloaded)
        let source = SourceDraft(
            platform: .web, originalURL: "https://e/\(unique)", title: title,
            capturedAt: Date())
        return try await services.ingest(draft, from: source, into: collectionID).asset.id
    }

    // MARK: - The grid

    @Test("collectionItems hides an archived member and restores it on unarchive")
    func gridHidesArchived() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id)
        let visible = try await seedAsset(services, into: refs.id)

        try await services.archive([shelved])
        let browsing = try await services.collectionItems(
            in: refs.id, includeArchived: false).map(\.asset.id)
        #expect(browsing == [visible])

        try await services.unarchive([shelved])
        let restored = try await services.collectionItems(
            in: refs.id, includeArchived: false).map(\.asset.id)
        #expect(Set(restored) == [shelved, visible])
    }

    // MARK: - Search

    @Test("searchAssets drops an archived hit, free text and unfiltered alike")
    func searchHidesArchived() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id, title: "brutalist tower")
        let visible = try await seedAsset(services, into: refs.id, title: "brutalist slab")

        try await services.archive([shelved])
        let hits = try await services.searchAssets(text: "brutalist").map(\.asset.id)
        #expect(hits == [visible])
        // …and with no text at all, which is a different query shape.
        let all = try await services.searchAssets().map(\.asset.id)
        #expect(all == [visible])

        try await services.unarchive([shelved])
        let back = try await services.searchAssets(text: "brutalist").map(\.asset.id)
        #expect(Set(back) == [shelved, visible])
    }

    /// A conjunct that is only ever exercised ALONE can be broken and still
    /// pass — the same reasoning `ServicesFavoritesTests` applies to the star.
    @Test("the predicate composes with a collection scope, a tag filter and the star")
    func predicateComposesWithOtherConjuncts() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id, title: "concrete")
        let visible = try await seedAsset(services, into: refs.id, title: "concrete")
        for id in [shelved, visible] {
            _ = try await services.applyTag("brut", to: id, source: .user)
            try await services.setFavorite(true, for: id)
        }
        let tag = try #require(try await services.allTags().first { $0.name == "brut" })
        try await services.archive([shelved])

        let hits = try await services.searchAssets(
            text: "concrete", tagIDs: [tag.id], collectionIDs: [refs.id],
            favoritesOnly: true).map(\.asset.id)
        #expect(hits == [visible])
    }

    /// The reason the predicate is a WHERE conjunct and never a post-filter: a
    /// post-filter over already-selected rows silently SHORTENS the page. Ask
    /// for 3 from a library where half the matches are archived and 3 must come
    /// back — not 1, and not 2.
    @Test("a page stays full: the predicate filters before the limit, not after")
    func pageIsNotShortened() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        var archived: [UUID] = []
        // Alternate archived / visible so any post-filter would eat into the
        // first page rather than trimming a tail.
        for index in 0..<12 {
            let id = try await seedAsset(services, into: refs.id, title: "paged")
            if index.isMultiple(of: 2) { archived.append(id) }
        }
        try await services.archive(archived)

        let page = try await services.searchAssets(text: "paged", limit: 3)
        #expect(page.count == 3)
        #expect(page.allSatisfy { $0.asset.archivedAt == nil })

        // …and paging through with the keyset cursor still sees every visible
        // row exactly once, with no gaps where the archived rows were.
        var seen: [UUID] = []
        var cursor: AssetPageCursor? = nil
        while true {
            let next = try await services.searchAssets(text: "paged", limit: 3, after: cursor)
            guard let last = next.last else { break }
            seen.append(contentsOf: next.map(\.asset.id))
            cursor = AssetPageCursor(createdAt: last.asset.createdAt, id: last.asset.id)
        }
        #expect(seen.count == 6)
        #expect(Set(seen).count == 6)
        #expect(seen.allSatisfy { !archived.contains($0) })
    }

    @Test("semanticSearchAssets excludes archived candidates before ranking")
    func semanticHidesArchived() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        // The archived asset is the PERFECT match; the visible one is orthogonal.
        // If the predicate were missing, the shelf item would rank first.
        let shelved = try await seedAsset(services, into: refs.id)
        let visible = try await seedAsset(services, into: refs.id)
        try await services.upsertEmbedding(
            assetID: shelved, modelVersion: 1, contentHash: "h", vector: [1, 0, 0])
        try await services.upsertEmbedding(
            assetID: visible, modelVersion: 1, contentHash: "h", vector: [0, 1, 0])
        try await services.archive([shelved])

        let hits = try await services.semanticSearchAssets(
            queryVector: [1, 0, 0], modelVersion: 1).map(\.asset.id)
        #expect(hits == [visible])
    }

    // MARK: - Gallery cards

    @Test("an archived cover falls out of collectionCovers and spaceCovers")
    func archivedCoverFallsBack() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let board = try await services.createSpace(name: "Board")
        let cover = try await seedAsset(services, into: refs.id)
        try await services.setCollectionCover(collectionID: refs.id, assetID: cover)
        try await services.setSpaceCover(spaceID: board.id, assetID: cover)

        // The fixture is real: both surfaces resolve the cover before archiving.
        #expect(try await services.collectionCovers([refs.id])[refs.id] != nil)
        #expect(try await services.spaceCovers([board.id])[board.id] != nil)

        try await services.archive([cover])

        // Absent from the map, exactly as a DELETED cover would be — which is
        // what makes the gallery fall back to its most-recent visible member
        // rather than rendering a picture of a hidden item.
        #expect(try await services.collectionCovers([refs.id])[refs.id] == nil)
        #expect(try await services.spaceCovers([board.id])[board.id] == nil)

        try await services.unarchive([cover])
        #expect(try await services.collectionCovers([refs.id])[refs.id] != nil)
        #expect(try await services.spaceCovers([board.id])[board.id] != nil)
    }

    /// Both halves of the card, on both sides of the pair. The count and the fan
    /// come from two queries, and a predicate applied to one and not the other
    /// is the "12 items, shows 9" bug.
    @Test("collectionStackPreviews drops an archived item from the count AND the fan")
    func collectionCardDropsArchived() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id)
        _ = try await seedAsset(services, into: refs.id)
        _ = try await seedAsset(services, into: refs.id)

        let before = try #require(
            try await services.collectionStackPreviews(limit: 5)
                .first { $0.collection.id == refs.id })
        #expect(before.itemCount == 3)
        #expect(before.recentBlobHashes.count == 3)

        try await services.archive([shelved])

        let after = try #require(
            try await services.collectionStackPreviews(limit: 5)
                .first { $0.collection.id == refs.id })
        #expect(after.itemCount == 2)
        #expect(after.recentBlobHashes.count == 2)
        #expect(after.recentBlobHashes.count == after.itemCount)
    }

    @Test("spaceStackPreviews drops an archived tile but still counts element rows")
    func spaceCardDropsArchivedKeepsElements() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let board = try await services.createSpace(name: "Board")
        let shelved = try await seedAsset(services, into: refs.id)
        let visible = try await seedAsset(services, into: refs.id)
        _ = try await services.addAssetToSpace(
            assetID: shelved, to: board.id, x: 0, y: 0, w: 10, h: 10, z: 0)
        _ = try await services.addAssetToSpace(
            assetID: visible, to: board.id, x: 20, y: 0, w: 10, h: 10, z: 1)
        _ = try await services.addElement(
            to: board.id, kind: .text,
            style: ElementStyle(text: "Note", fontSize: 18, textColor: "#000000"),
            x: 0, y: 40, w: 100, h: 40, z: 2)

        let before = try #require(
            try await services.spaceStackPreviews(limit: 5).first { $0.space.id == board.id })
        #expect(before.itemCount == 3)                   // 2 assets + 1 element
        #expect(before.recentBlobHashes.count == 2)

        try await services.archive([shelved])

        let after = try #require(
            try await services.spaceStackPreviews(limit: 5).first { $0.space.id == board.id })
        // The element row has a NULL `asset_id` and must survive the join the
        // predicate rides on — an inner join would have eaten it too.
        #expect(after.itemCount == 2)                    // 1 asset + 1 element
        #expect(after.recentBlobHashes.count == 1)
    }

    // MARK: - The shelf itself

    @Test("shelfAssets returns exactly the archived items, most recent first")
    func shelfContents() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let first = try await seedAsset(services, into: refs.id)
        let second = try await seedAsset(services, into: refs.id)
        let never = try await seedAsset(services, into: refs.id)

        #expect(try await services.shelfAssets().isEmpty)

        try await services.archive([first])
        try await services.archive([second])
        // Two `Date()` stamps can land in the same millisecond, so the order is
        // made unambiguous rather than assumed.
        try temp.database.write { db in
            try db.execute(
                sql: "UPDATE asset SET archived_at = ? WHERE id = ?",
                arguments: [
                    Date(timeIntervalSince1970: 1_000), first.uuidString.lowercased(),
                ])
            try db.execute(
                sql: "UPDATE asset SET archived_at = ? WHERE id = ?",
                arguments: [
                    Date(timeIntervalSince1970: 2_000), second.uuidString.lowercased(),
                ])
        }

        let shelf = try await services.shelfAssets()
        #expect(shelf.map(\.asset.id) == [second, first])
        #expect(!shelf.contains { $0.asset.id == never })
        // The joined provenance is present — the shelf reuses the grid host, so
        // it needs the same shape a browse read hands over.
        #expect(shelf.allSatisfy { $0.source.id == $0.asset.sourceId })

        try await services.unarchive([first, second])
        #expect(try await services.shelfAssets().isEmpty)
    }

    // MARK: - What the shelf is holding (016 stats)

    /// The reclaim figure has to be honest in the case that actually recurs: a
    /// blob shared between an archived asset and a visible one frees NOTHING,
    /// and counting it would promise space that unarchiving nothing could
    /// release.
    @Test("archivedUsage counts a shared blob only when every referrer is archived")
    func archivedUsageCountsOnlyExclusiveBytes() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let left = try await services.createCollection(name: "Left")
        let right = try await services.createCollection(name: "Right")

        // One blob, two asset rows (the same picture saved twice from different
        // sources, which is how a shared blob arises).
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        func seedSharing(_ collectionID: UUID, url: String) async throws -> UUID {
            let draft = AssetDraft(
                kind: .image, blobHash: hash, mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 100,
                downloadState: .downloaded)
            let source = SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
            return try await services.ingest(draft, from: source, into: collectionID).asset.id
        }
        let shared1 = try await seedSharing(left.id, url: "https://e/shared-1")
        _ = try await seedSharing(right.id, url: "https://e/shared-2")
        let lone = try await seedAsset(services, into: left.id)

        #expect(try await services.archivedUsage() == .empty)

        // Archive ONE of the two sharers: the count moves, the bytes do not.
        try await services.archive([shared1])
        let partial = try await services.archivedUsage()
        #expect(partial.assetCount == 1)
        #expect(partial.exclusiveBytes == 0)

        // Archive a lone byte-backed asset: its bytes are genuinely reclaimable.
        try await services.archive([lone])
        let withLone = try await services.archivedUsage()
        #expect(withLone.assetCount == 2)
        #expect(withLone.exclusiveBytes == 10)   // the seeded fileSize
    }

    @Test("archivedUsage counts media-less items but adds no bytes for them")
    func archivedUsageHandlesMediaLessItems() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let color = try await services.ingestContent(
            .color(hex: "#123456"),
            from: SourceDraft(platform: .localPaste, capturedAt: Date()),
            into: refs.id).asset.id

        try await services.archive([color])

        let usage = try await services.archivedUsage()
        // A shelf of a thousand swatches is a large count and zero bytes — which
        // is why the pane reports two numbers rather than one.
        #expect(usage.assetCount == 1)
        #expect(usage.exclusiveBytes == 0)
        #expect(usage.isEmpty == false)
    }

    /// The same blob under TWO archived assets is one file, so its bytes are
    /// counted once — not once per referring row.
    @Test("a blob shared by two archived assets is counted once")
    func sharedArchivedBlobCountedOnce() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let hash = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var ids: [UUID] = []
        for i in 0..<2 {
            let draft = AssetDraft(
                kind: .image, blobHash: hash, mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 250,
                downloadState: .downloaded)
            let source = SourceDraft(
                platform: .web, originalURL: "https://e/dup-\(i)", capturedAt: Date())
            ids.append(try await services.ingest(draft, from: source, into: refs.id).asset.id)
        }
        try await services.archive(ids)

        let usage = try await services.archivedUsage()
        #expect(usage.assetCount == 2)
        #expect(usage.exclusiveBytes == 250)     // one file, not two
    }

    // MARK: - The orphan sweep

    /// 023 claimed the sweep "must skip archived assets explicitly, or the shelf
    /// becomes a shelf of missing files". It was WRONG:
    /// `referencedBlobHashes()` selects every `asset` row, so an archived
    /// asset's blob is in the keep set by construction. That makes this a
    /// regression test rather than a code change — it fails only if a future
    /// change teaches the sweep to care about archived state.
    @Test("a blob referenced only by an archived asset stays in the keep set")
    func orphanSweepKeepsArchivedBlobs() async throws {
        let (services, temp) = try makeServices()
        defer { temp.cleanup() }
        let refs = try await services.createCollection(name: "Refs")
        let shelved = try await seedAsset(services, into: refs.id)
        let hash = try #require(
            try temp.database.read {
                try Asset.fetchOne($0, key: shelved.uuidString.lowercased())
            }?.blobHash)

        try await services.archive([shelved])

        #expect(try await services.referencedBlobHashes().contains(hash))
        // …and through the richer accounting the stats pane uses, too.
        #expect(try await services.blobUsage().contains { $0.blobHash == hash })
    }
}
