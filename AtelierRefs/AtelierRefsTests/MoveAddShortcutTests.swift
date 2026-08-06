//
//  MoveAddShortcutTests.swift
//  AtelierRefsTests
//
//  024 · K3 — **`M` = Move to…, `A` = Add to…**, on the collection grid; `A` only on
//  a Space board.
//
//  Four things are asserted here, in the order they can go wrong:
//
//   1. **Decoding.** Bare (or ⇧) `M` / `A` resolve; ⌘M, ⌥A, ⌃A resolve to nothing and
//      ⌘A is still Select All. A bare letter that leaked under ⌘ would eat a standard
//      chord; one that leaked under ⌥ would eat a character a text field owes the user.
//   2. **What they act on.** The SAME rule ⌫ and ⌘D use — the selection when there is
//      one, else the keyboard cursor's post, WIDENED, so a cursor on a collapsed ⧉4
//      tile files all four ([027] G1). A second targeting rule is the bug this shares
//      an accessor to avoid.
//   3. **The board's `A` leaves the placements alone**, which is the whole reason the
//      board has `A` and not `M`.
//   4. **`M` is not bound on a board at all**, asserted against the decoder rather
//      than against a view, because that is where it would come back.
//
//  The picker itself is view code (repo convention: compile-only + manual), so what is
//  tested of it is the pure half its keyboard cursor walks.
//

import AppKit
import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Decoding

@Suite("M / A decoding — bare means bare (024 K3)")
struct MoveAddDecodingTests {

    private func grid(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [])
        -> GridKeyCommand? {
        gridKeyCommand(characters: characters, modifiers: modifiers)
    }

    private func board(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [])
        -> CanvasHostView.CanvasBoardCommand? {
        CanvasHostView.boardShortcut(characters: characters, modifiers: modifiers)
    }

    // MARK: The grid

    @Test("bare M and A resolve in the grid, in both cases")
    func gridBareLetters() {
        #expect(grid("m") == .moveTo)
        #expect(grid("M") == .moveTo)
        #expect(grid("a") == .addTo)
        #expect(grid("A") == .addTo)
    }

    /// ⇧ is tolerated: these are verbs a user types, and a capital still meant the
    /// verb. (`X` differs deliberately — it is a toggle, not a verb, and its case
    /// tests the stricter `bareModifiers.isEmpty`.)
    @Test("⇧ is tolerated on the grid's M and A")
    func gridShiftTolerated() {
        #expect(grid("m", .shift) == .moveTo)
        #expect(grid("a", .shift) == .addTo)
        #expect(grid("M", .shift) == .moveTo)
        #expect(grid("A", .shift) == .addTo)
    }

    /// The guard that matters. ⌘A was Select All before K3 and still is; ⌘M belongs to
    /// nobody and must stay that way; ⌥ / ⌃ letters belong to a text field.
    @Test("the grid's ⌘ / ⌥ / ⌃ combos are untouched by M and A")
    func gridModifiedCombos() {
        #expect(grid("a", .command) == .selectAll)
        #expect(grid("a", [.command, .shift]) == .selectAll)
        #expect(grid("m", .command) == nil)
        #expect(grid("m", [.command, .shift]) == nil)
        for modifiers: NSEvent.ModifierFlags in [.option, .control, [.option, .shift]] {
            #expect(grid("m", modifiers) == nil)
            #expect(grid("a", modifiers) == nil)
        }
    }

    /// The letters that were already claimed keep their meanings — a decoder gaining
    /// two cases must not perturb the eight it had.
    @Test("the grid's existing bindings still decode as they did")
    func gridUnchanged() {
        #expect(grid("x") == .toggleLead)
        #expect(grid("x", .shift) == nil)      // still stricter than M / A
        #expect(grid("x", .command) == nil)
        #expect(grid("=", .command) == .zoomIn)
        #expect(grid("-", .command) == .zoomOut)
        #expect(grid("\r") == .openLead)
        #expect(grid("\u{1b}") == .escape)
        #expect(grid(" ") == .quickLook)
    }

