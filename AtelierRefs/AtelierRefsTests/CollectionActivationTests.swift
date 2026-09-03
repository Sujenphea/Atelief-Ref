//
//  CollectionActivationTests.swift
//  AtelierRefsTests
//
//  259 — select-on-create. Creating a collection from the sidebar must leave THAT
//  collection loaded, so `CollectionView.isLoaded`
//  (`loadedCollectionID == collectionID`) is true and the grid shows content
//  rather than the "Loading collection" skeleton.
//
//  The app wires this in two hops: `createFolder`'s `onCreated` selects the new
//  collection on `NavModel`, and `AppShellView.syncActiveCollection` (deferred a
//  runloop turn by `.onChange`) then points the model at it. These tests drive the
//  same sequence at the model level, both deferred (the real ordering) and
//  synchronous (the worst-case ordering).
//

import AppKit
import AtelierCore
import AtelierIngestion
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("Collection activation (259)")
struct CollectionActivationTests {

    private func makeModel() async throws -> (model: IngestionModel, services: AppServices) {
        let dbPath = NSTemporaryDirectory() + "collection-activation-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let model = IngestionModel(services: services, store: store)
        await model.refreshFolders()
        return (model, services)
    }

    /// Poll until `condition` holds — `loadContents` is fire-and-forget, so there
    /// is no write chain to await.
    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Put the model on `id` the way `AppShellView.syncActiveCollection` does.
    private func activate(_ id: UUID, on model: IngestionModel) {
        if model.selectedFolderID != id { model.selectedFolderID = id }
        model.loadContents(of: id)
    }

    /// Settle the model onto an existing collection, so the "previous collection"
    /// in each test is a real loaded state rather than the initial nil.
    private func settle(on id: UUID, model: IngestionModel) async throws {
        activate(id, on: model)
        #expect(await waitUntil { model.loadedCollectionID == id })
    }

    // MARK: - Create → activate

