//
//  GridSelectionStoreTests.swift
//  AtelierRefsTests
//
//  036 §2 A0 — the selection extraction onto ``GridSelectionStore``. These build a
//  REAL `IngestionModel` over a temp `AppServices` (the `AppUndoTests` harness) to
//  guard the wiring the refactor is most likely to break: the `selectedAssetIDs`
//  cache is now rebuilt from a Combine sink on the store's `$selection` instead of
//  the old `selection.didSet`. `@Published` fires on `willSet`, so a sink that
//  re-read the store's stored `selection` would see the STALE value; the model
//  passes the sink's NEW value instead. This asserts the cache reflects a
//  selection made through the store, and that the computed `model.selection`
//  reads it back consistently.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("GridSelectionStore ↔ IngestionModel (036 A0)")
struct GridSelectionStoreTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "ingest-selstore-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Seed `count` distinct media-less color assets into `collectionID` (mirrors
    /// `AppUndoTests.seedColors`), returning their asset ids in insertion order.
    private func seedColors(_ count: Int, into collectionID: UUID, _ services: AppServices) async throws -> [UUID] {
        var ids: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for i in 0..<count {
            let hex = String(format: "#%02x%02x%02x", (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            let result = try await services.ingestContent(.color(hex: hex), from: source, into: collectionID)
            ids.append(result.asset.id)
        }
        return ids
    }

    /// The classic bug this refactor risks: a selection change made through the
    /// store must land in `IngestionModel.selectedAssetIDs` synchronously. If the
    /// sink read the store's stale `willSet` value instead of the emitted new one,
    /// the cache would come back empty.
    @Test("a store selection updates selectedAssetIDs (willSet/sink timing) and the computed selection")
    func storeSelectionUpdatesCacheAndComputedSelection() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(3, into: folder.id, services)
        let items = try await services.collectionItems(in: folder.id, includeArchived: false)
        model.setItemsForTesting(items)                 // pushes feed order to the store

        let targetItemID = items[1].item.id
        let targetAssetID = items[1].asset.id

        // Baseline: nothing selected → empty cache.
        #expect(model.selectedAssetIDs.isEmpty)

        // Select through the store's reducer seam (the circle-toggle path).
        model.selectionStore.apply(.tapCircle(targetItemID))

        // The sink rebuilt the cache from the NEW selection — not the stale
        // `willSet` value — so the asset id is present.
        #expect(model.selectedAssetIDs == [targetAssetID])
        // And the computed `model.selection` reads the same state back.
        #expect(model.selection.ids == [targetItemID])
        #expect(model.selection.lead == targetItemID)
    }

    /// `IngestionModel.applySelection` must forward to the store and keep the cache
    /// in feed order across a multi-item selection (⌘A).
    @Test("applySelection forwards to the store and keeps selectedAssetIDs in feed order")
    func applySelectionForwardsAndPreservesOrder() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(3, into: folder.id, services)
        let items = try await services.collectionItems(in: folder.id, includeArchived: false)
        model.setItemsForTesting(items)

        model.applySelection(.selectAll)

        #expect(model.selection.ids == Set(items.map { $0.item.id }))
        // Cache mirrors feed order exactly (the old `items.filter…map` contract).
        #expect(model.selectedAssetIDs == items.map { $0.asset.id })
    }

    /// A store-driven lead change (the detail-open path) must reach the computed
    /// `leadItem` — the overlay's source of truth.
    @Test("setLead through the store resolves leadItem")
    func setLeadResolvesLeadItem() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        _ = try await seedColors(2, into: folder.id, services)
        let items = try await services.collectionItems(in: folder.id, includeArchived: false)
        model.setItemsForTesting(items)

        model.selectionStore.setLead(items[0].item.id)

        #expect(model.leadItem?.item.id == items[0].item.id)
    }
}
