//
//  TwoTierDeleteTests.swift
//  AtelierRefsTests
//
//  022 · D2–D5 — the surfaces now that they read `deleteIntent`:
//  **⌫ removes the item from where you are looking, ⌘⌫ removes it from the app.**
//
//  `DeleteIntentTests` pins the decoder; this pins what each surface does with the
//  answer. The grid's ⌫ used to land on `requestDeleteSelected` — the softest key on
//  the keyboard wired to the hardest verb — and `removeSelectedFromFolder` had zero
//  callers, so the remove side had never been exercised at all.
//
//  State is asserted against `AppServices` (the committed truth) after
//  `waitForWrites()`, in the shape `AppUndoTests` established.
//

import AppKit
import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - ⌫ in the collection grid (D2)

@MainActor
@Suite("⌫ removes from the collection (022 D2)")
struct GridRemoveVerbTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        try await CarouselRig.makeModel("two-tier-remove")
    }

    /// Seed `count` distinct media-less colour assets into `collectionID`.
    private func seedColors(
        _ count: Int, into collectionID: UUID, _ services: AppServices, hexSeed: Int = 0
    ) async throws -> [UUID] {
        try await CarouselRig.seedPost(
            url: nil, count: count, into: collectionID, services, hexSeed: hexSeed)
    }

    private func members(of collectionID: UUID, _ services: AppServices) async throws -> [UUID] {
        try await services.collectionItems(in: collectionID).map { $0.asset.id }
    }

    /// Open `collectionID` the way navigating to it does. `selectedFolderID` is what
    /// the remove verb reads for "where you are looking", so a rig that only calls
    /// `loadContents` leaves the model pointed at Unsorted and every removal no-ops.
    private func open(
        _ model: IngestionModel, _ collectionID: UUID
    ) async throws {
        await model.refreshFolders()   // so the toast can NAME the collection
        model.selectedFolderID = collectionID
        try await CarouselRig.load(model, collectionID)
    }

    // MARK: the two target branches

    @Test("⌫ over a SELECTION removes exactly the selected items")
    func removesTheSelection() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        try await open(model, folder.id)

        let items = model.displayItems
        _ = model.selectionStore.apply(.selectOnly(items[0].item.id))
        _ = model.selectionStore.apply(.commandClick(items[1].item.id))
        #expect(model.selection.ids.count == 2)

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[2]])
    }

    @Test("⌫ over a bare CURSOR removes the item under it")
    func removesTheLeadItem() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        try await open(model, folder.id)

        // An arrow key moves the cursor WITHOUT selecting — the un-widened branch.
        let target = try #require(model.displayItems.first { $0.asset.id == ids[1] })
        _ = model.selectionStore.apply(.setLead(target.item.id))
        #expect(model.selection.ids.isEmpty)

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])
    }

    /// The scope 027 · G1 fixed, now exercised by the verb it was fixed for: a
    /// collapsed tile reading ⧉4 STANDS FOR its post, so ⌫ takes all four rather than
    /// leaving a tile behind reading ⧉3.
    @Test("⌫ with the cursor on a collapsed ⧉4 tile removes the WHOLE post")
    func removesTheWidenedPost() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Feed")
        try await CarouselRig.seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 4, into: folder.id, services,
            hexSeed: 0)
        let lone = try await CarouselRig.seedPost(
            url: nil, count: 1, into: folder.id, services, hexSeed: 60)
        try await open(model, folder.id)
        #expect(model.items.count == 5)
        #expect(model.displayItems.count == 2)

        let tile = try #require(model.displayItems.first {
            model.postGroups.members(forItem: $0.item.id).count == 4
        })
        _ = model.selectionStore.apply(.setLead(tile.item.id))

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == lone)
    }

    // MARK: Unsorted — the no-op with an explanation

    /// Unsorted is the fallback every other removal re-homes INTO, and
    /// `AppServices.removeAssets` exempts it from the re-home for exactly that
    /// reason — so a removal there either does nothing or quietly orphans.
    @Test("⌫ in Unsorted removes NOTHING and says why")
    func unsortedIsANoOp() async throws {
        let (model, services) = try await makeModel()
        let ids = try await seedColors(2, into: Collection.unsortedID, services)
        try await open(model, Collection.unsortedID)
        let target = try #require(model.displayItems.first { $0.asset.id == ids[0] })
        _ = model.selectionStore.apply(.selectOnly(target.item.id))

        #expect(model.canRemoveFromCurrentFolder == false)
        model.removeSelectedFromFolder()
        await model.waitForWrites()

        // Nothing left, nothing staged for deletion, and one notice explaining ⌘⌫.
        #expect(Set(try await members(of: Collection.unsortedID, services)) == Set(ids))
        #expect(model.pendingDeletion == nil)
        #expect(model.lastNotice?.message.contains("⌘⌫") == true)
        // And no undo step was registered for a verb that did nothing.
        #expect(!model.canUndo)
    }

    @Test("⌫ with nothing to act on stages nothing and posts nothing")
    func noTargetsIsSilent() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        _ = try await seedColors(1, into: folder.id, services)
        try await open(model, folder.id)
        #expect(model.selection.lead == nil)

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services).count == 1)
        #expect(model.lastNotice == nil)
        #expect(!model.canUndo)
    }

    /// The search grid drives its OWN `GridSelectionStore`, so the shared model has no
    /// keyboard targets while a query is on screen — which is the structural reason ⌫
    /// there can never remove a membership even if it were wired to. Its ⌘⌫ goes
    /// through `requestDelete(assetIDs:)` with explicit ids instead, which does stage.
    @Test("search: ⌫ has no membership to take; ⌘⌫ still stages a delete")
    func searchRemovesNothingButStillDeletes() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Hits")
        let ids = try await seedColors(2, into: folder.id, services)
        try await open(model, folder.id)
        // A search surface never touches `model.selectionStore`.
        #expect(model.selection.ids.isEmpty && model.selection.lead == nil)

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services).count == 2)
        #expect(model.pendingDeletion == nil)

        model.requestDelete(assetIDs: ids)
        #expect(model.pendingDeletion?.assetIDs == ids)
    }

    // MARK: the F3 re-home invariant, through the new caller

    /// `AppServices.removeAssets(_:from:)` never orphans: an asset left with no
    /// memberships falls back to Unsorted. The invariant has a suite of its own for
    /// the tag-store caller; this is ⌫'s.
    @Test("removing an item's LAST membership re-homes it to Unsorted")
    func lastMembershipRehomes() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Only Home")
        let ids = try await seedColors(1, into: folder.id, services)
        // The seed lands it in `folder` alone — Unsorted is empty to begin with.
        #expect(try await members(of: Collection.unsortedID, services).isEmpty)
        try await open(model, folder.id)
        let target = try #require(model.displayItems.first)
        _ = model.selectionStore.apply(.selectOnly(target.item.id))

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services).isEmpty)
        // Reachable, not orphaned.
        #expect(try await members(of: Collection.unsortedID, services) == ids)
    }

    // MARK: undo

    /// The whole mitigation for inverting the grid's ⌫: it is undoable, and the toast
    /// that says so carries the token that fires the undo.
    @Test("⌫ then ⌘Z restores the membership AT ITS OLD POSITION")
    func undoRestoresMembershipAndOrder() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Ordered")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        try await open(model, folder.id)
        let target = try #require(model.displayItems.first { $0.asset.id == ids[1] })
        _ = model.selectionStore.apply(.selectOnly(target.item.id))

        model.removeSelectedFromFolder()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])

        // The toast says the verb out loud and carries the undo token.
        let event = try #require(model.lastUndoableAction)
        #expect(event.message.contains("Removed"))
        #expect(event.message.contains("Ordered"))

        model.undo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == ids)   // back in the middle
    }

    // MARK: the detail page's ⌫ (D4)

    /// The page's Remove and the grid's ⌫ are the same verb through the same rule, so
    /// the page cannot disagree with the grid behind it about what Unsorted means.
    @Test("the detail page's Remove takes one item, and no-ops in Unsorted")
    func detailPageRemove() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Page")
        let ids = try await seedColors(2, into: folder.id, services)
        try await open(model, folder.id)

        model.removeFromCurrentFolder(assetIDs: [ids[0]])
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[1]])

        let unsorted = try await seedColors(1, into: Collection.unsortedID, services, hexSeed: 90)
        try await open(model, Collection.unsortedID)
        model.removeFromCurrentFolder(assetIDs: unsorted)
        await model.waitForWrites()
        #expect(try await members(of: Collection.unsortedID, services).contains(unsorted[0]))
    }
}