    // MARK: The board

    @Test("bare A resolves on the board, in both cases")
    func boardBareA() {
        #expect(board("a") == .file)
        #expect(board("A") == .file)
        #expect(board("a", .shift) == .file)
    }

    /// **The board has no `M`.** [024] §C recommended one; it was rejected because a
    /// board is not a collection, so "move" there would have had to drop the
    /// placements too — a different verb from the grid's under the same key. This is
    /// the assertion that keeps it out.
    @Test("M is not bound on a board — no decoder claims it")
    func boardHasNoM() {
        for key in ["m", "M"] {
            for modifiers: NSEvent.ModifierFlags in [[], .shift, .command, .option, .control] {
                #expect(board(key, modifiers) == nil, "boardShortcut claimed \(key)")
                #expect(
                    CanvasHostView.toolShortcut(characters: key, modifiers: modifiers) == nil,
                    "toolShortcut claimed \(key)")
            }
        }
    }

    @Test("the board's A rejects ⌘ / ⌥ / ⌃ / fn")
    func boardModifiedCombos() {
        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control, .function] {
            #expect(board("a", modifiers) == nil)
        }
    }

    /// The two board decoders are siblings, not one overloaded on the other: a tool
    /// key is not a board command and a board command is not a tool.
    @Test("the tool decoder and the board decoder do not overlap")
    func boardDecodersAreDisjoint() {
        for key in ["v", "f", "t"] {
            #expect(CanvasHostView.toolShortcut(characters: key, modifiers: []) != nil)
            #expect(board(key) == nil)
        }
        #expect(CanvasHostView.toolShortcut(characters: "a", modifiers: []) == nil)
        #expect(board("v") == nil)
    }
}

// MARK: - What the keys act on

/// The grid's `M` / `A` read ``IngestionModel/destinationActionTargets``, which is
/// ``IngestionModel``'s private `keyboardActionTargets` — the same property ⌫ and ⌘D
/// read. Sharing it is the point: the one action path that used to compute its own
/// answer produced [027] G1's bug, where a cursor on a tile reading ⧉4 acted on one
/// image and left the tile behind reading 3.
@MainActor
@Suite("M / A act on the same targets ⌫ and ⌘D do (024 K3)")
struct MoveAddTargetTests {

    /// A four-image post plus one lone capture — 5 items, 2 tiles. The gap between
    /// those two numbers is what a naive lead read falls into.
    private func loadedFeed(
        _ tag: String
    ) async throws -> (model: IngestionModel, services: AppServices, target: UUID) {
        let (model, services) = try await CarouselRig.makeModel(tag)
        let target = Collection.unsortedID
        try await CarouselRig.seedPost(
            url: "https://www.instagram.com/p/AbCd/", count: 4, into: target, services,
            hexSeed: 0)
        try await CarouselRig.seedPost(
            url: nil, count: 1, into: target, services, hexSeed: 60)
        try await CarouselRig.load(model, target)
        return (model, services, target)
    }

