//
//  SpacePlacedItemsTests.swift
//  AtelierRefsTests
//
//  052 · B3 — `SpaceModel.placedItems` is the EXPORT seam: it must carry each
//  row's LIVE placement, not the `items` array (which a reload-free drag /
//  arrange leaves holding stale pre-move x/y/z). These pin that contract over the
//  real (temp) AppServices harness, the same way `SpaceArrangeTests` does — a
//  regression here is exactly "some items export at their old position".
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel placedItems (export seam)")
struct SpacePlacedItemsTests {

    private func makeModel() async throws -> SpaceModel {
        let dbPath = NSTemporaryDirectory() + "space-placed-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Placed Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return model
    }

    private func seed(_ model: SpaceModel, _ rects: [CGRect]) async -> [UUID] {
        var ids: [UUID] = []
        for r in rects {
            model.addFrame(worldRect: r)
            await model.waitForWrites()
            ids.append(model.selectedItemID!)
        }
        return ids
    }

    // MARK: - The regression

    @Test("A reload-free drag leaves items stale but placedItems carries the live position")
    func placedItemsReflectsLiveDrag() async throws {
        let model = try await makeModel()
        let id = (await seed(model, [CGRect(x: 0, y: 0, width: 100, height: 100)]))[0]

        // Drag the tile: moves it in the in-memory content and persists reload:false.
        let content = model.content()
        let tid = content.tileID(forSpaceItemID: id)!
        model.moveTile(tileID: tid, to: CGPoint(x: 500, y: 300), in: content)
        await model.waitForWrites()

        // `items` still holds the pre-move origin — the divergence the export bug rode.
        let stale = model.items.first { $0.item.id == id }!.item
        #expect(stale.x == 0)
        #expect(stale.y == 0)

        // `placedItems` carries the LIVE position export must use.
        let placed = model.placedItems.first { $0.item.id == id }!.item
        #expect(placed.x == 500)
        #expect(placed.y == 300)
        // Only x/y moved — w/h/z ride through unchanged.
        #expect(placed.w == 100)
        #expect(placed.h == 100)
        #expect(placed.z == stale.z)
    }

    // MARK: - Consistency + fidelity

    @Test("After a reload placedItems equals the stored items geometry")
    func placedItemsMatchesItemsAfterReload() async throws {
        let model = try await makeModel()
        _ = await seed(model, [CGRect(x: 10, y: 20, width: 30, height: 40)])
        await model.load()  // fresh from DB → no live/stale gap

        let placed = model.placedItems.first!.item
        let stored = model.items.first!.item
        #expect(placed.x == stored.x)
        #expect(placed.y == stored.y)
        #expect(placed.w == stored.w)
        #expect(placed.h == stored.h)
        #expect(placed.z == stored.z)
    }

    @Test("placedItems preserves identity, kind, and style; count matches items")
    func placedItemsPreservesNonGeometry() async throws {
        let model = try await makeModel()
        let ids = await seed(model, [CGRect(x: 0, y: 0, width: 40, height: 40),
                                     CGRect(x: 100, y: 0, width: 40, height: 40)])

        let placed = model.placedItems
        #expect(placed.count == model.items.count)
        #expect(Set(placed.map { $0.item.id }) == Set(ids))
        for detail in placed {
            let source = model.items.first { $0.item.id == detail.item.id }!.item
            #expect(detail.item.kind == source.kind)
            #expect(detail.item.style == source.style)  // frame label survives
        }
    }
}
