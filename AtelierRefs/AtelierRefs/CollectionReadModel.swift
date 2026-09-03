//
//  CollectionReadModel.swift
//  AtelierRefs
//
//  099 · 1A — the per-window read model.
//
//  `IngestionModel` held ONE `items` array for the whole app. Every window, every
//  pane and every grid read the same 1,400-line god-object's single feed, so
//  "what is on screen" and "what a write just touched" were the same variable —
//  which is why an undo of a move performed in another folder repointed the
//  visible grid at a collection the user was not looking at (see
//  ``IngestionModel/performWrite(focus:reload:_:)`` for the other half of that
//  story). It also meant a second feed — the saved-search grid P4 builds, the
//  palette P6 builds — had nowhere to live but a second copy of the same code.
//
//  This is `SpaceModel`'s shape applied to a collection: a small observable over
//  the shared library, owning ONE feed and everything derived from it, with the
//  READ injected. A collection window gets ``CollectionFeed/collection(_:sort:)``;
//  a saved-search window gets ``CollectionFeed/savedSearch(_:limit:)``. The rows
//  are the same type either way — `CollectionItemDetail`, which the search-results
//  grid has consumed through ``looseItems(for:)`` since 048 — and the ONE thing
//  that differs is whether they carry a real membership. Every manual-order
//  affordance keys off that, because a saved search has no manual order
//  ([057](../../.docs/057-smart-collections-overview.md)).
//
//  `IngestionModel` keeps the writes, the undo stack and the selection. It also
//  keeps thin forwards to everything here, so the ~300 existing `model.items` /
//  `model.displayItems` / `model.detailRun` call sites did not have to churn in
//  the same commit that moved the storage. The forwards are computed properties
//  over `contents`, never storage: there is exactly one feed and it lives here.
//

import AtelierCore
import Combine
import Foundation

// MARK: - The injected read

/// Where a ``CollectionReadModel``'s rows come from.
///
/// Two shapes ship today and they differ in one load-bearing way: a collection
/// feed's rows carry a real `collection_item` membership (so they can be dragged
/// into a manual order, and `manual_order` means something), while a saved-search
/// feed's rows are synthesised around bare assets and carry none. Rather than let
/// each surface re-derive that from what it happens to know, the feed states it
/// once in ``carriesMembership`` and every manual-order affordance asks.
@MainActor
struct CollectionFeed {

    /// One resolved page of a feed: the rows, and the child collections to show
    /// beside them (empty for a feed that has no tree under it).
    struct Page: Equatable {
        var items: [CollectionItemDetail]
        var subfolders: [Collection]

        init(items: [CollectionItemDetail], subfolders: [Collection] = []) {
            self.items = items
            self.subfolders = subfolders
        }
    }

    /// Whether these rows carry a real collection membership — i.e. whether a
    /// manual order exists to drag them into. `false` for every search-shaped
    /// feed (057: a saved search has no manual order).
    let carriesMembership: Bool

    /// The `AtelierError.notFound` entity this feed can be missing, and the
    /// sentence to say when it is. A collection window says "That folder no longer
    /// exists."; a saved-search window has its own noun. Everything else falls
    /// through to Core's exhaustive table (099 · 6A).
    let missingEntity: String
    let missingSentence: String

    /// Read one page. `nil` means "there is nothing to read yet" — the library is
    /// not open — and the read model publishes nothing at all, which is what
    /// `loadContents`' `guard let services else { return }` did before it.
    let read: (UUID) async throws -> Page?

    /// A feed with no library behind it: the state a read model is in between
    /// construction and ``IngestionModel/bootstrap()`` opening the Library.
    ///
    /// It reads nothing rather than reading empty, so a window built before the
    /// Library opens shows the loading skeleton (`loadedCollectionID == nil`)
    /// instead of an empty collection that would read as "you have nothing here".
    static let idle = CollectionFeed(
        carriesMembership: true,
        missingEntity: "collection",
        missingSentence: "That folder no longer exists.",
        read: { _ in nil })

