//
//  SpaceUndoTests.swift
//  AtelierRefsTests
//
//  005-E3 — the SpaceModel undo/redo chain over a real (temp) AppServices. Every
//  edit funnels through the serialized write queue; undo/redo register inverses
//  that ping-pong. These assert the round-trips settle to the right board state
//  (create / delete / restyle), with stable ids across undo↔redo.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel undo/redo (E3)")
struct SpaceUndoTests {

    private func makeModel() async throws -> (model: SpaceModel, services: AppServices, spaceID: UUID) {
        let dbPath = NSTemporaryDirectory() + "space-undo-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Undo Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load() // deterministic initial state (init's load Task is async)
        return (model, services, space.id)
    }

    @Test("add frame → undo removes it → redo restores it with the same id")
    func createUndoRedo() async throws {
        let (model, _, _) = try await makeModel()

        model.addFrame(worldRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        await model.waitForWrites()
        #expect(model.items.count == 1)
        #expect(model.items.first?.item.kind == .frame)
        let createdID = model.items.first!.item.id
        #expect(model.canUndo)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        #expect(model.canRedo)

        model.redo()
        await model.waitForWrites()
        #expect(model.items.count == 1)
        #expect(model.items.first?.item.id == createdID) // stable id across the cycle
    }

    @Test("delete a text element → undo brings it back verbatim")
    func deleteUndo() async throws {
        let (model, _, _) = try await makeModel()
        model.addText(worldRect: CGRect(x: 10, y: 10, width: 260, height: 72))
        await model.waitForWrites()
        let id = model.items.first!.item.id

        model.removeItem(id)
        await model.waitForWrites()
        #expect(model.items.isEmpty)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.count == 1)
        #expect(model.items.first?.item.id == id)
        #expect(model.items.first?.item.kind == .text)
    }

    @Test("restyle → undo restores the previous style")
    func restyleUndo() async throws {
        let (model, _, _) = try await makeModel()
        model.addText(worldRect: CGRect(x: 0, y: 0, width: 260, height: 72))
        await model.waitForWrites()
        let id = model.items.first!.item.id
        let before = model.style(forItemID: id)

        var edited = before
        edited.text = "Renamed"
        model.updateStyle(itemID: id, style: edited)
        await model.waitForWrites()
        #expect(model.style(forItemID: id).text == "Renamed")

        model.undo()
        await model.waitForWrites()
        #expect(model.style(forItemID: id).text == before.text)
    }

    @Test("writes stay ordered: create then move settles at the moved placement")
    func serializedMove() async throws {
        let (model, _, _) = try await makeModel()
        model.addFrame(worldRect: CGRect(x: 0, y: 0, width: 300, height: 200))
        await model.waitForWrites()
        let content = model.content()
        let tileID = content.tileID(forSpaceItemID: model.items.first!.item.id)!

        model.moveTile(tileID: tileID, to: CGPoint(x: 500, y: 400), in: content)
        await model.waitForWrites()
        // moveTile is reload-free (flicker-free drag); reload to observe the DB.
        await model.load()
        let moved = model.items.first!.item
        #expect(moved.x == 500)
        #expect(moved.y == 400)
        #expect(model.canUndo)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.first!.item.x == 0)
        #expect(model.items.first!.item.y == 0)
    }
}
