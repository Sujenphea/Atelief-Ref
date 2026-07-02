//
//  IngestionModel.swift
//  AtelierRefs
//
//  Chunk 3 (folders) — the app-side model behind the Library tab. It opens (or
//  creates) the on-disk Library under Application Support, holds the folder tree
//  (collections), the selected folder's direct contents + subfolders, and the
//  `IngestCoordinator`. Imports target the CURRENT `selectedFolderID` (default
//  the protected Unsorted folder). Folder create/rename/delete/move go through
//  `AppServices`; thrown `AtelierError`s surface via `lastError` for an alert.
//

import AppKit
import AtelierCore
import AtelierIngestion
import Combine
import SwiftUI

/// A node in the display folder tree, computed from the flat `[Collection]`.
/// `children == nil` marks a leaf (hides the `OutlineGroup` disclosure).
struct FolderNode: Identifiable, Hashable {
    let id: UUID
    let name: String
    var children: [FolderNode]?

    /// Build the root-to-leaf tree from a flat collection list. Roots have a
    /// `nil` parent; children are grouped by `parentCollectionID`, ordered by
    /// name. Empty child sets collapse to `nil` so leaves show no triangle.
    static func tree(from collections: [Collection]) -> [FolderNode] {
        let byParent = Dictionary(grouping: collections, by: { $0.parentCollectionID })
        func nodes(under parent: UUID?) -> [FolderNode]? {
            guard let kids = byParent[parent], !kids.isEmpty else { return nil }
            return kids
                .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
                .map { FolderNode(id: $0.id, name: $0.name, children: nodes(under: $0.id)) }
        }
        return nodes(under: nil) ?? []
    }
}

/// The `@MainActor` view model behind ``LibraryView``: owns the Library
/// (`MediaStore` + `AppServices` + `IngestCoordinator`), the folder tree, the
/// selected folder's contents, and drives ingestion into the selected folder.
@MainActor
final class IngestionModel: ObservableObject {

    // MARK: - Folder tree

    /// Every collection (folder) in the Library, flat. The display tree is
    /// derived via ``folderTree``.
    @Published private(set) var folders: [Collection] = []
    /// The folder imports/browsing target. Defaults to the protected Unsorted
    /// folder (guaranteed by the v2 migration).
    @Published var selectedFolderID: UUID = Collection.unsortedID

    // MARK: - Selected folder contents

    /// The selected folder's DIRECT items (decision F5).
    @Published private(set) var items: [CollectionItemDetail] = []
    /// The selected folder's immediate subfolders (navigable).
    @Published private(set) var subfolders: [Collection] = []

    // MARK: - Selected item (inspector)

    /// The membership id of the item shown in the inspector, or `nil` when
    /// nothing is selected. Cleared automatically when it leaves ``items``.
    @Published private(set) var selectedItemID: UUID?
    /// The selected item's large (1280-tier) preview, loaded OFF-MAIN; `nil`
    /// while loading, when nothing is selected, or if the tier can't be decoded.
    @Published private(set) var previewImage: NSImage?

    // MARK: - Import / status

    /// The in-flight batch's `(completed, total)`, or `nil` when idle.
    @Published private(set) var progress: Progress?
    /// A human-readable status line for the view, or `nil`.
    @Published private(set) var status: String?
    /// The last surfaced error message (drives an `.alert`), or `nil`.
    @Published var lastError: String?
    /// `false` until the Library has opened — import affordances stay disabled.
    @Published private(set) var isReady = false

    /// A batch's progress counters.
    struct Progress: Equatable {
        var completed: Int
        var total: Int
    }

    // The Library, populated once `bootstrap()` completes.
    private var store: MediaStore?
    private var coordinator: IngestCoordinator?
    private var services: AppServices?

    /// The protected default import target (available before the Library opens).
    var unsortedFolderID: UUID { Collection.unsortedID }

