//
//  SpaceMultiSelectTests.swift
//  AtelierRefsTests
//
//  049 · D11 — the SpaceModel multi-selection paths over a real (temp)
//  AppServices: a multi-tile move / delete / restack must settle to the right
//  board state AND fold into a SINGLE undo step (the batched-write + coalesced-undo
//  contract), and the selection set must prune to surviving ids on reload. These
//  complement the single-item `SpaceUndoTests` and close the previously untested
//  "Move Group" coalescing at the model level.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel multi-select (049)")
struct SpaceMultiSelectTests {

    private func makeModel() async throws -> (model: SpaceModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "space-multi-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Multi Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return (model, services)
    }

    /// Add three frame elements at distinct z's; returns the model with `items`
    /// z-ordered ([-1, 0, 1] under the frame-behind / element-front rules).
    private func seedThree(_ model: SpaceModel) async {
        model.addFrame(worldRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        await model.waitForWrites()
        model.addText(worldRect: CGRect(x: 10, y: 10, width: 100, height: 100))
        await model.waitForWrites()
        model.addText(worldRect: CGRect(x: 20, y: 20, width: 100, height: 100))
        await model.waitForWrites()
    }

    // MARK: - Multi-move → one undo

    @Test("moving two tiles in one burst settles both and undoes as ONE step")
    func multiMoveOneUndo() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        let ids = model.items.map(\.item.id)
        let t0 = content.tileID(forSpaceItemID: ids[0])!
        let t1 = content.tileID(forSpaceItemID: ids[1])!

        // Two synchronous moves = one burst (the host fires onMoveTile per tile).
        model.moveTile(tileID: t0, to: CGPoint(x: 500, y: 500), in: content)
        model.moveTile(tileID: t1, to: CGPoint(x: 600, y: 600), in: content)
        await model.waitForWrites()
        await model.load()

        #expect(model.items.first { $0.item.id == ids[0] }!.item.x == 500)
        #expect(model.items.first { $0.item.id == ids[1] }!.item.x == 600)
        #expect(model.undoActionName == "Move Group") // coalesced, not two "Move"s

        // ONE undo reverts BOTH tiles, and the NEXT undo is the prior add — proving
        // exactly one step was consumed (the burst is a single undo, not two).
        model.undo()
        await model.waitForWrites()
        #expect(model.items.first { $0.item.id == ids[0] }!.item.x == 0)
        #expect(model.items.first { $0.item.id == ids[1] }!.item.x == 10)
        #expect(model.undoActionName == "Add Text")
        #expect(model.redoActionName == "Move Group")

        // …and ONE redo re-applies BOTH moves.
        model.redo()
        await model.waitForWrites()
        await model.load()
        #expect(model.items.first { $0.item.id == ids[0] }!.item.x == 500)
        #expect(model.items.first { $0.item.id == ids[1] }!.item.x == 600)
    }

    // MARK: - Multi-delete → one undo

    @Test("deleting two rows in one call undoes as ONE step, restoring both")
    func multiDeleteOneUndo() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let ids = model.items.map(\.item.id)

        model.removeItems([ids[0], ids[1]])
        await model.waitForWrites()
        #expect(model.items.count == 1)
        #expect(model.items.first!.item.id == ids[2])
        #expect(model.undoActionName == "Delete Items")

        model.undo()
        await model.waitForWrites()
        #expect(model.items.count == 3)
        #expect(Set(model.items.map(\.item.id)) == Set(ids))
        // Exactly one step consumed — the next undo is the prior add.
        #expect(model.undoActionName == "Add Text")
    }

    @Test("deleting the selection drops those ids from the selection set")
    func deleteClearsSelection() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        let ids = model.items.map(\.item.id)
        let tiles = Set(ids.prefix(2).map { content.tileID(forSpaceItemID: $0)! })
        model.select(tileIDs: tiles, in: content)
        #expect(model.selectedItemIDs == Set(ids.prefix(2)))

        model.removeItems(Set(ids.prefix(2)))
        await model.waitForWrites()
        #expect(model.selectedItemIDs.isEmpty)
    }

    // MARK: - Multi-restack → one undo, relative order preserved

    @Test("bringing a two-tile selection to front preserves their relative order")
    func multiRestackPreservesOrder() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        // items are z-ordered: [back, mid, front]. Select the back two.
        let back = model.items[0].item.id
        let mid = model.items[1].item.id
        let front = model.items[2].item.id
        let tiles = Set([back, mid].map { content.tileID(forSpaceItemID: $0)! })
        model.select(tileIDs: tiles, in: content)

        model.bringSelectionToFront()
        await model.waitForWrites()
        await model.load()

        func z(_ id: UUID) -> Int { model.items.first { $0.item.id == id }!.item.z }
        // Both lifted above the previously-front (unselected) tile…
        #expect(z(back) > z(front))
        #expect(z(mid) > z(front))
        // …with their relative order preserved (back stays behind mid).
        #expect(z(back) < z(mid))
        #expect(model.undoActionName == "Bring to Front")

        model.undo()
        await model.waitForWrites()
        // Original stacking restored: back behind mid behind front.
        #expect(z(back) < z(mid))
        #expect(z(mid) < z(front))
    }

    @Test("restack is a no-op (no undo entry) when the whole board is selected")
    func restackWholeBoardNoOp() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        let allTiles = Set(model.items.map { content.tileID(forSpaceItemID: $0.item.id)! })
        model.select(tileIDs: allTiles, in: content)

        model.bringSelectionToFront()
        await model.waitForWrites()
        // Nothing to sit above → no write, no NEW undo entry (the top of the undo
        // stack is still the last seed add, not a "Bring to Front").
        #expect(model.undoActionName == "Add Text")
    }

    // MARK: - Selection set: pruning + mapping + derived single

    @Test("selection prunes to surviving ids after an external reload")
    func selectionPrunesOnReload() async throws {
        let (model, services) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        let ids = model.items.map(\.item.id)
        let tiles = Set(ids.prefix(2).map { content.tileID(forSpaceItemID: $0)! })
        model.select(tileIDs: tiles, in: content)
        #expect(model.selectedItemIDs.count == 2)

        // Remove one row OUT OF BAND (not via removeItems, which would clear it),
        // then reload — the prune must drop the vanished id.
        try await services.removeSpaceItem(itemID: ids[0])
        await model.load()
        #expect(model.selectedItemIDs == [ids[1]])
    }

    @Test("selectedItemID is the lone id for a single selection, nil for many")
    func derivedSingleSelection() async throws {
        let (model, _) = try await makeModel()
        await seedThree(model)
        let content = model.content()
        let ids = model.items.map(\.item.id)
        let t0 = content.tileID(forSpaceItemID: ids[0])!
        let t1 = content.tileID(forSpaceItemID: ids[1])!

        model.select(tileIDs: [t0], in: content)
        #expect(model.selectedItemID == ids[0])

        model.select(tileIDs: [t0, t1], in: content)
        #expect(model.selectedItemID == nil) // more than one → no single

        model.select(tileIDs: [], in: content)
        #expect(model.selectedItemID == nil)
        #expect(model.selectedItemIDs.isEmpty)
    }
}
