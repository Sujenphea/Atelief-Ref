//
//  ShelfView.swift
//  AtelierRefs
//
//  023 · A2 — the Archived destination.
//
//  The shelf renders through the SAME AppKit `MasonryGridHost` as the collection
//  and search grids, via the same synthetic membership bridge search uses
//  (`looseItems(for:)`, `item.id == asset.id`). That is the whole point of
//  reusing the host: selection, marquee, arrows, ⌘A, Esc, ⌘±, the native drag
//  image and the layout cache all arrive already built and already tested. A
//  bespoke list for the shelf would be a second grid to keep in step with the
//  first two.
//
//  What the shelf deliberately does NOT do, each of these a decision:
//
//   • **No move, no add-to, no reorder, no cover.** An archive you can file into
//     and rearrange is just another collection. The `.shelf` menu style offers
//     Unarchive and Delete, and that is the complete list.
//   • **No drag out, and no copy out.** Both would add an archived asset to a
//     collection where it would then be INVISIBLE — it is still archived, and
//     every browsing read hides it. A verb whose visible outcome is "nothing
//     appeared to happen" is worse than a verb that isn't offered. The one way
//     off the shelf is Unarchive.
//   • **No search within it.** The pane wraps in `LibrarySearchable` like every
//     other, so the toolbar height doesn't shift between panes, but search never
//     returns archived items (023 · A1). Typing a query leaves the shelf; it
//     does not filter it.
//

