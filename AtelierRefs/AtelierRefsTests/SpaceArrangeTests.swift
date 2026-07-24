//
//  SpaceArrangeTests.swift
//  AtelierRefsTests
//
//  051 Phase 1 [10A / 11A] — `SpaceModel.arrange(_:)` over the real (temp)
//  AppServices harness (like `SpaceUndoTests`). The pure geometry is proven in
//  `CanvasArrangeTests`; these pin the MODEL contract: an align/distribute of N
//  is ONE batched write + ONE undo step, undo restores all N, redo reapplies, a
//  no-op registers no undo, distribute needs 3, only x/y move (w/h/z preserved),
//  and the selection survives. Plus the align→undo→move interleaving through the
//  shared placement path.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel arrange (051 · 10A/11A)")
struct SpaceArrangeTests {

    private func makeModel() async throws -> (model: SpaceModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "space-arrange-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Arrange Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return (model, services)
    }

    /// Add a frame per rect; returns the created ids in rect order (each add selects
    /// the new element, so `selectedItemID` is that row's id).
    private func seed(_ model: SpaceModel, _ rects: [CGRect]) async -> [UUID] {
        var ids: [UUID] = []
        for r in rects {
            model.addFrame(worldRect: r)
            await model.waitForWrites()
            ids.append(model.selectedItemID!)
        }
        return ids
    }

    /// Select every seeded id (via its tile) so `arrange` acts on the whole set.
    private func selectAll(_ model: SpaceModel, _ ids: [UUID]) {
        let content = model.content()
        model.select(tileIDs: Set(ids.map { content.tileID(forSpaceItemID: $0)! }), in: content)
    }

    private func item(_ model: SpaceModel, _ id: UUID) -> SpaceItem {
        model.items.first { $0.item.id == id }!.item
    }

    // MARK: - Align integration

