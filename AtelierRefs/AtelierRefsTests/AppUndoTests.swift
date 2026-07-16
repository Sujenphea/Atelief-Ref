//
//  AppUndoTests.swift
//  AtelierRefsTests
//
//  010 · Phase 1 — the IngestionModel app-level undo/redo chain over a real
//  (temp) AppServices. The five reversible destructive verbs (rename, move
//  folder, reorder, remove-from-collection, move-to-collection) register id-based
//  inverses that ping-pong. These assert the round-trips settle to the right DB
//  state, with stable ids and restored ordering across undo↔redo, and that an
//  interleaved edit keeps the inverse correct (id-based, never index-based).
//
//  State is asserted against `AppServices` (the committed truth) after
//  `waitForWrites()`, not the model's fire-and-forget `items` reload.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("IngestionModel undo/redo (010 · Phase 1)")
struct AppUndoTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "ingest-undo-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Seed `count` distinct media-less color assets into `collectionID`, returning
    /// their asset ids in insertion order.
    private func seedColors(_ count: Int, into collectionID: UUID, _ services: AppServices, startIndex: Int = 0) async throws -> [UUID] {
        var ids: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for offset in 0..<count {
            let i = startIndex + offset
            // Distinct hex per asset so dedup (by canonical hex) keeps them separate;
            // callers pass a non-overlapping `startIndex` to guarantee fresh assets.
            let hex = String(format: "#%02x%02x%02x", (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            let result = try await services.ingestContent(.color(hex: hex), from: source, into: collectionID)
            ids.append(result.asset.id)
        }
        return ids
    }

    private func members(of collectionID: UUID, _ services: AppServices) async throws -> [UUID] {
        try await services.collectionItems(in: collectionID).map { $0.asset.id }
    }

    // MARK: - Rename

    @Test("rename folder → undo restores the old name → redo re-applies")
    func renameUndoRedo() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Old")
        await model.refreshFolders()

        model.renameFolder(id: folder.id, to: "New")
        await model.waitForWrites()
        #expect(try await services.getCollection(id: folder.id).name == "New")
        #expect(model.canUndo)

        model.undo()
        await model.waitForWrites()
        #expect(try await services.getCollection(id: folder.id).name == "Old")
        #expect(model.canRedo)

        model.redo()
        await model.waitForWrites()
        #expect(try await services.getCollection(id: folder.id).name == "New")
    }

    // MARK: - Move folder

    @Test("move folder under a parent → undo returns it to root")
    func moveFolderUndo() async throws {
        let (model, services) = try await makeModel()
        let parent = try await services.createCollection(name: "Parent")
        let child = try await services.createCollection(name: "Child")
        await model.refreshFolders()

        model.moveFolder(id: child.id, toParent: parent.id)
        await model.waitForWrites()
        #expect(try await services.getCollection(id: child.id).parentCollectionID == parent.id)

        model.undo()
        await model.waitForWrites()
        #expect(try await services.getCollection(id: child.id).parentCollectionID == nil)

        model.redo()
        await model.waitForWrites()
        #expect(try await services.getCollection(id: child.id).parentCollectionID == parent.id)
    }

    // MARK: - Reorder

    @Test("reorder grid → undo restores the exact prior order")
    func reorderUndoRestoresExactOrder() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Grid")
        let ids = try await seedColors(4, into: folder.id, services)   // [0,1,2,3]
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        // Select the folder and load its items so the verb reads the live order.
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)
        let before = try await members(of: folder.id, services)

        // Move the last item to the front of the target (index of ids[0]).
        model.reorderItems(movingAssetIDs: [ids[3]], toIndexOf: ids[0])
        await model.waitForWrites()
        let after = try await members(of: folder.id, services)
        #expect(after != before)
        #expect(after.first == ids[3])

        model.undo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == before)

        model.redo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == after)
    }

    // MARK: - Remove from collection

    @Test("remove from folder → undo re-adds with the prior order")
    func removeUndoRestoresMembershipAndOrder() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Bin")
        let ids = try await seedColors(3, into: folder.id, services)   // [0,1,2]
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.removeFromFolder(assetIDs: [ids[1]])
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])

        model.undo()
        await model.waitForWrites()
        // Re-added and restored to its original slot (order [0,1,2]).
        #expect(try await members(of: folder.id, services) == ids)

        model.redo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])
    }

    // MARK: - Move to collection

    @Test("move to another folder → undo moves back and restores source order")
    func moveToCollectionUndo() async throws {
        let (model, services) = try await makeModel()
        let source = try await services.createCollection(name: "Source")
        let target = try await services.createCollection(name: "Target")
        let ids = try await seedColors(3, into: source.id, services)
        try await services.setCollectionSortMode(.manual, for: source.id)
        try await services.setGridOrder(collectionID: source.id, orderedAssetIDs: ids)
        model.selectedFolderID = source.id
        try await primeItems(model, folder: source.id, services)

        model.moveToCollection(assetIDs: [ids[1]], to: target.id)
        await model.waitForWrites()
        #expect(try await members(of: source.id, services) == [ids[0], ids[2]])
        #expect(try await members(of: target.id, services) == [ids[1]])

        model.undo()
        await model.waitForWrites()
        #expect(try await members(of: source.id, services) == ids)          // back + reordered
        #expect(try await members(of: target.id, services).isEmpty)

        model.redo()
        await model.waitForWrites()
        #expect(try await members(of: source.id, services) == [ids[0], ids[2]])
        #expect(try await members(of: target.id, services) == [ids[1]])
    }

    // MARK: - Id-based inverse under interleaving

    @Test("an interleaved add doesn't corrupt a pending remove's inverse (id-based)")
    func inverseIsIdBased() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Interleave")
        let ids = try await seedColors(3, into: folder.id, services)   // [0,1,2]
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        // Remove the middle item, then (interleaved) add a brand-new asset.
        model.removeFromFolder(assetIDs: [ids[1]])
        await model.waitForWrites()
        let extra = try await seedColors(1, into: folder.id, services, startIndex: 50)[0]  // fresh asset
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2], extra])

        // Undo must bring back exactly ids[1] (by id), not "whatever is at index 1".
        model.undo()
        await model.waitForWrites()
        let after = try await members(of: folder.id, services)
        #expect(after.contains(ids[1]))
        #expect(after.contains(extra))   // the interleaved add survives the undo
    }

    /// Load the folder's items into the model deterministically so a verb that
    /// reads `items` (reorder / remove / move capture the live order) sees them.
    private func primeItems(_ model: IngestionModel, folder: UUID, _ services: AppServices) async throws {
        model.setItemsForTesting(try await services.collectionItems(in: folder))
    }

    // MARK: - Delete (010 · delete-undo)

    @Test("delete → undo restores the assets + order → redo re-deletes")
    func deleteUndoRedo() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Bin")
        let ids = try await seedColors(3, into: folder.id, services)   // [0,1,2]
        try await services.setCollectionSortMode(.manual, for: folder.id)
        try await services.setGridOrder(collectionID: folder.id, orderedAssetIDs: ids)
        model.selectedFolderID = folder.id

        model.requestDelete(assetIDs: [ids[1]])
        model.confirmPendingDeletion()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])
        #expect(model.canUndo)

        model.undo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == ids)   // back, in order
        #expect(model.canRedo)

        model.redo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [ids[0], ids[2]])
    }

    @Test("delete defers blob reaping — the bytes stay on disk so undo recovers them")
    func deleteDefersReap() async throws {
        let (model, services) = try await makeModel()
        let store = try #require(model.store)
        let folder = try await services.createCollection(name: "Bin")
        let hash = String(repeating: "e", count: 64)
        let a = try await services.ingest(
            AssetDraft(
                kind: .image, blobHash: hash, mimeType: "image/png",
                width: 10, height: 10, duration: nil, fileSize: 4,
                downloadState: .downloaded),
            from: SourceDraft(platform: .web, originalURL: "https://e/x", capturedAt: Date()),
            into: folder.id).asset
        try store.storeBlob(Data("img".utf8), hash: hash, fileExtension: "png")
        model.selectedFolderID = folder.id

        model.requestDelete(assetIDs: [a.id])
        model.confirmPendingDeletion()
        await model.waitForWrites()
        // Removed from the library…
        #expect(try await members(of: folder.id, services).isEmpty)
        // …but the blob was NOT reaped (deferred to the launch GC).
        #expect(store.hasBlob(hash: hash, fileExtension: "png"))

        model.undo()
        await model.waitForWrites()
        #expect(try await members(of: folder.id, services) == [a.id])
        #expect(store.hasBlob(hash: hash, fileExtension: "png")) // media intact
    }
}