import AtelierCore
import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: IngestionModel
    @ObservedObject var nav: NavModel
    @ObservedObject var gridPrefs: GridViewPreferences
    let services: AppServices

    @StateObject private var shelf = ShelfController()
    @StateObject private var selectionStore = GridSelectionStore()
    @Environment(\.displayScale) private var displayScale

    /// The live grid width, for the ⌘± density clamp — the same guard the
    /// collection and search grids apply.
    @State private var gridWidth: CGFloat = 1

    /// The shelf bucketed by originating post (307), so a carousel archived in
    /// one gesture can be picked up in one action here too. Owned by this pane,
    /// like search owns its own: the shelf is its own feed.
    @State private var postGroups = PostGroups()
    /// The shelf as the grid SHOWS it — collapsed to one tile per post when
    /// grouping is on. State rather than computed: this body re-runs on every
    /// selection change and collapsing is O(items).
    @State private var displayItems: [CollectionItemDetail] = []
    /// Bumped whenever ``displayItems`` is rebuilt. It cannot be
    /// `shelf.itemsVersion` alone — flipping the grouping toggle changes the
    /// display list while the shelf is identical, and the masonry layout cache
    /// keys off this integer.
    @State private var displayVersion = 0
    @State private var expandedPosts: Set<UUID> = []

    /// The open item, if any. The shelf reuses the membership-less detail
    /// overlay search uses — an ordered `[AssetDetail]` with no container is
    /// exactly what that page already walks.
    @State private var detail: AssetDetail?
    @State private var detailContexts = LooseDetailContextCache()

    /// The membership-less sentinel scope for the host, as search uses: a
    /// constant keeps the host from resetting scroll between reloads.
    private static let shelfScopeID = AssetDragPayload.nilSourceID

    private var items: [CollectionItemDetail] { looseItems(for: shelf.items) }
    private var orderIDs: [UUID] { displayItems.map { $0.item.id } }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Group {
                    if shelf.items.isEmpty {
                        emptyState
                    } else {
                        grid
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if detail != nil {
                let context = detailContexts.context(
                    results: shelf.items, resultsVersion: shelf.itemsVersion,
                    groupCarousels: gridPrefs.groupCarousels)
                LooseDetailOverlay(
                    services: services, model: model,
                    context: context, current: $detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .task { await shelf.load(services: services) }
        // A sidebar click on the already-selected row means "show me this
        // destination" — which for the shelf means a fresh read.
        .onChange(of: nav.navigationPulse) { _, _ in
            Task { await shelf.load(services: services) }
        }
        // A delete (from here or anywhere) and a ⌘Z restore both bump this. A
        // restored item comes back ARCHIVED (023 · edge case 4), so it belongs
        // on this pane again — which only happens if the pane re-reads.
        .onChange(of: model.contentsVersion) { _, _ in
            Task { await shelf.load(services: services) }
        }
        .onChange(of: shelf.lastError) { _, message in
            if let message { model.lastError = message }
        }
        // Edit ▸ Remove / Delete (022 · D5). `canRemove: false`, as on search:
        // an archived item is in whatever collections it always was, and picking
        // one of them to remove it from on the user's behalf would be a guess.
        // ⌘⌫ still leaves the library, as it does from every surface.
        .focusedSceneValue(\.deleteVerbs, DeleteVerbs(
            removeTitle: "Remove from Collection",
            canRemove: false,
            remove: {},
            destroy: { requestDeleteTargets() }))
    }

    // MARK: - Chrome

    /// The count, styled like every other pane's "N items" subtitle. It says
    /// "archived", not "items", because the number's meaning is the point of the
    /// pane.
    private var header: some View {
        HStack {
            if !shelf.items.isEmpty {
                Text(shelf.items.count == 1 ? "1 archived" : "\(shelf.items.count) archived")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.xs)
    }

    /// Three states, not two. "Nothing archived" is a claim about the library
    /// and must not be made before the shelf has been read — on a slow first
    /// load that would flash a wrong answer, and after a failed read it would be
    /// a lie that reads as data loss.
    @ViewBuilder
    private var emptyState: some View {
        if !shelf.hasLoaded {
            ProgressView()
        } else if shelf.lastError != nil {
            ContentUnavailableView(
                "Couldn't read the shelf",
                systemImage: "exclamationmark.triangle",
                description: Text("Something went wrong loading archived items."))
        } else {
            ContentUnavailableView(
                "Nothing archived",
                systemImage: "archivebox",
                description: Text("Archiving an item hides it everywhere without "
                    + "removing it from any collection. Unarchiving puts it back "
                    + "exactly where it was."))
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
            .onAppear {
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
            }
            .onChange(of: shelf.itemsVersion) { _, _ in
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
                // Unarchiving is how rows LEAVE this pane, so a multi-selection
                // holding ids that are no longer here is the normal case, not
                // the exceptional one.
                selectionStore.prune(to: orderIDs)
            }
            .onChange(of: gridPrefs.groupCarousels) { _, _ in
                rebuildGrouping()
                selectionStore.setOrder(orderIDs)
                selectionStore.prune(to: orderIDs)
            }
    }

    /// The selection bar's one extra. Unarchive earns the slot because it is the
    /// only way off this pane and the reason the pane exists.
    ///
    /// A ``SelectionBarButton`` like every other bar item — it was briefly a bare
    /// `Button("Unarchive")`, which draws the system's bordered push button, accent
    /// bezel and all, inside a capsule whose whole premise is that there is no
    /// coloured accent (079).
    ///
    /// Targets come from ``actionTargetsForKey()``, the SAME answer the bar's
    /// Delete and the `E` key give. Taking `selection.ids` raw would skip the
    /// widening, and a collapsed ⧉4 tile would then unarchive one of its four.
    private var selectionBar: some View {
        let count = selectionStore.selection.ids.count
        return CountSelectionBar(
            count: count,
            onClear: { selectionStore.apply(.clear) },
            onDelete: { requestDeleteTargets() }
        ) {
            SelectionBarButton("tray.and.arrow.up", help: "Unarchive \(count)") {
                unarchive(actionTargetsForKey())
            }
        }
    }

    // MARK: - Feed

    private func rebuildGrouping() {
        let source = items
        postGroups = PostGroups(items: source)
        expandedPosts = expandedPosts.filter { postGroups.memberCount(forItem: $0) > 1 }
        displayItems = gridPrefs.groupCarousels
            ? postGroups.collapsed(source, expanding: expandedPosts)
            : source
        displayVersion &+= 1
    }

    // MARK: - Host configuration

    private var gridConfiguration: GridHostConfiguration {
        GridHostConfiguration(
            items: displayItems,
            itemsVersion: displayVersion,
            postGroups: postGroups,
            density: gridPrefs.density,
            spacing: Theme.Spacing.sm,
            topInset: Theme.Spacing.md,
            collectionID: Self.shelfScopeID,
            displayScale: displayScale,
            thumbnailURL: { model.thumbnailURL(forAsset: $0.asset) },
            blobURL: { model.blobURL(forAsset: $0.asset) },
            selectionStore: selectionStore,
            onOpenDetail: { id in
                if let hit = shelf.items.first(where: { $0.asset.id == id }) {
                    model.recordView(assetID: id)
                    detail = hit
                }
            },
            // ⌫ is a no-op: an archived item is still in whatever collections it
            // always was, and "remove from where you are looking" has no answer
            // on a surface that is not a container (the search precedent).
            onRequestRemove: {},
            onRequestDelete: { requestDeleteTargets() },
            // ⌘C is deliberately inert here — see the file header. A copy out is
            // an add, and an added-but-still-archived item is invisible.
            onCopy: {},
            onQuickLook: {},
            onZoomIn: { gridPrefs.zoomIn(forWidth: gridWidth) },
            onZoomOut: { gridPrefs.zoomOut(forWidth: gridWidth) },
            // No drag out, for the same reason as ⌘C.
            dragPayload: { _ in nil },
            dragImage: { _ in nil },
            canReorder: false,
            onReorderCommit: { _, _ in false },
            actionTargets: { actionTargets(for: $0) },
            // The shelf offers no destination verbs, so the tree it would build
            // them from is empty rather than merely unused.
            destinationTree: [],
            destinationUnsortedID: model.unsortedFolderID,
            onMoveToCollection: { _, _ in },
            onCopyToCollection: { _, _ in },
            onSetCover: { _ in },
            onRemoveFromCollection: { _ in },
            onDelete: { ids in model.requestDelete(assetIDs: ids) },
            onToggleExpand: { toggleExpansion(forItem: $0) },
            expandedPosts: expandedPosts,
            isDetailPresented: detail != nil,
            menuStyle: .shelf,
            onReveal: { id in
                if let hit = shelf.items.first(where: { $0.asset.id == id }) {
                    model.revealInFinder(asset: hit.asset)
                }
            },
            onUnarchive: { ids in unarchive(ids) },
            // `E` on the shelf is the same verb pointing the other way: every
            // row here is archived, so `shelfVerb` resolves to unarchive. One
            // key, both directions, decided by the data rather than by which
            // pane is open (023 · A3).
            onArchiveVerb: {
                let targets = actionTargetsForKey()
                guard !targets.isEmpty else { return }
                unarchive(targets)
            })
    }

    // MARK: - Verbs

    private func unarchive(_ assetIDs: [UUID]) {
        guard !assetIDs.isEmpty else { return }
        Task {
            let changed = await shelf.unarchive(assetIDs, services: services)
            guard changed > 0 else { return }
            // The rows are gone from this pane; a selection pointing at them is
            // stale even though `prune` will also catch it on the reload.
            selectionStore.apply(.clear)
            // Everything else showing these assets was hiding them a moment ago
            // and must now show them: the open collection's grid, the folder
            // counts, and the gallery's covers and fans. Same call an add or a
            // removal makes, for the same reason — memberships did not change,
            // but which of them are VISIBLE did.
            model.reloadAfterMembershipChange()
        }
    }

    /// The ids a bare-key verb acts on: the selection while selecting, else the
    /// cursor's lone item, widened to whole posts.
    private func actionTargetsForKey() -> [UUID] {
        let selection = selectionStore.selection
        let scope: Set<UUID> = selection.isSelecting
            ? selection.ids : Set(selection.lead.map { [$0] } ?? [])
        return Array(widenedForAction(scope))
    }

    /// Delete from the keyboard or the bar — the same targets every other verb
    /// here acts on.
    private func requestDeleteTargets() {
        let targets = actionTargetsForKey()
        guard !targets.isEmpty else { return }
        model.requestDelete(assetIDs: targets)
    }

    private func actionTargets(for id: UUID) -> [UUID] {
        let selection = selectionStore.selection
        let scope: Set<UUID> = (selection.isSelecting && selection.ids.contains(id))
            ? selection.ids : [id]
        return Array(widenedForAction(scope))
    }

    /// Widen ids to whole posts for an action, but only where the grid is HIDING
    /// members (307). The synthetic membership makes `item.id == asset.id`, so
    /// the widened ids are already asset ids.
    private func widenedForAction(_ ids: Set<UUID>) -> Set<UUID> {
        guard gridPrefs.groupCarousels else { return ids }
        var result = Set<UUID>()
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

    private func toggleExpansion(forItem itemID: UUID) {
        let members = postGroups.members(forItem: itemID)
        guard let lead = members.first, members.count > 1 else { return }
        if expandedPosts.contains(lead) {
            expandedPosts.remove(lead)
        } else {
            expandedPosts.insert(lead)
        }
        rebuildGrouping()
        selectionStore.setOrder(orderIDs)
    }
}