    @Test("align-left of three: one undo step restores all; redo reapplies; selection survives")
    func alignLeftIntegration() async throws {
        let (model, _) = try await makeModel()
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 200, y: 50, width: 60, height: 80),
                     CGRect(x: 400, y: 300, width: 120, height: 40)]
        let ids = await seed(model, rects)
        selectAll(model, ids)
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, item(model, $0)) })

        model.arrange(.alignLeft)
        await model.waitForWrites()
        #expect(model.selectedItemIDs == Set(ids)) // selection survives (reload-free forward)
        await model.load()

        // Every minX pinned to the bbox left (0); y / w / h / z preserved.
        for id in ids {
            let now = item(model, id)
            let was = before[id]!
            #expect(now.x == 0)
            #expect(now.y == was.y)
            #expect(now.w == was.w)
            #expect(now.h == was.h)
            #expect(now.z == was.z)
        }
        #expect(model.undoActionName == "Align Left")

        // ONE undo reverts ALL three; the NEXT undo is the prior add → exactly one step.
        model.undo()
        await model.waitForWrites()
        for id in ids { #expect(item(model, id).x == before[id]!.x) }
        #expect(model.undoActionName == "Add Frame")

        // ONE redo reapplies to all three.
        model.redo()
        await model.waitForWrites()
        await model.load()
        for id in ids { #expect(item(model, id).x == 0) }
    }

    @Test("align-bottom moves only y; x / w / h / z untouched")
    func alignBottomTouchesOnlyY() async throws {
        let (model, _) = try await makeModel()
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 40),
                     CGRect(x: 50, y: 100, width: 60, height: 200),
                     CGRect(x: 120, y: 20, width: 80, height: 80)]
        let ids = await seed(model, rects)
        selectAll(model, ids)
        let before = Dictionary(uniqueKeysWithValues: ids.map { ($0, item(model, $0)) })
        let bottom = before.values.map { $0.y + $0.h }.max()!

        model.arrange(.alignBottom)
        await model.waitForWrites()
        await model.load()
        for id in ids {
            let now = item(model, id), was = before[id]!
            #expect(now.y + now.h == bottom) // bottom edge aligned to the box bottom
            #expect(now.x == was.x)          // x frozen
            #expect(now.w == was.w)
            #expect(now.z == was.z)
        }
    }

    // MARK: - Distribute integration

    @Test("distribute horizontally equalises gaps as ONE undo step")
    func distributeHorizontalIntegration() async throws {
        let (model, _) = try await makeModel()
        // A(0..100) B(200..260) C(500..620): span 620, widths 280, free 340, gap 170.
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 200, y: 0, width: 60, height: 100),
                     CGRect(x: 500, y: 0, width: 120, height: 100)]
        let ids = await seed(model, rects)
        selectAll(model, ids)

        model.arrange(.distributeHorizontal)
        await model.waitForWrites()
        await model.load()
        #expect(item(model, ids[0]).x == 0)   // first anchor fixed
        #expect(item(model, ids[1]).x == 270) // 100 + gap(170)
        #expect(item(model, ids[2]).x == 500) // last anchor fixed
        #expect(model.undoActionName == "Distribute Horizontally")

        model.undo()
        await model.waitForWrites()
        #expect(item(model, ids[1]).x == 200) // restored
        #expect(model.undoActionName == "Add Frame")
    }

    @Test("distribute of fewer than three items is a no-op (no write, no undo)")
    func distributeUnderThreeNoOp() async throws {
        let (model, _) = try await makeModel()
        let ids = await seed(model, [CGRect(x: 0, y: 0, width: 50, height: 50),
                                     CGRect(x: 300, y: 0, width: 50, height: 50)])
        selectAll(model, ids)

        model.arrange(.distributeHorizontal)
        await model.waitForWrites()
        // Unchanged, and the top of the undo stack is still the last add.
        #expect(item(model, ids[0]).x == 0)
        #expect(item(model, ids[1]).x == 300)
        #expect(model.undoActionName == "Add Frame")
    }

    // MARK: - No-op guard

    @Test("aligning already-aligned items registers no undo entry")
    func noOpAlignRegistersNoUndo() async throws {
        let (model, _) = try await makeModel()
        // All share minX == 10 already → align-left is a no-op.
        let ids = await seed(model, [CGRect(x: 10, y: 0, width: 40, height: 40),
                                     CGRect(x: 10, y: 100, width: 60, height: 20),
                                     CGRect(x: 10, y: 200, width: 20, height: 80)])
        selectAll(model, ids)
        let undoName = model.undoActionName // the last add

        model.arrange(.alignLeft)
        await model.waitForWrites()
        #expect(model.undoActionName == undoName) // no new undo entry
        for id in ids { #expect(item(model, id).x == 10) } // positions unchanged
    }

    // MARK: - Interleaving (11A)

    @Test("align → undo → move interleave correctly through the shared write chain")
    func alignUndoMoveInterleave() async throws {
        let (model, _) = try await makeModel()
        let rects = [CGRect(x: 0, y: 0, width: 100, height: 100),
                     CGRect(x: 200, y: 50, width: 100, height: 100),
                     CGRect(x: 400, y: 90, width: 100, height: 100)]
        let ids = await seed(model, rects)
        selectAll(model, ids)

        let startX = Dictionary(uniqueKeysWithValues: zip(ids, rects.map { Double($0.minX) }))

        model.arrange(.alignLeft) // all x → 0
        await model.waitForWrites()

        model.undo() // back to original x (reload:true)
        await model.waitForWrites()
        for id in ids { #expect(item(model, id).x == startX[id]!) }

        // Now move one tile — a reload-free geometry write immediately after the
        // align's reload:true undo, both flowing through applyPlacementEdit.
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: ids[1])!
        model.moveTile(tileID: tid, to: CGPoint(x: 900, y: 700), in: content)
        await model.waitForWrites()
        await model.load()
        #expect(item(model, ids[1]).x == 900)
        #expect(item(model, ids[1]).y == 700)
        // The others stayed at their restored positions.
        #expect(item(model, ids[0]).x == 0)
        #expect(item(model, ids[2]).x == 400)
    }
}
