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

    /// The selected folder's DIRECT items (decision F5). Rebuilds the O(1)
    /// selection/drag indexes (below) on every assignment — a load, a move, a
    /// reorder — so the marquee/drag hot path never rescans `items` per cell.
    @Published private(set) var items: [CollectionItemDetail] = [] {
        didSet { rebuildItemDerivations() }
    }
    /// The selected folder's immediate subfolders (navigable).
    @Published private(set) var subfolders: [Collection] = []

    /// The Unsorted screen's stack-row cards (009 · N4): one per root collection
    /// (Unsorted excluded), each with its count + recent thumbnail hashes. Loaded
    /// ONLY while the Unsorted folder is selected (empty otherwise), refreshed via
    /// the same `loadContents` funnel so a move keeps it live.
    @Published private(set) var stackPreviews: [CollectionStackPreview] = []

    // MARK: - Selected item (inspector)

    /// The grid's multi-selection (009 · N2): the selected membership ids, the
    /// ⇧-range anchor, and the `lead` (the detail-overlay / keyboard cursor).
    /// Selection MODE is derived — `selection.isSelecting`. Pruned to surviving
    /// ids on every contents reload. Mutated ONLY through ``applySelection`` (the
    /// pure reducer) so the mode-dependent click contract stays testable.
    @Published private(set) var selection = GridSelection() {
        didSet { rebuildSelectedAssetIDs() }
    }
    /// The selected item's large (1280-tier) preview, loaded OFF-MAIN; `nil`
    /// while loading, when nothing is selected, or if the tier can't be decoded.
    @Published private(set) var previewImage: NSImage?
    /// The selected item's tags (name-ordered), for the detail page's tags editor.
    /// Reloaded on selection change and after every add/remove. Empty when nothing
    /// is selected or the item has no tags.
    @Published private(set) var selectedTags: [Tag] = []

    // MARK: - Import / status

    /// The in-flight batch's `(completed, total)`, or `nil` when idle.
    @Published private(set) var progress: Progress?
    /// A human-readable status line for the view, or `nil`.
    @Published private(set) var status: String?
    /// The last surfaced error message (drives an `.alert`), or `nil`.
    @Published var lastError: String?
    /// `false` until the Library has opened — import affordances stay disabled.
    @Published private(set) var isReady = false

    /// The most recent remote-capture batch (011-B4), published so the shell can
    /// raise ONE "Saved — Jump" toast per batch. Carries a monotonic `token` so a
    /// repeat batch into the same folder still trips `onChange`.
    @Published private(set) var lastCaptureBatch: CaptureBatch?
    private var captureBatchToken = 0

    /// A selection to apply once a target collection finishes loading (011-B4 · 12A
    /// Jump). Deterministic, not a timer: `loadContents` applies it against the
    /// freshly loaded items, then clears it.
    private var pendingSelection: (collectionID: UUID, assetIDs: Set<UUID>)?

    /// The most recent reversible destructive verb (delete / remove / move),
    /// published so the shell raises ONE "…— Undo" toast (034 P1 — the unified
    /// action+undo surface). Carries the undo-stack `undoToken` captured just after
    /// the action registered, so the toast can verify it's still the top of the
    /// stack before firing (a superseded toast no-ops rather than undoing the wrong
    /// action). A new event trips `onChange` because the token strictly increases.
    @Published private(set) var lastUndoableAction: UndoableActionEvent?

    /// A performed-and-reversible action worth a toast: the human message plus the
    /// undo-stack token to fire against.
    struct UndoableActionEvent: Equatable {
        let message: String
        let undoToken: Int
    }

    /// A batch's progress counters.
    struct Progress: Equatable {
        var completed: Int
        var total: Int
    }

    /// A landed remote-capture batch — enough for the shell's "Saved N to <folder>
    /// — Jump" toast and its typed Jump target (011-B4).
    struct CaptureBatch: Equatable {
        let token: Int
        let collectionID: UUID
        let collectionName: String
        let assetIDs: [UUID]
        let importedCount: Int
    }

    /// Stash a Jump's target selection and load the collection so it lands on the
    /// freshly captured items (011-B4). The caller also navigates via
    /// `NavModel.openCollection`; if that folder is ALREADY the open one the
    /// pushed screen's `.task` won't re-fire, so reload here to apply the pending
    /// selection either way.
    func requestJumpSelection(assetIDs: [UUID], in collectionID: UUID) {
        pendingSelection = (collectionID, Set(assetIDs))
        if collectionID == selectedFolderID { loadContents(of: collectionID) }
    }

    // MARK: - Capture endpoint (Chrome extension)

    /// The shared-secret the extension must present (shown in the UI so the user
    /// can paste it into the extension's options). Empty until the Library opens.
    @Published private(set) var captureToken: String = ""
    /// The loopback port the capture endpoint listens on.
    let capturePort = CaptureServer.defaultPort
    /// The on-disk Library root (set once the Library opens) — surfaced in the
    /// Settings scene (010 · Phase 2) so the user can locate/back up their data.
    @Published private(set) var libraryRoot: URL?
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
    /// Library snapshot orchestration (008 H3): daily-on-launch, pre-destructive,
    /// manual, and retention. `nil` until `bootstrap()` opens the library.
    private(set) var snapshotManager: SnapshotManager?
    /// Presents the snapshots sheet (manual snapshot + restore).
    @Published var showSnapshots = false
    /// Set after a restore is staged — an alert asks the user to relaunch.
    @Published var restoreStagedMessage: String?

    /// Monotonic id for ``loadContents(of:)`` so a slow read can never clobber a
    /// newer one (fast folder switch, or a mutation-triggered reload).
    private var contentsLoadID = 0

    /// Coalesces detail-open view signals into batched `recordViews` writes
    /// (007 G4). Flushed by `flushViewBumps()` on detail-close and by a short
    /// debounce timer.
    private var viewBumps = ViewBumpCoalescer()
    private var viewFlushTask: Task<Void, Never>?
    /// How long a burst of opens is batched before an automatic flush.
    private let viewFlushDelay: Duration = .seconds(3)

    /// Downloads a bare image URL (drag/paste with no bytes) off-main. Stateless +
    /// injectable; the default uses the shared session (tests inject a stub one).
    private let remoteFetcher = RemoteImageFetcher()
    /// Resolves a pasted PAGE url to link metadata (og:title / description / og:image),
    /// SSRF-walled (001 · C2b). Shares the SSRF posture with `remoteFetcher`.
    private let pageResolver = PageResolver()

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

    /// The LEAD item's detail — what the full-window detail overlay shows and
    /// what the tag editor mutates — resolved from the loaded ``items`` by the
    /// `selection.lead` membership id (stable across a contents reload). `nil`
    /// when there is no cursor, which auto-dismisses the overlay.
    var leadItem: CollectionItemDetail? {
        guard let lead = selection.lead else { return nil }
        return items.first { $0.item.id == lead }
    }

    /// The asset ids of the current selection, in feed order — the boundary from
    /// membership-id selection to the asset-id verbs (move / copy / remove /
    /// delete / drag payload). Empty when nothing is selected. Served from a cache
    /// rebuilt on every `items`/`selection` change: a marquee re-render rebuilds
    /// each visible cell's `.draggable` payload, and every selected cell reads
    /// this — recomputing the filter per cell was O(visible × N) per tick.
    var selectedAssetIDs: [UUID] { cachedSelectedAssetIDs }

    // MARK: - Derived selection/drag indexes (009 · N6 perf)

    /// `item.id → asset.id` for O(1) single-cell drag/action scope, replacing an
    /// `items.first { … }` linear scan run per visible cell each marquee tick.
    private var assetIDByItemID: [UUID: UUID] = [:]
    /// The item ids in feed order — the reducer's `order` argument, hoisted out of
    /// `applySelection` so a per-tick `items.map` allocation is avoided.
    private var itemOrder: [UUID] = []
    /// The current selection's asset ids in feed order (see `selectedAssetIDs`).
    private var cachedSelectedAssetIDs: [UUID] = []

    /// Monotonic token bumped whenever `items` changes (a load / move / reorder),
    /// so the grid's masonry layout cache (011-B1 · 14A) can key off cheap
    /// integer equality instead of hashing the item ids or re-deriving aspects on
    /// every re-render — the marquee's selection churn re-renders the grid many
    /// times per second with `items` unchanged, and each of those must be a memo
    /// hit, not an O(N) re-layout.
    private(set) var itemsVersion = 0

    /// Rebuild the item-keyed indexes after `items` changes (a load / mutation);
    /// the selection cache depends on `items` too, so refresh it here as well.
    private func rebuildItemDerivations() {
        itemsVersion &+= 1
        itemOrder = items.map { $0.item.id }
        assetIDByItemID = Dictionary(
            items.map { ($0.item.id, $0.asset.id) }, uniquingKeysWith: { first, _ in first })
        rebuildSelectedAssetIDs()
    }

    /// Rebuild the selected-asset-id cache after `items` or `selection` changes.
    /// Preserves feed order (mirrors the old `items.filter { … }.map` exactly).
    private func rebuildSelectedAssetIDs() {
        cachedSelectedAssetIDs = items.compactMap {
            selection.ids.contains($0.item.id) ? $0.asset.id : nil
        }
    }

    /// The asset ids a batch action should act on for a right-click on the cell
    /// whose membership id is `itemID` (Finder scope, 009 · 7A): the WHOLE
    /// selection when that cell is part of it, else just that one cell — the
    /// selection is left untouched either way.
    func actionTargets(forCellItemID itemID: UUID) -> [UUID] {
        if selection.ids.contains(itemID) { return selectedAssetIDs }
        guard let assetID = assetIDByItemID[itemID] else { return [] }
        return [assetID]
    }

    /// Build the drag payload for a drag that starts on the cell `itemID`
    /// (009 · N3). Same scope rule as ``actionTargets(forCellItemID:)``: a cell
    /// that is part of the selection drags the WHOLE selection; an UNSELECTED
    /// cell drags just itself — a single-item drag, **selection left untouched**
    /// (an idle drag leaves you idle, not stuck in selection mode). Returns `nil`
    /// only if the cell has vanished.
    func dragPayload(forCellItemID itemID: UUID) -> AssetDragPayload? {
        let assetIDs = actionTargets(forCellItemID: itemID)
        guard !assetIDs.isEmpty else { return nil }
        return AssetDragPayload(assetIDs: assetIDs, sourceCollectionID: selectedFolderID)
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

    /// The space a confirmed delete will remove (UX-batch · space-delete undo).
    /// Drives the ``SpacesListView`` confirmation dialog; `nil` when none staged.
    @Published var pendingSpaceDeletion: PendingSpaceDeletion?

    /// The space staged for a confirmed, undoable delete.
    struct PendingSpaceDeletion {
        let id: UUID
        let name: String
    }

    init() {
        undoManager.groupsByEvent = false
        Task { await bootstrap() }
    }

    /// Test-only: inject an already-open library (no capture endpoint / snapshot
    /// orchestration) so the destructive verbs + their undo can be driven
    /// deterministically — mirrors ``SpaceModel``'s injectable init. Callers load
    /// the tree with ``refreshFolders()``.
    init(services: AppServices, store: MediaStore) {
        undoManager.groupsByEvent = false
        self.services = services
        self.store = store
        self.selectedFolderID = services.unsortedFolderID
        self.isReady = true
    }

    // MARK: - Bootstrap

    /// Open (or create) the Library under Application Support and wire the
    /// pipeline + coordinator. The v2 migration guarantees the Unsorted folder,
    /// so nothing is seeded here. Loads the folder tree + Unsorted's contents.
    private func bootstrap() async {
        do {
            let root = try LibraryLocation.defaultRoot()
            self.libraryRoot = root
            let layout = LibraryLayout(root: root)
            let store = MediaStore(layout: layout)
            let dbURL = layout.root.appendingPathComponent("library.sqlite")
            // A staged restore (008 H3) is applied here — before any connection
            // opens — the only safe time to swap the live database file.
            SnapshotManager.applyPendingRestore(
                snapshotsDir: layout.snapshots, livePath: dbURL)
            let dbPath = dbURL.path
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

            // Backup hygiene (008 H2): keep regenerable thumbnails/cache out of
            // Time Machine / iCloud. Idempotent, cheap; safe to run every launch.
            store.excludeDerivedFromBackup()

            // Snapshot orchestration (008 H3): daily-on-launch + pre-destructive
            // + manual, over the snapshots/ directory.
            let snapshots = SnapshotManager(
                services: services, directory: layout.snapshots)
            self.snapshotManager = snapshots

            // Any sweep still "open" at launch is abandoned (nothing is running yet),
            // so reconcile it to paused — otherwise a tab closed mid-sweep last session
            // would show as a phantom "running" job forever.
            try? await services.pauseStaleOpenJobs(olderThan: 0, now: Date())

            // Enforce known ⟺ blob present: forget any ledger row whose blob was
            // removed outside deleteAssets, so a future sweep re-imports that source
            // instead of dedup-skipping bytes that are gone.
            try? await services.reconcileOrphanedKnownItems()

            // Daily-on-launch snapshot if the newest daily is >1 day stale (008
            // H3, confirmed on-by-default). Best-effort; never blocks launch.
            await snapshots.snapshotIfStale()

            await refreshFolders()
            loadContents(of: selectedFolderID)
            await startCaptureEndpoint(coordinator: coordinator, services: services)

            // Reclaim blobs orphaned by deletes that were never undone (010 ·
            // delete-undo). Off-main, after the UI is up; the undo history is empty
            // at launch, so any unreferenced blob is unreachable.
            runOrphanBlobGC(services: services, store: store)
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
        let ingested: [Asset] = outcomes.compactMap {
            if case let .ingested(asset, _) = $0 { return asset } else { return nil }
        }
        let imported = ingested.count
        Task { await refreshFolders() }
        if collectionID == selectedFolderID {
            loadContents(of: selectedFolderID)
        }
        status = imported > 0
            ? "Captured \(imported) from the browser."
            : "A browser capture failed."
        // Publish a batch event (011-B4) so the shell can raise ONE "Saved — Jump"
        // toast per batch. The monotonic token makes `onChange` fire even for a
        // second batch into the same folder with the same count.
        if imported > 0 {
            captureBatchToken &+= 1
            lastCaptureBatch = CaptureBatch(
                token: captureBatchToken,
                collectionID: collectionID,
                collectionName: name(for: collectionID),
                assetIDs: ingested.map(\.id),
                importedCount: imported)
        }
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

    /// Regenerate the capture token (010 · Phase 2 Settings): stop the endpoint,
    /// persist a fresh secret, and restart it bound to the new token — so the
    /// change takes effect immediately (the user then re-pairs the extension).
    /// The old token stops working the moment the server restarts.
    func regenerateCaptureToken() {
        guard let coordinator, let services else { return }
        Task {
            await captureServer?.stop()
            _ = CaptureTokenStore.save(CaptureToken.generate())
            // `startCaptureEndpoint` reloads the persisted token, republishes
            // `captureToken`, and rebinds the server auth.
            await startCaptureEndpoint(coordinator: coordinator, services: services)
            status = "Capture token regenerated — re-pair the extension."
        }
    }

    /// Reveal the Library root in Finder (Settings "Show in Finder").
    func revealLibraryInFinder() {
        guard let libraryRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryRoot])
    }

    // MARK: - Diagnostics (010 · Phase 3)

    /// Gather non-sensitive facts for a diagnostics export — versions, sizes, and
    /// counts only, never library content.
    private func diagnosticsFacts() -> DiagnosticsFacts {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        var dbSize: Int64?
        if let root = libraryRoot {
            let dbPath = root.appendingPathComponent("library.sqlite").path
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
               let size = attrs[.size] as? NSNumber {
                dbSize = size.int64Value
            }
        }
        return DiagnosticsFacts(
            appVersion: version, appBuild: build,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            supportedExtensionRange:
                "\(CaptureServer.minExtensionVersion)–\(CaptureServer.maxExtensionVersion)",
            capturePort: Int(capturePort),
            captureEndpointRunning: captureEndpointRunning,
            libraryPath: libraryRoot?.path(percentEncoded: false),
            databaseFileSizeBytes: dbSize,
            snapshotCount: snapshotManager?.list().count ?? 0,
            generatedAt: Date())
    }

    /// Export diagnostics (Settings): write the text report into the app
    /// container's temp dir (sandbox-safe) and reveal it in Finder.
    func exportDiagnostics() {
        let text = DiagnosticsReport.text(from: diagnosticsFacts())
        let name = "AtelierRefs-Diagnostics-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = "Diagnostics exported."
            AppLog.diagnostics.info(
                "exported diagnostics: \(name, privacy: .public)")
        } catch {
            lastError = "Couldn't export diagnostics: \(error.localizedDescription)"
        }
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

    // MARK: - App-level undo/redo (010 · Phase 1)

    /// Library-wide undo/redo for the reversible destructive verbs — rename,
    /// move (folder + assets), reorder, remove-from-collection. Mirrors
    /// ``SpaceModel``'s proven design: every undoable write funnels through
    /// ``enqueueUndoable(_:)`` so an undo can't reorder ahead of an in-flight
    /// write, and inverses are id-based (never index-based) so they stay correct
    /// as remote captures interleave.
    ///
    /// Asset DELETE is deliberately NOT undoable in v1: reversing the cascading
    /// `deleteAssets` (sources, memberships, tag links, covers, job ledger, +
    /// trashed blobs) needs a core "undelete" primitive; until then the
    /// pre-destructive snapshot (008 H3) is its safety net (033-plan open-Q1).
    let undoManager = UndoManager()

    /// Bumped on every register / undo / redo so the Edit menu's enabled state +
    /// action names refresh (UndoManager isn't `ObservableObject`).
    @Published private(set) var undoToken = 0

    /// Serial write chain: each undoable op awaits the previous, so DB writes stay
    /// strictly ordered even as undo/redo interleave with live edits.
    private var undoWriteChain: Task<Void, Never> = Task {}

    /// Await the tail of the undoable write chain — for tests to observe a settled
    /// (committed) state after an edit / undo / redo.
    func waitForWrites() async { await undoWriteChain.value }

    /// Append `work` to the serial undoable write chain (FIFO, strictly ordered).
    private func enqueueUndoable(_ work: @escaping () async -> Void) {
        let previous = undoWriteChain
        undoWriteChain = Task { @MainActor in
            await previous.value
            await work()
        }
    }

    /// Register an already-performed action as its own closed undo group:
    /// `inverse` runs on undo, `primary` re-runs on redo, ping-ponging. Neither
    /// runs now.
    private func registerReversible(_ name: String,
                                    primary: @escaping () -> Void,
                                    inverse: @escaping () -> Void) {
        undoManager.beginUndoGrouping()
        undoManager.setActionName(name)
        installUndo(name, primary: primary, inverse: inverse)
        undoManager.endUndoGrouping()
        undoToken &+= 1
    }

    /// The recursive ping-pong (see ``SpaceModel``): run `inverse`, then re-install
    /// the mirror so redo re-runs `primary`. During undo/redo `UndoManager`
    /// supplies the enclosing group, so this must NOT open its own.
    private func installUndo(_ name: String,
                             primary: @escaping () -> Void,
                             inverse: @escaping () -> Void) {
        undoManager.registerUndo(withTarget: self) { model in
            inverse()
            model.installUndo(name, primary: inverse, inverse: primary)
            model.undoManager.setActionName(name)
        }
    }

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }
    var undoActionName: String { undoManager.undoActionName }
    var redoActionName: String { undoManager.redoActionName }

    func undo() { undoManager.undo(); undoToken &+= 1 }
    func redo() { undoManager.redo(); undoToken &+= 1 }

    /// Publish a just-performed reversible verb so the shell shows a "…— Undo" toast
    /// (034 P1). Call AFTER `registerReversible` so `undoToken` already reflects this
    /// action as the top of the stack.
    private func announceUndoable(_ message: String) {
        lastUndoableAction = UndoableActionEvent(message: message, undoToken: undoToken)
    }

    /// Fire an Undo toast's button: reverse the action ONLY if it's still the top of
    /// the undo stack (`token` unchanged since the toast was posted). If any later
    /// action / undo / redo bumped `undoToken`, this toast is stale — no-op, so it
    /// can't silently undo something the user didn't mean.
    func undoLastAction(expecting token: Int) {
        guard undoToken == token, undoManager.canUndo else { return }
        undo()
    }

    #if DEBUG
    /// Test-only: seed the visible `items` so a verb that captures the live order
    /// (reorder / remove / move) reads a known state without racing the async
    /// `loadContents` reload.
    func setItemsForTesting(_ items: [CollectionItemDetail]) {
        self.items = items
    }
    #endif

    // MARK: - Undoable write workers (shared by verbs + their inverses)

    /// Rename a folder, then refresh. No undo re-registration (the ping-pong
    /// installs the mirror).
    private func applyRename(id: UUID, to name: String) async {
        guard let services else { return }
        do {
            _ = try await services.renameCollection(id: id, to: name)
            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    /// Reparent a folder, then refresh.
    private func applyMoveFolder(id: UUID, toParent parent: UUID?) async {
        guard let services else { return }
        do {
            try await services.moveCollection(id: id, toParent: parent)
            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    /// Set `folder`'s grid order to `desired`, filtered to current members so a
    /// concurrently-deleted asset can't throw `.notFound`.
    private func applyOrder(folder: UUID, desired: [UUID]) async {
        guard let services, !desired.isEmpty else { return }
        do {
            let members = Set(try await services.collectionItems(in: folder).map { $0.asset.id })
            let filtered = desired.filter(members.contains)
            guard !filtered.isEmpty else { return }
            try await services.setGridOrder(collectionID: folder, orderedAssetIDs: filtered)
        } catch { lastError = Self.message(for: error) }
    }

    /// Persist a reorder, then focus + reload the folder (reorder verb + inverse).
    private func applyReorder(folder: UUID, order: [UUID]) async {
        await applyOrder(folder: folder, desired: order)
        selectedFolderID = folder
        loadContents(of: folder)
    }

    /// Drop memberships from `folder`, refresh, optionally publish `message`.
    private func applyRemove(assetIDs: [UUID], from folder: UUID, message: String?) async {
        guard let services else { return }
        do {
            try await services.removeAssets(assetIDs, from: folder)
            await refreshFolders()
            selectedFolderID = folder
            loadContents(of: folder)
            if let message { status = message }
        } catch { lastError = Self.message(for: error) }
    }

    /// Re-add memberships to `folder` and restore their prior order — the inverse
    /// of ``applyRemove``.
    private func applyRestoreMemberships(assetIDs: [UUID], to folder: UUID, order: [UUID]) async {
        guard let services else { return }
        do {
            try await services.addAssets(assetIDs, to: folder)
            await applyOrder(folder: folder, desired: order)
            await refreshFolders()
            selectedFolderID = folder
            loadContents(of: folder)
        } catch { lastError = Self.message(for: error) }
    }

    /// Move memberships `source → target`, then focus + reload the source (move
    /// verb + redo).
    private func applyMoveAssets(_ assetIDs: [UUID], from source: UUID, to target: UUID, message: String?) async {
        guard let services else { return }
        do {
            try await services.moveAssets(assetIDs, from: source, to: target)
            await refreshFolders()
            selectedFolderID = source
            loadContents(of: source)
            if let message { status = message }
        } catch { lastError = Self.message(for: error) }
    }

    /// Move memberships back `target → source` and restore the source order — the
    /// inverse of ``applyMoveAssets``.
    private func applyMoveBack(_ assetIDs: [UUID], from target: UUID, to source: UUID, order: [UUID]) async {
        guard let services else { return }
        do {
            try await services.moveAssets(assetIDs, from: target, to: source)
            await applyOrder(folder: source, desired: order)
            await refreshFolders()
            selectedFolderID = source
            loadContents(of: source)
        } catch { lastError = Self.message(for: error) }
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

    /// Rename a folder. Rejected for Unsorted (`.protectedCollection`). Undoable.
    func renameFolder(id: UUID, to name: String) {
        guard id != unsortedFolderID, services != nil else { return }
        let oldName = folders.first { $0.id == id }?.name
        enqueueUndoable { await self.applyRename(id: id, to: name) }
        if let oldName, oldName != name {
            registerReversible("Rename",
                primary: { self.enqueueUndoable { await self.applyRename(id: id, to: name) } },
                inverse: { self.enqueueUndoable { await self.applyRename(id: id, to: oldName) } })
        }
    }

    /// Delete a folder and its whole subtree. Rejected for Unsorted.
    func deleteFolder(id: UUID) {
        guard id != unsortedFolderID else { return }
        perform(after: id == selectedFolderID) { services in
            try await services.deleteCollection(id: id)
        }
    }

    /// Reparent a folder (`nil` ⇒ top level). Rejects cycles / Unsorted. Undoable.
    func moveFolder(id: UUID, toParent parent: UUID?) {
        guard id != unsortedFolderID, services != nil else { return }
        let oldParent = folders.first { $0.id == id }?.parentCollectionID
        enqueueUndoable { await self.applyMoveFolder(id: id, toParent: parent) }
        if oldParent != parent {
            registerReversible("Move Folder",
                primary: { self.enqueueUndoable { await self.applyMoveFolder(id: id, toParent: parent) } },
                inverse: { self.enqueueUndoable { await self.applyMoveFolder(id: id, toParent: oldParent) } })
        }
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
        let sort = sortMode(for: id)
        // The stack row is shown only on the Unsorted screen (009 · N4), so its
        // preview read is skipped for every other folder.
        let loadsStacks = id == unsortedFolderID
        Task {
            do {
                // The three reads are independent — run them concurrently so the
                // reload latency is the slowest ONE, not their sum (009 · 16A).
                async let itemsRead = services.collectionItems(in: id, sort: sort)
                async let subfoldersRead = services.childCollections(of: id)
                async let stacksRead: [CollectionStackPreview] =
                    loadsStacks ? services.collectionStackPreviews() : []
                let loadedItems = try await itemsRead
                let loadedSubfolders = try await subfoldersRead
                let loadedStacks = try await stacksRead
                // A newer load has superseded this one — the reads can finish out
                // of order, so a stale read must NOT overwrite the current
                // folder's content. Bail before publishing anything.
                guard loadID == contentsLoadID else { return }
                items = loadedItems
                subfolders = loadedSubfolders
                // Republish the stack row only when it actually changed — an
                // unchanged set never re-renders or re-decodes its fans (009 · 15A).
                if loadsStacks {
                    if stackPreviews != loadedStacks { stackPreviews = loadedStacks }
                } else if !stackPreviews.isEmpty {
                    stackPreviews = []
                }
                // Prune the selection to ids that survive the reloaded set
                // (folder switch, move-away, or delete). A removed lead clears
                // the inspector so a stale preview/tags can't linger.
                let hadLead = selection.lead
                selection = selection.pruned(to: items.map { $0.item.id })
                if hadLead != nil, selection.lead == nil {
                    previewImage = nil
                    selectedTags = []
                }
                // Apply a pending Jump selection (011-B4 · 12A) against the freshly
                // loaded items, then clear it — deterministic, no timing hack.
                if let pending = pendingSelection, pending.collectionID == id {
                    let jumped = jumpSelection(in: items, assetIDs: pending.assetIDs)
                    if !jumped.isEmpty { selection = jumped }
                    pendingSelection = nil
                }
                contentsVersion &+= 1
            } catch {
                guard loadID == contentsLoadID else { return }
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Sort (007 G4)

    /// The stored sort mode for `id`, resolved from the folder cache. `.manual`
    /// when the folder isn't cached yet (the safe, drag-enabled default).
    func sortMode(for id: UUID) -> SortMode {
        folders.first { $0.id == id }?.sortMode ?? .manual
    }

    /// Change a folder's grid sort mode: persist it, update the folder cache
    /// optimistically so the toolbar reflects the choice immediately, and reload
    /// the contents in the new order. Drag-reorder is meaningful only in
    /// `.manual`, so the grid disables it in the other modes.
    func setSortMode(_ mode: SortMode, for id: UUID) {
        guard let services, sortMode(for: id) != mode else { return }
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].sortMode = mode
        }
        loadContents(of: id)
        Task {
            do {
                try await services.setCollectionSortMode(mode, for: id)
            } catch {
                lastError = Self.message(for: error)
                await refreshFolders()          // resync the cache to the truth
                loadContents(of: id)
            }
        }
    }

    // MARK: - View tracking (007 G4)

    /// Record that `assetID`'s detail page was opened (the deliberate view
    /// signal). Coalesced: repeated opens in the debounce window collapse to one
    /// bump, flushed after `viewFlushDelay` or on `flushViewBumps()`.
    func recordView(assetID: UUID) {
        viewBumps.record(assetID)
        viewFlushTask?.cancel()
        viewFlushTask = Task { [viewFlushDelay] in
            try? await Task.sleep(for: viewFlushDelay)
            guard !Task.isCancelled else { return }
            flushViewBumps()
        }
    }

    /// Write any pending view bumps now (called on detail-close). One batched
    /// `recordViews` through the funnel; unknown/deleted ids are skipped by core.
    /// When the current folder ranks by views, the grid is reloaded afterwards so
    /// the ranking stays live — the just-viewed item visibly rises (manual /
    /// newest orders are view-independent, so they are left untouched).
    func flushViewBumps() {
        viewFlushTask?.cancel()
        viewFlushTask = nil
        guard let services, !viewBumps.isEmpty else { return }
        let ids = viewBumps.drain()
        let folder = selectedFolderID
        let reorders = sortMode(for: folder) == .mostViewed
        Task {
            do {
                try await services.recordViews(ids)
                if reorders { loadContents(of: folder) }
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    // MARK: - Reorder (drag-to-reorder)

    /// Move the dragged BLOCK `movingAssetIDs` to the grid slot currently held by
    /// `targetAssetID`, within the selected folder (009 · N3 — multi-select drag).
    /// OPTIMISTIC: reorders the local ``items`` immediately for feedback, then
    /// persists the new full order via `setGridOrder` (the write hops OFF the main
    /// actor). On failure the message surfaces via ``lastError`` and the folder
    /// reloads to the truth; on success it reloads too (core sorts by
    /// `manual_order`, so state stays consistent). A no-op when the target is one
    /// of the dragged items, no dragged id is a current item (foreign drop), or
    /// the folder isn't in `.manual` mode (reordering has no meaning there).
    func reorderItems(movingAssetIDs: [UUID], toIndexOf targetAssetID: UUID) {
        guard sortMode(for: selectedFolderID) == .manual, services != nil else { return }
        let currentIDs = items.map { $0.asset.id }
        guard let newOrder = reorderedIDs(
            ids: currentIDs, movingIDs: movingAssetIDs, toIndexOf: targetAssetID)
        else { return }

        // Optimistic local reorder — rebuild `items` in the new order.
        // uniquingKeysWith (not uniqueKeysWithValues) so a duplicate asset id in
        // a folder degrades instead of trapping (G3).
        let byAssetID = keyedByAssetID(items) { $0.asset.id }
        items = newOrder.compactMap { byAssetID[$0] }
        contentsVersion &+= 1

        // Undoable: the inverse restores the exact prior order (id-based). The
        // write is serialized + reloads to the persisted truth either way.
        let folder = selectedFolderID
        enqueueUndoable { await self.applyReorder(folder: folder, order: newOrder) }
        registerReversible("Reorder",
            primary: { self.enqueueUndoable { await self.applyReorder(folder: folder, order: newOrder) } },
            inverse: { self.enqueueUndoable { await self.applyReorder(folder: folder, order: currentIDs) } })
    }

    // MARK: - Selection + inspector

    /// Apply a selection `action` through the pure ``GridSelection`` reducer over
    /// the current feed order (+ `columns` for arrow keys), publish the new
    /// selection, and hand the caller the ``GridSelectionEffect`` to execute
    /// (open detail / scroll a cell into view / nothing). This is the ONLY
    /// selection mutator — views report raw input and never branch on mode (009 ·
    /// N2 · 11A). Pure state: NO preview/tags I/O happens here, so a toggle or a
    /// ⌘A never decodes a large thumbnail (009 · 8A); loads happen in
    /// ``openItem(_:)`` when the detail page is actually opened.
    @discardableResult
    func applySelection(_ action: GridSelectionAction, columns: Int = 1) -> GridSelectionEffect {
        let (next, effect) = selection.applying(action, order: itemOrder, columns: columns)
        // Publish only real changes: the marquee re-fires on every mouse-move
        // tick, and an unchanged hit set must not re-render the whole screen.
        if next != selection { selection = next }
        return effect
    }

    /// Open `detail` in the inspector/detail page: make it the lead cursor and
    /// load its preview + tags off-main (009 · 8A — the I/O is here, on open, not
    /// on every selection change). Called by a grid open and by the detail page's
    /// prev/next stepper; the caller still records the view + raises the overlay.
    func openItem(_ detail: CollectionItemDetail) {
        selection.lead = detail.item.id
        previewImage = nil
        selectedTags = []
        loadPreview(for: detail)
        loadTags(for: detail.asset.id)
    }

    /// Load the large (1280-tier) thumbnail for `detail` off-main, then publish
    /// it only if that item is still the lead (guards rapid re-selection).
    private func loadPreview(for detail: CollectionItemDetail) {
        // A media-less asset (003 · O1) has no thumbnail to decode.
        guard let store, let hash = detail.asset.blobHash else { return }
        let targetID = detail.item.id
        let url = store.thumbnailURL(
            hash: hash, size: ThumbnailTier.large.rawValue,
            fileExtension: "jpg")
        Task.detached(priority: .userInitiated) {
            let image = NSImage(contentsOf: url)
            await MainActor.run { [weak self] in
                guard let self, self.selection.lead == targetID else { return }
                self.previewImage = image
            }
        }
    }

    /// The on-disk full-resolution blob URL for `detail`.
    func blobURL(for detail: CollectionItemDetail) -> URL? {
        blobURL(forAsset: detail.asset)
    }

    /// The on-disk full-resolution blob URL for a bare `asset` — the same path as
    /// `blobURL(for:)` without a folder membership, so a Space board (which places
    /// assets, not collection items) can open the full-res detail page.
    func blobURL(forAsset asset: Asset) -> URL? {
        // Media-less kinds (003 · O1) have no blob on disk.
        guard let store, let hash = asset.blobHash else { return nil }
        let ext = ImageMetadata.fileExtension(forMIMEType: asset.mimeType ?? "")
        return store.blobURL(hash: hash, fileExtension: ext)
    }

    // MARK: - Tags (detail page)

    /// Load `assetID`'s tags off-main, publishing only if it's still the current
    /// selection (guards rapid re-selection, mirroring `loadPreview`).
    private func loadTags(for assetID: UUID) {
        guard let services else { return }
        Task {
            do {
                let tags = try await services.tags(for: assetID)
                guard leadItem?.asset.id == assetID else { return }
                selectedTags = tags
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Apply a user tag to the selected item, then refresh the chips. Empty /
    /// whitespace names are rejected inside the funnel (`Validation.tagName`) and
    /// surface via ``lastError``; a duplicate is idempotent (no second chip).
    func addTag(_ name: String) {
        guard let services, let detail = leadItem else { return }
        let assetID = detail.asset.id
        Task {
            do {
                try await services.applyTag(name, to: assetID, source: .user)
                reloadTagsIfCurrent(assetID)
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Remove `tag` from the selected item, then refresh the chips. Idempotent —
    /// a no-op if the link is already gone.
    func removeTag(_ tag: Tag) {
        guard let services, let detail = leadItem else { return }
        let assetID = detail.asset.id
        Task {
            do {
                try await services.removeTag(tag.name, from: assetID, source: tag.source)
                reloadTagsIfCurrent(assetID)
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Reload the tag chips if `assetID` is still the selection (a tag edit that
    /// lands after the user has navigated away must not repopulate a stale item).
    private func reloadTagsIfCurrent(_ assetID: UUID) {
        guard leadItem?.asset.id == assetID else { return }
        loadTags(for: assetID)
    }

    /// Open the selected item's original source URL in the default browser.
    /// A no-op when the source has no (valid) `originalURL`.
    func openSource(_ detail: CollectionItemDetail) {
        openSourceURL(detail.source.originalURL)
    }

    /// Open a source URL string in the default browser (asset/source-based, for
    /// the Space detail page). A no-op when the string is absent or unparseable.
    func openSourceURL(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Open the full-resolution blob in the default image app (e.g. Preview).
    func openBlob(_ detail: CollectionItemDetail) { openBlob(asset: detail.asset) }

    /// Open a bare asset's full-resolution blob in the default app (Space detail).
    func openBlob(asset: Asset) {
        guard let url = blobURL(forAsset: asset),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal the full-resolution blob in Finder.
    func revealInFinder(_ detail: CollectionItemDetail) { revealInFinder(asset: detail.asset) }

    /// Reveal a bare asset's blob in Finder (Space detail).
    func revealInFinder(asset: Asset) {
        guard let url = blobURL(forAsset: asset),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy the selected item's original source URL to the general pasteboard.
    func copySourceLink(_ detail: CollectionItemDetail) {
        copySourceLink(url: detail.source.originalURL)
    }

    /// Copy a source URL string to the pasteboard (asset/source-based, Space
    /// detail). A no-op when the string is absent.
    func copySourceLink(url string: String?) {
        guard let string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// The on-disk URL of a folder item's 512-tier thumbnail (pure — no decode).
    /// The grid loads + caches it off the main thread via `ThumbnailCache`, so the
    /// render path never blocks on disk I/O.
    func thumbnailURL(for detail: CollectionItemDetail) -> URL? {
        thumbnailURL(forAsset: detail.asset)
    }

    /// The on-disk 512-tier thumbnail URL for a bare asset, or `nil` for a
    /// media-less kind (003 · O1) — which has no thumbnail (the grid draws a
    /// swatch/placeholder from ``AssetContent`` instead).
    func thumbnailURL(forAsset asset: Asset) -> URL? {
        guard let store, let hash = asset.blobHash else { return nil }
        return store.thumbnailURL(
            hash: hash, size: ThumbnailTier.medium.rawValue, fileExtension: "jpg")
    }

    // MARK: - Remove / delete assets

    /// Remove assets from the CURRENT folder only (membership drop) — the asset,
    /// its bytes, and its memberships elsewhere are untouched. Non-destructive and
    /// reversible, so it runs immediately without confirmation.
    func removeFromFolder(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty, services != nil else { return }
        let folder = selectedFolderID
        // Capture the folder's order so undo restores the removed items' positions.
        let priorOrder = items.map { $0.asset.id }
        let message = "Removed \(Self.itemCount(assetIDs.count)) from “\(name(for: folder))”."
        enqueueUndoable { await self.applyRemove(assetIDs: assetIDs, from: folder, message: message) }
        registerReversible("Remove",
            primary: { self.enqueueUndoable { await self.applyRemove(assetIDs: assetIDs, from: folder, message: nil) } },
            inverse: { self.enqueueUndoable { await self.applyRestoreMemberships(assetIDs: assetIDs, to: folder, order: priorOrder) } })
        announceUndoable(message)
    }

    /// MOVE assets out of the current folder into `targetID` — the atomic triage
    /// verb (009 · N1). One transaction; the moved items leave this folder, so the
    /// reload prunes them from the selection. A `from == to` / empty set is a
    /// no-op in core.
    func moveToCollection(assetIDs: [UUID], to targetID: UUID) {
        guard !assetIDs.isEmpty, services != nil else { return }
        let source = selectedFolderID
        guard source != targetID else { return }
        // Capture the source order so undo restores the moved items' positions.
        let priorOrder = items.map { $0.asset.id }
        let message = "Moved \(Self.itemCount(assetIDs.count)) to “\(name(for: targetID))”."
        enqueueUndoable { await self.applyMoveAssets(assetIDs, from: source, to: targetID, message: message) }
        registerReversible("Move",
            primary: { self.enqueueUndoable { await self.applyMoveAssets(assetIDs, from: source, to: targetID, message: nil) } },
            inverse: { self.enqueueUndoable { await self.applyMoveBack(assetIDs, from: targetID, to: source, order: priorOrder) } })
        announceUndoable(message)
    }

    /// COPY assets into `targetID` WITHOUT removing them here (009 · ⌥-drag / Add
    /// to ▸) — multi-membership, so it is exactly `addAssets`. The current folder
    /// is unchanged, so the selection survives.
    func copyToCollection(assetIDs: [UUID], to targetID: UUID) {
        guard !assetIDs.isEmpty else { return }
        mutateContents { services in
            try await services.addAssets(assetIDs, to: targetID)
            return "Added \(Self.itemCount(assetIDs.count)) to “\(self.name(for: targetID))”."
        }
    }

    /// The asset ids a keyboard command (Delete / Remove) acts on: the whole
    /// selection when selecting, else the lead cursor's single item.
    private var keyboardActionTargets: [UUID] {
        selection.isSelecting ? selectedAssetIDs : (leadItem.map { [$0.asset.id] } ?? [])
    }

    /// Remove the current selection (or the lead item) from the current folder.
    func removeSelectedFromFolder() {
        removeFromFolder(assetIDs: keyboardActionTargets)
    }

    /// Stage a destructive delete for confirmation (see ``confirmPendingDeletion``).
    /// A no-op for an empty set.
    func requestDelete(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        pendingDeletion = PendingDeletion(assetIDs: assetIDs)
    }

    /// Stage a delete of the current selection (or the lead item).
    func requestDeleteSelected() {
        requestDelete(assetIDs: keyboardActionTargets)
    }

    /// Dismiss the pending delete without acting.
    func cancelPendingDeletion() {
        pendingDeletion = nil
    }

    /// Carry out the confirmed delete (010 · delete-undo). Captures a verbatim
    /// backup and removes the assets in one transaction, then registers an UNDO
    /// (⌘Z → restore). Blobs are NOT reaped here — reaping is deferred to the
    /// launch orphan-GC so an in-session undo finds the bytes on disk; a delete
    /// that is never undone is reclaimed at the next launch. The pre-destructive
    /// snapshot (008 H3) stays as the coarse net. Clears the pending state first so
    /// the dialog dismisses immediately.
    func confirmPendingDeletion() {
        guard let services, let pending = pendingDeletion else { return }
        pendingDeletion = nil
        let assetIDs = pending.assetIDs
        let count = assetIDs.count
        let snapshots = snapshotManager
        enqueueUndoable {
            try? await snapshots?.snapshot(reason: .preDestructive)
            do {
                let backup = try await services.deleteAssetsRecoverable(assetIDs)
                await self.refreshFolders()
                self.loadContents(of: self.selectedFolderID)
                let message = "Deleted \(Self.itemCount(count))."
                self.status = message
                // Register the undo now that the backup is in hand (id-based).
                self.registerReversible("Delete",
                    primary: { self.enqueueUndoable { await self.applyDeleteAgain(assetIDs, count: count) } },
                    inverse: { self.enqueueUndoable { await self.applyRestore(backup) } })
                self.announceUndoable(message)
            } catch {
                self.lastError = Self.message(for: error)
            }
        }
    }

    /// Restore a captured delete (undo). Blobs were never reaped, so byte-backed
    /// assets come back with their media.
    private func applyRestore(_ backup: DeletedAssetsBackup) async {
        guard let services else { return }
        do {
            try await services.restoreDeletedAssets(backup)
            await refreshFolders()
            loadContents(of: selectedFolderID)
            status = "Restored \(Self.itemCount(backup.assets.count))."
        } catch { lastError = Self.message(for: error) }
    }

    /// Re-delete after a restore (redo). Reuses the plain delete and does NOT reap
    /// (deferred to the launch GC), so a subsequent undo can restore again.
    private func applyDeleteAgain(_ assetIDs: [UUID], count: Int) async {
        guard let services else { return }
        do {
            _ = try await services.deleteAssets(assetIDs)
            await refreshFolders()
            loadContents(of: selectedFolderID)
            status = "Deleted \(Self.itemCount(count))."
        } catch { lastError = Self.message(for: error) }
    }

    /// Reclaim orphaned blob files left by deletes that were never undone (010 ·
    /// delete-undo). Runs off-main after launch, when the undo history is empty so
    /// any unreferenced blob is unreachable. A failed read of the referenced set
    /// SKIPS the sweep (never reaps on uncertainty).
    private func runOrphanBlobGC(services: AppServices, store: MediaStore) {
        Task.detached(priority: .utility) {
            guard let referenced = try? await services.referencedBlobHashes() else { return }
            let reaped = MediaReaper(store: store).reapOrphanedBlobs(referenced: referenced)
            if !reaped.isEmpty {
                AppLog.model.info(
                    "launch orphan-GC reclaimed \(reaped.count, privacy: .public) file(s)")
            }
        }
    }

    // MARK: - Snapshots (008 H3)

    /// Every snapshot on disk (newest first), for the snapshots sheet.
    func availableSnapshots() -> [SnapshotFile] {
        snapshotManager?.list() ?? []
    }

    /// Take a manual snapshot now; report success/failure on the shared surfaces.
    func snapshotNow() {
        guard let manager = snapshotManager else { return }
        Task {
            do {
                _ = try await manager.snapshot(reason: .manual)
                status = "Snapshot saved."
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Stage `snapshot` to be restored on the next launch, then prompt the user to
    /// relaunch. The swap itself happens at bootstrap, before the DB opens.
    func stageRestore(_ snapshot: SnapshotFile) {
        guard let manager = snapshotManager else { return }
        do {
            try manager.stageRestore(snapshot)
            showSnapshots = false
            restoreStagedMessage = "The snapshot will be restored the next time you "
                + "open AtelierRefs. Quit and reopen to complete the restore — your "
                + "current library is set aside, not deleted."
        } catch {
            lastError = "Couldn’t stage the restore: \(Self.message(for: error))"
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

    /// Stage a space delete for confirmation (UX-batch · space-delete undo). A
    /// space can hold hundreds of placements, so — like asset delete — it is
    /// confirmed before it runs and undoable after.
    func requestDeleteSpace(id: UUID, name: String) {
        pendingSpaceDeletion = PendingSpaceDeletion(id: id, name: name)
    }

    /// Dismiss the staged space delete without acting.
    func cancelSpaceDeletion() {
        pendingSpaceDeletion = nil
    }

    /// Carry out the confirmed space delete: capture a verbatim backup (the space
    /// + all its placements), delete, then register an UNDO (⌘Z restores the whole
    /// board). The underlying assets are never touched, so a restore reinstates the
    /// placements exactly. Clears the pending state first so the dialog dismisses.
    func confirmSpaceDeletion() {
        guard let services, let pending = pendingSpaceDeletion else { return }
        pendingSpaceDeletion = nil
        let id = pending.id
        let name = pending.name
        enqueueUndoable {
            do {
                let backup = try await services.deleteSpaceRecoverable(id: id)
                await self.refreshSpaces()
                self.status = "Deleted space “\(name).”"
                self.registerReversible("Delete Space",
                    primary: { self.enqueueUndoable { await self.applyDeleteSpaceAgain(id) } },
                    inverse: { self.enqueueUndoable { await self.applyRestoreSpace(backup) } })
            } catch {
                self.lastError = Self.message(for: error)
            }
        }
    }

    /// Restore a captured space delete (undo) — reinstates the board verbatim.
    private func applyRestoreSpace(_ backup: DeletedSpaceBackup) async {
        guard let services else { return }
        do {
            try await services.restoreDeletedSpace(backup)
            await refreshSpaces()
            status = "Restored space “\(backup.space?.name ?? "").”"
        } catch { lastError = Self.message(for: error) }
    }

    /// Re-delete a restored space (redo). Recoverable again so undo can restore it.
    private func applyDeleteSpaceAgain(_ id: UUID) async {
        guard let services else { return }
        do {
            _ = try await services.deleteSpaceRecoverable(id: id)
            await refreshSpaces()
        } catch { lastError = Self.message(for: error) }
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
    ///
    /// `undecoded` (drag path) is the count of dropped items that couldn't be read
    /// at all — folded into the completion status so a partial drop reports "N
    /// imported, M couldn't be read" rather than dropping them silently (7A).
    func run(inputs: [IngestInput], undecoded: Int = 0) {
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
            status = Self.importStatus(
                imported: imported, failures: failures, undecoded: undecoded)

            await refreshFolders()
            loadContents(of: selectedFolderID)
        }
    }

    /// Compose the completion status for an import batch: always the imported
    /// count, plus a failed clause (bytes that errored in the pipeline) and/or an
    /// unreadable clause (dropped items that couldn't be decoded at all — 7A).
    nonisolated static func importStatus(imported: Int, failures: Int, undecoded: Int) -> String {
        var clauses: [String] = []
        if failures > 0 { clauses.append("\(failures) failed") }
        if undecoded > 0 { clauses.append("\(undecoded) couldn't be read") }
        return clauses.isEmpty
            ? "Imported \(imported)."
            : "Imported \(imported), \(clauses.joined(separator: ", "))."
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
                // A page URL sniffs as HTML, not an image → resolve it into a LINK
                // (001 · C2b) rather than failing. Any OTHER error (blocked host, too
                // large, transport) surfaces its friendly status.
                if case RemoteImageFetchError.notAnImage = error {
                    await resolveLinkAndIngest(from: url, into: target)
                } else {
                    status = Self.remoteFetchStatus(for: error)
                }
            }
        }
    }

    /// Resolve a page URL into a `.link` item (001 · C2b): fetch its og-metadata
    /// (SSRF-walled), store its og:image as the card blob when present, and ingest
    /// through the normal batch path. Every branch still SAVES a link — a bare one
    /// keyed by the URL when resolution or the image fetch fails — so the paste is
    /// never lost. An auth-walled host (x / instagram / pinterest) is NOT app-resolved
    /// (it returns a login / share-card); the user is pointed at the extension.
    private func resolveLinkAndIngest(from url: URL, into folder: UUID) async {
        if PageResolver.isAuthWalledHost(url) {
            // Auth-walled: an app fetch returns a login / share-card, so DON'T resolve —
            // but still save a BARE link (URL preserved, no fetch) so the paste yields a
            // clickable item. The extension remains the way to get the rich tweet card.
            run(inputs: [Self.linkInput(for: url, page: nil, imageData: nil, into: folder)])
            return
        }
        status = "Resolving link…"
        let page = try? await pageResolver.resolve(url)
        // Fetch the og:image as the link's card image (guarded), best-effort.
        var imageData: Data?
        if let imageURL = page?.imageURL {
            imageData = try? await remoteFetcher.fetch(imageURL).data
        }
        run(inputs: [Self.linkInput(for: url, page: page, imageData: imageData, into: folder)])
    }

    /// Build the ``IngestInput`` for a resolved link (001 · C2b) — pure, so the
    /// mapping is unit-tested. With og:image bytes it carries a card blob
    /// (`remoteContentWithImage`); otherwise a media-less link. A `nil` page (resolution
    /// failed) still yields a bare link keyed by the URL. Provenance `originalURL` is the
    /// PAGE url (the funnel canonicalizes it into the dedup key + aligns the draft).
    static func linkInput(
        for url: URL, page: ResolvedPage?, imageData: Data?, into folder: UUID
    ) -> IngestInput {
        let draft = AssetContentDraft.link(
            url: url.absoluteString, title: page?.title, description: page?.description)
        let provenance = SourceDraft(
            platform: .web, originalURL: url.absoluteString, title: page?.title, capturedAt: Date())
        if let imageData {
            return DirectInputReader.remoteContentWithImage(
                draft: draft, imageData: imageData, provenance: provenance, into: folder)
        }
        return DirectInputReader.remoteContent(draft: draft, provenance: provenance, into: folder)
    }

    /// Parse user input into a fetchable http(s) URL — prepends `https://` when
    /// scheme-less (mirroring the funnel's canonicalizer), and rejects anything that
    /// isn't an http(s) URL with a host. `nil` → the caller saves a bare link and lets
    /// the funnel surface `.invalidLinkURL`.
    static func webURL(fromUserInput raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// A pasted PLAIN-TEXT string interpreted as a web URL — stricter than
    /// ``webURL(fromUserInput:)`` because the grid paste path GUESSES a URL from
    /// arbitrary clipboard text: the host must look like a real domain (contain a dot),
    /// so pasting a plain word (`"hello"`) isn't turned into `https://hello`. A
    /// multi-word string fails URL parsing (spaces) and returns nil.
    static func webURL(fromPastedText raw: String) -> URL? {
        guard let url = webURL(fromUserInput: raw),
              let host = url.host, host.contains(".") else { return nil }
        return url
    }

    /// Add a color item (003 · C1) to the current folder from a user-typed hex or
    /// color-picker selection. Media-less, so it skips the blob pipeline entirely
    /// and goes straight through `ingestContent` with local-paste provenance;
    /// canonicalization + dedup happen in the funnel. A malformed hex surfaces via
    /// ``lastError``. Reloads the folder on success (`perform`).
    func addColor(hex: String) {
        let folder = selectedFolderID
        perform { services in
            _ = try await services.ingestContent(
                .color(hex: hex),
                from: SourceDraft(platform: .localPaste, capturedAt: Date()),
                into: folder)
        }
    }

    /// Add a link item (003 · C2) to the current folder from a user-typed URL. When
    /// the input is a usable http(s) URL it is RESOLVED (001 · C2b) — og:title /
    /// description / og:image fill the card (SSRF-walled). A resolution failure still
    /// saves a bare link keyed by the URL. A non-URL string falls through to the funnel,
    /// which surfaces `.invalidLinkURL` into ``lastError``.
    func addLink(url raw: String) {
        guard isReady else { return }
        let folder = selectedFolderID
        guard let url = Self.webURL(fromUserInput: raw) else {
            perform { services in
                _ = try await services.ingestContent(
                    .link(url: raw),
                    from: SourceDraft(platform: .web, originalURL: raw, capturedAt: Date()),
                    into: folder)
            }
            return
        }
        Task { await resolveLinkAndIngest(from: url, into: folder) }
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
        case .blockedHost:
            return "That address can't be reached for safety reasons."
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
