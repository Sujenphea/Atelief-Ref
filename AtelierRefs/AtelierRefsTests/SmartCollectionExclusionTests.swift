//
//  SmartCollectionExclusionTests.swift
//  AtelierRefsTests
//
//  099 · P4 — **the prohibitions, asserted rather than assumed.**
//
//  [057](../../.docs/057-smart-collections-overview.md) states most of what a
//  smart collection is by saying what it is NOT: *"Not drop targets (can't add to
//  a query) — excluded from [009]'s stack row and rail, and from Move to ▸
//  lists"*, and *"no manual order"*. Every one of those is a rule that lives in
//  the ABSENCE of code — a `.onDrop` nobody attached, a row nobody appended — and
//  an absence is exactly what a refactor deletes by accident without failing
//  anything.
//
//  So each is written down here as a positive claim over the real code path: the
//  destination tree the menus and the rail are built from, the two pure drop
//  routers, the sidebar's own statement of what takes a drop, and the source id a
//  drag out of a smart collection carries.
//

import AtelierBrowse
import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Smart collections: excluded from every destination and drop (057)",
       .timeLimit(.minutes(1)))
struct SmartCollectionExclusionTests {

    private func makeServices(_ label: String) throws -> AppServices {
        let path = NSTemporaryDirectory() + "smart-excl-\(label)-\(UUID().uuidString).sqlite"
        return try AppServices(databasePath: path)
    }

    // MARK: - Destination lists and menus

    /// The `CollectionTargets` consumers — the Move to ▸ / Add to ▸ menus, the
    /// SwiftUI destination list, the AppKit nested menu and the Home gallery — all
    /// resolve through ONE tree, and that tree is built from `[Collection]`.
    ///
    /// This asserts the consequence end to end rather than by inspection: a library
    /// holding two collections AND two saved searches produces a destination tree
    /// whose ids are exactly the collections'.
    @Test("no saved search is ever a destination, at any depth")
    func savedSearchesAreNotDestinations() async throws {
        let services = try makeServices("targets")
        let root = try await services.createCollection(name: "Refs")
        let child = try await services.createCollection(name: "Type", parent: root.id)
        let searchA = try await services.createSavedSearch(name: "Serif", rules: SearchRules())
        let searchB = try await services.createSavedSearch(
            name: "Favourites", rules: SearchRules(favoritesOnly: true))

        let folders = try await services.listCollections()
        let unsorted = services.unsortedFolderID

        let tree = CollectionTargets.destinationTree(folders: folders, unsortedID: unsorted)
        let flat = CollectionTargets.moveTargetTree(folders: folders, unsortedID: unsorted)
        let treeIDs = Set(CollectionTargets.flatten(tree).map(\.id))
        let flatIDs = Set(flat.map(\.id))

        #expect(treeIDs == flatIDs)
        #expect(treeIDs.contains(root.id))
        #expect(treeIDs.contains(child.id))
        #expect(treeIDs.contains(unsorted))
        #expect(!treeIDs.contains(searchA.id))
        #expect(!treeIDs.contains(searchB.id))
        // …and the folder-reparent list, which is where a saved search would show
        // up if anyone ever tried to nest one.
        let reparent = CollectionTargets.folderMoveTargets(
            for: child.id, folders: folders, unsortedID: unsorted)
        #expect(!reparent.map(\.id).contains(searchA.id))
    }

    // MARK: - The rail and the sidebar rows

    /// The rail's rule, stated once and walked exhaustively. Adding a `SidebarItem`
    /// case forces a decision here, because ``SidebarItem/acceptsAssetDrops`` has
    /// no `default`.
    @Test("a smart collection is not a drop target; a collection and a space are")
    func sidebarDropTargets() {
        #expect(SidebarItem.collection(UUID()).acceptsAssetDrops)
        #expect(SidebarItem.space(UUID()).acceptsAssetDrops)
        #expect(!SidebarItem.savedSearch(UUID()).acceptsAssetDrops)
        // The three that were already not targets, so a change to the rule cannot
        // quietly turn one of them on while making the smart case pass.
        #expect(!SidebarItem.home.acceptsAssetDrops)
        #expect(!SidebarItem.capture.acceptsAssetDrops)
        #expect(!SidebarItem.shelf.acceptsAssetDrops)
    }

    // MARK: - The two drop routers

