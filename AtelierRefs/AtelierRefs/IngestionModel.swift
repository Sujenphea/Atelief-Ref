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
import OSLog
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

    // The Library, populated once `bootstrap()` completes. `store` / `services`
    // are read-only outside the model so a per-open-space ``SpaceModel`` can be
    // built against them (005-E2) without exposing the mutable wiring.
    private(set) var store: MediaStore?
    private var coordinator: IngestCoordinator?
    private(set) var services: AppServices?
    private var captureServer: CaptureServer?

    /// Monotonic id for ``loadContents(of:)`` so a slow read can never clobber a
    /// newer one (fast folder switch, or a mutation-triggered reload).
    private var contentsLoadID = 0

    /// Downloads a bare image URL (drag/paste with no bytes) off-main. Stateless +
    /// injectable; the default uses the shared session (tests inject a stub one).
    private let remoteFetcher = RemoteImageFetcher()

    /// Ingest-timing log (16A). A stall means generating the eager thumbnail tiers
    /// dominated the ingest — the signal to make the largest tier lazy (P16).
    private static let ingestLog = Logger(subsystem: "so.atelier.refs", category: "ingest-timing")
    /// Above this thumbnail-phase time (ms) we log a stall. Tuned to catch the
    /// decode-heavy large tier without noise on ordinary small images.
    private static let thumbnailStallMs = 250.0

    /// The pipeline's timing sink: log only a thumbnail STALL (keeps the log quiet
    /// on the common fast path + the P14 short-circuit). `@Sendable` static — no
    /// captured state, so it's safe to hand to the off-main pipeline.
    @Sendable private static func logIngestTiming(_ timing: IngestTiming) {
        guard timing.thumbnailMillis >= thumbnailStallMs else { return }
        let thumbMs = Int(timing.thumbnailMillis)
        let totalMs = Int(timing.totalMillis)
        let tiers = timing.tiersGenerated
        ingestLog.notice("thumbnail stall: \(thumbMs)ms for \(tiers) tiers (total \(totalMs)ms)")
    }

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

            // Phase 8 (16A): log a thumbnail stall — the measured trigger for the
            // P16 lazy-tier lever (added only IF a real bulk sweep shows the stall).
            let pipeline = IngestPipeline(
                store: store, services: services, timing: Self.logIngestTiming)
            let coordinator = IngestCoordinator(pipeline: pipeline)
            self.store = store
            self.services = services
            self.coordinator = coordinator
            self.selectedFolderID = services.unsortedFolderID
            self.isReady = true
            self.status = "Library ready — paste an image or drop a file."

            // Any sweep still "open" at launch is abandoned (nothing is running yet),
            // so reconcile it to paused — otherwise a tab closed mid-sweep last session
            // would show as a phantom "running" job forever.
            try? await services.pauseStaleOpenJobs(olderThan: 0, now: Date())

            // Enforce known ⟺ blob present: forget any ledger row whose blob was
            // removed outside deleteAssets, so a future sweep re-imports that source
            // instead of dedup-skipping bytes that are gone.
            try? await services.reconcileOrphanedKnownItems()

            await refreshFolders()
            loadContents(of: selectedFolderID)
            await startCaptureEndpoint(coordinator: coordinator, services: services)
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
    ///
    /// `services` doubles as the bulk-import `JobLedger` (015 · 3A): it backs the
    /// `/jobs` handshake and records a `job_item` for every capture tagged with a
    /// `jobId`+`sourceId`. Untagged single-item captures are unaffected.
    private func startCaptureEndpoint(
        coordinator: IngestCoordinator, services: AppServices
    ) async {
        let token = loadOrCreateCaptureToken()
        self.captureToken = token

        let routes = CaptureRoutes(
            coordinator: coordinator,
            defaultCollectionID: { Collection.unsortedID },
            onCapture: { [weak self] collectionID, outcomes in
                Task { @MainActor in
                    self?.handleRemoteCapture(collectionID: collectionID, outcomes: outcomes)
                }
            },
            jobLedger: services)
        // The extension reads these caps at job-open instead of hardcoding (8A).
        // `consentGranted` gates the first sweep (7A) — it reads the SAME persisted
        // flag the in-app consent toggle writes, so the server refuses `/jobs` until
        // the user accepts. Reads UserDefaults directly (thread-safe, no actor hop).
        let jobRoutes = JobRoutes(
            ledger: services,
            caps: CapsDTO(
                maxBodyBytes: CaptureServer.defaultMaxBodyBytes,
                maxVideoBodyBytes: CaptureServer.defaultMaxVideoBodyBytes),
            consentGranted: { UserDefaults.standard.bool(forKey: Self.bulkConsentKey) })
        let server = CaptureServer(
            auth: CaptureAuth(token: token), routes: routes, jobRoutes: jobRoutes)
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

    /// Load the persisted capture token from the Keychain, generating and storing
    /// one on first run. Migrates any legacy UserDefaults token once (G6).
    private func loadOrCreateCaptureToken() -> String {
        if let existing = CaptureTokenStore.load() {
            return existing
        }
        let token = CaptureToken.generate()
        _ = CaptureTokenStore.save(token)
        return token
    }

    /// Copy the capture token to the pasteboard (for pasting into the extension).
    func copyCaptureToken() {
        guard !captureToken.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captureToken, forType: .string)
    }

    // MARK: - Bulk import (sweeps) — 015 · Phase 7

    /// UserDefaults key for the bulk-import consent (7A / legal framing). The
    /// server's `/jobs` open gate reads this SAME flag, so a sweep can't start until
    /// the user accepts in-app.
    static let bulkConsentKey = "AtelierBulkConsentGranted"

    /// An `open` sweep idle this long (seconds) is treated as interrupted and paused.
    /// Set safely past the engine's 30s max item backoff so a live-but-throttled sweep
    /// isn't falsely reconciled; if it is, the browser loop halts cleanly and resumes.
    static let staleSweepSeconds: TimeInterval = 90

    /// Whether the user has accepted the bulk-import notice. Gates the first sweep
    /// server-side (the `JobRoutes` consent closure reads the persisted flag).
    @Published private(set) var bulkConsentGranted =
        UserDefaults.standard.bool(forKey: "AtelierBulkConsentGranted")

    /// The ledger's sweeps with their live per-outcome tallies (progress UI).
    @Published private(set) var sweeps: [SweepProgress] = []

    /// One sweep's progress, computed from its `Job` + `job_item` tally.
    struct SweepProgress: Identifiable {
        let job: Job
        let counts: [JobItemStatus: Int]
        var id: UUID { job.id }

        /// Items whose bytes landed (fresh + dedup).
        var ingested: Int { (counts[.ingested] ?? 0) + (counts[.deduped] ?? 0) }
        /// Items skipped as already-known (P14).
        var skipped: Int { counts[.skipped] ?? 0 }
        /// Items that failed (retryable + permanent).
        var failed: Int { (counts[.retryableFailed] ?? 0) + (counts[.permanentFailed] ?? 0) }
        /// The extension's up-front estimate, if any.
        var total: Int? { job.totalEstimate }
        /// Progress fraction against the estimate, clamped — nil when unknown.
        var fraction: Double? {
            guard let total, total > 0 else { return nil }
            return min(1, Double(ingested + skipped) / Double(total))
        }
    }

    /// Accept the bulk-import notice — persist it (the server reads the same flag)
    /// and unblock sweeps. Idempotent.
    func grantBulkConsent() {
        UserDefaults.standard.set(true, forKey: Self.bulkConsentKey)
        bulkConsentGranted = true
    }

    /// Withdraw consent — the next `/jobs` open is gated again.
    func revokeBulkConsent() {
        UserDefaults.standard.set(false, forKey: Self.bulkConsentKey)
        bulkConsentGranted = false
    }

    /// Reload every sweep + its per-outcome counts (the progress view polls this,
    /// since a sweep runs in the browser and lands rows here out of band).
    func refreshSweeps() async {
        guard let services else { return }
        do {
            // A sweep whose browser tab/worker died can't close its own job. Treat one
            // that hasn't advanced in `staleSweepSeconds` (safely past the 30s max item
            // backoff) as interrupted → paused, so it stops reading as "running". A
            // still-alive sweep halts cleanly on its next relay (7A jobStatus feedback).
            try? await services.pauseStaleOpenJobs(olderThan: Self.staleSweepSeconds, now: Date())
            let jobs = try await services.listJobs()
            var loaded: [SweepProgress] = []
            for job in jobs {
                do {
                    let counts = try await services.jobItemCounts(forJob: job.id)
                    loaded.append(SweepProgress(job: job, counts: counts))
                } catch {
                    // Don't render a failed sweep as fake-healthy 0/0 (G10).
                    throw error
                }
            }
            sweeps = loaded
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Pause a running sweep. The browser loop halts on the NEXT item (it reads the
    /// job status the ingest reply stamps — 7A relay feedback), then checkpoints.
    func pauseSweep(_ id: UUID) { setSweepStatus(id, .paused) }
    /// Re-open a paused sweep so a fresh browser run resumes it from its checkpoint.
    func resumeSweep(_ id: UUID) { setSweepStatus(id, .open) }
    /// Cancel a sweep for good (halted — the browser loop stops on the next item).
    func cancelSweep(_ id: UUID) { setSweepStatus(id, .halted) }

    private func setSweepStatus(_ id: UUID, _ status: JobStatus) {
        guard let services else { return }
        Task {
            do {
                try await services.setJobStatus(jobID: id, to: status)
                await refreshSweeps()
            } catch {
                lastError = Self.message(for: error)
            }
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
        contentsLoadID &+= 1
        let loadID = contentsLoadID
        Task {
            do {
                let loadedItems = try await services.collectionItems(in: id)
                let loadedSubfolders = try await services.childCollections(of: id)
                // A newer load has superseded this one — the two DB reads can
                // finish out of order, so a stale read must NOT overwrite the
                // current folder's content. Bail before publishing anything.
                guard loadID == contentsLoadID else { return }
                items = loadedItems
                subfolders = loadedSubfolders
                // Drop a selection that no longer exists in the reloaded set
                // (folder switch, or the item was removed).
                if let selectedItemID,
                   !items.contains(where: { $0.item.id == selectedItemID }) {
                    select(nil)
                }
                contentsVersion &+= 1
            } catch {
                guard loadID == contentsLoadID else { return }
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
        // uniquingKeysWith (not uniqueKeysWithValues) so a duplicate asset id in
        // a folder degrades instead of trapping (G3).
        let byAssetID = keyedByAssetID(items) { $0.asset.id }
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

    /// The on-disk URL of a folder item's 512-tier thumbnail (pure — no decode).
    /// The grid loads + caches it off the main thread via `ThumbnailCache`, so the
    /// render path never blocks on disk I/O.
    func thumbnailURL(for detail: CollectionItemDetail) -> URL? {
        guard let store else { return nil }
        return store.thumbnailURL(
            hash: detail.asset.blobHash, size: ThumbnailTier.medium.rawValue,
            fileExtension: "jpg")
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

    // MARK: - Content version

    /// Bumped whenever the selected folder's ``items`` change, so a dependent
    /// view can rebuild (via SwiftUI `.id`) to reflect the new set.
    @Published private(set) var contentsVersion = 0

    /// The direct root collections (drives the Collections gallery, 004-P2).
    var rootCollections: [Collection] {
        folders.filter { $0.parentCollectionID == nil }
    }

    /// Load a collection's items WITHOUT disturbing the selected-folder state —
    /// for the "Add from Library" picker (005-E2), which browses arbitrary
    /// collections while a space is open.
    func items(in collectionID: UUID) async throws -> [CollectionItemDetail] {
        guard let services else { return [] }
        return try await services.collectionItems(in: collectionID)
    }

    /// The on-disk 512-tier thumbnail URL for a blob hash (pure — no decode).
    /// Used by the gallery / Spaces-list cover cards.
    func thumbnailURL(forBlobHash hash: String) -> URL? {
        guard let store else { return nil }
        return store.thumbnailURL(hash: hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg")
    }

    // MARK: - Collection covers (004-P2)

    /// Cover blob-hash per collection id, for the gallery cards. Absent id ⇒ no
    /// (surviving) cover — the card shows a folder placeholder.
    @Published private(set) var collectionCovers: [UUID: String] = [:]

    /// Reload the gallery's cover map for every known collection.
    func refreshCollectionCovers() async {
        guard let services else { return }
        do {
            collectionCovers = try await services.collectionCovers(folders.map(\.id))
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Set a collection's cover (gallery "Set as Cover" context action).
    func setCollectionCover(collectionID: UUID, assetID: UUID) {
        perform { services in
            try await services.setCollectionCover(collectionID: collectionID, assetID: assetID)
        }
        Task { await refreshCollectionCovers() }
    }

    // MARK: - Spaces (005-E2)

    /// Every space, newest first (drives the Spaces list).
    @Published private(set) var spaces: [Space] = []
    /// Cover blob-hash per space id, for the Spaces-list cards.
    @Published private(set) var spaceCovers: [UUID: String] = [:]

    /// Reload the spaces list + their cover map.
    func refreshSpaces() async {
        guard let services else { return }
        do {
            let loaded = try await services.listSpaces()
            spaces = loaded
            spaceCovers = try await services.spaceCovers(loaded.map(\.id))
        } catch {
            lastError = Self.message(for: error)
        }
    }

    /// Create an empty space, refresh the list, and return its id (so the caller
    /// can open it). Surfaces failures via ``lastError``.
    @discardableResult
    func createSpace(name: String) async -> UUID? {
        guard let services else { return nil }
        do {
            let space = try await services.createSpace(name: name)
            await refreshSpaces()
            return space.id
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Rename a space, then refresh the list.
    func renameSpace(id: UUID, to name: String) {
        guard let services else { return }
        Task {
            do {
                _ = try await services.renameSpace(id: id, to: name)
                await refreshSpaces()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Delete a space, then refresh the list.
    func deleteSpace(id: UUID) {
        guard let services else { return }
        Task {
            do {
                try await services.deleteSpace(id: id)
                await refreshSpaces()
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Seed a NEW space from a collection's current arrangement (005 — "New Space
    /// from this collection"). Items with an explicit canvas placement keep it;
    /// the rest flow into justified rows below. The first asset becomes the
    /// space's cover. Returns the new space id (or `nil` on failure / empty).
    @discardableResult
    func newSpaceFromCollection(_ collectionID: UUID) async -> UUID? {
        guard let services else { return nil }
        do {
            let sourceItems = try await services.collectionItems(in: collectionID)
            guard !sourceItems.isEmpty else {
                status = "That collection has no items to seed a space."
                return nil
            }
            let name = name(for: collectionID)
            let space = try await services.createSpace(name: name)
            let placements = SpaceLayout.placements(seedingFrom: sourceItems)
            for (detail, rect) in zip(sourceItems, placements) {
                try await services.addAssetToSpace(
                    assetID: detail.asset.id, to: space.id,
                    x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z)
            }
            if let cover = sourceItems.first {
                try? await services.setSpaceCover(spaceID: space.id, assetID: cover.asset.id)
            }
            await refreshSpaces()
            return space.id
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Build a per-open-space view model against the shared Library (005-E2).
    /// `nil` before the Library opens.
    func makeSpaceModel(for spaceID: UUID) -> SpaceModel? {
        guard let services, let store else { return nil }
        return SpaceModel(spaceID: spaceID, services: services, store: store)
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
                case .cancelled: break
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
        case .persistenceFailure(let detail):
            if let detail, !detail.isEmpty {
                return "Library storage failed: \(detail)"
            }
            return "Library storage failed."
        default:
            return "\(error)"
        }
    }
}
