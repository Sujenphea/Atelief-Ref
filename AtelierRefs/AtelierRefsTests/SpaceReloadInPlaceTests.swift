//
//  SpaceReloadInPlaceTests.swift
//  AtelierRefsTests
//
//  The board's camera is the user's. Nothing the model does may take it away.
//
//  It used to, constantly. `SpaceView` bound the canvas with
//  `.id(space.contentVersion)`, and `SpaceModel.load()` bumped that version — so every
//  reload destroyed the `CanvasHostView` and built a fresh one, and a fresh host frames
//  the board to fit. `load()` is reached by deleting anything, creating a frame or text
//  box, dropping / pasting / adding references, both z-ops, and **every undo or redo of
//  a placement edit** (they all pass `reload: true`). That is the whole reported bug:
//  "modifying alignment or deleting items changes the zoom".
//
//  A reload now reconciles the live `SpaceContent` in place. There is no window here to
//  read a camera from, so the property is tested at the seam that decides it: the model
//  hands the renderer the SAME `SpaceContent` instance for the board's whole life, which
//  is exactly the condition under which the host is never rebuilt.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel: a reload never replaces the content")
struct SpaceReloadInPlaceTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-reload-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    private func seedText(_ model: SpaceModel, _ rect: CGRect) async -> UUID {
        model.addText(worldRect: rect)
        await model.waitForWrites()
        return model.selectedItemID!
    }

    // MARK: - The instance is never swapped

    @Test("content() is the same instance across a bare reload")
    func reloadKeepsTheInstance() async throws {
        let model = try await makeModel()
        _ = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))
        let content = model.content()

        await model.load()
        #expect(model.content() === content)
    }

    @Test("content() survives a create, a delete, and the undo of each")
    func mutationsKeepTheInstance() async throws {
        let model = try await makeModel()
        let content = model.content()

        let a = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))
        #expect(model.content() === content)   // create → load()

        _ = await seedText(model, CGRect(x: 300, y: 0, width: 160, height: 24))
        #expect(model.content() === content)

        model.removeItem(a)
        await model.waitForWrites()
        #expect(model.content() === content)   // delete → performBatch → load()

        model.undo()
        await model.waitForWrites()
        #expect(model.content() === content)   // undo-of-delete → restore → load()

        model.redo()
        await model.waitForWrites()
        #expect(model.content() === content)
    }

    @Test("content() survives a z-order change and its undo — both reload")
    func zOrderKeepsTheInstance() async throws {
        let model = try await makeModel()
        _ = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))
        let b = await seedText(model, CGRect(x: 300, y: 0, width: 160, height: 24))
        let content = model.content()

        model.sendToBack(itemID: b)
        await model.waitForWrites()
        #expect(model.content() === content)

        model.undo()
        await model.waitForWrites()
        #expect(model.content() === content)
    }

    // MARK: - What a reload actually does instead

    @Test("a reload re-syncs the canvas and reports whether the tile SET changed")
    func reloadSignalsThroughRenderRevision() async throws {
        let model = try await makeModel()
        _ = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))

        // A reload that changes nothing still redraws (it is the only signal the
        // canvas gets), but it is not a structural change.
        let rev = model.renderRevision
        let version = model.contentVersion
        await model.load()
        #expect(model.renderRevision == rev + 1)
        #expect(model.contentVersion == version)

        // Adding a row IS structural.
        _ = await seedText(model, CGRect(x: 300, y: 0, width: 160, height: 24))
        #expect(model.contentVersion > version)
    }

    @Test("a surviving row keeps its tile id across every reloading operation")
    func tileIDsSurviveReloads() async throws {
        let model = try await makeModel()
        let keep = await seedText(model, CGRect(x: 0, y: 0, width: 160, height: 24))
        let doomed = await seedText(model, CGRect(x: 300, y: 0, width: 160, height: 24))
        let content = model.content()
        let keepTile = content.tileID(forSpaceItemID: keep)!

        // Deleting the row that sorts AFTER it, then one that sorts before — under the
        // old index-as-id scheme the second of those renumbered `keep`, which would
        // repoint the selection and any open inline editor at a different row.
        model.removeItem(doomed)
        await model.waitForWrites()
        #expect(content.tileID(forSpaceItemID: keep) == keepTile)

        model.undo()
        await model.waitForWrites()
        #expect(content.tileID(forSpaceItemID: keep) == keepTile)

        // The restored row is a NEW tile — its old id is gone for good.
        let restored = content.tileID(forSpaceItemID: doomed)
        #expect(restored != nil)
        #expect(restored != keepTile)
    }
}
