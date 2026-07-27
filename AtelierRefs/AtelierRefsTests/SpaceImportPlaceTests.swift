//
//  SpaceImportPlaceTests.swift
//  AtelierRefsTests
//
//  059 · SP2 / 6A — the shared placement pipeline `SpaceModel.insertPlaced`
//  exercised through both public seams: `addAssets` (flow BELOW content) and
//  `placeDroppedAssets(ids:at:)` (centre on a drop point). Over a real temp
//  AppServices: the batch insert lands rows, the seed positions them, and the
//  placement-only undo (S2) removes them while the underlying asset survives.
//

import AtelierCore
import AtelierIngestion
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel import placement (SP2)")
struct SpaceImportPlaceTests {

    private func makeModel() async throws -> (model: SpaceModel, services: AppServices, spaceID: UUID) {
        let dbPath = NSTemporaryDirectory() + "space-import-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Import Board")
        let model = SpaceModel(spaceID: space.id, services: services, store: store)
        await model.load()
        return (model, services, space.id)
    }

    /// Ingest one 800×600 image into Unsorted and return its `Asset` (aspect 4:3,
    /// so a flowed tile is 320×240 — width = rowHeight × aspect).
    private func makeAsset(
        _ services: AppServices, hash: String, url: String
    ) async throws -> Asset {
        let asset = AssetDraft(
            kind: .image, blobHash: hash, mimeType: "image/png",
            width: 800, height: 600, duration: nil, fileSize: 4096, downloadState: .downloaded)
        let source = SourceDraft(platform: .web, originalURL: url, capturedAt: Date())
        let result = try await services.ingest(asset, from: source, into: services.unsortedFolderID)
        return result.asset
    }

    // MARK: addAssets — flow below content

    @Test("addAssets inserts a batch below content; undo removes, redo restores")
    func addAssetsUndoRedo() async throws {
        let (model, services, _) = try await makeModel()
        let a1 = try await makeAsset(services, hash: "aa0001", url: "https://e.com/1")
        let a2 = try await makeAsset(services, hash: "aa0002", url: "https://e.com/2")

        model.addAssets([a1, a2])
        await model.waitForWrites()
        #expect(model.items.count == 2)
        #expect(model.items.first?.item.y == 0)   // empty board → first row at y=0
        #expect(model.canUndo)
        let createdIDs = Set(model.items.map(\.item.id))

        model.undo()
        await model.waitForWrites()
        #expect(model.items.isEmpty)              // placement-only undo removed both

        model.redo()
        await model.waitForWrites()
        #expect(model.items.count == 2)
        #expect(Set(model.items.map(\.item.id)) == createdIDs) // stable ids
    }

    // MARK: placeDroppedAssets — centre on the drop point

    @Test("a single dropped asset centres its tile on the drop point")
    func dropSingleCentresOnPoint() async throws {
        let (model, services, _) = try await makeModel()
        let a = try await makeAsset(services, hash: "bb0001", url: "https://e.com/a")

        model.placeDroppedAssets(ids: [a.id], at: CGPoint(x: 100, y: 200))
        await model.waitForWrites()
        #expect(model.items.count == 1)
        let item = model.items[0].item
        #expect(abs((item.x + item.w / 2) - 100) < 1e-6)
        #expect(abs((item.y + item.h / 2) - 200) < 1e-6)
    }

    @Test("dropping references is additive + undoable; the asset survives undo (S2)")
    func dropUndoKeepsAsset() async throws {
        let (model, services, _) = try await makeModel()
        let a = try await makeAsset(services, hash: "cc0001", url: "https://e.com/c")

        model.placeDroppedAssets(ids: [a.id], at: CGPoint(x: 0, y: 0))
        await model.waitForWrites()
        #expect(model.items.count == 1)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.isEmpty)                       // placement gone
        // The underlying library asset is untouched by a placement-only undo.
        let stillThere = try await services.getAsset(id: a.id)
        #expect(stillThere.asset.id == a.id)
    }

    @Test("dropping the same asset twice makes two independent placements")
    func dropSameAssetTwice() async throws {
        let (model, services, _) = try await makeModel()
        let a = try await makeAsset(services, hash: "dd0001", url: "https://e.com/d")

        model.placeDroppedAssets(ids: [a.id], at: CGPoint(x: 0, y: 0))
        await model.waitForWrites()
        model.placeDroppedAssets(ids: [a.id], at: CGPoint(x: 500, y: 500))
        await model.waitForWrites()
        #expect(model.items.count == 2)
        #expect(Set(model.items.map(\.item.id)).count == 2)
    }

    @Test("an empty drop and a fully-stale drop are silent no-ops")
    func emptyAndStaleDropNoOp() async throws {
        let (model, _, _) = try await makeModel()
        model.placeDroppedAssets(ids: [], at: CGPoint(x: 0, y: 0))
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        #expect(!model.canUndo)                            // nothing registered

        model.placeDroppedAssets(ids: [UUID()], at: CGPoint(x: 0, y: 0)) // unknown id
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        #expect(!model.canUndo)
    }

    // MARK: importAndPlace — external drop seam (SP3 / 10A, injected fake ingest)

    @Test("importAndPlace places the ingested assets centred on the drop point")
    func importAndPlaceSuccess() async throws {
        let (model, services, _) = try await makeModel()
        let a1 = try await makeAsset(services, hash: "ee0001", url: "https://e.com/e1")
        let a2 = try await makeAsset(services, hash: "ee0002", url: "https://e.com/e2")

        // Fake ingest: stands in for IngestionModel.importInputs, returning assets
        // that already exist in the store (as a real ingest would).
        await model.importAndPlace(at: CGPoint(x: 300, y: 400)) { [a1, a2] }
        await model.waitForWrites()
        #expect(model.items.count == 2)
        // The block's bounding box centres on the point.
        let minX = model.items.map(\.item.x).min()!
        let maxX = model.items.map { $0.item.x + $0.item.w }.max()!
        #expect(abs((minX + maxX) / 2 - 300) < 1e-6)
        #expect(model.canUndo)
    }

    @Test("importAndPlace with a zero-result ingest is a silent no-op")
    func importAndPlaceZeroResults() async throws {
        let (model, _, _) = try await makeModel()
        await model.importAndPlace(at: CGPoint(x: 0, y: 0)) { [] }
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        #expect(!model.canUndo)              // nothing to undo when nothing imported
    }

    @Test("importAndPlace when the space was deleted mid-import: notFound, no crash")
    func importAndPlaceSpaceDeleted() async throws {
        let (model, services, spaceID) = try await makeModel()
        let a = try await makeAsset(services, hash: "ff0001", url: "https://e.com/f")

        // The ingest resolves an asset, but the space is gone by the time the
        // placement runs (a board closed / deleted mid-import). The batch insert
        // throws .notFound; insertPlaced catches it — no crash, no placement.
        try await services.deleteSpace(id: spaceID)
        await model.importAndPlace(at: CGPoint(x: 0, y: 0)) { [a] }
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        #expect(!model.canUndo)              // failed insert registers no undo step
    }

    @Test("importAndPlace is additive + undoable; undo keeps the asset")
    func importAndPlaceUndoKeepsAsset() async throws {
        let (model, services, _) = try await makeModel()
        let a = try await makeAsset(services, hash: "ff0002", url: "https://e.com/g")

        await model.importAndPlace(at: CGPoint(x: 10, y: 10)) { [a] }
        await model.waitForWrites()
        #expect(model.items.count == 1)

        model.undo()
        await model.waitForWrites()
        #expect(model.items.isEmpty)
        let survivor = try await services.getAsset(id: a.id)
        #expect(survivor.asset.id == a.id)   // placement-only undo; asset untouched
    }
}