    /// The tile standing for `images` images, by what it stands for rather than by
    /// feed position, so the suite does not depend on the collection's sort order.
    private func tileID(_ model: IngestionModel, standsFor images: Int) throws -> UUID {
        try #require(model.displayItems.first {
            max(model.postGroups.members(forItem: $0.item.id).count, 1) == images
        }).item.id
    }

    @Test("with a selection, M files the SELECTION")
    func selectionWins() async throws {
        let (model, _, _) = try await loadedFeed("move-add-selection")
        let ids = model.displayItems.map(\.item.id)
        model.selectionStore.apply(.selectAll)
        #expect(model.selection.ids.count == ids.count)
        // Two tiles, five assets: the selection widens through the same `assetIDs`
        // mapping the bar's batch verbs use.
        #expect(model.destinationActionTargets.count == 5)
    }

    @Test("with no selection, M files the CURSOR's post — all four of a ⧉4 tile")
    func cursorOnCollapsedPostWidens() async throws {
        let (model, _, _) = try await loadedFeed("move-add-collapsed")
        let tile = try tileID(model, standsFor: 4)
        _ = model.selectionStore.apply(.setLead(tile))
        #expect(model.selection.ids.isEmpty)     // a cursor, not a selection
        #expect(model.destinationActionTargets.count == 4)
    }

    @Test("inside an OPENED post the cursor files one frame — the deliberate exception")
    func cursorInsideOpenedPostStaysNarrow() async throws {
        let (model, _, _) = try await loadedFeed("move-add-opened")
        let tile = try tileID(model, standsFor: 4)
        model.toggleExpansion(forItem: tile)
        #expect(model.displayItems.count == 5)
        for member in model.postGroups.members(forItem: tile) {
            _ = model.selectionStore.apply(.setLead(member))
            #expect(model.destinationActionTargets.count == 1)
        }
    }

    @Test("with neither a selection nor a cursor there is nothing to file")
    func emptyGridFilesNothing() async throws {
        let (model, _) = try await CarouselRig.makeModel("move-add-empty")
        #expect(model.destinationActionTargets.isEmpty)
    }

    /// The verb behind `M`, end to end: the memberships move, and one undo puts them
    /// back. (`A`'s own undo is asserted on the board below, where it matters most.)
    @Test("M's verb moves the memberships and undoes")
    func moveVerbRoundTrips() async throws {
        let (model, services, source) = try await loadedFeed("move-add-verb")
        let destination = try await services.createCollection(name: "Filed", parent: nil)
        let targets = try #require(model.displayItems.first).item.id
        _ = model.selectionStore.apply(.setLead(targets))
        let assetIDs = model.destinationActionTargets
        #expect(!assetIDs.isEmpty)

        model.moveToCollection(assetIDs: assetIDs, to: destination.id)
        await model.waitForWrites()
        var filed = try await services.collectionItems(in: destination.id).map(\.asset.id)
        #expect(Set(filed) == Set(assetIDs))

        model.undo()
        await model.waitForWrites()
        filed = try await services.collectionItems(in: destination.id).map(\.asset.id)
        #expect(filed.isEmpty)
        let back = try await services.collectionItems(in: source).map(\.asset.id)
        #expect(Set(assetIDs).isSubset(of: Set(back)))
    }
}

// MARK: - A on a board

/// The board's `A` is `addAssets` and nothing else: the tiles stay exactly where they
/// were. That is the whole argument for binding `A` there and not `M` — a board owns
/// PLACEMENTS, not memberships (019 · C1), so "move" would have had to invent a
/// composite verb, and this suite is what would notice if one crept in.
@MainActor
@Suite("A on a board files the assets and leaves the placements (024 K3)")
struct BoardAddToCollectionTests {

    private struct Rig {
        let model: IngestionModel
        let space: SpaceModel
        let services: AppServices
        let assetIDs: [UUID]
    }

    /// A board with three placed colour assets, plus one text element to prove
    /// elements are skipped rather than crashing the mapping.
    private func makeRig(_ tag: String) async throws -> Rig {
        let dbPath = NSTemporaryDirectory() + "\(tag)-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()

        let source = SourceDraft(platform: .localPaste, originalURL: nil, capturedAt: Date())
        var assets: [Asset] = []
        for hex in ["#112233", "#445566", "#778899"] {
            assets.append(try await services.ingestContent(
                .color(hex: hex), from: source, into: Collection.unsortedID).asset)
        }

        let created = try await services.createSpace(name: "Filing Board")
        let space = SpaceModel(spaceID: created.id, services: services, store: store)
        await space.load()
        space.addAssets(assets)
        await space.waitForWrites()
        space.addText(worldRect: CGRect(x: 0, y: 0, width: 100, height: 40))
        await space.waitForWrites()
        await space.load()

        return Rig(model: model, space: space, services: services,
                   assetIDs: assets.map(\.id))
    }

