//
//  HomeCardDeleteTests.swift
//  AtelierRefsTests
//
//  009 · N6 — the Home marquee batch delete (`IngestionModel.deleteCards`) and the
//  single-space recoverable delete extracted from `confirmSpaceDeletion`.
//  Collections delete fire-and-forget (Unsorted guarded); each space deletes
//  recoverably with its own undo. Asserted against `AppServices` (committed truth).
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("IngestionModel: Home card batch delete (009 · N6)")
struct HomeCardDeleteTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "home-delete-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        await model.refreshSpaces()
        return (model, services)
    }

    /// Poll until `condition` holds — folder deletes run on the fire-and-forget
    /// `perform` path, which `waitForWrites()` does NOT await (only the undoable
    /// space/asset write chain is tracked).
    private func eventually(
        timeoutMs: Int = 2000, _ condition: () async throws -> Bool
    ) async throws {
        var waited = 0
        while waited < timeoutMs {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
            waited += 25
        }
        #expect(try await condition())   // final check — records a failure if still false
    }

    @Test("deleteCards removes the selected spaces; each undo restores its board")
    func spacesDeletedAndUndoable() async throws {
        let (model, services) = try await makeModel()
        let one = try await services.createSpace(name: "One")
        let two = try await services.createSpace(name: "Two")

        model.deleteCards(collectionIDs: [], spaceIDs: [one.id, two.id])
        await model.waitForWrites()
        #expect(try await services.listSpaces().isEmpty)
        #expect(model.canUndo)

        // Each space registered its own undo; two undos restore both boards.
        model.undo(); await model.waitForWrites()
        model.undo(); await model.waitForWrites()
        #expect(try await services.listSpaces().map(\.name).sorted() == ["One", "Two"])
    }

    @Test("deleteCards deletes a real collection but never Unsorted")
    func collectionsDeletedGuardingUnsorted() async throws {
        let (model, services) = try await makeModel()
        let doomed = try await services.createCollection(name: "Doomed")
        let unsorted = model.unsortedFolderID

        model.deleteCards(collectionIDs: [unsorted, doomed.id], spaceIDs: [])
        try await eventually {
            try await services.listCollections().contains { $0.id == doomed.id } == false
        }
        // The protected Unsorted root survives the guard.
        #expect(try await services.listCollections().contains { $0.id == unsorted })
    }

    @Test("mixed batch: a collection and a space both delete in one call")
    func mixedBatchDeletesBoth() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Folder")
        let space = try await services.createSpace(name: "Board")

        model.deleteCards(collectionIDs: [folder.id], spaceIDs: [space.id])
        await model.waitForWrites()                       // awaits the space delete
        #expect(try await services.listSpaces().isEmpty)
        try await eventually {                            // folder delete is fire-and-forget
            try await services.listCollections().contains { $0.id == folder.id } == false
        }
    }

    @Test("confirmSpaceDeletion (refactored onto the shared helper) still deletes + undoes")
    func singleSpaceConfirmStillWorks() async throws {
        let (model, services) = try await makeModel()
        let board = try await services.createSpace(name: "Board")

        model.requestDeleteSpace(id: board.id, name: board.name)
        model.confirmSpaceDeletion()
        await model.waitForWrites()
        #expect(try await services.listSpaces().isEmpty)

        model.undo(); await model.waitForWrites()
        #expect(try await services.listSpaces().map(\.name) == ["Board"])
    }
}
