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
import AtelierCapture
import AtelierArchive
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
                // Manual order (043 · 2B): persisted `sortIndex`, tie-broken by
                // `(name, id)` so equal indices (unmigrated fixtures) stay stable.
                .sorted {
                    ($0.sortIndex, $0.name, $0.id.uuidString)
                        < ($1.sortIndex, $1.name, $1.id.uuidString)
                }
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
    /// The collection `items` currently belong to — the identity a view checks to
    /// know whether the shared array is ITS data yet. `nil` until the first load
    /// resolves. Because `items` is a SINGLE shared array (not partitioned per
    /// collection), a freshly-pushed `CollectionView` would otherwise render the
    /// PREVIOUS collection's items during the async reload gap (the "flash of the
    /// last collection" on switch). Set only when `items` is published for a
    /// collection, so a view whose `collectionID` doesn't match shows a loading
    /// skeleton instead of stale content. An in-place reload (move/delete within
    /// the same folder) keeps this equal, so it never flashes a skeleton.
    @Published private(set) var loadedCollectionID: UUID?
    /// The selected folder's immediate subfolders (navigable).
    @Published private(set) var subfolders: [Collection] = []

    // MARK: - Selected item (inspector)

    /// The grid's multi-selection (009 · N2), extracted onto its own observable
    /// (036 §2 A0) so a selection publish no longer fan-outs to every view that
    /// observes this god-object. Mutated ONLY through ``applySelection`` (the pure
    /// reducer) so the mode-dependent click contract stays testable; the store is
    /// the single seam the AppKit grid coordinator subscribes to later.
    let selectionStore = GridSelectionStore()

    /// The current selection, read straight off ``selectionStore`` — a computed
    /// forward so every internal reader (`leadItem`, `selectedAssetIDs`,
    /// `dragPayload`, `actionTargets`, keyboard targets) is unchanged. NOTE: this
    /// is NOT `@Published`, so reading `model.selection` in a SwiftUI body no
    /// longer subscribes to selection changes — a view that must repaint on
    /// selection (only ``CollectionView`` today) observes ``selectionStore``.
    var selection: GridSelection { selectionStore.selection }

    /// Keeps the `selectedAssetIDs` cache in step with the store — the Combine
    /// replacement for the old `selection.didSet`.
    private var selectionCancellable: AnyCancellable?
    // NOTE (036 §3 B1): the detail-overlay's `previewImage` + `selectedTags` moved
    // OFF this god-object into `DetailSession` / `AssetTagsStore`, so opening or
    // stepping the overlay no longer fires `@Published` writes here (each of which
    // re-ran the whole screen, grid included). Only `recordView` remains on this
    // model for the detail page.

    // MARK: - Import / feedback

    /// The in-flight batch's `(completed, total)`, or `nil` when idle.
    @Published private(set) var progress: Progress?
    /// The last one-off notice for the shell to raise as a toast, or `nil`.
    ///
    /// Replaces the old `status` line. That property was read by the toolbar; 006
    /// removed the toolbar and left 18 write sites publishing into nothing, so a
    /// failed drop, a deleted space and a restored backup all reported themselves
    /// to no one. Notices go through the same ``ToastCenter`` as every other
    /// feedback channel now (034 theme 2).
    ///
    /// Carries a monotonic `seq` because `onChange` compares values: two identical
    /// messages in a row (two failed drops) would otherwise register as one event.
    @Published private(set) var lastNotice: Notice?
    private var noticeSeq = 0

    /// A user-facing notice worth exactly one toast.
    struct Notice: Equatable {
        let message: String
        let seq: Int
    }

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

    /// The outcome of the last ⌘C copy (052 · B1), published so the shell raises a
    /// partial-copy toast when some selected assets had nothing to copy (7A). A
    /// monotonic `seq` trips `onChange` even when an identical selection is recopied.
    @Published private(set) var lastCopyReport: CopyReport?
    private var copyReportSeq = 0

    /// How a ⌘C resolved: how many entries reached the pasteboard and how many
    /// selected assets were skipped (media-less `.unknown` / missing blob).
    struct CopyReport: Equatable {
        let copied: Int
        let skipped: Int
        let seq: Int
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
    let capturePort = IngestionModel.capturePort()

    /// The capture port for THIS build.
    ///
    /// The extension hard-codes ``CaptureServer/defaultPort`` (P4), so the shipping
    /// bundle must keep it; a dev build installed alongside it (the `.dev` bundle id)
    /// offsets by one. Without the offset the two builds race for the same bind and
    /// whichever launched first wins, leaving the other's endpoint silently dead —
    /// the loser only says so through the `port … is in use` notice.
    static func capturePort(
        bundleID: String? = Bundle.main.bundleIdentifier
    ) -> UInt16 {
        (bundleID?.hasSuffix(".dev") ?? false)
            ? CaptureServer.defaultPort + 1
            : CaptureServer.defaultPort
    }
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
    /// Drains `inbox/` — the iOS share extension's half of the handoff — at launch
    /// and on every activation (092 · S3). `nil` until `bootstrap()` opens the
    /// library, since the inbox is a directory INSIDE it. Held so the activation
    /// subscription outlives `bootstrap()`'s stack frame.
    private(set) var inboxDrain: InboxDrainScheduler?
    /// The idle on-device analysis + embedding backfill loop (047 · 3a). Held so it
    /// can be cancelled; runs at `.background` for the app's lifetime.
    private var analysisTask: Task<Void, Never>?
    /// Library snapshot orchestration (008 H3): daily-on-launch, pre-destructive,
    /// manual, and retention. `nil` until `bootstrap()` opens the library.
    private(set) var snapshotManager: SnapshotManager?
    /// Presents the snapshots sheet (manual snapshot + restore).
    @Published var showSnapshots = false
    /// Presents the near-duplicate review sheet (012 · I5). A sheet on the MAIN
    /// window rather than a Settings pane, deliberately: its only action is a
    /// delete, and ⌘Z has to reach the same undo stack the grid's delete uses.
    @Published var showDuplicates = false
    /// Set after a restore is staged — an alert asks the user to relaunch.
    @Published var restoreStagedMessage: String?

    // MARK: - Off-device backup target (008 H4)

    /// The user's chosen off-device backup folder, remembered across launches as
    /// a security-scoped bookmark. Owned here rather than by the Settings view:
    /// that window can be closed and reopened at will, and view state would go
    /// with it.
    let backupFolder = StoredFolderAccess()
    /// The target as currently resolved, for display. `nil` when none is chosen
    /// or it can't be reached right now (see ``backupFolderMessage``).
    @Published private(set) var backupFolderURL: URL?
    /// Why the target isn't usable, in words — `nil` when all is well.
    @Published private(set) var backupFolderMessage: String?
    /// Runs, progress, and the last-run record (008 H5). Its own observable
    /// object rather than more `@Published` here: `SettingsView` observes it
    /// directly, so a progress tick during a copy re-renders one section
    /// instead of every view bound to the model.
    let backup = BackupController()
    /// Restores from the backup folder (008 H5c). Its own controller for the
    /// same reasons ``backup`` is one, and separate from it because the two are
    /// different jobs with different progress and different outcomes — sharing
    /// one would make "is something running?" ambiguous exactly when it matters.
    let restore = RestoreController()
    /// Re-hashes what landed at the destination (008 H5d). Its own controller
    /// for the same reasons ``restore`` is one — it is a separate long job with
    /// its own progress, and the section has to be able to say which of the
    /// three is running.
    let verify = BackupVerifyController()
    /// Presents the restore-from-backup sheet.
    @Published var showRestoreBackups = false
    /// Writes the portable library archive (008 H6). Its own controller for the
    /// same reasons ``backup`` and ``restore`` are: the Settings window can close
    /// mid-run, and "is something running?" must stay unambiguous per job. It
    /// needs no bookmark — an archive's destination is a save-panel grant
    /// consumed in-process.
    let archive = ArchiveExportController()
    /// Reads a portable archive back in (008 H7). Its own controller for the
    /// same reason ``archive`` is — and separate from it so a progress bar
    /// always means exactly one job.
    let archiveImport = ArchiveImportController()

    // MARK: - Ambient clipboard capture (013 · K3)

    /// The opt-in clipboard watcher. Owned here for the same reason ``backup`` is:
    /// it must outlive the Settings window that turns it on, and something has to
    /// keep polling while that window is closed. Its own observable object so the
    /// Settings row re-renders on a pause/resume without every model observer
    /// doing so. Off until ``activateClipboardWatcher(root:)`` binds it to the
    /// open library.
    let clipboard = ClipboardWatcher()

    // MARK: - Library stats + maintenance (016 · A)

    /// The storage measurement and the cleanup jobs (016 · A). Owned here and
    /// observed separately by `SettingsView`, for both of `backup`'s reasons: a
    /// progress tick during a scan re-renders one section rather than every view
    /// bound to this model, and the Settings window can be closed and reopened
    /// while a scan of a large library is still walking files.
    let libraryStats = LibraryStatsController()

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

    /// Whether the COLLECTION item-detail overlay is currently up (036 §3 B4). A
    /// PLAIN flag — deliberately NOT `@Published`: a view-bump flush that fires on
    /// the 3s debounce while the overlay is open must NOT reorder the grid *under*
    /// the fade, so ``flushViewBumps()`` defers the Most-Viewed reorder while this
    /// is `true` and the host applies it once, after close, via
    /// ``applyDeferredMostViewedReorder()``. The `CollectionDetailHost` toggles it
    /// on the overlay's lifecycle. (Space / search detail overlays have their own
    /// grids and never set this, so their flushes reorder as before.)
    var isDetailPresented = false

    /// The membership id the COLLECTION item-detail page is showing right now, or
    /// `nil` when it is down (355). A PLAIN flag for the same reason
    /// ``isDetailPresented`` is: nothing renders from it, and a publish would re-run
    /// the grid under the overlay on every step.
    ///
    /// It exists because two verbs that can take the shown item out of the feed are
    /// raised from surfaces that do not know what the page is showing — the detail
    /// sidebar's collection chips (which speak asset ids) and a drag out of the page
    /// onto a sidebar collection (which the outline view completes). Both need to arm
    /// a ``DetailStepIntent`` for the item ON SCREEN, and after however many ← / →
    /// steps that is neither the lead nor the route. `CollectionDetailHost` keeps it
    /// in step with `DetailSession`.
    var detailShownItemID: UUID?

    /// Per-asset view-count deltas that have been PERSISTED (`recordViews`) but not
    /// yet reflected in the local ``items`` (036 §3 B4). This is exactly
    /// `DB.view_count − items.viewCount` for every asset, so the invariant
    /// `items.viewCount + pendingReorderBumps == DB.view_count` holds at all times.
    /// It exists to survive a "skip when unchanged" reorder: when a flush's bumps
    /// don't move any item, its `items` publish is skipped, but the delta must NOT
    /// be lost — a LATER flush needs it to compute an order identical to what a real
    /// reload would produce. Cleared whenever ``loadContents(of:)`` re-syncs `items`
    /// to the database truth, and consumed by ``applyDeferredMostViewedReorder()``.
    private var pendingReorderBumps: [UUID: Int] = [:]

    /// Downloads a bare image URL (drag/paste with no bytes) off-main. Stateless +
    /// injectable; the default uses the shared session (tests inject a stub one).
    private let remoteFetcher = RemoteImageFetcher()
    /// Resolves a pasted PAGE url to link metadata (og:title / description / og:image),
    /// SSRF-walled (001 · C2b). Shares the SSRF posture with `remoteFetcher`.
    private let pageResolver = PageResolver()

    /// Ingest-timing log (16A). A stall means generating the eager thumbnail tiers
    /// dominated the ingest — the signal to make the largest tier lazy (P16).
    /// Above this thumbnail-phase time (ms) we log a stall. Tuned to catch the
    /// decode-heavy large tier without noise on ordinary small images.
    nonisolated private static let thumbnailStallMs = 250.0

    /// The pipeline's timing sink: log only a thumbnail STALL (keeps the log quiet
    /// on the common fast path + the P14 short-circuit). `nonisolated` static — no
    /// captured state, so it's safe to hand to the off-main pipeline.
    nonisolated private static func logIngestTiming(_ timing: IngestTiming) {
        guard timing.thumbnailMillis >= thumbnailStallMs else { return }
        let thumbMs = Int(timing.thumbnailMillis)
        let totalMs = Int(timing.totalMillis)
        let tiers = timing.tiersGenerated
        AppLog.ingestTiming.notice("thumbnail stall: \(thumbMs)ms for \(tiers) tiers (total \(totalMs)ms)")
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
    /// The current selection's asset ids in feed order (see `selectedAssetIDs`).
    private var cachedSelectedAssetIDs: [UUID] = []

    /// The loaded feed bucketed by originating post (307 · carousel grouping) —
    /// what makes "these four tiles are one Instagram carousel" answerable. Built
    /// here rather than in the view because a `CollectionView` body re-runs on
    /// every selection change and the bucketing is O(N) over the whole feed. This
    /// is the ONLY build site; the grid host mirrors it through the configuration.
    private(set) var postGroups = PostGroups()

    /// Whether the grid collapses each multi-image post to one tile (307). Mirrored
    /// from `GridViewPreferences` (which persists it) so the derivation can run
    /// where `items` lives; setting it re-derives, which also bumps `itemsVersion`
    /// and so invalidates the masonry layout cache — the display list changed even
    /// though `items` did not.
    ///
    /// `@Published` for the same reason `items` is: the derived values it feeds
    /// (``displayItems``, ``itemsVersion``) are deliberately plain, so this is the
    /// TRIGGER that has to re-run `CollectionView`'s body. Without it the toggle
    /// re-derives the display list into a model nobody re-reads, and the grid keeps
    /// showing the previous one until some unrelated publish happens to flush it.
    @Published var groupCarousels = true {
        didSet { if groupCarousels != oldValue { rebuildItemDerivations() } }
    }

    /// Representative ids of the posts currently OPENED in place (307) — their
    /// members show as their own tiles until the chip is clicked again. Pruned on
    /// every derivation so a representative that left the feed can't keep a post
    /// wedged open.
    ///
    /// `@Published` because ``CollectionView`` reads it straight into the grid
    /// configuration, and the chip click is the one interaction that deliberately
    /// does NOT touch the selection (the chip-zone branch of `gridCellMouseDown`,
    /// which toggles and returns) — so there is no other
    /// publish riding along to invalidate the body.
    @Published private(set) var expandedPosts: Set<UUID> = []

    /// Open or close the post behind the tile `itemID` — what the carousel chip does.
    /// A no-op for an ungrouped tile, so callers don't have to check first.
    func toggleExpansion(forItem itemID: UUID) {
        guard groupCarousels, postGroups.memberCount(forItem: itemID) > 1 else { return }
        let lead = postGroups.members(forItem: itemID).first ?? itemID
        if expandedPosts.contains(lead) {
            expandedPosts.remove(lead)
        } else {
            expandedPosts.insert(lead)
        }
        rebuildItemDerivations()
    }

    /// The feed AS THE GRID SHOWS IT: `items` with every multi-image post collapsed
    /// to its first member when grouping is on, otherwise `items` verbatim.
    ///
    /// This — not `items` — is what the grid renders and what the selection store
    /// orders. It is an array of the SAME element type, never longer than `items`,
    /// so the grid keeps one item per cell per selectable id and every index-based
    /// subsystem is untouched. Actions widen back to real members at the boundary via
    /// ``PostGroups/expand(_:)``.
    ///
    /// Its ORDER is the grid's order, and since 309 it is not merely a subsequence
    /// of `items`: an opened post's members are gathered into a contiguous run at
    /// the tile's slot. Nothing downstream resolves a tile through its index in
    /// `items` — layout, selection order, marquee and the reorder solve are all
    /// index-based over THIS list — so display order is the order they all mean.
    /// Only the persisted order (`manual_order`) is still `items`' business, and it
    /// is written by ``reorderItems(movingAssetIDs:insertAt:)`` alone: opening a
    /// post rearranges nothing on disk.
    private(set) var displayItems: [CollectionItemDetail] = []
    /// Membership ids of ``displayItems``, for O(1) "is this tile on screen?".
    private var displayItemIDs: Set<UUID> = []

    /// The feed AS THE DETAIL PAGE WALKS IT (069): every image, in the grid's order,
    /// with each post's images together and in the post's own order.
    ///
    /// The overlay stepped `items` raw until 069 — so its prev/next read the feed order
    /// 309 had already stopped using for the grid, and a post whose images a reorder had
    /// scattered was walked in pieces. This is ``displayItems``' sibling: same
    /// derivation site, same invalidation, differing only in that a post contributes all
    /// its images rather than one tile. The page is paging through IMAGES, so it is the
    /// one list that opens every post.
    private(set) var detailRun: [CollectionItemDetail] = []
    /// Position in ``detailRun`` by membership id — the overlay resolves the shown item
    /// to its pager index on every body pass, which was an `items.firstIndex` scan.
    private var detailRunIndexByItem: [UUID: Int] = [:]

    /// Where `id` sits in ``detailRun``, or `nil` when it isn't in the loaded feed.
    func detailRunIndex(of id: UUID) -> Int? { detailRunIndexByItem[id] }

    /// The item ids a TILE stands for, in feed order (307): a collapsed post's whole
    /// membership, or just the item itself when it is ungrouped, opened, or grouping
    /// is off. The ordered counterpart of ``widenedForAction(_:)``, used where the
    /// sequence matters — reordering, which must keep a post's images together.
    private func itemsRepresented(by displayItemID: UUID) -> [UUID] {
        guard groupCarousels else { return [displayItemID] }
        let members = postGroups.members(forItem: displayItemID)
        guard let lead = members.first, lead == displayItemID,
              !expandedPosts.contains(lead) else { return [displayItemID] }
        return members
    }

    /// The tile that STANDS FOR `id` in the current display list (307).
    ///
    /// `id` itself when it is on screen; otherwise its post's representative. The
    /// detail overlay steps through ALL items — including carousel members the grid
    /// is hiding — and syncs the cursor back on close, so without this the grid's
    /// lead could land on an id that isn't in the reducer's `order` at all, leaving
    /// arrow-key navigation with nothing to resolve against.
    func displayTile(for id: UUID) -> UUID {
        if displayItemIDs.contains(id) { return id }
        return postGroups.members(forItem: id).first ?? id
    }

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
        postGroups = PostGroups(items: items)
        // Drop expansions whose representative has left the feed (a delete, a move,
        // a collection switch) — otherwise a stale id would keep re-opening nothing,
        // and the set would grow for the life of the process. Assigned only when it
        // actually changes: `expandedPosts` is `@Published`, and the common case (an
        // empty set, every load) must not fire a publish from inside a derivation.
        let live = expandedPosts.filter { postGroups.memberCount(forItem: $0) > 1 }
        if live != expandedPosts { expandedPosts = live }
        displayItems = groupCarousels
            ? postGroups.collapsed(items, expanding: expandedPosts)
            : items
        displayItemIDs = Set(displayItems.map { $0.item.id })
        // The detail page's run (069) — derived HERE so it shares the display list's
        // invalidation exactly. A post contributes all its images (the page pages
        // through images), but at its tile's slot and in the post's order, so the page
        // and the grid can't tell different stories about where a carousel is.
        detailRun = groupCarousels ? postGroups.fullRun(items) : items
        detailRunIndexByItem = Dictionary(
            detailRun.enumerated().map { ($0.element.item.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        // Push the DISPLAYED order to the selection store (the reducer's `order`
        // argument) — replaces the old hoisted `itemOrder`. It has to be the display
        // list, not `items`: ⇧-range, arrow nav and the marquee all resolve hits
        // through this order, so a hidden carousel member in it would let a range
        // select a tile that isn't on screen.
        selectionStore.setOrder(displayItems.map { $0.item.id })
        // Keyed over ALL items, not just the displayed ones: an action on a collapsed
        // tile expands to its hidden members and still needs their asset ids.
        assetIDByItemID = Dictionary(
            items.map { ($0.item.id, $0.asset.id) }, uniquingKeysWith: { first, _ in first })
        // Items changed, selection didn't — rebuild the cache against the store's
        // CURRENT (settled) selection. Safe to read here: no `willSet` is in
        // flight, unlike inside the `$selection` sink below.
        rebuildSelectedAssetIDs(for: selectionStore.selection)
    }

    /// Rebuild the selected-asset-id cache after `items` or `selection` changes.
    /// Preserves feed order (mirrors the old `items.filter { … }.map` exactly).
    ///
    /// Takes the selection EXPLICITLY rather than reading `self.selection`: when
    /// driven by the `$selection` sink, `@Published` fires on `willSet`, so the
    /// store's stored `selection` still holds the OLD value at that instant — the
    /// computed `self.selection` would read stale. The sink passes the NEW value.
    private func rebuildSelectedAssetIDs(for selection: GridSelection) {
        cachedSelectedAssetIDs = assetIDs(for: widenedForAction(selection.ids))
    }

    /// Widen ids to whole posts for an action — but only where the grid is actually
    /// HIDING members (307).
    ///
    /// A collapsed tile stands for its post, so it must widen. An OPENED post shows
    /// every member as its own tile, and those tiles have to act individually —
    /// otherwise opening a carousel to delete one bad frame would delete all four,
    /// which is precisely the thing someone opens a post to avoid.
    private func widenedForAction(_ ids: Set<UUID>) -> Set<UUID> {
        guard groupCarousels else { return ids }
        var result = Set<UUID>()
        result.reserveCapacity(ids.count)
        for id in ids {
            let members = postGroups.members(forItem: id)
            guard let lead = members.first, !expandedPosts.contains(lead) else {
                result.insert(id)
                continue
            }
            result.formUnion(members)
        }
        return result
    }

    /// ``widenedForAction(_:)`` as a seam for the readers that never leave
    /// MEMBERSHIP-id space — ⌘C, the two exports, and Quick Look, all of which take
    /// a `Set<CollectionItem.id>` rather than asset ids.
    ///
    /// Every asset-id verb already widens on its way through ``selectedAssetIDs`` or
    /// ``actionTargets(forCellItemID:)``, so those callers never see this. The item-id
    /// readers had no such funnel and so quietly skipped the widening entirely: ⌘C on a
    /// tile reading ⧉4 copied one image, and Space previewed one. Exposing the rule —
    /// rather than letting each surface re-derive "which ids does this act on" — is the
    /// same argument ``assetIDs(for:)`` makes one line down.
    ///
    /// An empty set widens to an empty set, which the exports rely on: they read empty
    /// as "no selection, take the whole collection".
    func itemIDsForAction(_ ids: Set<UUID>) -> Set<UUID> { widenedForAction(ids) }

    /// The asset behind a membership id, or `nil` when the item has left the loaded
    /// feed. O(1) off the same index the drag/action scope uses.
    ///
    /// For the single-item verbs that must act on the TILE rather than on its post —
    /// Set as Cover, where the cover wanted is the post's own cover, i.e. the
    /// representative the collapsed tile is already showing. Widening there and taking
    /// `.first` would pick the post's earliest member in FEED order, which a reorder or
    /// a partial move can drift away from carousel image #1.
    func assetID(forItem itemID: UUID) -> UUID? { assetIDByItemID[itemID] }

    /// The asset ids for `itemIDs`, in feed order — THE action boundary (307).
    ///
    /// Callers pass ids already widened through ``PostGroups/expand(_:)``, so a
    /// selection holding one collapsed tile yields all four of its assets. Doing the
    /// widening here (and in ``actionTargets(forCellItemID:)``) rather than in each
    /// verb is what makes delete / move / remove / drag fan out consistently instead
    /// of each remembering to. Walks `items`, not `displayItems`: the hidden members
    /// are exactly what we are widening to.
    private func assetIDs(for itemIDs: Set<UUID>) -> [UUID] {
        items.compactMap { itemIDs.contains($0.item.id) ? $0.asset.id : nil }
    }

    /// The asset ids a batch action should act on for a right-click on the cell
    /// whose membership id is `itemID` (Finder scope, 009 · 7A): the WHOLE
    /// selection when that cell is part of it, else just that one cell — the
    /// selection is left untouched either way.
    ///
    /// The rule itself is the pure ``gridActionTargets(isSelected:selectedAssetIDs:cellAssetID:)``
    /// (036 §4 C4), so the container-level context menu and this model seam can
    /// never diverge on scope, and the rule is unit-tested off the main actor.
    func actionTargets(forCellItemID itemID: UUID) -> [UUID] {
        gridActionTargets(
            isSelected: selection.ids.contains(itemID),
            selectedAssetIDs: selectedAssetIDs,
            // A collapsed carousel tile stands for its whole post (307), so an
            // UNSELECTED right-click widens too — otherwise "Delete" on a tile
            // reading ⧉4 would remove one image and leave the tile behind.
            cellAssetIDs: assetIDs(for: widenedForAction([itemID])))
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
    /// Drives ``ContentView``'s confirmation dialog; `nil` when none staged.
    @Published var pendingSpaceDeletion: PendingSpaceDeletion?

    /// The space staged for a confirmed, undoable delete.
    struct PendingSpaceDeletion {
        let id: UUID
        let name: String
    }

    init() {
        observeSelection()
        Task { await bootstrap() }
    }

    /// Test-only: inject an already-open library (no capture endpoint / snapshot
    /// orchestration) so the destructive verbs + their undo can be driven
    /// deterministically — mirrors ``SpaceModel``'s injectable init. Callers load
    /// the tree with ``refreshFolders()``.
    init(services: AppServices, store: MediaStore) {
        self.services = services
        self.store = store
        self.selectedFolderID = services.unsortedFolderID
        self.isReady = true
        observeSelection()
    }

    /// Rebuild the `selectedAssetIDs` cache whenever the store publishes a new
    /// selection — the Combine replacement for the old `selection.didSet`. The
    /// closure receives the NEW value (see ``rebuildSelectedAssetIDs(for:)`` on
    /// why we must not re-read `self.selection` here). `@Published` emits the
    /// current value on subscribe, so the cache is seeded (empty) immediately.
    private func observeSelection() {
        selectionCancellable = selectionStore.$selection
            .sink { [weak self] newSelection in
                self?.rebuildSelectedAssetIDs(for: newSelection)
            }
    }

    // MARK: - Bootstrap

    /// Open (or create) the Library under Application Support and wire the
    /// pipeline + coordinator. The v2 migration guarantees the Unsorted folder,
    /// so nothing is seeded here. Loads the folder tree + Unsorted's contents.
    private func bootstrap() async {
        do {
            // `resolvedRoot` is `defaultRoot` unless the `-library-root` launch
            // argument / `ATELIER_LIBRARY_ROOT` is supplied — the throwaway-library
            // escape hatch used by the grid bake-off, never hit in normal launches.
            let root = try LibraryLocation.resolvedRoot()
            self.libraryRoot = root
            let layout = LibraryLayout(root: root)
            let store = MediaStore(layout: layout)
            let dbURL = layout.root.appendingPathComponent("library.sqlite")
            // A staged restore (008 H3) is applied here — before any connection
            // opens — the only safe time to swap the live database file.
            let didRestore = SnapshotManager.applyPendingRestore(
                snapshotsDir: layout.snapshots, livePath: dbURL)
            // If that restore came from an off-device backup (008 H5c), this
            // library IS now the backed-up library and takes its id, so future
            // backups keep updating the same folder instead of starting a second
            // copy beside it. Only ever on a restore that actually landed.
            SnapshotManager.applyPendingIdentityAdoption(
                snapshotsDir: layout.snapshots, libraryRoot: root, restored: didRestore)
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

            // Backup hygiene (008 H2): keep regenerable thumbnails/cache out of
            // Time Machine / iCloud. Idempotent, cheap; safe to run every launch.
            store.excludeDerivedFromBackup()

            // Snapshot orchestration (008 H3): daily-on-launch + pre-destructive
            // + manual, over the snapshots/ directory.
            let snapshots = SnapshotManager(
                services: services, directory: layout.snapshots)
            self.snapshotManager = snapshots
            // Normally false here — the restore this launch was asked for has
            // just been applied and its marker consumed — but a restore that
            // was staged and then refused leaves one behind, and the Backup
            // section has to say why its buttons are off.
            refreshPendingRestore()

            // The safety nets must not fail silently (008 review, 8A): if the
            // last open migrated the library WITHOUT its pre-migration snapshot,
            // say so — once — and point at the manual remedy.
            if snapshots.consumePreMigrationSnapshotFailure() {
                AppLog.model.error(
                    "pre-migration snapshot failed; library migrated without a safety copy")
                notify("Couldn't take the pre-update safety snapshot — "
                    + "consider Snapshot Now in Settings.")
            }

            // Any sweep still "open" at launch is abandoned (nothing is running yet),
            // so reconcile it to paused — otherwise a tab closed mid-sweep last session
            // would show as a phantom "running" job forever.
            _ = try? await services.pauseStaleOpenJobs(olderThan: 0, now: Date())

            // Enforce known ⟺ blob present: forget any ledger row whose blob was
            // removed outside deleteAssets, so a future sweep re-imports that source
            // instead of dedup-skipping bytes that are gone.
            _ = try? await services.reconcileOrphanedKnownItems()

            // Ambient clipboard capture (013 · K3). Bound here, after the library
            // is open: its preference is namespaced by library id, and nothing
            // ambient should be able to run before the app knows where it would
            // file what it takes. Off unless the user turned it on before.
            activateClipboardWatcher(root: root)
            // The backup cadence is per-library for the same reason (008 H5d):
            // two libraries pointed at one folder must be able to disagree about
            // how often they copy themselves into it. A library whose id can't
            // be resolved keeps the default in memory and simply never persists
            // a change — it also can't be backed up at all, which the run path
            // already reports in its own words.
            if let libraryID = try? LibraryIdentity.resolve(root: root) {
                backup.activate(libraryID: libraryID)
            }

            await refreshFolders()
            // Spaces load here too — the sidebar's `.task` can run BEFORE this
            // bootstrap slice sets `services` (observed in practice), in which case
            // its `refreshSpaces()` silently no-ops; bootstrap owns the load so the
            // list can't depend on task-scheduling order.
            await refreshSpaces()
            loadContents(of: selectedFolderID)
            await startCaptureEndpoint(coordinator: coordinator, services: services)
            // The second producer, on the same coordinator as the first (092 · S3).
            // After the endpoint rather than before it only because both are cheap
            // and this is the one that touches the disk.
            activateInboxDrain(libraryRoot: root, coordinator: coordinator)

            // Reclaim blobs orphaned by deletes that were never undone (010 ·
            // delete-undo). Off-main, after the UI is up; the undo history is empty
            // at launch, so any unreferenced blob is unreachable.
            //
            // EXCEPT on the first launch after a restore (008 review, 3A): the
            // restored DB is older than the disk, so "unreferenced" includes media
            // captured AFTER the snapshot — reaping now would silently trash it.
            // That launch reconciles and REPORTS both divergence directions
            // instead; the next launch's GC reclaims whatever isn't rescued.
            if snapshots.consumeJustRestored() {
                runPostRestoreBlobReconcile(services: services, store: store)
            } else {
                runOrphanBlobGC(services: services, store: store)
            }

            // Daily-on-launch snapshot if the newest daily is >1 day stale (008
            // H3, confirmed on-by-default). Fired AFTER content loads (008
            // review, 13A): the `VACUUM INTO` cost grows with the DB (analysis
            // tables), and it has no ordering dependency on anything above — a
            // concurrent capture write just queues behind the writer briefly.
            // Best-effort; never blocks or disrupts launch.
            Task { await snapshots.snapshotIfStale() }

            // The off-device backup on the same terms (008 H5d): a background
            // task, after everything above, gated on the user's cadence. It
            // deliberately sits BELOW the daily snapshot — a snapshot is local,
            // bounded and fast; a backup can be tens of gigabytes over USB, and
            // whichever of the two is going to be slow must not be the one the
            // other waits behind. Best-effort, cancellable from Settings, and a
            // no-op unless a folder is chosen and the last good run is stale.
            Task { [weak self] in await self?.backUpIfStale() }

            // Wire the (previously dormant) on-device analysis pipeline: an idle
            // .background loop that drains OCR/colors/phash then the semantic
            // embeddings, resumable across launches (047 · 3a · 6A).
            let analysisCoordinator = AnalysisCoordinator(services: services, store: store)
            analysisTask = Task.detached(priority: .background) {
                await analysisCoordinator.run()
            }
        } catch {
            self.lastError = "Failed to open library: \(error)"
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
                guard let self else { return }
                Task { @MainActor in
                    self.handleRemoteCapture(collectionID: collectionID, outcomes: outcomes)
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
            port: capturePort,
            auth: CaptureAuth(token: token), routes: routes, jobRoutes: jobRoutes)
        self.captureServer = server

        do {
            try await server.start()
            captureEndpointRunning = true
        } catch {
            captureEndpointRunning = false
            // Only the FAILURE is worth saying out loud: the extension silently stops
            // working, and `captureEndpointRunning` alone is buried in the Capture pane.
            notify("Capture endpoint unavailable — port \(capturePort) is in use.")
        }
    }

    // MARK: - The inbox (092 · S3)

    /// Wire the iOS handoff: drain `inbox/` at launch and on every activation.
    ///
    /// Everything about WHEN lives in ``InboxDrainScheduler`` — including the
    /// guard against two passes overlapping — so this is a call site and nothing
    /// more. The drain feeds the SAME bounded `IngestCoordinator` the capture
    /// endpoint and every paste/drag do; a second runner would be two things
    /// deciding independently how much of the machine to spend decoding images.
    private func activateInboxDrain(libraryRoot: URL, coordinator: IngestCoordinator) {
        let drain = InboxDrain(libraryRoot: libraryRoot, coordinator: coordinator)
        let scheduler = InboxDrainScheduler(
            // A pass reports counts, not outcomes, and it resolves each record's
            // OWN target collection — so the refresh is told "somewhere", not
            // where. See ``refreshAfterIngest(touching:)``.
            pass: { await drain.drainOnce() },
            onIngest: { [weak self] in self?.refreshAfterIngest(touching: nil) })
        inboxDrain = scheduler
        scheduler.start()
    }

    // MARK: - Capture feedback

    /// Bring the live UI back in step with a library some producer OTHER than the
    /// user just wrote to: refresh the tree's counts, and reload the visible
    /// folder if it may have received something.
    ///
    /// `collectionID` is the collection that received the items; `nil` means the
    /// producer cannot say — an inbox pass resolves each record's own target and
    /// reports only counts — in which case the visible folder is reloaded
    /// unconditionally. That is a wasted query when the drain landed elsewhere,
    /// and it is the honest response to not knowing: the alternative is a grid
    /// that silently omits a capture the user just watched arrive.
    private func refreshAfterIngest(touching collectionID: UUID?) {
        Task { await refreshFolders() }
        if collectionID == nil || collectionID == selectedFolderID {
            loadContents(of: selectedFolderID)
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
        refreshAfterIngest(touching: collectionID)
        // A successful capture already raises its own "Saved N — Jump" toast below;
        // only the failure needs saying, since nothing else reports it.
        if imported == 0 { notify("A browser capture failed.") }
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

    /// Copy the capture token to the pasteboard (for pasting into the extension),
    /// and raise a toast confirming it.
    ///
    /// The confirmation lives HERE rather than at the button, so all three copy
    /// surfaces (the Capture pane, the Settings row, the onboarding guide) report
    /// identically — the alternative was three buttons each remembering to say so.
    func copyCaptureToken() {
        guard !captureToken.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(captureToken, forType: .string)
        notify(CaptureCopy.tokenCopied)
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
            notify("Capture token regenerated — re-pair the extension.")
        }
    }

    /// Reveal the Library root in Finder (Settings "Show in Finder").
    func revealLibraryInFinder() {
        guard let libraryRoot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([libraryRoot])
    }

    // MARK: - Off-device backup target (008 H4)

    /// Re-read the chosen backup folder and publish either its URL or the reason
    /// it can't be reached. Cheap enough to call whenever Settings appears, and
    /// deliberately re-run there: an external drive can be unplugged between two
    /// visits, and a target shown as fine when it isn't is worse than no target.
    func refreshBackupFolder() {
        guard backupFolder.hasFolder else {
            backupFolderURL = nil
            backupFolderMessage = nil        // "none chosen" is a state, not a fault
            return
        }
        do {
            backupFolderURL = try backupFolder.resolve()
            backupFolderMessage = nil
        } catch let error as FolderAccessError {
            // The bookmark is KEPT (see `StoredFolderAccess.resolve`), so the row
            // still shows a target — with the reason it's unreachable beside it.
            backupFolderURL = nil
            backupFolderMessage = BackupTarget.message(for: error)
        } catch {
            backupFolderURL = nil
            backupFolderMessage = BackupTarget.message(for: .bookmarkUnresolvable)
        }
    }

    /// Adopt a folder the picker just granted, after vetting it.
    func setBackupFolder(_ url: URL) {
        if let rejection = BackupTarget.rejection(choosing: url, libraryRoot: libraryRoot) {
            backupFolderURL = nil
            backupFolderMessage = BackupTarget.message(for: rejection)
            return
        }
        do {
            try backupFolder.setFolder(url)
            refreshBackupFolder()
        } catch {
            // `setFolder` persists nothing when the bookmark can't be made, so
            // there is no half-chosen target to clean up here.
            AppLog.model.error("backup folder bookmark failed: \(error, privacy: .public)")
            backupFolderURL = nil
            backupFolderMessage = BackupTarget.couldNotRemember
        }
    }

    /// Forget the target entirely.
    func clearBackupFolder() {
        backupFolder.clearFolder()
        refreshBackupFolder()
        // A "last backed up 2 days ago" line about a folder the app no longer
        // has would be true and useless — and read as though the backup is
        // still current.
        backup.forgetLastRun()
        // Same for a verdict about that folder's contents (008 H5d).
        verify.forgetLastRun()
    }

    // MARK: - Off-device backup runs (008 H5)

    /// Whether a run can start: an open library and a reachable target.
    ///
    /// Blocked while a restore is staged (008 H5c). The database this library is
    /// about to discard is not the one to push off-device — and if the staged
    /// restore came from THIS target, backing up now would overwrite the very
    /// backup the user is one relaunch away from restoring.
    var canRunBackup: Bool {
        services != nil && store != nil && libraryRoot != nil
            && backupFolder.hasFolder && !backup.isRunning
            && !restore.isRunning && !verify.isRunning && !hasPendingRestore
    }

    /// Copy everything the target is missing, then the database, then the
    /// manifest. The controller owns the progress and the outcome; this is the
    /// glue that hands it an open library.
    func runBackupNow() {
        guard let services, let store, let libraryRoot, canRunBackup else { return }
        backup.start(
            services: services, source: store, libraryRoot: libraryRoot,
            folder: backupFolder, appVersion: Self.appVersion)
    }

    /// The launch-time cadence check (008 · H5d), called from a background task
    /// once the library is up.
    ///
    /// Every real decision — cadence, staleness, whether the bookmark resolves —
    /// lives on the controller, where it is testable without a model. What
    /// belongs here is only what the model knows: that a library is open, and
    /// that a restore is pending.
    func backUpIfStale() async {
        guard let services, let store, let libraryRoot, canRunBackup else { return }
        await backup.backUpIfStale(
            services: services, source: store, libraryRoot: libraryRoot,
            folder: backupFolder, appVersion: Self.appVersion,
            restorePending: hasPendingRestore)
    }

    /// The running app's marketing version, recorded in the backup manifest.
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    // MARK: - Verifying the backup (008 H5d)

    /// Whether a check can start. Not blocked by a pending restore: reading the
    /// destination changes nothing there, and a user about to restore from a
    /// backup has more reason to want it verified than anyone.
    var canVerifyBackup: Bool {
        isReady && libraryRoot != nil && backupFolder.hasFolder
            && !backup.isRunning && !restore.isRunning && !verify.isRunning
    }

    /// Re-hash the backup and report what disagrees.
    ///
    /// - Parameter exhaustive: `false` checks a capped sample; `true` checks
    ///   every file, which downloads the whole backup from a synced destination.
    ///   Two buttons rather than one with a modifier, because the second one
    ///   costs real money on a metered connection and should never be reachable
    ///   by accident.
    func verifyBackupNow(exhaustive: Bool = false) {
        guard let libraryRoot, canVerifyBackup else { return }
        verify.start(
            libraryRoot: libraryRoot, folder: backupFolder, exhaustive: exhaustive)
    }

    // MARK: - Restore from the backup folder (008 H5c)

    /// Whether a restore is already staged and waiting for a relaunch.
    ///
    /// Cached rather than a `fileExists` per read: it gates two buttons and a
    /// status line in a form that re-renders on every progress tick, and 016's
    /// rule stands — nothing in Settings `stat`s a file per render. Refreshed
    /// where it can actually change: at bootstrap, whenever the Settings window
    /// appears, and immediately after either staging path.
    @Published private(set) var hasPendingRestore = false

    /// Re-read whether a restore is staged.
    func refreshPendingRestore() {
        hasPendingRestore = snapshotManager?.hasPendingRestore() ?? false
    }

    /// Whether the restore sheet can be opened: an open library, a chosen
    /// folder, and nothing else in flight.
    var canRestoreBackup: Bool {
        store != nil && libraryRoot != nil && snapshotManager != nil
            && backupFolder.hasFolder && !backup.isRunning && !restore.isRunning
            && !verify.isRunning && !hasPendingRestore
    }

    /// Open the restore sheet and start reading the backup folder.
    func beginRestoreFromBackup() {
        guard canRestoreBackup else { return }
        showRestoreBackups = true
        restore.scan(folder: backupFolder)
    }

    /// Copy `source` back into this library and stage its database as the next
    /// launch's restore.
    ///
    /// The pre-destructive snapshot comes FIRST: the restore replaces the live
    /// database, and `snapshotBeforeDestruction()` is freshness-gated, so this
    /// is cheap and usually a no-op. It is also the only route back if the user
    /// restores the wrong backup.
    func restoreFromBackup(_ source: BackupSource) {
        guard let store, let snapshots = snapshotManager, canRestoreBackup else { return }
        showRestoreBackups = false
        Task { [weak self] in
            guard let self else { return }
            _ = try? await snapshots.snapshotBeforeDestruction()
            self.restore.start(
                source: source, live: store,
                snapshotsDirectory: snapshots.directory, folder: self.backupFolder
            ) { [weak self] snapshot, source in
                self?.stageRestoredBackup(snapshot, from: source, snapshots: snapshots)
            }
        }
    }

    /// Hand the restored database to the SHIPPED restore seam, and record the
    /// identity the library adopts once that restore actually lands.
    ///
    /// Order matters: the identity request is written only after `stageRestore`
    /// accepted the snapshot, so a refused (unhealthy) database leaves no
    /// pending id behind to fire after some unrelated later restore.
    private func stageRestoredBackup(
        _ snapshot: URL, from source: BackupSource, snapshots: SnapshotManager
    ) {
        guard let file = SnapshotFile(url: snapshot) else {
            lastError = BackupTarget.unknownRestoreFailure
            return
        }
        do {
            try snapshots.stageRestore(file)
            // This library is about to BE the backed-up library, so it must keep
            // backing up into that library's folder rather than minting a fresh
            // one and stranding the backup it just restored from.
            try? snapshots.stageIdentityAdoption(source.libraryID)
            refreshPendingRestore()
            restoreStagedMessage = BackupTarget.restoreStaged
        } catch {
            lastError = "Couldn’t stage the restore: \(Self.message(for: error))"
        }
    }

    // MARK: - Portable archive (008 H6)

    /// Whether an archive can be written: an open library and nothing already
    /// writing one.
    ///
    /// Deliberately NOT blocked by a pending restore, unlike ``canRunBackup``.
    /// An archive only reads, and a user one relaunch away from replacing their
    /// library is exactly the user who might want a portable copy of what it
    /// holds right now.
    var canArchiveLibrary: Bool {
        services != nil && store != nil && !archive.isExporting
    }

    /// Ask where to put the archive, then write it there.
    ///
    /// The save-panel grant is wrapped in a ``DirectFolderAccess`` rather than a
    /// bookmark: it lasts as long as this process, which is longer than the run.
    func archiveLibrary() {
        guard let services, let store, canArchiveLibrary else { return }
        let version = Bundle.main
            .infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let root = libraryRoot
        ArchiveFolderPanel.present(suggestedName: ArchiveCopy.suggestedName()) {
            [weak self] url in
            guard let self, let url else { return }
            // The rule the backup target already carries (008 · H4), applied to
            // the other destination the user picks. An archive written inside the
            // library would sit in the folder every snapshot, size report and
            // future archive walks — and the NEXT archive would copy it in
            // wholesale. Unbounded rather than merely untidy.
            if let root, BackupTarget.isSelfOrDescendant(url, of: root) {
                self.archive.reject(ArchiveCopy.insideLibrary)
                return
            }
            self.archive.start(
                services: services, store: store,
                folder: DirectFolderAccess(url: url), appVersion: version)
        }
    }

    /// Reveal the archive a run just wrote.
    func revealArchive() {
        guard let url = archive.lastRun?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Archive import (008 H7)

    /// Whether an archive can be read in: an open library, neither archive job
    /// already running, and no restore waiting.
    ///
    /// Blocked by an export in flight — not because the two would corrupt each
    /// other, but because "is something running?" must stay unambiguous per
    /// feature, and one progress bar cannot mean two things.
    ///
    /// Blocked by a pending restore for a much harder reason: `applyPendingRestore`
    /// replaces the live database at the next launch, so every row an import
    /// writes between staging and relaunch is discarded — the user would watch a
    /// progress bar fill, read "imported 900 items", quit as instructed, and find
    /// nothing. Unlike ``canArchiveLibrary``, which only reads, this one writes,
    /// and the write is the thing that gets thrown away.
    var canImportArchive: Bool {
        services != nil && store != nil
            && !archiveImport.isImporting && !archive.isExporting
            && !hasPendingRestore
    }

    /// Ask which archive to read, then replay it into a new root collection.
    ///
    /// The pre-destructive snapshot is handed to the controller rather than
    /// taken here, so it runs at the one moment that is correct: after the
    /// archive has proved readable, before the first row is written. A refused
    /// archive therefore costs nothing at all.
    func importArchive() {
        guard let services, let store, canImportArchive else { return }
        let snapshots = snapshotManager
        ArchiveFolderPanel.presentImport { [weak self] url in
            guard let self, let url else { return }
            self.archiveImport.start(
                services: services, store: store,
                folder: DirectFolderAccess(url: url),
                snapshot: { _ = try? await snapshots?.snapshotBeforeDestruction() }
            ) { [weak self] in
                // Whatever the outcome — a cancelled import keeps what it wrote,
                // so the sidebar and the grid have to reload either way.
                self?.reloadAfterMembershipChange()
            }
        }
    }

    // MARK: - Library stats + maintenance (016 · A)

    /// Whether a stats scan or a cleanup job can start: an open library, and
    /// nothing already running.
    var canRunLibraryJob: Bool {
        services != nil && store != nil && !libraryStats.isRunning
    }

    /// Start one confirmed maintenance job. The glue only hands the controller
    /// an open library — every job below is a call into a service that already
    /// existed, which is the whole design of 016 · A.
    ///
    /// ``LibraryStatsController/Job/scan`` aside, the destructive-adjacent work
    /// is `MediaReaper`'s and `AppServices`'s; nothing new decides what to
    /// remove. "Snapshot now" is deliberately absent — it is `snapshotNow()`,
    /// the SAME call File ▸ Snapshot Now makes, and duplicating it here would
    /// give the app two manual-snapshot paths to keep in step.
    func runLibraryJob(_ job: LibraryStatsController.Job) {
        guard let services, let store, canRunLibraryJob else { return }
        switch job {
        case .scan: libraryStats.measure(services: services, store: store)
        case .orphanSweep: libraryStats.runOrphanSweep(services: services, store: store)
        case .thumbnails: libraryStats.regenerateThumbnails(services: services, store: store)
        case .integrity: libraryStats.verifyIntegrity(services: services)
        case .reconcile: libraryStats.reconcileKnownItems(services: services)
        }
    }

    /// Reveal a largest-items row's blob in Finder. Same path as the detail
    /// page's Reveal — the file is named from the hash + mime, not re-derived.
    func revealInFinder(largestItem item: LargestItem) {
        guard let url = blobURL(forBlobHash: item.blobHash, mimeType: item.mimeType),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open a largest-items row's blob in the default app (Preview, QuickTime).
    ///
    /// The row's OTHER natural action — open the in-app detail page — is not
    /// offered, and the omission is deliberate. The detail overlay is routed by
    /// `NavModel.presentedItemID` over the main window's currently loaded
    /// collection; Settings is a separate scene with no `NavModel` in reach, so
    /// wiring it would mean building cross-window navigation. 016 · A is a read
    /// layer plus buttons on existing services, and this is the existing way to
    /// look at a file full-size from anywhere in the app.
    func openBlob(largestItem item: LargestItem) {
        guard let url = blobURL(forBlobHash: item.blobHash, mimeType: item.mimeType),
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Delete every asset that references a largest-items row's blob.
    ///
    /// Deletes ALL of them because the row is a FILE: removing one of three
    /// assets that share a blob reclaims nothing, and a "free 240 MB" action
    /// that frees nothing is worse than no action.
    ///
    /// Goes through the SAME two calls the grid, inspector and canvas use —
    /// stage, then confirm — so the pre-destructive snapshot, the recoverable
    /// backup and the ⌘Z registration happen exactly as they do everywhere else.
    /// Both run in one main-actor turn, so `ContentView`'s shared confirmation
    /// dialog never observes the staged state: the confirmation the user
    /// answered was the one in Settings, beside the row they were looking at.
    func deleteLibraryItem(_ item: LargestItem) {
        requestDelete(assetIDs: item.assetIDs)
        confirmPendingDeletion()
        // The bytes are still on disk: reaping is DEFERRED so an in-session ⌘Z
        // finds them (010 · delete-undo). The measurement above is therefore
        // stale in items but not yet in size — say so rather than redraw a
        // number nobody recomputed.
        libraryStats.markStale()
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
            notify("Diagnostics exported.")
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
    nonisolated static let bulkConsentKey = "AtelierBulkConsentGranted"

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
        /// Temporary failures (429/timeout/5xx) — a retry can recover these.
        var retryableFailed: Int { counts[.retryableFailed] ?? 0 }
        /// Permanent failures (404/unsupported/decode) — a retry won't help.
        var permanentFailed: Int { counts[.permanentFailed] ?? 0 }
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
            _ = try? await services.pauseStaleOpenJobs(olderThan: Self.staleSweepSeconds, now: Date())
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

    /// Retry a terminal sweep's failures (034 P2): re-open the job so the next
    /// browser run re-attempts everything not yet ingested. Only ingested/deduped
    /// items are in the download-skip set, so failed items ARE re-tried; this is the
    /// actionable exit from the "Failed N" dead-end. Same write as resume.
    func retrySweep(_ id: UUID) { setSweepStatus(id, .open) }

    /// The failed items of a sweep (retryable + permanent), newest change first, for
    /// the row's expandable failure list. Empty on error / no failures.
    func sweepFailures(jobID: UUID) async -> [JobItem] {
        guard let services else { return [] }
        let failed: Set<JobItemStatus> = [.retryableFailed, .permanentFailed]
        let items = (try? await services.jobItems(forJob: jobID)) ?? []
        return items
            .filter { failed.contains($0.status) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

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
    ///
    /// `lazy` only because the callback needs `self`; it is created on the first
    /// undoable write and never replaced.
    private lazy var undoStack = UndoStack { [weak self] in self?.undoToken &+= 1 }

    /// Bumped on every register / undo / redo so the Edit menu's enabled state +
    /// action names refresh (UndoManager isn't `ObservableObject`).
    @Published private(set) var undoToken = 0

    /// Await the tail of the undoable write chain — for tests to observe a settled
    /// (committed) state after an edit / undo / redo.
    func waitForWrites() async { await undoStack.waitForWrites() }

    /// Append `work` to the serial undoable write chain (FIFO, strictly ordered).
    private func enqueueUndoable(_ work: @escaping () async -> Void) {
        undoStack.enqueue(work)
    }

    /// Register an already-performed action as its own closed undo group:
    /// `inverse` runs on undo, `primary` re-runs on redo, ping-ponging. Neither
    /// runs now.
    private func registerReversible(_ name: String,
                                    primary: @escaping () -> Void,
                                    inverse: @escaping () -> Void) {
        undoStack.registerReversible(name, primary: primary, inverse: inverse)
    }

    var canUndo: Bool { undoStack.canUndo }
    var canRedo: Bool { undoStack.canRedo }
    var undoActionName: String { undoStack.undoActionName }
    var redoActionName: String { undoStack.redoActionName }

    func undo() { undoStack.undo() }
    func redo() { undoStack.redo() }

    /// Publish a just-performed reversible verb so the shell shows a "…— Undo" toast
    /// (034 P1). Call AFTER `registerReversible` so `undoToken` already reflects this
    /// action as the top of the stack.
    ///
    /// EVERY `registerReversible` is followed by one of these. The five verbs that
    /// used to skip it (rename, move folder, reorder, move space, delete space) had
    /// a working undo the user was never told about — worst of all space delete,
    /// which 034 batch 1 made recoverable specifically so it could be reversed.
    private func announceUndoable(_ message: String) {
        lastUndoableAction = UndoableActionEvent(message: message, undoToken: undoToken)
    }

    /// Publish a one-off notice for the shell to raise as a plain toast.
    ///
    /// NOT for a verb that also calls ``announceUndoable(_:)`` — that raises the same
    /// sentence WITH an Undo button, and posting both would say it twice. Where the
    /// two used to overlap (the old `status = message` beside an announce) the notice
    /// is the one that goes.
    private func notify(_ message: String) {
        noticeSeq &+= 1
        lastNotice = Notice(message: message, seq: noticeSeq)
    }

    /// Fire an Undo toast's button: reverse the action ONLY if it's still the top of
    /// the undo stack (`token` unchanged since the toast was posted). If any later
    /// action / undo / redo bumped `undoToken`, this toast is stale — no-op, so it
    /// can't silently undo something the user didn't mean.
    func undoLastAction(expecting token: Int) {
        guard undoToken == token, canUndo else { return }
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

    /// Reparent and/or reposition a folder, then refresh. `index` is the destination
    /// slot (nil = append); it flows straight to `moveCollection` (043 · Phase C).
    private func applyMoveFolder(id: UUID, toParent parent: UUID?, index: Int? = nil) async {
        guard let services else { return }
        do {
            try await services.moveCollection(id: id, toParent: parent, index: index)
            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    /// Set `folder`'s grid order to `desired`, filtered to current members so a
    /// concurrently-deleted asset can't throw `.notFound`.
    private func applyOrder(folder: UUID, desired: [UUID]) async {
        guard let services, !desired.isEmpty else { return }
        do {
            let members = Set(try await services.collectionItems(in: folder, includeArchived: false).map { $0.asset.id })
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

    /// Drop memberships from `folder` and refresh.
    ///
    /// It used to take a `message` to publish on the primary run only. The verb's
    /// ``announceUndoable(_:)`` says the same sentence with an Undo button, so the
    /// parameter only existed to say it twice.
    private func applyRemove(assetIDs: [UUID], from folder: UUID) async {
        guard let services else { return }
        do {
            try await services.removeAssets(assetIDs, from: folder)
            await refreshFolders()
            selectedFolderID = folder
            loadContents(of: folder)
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
    private func applyMoveAssets(_ assetIDs: [UUID], from source: UUID, to target: UUID) async {
        guard let services else { return }
        do {
            try await services.moveAssets(assetIDs, from: source, to: target)
            await refreshFolders()
            selectedFolderID = source
            loadContents(of: source)
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

    /// Create a folder (root when `parent == nil`, else a subfolder). `onCreated`
    /// fires with the created collection AFTER ``refreshFolders`` has published it,
    /// so a caller that activates the new folder (the sidebar's select-on-create)
    /// finds its row already in the tree — selecting it before the refresh would
    /// leave the outline unable to resolve the row.
    func createFolder(name: String, parent: UUID?, onCreated: ((Collection) -> Void)? = nil) {
        guard let services else { return }
        Task {
            do {
                let created = try await services.createCollection(name: name, parent: parent)
                await refreshFolders()
                onCreated?(created)
                loadContents(of: selectedFolderID)
            } catch {
                lastError = Self.message(for: error)
            }
        }
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
            announceUndoable("Renamed “\(oldName)” to “\(name)”.")
        }
    }

    /// Delete a folder and its whole subtree. Rejected for Unsorted.
    func deleteFolder(id: UUID) {
        guard id != unsortedFolderID else { return }
        perform(after: id == selectedFolderID) { services in
            try await services.deleteCollection(id: id)
        }
    }

    /// Reparent and/or reposition a folder (`nil` parent ⇒ top level; `index` nil ⇒
    /// append). Rejects cycles / Unsorted. Undoable — the inverse restores BOTH the
    /// old parent AND the old slot (captured `sortIndex`), so undoing a drag puts
    /// the folder back exactly where it was (043 · Phase C).
    func moveFolder(id: UUID, toParent parent: UUID?, index: Int? = nil) {
        guard id != unsortedFolderID, services != nil else { return }
        let old = folders.first { $0.id == id }
        let oldParent = old?.parentCollectionID
        let oldIndex = old?.sortIndex
        enqueueUndoable { await self.applyMoveFolder(id: id, toParent: parent, index: index) }
        if oldParent != parent || index != nil {
            registerReversible("Move Folder",
                primary: {
                    self.enqueueUndoable {
                        await self.applyMoveFolder(id: id, toParent: parent, index: index)
                    }
                },
                inverse: {
                    self.enqueueUndoable {
                        await self.applyMoveFolder(id: id, toParent: oldParent, index: oldIndex)
                    }
                })
            announceUndoable("Moved “\(old?.name ?? "collection")”.")
        }
    }

    /// Apply a routed outline-view drop (043 · Phase C). `.reject` is a no-op; a
    /// `.move` funnels through the undoable ``moveFolder(id:toParent:index:)``.
    func applyCollectionDrop(_ drop: CollectionDrop, dragged: UUID) {
        guard case let .move(parent, index) = drop else { return }
        moveFolder(id: dragged, toParent: parent, index: index)
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

    /// ``perform(after:_:)`` for a write whose target is KNOWN — reload that folder
    /// rather than `selectedFolderID`. The two differ whenever the add was triggered
    /// from a pane that isn't the last-loaded collection, which is precisely when
    /// reloading the selection shows the user nothing.
    private func perform(
        reloading folder: UUID, _ body: @escaping (AppServices) async throws -> Void
    ) {
        guard let services else { return }
        Task {
            do {
                try await body(services)
                await refreshFolders()
                loadContents(of: folder)
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
        Task {
            do {
                // The two reads are independent — run them concurrently so the
                // reload latency is the slowest ONE, not their sum (009 · 16A).
                async let itemsRead = services.collectionItems(in: id, sort: sort, includeArchived: false)
                async let subfoldersRead = services.childCollections(of: id)
                let loadedItems = try await itemsRead
                let loadedSubfolders = try await subfoldersRead
                // A newer load has superseded this one — the reads can finish out
                // of order, so a stale read must NOT overwrite the current
                // folder's content. Bail before publishing anything.
                guard loadID == contentsLoadID else { return }
                items = loadedItems
                // A genuine reload IS the database truth — including every persisted
                // `view_count`. So any locally-tracked, not-yet-baked view deltas are
                // now redundant: clear them, or the next Most-Viewed reorder would
                // double-count them on top of counts the reload already carries
                // (036 §3 B4).
                pendingReorderBumps.removeAll(keepingCapacity: true)
                // Stamp WHICH collection the shared `items` now belong to, so a
                // freshly-pushed view for a different collection renders a skeleton
                // instead of this (still-stale-until-now) content mid-switch.
                loadedCollectionID = id
                subfolders = loadedSubfolders
                // Prune the selection to ids that survive the reloaded set
                // (folder switch, move-away, or delete). A removed lead falls back
                // to `nil`; the detail overlay's own state now lives in
                // `DetailSession`, so its auto-dismiss-on-delete is driven by the
                // host observing this reload (036 §3 B1), not by clearing model
                // state here.
                selectionStore.prune(to: items.map { $0.item.id })
                // Apply a pending Jump selection (011-B4 · 12A) against the freshly
                // loaded items, then clear it — deterministic, no timing hack.
                if let pending = pendingSelection, pending.collectionID == id {
                    let jumped = jumpSelection(in: items, assetIDs: pending.assetIDs)
                    if !jumped.isEmpty { selectionStore.replace(jumped) }
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

    /// Write any pending view bumps now (the 3s debounce, or a detail-close). One
    /// batched `recordViews` through the funnel; unknown/deleted ids are skipped by
    /// core. Each DISTINCT drained id folds into ``pendingReorderBumps`` as +1 — the
    /// exact `view_count` increment core applies per asset per batch — so a later
    /// Most-Viewed reorder reproduces the database order without a reload.
    ///
    /// When the folder ranks by views AND the detail overlay is NOT up, the
    /// Most-Viewed reorder is applied here in place (manual / newest orders are
    /// view-independent and left untouched). While the overlay IS up
    /// (``isDetailPresented``) the reorder is DEFERRED — the host applies it once,
    /// after the close fade, via ``applyDeferredMostViewedReorder()`` — so nothing
    /// reflows under the overlay (036 §3 B4). The full `loadContents` reload now
    /// survives ONLY as the fallback when the `recordViews` write fails, so local
    /// order can never drift from the persisted truth.
    func flushViewBumps() {
        viewFlushTask?.cancel()
        viewFlushTask = nil
        guard let services, !viewBumps.isEmpty else { return }
        let counts = viewBumps.drain()
        let ids = Array(counts.keys)
        // Fold to +1 per distinct id: core coalesces a batch to one `view_count`
        // bump per asset, so the local delta must too (raw per-open counts would
        // over-bump vs the database and diverge on the next real reload).
        for id in ids { pendingReorderBumps[id, default: 0] += 1 }
        let folder = selectedFolderID
        let reorders = sortMode(for: folder) == .mostViewed
        let reorderNow = reorders && !isDetailPresented
        Task {
            do {
                try await services.recordViews(ids)
                if reorderNow { applyDeferredMostViewedReorder() }
            } catch {
                lastError = Self.message(for: error)
                // The write did NOT land — the deltas we optimistically folded in
                // aren't persisted. Fall back to the truth: a reload re-syncs `items`
                // to the database (which lacks the failed bump) and clears the
                // accumulator, so local order can't drift (036 §3 B4).
                if reorders { loadContents(of: folder) }
                else { for id in ids { pendingReorderBumps[id]? -= 1 } }
            }
        }
    }

    /// Apply the deferred Most-Viewed reorder in place (036 §3 B4) — called by the
    /// detail host in the close animation's completion, so the just-viewed item
    /// rises AFTER the overlay fade rather than churning the grid under it.
    ///
    /// Pure and local: it bumps a copy of ``items`` by ``pendingReorderBumps`` and
    /// stable-sorts with core's exact Most-Viewed tiebreak (``mostViewedReorder``).
    /// When the order is unchanged (the common case — the viewed item was already
    /// at the top) it publishes NOTHING and keeps the accumulator, so a later flush
    /// still has the deltas. When it moves, `items` is replaced once (the bumped
    /// `view_count`s baked in, so `items` again equals the database truth) and the
    /// accumulator clears. A no-op when the folder isn't Most-Viewed or nothing is
    /// pending.
    func applyDeferredMostViewedReorder() {
        guard sortMode(for: selectedFolderID) == .mostViewed,
              !pendingReorderBumps.isEmpty else { return }
        switch mostViewedReorder(items: items, bumps: pendingReorderBumps) {
        case .unchanged:
            break                                   // keep the accumulator; no publish
        case .reordered(let newItems):
            items = newItems                         // one publish; view_counts now baked in
            contentsVersion &+= 1
            pendingReorderBumps.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Reorder (drag-to-reorder)

    /// Re-insert the dragged BLOCK `movingAssetIDs` at grid `slot` — the insertion
    /// index in the block-removed order chosen by the live preview (040), within
    /// the selected folder (009 · N3 — multi-select drag). OPTIMISTIC: reorders the
    /// local ``items`` immediately for feedback, then persists the new full order
    /// via `setGridOrder` (the write hops OFF the main actor). On failure the
    /// message surfaces via ``lastError`` and the folder reloads to the truth; on
    /// success it reloads too (core sorts by `manual_order`, so state stays
    /// consistent). A no-op when no dragged id is a current item (foreign drop) or
    /// the folder isn't in `.manual` mode (reordering has no meaning there).
    func reorderItems(movingAssetIDs: [UUID], insertAt slot: Int) {
        guard sortMode(for: selectedFolderID) == .manual, services != nil else { return }
        let currentIDs = items.map { $0.asset.id }
        // `slot` is an index among the TILES the grid drew, i.e. into `displayItems`
        // — so the reorder has to be solved in display space and only then widened
        // back to every item (307). Solving it directly against `items` treats "after
        // the 3rd tile" as "after the 3rd IMAGE", which with carousels collapsed
        // lands a drop near the start of the feed instead of where it was dropped.
        let displayIDs = displayItems.map { $0.item.id }
        let movingAssetSet = Set(movingAssetIDs)
        // The dragged payload is asset ids covering whole posts; map them back to the
        // tiles that stand for them, de-duplicated but kept in display order.
        var seen = Set<UUID>()
        let movingTiles = displayIDs.filter { tileID in
            let representsDragged = itemsRepresented(by: tileID).contains { memberID in
                guard let assetID = assetIDByItemID[memberID] else { return false }
                return movingAssetSet.contains(assetID)
            }
            return representsDragged && seen.insert(tileID).inserted
        }
        guard let newTileOrder = reorderedIDs(
            ids: displayIDs, movingIDs: movingTiles, insertAt: slot)
        else { return }
        // Widen back: each tile contributes the items it stands for, in feed order,
        // which also keeps a post's images contiguous after a move.
        let newOrder = newTileOrder
            .flatMap { itemsRepresented(by: $0) }
            .compactMap { assetIDByItemID[$0] }
        guard !newOrder.isEmpty else { return }

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
        announceUndoable("Reordered \(Self.itemCount(movingAssetIDs.count)).")
    }

    // MARK: - Selection + inspector

    /// Apply a selection `action` through the pure ``GridSelection`` reducer over
    /// the current feed order (+ `columns` for arrow keys), publish the new
    /// selection, and hand the caller the ``GridSelectionEffect`` to execute
    /// (open detail / scroll a cell into view / nothing). This is the ONLY
    /// selection mutator — views report raw input and never branch on mode (009 ·
    /// N2 · 11A). Pure state: NO preview/tags I/O happens here, so a toggle or a
    /// ⌘A never decodes a large thumbnail (009 · 8A); the detail overlay's preview
    /// + tags load in ``DetailSession`` when the page is actually opened (036 B1).
    @discardableResult
    func applySelection(_ action: GridSelectionAction, columns: Int = 1) -> GridSelectionEffect {
        // The single seam onto ``selectionStore`` (036 A0): it runs the same pure
        // reducer over the store's `order` and publishes only real changes — the
        // marquee re-fires per mouse-move tick, so an unchanged hit set must not
        // re-render the store's observers.
        selectionStore.apply(action, columns: columns)
    }

    /// The large (1280-tier) thumbnail URL for `asset` — the detail overlay's
    /// instant placeholder while full-res decodes. `nil` for a media-less kind
    /// (003 · O1) with no thumbnail. `DetailSession` (036 §3 B1) decodes it
    /// off-main into the overlay-scoped state; opening the overlay no longer writes
    /// a `previewImage` on this model.
    func previewImageURL(forAsset asset: Asset) -> URL? {
        guard let store, let hash = asset.blobHash else { return nil }
        return store.thumbnailURL(
            hash: hash, size: ThumbnailTier.large.rawValue, fileExtension: "jpg")
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
        guard let hash = asset.blobHash else { return nil }
        return blobURL(forBlobHash: hash, mimeType: asset.mimeType ?? "")
    }

    /// The on-disk blob URL for a bare `(hash, mimeType)` pair — the one place
    /// the store-time extension is recovered, shared by the asset-based callers
    /// above and the largest-items rows (016 · A), which have a `BlobUsage`
    /// rather than an `Asset`.
    func blobURL(forBlobHash hash: String, mimeType: String) -> URL? {
        guard let store else { return nil }
        return store.blobURL(
            hash: hash, fileExtension: ImageMetadata.fileExtension(forMIMEType: mimeType))
    }

    // MARK: - Tags (detail page)
    //
    // 036 §3 B1: the detail overlay's tags moved onto the shared `AssetTagsStore`
    // (already used by the Space board + search overlays), driven by
    // `DetailSession`/`CollectionDetailHost`. The former `loadTags` / `addTag` /
    // `removeTag` / `reloadTagsIfCurrent` on this model — which published
    // `selectedTags` and re-ran the whole screen on every chip edit — are deleted.

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

    /// Copy an ordered selection to the general pasteboard and record the outcome
    /// (052 · B1). The ONE ⌘C write path shared by grid / canvas / detail: each
    /// surface supplies only its ordered `(asset, source)` pairs; the blob-URL
    /// truth (``blobURL(forAsset:)``), the kind-aware entry rule
    /// (``AssetExport/pasteboardEntry(asset:source:blobURL:)``), and the pasteboard
    /// representations (``AssetPasteboardWriter``) all live in one place. Skips are
    /// reported via ``lastCopyReport`` (7A), never silent.
    ///
    /// Writes TWO representations of the one selection (019 · C1, the 065 §2.4
    /// pattern applied outside Spaces), so the DESTINATION decides what a copy meant:
    ///
    /// - the byte one — blob file URLs (plus an `NSImage` for a single item), which
    ///   is all Figma / Finder / Photoshop ever see, unchanged;
    /// - the app-private ``AssetDragPayload``, so a ⌘V back into the app pastes the
    ///   ASSET (a second membership) instead of re-importing its bytes as a fresh
    ///   `.localDrag` capture — which loses the note, tags, `original_url` and
    ///   `created_at` of anything not already local (019).
    ///
    /// `sourceCollectionID` is the collection the copy was taken from, or
    /// ``AssetDragPayload/nilSourceID`` for a membership-less surface (library
    /// search, a Space board). Required rather than defaulted: every caller knows
    /// its own answer, and guessing one is how a paste picks the wrong target.
    ///
    /// The report's counts stay about the BYTE representation — the honest number
    /// for other apps, and what keeps the "this won't paste into Figma" warning
    /// truthful — even though the private payload carries the whole selection.
    func copyToPasteboard(
        assets: [(asset: Asset, source: Source?)], sourceCollectionID: UUID
    ) {
        let selection = AssetExport.exportSelection(
            assets: assets, blobURL: { self.blobURL(forAsset: $0) })
        AssetPasteboardWriter.write(selection, to: .general)
        // AFTER the write, which clears the board first (see `appendAssetIDs`), and
        // over the WHOLE selection — including entries the byte pass had to skip.
        AssetPasteboardWriter.appendAssetIDs(
            assets.map { $0.asset.id }, from: sourceCollectionID, to: .general)
        copyReportSeq += 1
        lastCopyReport = CopyReport(
            copied: selection.entries.count, skipped: selection.skipped, seq: copyReportSeq)
    }

    /// Copy the `selection` (membership ids) out of `details` to the pasteboard, in
    /// `details` order (052 · B1). The grid-shaped convenience over
    /// ``copyToPasteboard(assets:sourceCollectionID:)`` shared by the collection grid
    /// and the search grid — both hold `[CollectionItemDetail]` and select by
    /// `item.id`. Search passes ``AssetDragPayload/nilSourceID``: it has no owning
    /// collection to have copied out of.
    func copySelectedToPasteboard(
        from details: [CollectionItemDetail], selection ids: Set<UUID>, sourceCollectionID: UUID
    ) {
        let assets = details
            .filter { ids.contains($0.item.id) }
            .map { (asset: $0.asset, source: Optional($0.source)) }
        copyToPasteboard(assets: assets, sourceCollectionID: sourceCollectionID)
    }

    /// Resolve `assetIDs` out of `details` to an ``ExportSelection`` — ordered
    /// entries plus the count that had nothing to export (011 · A2/A3).
    ///
    /// Selects by **asset** id, not membership id, because that is what the
    /// right-click's Finder-scope targets are (`gridActionTargets`) and what the
    /// detail page holds; ``copySelectedToPasteboard(from:selection:sourceCollectionID:)``
    /// filters by `item.id` because ⌘C comes from a grid selection, which is
    /// membership-shaped. Order is `details` order — the feed the user is looking
    /// at — so an export and a share list the refs the same way the grid does.
    ///
    /// Shared by the originals folder export and the share sheet so neither
    /// re-derives "what does this selection actually contain".
    func exportSelection(
        from details: [CollectionItemDetail], assetIDs: [UUID]
    ) -> ExportSelection {
        let wanted = Set(assetIDs)
        let assets = details
            .filter { wanted.contains($0.asset.id) }
            .map { (asset: $0.asset, source: Optional($0.source)) }
        return AssetExport.exportSelection(
            assets: assets, blobURL: { self.blobURL(forAsset: $0) })
    }

    /// Whether ANY of `assetIDs` has something shareable — the CHEAP question a
    /// right-click asks (011 · A3 review).
    ///
    /// Deliberately not `!exportSelection(...).isEmpty`: that resolves every asset
    /// and was measured at ~77 ms for 1,000 refs, paid before the menu could draw.
    /// This stops at the FIRST shareable ref via `contains(where:)`, and
    /// ``AssetShare/canShare(_:)`` touches no filesystem — so a 5,000-ref selection
    /// normally answers after looking at one asset.
    func canShareAny(from details: [CollectionItemDetail], assetIDs: [UUID]) -> Bool {
        let wanted = Set(assetIDs)
        return details.contains { wanted.contains($0.asset.id) && AssetShare.canShare($0.asset) }
    }

    /// The on-disk URL of a folder item's 512-tier thumbnail (pure — no decode).
    /// The grid decodes + caches it off the main thread via ``ThumbnailPipeline``
    /// (at the cell's own pixel bucket), so the render path never blocks on disk
    /// I/O and never pays a lazy decode at first draw.
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
        enqueueUndoable { await self.applyRemove(assetIDs: assetIDs, from: folder) }
        registerReversible("Remove",
            primary: { self.enqueueUndoable { await self.applyRemove(assetIDs: assetIDs, from: folder) } },
            inverse: { self.enqueueUndoable { await self.applyRestoreMemberships(assetIDs: assetIDs, to: folder, order: priorOrder) } })
        announceUndoable(message)
    }

    /// Reload the current folder + folder list after an EXTERNAL membership change
    /// (the Item Detail "Collections" chips, 041 — which mutate through the shared
    /// asset store, not this model). Refreshes the grid + sidebar counts so the
    /// edit is reflected behind the overlay; if the change dropped the shown item
    /// from the current folder, the `contentsVersion` bump drives the overlay's
    /// auto-dismiss, matching ``removeFromFolder(assetIDs:)``.
    ///
    /// `removedFrom` names the collection the chip took the asset OUT of — the one it
    /// was removed from, or Unsorted when an ADD evicted it there (356; `nil` for the
    /// archive import, which also calls this). When that collection is the one the run
    /// belongs to, the chip is the page's ⌫ wearing different chrome — the shown item
    /// is about to leave this feed because the user said so — so it arms the same step
    /// (355). Everything else reloads exactly as it did.
    func reloadAfterMembershipChange(removedFrom collectionID: UUID? = nil) {
        guard services != nil else { return }
        if let collectionID, collectionID == loadedCollectionID, let shown = detailShownItemID {
            armDetailStep(for: shown)
        }
        Task { await refreshFolders() }
        loadContents(of: selectedFolderID)
    }

    /// MOVE assets out of the current folder into `targetID` — the atomic triage
    /// verb (009 · N1). One transaction; the moved items leave this folder, so the
    /// reload prunes them from the selection. A `from == to` / empty set is a
    /// no-op in core.
    func moveToCollection(assetIDs: [UUID], to targetID: UUID) {
        guard !assetIDs.isEmpty, services != nil else { return }
        let source = selectedFolderID
        guard source != targetID else { return }
        // A move that carries the item the detail page is SHOWING is that page's verb,
        // wherever the drop was completed (355): dragging the picture off the page onto
        // a sidebar collection is finished by the outline view, which knows the asset
        // ids and nothing about the overlay. The shown item leaves this feed either
        // way — armed, the page steps to what takes its place instead of dropping the
        // user back on the grid. A move raised from anywhere else (the grid's Move to ▸,
        // M, a drag of a different tile) does not name the shown item and arms nothing.
        armDetailStepIfShown(assetIDs: assetIDs, leaving: source)
        // Capture the source order so undo restores the moved items' positions.
        let priorOrder = items.map { $0.asset.id }
        let message = "Moved \(Self.itemCount(assetIDs.count)) to “\(name(for: targetID))”."
        enqueueUndoable { await self.applyMoveAssets(assetIDs, from: source, to: targetID) }
        registerReversible("Move",
            primary: { self.enqueueUndoable { await self.applyMoveAssets(assetIDs, from: source, to: targetID) } },
            inverse: { self.enqueueUndoable { await self.applyMoveBack(assetIDs, from: targetID, to: source, order: priorOrder) } })
        announceUndoable(message)
    }

    /// COPY assets into `targetID` WITHOUT removing them here (009 · ⌥-drag / Add
    /// to ▸) — multi-membership, so it is exactly `addAssets`. The current folder
    /// is unchanged, so the selection survives.
    ///
    /// `source` is where the copy was dragged FROM, purely for the notice's verb:
    /// under the Unsorted invariant (F3) a copy out of Unsorted DOES empty the
    /// source — the asset is filed now, so it stops being unsorted — and calling
    /// that "Added" would describe a row the user just watched disappear. Callers
    /// with no folder source (search results) pass `nil` and keep "Added".
    /// **Undoable since 024 · K3.** It was not before, and the asymmetry only became
    /// dangerous when a single bare `A` could fire it: Move and Remove both register a
    /// reversible action and raise an "…— Undo" toast, while Add published a plain
    /// notice and left nothing to press. A key you can hit by accident needs the same
    /// way back the two verbs beside it have.
    ///
    /// The inverse removes only the memberships this call actually CREATED — see
    /// ``applyAdd(_:to:record:)`` — so undoing an add over a set that was already half
    /// filed there leaves the half that predated it alone.
    func copyToCollection(assetIDs: [UUID], to targetID: UUID, from source: UUID? = nil) {
        guard !assetIDs.isEmpty, services != nil else { return }
        // The same invariant the notice's verb reads, applied to the detail page (356):
        // out of Unsorted this "copy" is a departure, so an ⌥-drag of the page's picture
        // onto a collection has to arm the step exactly as the plain drag does. The
        // guard is the loaded folder, not `source` — a caller that passes no source
        // (a Space board, a search hit) has no Unsorted feed behind it to leave.
        if targetID != unsortedFolderID {
            armDetailStepIfShown(assetIDs: assetIDs, leaving: unsortedFolderID)
        }
        let verb = source == Collection.unsortedID ? "Moved" : "Added"
        let message = "\(verb) \(Self.itemCount(assetIDs.count)) to “\(name(for: targetID))”."
        // Shared by the forward pass and its inverse, so a redo re-records what the
        // second run created rather than reusing the first run's answer.
        let record = AddedMemberships()
        enqueueUndoable { await self.applyAdd(assetIDs, to: targetID, record: record) }
        registerReversible("Add",
            primary: { self.enqueueUndoable { await self.applyAdd(assetIDs, to: targetID, record: record) } },
            inverse: { self.enqueueUndoable { await self.applyUnadd(record, from: targetID) } })
        announceUndoable(message)
    }

    /// The memberships one `Add` created, written by the forward pass and read by its
    /// inverse. A reference type because both closures are registered ONCE and must
    /// see the same box across every undo ↔ redo ping-pong.
    final class AddedMemberships {
        var assetIDs: [UUID] = []
    }

    /// Add memberships to `target` and record which ones were new, then refresh.
    ///
    /// The delta is measured by reading the target's membership before and after
    /// rather than by predicting it. `addAssets` skips assets that are already
    /// members, and — when the target is Unsorted — also skips assets that are filed
    /// anywhere real (the F3 invariant). Reproducing both rules here to guess the
    /// delta would be a second copy of them, which is how an inverse silently starts
    /// removing a membership the user had before.
    private func applyAdd(
        _ assetIDs: [UUID], to target: UUID, record: AddedMemberships
    ) async {
        guard let services else { return }
        do {
            let before = Set(try await services.collectionItems(in: target, includeArchived: false).map(\.asset.id))
            try await services.addAssets(assetIDs, to: target)
            let after = Set(try await services.collectionItems(in: target, includeArchived: false).map(\.asset.id))
            // In the given order, so the undo reads deterministically in a test.
            record.assetIDs = assetIDs.filter { after.contains($0) && !before.contains($0) }
            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    /// Drop exactly the memberships ``applyAdd(_:to:record:)`` created — the inverse.
    ///
    /// Does NOT touch the source: an add never removed anything, so there is nothing
    /// to put back. An asset left with no memberships at all is re-homed to Unsorted by
    /// `removeAssets` (F3), which is precisely where the forward pass evicted it from.
    private func applyUnadd(_ record: AddedMemberships, from target: UUID) async {
        guard let services, !record.assetIDs.isEmpty else { return }
        do {
            try await services.removeAssets(record.assetIDs, from: target)
            await refreshFolders()
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    /// The asset ids a keyboard command (Delete / Remove / ⌘D) acts on: the whole
    /// selection when selecting, else the lead cursor's item.
    ///
    /// The lead branch goes through the SAME two helpers as the right-click path
    /// (``widenedForAction(_:)`` then ``assetIDs(for:)``) — a collapsed carousel
    /// tile stands for its whole post (307), so a cursor sitting on a tile reading
    /// ⧉4 must act on all four. Taking `leadItem.asset.id` raw was the one action
    /// path that skipped the widening, and it produced exactly the failure
    /// ``actionTargets(forCellItemID:)`` documents itself as preventing: ⌫ removed
    /// one image and left the tile behind reading 3, and ⌘D starred one image of
    /// four. Note it widens the ITEM id, not the asset id — `widenedForAction`
    /// speaks membership ids. An OPENED post still acts per frame; that exception
    /// lives inside `widenedForAction` and is deliberate.
    private var keyboardActionTargets: [UUID] {
        selection.isSelecting
            ? selectedAssetIDs
            : (leadItem.map { assetIDs(for: widenedForAction([$0.item.id])) } ?? [])
    }

    /// The assets `M` / `A` file (024 · K3) — **deliberately the same answer ⌫ and ⌘D
    /// give**, not a second targeting rule read off the grid's cells.
    ///
    /// This exists only because ``keyboardActionTargets`` is private and the two new
    /// verbs are raised from a view rather than from a method on this model (the key
    /// opens a picker; the picker calls back with a destination later). A separate
    /// rule would have re-introduced exactly the bug [027] G1 fixed: a cursor on a
    /// collapsed ⧉4 tile must file all four, because that is what the tile stands for.
    var destinationActionTargets: [UUID] { keyboardActionTargets }

    // MARK: - Favorites (011 · U5)

    /// Whether the current ⌘D target has anything left to star — drives the menu
    /// item's title, so it says what the press will actually do. `true` (the
    /// "Favorite" wording) when there is no target at all, where the item is
    /// disabled anyway.
    var favoriteActionWouldStar: Bool {
        let targets = keyboardActionTargets
        guard !targets.isEmpty else { return true }
        return Self.wouldFavorite(targets, favorited: favoritedAssetIDs)
    }

    /// Whether ⌘D has anything to act on (the menu item's enabled state).
    var canToggleFavorite: Bool { !keyboardActionTargets.isEmpty }

    /// Ids in the current folder's feed that are favorited — read straight off the
    /// loaded rows, so the menu title and the grid star can never disagree with
    /// what is on screen.
    private var favoritedAssetIDs: Set<UUID> {
        Set(items.filter(\.asset.isFavorite).map(\.asset.id))
    }

    /// **The ⌘D multi-select rule.** Over a selection, ⌘D FAVORITES unless every
    /// target is already a favorite, in which case it UNFAVORITES all of them.
    ///
    /// Two properties make this the right rule rather than a coin toss:
    ///
    ///   • *A mixed selection converges.* "Star them all" is the only outcome that
    ///     leaves the set in a state the user can see and predict; a per-item flip
    ///     would leave it just as mixed as before, and the user would have to look
    ///     at each tile to know what happened.
    ///   • *One more press is the inverse.* After ⌘D the set is uniformly starred,
    ///     so a second ⌘D unstars all of it — the shortcut still reads as a toggle
    ///     even though it isn't a per-item one.
    ///
    /// Pure and static so the rule is testable without a model, a grid or a
    /// database. `targets` empty → `false` (nothing to do).
    static func wouldFavorite(_ targets: [UUID], favorited: Set<UUID>) -> Bool {
        guard !targets.isEmpty else { return false }
        return !targets.allSatisfy(favorited.contains)
    }

    /// Set the flag on `assetIDs` explicitly — the detail page's star, and the
    /// primitive that ``toggleFavorite(assetIDs:)`` resolves to.
    ///
    /// Undoable, matching the other reversible membership-ish verbs (Remove /
    /// Move): the inverse sets `!isFavorite` on exactly these ids. It does NOT
    /// consult prior state, deliberately — a detail page opened from a Space board
    /// or a search hit shows an asset that is not in this model's loaded feed, so
    /// there is no prior state to consult, and setting is idempotent in the funnel
    /// either way. The caller that DOES know the prior state (⌘D) narrows the ids
    /// before calling in.
    func setFavorite(_ isFavorite: Bool, assetIDs: [UUID]) {
        guard !assetIDs.isEmpty, services != nil else { return }
        let message = isFavorite
            ? "Favorited \(Self.itemCount(assetIDs.count))."
            : "Removed \(Self.itemCount(assetIDs.count)) from Favorites."
        enqueueUndoable { await self.applyFavorite(isFavorite, to: assetIDs) }
        registerReversible("Favorite",
            primary: { self.enqueueUndoable { await self.applyFavorite(isFavorite, to: assetIDs) } },
            inverse: { self.enqueueUndoable { await self.applyFavorite(!isFavorite, to: assetIDs) } })
        announceUndoable(message)
    }

    /// Toggle the favorite flag over `assetIDs` under the rule above. Only the ids
    /// this press actually CHANGES are handed on: the rest are already where they
    /// are going, so neither the toast's count nor the undo should mention them —
    /// and undoing a ⌘D over a mixed selection therefore restores the mixture
    /// rather than clearing the lot.
    func toggleFavorite(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        let previouslyFavorited = favoritedAssetIDs.intersection(assetIDs)
        let starring = Self.wouldFavorite(assetIDs, favorited: previouslyFavorited)
        let changed = starring
            ? assetIDs.filter { !previouslyFavorited.contains($0) }
            : assetIDs.filter { previouslyFavorited.contains($0) }
        setFavorite(starring, assetIDs: changed)
    }

    /// Toggle the favorite flag over the current selection (or the lead item) —
    /// the ⌘D command's entry point.
    func toggleFavoriteSelected() {
        toggleFavorite(assetIDs: keyboardActionTargets)
    }

    /// Set the flag and reload, so the grid stars repaint. Shared by the verb and
    /// its inverse (no undo re-registration — the ping-pong installs the mirror).
    private func applyFavorite(_ isFavorite: Bool, to assetIDs: [UUID]) async {
        guard let services else { return }
        do {
            try await services.setFavorite(isFavorite, for: assetIDs)
            loadContents(of: selectedFolderID)
        } catch { lastError = Self.message(for: error) }
    }

    // MARK: - The archive shelf (023 · A3)

    /// Archive (or unarchive) `assetIDs` explicitly. Undoable, in the same shape
    /// as ``setFavorite(_:assetIDs:)``: the inverse is the opposite verb over
    /// exactly these ids.
    ///
    /// Reversible rather than confirmed, because that is what archive IS — the
    /// verb you reach for instead of delete precisely because nothing is lost.
    /// A confirmation dialog on a lossless, one-key-undoable action would teach
    /// the user to dismiss dialogs.
    func setArchived(_ archived: Bool, assetIDs: [UUID]) {
        guard !assetIDs.isEmpty, services != nil else { return }
        let verb: ShelfVerb = archived
            ? .archive(count: assetIDs.count) : .unarchive(count: assetIDs.count)
        enqueueUndoable { await self.applyArchived(archived, to: assetIDs) }
        registerReversible("Archive",
            primary: { self.enqueueUndoable { await self.applyArchived(archived, to: assetIDs) } },
            inverse: { self.enqueueUndoable { await self.applyArchived(!archived, to: assetIDs) } })
        announceUndoable(verb.completedMessage + ".")
    }

    /// The `E` verb over `assetIDs` — archive unless every one of them already
    /// is (023 · A3, and the ⌘D rule it mirrors).
    ///
    /// The archived state is READ rather than assumed. Every browsing surface
    /// hides archived items, so the answer is nearly always "none of them", but
    /// a selection can outlive the rows under it — and assuming here is exactly
    /// how a stale selection would archive something twice and then undo into a
    /// state the user never had.
    /// `async` rather than fire-and-forget, deliberately. The read has to finish
    /// before the verb is even known, so a detached `Task` would put it OUTSIDE
    /// the undo stack's serial write chain — and `waitForWrites()`, which is how
    /// every caller and every test knows the verb is done, would return before
    /// this had decided anything. Callers wrap it in a `Task`; that is visible
    /// at the call site rather than hidden here.
    func toggleArchived(assetIDs: [UUID]) async {
        guard !assetIDs.isEmpty, let services else { return }
        let archived: Set<UUID>
        do {
            archived = try await services.archivedAssetIDs(among: assetIDs)
        } catch {
            lastError = Self.message(for: error)
            return
        }
        guard let verb = shelfVerb(targets: assetIDs, archived: archived) else { return }
        switch verb {
        case .archive:
            // Only the ids this press actually CHANGES, so the toast's count and
            // the undo both describe what happened — and undoing over a mixed
            // selection restores the mixture rather than clearing it.
            setArchived(true, assetIDs: assetIDs.filter { !archived.contains($0) })
        case .unarchive:
            setArchived(false, assetIDs: assetIDs.filter { archived.contains($0) })
        }
    }

    /// The `E` key's entry point — the current selection, or the lead cursor's
    /// post, exactly as ⌫ and ⌘D resolve their targets.
    func toggleArchivedSelected() async {
        await toggleArchived(assetIDs: keyboardActionTargets)
    }

    /// Apply and reload. Shared by the verb and its inverse (no undo
    /// re-registration — the ping-pong installs the mirror). The reload is a
    /// membership-shaped one even though no membership changed: which items are
    /// VISIBLE changed, and that is what the grid, the counts and the gallery
    /// covers all render from.
    private func applyArchived(_ archived: Bool, to assetIDs: [UUID]) async {
        guard let services else { return }
        do {
            if archived {
                _ = try await services.archive(assetIDs)
            } else {
                _ = try await services.unarchive(assetIDs)
            }
            reloadAfterMembershipChange()
        } catch { lastError = Self.message(for: error) }
    }

    /// Whether ⌫ has a container to remove from here (022 · D2). False in Unsorted,
    /// which is the fallback every other removal re-homes INTO — there is nowhere
    /// below it to fall to, so the Edit-menu item disables rather than offering a
    /// verb that would only explain itself.
    var canRemoveFromCurrentFolder: Bool { selectedFolderID != Collection.unsortedID }

    /// **⌫ in the collection grid** (022 · D2): remove the current selection (or the
    /// lead cursor's post) from the collection in view. Undoable, no dialog — the
    /// "…— Undo" toast `removeFromFolder` raises is what makes the verb legible.
    ///
    /// Unsorted is the one collection where this cannot mean anything. `AppServices`
    /// exempts it from the F3 re-home (`removeAssets(_:from:)`) precisely because a
    /// removal there would re-add what it just removed — so removing from Unsorted
    /// either does nothing or quietly orphans, and neither is a verb worth binding to
    /// the softest key on the keyboard. It says so instead, and names the key that
    /// DOES leave the library.
    func removeSelectedFromFolder() {
        removeFromCurrentFolder(assetIDs: keyboardActionTargets)
    }

    /// The ⌫ verb over an explicit id set — the item detail page's Remove, which acts
    /// on the one item on screen rather than on the grid's cursor (022 · D4). Same
    /// Unsorted rule, in the same place, so the page and the grid behind it cannot
    /// answer that question differently.
    func removeFromCurrentFolder(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        guard canRemoveFromCurrentFolder else {
            notify("Unsorted is the fallback — press ⌘⌫ to delete.")
            return
        }
        removeFromFolder(assetIDs: assetIDs)
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
    ///
    /// Every dismissal route lands here — the Cancel button, Escape, and the dialog's
    /// `isPresented` binding writing `false` — which is what makes it the right place
    /// to disarm a detail step: a ⌘⌫ that was called off must not leave an intent
    /// waiting to fire on some later, unrelated reload (026 · I3).
    ///
    /// **The guard is what keeps CONFIRMING out of that set** (354). SwiftUI writes
    /// `false` into the dialog's `isPresented` binding when it dismisses — including
    /// after the Delete button's action has run — so the confirm path arrives here too,
    /// a moment after ``confirmPendingDeletion()`` cleared the pending state and long
    /// before the delete's asynchronous reload lands. Disarming there took the intent
    /// away from the very reload it was armed for, and the page closed instead of
    /// stepping. Nothing pending means nothing was called off: the second write is a
    /// no-op, and Cancel / Escape (which arrive with the deletion still staged) disarm
    /// exactly as before.
    func cancelPendingDeletion() {
        guard pendingDeletion != nil else { return }
        pendingDeletion = nil
        detailStepIntent = nil
    }

    // MARK: - Step, don't dismiss (026 · I3)

    /// The one-shot record that the detail page issued a verb which is about to take
    /// the shown item out of this feed. Armed by the two `itemID:`-taking verbs below,
    /// read-and-cleared by ``consumeDetailStepIntent()``.
    ///
    /// Deliberately NOT `@Published`: nothing renders from it: it is a handoff between
    /// a verb and the very next reload, and a publish would re-render the grid under
    /// the overlay for a value no view reads.
    private var detailStepIntent: DetailStepIntent?

    /// Capture where `itemID` sits RIGHT NOW, before the verb's reload replaces
    /// ``detailRun``. This is the whole reason the intent exists as state rather than
    /// as a boolean: the observer that reacts to the reload can only ever see the new
    /// run, in which the departed item has no position at all.
    ///
    /// An id that is not in the run, or a feed that hasn't finished loading, arms
    /// nothing — and clears any stale intent rather than leaving one behind.
    ///
    /// ``loadedCollectionID`` (not ``selectedFolderID``) is the folder stamped on the
    /// intent, because it is the one that describes the run being captured: the
    /// selected folder can already have moved on while the previous feed is still on
    /// screen, and a step must land in the folder the user was actually judging.
    private func armDetailStep(for itemID: UUID) {
        guard let index = detailRunIndex(of: itemID), let collectionID = loadedCollectionID
        else {
            detailStepIntent = nil
            return
        }
        detailStepIntent = DetailStepIntent(
            itemID: itemID, index: index, run: detailRun.map { $0.item.id },
            collectionID: collectionID)
    }

    /// Arm the step when `assetIDs` carries the item the detail page is SHOWING and it
    /// is leaving the collection that run belongs to (355).
    ///
    /// The asset-id detour is the point: the two verbs that reach here — a chip and a
    /// drag-out — are raised by surfaces that speak assets, not memberships, and are
    /// completed somewhere other than the page. Resolving through ``detailShownItemID``
    /// is what keeps them aimed at what the user is looking at rather than at the
    /// grid's cursor, which ← / → deliberately leave behind.
    ///
    /// Both guards matter. Without the id check, any move out of this folder would arm
    /// a step for a page showing something else; without the folder check, a move whose
    /// source is not the loaded run would arm against a feed it was never in.
    private func armDetailStepIfShown(assetIDs: [UUID], leaving collectionID: UUID) {
        guard collectionID == loadedCollectionID, let shown = detailShownItemID,
              let detail = detailRun.first(where: { $0.item.id == shown }),
              assetIDs.contains(detail.asset.id)
        else { return }
        armDetailStep(for: shown)
    }

    /// Read the armed step intent AND clear it. One-shot by construction: the host
    /// calls this on every content reload, so an intent that is never followed by the
    /// departure it expected is spent on the next reload instead of lingering.
    func consumeDetailStepIntent() -> DetailStepIntent? {
        defer { detailStepIntent = nil }
        return detailStepIntent
    }

    /// **The detail page's ⌫** (022 · D4 + 026 · I3): remove the shown item from the
    /// collection in view, and arm the page to step to whatever takes its place.
    ///
    /// The Unsorted guard is checked BEFORE arming, not after: in Unsorted this verb
    /// only says why it can't act, so there is no reload coming, and an intent armed
    /// here would sit until some unrelated later reload consumed it — which is exactly
    /// the "leaves the page showing a stranger" failure the explicit gate exists to
    /// prevent. The plain ``removeFromCurrentFolder(assetIDs:)`` still runs, so the
    /// notice and the rule stay in one place.
    func removeFromCurrentFolder(itemID: UUID, assetIDs: [UUID]) {
        guard !assetIDs.isEmpty, canRemoveFromCurrentFolder else {
            removeFromCurrentFolder(assetIDs: assetIDs)
            return
        }
        armDetailStep(for: itemID)
        removeFromCurrentFolder(assetIDs: assetIDs)
    }

    /// **The detail page's ⌘⌫** (022 · D4 + 026 · I3): stage the shared confirmation
    /// and arm the step for the item it is about to destroy.
    ///
    /// Arming here rather than at confirmation time is what keeps the captured index
    /// pre-reload — and the dialog is modal over the page, so the run cannot move
    /// underneath the intent while it is up. A cancelled dialog disarms through
    /// ``cancelPendingDeletion()``.
    func requestDelete(itemID: UUID, assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        armDetailStep(for: itemID)
        requestDelete(assetIDs: assetIDs)
    }

    /// Carry out the confirmed delete (010 · delete-undo). Captures a verbatim
    /// backup and removes the assets in one transaction, then registers an UNDO
    /// (⌘Z → restore). Blobs are NOT reaped here — reaping is deferred to the
    /// launch orphan-GC so an in-session undo finds the bytes on disk; a delete
    /// that is never undone is reclaimed at the next launch. The pre-destructive
    /// snapshot (008 H3) stays as the coarse net. Clears the pending state first so
    /// the dialog dismisses immediately.
    func confirmPendingDeletion() {
        guard let pending = pendingDeletion else { return }
        pendingDeletion = nil
        deleteRecoverably(assetIDs: pending.assetIDs)
    }

    /// Delete `assetIDs` for a surface that ran its OWN confirmation — the
    /// near-duplicate review sheet (012 · I5), whose confirmation has to live
    /// inside the sheet because the shell's shared dialog would open behind it.
    ///
    /// Deliberately the same call, not a second delete: it lands on
    /// ``deleteRecoverably(assetIDs:)`` exactly as the confirmed grid delete does,
    /// so the snapshot, the recoverable backup, the ⌘Z undo and the deferred blob
    /// reap are identical. A near-duplicate delete is an ordinary delete that was
    /// reached from a different screen, and it must stay reversible in the same
    /// way. Ignores an empty set.
    func deleteReviewedDuplicates(assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        deleteRecoverably(assetIDs: assetIDs)
    }

    /// The one recoverable-delete implementation, shared by every surface that can
    /// reach it. Callers own the confirmation; this owns the safety net.
    private func deleteRecoverably(assetIDs: [UUID]) {
        guard let services, !assetIDs.isEmpty else { return }
        let count = assetIDs.count
        let snapshots = snapshotManager
        enqueueUndoable {
            // The coarse net, freshness-gated (008 review, 14A): skipped when any
            // snapshot is <10 min old. Its failure is surfaced but never blocks
            // the delete — the in-DB recoverable backup below still protects it
            // (008 review, 8A).
            do {
                _ = try await snapshots?.snapshotBeforeDestruction()
            } catch {
                AppLog.model.error(
                    "pre-destructive snapshot failed: \(String(describing: error))")
                self.notify("Safety snapshot failed — the delete is still undoable.")
            }
            do {
                let backup = try await services.deleteAssetsRecoverable(assetIDs)
                await self.refreshFolders()
                self.loadContents(of: self.selectedFolderID)
                let message = "Deleted \(Self.itemCount(count))."
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
            notify("Restored \(Self.itemCount(backup.assets.count)).")
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
            notify("Deleted \(Self.itemCount(count)).")
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

    /// The first launch after a restore (008 review, 3A): diff the restored DB's
    /// referenced blobs against the disk and REPORT both divergence directions —
    /// items whose media vanished after the snapshot (check the Trash), and media
    /// captured after the snapshot that the restored DB doesn't know (kept this
    /// launch, reclaimed by the next launch's GC). Reaps nothing.
    private func runPostRestoreBlobReconcile(services: AppServices, store: MediaStore) {
        Task.detached(priority: .utility) {
            guard let referenced = try? await services.referencedBlobHashes() else { return }
            let onDisk = Set(store.enumerateBlobFiles().map(\.hash))
            let report = PostRestoreBlobReport(referenced: referenced, onDisk: onDisk)
            AppLog.model.info(
                """
                post-restore reconcile: \
                \(report.missingReferenced, privacy: .public) referenced-but-missing, \
                \(report.keptUnreferenced, privacy: .public) unreferenced-but-kept
                """)
            guard !report.isClean else { return }
            await MainActor.run {
                if report.missingReferenced > 0 {
                    self.notify("Restore: \(report.missingReferenced) item(s) reference "
                        + "media no longer on disk — it may still be in the Trash.")
                }
                if report.keptUnreferenced > 0 {
                    self.notify("Restore: kept \(report.keptUnreferenced) media file(s) "
                        + "newer than the snapshot; they're cleaned up next launch.")
                }
            }
        }
    }

    // MARK: - Snapshots (008 H3)

    /// Every snapshot on disk (newest first), for the snapshots sheet.
    func availableSnapshots() -> [SnapshotFile] {
        snapshotManager?.list() ?? []
    }

    /// `true` while a manual snapshot is being written (drives the sheet's
    /// in-progress spinner + disabled button, 034 P2).
    @Published private(set) var isSnapshotting = false
    /// Bumped when the snapshot set on disk changes (a manual snapshot lands, or one
    /// is deleted), so the sheet re-reads the list.
    @Published private(set) var snapshotsVersion = 0

    /// Take a manual snapshot now; report success/failure on the shared surfaces.
    /// Guards against a double-tap while one is already running.
    func snapshotNow() {
        guard let manager = snapshotManager, !isSnapshotting else { return }
        isSnapshotting = true
        Task {
            do {
                _ = try await manager.snapshot(reason: .manual)
                notify("Snapshot saved.")
            } catch {
                lastError = Self.message(for: error)
            }
            isSnapshotting = false
            snapshotsVersion &+= 1
        }
    }

    /// The on-disk size (bytes, incl. sidecars) of a snapshot, for the list.
    func snapshotByteSize(_ snapshot: SnapshotFile) -> Int64 {
        snapshotManager?.byteSize(of: snapshot) ?? 0
    }

    /// Delete one snapshot on the user's explicit request, then refresh the list.
    func deleteSnapshot(_ snapshot: SnapshotFile) {
        snapshotManager?.delete(snapshot)
        snapshotsVersion &+= 1
    }

    /// Stage `snapshot` to be restored on the next launch, then prompt the user to
    /// relaunch. The swap itself happens at bootstrap, before the DB opens.
    func stageRestore(_ snapshot: SnapshotFile) {
        guard let manager = snapshotManager else { return }
        do {
            try manager.stageRestore(snapshot)
            refreshPendingRestore()
            showSnapshots = false
            restoreStagedMessage = "The snapshot will be restored the next time you "
                + "open AtelierRefs. Quit and reopen to complete the restore — your "
                + "current library is set aside, not deleted."
        } catch {
            lastError = "Couldn’t stage the restore: \(Self.message(for: error))"
        }
    }

    /// Run an asset mutation that changes the current folder's contents, then
    /// refresh the tree + reload the folder and publish `body`'s message as a notice.
    /// Thrown `AtelierError`s land in ``lastError``. (The folder-scoped `perform`
    /// also resets the selected folder; asset mutations never need that.)
    private func mutateContents(_ body: @escaping (AppServices) async throws -> String) {
        guard let services else { return }
        Task {
            do {
                let message = try await body(services)
                await refreshFolders()
                loadContents(of: selectedFolderID)
                notify(message)
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// "1 item" / "N items" for notice + confirmation copy.
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
        return try await services.collectionItems(in: collectionID, includeArchived: false)
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

    /// The gallery cards' fanned "stack" previews (009 · N4): item count + newest
    /// thumbnail hashes per ROOT collection, Unsorted included. Keyed by
    /// collection id; an absent id ⇒ the card falls back to its cover.
    @Published private(set) var stackPreviews: [UUID: CollectionStackPreview] = [:]

    /// Reload every root collection's fan preview for the Collections gallery.
    func refreshStackPreviews() async {
        guard let services else { return }
        do {
            let previews = try await services.collectionStackPreviews(includeUnsorted: true)
            let lookup = Dictionary(
                previews.map { ($0.collection.id, $0) }, uniquingKeysWith: { first, _ in first })
            if stackPreviews != lookup { stackPreviews = lookup }
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
    /// Whether a `refreshSpaces` has completed against an OPEN library. Until then
    /// an empty `spaces` means "not loaded yet", NOT "no spaces" — the sidebar shows
    /// a skeleton, not the empty state (034 P2 loading-flash). Lives on the model
    /// (not view `@State`) because a pre-bootstrap call no-ops on the guard below.
    @Published private(set) var spacesLoaded = false

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
        spacesLoaded = true
    }

    /// The Home Spaces cards' fanned "stack" previews (009 · N4): placed-item count
    /// + newest asset thumbnail hashes per space. Keyed by space id; an absent id ⇒
    /// the card falls back to its cover.
    @Published private(set) var spaceStackPreviews: [UUID: SpaceStackPreview] = [:]

    /// Reload every space's fan preview for the Home Spaces section.
    func refreshSpaceStackPreviews() async {
        guard let services else { return }
        do {
            let previews = try await services.spaceStackPreviews()
            let lookup = Dictionary(
                previews.map { ($0.space.id, $0) }, uniquingKeysWith: { first, _ in first })
            if spaceStackPreviews != lookup { spaceStackPreviews = lookup }
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

    /// Reposition a space in the flat manual order (`index` nil ⇒ append). Undoable
    /// — the inverse restores the old slot (captured `sortIndex`), so undoing a drag
    /// puts the space back exactly where it was (the space analog of ``moveFolder``).
    func moveSpace(id: UUID, index: Int? = nil) {
        guard services != nil else { return }
        let oldIndex = spaces.first { $0.id == id }?.sortIndex
        enqueueUndoable { await self.applyMoveSpace(id: id, index: index) }
        registerReversible("Move Space",
            primary: { self.enqueueUndoable { await self.applyMoveSpace(id: id, index: index) } },
            inverse: { self.enqueueUndoable { await self.applyMoveSpace(id: id, index: oldIndex) } })
        announceUndoable("Moved “\(spaces.first { $0.id == id }?.name ?? "space")”.")
    }

    /// Reposition a space, then refresh the list + Home stack previews (both share
    /// the one manual order). `index` flows straight to `moveSpace` (043 · 2B).
    private func applyMoveSpace(id: UUID, index: Int? = nil) async {
        guard let services else { return }
        do {
            try await services.moveSpace(id: id, index: index)
            await refreshSpaces()
            await refreshSpaceStackPreviews()
        } catch { lastError = Self.message(for: error) }
    }

    /// Apply a routed spaces outline-view drop (043 · Phase C, spaces). `.reject` is
    /// a no-op; a `.move` funnels through the undoable ``moveSpace(id:index:)``.
    func applySpaceDrop(_ drop: SpaceDrop, dragged: UUID) {
        guard case let .move(index) = drop else { return }
        moveSpace(id: dragged, index: index)
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
        guard let pending = pendingSpaceDeletion else { return }
        pendingSpaceDeletion = nil
        deleteSpaceRecoverableWithUndo(id: pending.id, name: pending.name)
    }

    /// Delete ONE space recoverably + register its ⌘Z undo. Shared by the single
    /// confirmed delete and the Home marquee batch delete (below).
    private func deleteSpaceRecoverableWithUndo(id: UUID, name: String) {
        guard let services else { return }
        enqueueUndoable {
            do {
                let backup = try await services.deleteSpaceRecoverable(id: id)
                await self.refreshSpaces()
                await self.refreshSpaceStackPreviews()
                self.registerReversible("Delete Space",
                    primary: { self.enqueueUndoable { await self.applyDeleteSpaceAgain(id) } },
                    inverse: { self.enqueueUndoable { await self.applyRestoreSpace(backup) } })
                self.announceUndoable("Deleted space “\(name).”")
            } catch {
                self.lastError = Self.message(for: error)
            }
        }
    }

    /// Delete a marquee selection of Home cards (009 · N6) after a single
    /// confirmation. Collections are removed fire-and-forget (``deleteFolder``
    /// already guards Unsorted); each space is removed recoverably with its own
    /// ⌘Z undo, mirroring the single-space delete. The grids refresh via those
    /// paths (`perform` for folders, `refreshSpaces` for spaces).
    func deleteCards(collectionIDs: [UUID], spaceIDs: [UUID]) {
        for id in collectionIDs { deleteFolder(id: id) }
        for id in spaceIDs {
            let name = spaces.first { $0.id == id }?.name ?? ""
            deleteSpaceRecoverableWithUndo(id: id, name: name)
        }
    }

    /// Home's answer to a bare ⌫ (073): **nothing is deleted, and it says so.**
    ///
    /// Everywhere else ⌫ drops the item from the container in view. Home is not a
    /// container — a collection card is not "in" anything you could take it out of —
    /// so the remove half of the rule has no meaning there and the key deletes
    /// nothing. It used to delete the cards outright, which is exactly why this is a
    /// notice and not silence: muscle memory trained on the old binding needs to be
    /// told which key took the verb over. Same shape, same sentence pattern, as
    /// ``removeFromCurrentFolder(assetIDs:)``'s Unsorted branch.
    func explainHomeDeleteKey() {
        notify("Home has nothing to remove from — press ⌘⌫ to delete.")
    }

    /// Restore a captured space delete (undo) — reinstates the board verbatim.
    private func applyRestoreSpace(_ backup: DeletedSpaceBackup) async {
        guard let services else { return }
        do {
            try await services.restoreDeletedSpace(backup)
            await refreshSpaces()
            notify("Restored space “\(backup.space?.name ?? "").”")
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
            let sourceItems = try await services.collectionItems(in: collectionID, includeArchived: false)
            guard !sourceItems.isEmpty else {
                notify("That collection has no items to seed a space.")
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

    /// Add assets to an existing space BY ID — the sidebar drag-to-space drop, with
    /// no open ``SpaceModel`` in play. The assets flow into justified rows BELOW the
    /// space's current content (mirroring ``SpaceModel/addAssets(_:)``). A space is a
    /// placement board, so this is always ADDITIVE — the source collection is never
    /// touched. Refreshes the spaces list so the card cover/preview updates.
    func addAssetsToSpace(assetIDs: [UUID], to spaceID: UUID) {
        guard let services, !assetIDs.isEmpty else { return }
        Task {
            do {
                // Where the current content ends, and the next free z.
                let existing = try await services.spaceItems(in: spaceID)
                let startY: Double = {
                    let maxBottom = existing.map { $0.item.y + $0.item.h }.max() ?? 0
                    return maxBottom > 0 ? maxBottom + SpaceLayout.spacing : 0
                }()
                let startZ = (existing.map(\.item.z).max() ?? -1) + 1
                // Resolve the dragged ids to assets (for aspect-ratio flow-in),
                // skipping any that no longer exist.
                var assets: [Asset] = []
                for id in assetIDs {
                    if let detail = try? await services.getAsset(id: id) { assets.append(detail.asset) }
                }
                guard !assets.isEmpty else { return }
                let rects = SpaceLayout.flowIn(
                    aspects: assets.map(SpaceLayout.aspect), originY: startY, startZ: startZ)
                for (asset, rect) in zip(assets, rects) {
                    try await services.addAssetToSpace(
                        assetID: asset.id, to: spaceID,
                        x: rect.x, y: rect.y, w: rect.w, h: rect.h, z: rect.z)
                }
                // First content into an empty space → seed its cover.
                if existing.isEmpty, let first = assets.first {
                    try? await services.setSpaceCover(spaceID: spaceID, assetID: first.id)
                }
                await refreshSpaces()
                let name = spaces.first(where: { $0.id == spaceID })?.name ?? ""
                notify("Added \(Self.itemCount(assets.count)) to “\(name).”")
            } catch {
                lastError = Self.message(for: error)
            }
        }
    }

    /// Build a per-open-space view model against the shared Library (005-E2).
    /// `nil` before the Library opens.
    func makeSpaceModel(for spaceID: UUID) -> SpaceModel? {
        guard let services, let store else { return nil }
        return SpaceModel(spaceID: spaceID, services: services, store: store)
    }

    // MARK: - Ambient clipboard capture (013 · K3)

    /// Wire the clipboard watcher to this library and let it resume the stored
    /// preference (off unless the user turned it on before).
    ///
    /// The id comes from ``LibraryIdentity`` — the same stable name the backup
    /// destination uses — because the preference key is namespaced `library.<id>.`
    /// per 016 §C. If it cannot be resolved (a malformed `library-id` file, which
    /// that type deliberately refuses to self-heal), the watcher simply stays
    /// unavailable: a per-library preference we can't read is not an invitation to
    /// guess, and "no ambient capture" is the safe side of that guess.
    private func activateClipboardWatcher(root: URL) {
        clipboard.onCapture = { [weak self] capture in
            self?.ingestClipboardCapture(capture)
        }
        clipboard.onOpenSettings = { Self.openSettingsWindow() }
        guard let libraryID = try? LibraryIdentity.resolve(root: root) else {
            AppLog.model.error(
                "library id unresolved — clipboard capture stays unavailable this launch")
            return
        }
        clipboard.activate(libraryID: libraryID)
    }

    /// File one ambient capture into Unsorted, through the ordinary import path.
    ///
    /// Deliberately NOT ``run(inputs:)``: that reloads the folder a batch landed
    /// in, which is right for a paste (the user is looking at it) and wrong here —
    /// an image copied in another app must not yank the grid over to Unsorted
    /// while the user is working in a collection. So the tree refreshes (counts
    /// move), and the contents reload only if Unsorted is what's on screen.
    ///
    /// The completion toast ``importInputs(_:undecoded:)`` posts is kept on
    /// purpose: an ambient capture the user did not ask for, item by item, is
    /// exactly the thing that should say so. 18A content-hash dedup makes a
    /// double-fire (or the same image copied twice) resolve to the one asset.
    private func ingestClipboardCapture(_ capture: ClipboardCapture) {
        guard isReady else { return }
        let target = Collection.unsortedID
        let input = DirectInputReader.clipboardInput(
            imageData: capture.imageData,
            appName: capture.app.name,
            appBundleID: capture.app.bundleID,
            into: target, at: Date())
        Task {
            _ = await importInputs([input])
            await refreshFolders()
            if selectedFolderID == target { loadContents(of: target) }
        }
    }

    /// Open the Settings scene from AppKit (the menu-bar item).
    ///
    /// SwiftUI's `Settings` scene has no programmatic opener outside a view
    /// hierarchy (`SettingsLink` is a `View`), so this goes through the action the
    /// ⌘, menu item sends. The selector was renamed in macOS 13, hence the pair —
    /// both are tried, and doing nothing is an acceptable failure for a
    /// convenience item.
    private static func openSettingsWindow() {
        let selectors = [
            Selector(("showSettingsWindow:")),
            Selector(("showPreferencesWindow:")),
        ]
        NSApp.activate(ignoringOtherApps: true)
        for selector in selectors where NSApp.sendAction(selector, to: nil, from: nil) {
            return
        }
    }

    // MARK: - Import

    /// Run a batch of inputs through the coordinator OFF-MAIN, then reload the
    /// selected folder's contents + the tree. A no-op if not ready / empty.
    ///
    /// `undecoded` (drag path) is the count of dropped items that couldn't be read
    /// at all — folded into the completion notice so a partial drop reports "N
    /// imported, M couldn't be read" rather than dropping them silently (7A).
    func run(inputs: [IngestInput], undecoded: Int = 0) {
        guard isReady, coordinator != nil, !inputs.isEmpty else { return }
        // Reload the folder the batch actually LANDED in, not `selectedFolderID`.
        // Each input bakes in its destination at decode (the pasting view's own
        // `collectionID`), so if the selection hasn't caught up yet the imported
        // assets still appear in the grid the user pasted into instead of silently
        // going missing. A mixed-target batch has no single grid to show, so it
        // falls back to the selection.
        let first = inputs[0].collectionID
        let folder = inputs.allSatisfy { $0.collectionID == first } ? first : selectedFolderID
        Task {
            _ = await importInputs(inputs, undecoded: undecoded)
            await refreshFolders()
            loadContents(of: folder)
        }
    }

    /// Ingest inputs for files the user CHOSE (the "Import Images…" panel), targeting
    /// `folder`. Routes through the same ``DirectInputReader/fileInput(fileURL:into:at:)``
    /// factory a Finder DROP builds, so a chosen file and a dropped file are the same
    /// import — one decode order, one dedup, one provenance shape.
    ///
    /// Static + input-returning rather than a whole import method, so each caller keeps
    /// the completion it needs: the grid hands these to ``run(inputs:undecoded:)``
    /// (which reloads the folder), the board to ``importInputs(_:undecoded:)`` (which
    /// returns the assets to place).
    nonisolated static func fileInputs(_ urls: [URL], into folder: UUID) -> [IngestInput] {
        let now = Date()
        return urls.map { DirectInputReader.fileInput(fileURL: $0, into: folder, at: now) }
    }

    /// The awaitable ingest CORE shared by the grid path (``run``, fire-and-forget)
    /// and the canvas drop path (059 · SP3 / 1A·2A — `await` → place). Runs the
    /// batch through the coordinator, drives `progress` + the completion notice, and RETURNS the
    /// dedup-resolved assets in input order. Assets are collapsed by id so a
    /// same-file-twice drop yields ONE asset (059 · Q2). Each input already carries
    /// its target folder (baked in at decode), so this takes no folder. Empty batch
    /// → `[]` with no notice churn. Does NOT reload the grid — that stays with the
    /// caller, so the canvas can place instead of refreshing a folder it isn't on.
    @discardableResult
    func importInputs(_ inputs: [IngestInput], undecoded: Int = 0) async -> [Asset] {
        guard let coordinator, !inputs.isEmpty else { return [] }
        let total = inputs.count
        // No "Importing N…" notice: `progress` drives ``ImportProgressPill``, which
        // shows the same thing live on both the grid and a board. Only the OUTCOME
        // needs a toast, because it can report failures the pill never sees.
        progress = Progress(completed: 0, total: total)

        let outcomes = await coordinator.ingest(inputs) { completed, total in
            Task { @MainActor [weak self] in
                self?.progress = Progress(completed: completed, total: total)
            }
        }

        var assets: [Asset] = []
        var seen: Set<UUID> = []
        var imported = 0
        var failures = 0
        for outcome in outcomes {
            switch outcome {
            case let .ingested(asset, _):
                imported += 1
                if seen.insert(asset.id).inserted { assets.append(asset) }
            case .failed: failures += 1
            case .cancelled: break
            }
        }

        progress = nil
        notify(Self.importStatus(
            imported: imported, failures: failures, undecoded: undecoded))
        return assets
    }

    /// Compose the completion notice for an import batch: always the imported
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
    /// the existing notice / `lastError` infra. A no-op if not ready.
    ///
    /// `folder` is the target the CALLER is showing — the pasting view's own
    /// `collectionID`, exactly like the byte path bakes into its `IngestInput`s.
    /// It used to read `selectedFolderID`, which lags the sidebar selection by a
    /// runloop hop: a URL pasted right after switching (or creating) a collection
    /// landed in the PREVIOUS one, and the reload that followed left the visible
    /// collection stuck on its "Loading collection" skeleton.
    func ingestRemoteImage(from url: URL, into folder: UUID) {
        guard isReady else { return }
        let target = folder
        let fetcher = remoteFetcher
        notify("Downloading image…")
        Task {
            do {
                let input = try await fetcher.ingestInput(for: url, into: target, at: Date())
                run(inputs: [input])
            } catch {
                // A page URL sniffs as HTML, not an image → resolve it into a LINK
                // (001 · C2b) rather than failing. Any OTHER error (blocked host, too
                // large, transport) surfaces its friendly notice.
                if case RemoteImageFetchError.notAnImage = error {
                    await resolveLinkAndIngest(from: url, into: target)
                } else {
                    notify(Self.remoteFetchStatus(for: error))
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
        run(inputs: [await resolveLinkInput(from: url, into: folder)])
    }

    /// The input-producing half of ``resolveLinkAndIngest`` (059 · SP3) — resolve a
    /// page URL into the `.link` ``IngestInput`` WITHOUT running it, so both the
    /// grid path (fire-and-forget `run`) and the awaitable canvas path
    /// (``importRemoteURL``) share one resolution. Every branch yields a saveable
    /// link so the drop is never lost.
    private func resolveLinkInput(from url: URL, into folder: UUID) async -> IngestInput {
        if PageResolver.isAuthWalledHost(url) {
            // Auth-walled: an app fetch returns a login / share-card, so DON'T resolve —
            // but still save a BARE link (URL preserved, no fetch) so the paste yields a
            // clickable item. The extension remains the way to get the rich tweet card.
            return Self.linkInput(for: url, page: nil, imageData: nil, into: folder)
        }
        notify("Resolving link…")
        let page = try? await pageResolver.resolve(url)
        // Fetch the og:image as the link's card image (guarded), best-effort.
        var imageData: Data?
        if let imageURL = page?.imageURL {
            imageData = try? await remoteFetcher.fetch(imageURL).data
        }
        return Self.linkInput(for: url, page: page, imageData: imageData, into: folder)
    }

    /// Awaitable remote-URL import (059 · SP3): download a bare image URL, or —
    /// when the URL is a page, not an image — resolve it into a link, then ingest
    /// and RETURN the resolved assets so the canvas can place them. Mirrors
    /// ``ingestRemoteImage`` (the grid path) but awaits + returns instead of
    /// fire-and-forget. Network runs off-actor; failures surface as a notice.
    func importRemoteURL(_ url: URL, into folder: UUID) async -> [Asset] {
        notify("Downloading image…")
        do {
            let input = try await remoteFetcher.ingestInput(for: url, into: folder, at: Date())
            return await importInputs([input])
        } catch {
            if case RemoteImageFetchError.notAnImage = error {
                return await importInputs([await resolveLinkInput(from: url, into: folder)])
            }
            notify(Self.remoteFetchStatus(for: error))
            return []
        }
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

    /// Add a color item (003 · C1) to `folder` from a user-typed hex or color-picker
    /// selection. Media-less, so it skips the blob pipeline entirely and goes straight
    /// through `ingestContent` with local-paste provenance; canonicalization + dedup
    /// happen in the funnel. A malformed hex surfaces via ``lastError``. Reloads the
    /// target folder on success.
    ///
    /// The target is a PARAMETER, not `selectedFolderID`. That field is the last
    /// collection whose contents were loaded, which is not the collection the user is
    /// looking at when the add is triggered from Home or a Space — a swatch added
    /// there landed in an off-screen folder and read as "nothing happened". Callers
    /// pass the same resolved target their drop / ⌘V paths use.
    func addColor(hex: String, into folder: UUID) {
        perform(reloading: folder) { services in
            _ = try await services.ingestContent(
                .color(hex: hex),
                from: SourceDraft(platform: .localPaste, capturedAt: Date()),
                into: folder)
        }
    }

    /// Add a link item (003 · C2) to `folder` from a user-typed URL. When the input is
    /// a usable http(s) URL it is RESOLVED (001 · C2b) — og:title / description /
    /// og:image fill the card (SSRF-walled). A resolution failure still saves a bare
    /// link keyed by the URL. A non-URL string falls through to the funnel, which
    /// surfaces `.invalidLinkURL` into ``lastError``.
    ///
    /// Takes its target explicitly, for the reason ``addColor(hex:into:)`` explains.
    func addLink(url raw: String, into folder: UUID) {
        guard isReady else { return }
        guard let url = Self.webURL(fromUserInput: raw) else {
            perform(reloading: folder) { services in
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
        notify("Couldn't read that drop — no image, file, or image URL.")
    }

    /// Report a ⌘V of the app's own copy back into the collection it came from
    /// (019 · C2). `addAssets` guarantees ONE membership, so the paste genuinely
    /// changes nothing — say so, rather than letting the grid appear to swallow the
    /// keystroke. Same shape as ``reportUnreadableDrop()``: a plain notice for a
    /// deliberate no-op.
    func reportAlreadyInCollection() {
        notify("Already in this collection.")
    }

    /// A friendly notice for a failed remote-image download.
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
