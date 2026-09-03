//
//  SmartCollectionView.swift
//  AtelierRefs
//
//  099 · P4 — one smart collection's screen.
//
//  **This is P3's second window.** [472](../../.change-log/472-the-feed-gets-a-model-of-its-own.md)
//  closed by saying the claim it was really making — *"a second window can now have
//  its own feed without touching the writes"* — was demonstrated by a stub and by
//  the shape, not by a second window, and that the first real one would be P4's.
//  This is it: a `CollectionReadModel` pointed at ``CollectionFeed/savedSearch(_:sort:limit:)``,
//  its own ``GridSelectionStore``, and not one line of `IngestionModel`'s feed.
//
//  What it renders is the SAME `MasonryGridHost` the collection grid, the search
//  results and the archive shelf render — selection, marquee, arrows, ⌘A, Esc, ⌘±,
//  the native drag image and the layout cache all arrive already built and already
//  tested. A bespoke grid for smart collections would be a fourth to keep in step
//  with the other three.
//
//  What it deliberately does NOT do, each of these
//  [057](../../.docs/057-smart-collections-overview.md):
//
//   • **No manual order, so no drag-reorder.** `canReorder: false`, and the read
//     model refuses one anyway (`applyReorder` returns `nil` on a feed with no
//     memberships) — belt and braces on purpose, because the two say it for
//     different reasons: the flag stops the live preview from ever promising a
//     reorder, the model stops one being applied if some other path asked.
//   • **No ⌫.** A hit belongs to the QUERY, not to a container, so "remove it from
//     where you are looking" has no answer — the same answer search results and
//     the shelf already give. ⌘⌫ still leaves the library, as it does everywhere.
//   • **It is not a drop target.** You cannot add to a query. There is no import
//     `.onDrop`, no ⌘V, and ``SidebarItem/acceptsAssetDrops`` says so where a test
//     can read it.
//   • **Drag-OUT and drag-to-a-collection still work** — 057 is explicit that they
//     must. They carry ``AssetDragPayload/nilSourceID``, so `routeDrop` resolves
//     every landing as a COPY: there is no collection to move OUT of. An item that
//     stops matching as a result vanishes on the next reload and the selection is
//     pruned, which is 057's own "an item can legitimately vanish mid-triage".
//

import AppKit
import AtelierCore
import SwiftUI