// MARK: - ⌘⌫ on a board (D3)

@MainActor
@Suite("A board can delete from the library (022 D3)")
struct SpaceDeleteVerbTests {

    private func makeBoard() async throws
        -> (space: SpaceModel, model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "two-tier-space-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        let board = try await services.createSpace(name: "Board")
        let space = SpaceModel(spaceID: board.id, services: services, store: store)
        await space.load()
        return (space, model, services)
    }

    private func makeAsset(
        _ services: AppServices, hash: String, url: String
    ) async throws -> Asset {
        let draft = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096,
            downloadState: .downloaded)
        let source = SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
        return try await services.ingest(
            draft, from: source, into: services.unsortedFolderID).asset
    }

    private func members(of collectionID: UUID, _ services: AppServices) async throws -> [UUID] {
        try await services.collectionItems(in: collectionID).map { $0.asset.id }
    }

    /// ⌫ on a board drops the PLACEMENT and nothing else — a board owns placements,
    /// not memberships, so the picture stays in its collections.
    @Test("onRemoveTiles drops only the placement; the asset survives")
    func removeDropsOnlyThePlacement() async throws {
        let (space, _, services) = try await makeBoard()
        let asset = try await makeAsset(services, hash: "bb0001", url: "https://e.com/1")
        space.addAssets([asset])
        await space.waitForWrites()
        #expect(space.items.count == 1)

        let content = space.content()
        space.removeTiles(tileIDs: Set(content.tiles.map(\.id)), in: content)
        await space.waitForWrites()
        #expect(space.items.isEmpty)
        // Still in the library, still in Unsorted.
        #expect(try await members(of: Collection.unsortedID, services) == [asset.id])
    }

    /// ⌘⌫ on a board is a genuinely new capability: it stages the SHARED confirmation,
    /// and the tile is still there until the user answers it.
    @Test("⌘⌫ stages the shared confirmation — the placement survives until it is answered")
    func destroyStagesAndWaits() async throws {
        let (space, model, services) = try await makeBoard()
        let asset = try await makeAsset(services, hash: "bb0002", url: "https://e.com/2")
        space.addAssets([asset])
        await space.waitForWrites()
        let content = space.content()
        let assetIDs = content.tiles.compactMap { content.detail(forTileID: $0.id)?.asset?.id }
        #expect(assetIDs == [asset.id])

        model.requestDelete(assetIDs: assetIDs)
        #expect(model.pendingDeletion?.assetIDs == [asset.id])
        // Nothing has happened yet — the board and the library are untouched.
        await space.load()
        #expect(space.items.count == 1)
        #expect(try await members(of: Collection.unsortedID, services) == [asset.id])

        // Cancelling really cancels.
        model.cancelPendingDeletion()
        await model.waitForWrites()
        await space.load()
        #expect(space.items.count == 1)

        // Confirming lands on the ONE destructive path, and `space_item.asset_id`
        // CASCADEs — so the row goes with the asset and the board reloads empty.
        model.requestDelete(assetIDs: assetIDs)
        model.confirmPendingDeletion()
        await model.waitForWrites()
        #expect(try await members(of: Collection.unsortedID, services).isEmpty)
        await space.load()
        #expect(space.items.isEmpty)
    }

    /// Element tiles (frame / text) carry no asset, so ⌘⌫ over a selection of nothing
    /// but elements stages nothing rather than raising an empty confirmation.
    @Test("⌘⌫ over element-only tiles stages nothing")
    func elementsHaveNothingToDestroy() async throws {
        let (space, model, _) = try await makeBoard()
        space.addFrame(worldRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        await space.waitForWrites()
        let content = space.content()
        let assetIDs = content.tiles.compactMap { content.detail(forTileID: $0.id)?.asset?.id }
        #expect(assetIDs.isEmpty)

        model.requestDelete(assetIDs: assetIDs)
        #expect(model.pendingDeletion == nil)
    }
}

