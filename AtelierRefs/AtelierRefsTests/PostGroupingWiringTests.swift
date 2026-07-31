//
//  PostGroupingWiringTests.swift
//  AtelierRefsTests
//
//  307 · carousel grouping — the WIRING, as opposed to the pure grouping that
//  `PostGroupingTests` covers.
//
//  The pure index was always well tested; the glue around it was not, and the glue
//  is where the damage lives. Two failure modes in particular are invisible without
//  these:
//
//   1. A stale derivation. `displayItems` and the selection store's feed order are
//      rebuilt from one place (`rebuildItemDerivations`). If that stops firing, the
//      grid keeps showing — and RANGE-SELECTING over — a display list that no longer
//      matches `items`.
//   2. An un-widened action. A collapsed tile stands for its whole post, so delete /
//      move / drag must widen through `PostGroups.expand(_:)`. Miss it and "Delete"
//      on a tile reading ⧉4 removes one image and leaves the tile behind reading 3.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Carousel grouping: model wiring")
struct PostGroupingWiringTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "post-grouping-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Seed `count` colour assets that all claim `url` as their permalink — the shape
    /// a real carousel arrives in, where every member gets its OWN `Source` row and
    /// only the URL ties them together.
    @discardableResult
    private func seedPost(
        url: String?, count: Int, into collectionID: UUID, _ services: AppServices,
        hexSeed: Int
    ) async throws -> [UUID] {
        // The platform follows the URL, because the ingest funnel enforces exactly
        // that: a `.instagram` source with no `originalURL` is rejected outright
        // (`.missingOriginalURL`). A URL-less capture really is a local paste, which
        // is also the case that must never group.
        let source = SourceDraft(
            platform: url == nil ? .localPaste : .instagram,
            originalURL: url, capturedAt: Date())
        var ids: [UUID] = []
        for offset in 0..<count {
            let i = hexSeed + offset
            let hex = String(
                format: "#%02x%02x%02x",
                (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            let result = try await services.ingestContent(
                .color(hex: hex), from: source, into: collectionID)
            ids.append(result.asset.id)
        }
        return ids
    }

    /// Load a collection and wait for the async publish to land.
    private func load(_ model: IngestionModel, _ collectionID: UUID) async throws {
        model.loadContents(of: collectionID)
        for _ in 0..<200 where model.loadedCollectionID != collectionID {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a carousel contributes ONE tile to the display list, not four")
    func collapseHidesMembers() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await seedPost(
            url: "https://www.instagram.com/p/Zzzz/", count: 1, into: target, services,
            hexSeed: 50)
        try await load(model, target)

        #expect(model.items.count == 4)
        #expect(model.displayItems.count == 2)
        // The reducer's order MUST be the display list: ⇧-range and the marquee
        // resolve hits through it, so a hidden member in there would let a range
        // select a tile that is not on screen.
        #expect(model.selectionStore.order == model.displayItems.map { $0.item.id })
    }

    @Test("ungrouping restores every tile, and bumps the version the layout cache keys on")
    func togglingRederives() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await load(model, target)
        #expect(model.displayItems.count == 1)

        let versionWhenGrouped = model.itemsVersion
        model.groupCarousels = false
        #expect(model.displayItems.count == 3)
        // Without this bump `MasonryLayoutCache` would serve the previous solve and
        // lay three cells out against one cell's frames.
        #expect(model.itemsVersion != versionWhenGrouped)
        #expect(model.selectionStore.order == model.displayItems.map { $0.item.id })

        model.groupCarousels = true
        #expect(model.displayItems.count == 1)
    }

    @Test("setting the toggle to its current value does not churn the version")
    func idempotentToggle() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(url: nil, count: 1, into: target, services, hexSeed: 0)
        try await load(model, target)

        let before = model.itemsVersion
        model.groupCarousels = true          // already true
        #expect(model.itemsVersion == before)
    }

    @Test("selecting a collapsed tile targets the WHOLE post")
    func selectionWidensToPost() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        model.selectionStore.apply(.selectOnly(tile))
        // One tile selected, three assets acted on — the whole point of the split
        // between what the selection HOLDS and what an action TOUCHES.
        #expect(model.selection.ids.count == 1)
        #expect(model.selectedAssetIDs.count == 3)
    }

    @Test("a right-click on an UNSELECTED collapsed tile widens too")
    func unselectedCellWidens() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        #expect(model.selection.ids.isEmpty)
        // Otherwise Delete on a ⧉3 tile would remove one image and leave the tile.
        #expect(model.actionTargets(forCellItemID: tile).count == 3)
    }

    @Test("a lone item still acts on exactly itself")
    func loneItemUnaffected() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(url: nil, count: 2, into: target, services, hexSeed: 0)
        try await load(model, target)

        #expect(model.displayItems.count == 2)
        let tile = try #require(model.displayItems.first).item.id
        #expect(model.actionTargets(forCellItemID: tile).count == 1)
    }

    @Test("the drag payload carries the whole post")
    func dragCarriesThePost() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        let payload = try #require(model.dragPayload(forCellItemID: tile))
        #expect(payload.assetIDs.count == 3)
    }

    @Test("the delete confirmation counts ITEMS even though one tile was picked")
    func deleteConfirmationNamesItems() async throws {
        let (model, services) = try await makeModel()
        let target = Collection.unsortedID
        try await seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        model.requestDelete(assetIDs: model.actionTargets(forCellItemID: tile))
        // "Delete 3 items" while the selection bar would read "1 selected".
        #expect(model.pendingDeletion?.count == 3)
    }
}