    @Test("create + activate (deferred, as AppShellView does) loads the NEW collection")
    func createThenDeferredActivateLoadsNew() async throws {
        let (model, services) = try await makeModel()
        let old = try await services.createCollection(name: "temp-01")
        await model.refreshFolders()
        try await settle(on: old.id, model: model)

        var createdID: UUID?
        model.createFolder(name: "Inspiration", parent: nil) { created in
            createdID = created.id
            // `.onChange(of: nav.sidebarSelection)` hops a runloop turn before
            // syncing the model — the real app's ordering.
            DispatchQueue.main.async { activate(created.id, on: model) }
        }

        #expect(await waitUntil { createdID != nil })
        let newID = try #require(createdID)
        #expect(await waitUntil { model.loadedCollectionID == newID },
                "the new collection must be the loaded one — otherwise the grid shows the skeleton")
        #expect(model.selectedFolderID == newID)
    }

    @Test("create + activate SYNCHRONOUSLY still loads the NEW collection")
    func createThenImmediateActivateLoadsNew() async throws {
        let (model, services) = try await makeModel()
        let old = try await services.createCollection(name: "temp-01")
        await model.refreshFolders()
        try await settle(on: old.id, model: model)

        var createdID: UUID?
        model.createFolder(name: "Inspiration", parent: nil) { created in
            createdID = created.id
            activate(created.id, on: model)   // no deferral — worst-case ordering
        }

        #expect(await waitUntil { createdID != nil })
        let newID = try #require(createdID)
        #expect(await waitUntil { model.loadedCollectionID == newID },
                "a trailing reload of the PREVIOUS folder must not win the race")
        #expect(model.selectedFolderID == newID)
    }

    @Test("the sidebar's onCreated activates the model WITHOUT the deferred sync")
    func sidebarCallbackActivatesImmediately() async throws {
        let (model, services) = try await makeModel()
        let old = try await services.createCollection(name: "temp-01")
        await model.refreshFolders()
        try await settle(on: old.id, model: model)

        // Exactly what `CollectionsOutlineCoordinator.endDraft` does — and NOTHING
        // else: `AppShellView.syncActiveCollection` is deliberately not simulated,
        // because the window before it runs is when a pasted URL / Add Color would
        // read a stale `selectedFolderID` and land in the previous collection.
        var createdID: UUID?
        model.createFolder(name: "Inspiration", parent: nil) { created in
            createdID = created.id
            model.selectedFolderID = created.id
        }

        #expect(await waitUntil { createdID != nil })
        let newID = try #require(createdID)
        #expect(model.selectedFolderID == newID,
                "an add-to-current-folder verb fired right now must target the NEW collection")
        #expect(await waitUntil { model.loadedCollectionID == newID },
                "the new collection must load without the deferred sync — else it shows the skeleton")
    }

    // MARK: - The real sidebar flow (coordinator + NSOutlineView)

    /// The first `SidebarDraftCell` materialized in the outline, i.e. the inline
    /// "New Collection" row.
    private func draftCell(in outline: NSOutlineView) -> SidebarDraftCell? {
        for row in 0..<outline.numberOfRows {
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? SidebarDraftCell { return cell }
        }
        return nil
    }

    /// Stand in for SwiftUI's `updateNSView`, which re-runs on every invalidation
    /// of `model.folders` / `nav.sidebarSelection`.
    private func pumpSwiftUI(_ coordinator: CollectionsOutlineCoordinator,
                             _ model: IngestionModel, _ nav: NavModel) {
        coordinator.update(
            folders: model.folders, unsortedID: model.unsortedFolderID,
            selection: nav.sidebarSelection)
    }

    /// End-to-end reproduction of "create a collection in the sidebar, then paste":
    /// commit the inline draft through the real cell callback and let the real
    /// coordinator + `NSOutlineView` react, then assert what `CollectionView` would
    /// bake into a paste — `nav.sidebarSelection`.
    @Test("committing the sidebar draft leaves NAV on the new collection")
    func sidebarDraftCommitSelectsNewCollection() async throws {
        let (model, services) = try await makeModel()
        let old = try await services.createCollection(name: "temp-01")
        await model.refreshFolders()
        let nav = NavModel()
        nav.selectSidebar(.collection(old.id))
        try await settle(on: old.id, model: model)

        let coordinator = CollectionsOutlineCoordinator(
            model: model, nav: nav, palette: PaletteModel(),
            onRename: { _ in }, reportHeight: { _ in })
        let outline = coordinator.makeOutlineView()
        pumpSwiftUI(coordinator, model, nav)

        // "+ New Collection" → type → Return.
        coordinator.beginDraft(parentID: nil)
        let cell = try #require(draftCell(in: outline), "the inline draft row must exist")
        cell.onCommit?("Inspiration")

        // Let the create + refresh land, re-running the SwiftUI update throughout.
        _ = await waitUntil {
            pumpSwiftUI(coordinator, model, nav)
            return model.folders.contains { $0.name == "Inspiration" }
        }
        let newID = try #require(model.folders.first { $0.name == "Inspiration" }?.id)
        // Keep pumping so any deferred outline callback has its chance to land.
        _ = await waitUntil(timeout: 1) {
            pumpSwiftUI(coordinator, model, nav)
            return false
        }

        #expect(nav.sidebarSelection == .collection(newID),
                "nav drives CollectionView.collectionID — a paste targets whatever this says")
        #expect(model.selectedFolderID == newID)
    }

    // MARK: - The paste target (the stale-closure bug)

    /// `CollectionView` has no collection-keyed `.id(...)`, so SwiftUI keeps ONE
    /// view identity across every collection and never re-registers the hidden ⌘V
    /// button's action closure — it stays bound to the `collectionID` captured when
    /// the shortcut was installed. Traced in the running app: three consecutive
    /// pastes all reported the LAUNCH collection while `nav` had long since moved
    /// on. The target must therefore come from `nav` (a reference type, so always
    /// live) at invocation, never from the captured id.
    @Test("the import target follows nav, not a stale captured collectionID")
    func importTargetFollowsNavNotStaleCapture() {
        let stale = UUID()      // what a stale closure would have captured
        let selected = UUID()
        let drilled = UUID()

        #expect(CollectionView.resolveImportTarget(
            path: [], sidebar: .collection(selected), fallback: stale) == selected)

        // A drilled subfolder outranks the sidebar (matches syncActiveCollection).
        #expect(CollectionView.resolveImportTarget(
            path: [.collection(drilled)], sidebar: .collection(selected),
            fallback: stale) == drilled)

        // Non-collection destinations leave the captured id in charge.
        for item in [SidebarItem.home, .capture, .space(UUID())] {
            #expect(CollectionView.resolveImportTarget(
                path: [], sidebar: item, fallback: stale) == stale)
        }
    }

    // MARK: - Import into the freshly created collection

    /// The tail of `run(inputs:)` — reload the folder the batch targeted. `run`
    /// itself needs the (private) ingest coordinator, so this drives the reload
    /// ordering it performs rather than the ingest.
    @Test("reloading the import target leaves that collection loaded")
    func importTargetReloadKeepsTargetLoaded() async throws {
        let (model, services) = try await makeModel()
        let old = try await services.createCollection(name: "temp-01")
        await model.refreshFolders()
        try await settle(on: old.id, model: model)

        var createdID: UUID?
        model.createFolder(name: "Inspiration", parent: nil) { created in
            createdID = created.id
            DispatchQueue.main.async { activate(created.id, on: model) }
        }
        #expect(await waitUntil { createdID != nil })
        let newID = try #require(createdID)
        #expect(await waitUntil { model.loadedCollectionID == newID })

        // Paste lands in the collection the view baked in, then `run` reloads it.
        await model.refreshFolders()
        model.loadContents(of: newID)
        #expect(await waitUntil { model.loadedCollectionID == newID },
                "after an import the target collection must stay the loaded one")
    }
}