// MARK: - The two decoders

/// The canvas lives in `CanvasRenderer`, a package declared with ZERO dependencies so
/// the compiler enforces the view-agnostic boundary — so it carries its own eight-line
/// copy of the decoder rather than the package taking a dependency on the app (or a
/// decoder whose vocabulary is "remove from a collection" moving into a renderer).
///
/// This is the test that makes the duplication safe. It is the only place both copies
/// are visible at once, and it runs the whole matrix through both: a divergence fails
/// here instead of shipping a board where ⌘⌫ means something else.
@MainActor
@Suite("The board's delete decoder agrees with the app's (022 D3)")
struct DeleteIntentContractTests {

    private static let keys = [
        "\u{7f}",                                      // ⌫
        String(UnicodeScalar(NSDeleteFunctionKey)!),   // ⌦
        "x", "", "\r", " ",                            // and things that are not deletes
        String(UnicodeScalar(NSLeftArrowFunctionKey)!),
    ]

    private static let modifierSets: [NSEvent.ModifierFlags] = [
        [], [.command], [.shift], [.option], [.control], [.function],
        [.command, .shift], [.command, .option], [.command, .control],
        [.command, .function], [.shift, .option],
    ]

    @Test("both copies answer identically for every key × modifier pair")
    func decodersAgree() {
        for key in Self.keys {
            for modifiers in Self.modifierSets {
                let app = deleteIntent(characters: key, modifiers: modifiers)
                let board = CanvasHostView.deleteIntent(characters: key, modifiers: modifiers)
                switch (app, board) {
                case (nil, nil): break
                case (.remove, .remove): break
                case (.destroy, .destroy): break
                default:
                    let detail = "decoders disagree on \(key.debugDescription) "
                        + "with \(modifiers): app \(String(describing: app)), "
                        + "board \(String(describing: board))"
                    Issue.record(Comment(rawValue: detail))
                }
            }
        }
    }

    /// `nil` characters only reach the canvas copy (an `NSEvent` can report none);
    /// the app's takes a non-optional string, so this arm is the board's alone.
    @Test("the board's copy tolerates a nil character")
    func boardHandlesNilCharacters() {
        #expect(CanvasHostView.deleteIntent(characters: nil, modifiers: []) == nil)
        #expect(CanvasHostView.deleteIntent(characters: nil, modifiers: [.command]) == nil)
    }
}