    /// A collection's own contents: the P14 joined read plus the immediate
    /// subfolders, both concurrently (009 · 16A — the reload latency is the slowest
    /// ONE, not their sum).
    ///
    /// `sort` resolves the collection's stored ``SortMode`` at read time rather
    /// than taking a value, because the mode is per-collection and lives in the
    /// folder cache the writing model owns; a captured value would be one folder
    /// switch out of date.
    static func collection(
        _ services: AppServices,
        sort: @escaping (UUID) -> SortMode = { _ in .manual }
    ) -> CollectionFeed {
        CollectionFeed(
            carriesMembership: true,
            missingEntity: "collection",
            missingSentence: "That folder no longer exists.",
            read: { id in
                // Resolved BEFORE the concurrent reads: `sort` is main-actor state
                // (it reads the folder cache), and evaluating it inside an
                // `async let` would send it into a child task.
                let mode = sort(id)
                async let items = services.collectionItems(
                    in: id, sort: mode, includeArchived: false)
                async let subfolders = services.childCollections(of: id)
                return try await Page(items: items, subfolders: subfolders)
            })
    }

    /// A saved search's live results (015): the stored rules through
    /// `evaluate(rules:)`, wrapped as membership-less rows by ``looseItems(for:)``.
    ///
    /// **No memberships, and no subfolders.** A saved search is a query, not a
    /// container: nothing is filed in it, so there is no manual order to drag into
    /// and no tree beneath it. `evaluateSavedSearch` is `evaluate(rules:)` behind
    /// the stored blob, and it is the call that owns the two badge errors P4 will
    /// render — `.notFound` for a deleted search and `.invalidSavedSearchRules` for
    /// a blob that will not decode.
    ///
    /// `limit` matches the search-results grid's own 500 (`LibrarySearch.swift`),
    /// so the two surfaces that show the same query show the same number of hits.
    ///
    /// **`sort` is applied here, over the fetched page, and it has to be.** 057
    /// gives a smart collection 007's grid modes minus `.manual`, but
    /// `evaluate(rules:)` deliberately passes no `sort:` at all — sort is display,
    /// not part of what a saved search MEANS (`SearchRules`' own header), and
    /// `searchAssets`' `SearchSort` has only `.newest` and `.relevance` anyway.
    /// So `.newest` IS the service's order, untouched, and `.mostViewed` is
    /// `mostViewedSorted` — core's own `view_count DESC, created_at DESC, id DESC`,
    /// reproduced byte-for-byte by the function that exists for exactly that
    /// promise. A value rather than a closure over `id`, unlike
    /// ``collection(_:sort:)``: a collection's mode is per-collection state the
    /// writing model caches, while a smart collection's is the window's own and
    /// the window rebuilds the feed when it changes.
    static func savedSearch(
        _ services: AppServices,
        sort: SmartCollectionSort = .newest,
        limit: Int = 500
    ) -> CollectionFeed {
        CollectionFeed(
            carriesMembership: false,
            missingEntity: "saved_search",
            missingSentence: "That smart collection no longer exists.",
            read: { id in
                let hits = try await services.evaluateSavedSearch(id: id, limit: limit)
                let rows = looseItems(for: hits)
                switch sort {
                case .newest: return Page(items: rows)
                case .mostViewed: return Page(items: mostViewedSorted(rows))
                }
            })
    }
}

// MARK: - The read model

/// One window's view of one collection (or one saved search).
///
/// Owns the feed and every index derived from it; owns NOTHING that writes. The
/// only state it mutates outside itself is the ``GridSelectionStore`` it is handed
/// — it sets the display order and prunes the selection to survivors, both of
/// which are facts about the feed and cannot be computed anywhere else.
@MainActor
final class CollectionReadModel: ObservableObject {

    // MARK: - The feed

    /// The loaded rows. Rebuilds the O(1) selection/drag indexes on every
    /// assignment — a load, a move, a reorder — so the marquee/drag hot path never
    /// rescans per cell (009 · N6).
    @Published private(set) var items: [CollectionItemDetail] = [] {
        didSet { rebuildItemDerivations() }
    }

