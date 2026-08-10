//
//  AppFavoritesTests.swift
//  AtelierRefsTests
//
//  011 · U5 — the ⌘D rule and its undo, over a real (temp) `AppServices`.
//
//  The rule under test, stated once here so a future reader does not have to
//  reverse-engineer it from assertions:
//
//      ⌘D over a selection FAVORITES unless every target is already a favorite,
//      in which case it UNFAVORITES all of them.
//
//  Which is to say a MIXED selection converges to "all starred" rather than
//  flipping each item — the only outcome the user can predict without inspecting
//  every tile — and a second ⌘D is still the inverse, so the shortcut reads as a
//  toggle even though it is not a per-item one.
//
//  State is asserted against `AppServices` (the committed truth) after
//  `waitForWrites()`, matching `AppUndoTests`.
//

import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("IngestionModel favorites + ⌘D (011 · U5)")
struct AppFavoritesTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "ingest-fav-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Seed `count` distinct media-less color assets, as `AppUndoTests` does.
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

    /// Load the folder into the model's `items`, so the toggle reads live state.
    private func primeItems(
        _ model: IngestionModel, folder: UUID, _ services: AppServices
    ) async throws {
        model.setItemsForTesting(try await services.collectionItems(in: folder, includeArchived: false))
    }

    private func favorites(
        of ids: [UUID], _ services: AppServices
    ) async throws -> Set<UUID> {
        try await services.favoritedAssetIDs(among: ids)
    }

    // MARK: - The pure rule

    /// The decision itself, with no model, grid or database in the way.
    @Test("wouldFavorite: none / some / all starred")
    func ruleIsPure() {
        let a = UUID(), b = UUID(), c = UUID()
        // Nothing starred → star.
        #expect(IngestionModel.wouldFavorite([a, b, c], favorited: []))
        // MIXED → star (converge), NOT flip.
        #expect(IngestionModel.wouldFavorite([a, b, c], favorited: [b]))
        #expect(IngestionModel.wouldFavorite([a, b, c], favorited: [a, b]))
        // Every target starred → unstar.
        #expect(!IngestionModel.wouldFavorite([a, b, c], favorited: [a, b, c]))
        // Stars OUTSIDE the target set are irrelevant.
        #expect(IngestionModel.wouldFavorite([a], favorited: [b, c]))
        // Nothing to act on.
        #expect(!IngestionModel.wouldFavorite([], favorited: [a]))
    }

    // MARK: - ⌘D over a selection

    @Test("⌘D over an unstarred selection stars all of it")
    func togglesUnstarredSelection() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == Set(ids))
    }

    /// The rule's defining case. Two of three starred: ⌘D stars the third rather
    /// than unstarring the two — and the toast counts only the row that changed.
    @Test("⌘D over a MIXED selection stars the rest, and counts only the change")
    func mixedSelectionConverges() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setFavorite(true, for: [ids[0], ids[1]])
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == Set(ids))
        // One row changed, so the sentence says "1 item" — not "3 items", which
        // would claim two writes that never happened.
        #expect(model.lastUndoableAction?.message == "Favorited 1 item.")
    }

    /// …and the second press is the inverse, which is what keeps ⌘D readable as a
    /// toggle after the convergence above.
    @Test("a second ⌘D unstars the now-uniform selection")
    func secondPressUnstars() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setFavorite(true, for: [ids[0]])
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)          // mixed → all starred
        await model.waitForWrites()
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)          // uniform → all unstarred
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services).isEmpty)
        #expect(model.lastUndoableAction?.message == "Removed 3 items from Favorites.")
    }

    @Test("⌘D over an already-uniform starred selection unstars it")
    func uniformStarredUnstars() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        try await services.setFavorite(true, for: ids)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services).isEmpty)
    }

    /// The command's title has to state what the press will do, or the rule is
    /// only discoverable by trying it.
    @Test("the menu title tracks the rule for the current selection")
    func menuTitleTracksTheRule() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)
        _ = model.applySelection(.selectAll)

        #expect(model.canToggleFavorite)
        #expect(model.favoriteActionWouldStar)        // "Favorite"

        try await services.setFavorite(true, for: ids)
        try await primeItems(model, folder: folder.id, services)
        #expect(!model.favoriteActionWouldStar)       // "Remove from Favorites"
    }

    // MARK: - Undo

    /// Undo restores EXACTLY the prior per-asset state, which for a mixed selection
    /// means the mixture — not "all off". This is the assertion that fails if the
    /// inverse is written against the whole selection instead of the changed rows.
    @Test("undo after a mixed ⌘D restores the mixture, and redo re-applies")
    func undoRestoresTheMixture() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(3, into: folder.id, services)
        try await services.setFavorite(true, for: [ids[1]])
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.toggleFavorite(assetIDs: ids)
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == Set(ids))
        #expect(model.canUndo)

        model.undo()
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == [ids[1]])
        #expect(model.canRedo)

        model.redo()
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == Set(ids))
    }

    @Test("the detail page's explicit set is undoable too")
    func explicitSetIsUndoable() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(1, into: folder.id, services)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        model.setFavorite(true, assetIDs: ids)
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services) == Set(ids))

        model.undo()
        await model.waitForWrites()
        #expect(try await favorites(of: ids, services).isEmpty)
    }

    /// A press with nothing left to change must not land an undo entry — otherwise
    /// ⌘Z after a no-op would silently reverse whatever came before it.
    @Test("a ⌘D that changes nothing registers no undo and no toast")
    func noOpRegistersNothing() async throws {
        let (model, services) = try await makeModel()
        let folder = try await services.createCollection(name: "Refs")
        let ids = try await seedColors(2, into: folder.id, services)
        model.selectedFolderID = folder.id
        try await primeItems(model, folder: folder.id, services)

        // Nothing selected and no lead → nothing to act on.
        model.toggleFavorite(assetIDs: [])
        await model.waitForWrites()
        #expect(!model.canUndo)
        #expect(model.lastUndoableAction == nil)
        #expect(try await favorites(of: ids, services).isEmpty)
    }
}