    /// Dropping a drag that CAME OUT of a smart collection onto a real collection
    /// adds it — never moves it, because there is no collection to move out of.
    /// This is the same `sourceless` arm search results and a Space board already
    /// take (009 · N3), reached by 057's road.
    @Test("a drag out of a smart collection can only COPY, ⌥ or no ⌥")
    func smartDragCopiesNeverMoves() {
        let assets = [UUID(), UUID()]
        let target = UUID()
        let payload = AssetDragPayload(
            assetIDs: assets, sourceCollectionID: AssetDragPayload.nilSourceID)

        #expect(routeDrop(payload, onto: .collection(target), optionDown: false)
                == .copy(assetIDs: assets, to: target))
        #expect(routeDrop(payload, onto: .collection(target), optionDown: true)
                == .copy(assetIDs: assets, to: target))
    }

    /// 057: drag-REORDER is disabled. The grid says so with `canReorder: false`,
    /// and the router says so independently — a membership-less payload can never
    /// resolve a slot drop, whatever sort mode the target claims.
    @Test("a smart-collection drag never resolves a reorder slot")
    func smartDragNeverReorders() {
        let payload = AssetDragPayload(
            assetIDs: [UUID()], sourceCollectionID: AssetDragPayload.nilSourceID)
        for mode in SortMode.allCases {
            #expect(routeDrop(
                payload,
                onto: .slot(collectionID: UUID(), sortMode: mode, index: 0),
                optionDown: false) == .reject)
        }
    }

    /// Drag-OUT still works, which 057 is equally explicit about: the board takes
    /// it and places it. `CanvasDropContents` has no case for a saved search, so a
    /// board can never be asked to drop ONTO one — the exclusion there is in the
    /// type rather than in a guard.
    @Test("a smart-collection drag still places on a Space board")
    func smartDragPlacesOnABoard() {
        let assets = [UUID(), UUID()]
        let payload = AssetDragPayload(
            assetIDs: assets, sourceCollectionID: AssetDragPayload.nilSourceID)
        #expect(canvasDropRoute(.assetDrag(payload)) == .place(assetIDs: assets))
        // And an empty payload is still refused, so "membership-less" never becomes
        // "place nothing".
        #expect(canvasDropRoute(.assetDrag(AssetDragPayload.internalMarker)) == .reject)
    }

    // MARK: - The drag's SOURCE (099 · P3's second handoff)

    /// `dragPayload` used to stamp `selectedFolderID` — the IMPORT target — as the
    /// drag's source. This asserts the two are now distinct answers and that the
    /// one the drag carries is the FEED's.
    @Test("a drag's source is the loaded feed, not the import target")
    func dragSourceIsTheFeed() async throws {
        let services = try makeServices("drag-source")
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()

        let shown = try await services.createCollection(name: "Shown")
        let importTarget = try await services.createCollection(name: "Import target")
        await model.refreshFolders()

        let recorder = EventRecorder(model.contents.events.stream())
        model.loadContents(of: shown.id)
        await recorder.wait { events in
            events.contains(where: { event in
                if case .loaded(let id, _) = event { return id == shown.id }
                return false
            })
        }
        // The two fields now disagree, which is the case the old code got wrong.
        model.selectedFolderID = importTarget.id
        #expect(model.dragSourceID == shown.id)
        #expect(model.dragSourceID != model.selectedFolderID)
    }

    /// The same seam on a membership-less feed: a window showing a saved search has
    /// no source collection at all, so its drags carry the sentinel and every drop
    /// they reach copies.
    @Test("a membership-less feed drags with the nil-source sentinel")
    func membershipLessFeedDragsSourceless() async throws {
        let services = try makeServices("drag-smart")
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()

        model.contents.feed = .savedSearch(services)
        #expect(model.dragSourceID == AssetDragPayload.nilSourceID)
        // …and that source routes to a copy, which is the point of the sentinel.
        let payload = AssetDragPayload(
            assetIDs: [UUID()], sourceCollectionID: model.dragSourceID)
        let target = UUID()
        if case .copy = routeDrop(payload, onto: .collection(target), optionDown: false) {
            // expected
        } else {
            Issue.record("a sourceless drag must copy, never move")
        }
    }

    // MARK: - The tint (057 — "a distinct badge/tint")

    /// Three card kinds, three shades. Asserted because a "distinct tint" that
    /// quietly resolved to the same colour twice would look exactly like a card
    /// that had been given the wrong kind, and nothing else would notice.
    @Test("the three card tints are three different shades")
    func cardTintsDiffer() {
        let fills = CardTint.allCases.map(\.fill)
        #expect(Set(CardTint.allCases).count == 3)
        #expect(fills[0] != fills[1])
        #expect(fills[1] != fills[2])
        #expect(fills[0] != fills[2])
        // The smart card's placeholder ink reads as primary, like Unsorted's — it is
        // the FILL that separates them.
        #expect(CardTint.smart.ink == CardTint.accent.ink)
        #expect(CardTint.plain.ink != CardTint.smart.ink)
    }
}