    /// The exact body `SpaceView` hands the canvas as `onFileTiles`: tiles → z-ordered
    /// asset ids, elements dropped. Kept here so the mapping under test is the one the
    /// view runs, not a paraphrase of it.
    private func assetIDs(forTiles tileIDs: Set<Int>, in content: SpaceContent) -> [UUID] {
        tileIDs
            .compactMap { content.detail(forTileID: $0) }
            .sorted { $0.item.z < $1.item.z }
            .compactMap { $0.asset?.id }
    }

    @Test("A files the selected tiles' assets and every placement stays put")
    func placementsSurvive() async throws {
        let rig = try await makeRig("board-add")
        let destination = try await rig.services.createCollection(name: "Board Refs", parent: nil)
        await rig.model.refreshFolders()

        let content = rig.space.content()
        let allTiles = Set(rig.space.items.compactMap { content.tileID(forSpaceItemID: $0.item.id) })
        rig.space.select(tileIDs: allTiles, in: content)

        let placementsBefore = rig.space.items.count
        let placedBefore = rig.space.placedItems.map(\.item.id)
        #expect(placementsBefore == 4)   // three assets + one text element

        // The text element carries no asset, so three ids come out of four tiles.
        let targets = assetIDs(forTiles: rig.space.selectedTileIDs(in: content), in: content)
        #expect(Set(targets) == Set(rig.assetIDs))

        rig.model.copyToCollection(assetIDs: targets, to: destination.id)
        await rig.model.waitForWrites()

        let filed = try await rig.services.collectionItems(in: destination.id).map(\.asset.id)
        #expect(Set(filed) == Set(rig.assetIDs))

        // …and the board is untouched: same rows, same ids, same count.
        await rig.space.load()
        #expect(rig.space.items.count == placementsBefore)
        #expect(rig.space.placedItems.map(\.item.id) == placedBefore)
    }

    /// One undoable membership edit, and NOTHING on the board's own undo stack. The
    /// two stacks are separate (`SpaceModel` has its own), and a verb that pushed onto
    /// both would make ⌘Z on a board ambiguous about what it was reversing.
    @Test("A registers one undoable membership edit and no placement edit")
    func oneUndoableMembershipEdit() async throws {
        let rig = try await makeRig("board-add-undo")
        let destination = try await rig.services.createCollection(name: "Board Refs", parent: nil)
        await rig.model.refreshFolders()

        let boardUndoBefore = rig.space.undoActionName
        let boardCountBefore = rig.space.items.count
        #expect(!rig.model.canUndo)      // nothing filed yet

        rig.model.copyToCollection(assetIDs: rig.assetIDs, to: destination.id)
        await rig.model.waitForWrites()

        // The membership half: one entry, named for the verb.
        #expect(rig.model.canUndo)
        #expect(rig.model.undoActionName == "Add")

        // The placement half: nothing at all.
        #expect(rig.space.undoActionName == boardUndoBefore)
        #expect(rig.space.items.count == boardCountBefore)

        // And it really reverses: the memberships go, the board does not.
        rig.model.undo()
        await rig.model.waitForWrites()
        let filed = try await rig.services.collectionItems(in: destination.id)
        #expect(filed.isEmpty)
        await rig.space.load()
        #expect(rig.space.items.count == boardCountBefore)
    }

    /// The inverse removes only what the forward pass CREATED. An asset already in the
    /// destination keeps the membership it arrived with, or undoing an `A` over a
    /// half-filed selection would quietly unfile the half that predated it.
    @Test("undoing A leaves memberships that predated it alone")
    func undoSparesPriorMemberships() async throws {
        let rig = try await makeRig("board-add-partial")
        let destination = try await rig.services.createCollection(name: "Board Refs", parent: nil)
        // One asset is filed there BEFORE the shortcut runs.
        try await rig.services.addAssets([rig.assetIDs[0]], to: destination.id)
        await rig.model.refreshFolders()

        rig.model.copyToCollection(assetIDs: rig.assetIDs, to: destination.id)
        await rig.model.waitForWrites()
        var filed = try await rig.services.collectionItems(in: destination.id).map(\.asset.id)
        #expect(Set(filed) == Set(rig.assetIDs))

        rig.model.undo()
        await rig.model.waitForWrites()
        filed = try await rig.services.collectionItems(in: destination.id).map(\.asset.id)
        #expect(filed == [rig.assetIDs[0]])
    }
}