    /// The display tree derived from ``folders``.
    var folderTree: [FolderNode] { FolderNode.tree(from: folders) }

    /// Look up a folder's name (for menus / titles).
    func name(for id: UUID) -> String {
        folders.first { $0.id == id }?.name ?? "Folder"
    }

    /// The selected item's detail, resolved from the loaded ``items`` (the
    /// membership id is the source of truth so it survives a contents reload).
    var selectedItem: CollectionItemDetail? {
        guard let selectedItemID else { return nil }
        return items.first { $0.item.id == selectedItemID }
    }

    init() {
        Task { await bootstrap() }
    }

    // MARK: - Bootstrap

    /// Open (or create) the Library under Application Support and wire the
    /// pipeline + coordinator. The v2 migration guarantees the Unsorted folder,
    /// so nothing is seeded here. Loads the folder tree + Unsorted's contents.
    private func bootstrap() async {
        do {
            let root = try LibraryLocation.defaultRoot()
            let layout = LibraryLayout(root: root)
            let store = MediaStore(layout: layout)
            let dbPath = layout.root.appendingPathComponent("library.sqlite").path
            let services = try AppServices(databasePath: dbPath)

            let pipeline = IngestPipeline(store: store, services: services)
            self.store = store
            self.services = services
            self.coordinator = IngestCoordinator(pipeline: pipeline)
            self.selectedFolderID = services.unsortedFolderID
            self.isReady = true
            self.status = "Library ready — paste an image or drop a file."

            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch {
            self.lastError = "Failed to open library: \(error)"
            self.status = "Failed to open library."
        }
    }

    // MARK: - Folder actions

    /// Reload the flat folder list (drives ``folderTree``).
    func refreshFolders() async {
        guard let services else { return }
        do {
            folders = try await services.listCollections()
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Create a folder (root when `parent == nil`, else a subfolder).
    func createFolder(name: String, parent: UUID?) {
        perform { services in _ = try await services.createCollection(name: name, parent: parent) }
    }

    /// Rename a folder. Rejected for Unsorted (`.protectedCollection`).
    func renameFolder(id: UUID, to name: String) {
        guard id != unsortedFolderID else { return }
        perform { services in _ = try await services.renameCollection(id: id, to: name) }
    }

    /// Delete a folder and its whole subtree. Rejected for Unsorted.
    func deleteFolder(id: UUID) {
        guard id != unsortedFolderID else { return }
        perform(after: id == selectedFolderID) { services in
            try await services.deleteCollection(id: id)
        }
    }

    /// Reparent a folder (`nil` ⇒ top level). Rejects cycles / Unsorted.
    func moveFolder(id: UUID, toParent parent: UUID?) {
        guard id != unsortedFolderID else { return }
        perform { services in try await services.moveCollection(id: id, toParent: parent) }
    }

    /// Run a folder mutation, refresh the tree, and (optionally, when the
    /// selected folder was affected) fall back to Unsorted + reload contents.
    /// Thrown `AtelierError`s land in ``lastError``.
    private func perform(
        after selectionInvalidated: Bool = false,
        _ body: @escaping (AppServices) async throws -> Void
    ) {
        guard let services else { return }
        Task {
            do {
                try await body(services)
                await refreshFolders()
                if selectionInvalidated {
                    selectedFolderID = unsortedFolderID
                }
                loadContents(of: selectedFolderID)
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Folder contents

    /// Load the DIRECT items + immediate subfolders of `id` (decision F5).
    func loadContents(of id: UUID) {
        guard let services else { return }
        Task {
            do {
                items = try await services.collectionItems(in: id)
                subfolders = try await services.childCollections(of: id)
                // Drop a selection that no longer exists in the reloaded set
                // (folder switch, or the item was removed).
                if let selectedItemID,
                   !items.contains(where: { $0.item.id == selectedItemID }) {
                    select(nil)
                }
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Selection + inspector

    /// Select `detail` (or clear with `nil`) and load its preview off-main.
    func select(_ detail: CollectionItemDetail?) {
        selectedItemID = detail?.item.id
        previewImage = nil
        guard let detail else { return }
        loadPreview(for: detail)
    }

    /// Load the large (1280-tier) thumbnail for `detail` off-main, then publish
    /// it only if that item is still the selection (guards rapid re-selection).
    private func loadPreview(for detail: CollectionItemDetail) {
        guard let store else { return }
        let targetID = detail.item.id
        let url = store.thumbnailURL(
            hash: detail.asset.blobHash, size: ThumbnailTier.large.rawValue,
            fileExtension: "jpg")
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self, self.selectedItemID == targetID else { return }
                self.previewImage = image
            }
        }
    }

    /// The on-disk full-resolution blob URL for `detail`, rebuilt from the
    /// asset's persisted `mimeType` (round-trips the store-time extension).
    func blobURL(for detail: CollectionItemDetail) -> URL? {
        guard let store else { return nil }
        let ext = ImageMetadata.fileExtension(forMIMEType: detail.asset.mimeType)
        return store.blobURL(hash: detail.asset.blobHash, fileExtension: ext)
    }

    /// Open the selected item's original source URL in the default browser.
    /// A no-op when the source has no (valid) `originalURL`.
    func openSource(_ detail: CollectionItemDetail) {
        guard let string = detail.source.originalURL,
              let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open the full-resolution blob in the default image app (e.g. Preview).
    func openBlob(_ detail: CollectionItemDetail) {
        guard let url = blobURL(for: detail),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal the full-resolution blob in Finder.
    func revealInFinder(_ detail: CollectionItemDetail) {
        guard let url = blobURL(for: detail),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy the selected item's original source URL to the general pasteboard.
    func copySourceLink(_ detail: CollectionItemDetail) {
        guard let string = detail.source.originalURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Load the 512-tier thumbnail for a folder item from the `MediaStore`,
    /// or `nil` if it hasn't been generated / can't be decoded.
    func thumbnail(for detail: CollectionItemDetail) -> NSImage? {
        guard let store else { return nil }
        let url = store.thumbnailURL(
            hash: detail.asset.blobHash, size: ThumbnailTier.medium.rawValue,
            fileExtension: "jpg")
        return NSImage(contentsOf: url)
    }

    // MARK: - Import

    /// Run a batch of inputs through the coordinator OFF-MAIN, then reload the
    /// selected folder's contents + the tree. A no-op if not ready / empty.
    func run(inputs: [IngestInput]) {
        guard isReady, let coordinator, !inputs.isEmpty else { return }
        let total = inputs.count
        progress = Progress(completed: 0, total: total)
        status = "Importing \(total)…"

        Task {
            let outcomes = await coordinator.ingest(inputs) { completed, total in
                Task { @MainActor [weak self] in
                    self?.progress = Progress(completed: completed, total: total)
                }
            }

            var imported = 0
            var failures = 0
            for outcome in outcomes {
                switch outcome {
                case .ingested: imported += 1
                case .failed: failures += 1
                }
            }

            progress = nil
            status = failures == 0
                ? "Imported \(imported)."
                : "Imported \(imported), \(failures) failed."

            await refreshFolders()
            loadContents(of: selectedFolderID)
        }
    }

    // MARK: - Errors

    /// Map an `AtelierError` to a friendly message for the alert.
    private static func message(for error: Error) -> String {
        guard let error = error as? AtelierError else { return error.localizedDescription }
        switch error {
        case .protectedCollection:
            return "The Unsorted folder is protected — it can't be renamed, moved, or deleted."
        case .folderCycle:
            return "Can't move a folder inside itself or one of its own subfolders."
        case .invalidName:
            return "That name isn't valid. Enter a non-empty folder name."
        case .notFound:
            return "That folder no longer exists."
        default:
            return "\(error)"
        }
    }
}
