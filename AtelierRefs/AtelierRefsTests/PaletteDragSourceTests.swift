//
//  PaletteDragSourceTests.swift
//  AtelierRefsTests
//
//  099 · P6 — **what a drag out of a second window says it came from.**
//
//  This is the phase's inherited handoff, and it has a history worth stating in one
//  place because the bug got closer to real each time it was touched:
//
//   • P3 left `dragPayload` stamping `selectedFolderID` — the IMPORT target — as
//     the drag's source. Wrong in principle, invisible in practice, because one
//     window on a collection makes the two agree.
//   • P4 changed it to `contents.loadedCollectionID`, with
//     `AssetDragPayload.nilSourceID` for a feed that carries no memberships. Right,
//     and still written on `IngestionModel` — which reads exactly ONE read model.
//   • P6 opens a second window with a second feed. Had the rule stayed where P4 put
//     it, a drag out of the PALETTE would have carried the MAIN WINDOW's collection
//     as its source, and `routeDrop` would have read that as a MOVE: dropping a
//     palette tile on a sidebar row would have removed the asset from a folder the
//     user was not looking at.
//
//  So the rule now lives on ``CollectionReadModel``, and the assertions below are
//  about the thing that can go wrong again: TWO read models, loaded on different
//  feeds, must answer differently at the same moment.
//

import AtelierCore
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("What a drag out of a second window carries (099 · P6)", .timeLimit(.minutes(1)))
struct PaletteDragSourceTests {

    /// `CollectionReadModelTests`' stub, reused rather than re-written: the read is
    /// injected, so a feed a test drives by hand is the intended way to build one.
    private typealias StubFeed = CollectionReadModelTests.StubFeed

    private func item(in collectionID: UUID, order: Int = 0) -> CollectionItemDetail {
        let assetID = UUID()
        let sourceID = UUID()
        return CollectionItemDetail(
            item: CollectionItem(
                id: UUID(), collectionID: collectionID, assetID: assetID,
                addedAt: Date(), manualOrder: order),
            asset: Asset(
                id: assetID, kind: .image, blobHash: String(format: "%040x", order + 1),
                mimeType: "image/png", width: 10, height: 10, duration: nil,
                fileSize: 1, downloadState: .downloaded, createdAt: Date(),
                sourceId: sourceID),
            source: Source(id: sourceID, platform: .web, capturedAt: Date()))
    }

    /// Load `id` through a stub and wait for the publish — a signal, never a sleep
    /// (099 · 11A).
    private func loaded(
        _ id: UUID, carriesMembership: Bool, rows: Int = 2
    ) async -> CollectionReadModel {
        let stub = StubFeed()
        stub.pages[id] = CollectionFeed.Page(
            items: (0..<rows).map { item(in: id, order: $0) })
        let model = CollectionReadModel(
            feed: stub.feed(carriesMembership: carriesMembership),
            selectionStore: GridSelectionStore())
        let recorder = EventRecorder(model.events.stream())
        model.load(id)
        await recorder.wait { $0.contains(.loaded(collectionID: id, count: rows)) }
        return model
    }

    // MARK: - One feed at a time

    @Test("a drag out of a collection feed carries that collection")
    func collectionFeedCarriesItsCollection() async throws {
        let id = UUID()
        let model = await loaded(id, carriesMembership: true)
        #expect(model.dragSourceID == id)

        let cell = try #require(model.items.first).item.id
        let payload = try #require(model.dragPayload(forCellItemID: cell))
        #expect(payload.sourceCollectionID == id)
        #expect(payload.assetIDs == [model.items[0].asset.id])
    }

    /// A saved search is a query, not a container, so there is nothing to move OUT
    /// of and every drop it reaches can only COPY (`routeDrop`'s `sourceless` arm).
    /// The FEED says so (``CollectionFeed/carriesMembership``); nothing re-derives it.
    @Test("a drag out of a saved-search feed carries no source")
    func savedSearchDragsCarryNoSource() async throws {
        let id = UUID()
        let model = await loaded(id, carriesMembership: false)
        #expect(model.dragSourceID == AssetDragPayload.nilSourceID)

        let cell = try #require(model.items.first).item.id
        let payload = try #require(model.dragPayload(forCellItemID: cell))
        #expect(payload.sourceCollectionID == AssetDragPayload.nilSourceID)
    }

    /// "There is no source" is a fact about the FEED, not about whether a load has
    /// landed — P4's sentence, asserted at the one moment the two are distinguishable.
    @Test("a collection feed that has not loaded yet carries the sentinel, not a guess")
    func anUnloadedCollectionFeedCarriesTheSentinel() {
        let model = CollectionReadModel(selectionStore: GridSelectionStore())
        #expect(model.loadedCollectionID == nil)
        #expect(model.dragSourceID == AssetDragPayload.nilSourceID)
    }

    // MARK: - Two windows at once — the thing P6 could have broken

    /// **The assertion this suite exists for.** Two read models, loaded on different
    /// collections, answer with their own — at the same instant, from the same call.
    /// A rule that lived on the shared writing model could not make this true.
    @Test("two windows on two collections drag from two different sources")
    func twoWindowsDragFromTheirOwnFeeds() async throws {
        let main = UUID()
        let palette = UUID()
        let mainModel = await loaded(main, carriesMembership: true)
        let paletteModel = await loaded(palette, carriesMembership: true)

        #expect(main != palette)
        #expect(mainModel.dragSourceID == main)
        #expect(paletteModel.dragSourceID == palette)

        let mainCell = try #require(mainModel.items.first).item.id
        let paletteCell = try #require(paletteModel.items.first).item.id
        #expect(try #require(mainModel.dragPayload(forCellItemID: mainCell))
            .sourceCollectionID == main)
        #expect(try #require(paletteModel.dragPayload(forCellItemID: paletteCell))
            .sourceCollectionID == palette)
    }

    /// The palette can be on a saved search while the main window is on a collection,
    /// which is the mixed case: one carries a source, the other must not.
    @Test("a palette on a saved search carries no source while the shell carries one")
    func aPaletteOnASavedSearchIsSourcelessBesideACollectionWindow() async throws {
        let main = UUID()
        let search = UUID()
        let mainModel = await loaded(main, carriesMembership: true)
        let paletteModel = await loaded(search, carriesMembership: false)

        #expect(mainModel.dragSourceID == main)
        #expect(paletteModel.dragSourceID == AssetDragPayload.nilSourceID)
    }

    /// A cell that has left the feed yields no payload at all, so the grid host falls
    /// back to its lone-cell payload rather than dragging an empty set.
    @Test("a cell that is not in the feed has no payload")
    func aVanishedCellHasNoPayload() async throws {
        let id = UUID()
        let model = await loaded(id, carriesMembership: true)
        #expect(model.dragPayload(forCellItemID: UUID()) == nil)
    }
}