// MARK: - The picker's keyboard cursor

/// The popover is view code, so what is asserted is the pure half its ↑ / ↓ walk: the
/// ids it may land on, and how a step moves between them. Both live on
/// ``CollectionDestinationList`` so the cursor can never walk an order the eye does
/// not see — it is derived from the SAME `rows` the list draws.
@Suite("The destination picker's keyboard cursor (024 K3)")
struct DestinationPickerCursorTests {

    private func collection(
        _ name: String, id: UUID = UUID(), parent: UUID? = nil, sortIndex: Int = 0
    ) -> Collection {
        Collection(
            id: id, name: name, description: nil, coverAssetID: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            parentCollectionID: parent, sortIndex: sortIndex)
    }

    /// Unsorted, then Refs ▸ Type, then Photography.
    private func folders() -> (all: [Collection], unsorted: UUID, refs: UUID, type: UUID, photo: UUID) {
        let unsorted = collection("Unsorted", id: Collection.unsortedID)
        let refs = collection("Refs", sortIndex: 0)
        let type = collection("Type", parent: refs.id)
        let photo = collection("Photography", sortIndex: 1)
        return ([unsorted, refs, type, photo], unsorted.id, refs.id, type.id, photo.id)
    }

    @Test("the cursor walks the list's own row order")
    func navigableIDsFollowTheRows() {
        let f = folders()
        let rows = CollectionDestinationList.rows(
            folders: f.all, unsortedID: f.unsorted).map(\.id)
        let ids = CollectionDestinationList.navigableIDs(
            folders: f.all, unsortedID: f.unsorted)
        #expect(ids == rows)
        #expect(ids.first == f.unsorted)   // pinned, as everywhere else
    }

    /// A greyed row (the collection you are already in) is LISTED — so the list still
    /// reads as the whole tree — but the cursor skips it, because Return on it would
    /// do nothing.
    @Test("the cursor skips the greyed current collection")
    func disabledRowsAreSkipped() {
        let f = folders()
        let ids = CollectionDestinationList.navigableIDs(
            folders: f.all, unsortedID: f.unsorted, disabled: [f.refs])
        #expect(!ids.contains(f.refs))
        #expect(ids.contains(f.type))      // a greyed PARENT keeps its children
        #expect(ids.count == 3)
    }

    @Test("an excluded row is gone from the walk entirely")
    func excludedRowsAreAbsent() {
        let f = folders()
        let ids = CollectionDestinationList.navigableIDs(
            folders: f.all, unsortedID: f.unsorted, excluded: [f.photo])
        #expect(!ids.contains(f.photo))
    }

    /// Clamped, not wrapping: ↓ at the last row must not jump back to Unsorted, which
    /// the list pins first precisely because it is not one of your folders.
    @Test("a step clamps at both ends")
    func stepClamps() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(CollectionDestinationList.step(from: ids[0], in: ids, by: -1) == ids[0])
        #expect(CollectionDestinationList.step(from: ids[2], in: ids, by: 1) == ids[2])
        #expect(CollectionDestinationList.step(from: ids[1], in: ids, by: 1) == ids[2])
        #expect(CollectionDestinationList.step(from: ids[1], in: ids, by: -1) == ids[0])
    }

    /// A cursor that is nowhere yet enters at the end it was heading for.
    @Test("a nil cursor enters at the first row on ↓ and the last on ↑")
    func stepEnters() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(CollectionDestinationList.step(from: nil, in: ids, by: 1) == ids.first)
        #expect(CollectionDestinationList.step(from: nil, in: ids, by: -1) == ids.last)
        #expect(CollectionDestinationList.step(from: nil, in: [], by: 1) == nil)
        // An id that has left the list (a folder deleted under the picker) re-enters
        // rather than stranding the cursor.
        #expect(CollectionDestinationList.step(from: UUID(), in: ids, by: 1) == ids.first)
    }
}