    /// The collection ``items`` currently belong to — the identity a view checks
    /// to know whether the array is ITS data yet. `nil` until the first load
    /// resolves, which is what makes a freshly-pushed grid show a loading skeleton
    /// rather than the previous collection's content during the async reload gap.
    @Published private(set) var loadedCollectionID: UUID?

    /// The loaded collection's immediate subfolders (navigable). Always empty for
    /// a feed with no tree under it.
    @Published private(set) var subfolders: [Collection] = []

    /// Bumped whenever ``items`` changes, so a dependent view can rebuild.
    @Published private(set) var contentsVersion = 0

    /// The last fetch failure's sentence, or `nil`. The window mirrors it into
    /// whatever raises the alert.
    @Published var lastError: String?

    /// Where the rows come from. A `var` because a window is built before the
    /// Library is open: it starts ``CollectionFeed/idle`` and is pointed at a real
    /// read exactly once, by whoever opened the library.
    var feed: CollectionFeed

    /// The grid selection this feed orders and prunes. Injected rather than owned:
    /// selection belongs to the writing model (099 · 1A), and the same store is
    /// read by the verbs.
    let selectionStore: GridSelectionStore

    /// Load lifecycle, for tests that must await a reload rather than guess at one
    /// (099 · 11A). Nothing in the app subscribes.
    let events = EventSignal<Event>()

    /// What a load did. Deliberately the LIFECYCLE, not the answer: a test that
    /// awaits `.superseded` proves the race guard held, which "the items are what I
    /// expected" cannot.
    ///
    /// `nonisolated` because the app target defaults every unannotated type to
    /// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION`), and a main-actor `Equatable`
    /// conformance cannot be used from the `@Sendable` predicate an ``EventRecorder``
    /// wait is written as. The events carry only value types, so there is nothing
    /// here for the main actor to protect.
    nonisolated enum Event: Sendable, Equatable {
        /// A load published `count` rows for `collectionID`.
        case loaded(collectionID: UUID, count: Int)
        /// A load finished but a NEWER one had already started, so it published
        /// nothing at all.
        case superseded(collectionID: UUID)
        /// A load threw; ``lastError`` carries the sentence.
        case failed(collectionID: UUID)
        /// There was no library to read from — nothing was published.
        case idle(collectionID: UUID)
    }

    /// Monotonic id so a slow read can never clobber a newer one (a fast folder
    /// switch, or a mutation-triggered reload). Moved here verbatim: the guard is
    /// the whole reason a shared feed was survivable, and it is not re-derived.
    private var loadID = 0

    /// A selection to apply once a target collection finishes loading (011-B4 · 12A
    /// Jump). Deterministic, not a timer: ``load(_:)`` applies it against the
    /// freshly loaded items, then clears it.
    private var pendingSelection: (collectionID: UUID, assetIDs: Set<UUID>)?

    private var selectionCancellable: AnyCancellable?
    private var changeCancellable: AnyCancellable?

    init(feed: CollectionFeed = .idle, selectionStore: GridSelectionStore) {
        self.feed = feed
        self.selectionStore = selectionStore
        // Keep the selected-asset-id cache in step with the store — the Combine
        // replacement for the old `selection.didSet`. The closure receives the NEW
        // value (see ``rebuildSelectedAssetIDs(for:)`` on why we must not re-read
        // the store here). `@Published` emits on subscribe, so the cache is seeded.
        selectionCancellable = selectionStore.$selection
            .sink { [weak self] newSelection in
                self?.rebuildSelectedAssetIDs(for: newSelection)
            }
    }

    // MARK: - Loading

