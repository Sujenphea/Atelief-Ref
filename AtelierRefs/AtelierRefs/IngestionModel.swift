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
import AtelierServer
import CanvasRenderer
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

    // MARK: - Capture endpoint (Chrome extension)

    /// The shared-secret the extension must present (shown in the UI so the user
    /// can paste it into the extension's options). Empty until the Library opens.
    @Published private(set) var captureToken: String = ""
    /// The loopback port the capture endpoint listens on.
    let capturePort = CaptureServer.defaultPort
    /// Whether the capture endpoint bound successfully (false if the port was in
    /// use). Drives a hint in the UI.
    @Published private(set) var captureEndpointRunning = false

    // The Library, populated once `bootstrap()` completes.
    private var store: MediaStore?
    private var coordinator: IngestCoordinator?
    private var services: AppServices?
    private var captureServer: CaptureServer?

    /// Downloads a bare image URL (drag/paste with no bytes) off-main. Stateless +
    /// injectable; the default uses the shared session (tests inject a stub one).
    private let remoteFetcher = RemoteImageFetcher()

    /// UserDefaults key persisting the capture token across launches.
    private static let captureTokenKey = "AtelierCaptureToken"

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

    /// A pending destructive delete awaiting the user's confirmation. Set by the
    /// three delete surfaces (inspector / grid / canvas); drives one shared
    /// confirmation dialog in ``ContentView``.
    @Published var pendingDeletion: PendingDeletion?

    /// The assets a confirmed delete will remove entirely from the library.
    struct PendingDeletion {
        let assetIDs: [UUID]
        /// How many items — for the confirmation copy.
        var count: Int { assetIDs.count }
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
            let coordinator = IngestCoordinator(pipeline: pipeline)
            self.store = store
            self.services = services
            self.coordinator = coordinator
            self.selectedFolderID = services.unsortedFolderID
            self.isReady = true
            self.status = "Library ready — paste an image or drop a file."

            await refreshFolders()
            loadContents(of: selectedFolderID)
            await startCaptureEndpoint(coordinator: coordinator)
        } catch {
            self.lastError = "Failed to open library: \(error)"
            self.status = "Failed to open library."
        }
    }

    // MARK: - Capture endpoint

    /// Start the localhost capture endpoint the Chrome extension POSTs to. Runs
    /// off the launch path; a bind failure (port already in use) is surfaced as a
    /// hint, never fatal — the app is fully usable without the extension.
    ///
    /// Captures ingest through the SAME bounded coordinator as paste/drag (no new
    /// queue), defaulting to the protected Unsorted folder when the request omits
    /// a target. `onCapture` hops to the main actor to refresh the live UI (CQ1).
    private func startCaptureEndpoint(coordinator: IngestCoordinator) async {
        let token = loadOrCreateCaptureToken()
        self.captureToken = token

        let routes = CaptureRoutes(
            coordinator: coordinator,
            defaultCollectionID: { Collection.unsortedID },
            onCapture: { [weak self] collectionID, outcomes in
                Task { @MainActor in
                    self?.handleRemoteCapture(collectionID: collectionID, outcomes: outcomes)
                }
            })
        let server = CaptureServer(auth: CaptureAuth(token: token), routes: routes)
        self.captureServer = server

        do {
            try await server.start()
            captureEndpointRunning = true
            status = "Library ready — capture endpoint on 127.0.0.1:\(capturePort)."
        } catch {
            captureEndpointRunning = false
            status = "Library ready. Capture endpoint unavailable (port \(capturePort) in use)."
        }
    }

    /// Refresh the live UI after a browser capture: reload the visible folder when
    /// it received the item, and always refresh the tree's counts. Runs on the
    /// main actor (hopped from the server's off-main callback).
    private func handleRemoteCapture(collectionID: UUID, outcomes: [IngestOutcome]) {
        let imported = outcomes.reduce(into: 0) { count, outcome in
            if case .ingested = outcome { count += 1 }
        }
        Task { await refreshFolders() }
        if collectionID == selectedFolderID {
            loadContents(of: selectedFolderID)
        }
        status = imported > 0
            ? "Captured \(imported) from the browser."
            : "A browser capture failed."
    }

    /// Load the persisted capture token, generating and storing one on first run.
    private func loadOrCreateCaptureToken() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.captureTokenKey),
           !existing.isEmpty {
            return existing
        }
        let token = CaptureToken.generate()
        defaults.set(token, forKey: Self.captureTokenKey)
        return token
    }

    /// Copy the capture token to the pasteboard (for pasting into the extension).
    func copyCaptureToken() {
        guard !captureToken.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captureToken, forType: .string)
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
                contentsVersion &+= 1
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Reorder (drag-to-reorder)

    /// Move the item with `movingAssetID` to the grid slot currently held by
    /// `targetAssetID`, within the selected folder. OPTIMISTIC: reorders the local
    /// ``items`` immediately for feedback, then persists the new full order via
    /// `setGridOrder` (the write hops OFF the main actor). On failure the message
    /// surfaces via ``lastError`` and the folder reloads to the truth; on success
    /// it reloads too (core sorts by `manual_order`, so state stays consistent).
    /// A no-op when the ids match or either isn't a current item (foreign drop).
    func reorderItem(movingAssetID: UUID, toIndexOf targetAssetID: UUID) {
        guard let services else { return }
        let currentIDs = items.map { $0.asset.id }
        guard let newOrder = reorderedIDs(
            ids: currentIDs, movingID: movingAssetID, toIndexOf: targetAssetID)
        else { return }

        // Optimistic local reorder — rebuild `items` in the new order.
        let byAssetID = Dictionary(uniqueKeysWithValues: items.map { ($0.asset.id, $0) })
        items = newOrder.compactMap { byAssetID[$0] }
        contentsVersion &+= 1

        let folder = selectedFolderID
        Task {
            do {
                try await services.setGridOrder(
                    collectionID: folder, orderedAssetIDs: newOrder)
            } catch {
                lastError = Self.message(for: error)
            }
            // Reload to the persisted truth either way (core sorts by manual_order).
            loadContents(of: folder)
        }
    }

    // MARK: - Canvas drag-to-place

    /// Move a canvas tile to `worldOrigin` and PERSIST the placement. The tile's
    /// current `w/h/z` are re-persisted alongside the new `x/y` so the placement
    /// "pins" the tile at its dropped size — a later provider rebuild (folder
    /// switch / relaunch) then honours `canvas_*` and reproduces it exactly.
    ///
    /// The in-memory `content.setPlacement` runs synchronously (so the tile stays
    /// put, no snap-back / viewport reset — the renderer reads it next `sync()`);
    /// the DB write hops OFF the main actor and surfaces failures via `lastError`.
    /// A no-op if the tile can't be resolved to a current asset.
    func moveCanvasTile(tileID: Int, to worldOrigin: CGPoint) {
        guard let services, let content = cachedCanvasContent,
              let detail = content.detail(forTileID: tileID),
              content.tiles.indices.contains(tileID) else { return }

        let assetID = detail.asset.id
        let folder = selectedFolderID
        let tile = content.tiles[tileID]
        let (w, h, z) = (tile.w, tile.h, tile.z)
        let x = Double(worldOrigin.x)
        let y = Double(worldOrigin.y)

        // In-memory update first — keeps the tile exactly where it was dropped.
        content.setPlacement(tileID: tileID, x: x, y: y)

        Task {
            do {
                try await services.setCanvasPlacement(
                    collectionID: folder, assetID: assetID,
                    x: x, y: y, w: w, h: h, z: z)
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

    // MARK: - Remove / delete assets

    /// Remove assets from the CURRENT folder only (membership drop) — the asset,
    /// its bytes, and its memberships elsewhere are untouched. Non-destructive and
    /// reversible, so it runs immediately without confirmation.
    func removeFromFolder(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        let folder = selectedFolderID
        mutateContents { services in
            try await services.removeAssets(assetIDs, from: folder)
            return "Removed \(Self.itemCount(assetIDs.count)) from “\(self.name(for: folder))”."
        }
    }

    /// Remove the inspector's currently-selected item from the current folder.
    func removeSelectedFromFolder() {
        guard let detail = selectedItem else { return }
        removeFromFolder(assetIDs: [detail.asset.id])
    }

    /// Stage a destructive delete for confirmation (see ``confirmPendingDeletion``).
    /// A no-op for an empty set.
    func requestDelete(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        pendingDeletion = PendingDeletion(assetIDs: assetIDs)
    }

    /// Stage a delete of the inspector's currently-selected item.
    func requestDeleteSelected() {
        guard let detail = selectedItem else { return }
        requestDelete(assetIDs: [detail.asset.id])
    }

    /// Dismiss the pending delete without acting.
    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    /// Carry out the confirmed delete: remove the assets from the library, move
    /// any now-orphaned blob/thumbnail files to the Trash (off-main), then refresh
    /// the tree + current folder. Clears the pending state first so the dialog
    /// dismisses immediately.
    func confirmPendingDeletion() {
        guard let store, let pending = pendingDeletion else { return }
        pendingDeletion = nil
        let assetIDs = pending.assetIDs
        mutateContents { services in
            let orphans = try await services.deleteAssets(assetIDs)
            // File IO off the main actor; the DB delete is already committed, so
            // this is best-effort cleanup (MediaReaper swallows per-file errors).
            let reaper = MediaReaper(store: store)
            _ = await Task.detached { reaper.reap(orphans) }.value
            return "Deleted \(Self.itemCount(assetIDs.count))."
        }
    }

    /// Run an asset mutation that changes the current folder's contents, then
    /// refresh the tree + reload the folder and publish `body`'s status line.
    /// Thrown `AtelierError`s land in ``lastError``. (The folder-scoped `perform`
    /// also resets the selected folder; asset mutations never need that.)
    private func mutateContents(_ body: @escaping (AppServices) async throws -> String) {
        guard let services else { return }
        Task {
            do {
                let message = try await body(services)
                await refreshFolders()
                loadContents(of: selectedFolderID)
                status = message
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// "1 item" / "N items" for status + confirmation copy.
    private static func itemCount(_ n: Int) -> String {
        "\(n) item\(n == 1 ? "" : "s")"
    }

    // MARK: - Canvas content

    /// Bumped whenever the selected folder's ``items`` change, so the Canvas tab
    /// can rebuild its view (via SwiftUI `.id`) to reflect the new set.
    @Published private(set) var contentsVersion = 0

    private var cachedCanvasContent: CanvasContent?
    private var cachedCanvasVersion = -1

    /// Canvas content for the currently loaded folder items — rebuilt only when
    /// ``contentsVersion`` changes (SwiftUI re-evaluates `body` often, and the
    /// layout pass is not free). `nil` before the Library opens or when empty.
    func canvasContent() -> CanvasContent? {
        if cachedCanvasVersion == contentsVersion { return cachedCanvasContent }
        cachedCanvasVersion = contentsVersion
        guard let store, !items.isEmpty else {
            cachedCanvasContent = nil
            return nil
        }
        cachedCanvasContent = CanvasContent(items: items, store: store)
        return cachedCanvasContent
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

    /// Download a BARE image URL (a drag/paste that carried a URL but no bytes —
    /// e.g. a Pinterest image), then ingest it as `.web` provenance through the
    /// same batch path as everything else. The network fetch runs OFF-MAIN (the
    /// fetcher's `await`s hop off this actor); progress + failure surface through
    /// the existing `status` / `lastError` infra. A no-op if not ready.
    func ingestRemoteImage(from url: URL) {
        guard isReady else { return }
        let target = selectedFolderID
        let fetcher = remoteFetcher
        status = "Downloading image…"
        Task {
            do {
                let input = try await fetcher.ingestInput(for: url, into: target, at: Date())
                run(inputs: [input])
            } catch {
                status = Self.remoteFetchStatus(for: error)
            }
        }
    }

    /// Report a drop the app couldn't read at all (no image bytes, no file, no
    /// downloadable image URL) — no more silent no-op (backlog B1).
    func reportUnreadableDrop() {
        status = "Couldn't read that drop — no image, file, or image URL."
    }

    /// A friendly status line for a failed remote-image download.
    private static func remoteFetchStatus(for error: Error) -> String {
        guard let error = error as? RemoteImageFetchError else {
            return "Couldn't download that image."
        }
        switch error {
        case .notAnImage:
            return "That link isn't a direct image."
        case .tooLarge:
            return "That image is too large to import."
        case .invalidURL, .requestFailed, .httpStatus:
            return "Couldn't download that image."
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
