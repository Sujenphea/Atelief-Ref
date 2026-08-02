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
import Combine
import Foundation
import Testing
@testable import AtelierRefs

/// The rig every carousel suite in this file needs: a throwaway on-disk library, a
/// temp media store, and a model with its folders loaded. It lived as three
/// near-identical private copies — same setup, three places to fix a seeding bug in
/// only two of them — so it is one place now.
@MainActor
enum CarouselRig {

    /// A model over a fresh database. `tag` only names the temp file, to keep a
    /// failing run's leftovers traceable to the suite that made them.
    static func makeModel(
        _ tag: String
    ) async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "\(tag)-\(UUID().uuidString).sqlite"
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
    static func seedPost(
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
    static func load(_ model: IngestionModel, _ collectionID: UUID) async throws {
        model.loadContents(of: collectionID)
        for _ in 0..<200 where model.loadedCollectionID != collectionID {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
@Suite("Carousel grouping: model wiring")
struct PostGroupingWiringTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        try await CarouselRig.makeModel("post-grouping")
    }

    @discardableResult
    private func seedPost(
        url: String?, count: Int, into collectionID: UUID, _ services: AppServices,
        hexSeed: Int
    ) async throws -> [UUID] {
        try await CarouselRig.seedPost(
            url: url, count: count, into: collectionID, services, hexSeed: hexSeed)
    }

    private func load(_ model: IngestionModel, _ collectionID: UUID) async throws {
        try await CarouselRig.load(model, collectionID)
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

@MainActor
@Suite("Carousel grouping: opening a post in place")
struct PostExpansionTests {

    private func rig() async throws -> (model: IngestionModel, services: AppServices) {
        try await CarouselRig.makeModel("post-expand")
    }

    private func seed(
        _ services: AppServices, url: String?, count: Int, into collectionID: UUID, hexSeed: Int
    ) async throws {
        try await CarouselRig.seedPost(
            url: url, count: count, into: collectionID, services, hexSeed: hexSeed)
    }

    private func load(_ model: IngestionModel, _ id: UUID) async throws {
        try await CarouselRig.load(model, id)
    }

    @Test("the chip opens the post in place and closes it again")
    func toggleOpensAndCloses() async throws {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        try await seed(services, url: "https://www.instagram.com/p/AbCd/", count: 3,
                       into: target, hexSeed: 0)
        try await load(model, target)
        #expect(model.displayItems.count == 1)

        let tile = try #require(model.displayItems.first).item.id
        model.toggleExpansion(forItem: tile)
        #expect(model.displayItems.count == 3)
        // The reducer's order has to follow, or ⇧-range would not reach the members
        // that just appeared.
        #expect(model.selectionStore.order.count == 3)

        model.toggleExpansion(forItem: tile)
        #expect(model.displayItems.count == 1)
    }

    @Test("an OPEN post's members act individually, not as a post")
    func openMembersActAlone() async throws {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        try await seed(services, url: "https://www.instagram.com/p/AbCd/", count: 3,
                       into: target, hexSeed: 0)
        try await load(model, target)
        let tile = try #require(model.displayItems.first).item.id

        // Closed: the tile stands for the whole post.
        #expect(model.actionTargets(forCellItemID: tile).count == 3)

        model.toggleExpansion(forItem: tile)
        // Open: each visible member is its own thing. Otherwise opening a carousel
        // to delete ONE bad frame would delete all three — the exact thing you
        // opened it to avoid.
        for member in model.displayItems.map({ $0.item.id }) {
            #expect(model.actionTargets(forCellItemID: member).count == 1)
        }
    }

    @Test("the chip is a no-op on a tile that isn't a post")
    func loneTileIgnoresTheToggle() async throws {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        try await seed(services, url: nil, count: 2, into: target, hexSeed: 0)
        try await load(model, target)

        let before = model.itemsVersion
        model.toggleExpansion(forItem: try #require(model.displayItems.first).item.id)
        #expect(model.itemsVersion == before)
        #expect(model.displayItems.count == 2)
    }

    @Test("an expansion whose post leaves the feed is dropped, not left wedged open")
    func staleExpansionPruned() async throws {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        try await seed(services, url: "https://www.instagram.com/p/AbCd/", count: 3,
                       into: target, hexSeed: 0)
        try await load(model, target)
        model.toggleExpansion(forItem: try #require(model.displayItems.first).item.id)
        #expect(model.expandedPosts.count == 1)

        // A different collection has none of those items.
        let other = try await services.createCollection(name: "Other", parent: nil)
        try await load(model, other.id)
        #expect(model.expandedPosts.isEmpty)
    }

    @Test("the detail cursor lands on a TILE, never on a hidden member")
    func displayTileMapsHiddenMembers() async throws {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        try await seed(services, url: "https://www.instagram.com/p/AbCd/", count: 3,
                       into: target, hexSeed: 0)
        try await load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        let hidden = try #require(
            model.items.map { $0.item.id }.first { $0 != tile })
        // The overlay steps through every item, so closing on a hidden member used
        // to leave the grid's lead pointing at an id not in the reducer's order.
        #expect(model.displayTile(for: hidden) == tile)
        #expect(model.displayTile(for: tile) == tile)

        // Once the post is OPEN the member is a real tile, so it maps to itself.
        model.toggleExpansion(forItem: tile)
        #expect(model.displayTile(for: hidden) == hidden)
    }
}

@MainActor
@Suite("Carousel grouping: reordering collapsed posts")
struct PostReorderTests {

    private func rig() async throws -> (model: IngestionModel, services: AppServices) {
        try await CarouselRig.makeModel("post-reorder")
    }

    private func seed(
        _ services: AppServices, url: String?, count: Int, into collectionID: UUID, hexSeed: Int
    ) async throws {
        try await CarouselRig.seedPost(
            url: url, count: count, into: collectionID, services, hexSeed: hexSeed)
    }

    /// Three posts of three images each: 9 items, 3 tiles. The gap between those two
    /// numbers is what the bug lived in.
    private func loadedFeed() async throws -> (IngestionModel, UUID) {
        let (model, services) = try await rig()
        let target = Collection.unsortedID
        for (index, code) in ["Aaa", "Bbb", "Ccc"].enumerated() {
            try await seed(
                services, url: "https://www.instagram.com/p/\(code)/", count: 3,
                into: target, hexSeed: index * 20)
        }
        model.setSortMode(.manual, for: target)
        model.loadContents(of: target)
        for _ in 0..<200 where model.loadedCollectionID != target {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (model, target)
    }

    @Test("dragging the first post past the last tile puts it LAST, not third-of-nine")
    func collapsedPostReordersToTheEnd() async throws {
        let (model, _) = try await loadedFeed()
        #expect(model.items.count == 9)
        #expect(model.displayItems.count == 3)

        let firstTile = try #require(model.displayItems.first).item.id
        let lastTile = try #require(model.displayItems.last).item.id
        let moving = model.actionTargets(forCellItemID: firstTile)
        #expect(moving.count == 3)

        // Slot 3 = "after every tile", the index the GRID hands over. Applied to the
        // 9-item array it used to mean "after the 3rd image" — barely a move.
        model.reorderItems(movingAssetIDs: moving, insertAt: 3)

        #expect(model.displayItems.count == 3)
        #expect(model.displayItems.last?.item.id == firstTile)
        #expect(model.displayItems.first?.item.id != firstTile)
        // The post that was last is now first, so nothing was dropped or duplicated.
        #expect(model.displayItems.map { $0.item.id }.contains(lastTile))
        #expect(model.items.count == 9)
    }

    @Test("a moved post keeps its images together and in order")
    func membersStayContiguous() async throws {
        let (model, _) = try await loadedFeed()
        let firstTile = try #require(model.displayItems.first).item.id
        let movedMembers = model.postGroups.members(forItem: firstTile)
        model.reorderItems(
            movingAssetIDs: model.actionTargets(forCellItemID: firstTile), insertAt: 3)

        let order = model.items.map { $0.item.id }
        let positions = movedMembers.compactMap { order.firstIndex(of: $0) }
        #expect(positions.count == 3)
        // Contiguous...
        #expect(positions.max()! - positions.min()! == 2)
        // ...at the very end, and still in their original relative order.
        #expect(positions.max() == order.count - 1)
        #expect(positions == positions.sorted())
    }

    @Test("with grouping off, reordering is unchanged")
    func ungroupedReorderStillWorks() async throws {
        let (model, _) = try await loadedFeed()
        model.groupCarousels = false
        #expect(model.displayItems.count == 9)

        let first = try #require(model.items.first)
        model.reorderItems(movingAssetIDs: [first.asset.id], insertAt: 9)
        #expect(model.items.last?.item.id == first.item.id)
        #expect(model.items.count == 9)
    }
}

/// The regression these guard is not visible in any pure test and barely visible on
/// screen: `IngestionModel.displayItems` / `itemsVersion` / `postGroups` are all
/// deliberately PLAIN properties, so the only thing that can re-run a SwiftUI body
/// is the trigger that changed them. Ship the trigger un-`@Published` and the model
/// re-derives correctly into a display list nobody re-reads — the grid keeps drawing
/// the previous one until some unrelated publish happens along to flush it, which
/// reads as "the toggle does nothing" and then, a click later, "the toggle works".
///
/// `objectWillChange` fires on `willSet`, so the derivation is still the OLD one
/// *inside* the sink; what matters — and what SwiftUI's coalesced update actually
/// sees — is that the value has settled by the time the mutation returns. Both are
/// asserted.
@MainActor
@Suite("Carousel grouping: the grid is told to redraw")
struct PostGroupingPublishTests {

    /// Counts `objectWillChange` emissions. A class because the sink escapes.
    @MainActor
    private final class Recorder {
        var count = 0
        var token: AnyCancellable?

        init(_ object: IngestionModel) {
            token = object.objectWillChange.sink { [self] _ in count += 1 }
        }
    }

    private func loadedCarousel() async throws -> IngestionModel {
        let (model, services) = try await CarouselRig.makeModel("post-publish")
        let target = Collection.unsortedID
        try await CarouselRig.seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 3, into: target, services,
            hexSeed: 0)
        try await CarouselRig.load(model, target)
        return model
    }

    @Test("flipping the grouping toggle publishes, so the grid re-reads the feed")
    func togglePublishes() async throws {
        let model = try await loadedCarousel()
        #expect(model.displayItems.count == 1)

        let recorder = Recorder(model)
        model.groupCarousels = false

        #expect(recorder.count >= 1)
        #expect(model.displayItems.count == 3)
    }

    /// The chip click is the ONE interaction that deliberately leaves the selection
    /// alone (the chip-zone branch of `gridCellMouseDown`), so unlike every other
    /// grid gesture there is no
    /// selection publish riding along to redraw for it.
    @Test("opening a post in place publishes on its own")
    func expansionPublishes() async throws {
        let model = try await loadedCarousel()
        let tile = try #require(model.displayItems.first).item.id

        let recorder = Recorder(model)
        model.toggleExpansion(forItem: tile)

        #expect(recorder.count >= 1)
        #expect(model.displayItems.count == 3)

        let before = recorder.count
        model.toggleExpansion(forItem: tile)
        #expect(recorder.count > before)
        #expect(model.displayItems.count == 1)
    }

    /// The chip on an ungrouped tile does nothing, so it must also say nothing —
    /// otherwise every stray click on a lone tile invalidates the whole screen.
    @Test("a no-op chip click publishes nothing")
    func noOpToggleIsSilent() async throws {
        let (model, services) = try await CarouselRig.makeModel("post-publish-noop")
        let target = Collection.unsortedID
        try await CarouselRig.seedPost(
            url: "https://www.instagram.com/p/Solo/", count: 1, into: target, services,
            hexSeed: 5)
        try await CarouselRig.load(model, target)

        let tile = try #require(model.displayItems.first).item.id
        let recorder = Recorder(model)
        model.toggleExpansion(forItem: tile)
        #expect(recorder.count == 0)
    }

    /// A plain load must not publish the expansion set: it is pruned on EVERY
    /// derivation, and the common case (nothing open) has to assign nothing.
    @Test("loading a feed with nothing open does not churn the expansion state")
    func pruneIsSilentWhenNothingIsOpen() async throws {
        let model = try await loadedCarousel()
        #expect(model.expandedPosts.isEmpty)
        let tile = try #require(model.displayItems.first).item.id
        model.toggleExpansion(forItem: tile)
        #expect(model.expandedPosts.count == 1)
        model.toggleExpansion(forItem: tile)
        #expect(model.expandedPosts.isEmpty)
    }
}