    /// Load `id` through the injected feed and publish it.
    ///
    /// The load-id race guard is 004's, unchanged: two reads can finish out of
    /// order, so a stale one must not overwrite the current feed. It bails BEFORE
    /// publishing anything — including before `lastError`, so a superseded failure
    /// cannot raise an alert about a collection the user has already left.
    func load(_ id: UUID) {
        loadID &+= 1
        let thisLoad = loadID
        let read = feed.read
        Task {
            do {
                let page = try await read(id)
                // Superseded FIRST, so a stale read reports itself as stale whatever
                // it came back with.
                guard thisLoad == loadID else {
                    events.emit(.superseded(collectionID: id))
                    return
                }
                guard let page else {
                    events.emit(.idle(collectionID: id))
                    return
                }
                publish(page, for: id)
                events.emit(.loaded(collectionID: id, count: page.items.count))
            } catch {
                guard thisLoad == loadID else {
                    events.emit(.superseded(collectionID: id))
                    return
                }
                lastError = message(for: error)
                events.emit(.failed(collectionID: id))
            }
        }
    }

    /// Reload whatever is currently loaded, if anything. The no-op when nothing is
    /// loaded is the point: a window that has never shown a collection has no
    /// business fetching one because some other window wrote.
    func reload() {
        guard let id = loadedCollectionID else { return }
        load(id)
    }

    /// Subscribe to a library-change subject and reload when it names this feed.
    ///
    /// The rule is the plan's: reload when the published id MATCHES what is loaded,
    /// or when it is `nil` — a producer that cannot say which collection it touched
    /// (an inbox drain resolving each record's own target, an asset delete that may
    /// have been a member of anything) invalidates every feed, and saying so is
    /// more honest than a grid that silently omits what the user just watched
    /// arrive.
    func follow(_ changes: some Publisher<UUID?, Never>) {
        changeCancellable = changes.sink { [weak self] changed in
            guard let self, let loaded = self.loadedCollectionID else { return }
            guard changed == nil || changed == loaded else { return }
            self.reload()
        }
    }

    /// Publish a resolved page as `id`'s content.
    private func publish(_ page: CollectionFeed.Page, for id: UUID) {
        items = page.items
        // A genuine reload IS the database truth — including every persisted
        // `view_count`. Any locally-tracked, not-yet-baked view deltas are now
        // redundant: clear them, or the next Most-Viewed reorder would double-count
        // them on top of counts the reload already carries (036 §3 B4).
        viewDelta.removeAll(keepingCapacity: true)
        // Stamp WHICH collection the array now belongs to, so a freshly-pushed view
        // for a different collection renders a skeleton instead of stale content.
        loadedCollectionID = id
        subfolders = page.subfolders
        // Prune the selection to ids that survive the reloaded set (a folder switch,
        // a move-away, a delete). A removed lead falls back to `nil`; the detail
        // overlay's auto-dismiss is driven by the host observing this reload
        // (036 §3 B1), not by clearing model state here.
        selectionStore.prune(to: items.map { $0.item.id })
        // Apply a pending Jump selection (011-B4 · 12A) against the freshly loaded
        // items, then clear it — deterministic, no timing hack.
        if let pending = pendingSelection, pending.collectionID == id {
            let jumped = jumpSelection(in: items, assetIDs: pending.assetIDs)
            if !jumped.isEmpty { selectionStore.replace(jumped) }
            pendingSelection = nil
        }
        contentsVersion &+= 1
    }

    /// Stash a Jump's target selection, to be applied by the next load of
    /// `collectionID` (011-B4).
    func stageJumpSelection(assetIDs: [UUID], in collectionID: UUID) {
        pendingSelection = (collectionID, Set(assetIDs))
    }

    /// The sentence for a failed read. The feed says what noun it is about; Core's
    /// exhaustive table says everything else (099 · 6A).
    private func message(for error: Error) -> String {
        ErrorMessage.notFound(error, entity: feed.missingEntity, say: feed.missingSentence)
            ?? ErrorMessage.text(for: error)
    }

    // MARK: - Derived selection/drag indexes (009 · N6 perf)