struct SmartCollectionView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @ObservedObject var gridPrefs: GridViewPreferences
    let services: AppServices
    let searchID: UUID

    /// This window's feed — a second ``CollectionReadModel``, the first one the app
    /// has ever built (099 · 1A's whole point).
    @StateObject private var contents: CollectionReadModel
    /// Its selection, owned here rather than shared with the main window's: two
    /// grids showing different things cannot share one selection, and the read
    /// model prunes whichever store it was handed.
    @StateObject private var selectionStore: GridSelectionStore
    /// The smart-collection list, for the header's name and badge.
    @ObservedObject private var smart: SavedSearchesSidebarModel

    @Environment(\.displayScale) private var displayScale

    /// 007's modes minus `.manual` (057). Window state, not persisted: a saved
    /// search has no row to store it on — `sort_mode` is a column on `collection` —
    /// and 057 lists sort among the things a rule deliberately does not carry.
    @State private var sort: SmartCollectionSort = .newest
    /// The live grid width, for the ⌘± density clamp — the same guard every other
    /// grid applies.
    @State private var gridWidth: CGFloat = 1
    /// The open item, if any. A smart collection reuses the membership-less detail
    /// overlay search and the shelf use: an ordered `[AssetDetail]` with no
    /// container is exactly what that page already walks.
    @State private var detail: AssetDetail?
    @State private var detailContexts = LooseDetailContextCache()
    /// The destination hierarchy, memoized (012 · CQ 1A). Plain `@State`; not
    /// observed — ``MoveTargetsCache``'s discipline.
    @State private var moveTargetsCache = MoveTargetsCache()

    init(
        model: IngestionModel, nav: NavModel, gridPrefs: GridViewPreferences,
        services: AppServices, searchID: UUID
    ) {
        _model = ObservedObject(wrappedValue: model)
        _nav = ObservedObject(wrappedValue: nav)
        _gridPrefs = ObservedObject(wrappedValue: gridPrefs)
        _smart = ObservedObject(wrappedValue: model.smartCollections)
        self.services = services
        self.searchID = searchID
        // ONE store, handed to both wrappers. `StateObject(wrappedValue:)` takes an
        // autoclosure evaluated once per view identity, and both close over the same
        // local — so the model prunes exactly the store this view observes.
        let store = GridSelectionStore()
        _selectionStore = StateObject(wrappedValue: store)
        _contents = StateObject(wrappedValue: CollectionReadModel(
            feed: .savedSearch(services), selectionStore: store))
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Group {
                    if contents.loadedCollectionID != searchID {
                        ProgressView()
                    } else if contents.items.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if detail != nil {
                let context = detailContexts.context(
                    results: hits, resultsVersion: contents.contentsVersion,
                    groupCarousels: gridPrefs.groupCarousels)
                LooseDetailOverlay(
                    services: services, model: model,
                    context: context, current: $detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .task {
            mirrorGroupCarousels()
            // The feed follows the library's change stream like the main window's,
            // so a delete, a favourite or a capture elsewhere re-evaluates the query
            // — which is what makes "an item that stops matching vanishes" true
            // without this pane knowing anything about what changed.
            contents.follow(model.libraryChanged)
            contents.load(searchID)
        }
        // A sidebar click on the already-selected row means "show me this
        // destination", which for a live query means running it again.
        .onChange(of: nav.navigationPulse) { _, _ in contents.reload() }
        .onChange(of: gridPrefs.groupCarousels) { _, _ in mirrorGroupCarousels() }
        // The rules changed under us — "Save this search…" re-saved into this very
        // search (057: the search field IS the rule editor). `updatedAt` moves on
        // every re-rule and rename, so this fires for exactly the edits that can
        // change what the grid should show.
        .onChange(of: smart.search(id: searchID)?.updatedAt) { _, _ in contents.reload() }
        .onChange(of: sort) { _, mode in
            // The feed is rebuilt rather than parameterised at read time: a saved
            // search's mode is this WINDOW's, not per-collection state some cache
            // holds, so there is nothing for a closure to resolve later.
            contents.feed = .savedSearch(services, sort: mode)
            contents.reload()
        }
        // Edit ▸ Remove / Delete (022 · D5). `canRemove: false`, as on search and
        // the shelf: a hit belongs to the query, and picking one of its collections
        // to remove it from on the user's behalf would be a guess.
        .focusedSceneValue(\.deleteVerbs, DeleteVerbs(
            removeTitle: "Remove from Collection",
            canRemove: false,
            remove: {},
            destroy: { requestDeleteTargets() }))
    }

    // MARK: - Chrome

    /// The name, the count and — when there is one — 057's badge.
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.Typography.sectionTitle)
                    .foregroundStyle(Theme.Colors.inkPrimary)
                HStack(spacing: Theme.Spacing.sm) {
                    Text(countLabel)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .redacted(reason: contents.loadedCollectionID == searchID ? [] : .placeholder)
                    if let badge = smart.badge(id: searchID) {
                        SmartCollectionBadgeLabel(badge: badge)
                    }
                }
            }
            Spacer(minLength: 0)
            sortMenu
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private var name: String { smart.search(id: searchID)?.name ?? "Smart Collection" }

    private var countLabel: String {
        let n = contents.items.count
        return n == 1 ? "1 item" : "\(n) items"
    }

    /// 007's sort control minus `.manual` (057). Built from
    /// ``SmartCollectionSort/offered`` rather than three hand-written buttons, so a
    /// mode 007 adds appears here without anyone remembering to.
    private var sortMenu: some View {
        Menu {
            ForEach(SmartCollectionSort.offered, id: \.self) { mode in
                Button {
                    sort = mode
                } label: {
                    Label(mode.title, systemImage: sort == mode ? "checkmark" : mode.symbol)
                }
            }
        } label: {
            Label("Sort: \(sort.title)", systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose how this smart collection's grid is ordered — a saved search "
              + "has no manual order")
    }

    /// Three states, not two — `ShelfView`'s rule, for the same reason. "Nothing
    /// matches" is a claim about the query and must not be made before it has run,
    /// nor after it failed.
    @ViewBuilder
    private var emptyState: some View {
        if smart.badge(id: searchID) == .unreadableRules {
            ContentUnavailableView(
                "Can't read this search",
                systemImage: "exclamationmark.triangle",
                description: Text("Its saved rules were written in a shape this "
                    + "version can't read. Re-save the search from the search "
                    + "field to replace them."))
        } else if contents.lastError != nil {
            ContentUnavailableView(
                "Couldn't run this search",
                systemImage: "exclamationmark.triangle",
                description: Text("Something went wrong evaluating the saved rules."))
        } else {
            ContentUnavailableView(
                "Nothing matches",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("A smart collection is a saved search, run fresh "
                    + "every time you open it. Nothing in the library matches its "
                    + "rules right now."))
        }
    }

    private var grid: some View {
        MasonryGridHost(configuration: gridConfiguration)
            .padding(.horizontal, Theme.Spacing.xl)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
                if abs(gridWidth - w) > 0.5 { gridWidth = w }
            }
            .overlay(alignment: .bottom) {
                if selectionStore.selection.isSelecting {
                    selectionBar.padding(.bottom, Theme.Spacing.lg)
                }
            }
    }

    /// The plain count bar. No extra verb: every verb a smart collection offers
    /// needs a membership it does not have, except Delete — which the bar carries
    /// already.
    private var selectionBar: some View {
        CountSelectionBar(
            count: selectionStore.selection.ids.count,
            onClear: { selectionStore.apply(.clear) },
            onDelete: { requestDeleteTargets() })
    }

    /// The whole collection hierarchy as ADD destinations, memoized (012 · CQ 1A)
    /// so a body pass never re-groups the folder tree — the same memo the collection
    /// and search grids hold. Smart collections are structurally absent from it: it
    /// is built from `model.folders`, which is `[Collection]`.
    private var destinationTree: [DestinationTreeNode] {
        moveTargetsCache.destinationTree(
            folders: model.folders, unsortedID: model.unsortedFolderID)
    }

    // MARK: - The feed, as the detail page walks it

    /// The loaded rows as bare `AssetDetail`s — what the membership-less detail
    /// overlay takes. `looseItems(for:)` made `item.id == asset.id` on the way in,
    /// so this is the same list under a different projection, not a second one.
    private var hits: [AssetDetail] {
        contents.items.map { AssetDetail(asset: $0.asset, source: $0.source) }
    }

    /// Keep the read model's grouping in step with the persisted global toggle —
    /// `CollectionView.mirrorGroupCarousels`' rule, assigned only when it differs so
    /// a no-op cannot fire a publish from a derivation.
    private func mirrorGroupCarousels() {
        if contents.groupCarousels != gridPrefs.groupCarousels {
            contents.groupCarousels = gridPrefs.groupCarousels
        }
    }

    // MARK: - Host configuration

    private var gridConfiguration: GridHostConfiguration {
        GridHostConfiguration(
            items: contents.displayItems,
            itemsVersion: contents.itemsVersion,
            postGroups: contents.postGroups,
            density: gridPrefs.density,
            spacing: Theme.Spacing.sm,
            topInset: Theme.Spacing.md,
            // The SEARCH's id, not the sentinel: the host resets its scroll offset
            // when this changes, and switching between two smart collections has to
            // scroll back to the top exactly as switching collections does.
            collectionID: searchID,
            displayScale: displayScale,
            thumbnailURL: { model.thumbnailURL(for: $0) },
            blobURL: { model.blobURL(for: $0) },
            selectionStore: selectionStore,
            onOpenDetail: { id in
                guard let row = contents.items.first(where: { $0.item.id == id }) else { return }
                model.recordView(assetID: row.asset.id)
                detail = AssetDetail(asset: row.asset, source: row.source)
            },
            // ⌫ is a no-op — see the file header.
            onRequestRemove: {},
            onRequestDelete: { requestDeleteTargets() },
            // Membership-less (019 · C1): the copy's private payload carries the
            // nil-source sentinel, so a ⌘V anywhere reads as an add.
            onCopy: {
                model.copySelectedToPasteboard(
                    from: contents.items,
                    selection: contents.itemIDsForAction(selectionStore.selection.ids),
                    sourceCollectionID: AssetDragPayload.nilSourceID)
            },
            onQuickLook: {},
            onZoomIn: { gridPrefs.zoomIn(forWidth: gridWidth) },
            onZoomOut: { gridPrefs.zoomOut(forWidth: gridWidth) },
            dragPayload: { dragPayload(for: $0) },
            dragImage: { _ in nil },
            // 057: a saved search has no manual order.
            canReorder: false,
            onReorderCommit: { _, _ in false },
            actionTargets: { contents.actionTargets(forCellItemID: $0) },
            // The whole collection hierarchy as ADD destinations — the same nested
            // tree the collection and search grids offer. Nothing is greyed: a hit
            // belongs to no collection here, so every destination is a legitimate
            // add. Smart collections are not in this tree and cannot be: it is built
            // from `folders`, which holds `Collection` rows only.
            destinationTree: destinationTree,
            destinationUnsortedID: model.unsortedFolderID,
            onMoveToCollection: { _, _ in },   // membership-less: never moves
            onCopyToCollection: { ids, target in model.copyToCollection(assetIDs: ids, to: target) },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { ids in model.requestDelete(assetIDs: ids) },
            onToggleExpand: { contents.toggleExpansion(forItem: $0) },
            expandedPosts: contents.expandedPosts,
            isDetailPresented: detail != nil,
            menuStyle: .looseAssets,
            onReveal: { id in
                guard let row = contents.items.first(where: { $0.item.id == id }) else { return }
                model.revealInFinder(asset: row.asset)
            },
            // 023 · A3. A smart collection shows only unarchived items (every
            // browsing read hides the shelf), so `E` resolves to Archive and the
            // item leaves on the reload the write publishes.
            onArchiveVerb: {
                let targets = actionTargetsForKey()
                guard !targets.isEmpty else { return }
                Task { await model.toggleArchived(assetIDs: targets) }
            },
            onArchive: { ids in Task { await model.toggleArchived(assetIDs: ids) } })
    }

    // MARK: - Finder-scope target rules

    /// The payload a cell drag carries. The sentinel source marks it
    /// membership-less, so every drop COPIES (adds) rather than moving — there is
    /// no collection to move out of.
    private func dragPayload(for id: UUID) -> AssetDragPayload {
        let ids = contents.actionTargets(forCellItemID: id)
        return AssetDragPayload(
            assetIDs: ids, sourceCollectionID: AssetDragPayload.nilSourceID)
    }

    /// The ids a bare-key verb acts on: the selection while selecting, else the
    /// cursor's lone item — widened to whole posts by the read model.
    private func actionTargetsForKey() -> [UUID] {
        let selection = selectionStore.selection
        if selection.isSelecting { return contents.selectedAssetIDs }
        guard let lead = selection.lead else { return [] }
        return contents.actionTargets(forCellItemID: lead)
    }

    private func requestDeleteTargets() {
        let targets = actionTargetsForKey()
        guard !targets.isEmpty else { return }
        model.requestDelete(assetIDs: targets)
    }
}

// MARK: - The badge, drawn

/// 057's badge as a label — one view, used by the sidebar row and the grid header,
/// so the two cannot describe the same search differently.
struct SmartCollectionBadgeLabel: View {
    let badge: SmartCollectionBadge
    /// Whether to draw the sentence beside the glyph. The sidebar row has no room
    /// and shows it as a tooltip; the header has room and says it out loud.
    var showsSentence = true

    var body: some View {
        Label {
            if showsSentence {
                Text(badge.sentence)
                    .font(Theme.Typography.caption)
            }
        } icon: {
            Image(systemName: badge.symbol)
                .font(.system(size: 11))
        }
        .foregroundStyle(Theme.Colors.warning)
        .help(badge.sentence)
        .accessibilityLabel(badge.sentence)
    }
}
