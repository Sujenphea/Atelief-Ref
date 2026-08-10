//
//  AppArchiveTests.swift
//  AtelierRefsTests
//
//  023 · A3 — the `E` verb through the model, over a real (temp) `AppServices`.
//
//  `ShelfIntentTests` pins the pure rule. This file pins what the model does
//  WITH it: that the verb narrows to the ids it actually changes, that the toast
//  counts only those, and that undoing over a mixed selection restores the
//  MIXTURE rather than clearing the lot — which is the property a "just toggle
//  everything" implementation loses while still passing every single-state test.
//
//  Shaped after `AppFavoritesTests`, deliberately: same rule, same convergence,
//  same undo shape, so the two read as one convention rather than two.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("IngestionModel archive + E (023 · A3)")
struct AppArchiveTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "ingest-archive-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    @discardableResult
    private func seedColors(
        _ count: Int, into collectionID: UUID, _ services: AppServices
    ) async throws -> [UUID] {
        var ids: [UUID] = []
        let source = SourceDraft(platform: .localPaste, capturedAt: Date())
        for i in 0..<count {
            let hex = String(
                format: "#%02x%02x%02x",
                (i * 40 + 10) % 256, (i * 17 + 5) % 256, (i * 91 + 3) % 256)
            ids.append(try await services.ingestContent(
                .color(hex: hex), from: source, into: collectionID).asset.id)
        }
        return ids
    }

    private func archived(
        of ids: [UUID], _ services: AppServices
    ) async throws -> Set<UUID> {
        try await services.archivedAssetIDs(among: ids)
    }

    // MARK: - The verb

    @Test("E over an unarchived selection archives all of it")
    func archivesUnarchivedSelection() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()

        #expect(try await archived(of: ids, services) == Set(ids))
        // …and they are gone from the collection's grid read, which is the
        // visible half of what "archived" means.
        #expect(try await services.collectionItems(
            in: folder.id, includeArchived: false).isEmpty)
    }

    @Test("E over an all-archived selection puts it back")
    func unarchivesArchivedSelection() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        try await services.archive(ids)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()

        #expect(try await archived(of: ids, services).isEmpty)
        #expect(try await services.collectionItems(
            in: folder.id, includeArchived: false).count == 2)
    }

    /// The rule's defining case. Two of three archived: E archives the third
    /// rather than unarchiving the two — and the toast counts only the row that
    /// changed, because claiming three writes when one happened is a lie the
    /// undo would then have to keep.
    @Test("E over a MIXED selection archives the rest and counts only the change")
    func mixedSelectionConverges() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.archive([ids[0], ids[1]])
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()

        #expect(try await archived(of: ids, services) == Set(ids))
        #expect(model.lastUndoableAction?.message == "Archived 1 item.")
    }

    @Test("the toast counts a multi-item archive in the plural")
    func toastCountsPlural() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()

        #expect(model.lastUndoableAction?.message == "Archived 3 items.")
    }

    @Test("an empty selection does nothing at all")
    func emptySelectionIsNoOp() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        _ = try await seedColors(1, into: folder.id, services)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: [])
        await model.waitForWrites()

        #expect(model.lastUndoableAction == nil)
    }

    // MARK: - Undo

    @Test("undo puts an archived selection back")
    func undoRestores() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await archived(of: ids, services) == Set(ids))

        model.undo()
        await model.waitForWrites()
        #expect(try await archived(of: ids, services).isEmpty)
    }

    /// The assertion a "toggle them all" implementation fails. Undo must restore
    /// the MIXTURE — the two that were already archived stay archived, because
    /// the verb never touched them and its inverse must not either.
    @Test("undoing a mixed-selection archive restores the mixture, not a clean slate")
    func undoRestoresTheMixture() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.archive([ids[0], ids[1]])
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await archived(of: ids, services) == Set(ids))

        model.undo()
        await model.waitForWrites()

        #expect(try await archived(of: ids, services) == [ids[0], ids[1]])
    }

    @Test("redo re-applies the archive")
    func redoReapplies() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        model.selectedFolderID = folder.id

        await model.toggleArchived(assetIDs: ids)
        await model.waitForWrites()
        model.undo()
        await model.waitForWrites()
        model.redo()
        await model.waitForWrites()

        #expect(try await archived(of: ids, services) == Set(ids))
    }

    // MARK: - Losslessness, from the app's side

    /// The premise, asserted where the user meets it: archiving from the grid
    /// and unarchiving from the shelf leaves the collection exactly as it was,
    /// in the same manual order.
    @Test("archive then unarchive restores the collection's order exactly")
    func roundTripKeepsOrder() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(4, into: folder.id, services)
        model.selectedFolderID = folder.id

        let before = try await services.collectionItems(
            in: folder.id, sort: .manual, includeArchived: false).map(\.asset.id)

        await model.toggleArchived(assetIDs: [ids[1], ids[2]])
        await model.waitForWrites()
        #expect(try await services.collectionItems(
            in: folder.id, sort: .manual, includeArchived: false).map(\.asset.id)
            == [ids[0], ids[3]])

        await model.toggleArchived(assetIDs: [ids[1], ids[2]])
        await model.waitForWrites()

        let after = try await services.collectionItems(
            in: folder.id, sort: .manual, includeArchived: false).map(\.asset.id)
        #expect(after == before)
    }
}