    /// `item.id → asset.id` for O(1) single-cell drag/action scope, replacing an
    /// `items.first { … }` linear scan run per visible cell each marquee tick.
    private var assetIDByItemID: [UUID: UUID] = [:]
    /// The current selection's asset ids in feed order (see ``selectedAssetIDs``).
    private var cachedSelectedAssetIDs: [UUID] = []

    /// The loaded feed bucketed by originating post (307 · carousel grouping) —
    /// what makes "these four tiles are one Instagram carousel" answerable. Built
    /// here rather than in the view because a `CollectionView` body re-runs on every
    /// selection change and the bucketing is O(N) over the whole feed. This is the
    /// ONLY build site; the grid host mirrors it through the configuration.
    private(set) var postGroups = PostGroups()

    /// Whether the grid collapses each multi-image post to one tile (307). Mirrored
    /// from `GridViewPreferences` (which persists it) so the derivation can run where
    /// `items` lives; setting it re-derives, which also bumps ``itemsVersion`` and so
    /// invalidates the masonry layout cache — the display list changed even though
    /// `items` did not.
    ///
    /// `@Published` for the same reason `items` is: the derived values it feeds
    /// (``displayItems``, ``itemsVersion``) are deliberately plain, so this is the
    /// TRIGGER that has to re-run the grid's body.
    @Published var groupCarousels = true {
        didSet { if groupCarousels != oldValue { rebuildItemDerivations() } }
    }

    /// Representative ids of the posts currently OPENED in place (307) — their
    /// members show as their own tiles until the chip is clicked again. Pruned on
    /// every derivation so a representative that left the feed can't keep a post
    /// wedged open.
    @Published private(set) var expandedPosts: Set<UUID> = []

    /// The feed AS THE GRID SHOWS IT: ``items`` with every multi-image post
    /// collapsed to its first member when grouping is on, otherwise `items` verbatim.
    private(set) var displayItems: [CollectionItemDetail] = []
    /// Membership ids of ``displayItems``, for O(1) "is this tile on screen?".
    private var displayItemIDs: Set<UUID> = []

    /// The feed AS THE DETAIL PAGE WALKS IT (069): every image, in the grid's order,
    /// with each post's images together and in the post's own order.
    private(set) var detailRun: [CollectionItemDetail] = []
    /// Position in ``detailRun`` by membership id.
    private var detailRunIndexByItem: [UUID: Int] = [:]

    /// Monotonic token bumped whenever `items` changes, so the grid's masonry layout
    /// cache (011-B1 · 14A) can key off cheap integer equality.
    private(set) var itemsVersion = 0

    /// Where `id` sits in ``detailRun``, or `nil` when it isn't in the loaded feed.
    func detailRunIndex(of id: UUID) -> Int? { detailRunIndexByItem[id] }

    /// The LEAD item's detail — what the full-window detail overlay shows —
    /// resolved from the loaded ``items`` by the `selection.lead` membership id.
    var leadItem: CollectionItemDetail? {
        guard let lead = selectionStore.selection.lead else { return nil }
        return items.first { $0.item.id == lead }
    }

    /// The asset ids of the current selection, in feed order — the boundary from
    /// membership-id selection to the asset-id verbs. Served from a cache rebuilt on
    /// every `items`/`selection` change.
    var selectedAssetIDs: [UUID] { cachedSelectedAssetIDs }

    /// Open or close the post behind the tile `itemID` — what the carousel chip
    /// does. A no-op for an ungrouped tile, so callers don't have to check first.
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

    /// The item ids a TILE stands for, in feed order (307): a collapsed post's whole
    /// membership, or just the item itself when it is ungrouped, opened, or grouping
    /// is off.
    private func itemsRepresented(by displayItemID: UUID) -> [UUID] {
        guard groupCarousels else { return [displayItemID] }
        let members = postGroups.members(forItem: displayItemID)
        guard let lead = members.first, lead == displayItemID,
              !expandedPosts.contains(lead) else { return [displayItemID] }
        return members
    }

    /// The tile that STANDS FOR `id` in the current display list (307).
    func displayTile(for id: UUID) -> UUID {
        if displayItemIDs.contains(id) { return id }
        return postGroups.members(forItem: id).first ?? id
    }

    /// Rebuild the item-keyed indexes after `items` changes.
    private func rebuildItemDerivations() {
        itemsVersion &+= 1
        postGroups = PostGroups(items: items)
        // Drop expansions whose representative has left the feed. Assigned only when
        // it actually changes: `expandedPosts` is `@Published`, and the common case
        // (an empty set, every load) must not fire a publish from a derivation.
        let live = expandedPosts.filter { postGroups.memberCount(forItem: $0) > 1 }
        if live != expandedPosts { expandedPosts = live }
        displayItems = groupCarousels
            ? postGroups.collapsed(items, expanding: expandedPosts)
            : items
        displayItemIDs = Set(displayItems.map { $0.item.id })
        // The detail page's run (069) — derived HERE so it shares the display list's
        // invalidation exactly.
        detailRun = groupCarousels ? postGroups.fullRun(items) : items
        detailRunIndexByItem = Dictionary(
            detailRun.enumerated().map { ($0.element.item.id, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        // Push the DISPLAYED order to the selection store (the reducer's `order`
        // argument). It has to be the display list, not `items`: ⇧-range, arrow nav
        // and the marquee all resolve hits through this order.
        selectionStore.setOrder(displayItems.map { $0.item.id })
        // Keyed over ALL items, not just the displayed ones: an action on a collapsed
        // tile expands to its hidden members and still needs their asset ids.
        assetIDByItemID = Dictionary(
            items.map { ($0.item.id, $0.asset.id) }, uniquingKeysWith: { first, _ in first })
        // Items changed, selection didn't — rebuild the cache against the store's
        // CURRENT (settled) selection.
        rebuildSelectedAssetIDs(for: selectionStore.selection)
    }

    /// Rebuild the selected-asset-id cache after `items` or `selection` changes.
    ///
    /// Takes the selection EXPLICITLY rather than reading the store: when driven by
    /// the `$selection` sink, `@Published` fires on `willSet`, so the store's stored
    /// value is still the OLD one at that instant.
    private func rebuildSelectedAssetIDs(for selection: GridSelection) {
        cachedSelectedAssetIDs = assetIDs(for: widenedForAction(selection.ids))
    }

    /// Widen ids to whole posts for an action — but only where the grid is actually
    /// HIDING members (307). An OPENED post acts per frame, which is precisely the
    /// thing someone opens a carousel to do.
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
    /// MEMBERSHIP-id space — ⌘C, the two exports, and Quick Look.
    func itemIDsForAction(_ ids: Set<UUID>) -> Set<UUID> { widenedForAction(ids) }

    /// The asset behind a membership id, or `nil` when the item has left the loaded
    /// feed. O(1) off the same index the drag/action scope uses.
    func assetID(forItem itemID: UUID) -> UUID? { assetIDByItemID[itemID] }

    /// The asset ids for `itemIDs`, in feed order — THE action boundary (307).
    /// Walks `items`, not `displayItems`: the hidden members are what we widen to.
    private func assetIDs(for itemIDs: Set<UUID>) -> [UUID] {
        items.compactMap { itemIDs.contains($0.item.id) ? $0.asset.id : nil }
    }

    /// The asset ids a batch action should act on for a right-click on the cell
    /// whose membership id is `itemID` (Finder scope, 009 · 7A).
    func actionTargets(forCellItemID itemID: UUID) -> [UUID] {
        gridActionTargets(
            isSelected: selectionStore.selection.ids.contains(itemID),
            selectedAssetIDs: selectedAssetIDs,
            cellAssetIDs: assetIDs(for: widenedForAction([itemID])))
    }

    // MARK: - In-place edits (no reload)

    /// Per-asset view-count deltas that have been PERSISTED (`recordViews`) but not
    /// yet reflected in the local ``items`` (036 §3 B4). Exactly
    /// `DB.view_count − items.viewCount` for every asset, so the invariant
    /// `items.viewCount + viewDelta == DB.view_count` holds at all times.
    ///
    /// It lives HERE, beside the array it is a delta against, so "cleared whenever a
    /// load re-syncs `items`" is one line of ``publish(_:for:)`` rather than a rule
    /// two objects have to remember.
    private(set) var viewDelta: [UUID: Int] = [:]

    /// Fold one drained flush into the delta: +1 per DISTINCT id, because core
    /// coalesces a batch to one `view_count` increment per asset. Raw per-open
    /// counts would over-bump against the database and diverge on the next reload.
    func foldViewDelta(_ ids: [UUID]) {
        for id in ids { viewDelta[id, default: 0] += 1 }
    }

    /// Take one fold back out — the `recordViews` write did NOT land, so the
    /// optimistic delta was never persisted.
    func unfoldViewDelta(_ ids: [UUID]) {
        for id in ids { viewDelta[id]? -= 1 }
    }

    /// Apply the pending Most-Viewed reorder in place, if it changes anything.
    ///
    /// Pure and local: it bumps a copy of ``items`` by ``viewDelta`` and stable-sorts
    /// with core's exact Most-Viewed tiebreak (``mostViewedReorder``). When the order
    /// is unchanged (the common case — the viewed item was already at the top) it
    /// publishes NOTHING and KEEPS the delta, so a later flush still has it. When it
    /// moves, `items` is replaced once (the bumped counts baked in, so `items` again
    /// equals the database truth) and the delta clears.
    ///
    /// - Returns: whether anything was republished.
    @discardableResult
    func applyMostViewedReorder() -> Bool {
        guard !viewDelta.isEmpty else { return false }
        switch mostViewedReorder(items: items, bumps: viewDelta) {
        case .unchanged:
            return false
        case .reordered(let newItems):
            items = newItems
            contentsVersion &+= 1
            viewDelta.removeAll(keepingCapacity: true)
            return true
        }
    }

    /// Solve a drag-reorder in DISPLAY space and apply it optimistically.
    ///
    /// - Parameters:
    ///   - movingAssetIDs: the dragged payload's asset ids (whole posts).
    ///   - slot: the insertion index in the BLOCK-REMOVED display order the live
    ///     preview chose (040).
    /// - Returns: the new full asset order to persist, or `nil` when the drop
    ///   changes nothing (a foreign drop, or a solve that does not resolve).
    ///
    /// The solve has to happen in display space and only then widen back to every
    /// item (307): solving directly against `items` reads "after the 3rd tile" as
    /// "after the 3rd IMAGE", which with carousels collapsed lands a drop near the
    /// start of the feed instead of where it was dropped.
    ///
    /// **A feed with no memberships cannot be reordered** and returns `nil` without
    /// touching anything — there is no `manual_order` to write (057).
    func applyReorder(movingAssetIDs: [UUID], insertAt slot: Int) -> [UUID]? {
        guard feed.carriesMembership else { return nil }
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
        else { return nil }
        // Widen back: each tile contributes the items it stands for, in feed order,
        // which also keeps a post's images contiguous after a move.
        let newOrder = newTileOrder
            .flatMap { itemsRepresented(by: $0) }
            .compactMap { assetIDByItemID[$0] }
        guard !newOrder.isEmpty else { return nil }
        // uniquingKeysWith (not uniqueKeysWithValues) so a duplicate asset id in a
        // folder degrades instead of trapping (G3).
        let byAssetID = keyedByAssetID(items) { $0.asset.id }
        items = newOrder.compactMap { byAssetID[$0] }
        contentsVersion &+= 1
        return newOrder
    }

    #if DEBUG
    /// Test-only: seed the visible feed so a verb that captures the live order
    /// (reorder / remove / move) reads a known state without racing an async load.
    func setItemsForTesting(_ items: [CollectionItemDetail], loadedAs id: UUID? = nil) {
        self.items = items
        if let id { loadedCollectionID = id }
    }
    #endif
}
