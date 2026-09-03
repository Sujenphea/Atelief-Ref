//
//  NavModel.swift
//  AtelierRefs
//
//  004-P1 — the navigation redesign's route state. A small `ObservableObject`
//  holding ONLY route state (the drill-down path + the item-detail overlay id);
//  all data loading stays in `IngestionModel` (the epic deliberately does NOT
//  decompose that view model). The pure route/breadcrumb math is kept
//  SwiftUI-free below so it can be unit-tested directly (the `GridNavigation`
//  pattern).
//

import AtelierCore
import Combine
import Foundation

/// A screen pushed onto the detail panel's WITHIN-collection drill-down stack
/// (006 shell). Top-level destinations now live in ``SidebarItem``; `path` carries
/// only subfolder drill-down (so ⌘[ back still works) and nothing else.
nonisolated enum AppRoute: Hashable {
    /// A deeper collection drilled into from a subfolder chip.
    case collection(UUID)
    /// One open space (freeform board).
    case space(UUID)
}

/// A top-level sidebar destination (006 split-view shell). The sidebar owns this
/// selection; `NavModel.path` is kept only for within-collection drill-down.
///
/// Settings is deliberately NOT a case: it lives in the standard macOS Settings
/// window (⌘, — the `Settings` scene in ``AtelierRefsApp``), which is the app's
/// single settings surface. The sidebar still shows a gear, but it *opens* that
/// window rather than selecting a destination, so there is one settings view with
/// one door. See ``SidebarView``'s `settingsRow`.
nonisolated enum SidebarItem: Hashable {
    case home
    case capture
    /// The archive shelf (023 · A2) — every archived item, newest first. A
    /// top-level destination rather than a collection, because it is not one: it
    /// has no memberships, no order to arrange and nothing to add to it.
    case shelf
    /// A collection selected in the sidebar tree (the panel shows its grid).
    case collection(UUID)
    /// A space selected in the sidebar's Spaces section.
    case space(UUID)
    /// A smart collection — a saved search — selected in the sidebar's Smart
    /// section (099 · P4 / [057](../../.docs/057-smart-collections-overview.md)).
    ///
    /// A top-level destination rather than a row in the collections tree, for the
    /// reason 057 rejected a `type` flag on `collection`: it has no memberships,
    /// no manual order, no nesting and it cannot hold a drop, so putting it in the
    /// tree would invite every collection consumer to grow a discriminator check.
    ///
    /// Safe to add despite the relaunch restore, on ``theme``'s reasoning:
    /// `restoredSelection()` only ever reconstructs `.home` or `.collection(_:)`
    /// from `UserDefaults`, so nothing persists this.
    case savedSearch(UUID)
    #if DEBUG
    /// The design-token specimen pane (``ThemeGalleryView``) — a DEBUG-only
    /// destination, so the sidebar row and the pane both compile out of a release
    /// build rather than shipping a developer tool.
    ///
    /// Safe to add as a case despite the relaunch restore: `restoredSelection()`
    /// only ever reconstructs `.home` or `.collection(_:)` from `UserDefaults`, so
    /// nothing persists this and a release build cannot be asked to decode it.
    case theme
    #endif
}

/// A pending inline-creation request the sidebar consumes, then clears (214). One
/// source of truth for every entry point — the section "+" buttons, the outline
/// row's "New Subfolder…", and the ⌘N command all set this; the sidebar renders the
/// draft row from it. `nil` = no draft in flight.
enum SidebarDraft: Equatable {
    /// A new space (draft row at the end of the Spaces list).
    case space
    /// A new collection — `parent == nil` is a root, else a subfolder of `parent`.
    case collection(parent: UUID?)
}

// MARK: - What a destination can be dropped ON (099 · P4)

extension SidebarItem {
    /// Whether assets may be DROPPED on this destination — the sidebar row, and
    /// the pane behind it.
    ///
    /// Written down as one exhaustive `switch` rather than left implicit in which
    /// views happen to attach an `.onDrop`, because 057 states the rule as a
    /// prohibition ("not drop targets — you can't add to a query") and a
    /// prohibition that lives only in the absence of code is one nobody can assert.
    /// `SmartCollectionExclusionTests` walks every case.
    ///
    /// A collection and a space take drops (both have a membership to write);
    /// Home, Capture, Archived, the theme pane and a smart collection do not. The
    /// shelf's refusal is 023's — "an archive you can file into is just another
    /// collection"; a smart collection's is 057's, and it is stronger: there is no
    /// row a drop could even write.
    var acceptsAssetDrops: Bool {
        switch self {
        case .collection, .space: true
        case .home, .capture, .shelf, .savedSearch: false
        #if DEBUG
        case .theme: false
        #endif
        }
    }
}

/// Route state for the app shell (004-P1). Holds the `NavigationStack` path and
/// the detail-overlay selection; nothing else. `@MainActor` because it drives
/// SwiftUI directly.
@MainActor
final class NavModel: ObservableObject {

    /// The `NavigationStack` drill-down path. Empty = the Collections gallery.
    /// Seeded at construction with the last-opened collection (004 Q3 restore) as
    /// the STARTING value — never pushed at runtime during launch. Pushing the
    /// restore reactively (once folders loaded) mutated the stack mid-launch and
    /// tripped "NavigationRequestObserver tried to update multiple times per frame";
    /// as the initial value there is no launch-time path change at all. Validated
    /// against the real folder list once it loads (`pruneRestoredPathIfMissing`).
    @Published var path: [AppRoute]

    /// The selected top-level sidebar destination — the primary navigation state
    /// (006 shell). Seeded from the relaunch restore (last-opened collection).
    @Published var sidebarSelection: SidebarItem

    /// Whether the sidebar is collapsed to the 60pt icon rail (frames 1:3 / 5:92 /
    /// 6:4 — the rail = the traffic-light footprint). Auto-set true while the
    /// item-detail overlay is up.
    @Published var sidebarCollapsed = false

    /// A pending inline-creation draft (214). Set by the section "+" buttons and the
    /// ⌘N command; the sidebar starts the inline row and clears this back to `nil`.
    @Published var sidebarDraft: SidebarDraft?

    /// Bumped by every sidebar navigation INTENT — including re-selecting the row that
    /// is already selected. The panel's `LibrarySearchable` resets its query on a bump,
    /// so "click a destination" always lands on that destination's CONTENT.
    ///
    /// `sidebarSelection` alone can't express this. Its search model is a `@StateObject`
    /// that survives a same-branch selection change (space→space, collection→collection
    /// are one `switch` arm each), and re-selecting the open row changes no state at all
    /// — so an active search stayed up in both cases with no way back but the field's `×`.
    @Published private(set) var navigationPulse = 0

    /// - Parameters:
    ///   - initialPath: the within-collection drill-down stack; tests pass `[]`.
    ///   - initialSelection: the starting sidebar destination. Defaults to the
    ///     relaunch restore (the last-opened collection, else Home).
    init(
        initialPath: [AppRoute] = [],
        initialSelection: SidebarItem = NavModel.restoredSelection()
    ) {
        self.path = initialPath
        self.sidebarSelection = initialSelection
    }

    /// Whether the Keyboard Shortcuts sheet is up (024 · K2). Route state rather than
    /// a `@State` in the shell, for the same reason `sidebarDraft` is: the thing that
    /// raises it is a menu command, which reaches this object as a focused value and
    /// has no view of its own to hang a sheet on.
    @Published var showShortcuts = false

    /// Whether the ⌘K quick switcher is up (099 · P5). Route state for
    /// ``showShortcuts``' reason and one more of its own: the panel must open from
    /// EVERY surface — the item-detail overlay and a Space board included — and a
    /// `@State` on any pane would go away with that pane. The shell raises the
    /// panel from this; see ``AppShellView``.
    @Published var showSwitcher = false

    /// The membership id of the item shown in the full-window detail overlay, or
    /// `nil`. Reserved for 006; the collection screen keeps a local flag until
    /// then, but the field exists so the wiring is ready.
    @Published var presentedItemID: UUID?

    /// UserDefaults key for the last-opened collection (nav restore, 004 Q3 —
    /// "restore last collection only").
    nonisolated private static let lastCollectionKey = "AtelierLastCollectionID"

    // MARK: - Navigation intents

    /// Select a top-level sidebar destination — resets the within-collection
    /// drill-down `path` so the destination renders as the panel root.
    func selectSidebar(_ item: SidebarItem) {
        // Leaving the pane closes its item detail (355). Home / Capture / a Space are
        // different `switch` arms in the shell, so the collection pane — and with it the
        // overlay's host — UNMOUNTS: none of the host's observers run, and the route was
        // left pointing at an item nothing was showing. That stale id kept the sidebar
        // collapsed, hid the pane's floating +, and told the grid the page still had the
        // keyboard, so on return the grid answered no key until an item was opened and
        // closed. Cleared BEFORE the selection changes, so the host is still mounted to
        // see it and can tear the session down properly.
        presentedItemID = nil
        sidebarSelection = item
        navigationPulse &+= 1
        if !path.isEmpty { path = [] }
        if case .collection(let id) = item {
            UserDefaults.standard.set(id.uuidString, forKey: Self.lastCollectionKey)
        }
    }

    /// Open a collection as a sidebar selection (gallery card tap, capture Jump).
    /// Resets drill-down — distinct from ``drillIntoCollection(_:)``.
    func openCollection(_ id: UUID) { selectSidebar(.collection(id)) }

    /// Drill into a subfolder from a collection screen — a PUSH onto the panel's
    /// within-collection stack (keeps ⌘[ back), not a sidebar selection.
    func drillIntoCollection(_ id: UUID) {
        if path.last != .collection(id) { path.append(.collection(id)) }
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastCollectionKey)
    }

    /// Select an open space in the sidebar's Spaces section.
    func openSpace(_ id: UUID) { selectSidebar(.space(id)) }

    /// Open a smart collection — a sidebar row's click, or a Home card's
    /// (099 · P4). Deliberately NOT persisted as the relaunch destination: the
    /// restore key is `AtelierLastCollectionID` and it reconstructs a
    /// `.collection`, so writing a saved-search id into it would restore the app
    /// onto a collection that does not exist. Landing on Home instead is the
    /// honest answer and costs one click.
    func openSavedSearch(_ id: UUID) { selectSidebar(.savedSearch(id)) }

    // MARK: - The ⌘K switcher (099 · P5)

    /// Commit a quick-switcher choice: close the panel, remember the visit, go.
    ///
    /// **The order is the requirement, not an implementation detail.** ⌘K opens on
    /// top of the full-window item-detail overlay and on top of a Space board, so a
    /// destination committed from there has to POP THE OVERLAY FIRST — otherwise
    /// the route changes underneath an overlay that is still up, and the user is
    /// left looking at a picture from the collection they have just left.
    /// ``selectSidebar(_:)`` already clears ``presentedItemID`` before it assigns
    /// the selection (355), so routing THROUGH it rather than around it is what
    /// keeps that ordering true for this caller too.
    ///
    /// The panel is closed before the navigation, so the keyboard is back on the
    /// shell by the time the destination's pane mounts and can take it — the same
    /// reason ``DestinationPicker`` commits and dismisses through one call site.
    ///
    /// Lives here rather than in ``AppShellView`` so the sequence is a test
    /// (`SwitcherNavigationTests`) and not a paragraph.
    func commitSwitcher(_ destination: SidebarItem, recents: SwitcherRecents) {
        showSwitcher = false
        recents.record(destination)
        selectSidebar(destination)
    }

    /// Go back one drill-down step (⌘[). A no-op at a sidebar root.
    func goBack() {
        guard !path.isEmpty else { return }
        presentedItemID = nil   // as ``selectSidebar(_:)`` — popping unmounts the host
        path.removeLast()
    }

    /// Clear the within-collection drill-down back to the sidebar root.
    func goToRoot() { path.removeAll() }

    // MARK: - Relaunch restore (004 Q3)

    /// The sidebar destination to START at: the last-opened collection, else Home.
    /// UI smoke tests launch at Home (`-uitest-fresh-nav`). Existence is validated
    /// later, once the folder list loads (``reconcile(using:)``).
    nonisolated private static func restoredSelection() -> SidebarItem {
        guard
            !ProcessInfo.processInfo.arguments.contains("-uitest-fresh-nav"),
            let stored = UserDefaults.standard.string(forKey: lastCollectionKey),
            let id = UUID(uuidString: stored)
        else { return .home }
        return .collection(id)
    }

    // MARK: - Route reconcile (043 · 3A)

    /// Reconcile route state against the live collection set — run on every folder
    /// refresh (launch restore-validation, and after a delete removes a subtree).
    /// A drill-down `path` truncates at the first entry whose collection is gone;
    /// a deleted sidebar collection falls back to Home. Non-collection routes
    /// (Home/Search/…/Spaces) are a different domain and left untouched.
    ///
    /// No-op until folders load and no-op when nothing is missing — so the common
    /// case (launch with the restored collection still present) mutates nothing,
    /// and the `NavigationStack` observer stays quiet (004 launch semantics). An
    /// empty list means "not yet loaded" (the DB always has Unsorted), never
    /// "everything was deleted", so it is skipped.
    ///
    /// Falls back to Home rather than the deleted collection's PARENT: delete
    /// removes the whole subtree, so the parent may be gone too, and it is no
    /// longer in `collections` to consult. Home is the one always-valid target.
    func reconcile(using collections: [Collection]) {
        guard !collections.isEmpty else { return }
        let ids = Set(collections.map(\.id))
        let result = Self.reconciled(selection: sidebarSelection, path: path, existing: ids)
        // A route that moves because a collection was DELETED unmounts the pane exactly
        // as a navigation does, and reaches here instead of `selectSidebar` — so it owes
        // the same cleanup (355). Guarded, because this runs on every folder refresh and
        // must not clear a live page when nothing moved.
        if result.path != path || result.selection != sidebarSelection {
            presentedItemID = nil
        }
        if result.path != path { path = result.path }
        if result.selection != sidebarSelection { sidebarSelection = result.selection }
    }

    /// The pure core of ``reconcile(using:)`` — kept SwiftUI-free so the
    /// truncate/fallback math is unit-tested directly (the `GridNavigation`
    /// pattern). `existing` is the set of live collection ids.
    nonisolated static func reconciled(
        selection: SidebarItem,
        path: [AppRoute],
        existing ids: Set<UUID>
    ) -> (selection: SidebarItem, path: [AppRoute]) {
        // Truncate the drill-down at the first missing collection: anything deeper
        // was reached THROUGH it, so those routes are invalid once it is gone.
        var newPath = path
        if let cut = path.firstIndex(where: {
            if case .collection(let id) = $0 { return !ids.contains(id) }
            return false
        }) {
            newPath = Array(path[..<cut])
        }
        // Fall a deleted sidebar collection back to Home.
        var newSelection = selection
        if case .collection(let id) = selection, !ids.contains(id) {
            newSelection = .home
        }
        return (newSelection, newPath)
    }

    // MARK: - Smart-collection reconcile (099 · P4)

    /// Reconcile the route against the live saved-search set — run on every
    /// saved-search refresh, so deleting the smart collection you are looking at
    /// does not leave the panel on a query that no longer exists.
    ///
    /// A SEPARATE entry point from ``reconcile(using:)`` rather than a third
    /// argument to it, because the two run at different moments off different
    /// publishers: the folder tree refreshes on every write through
    /// `publishChange`, the saved-search list only when a saved-search verb ran.
    /// Folding them together would mean either reconciling saved searches against
    /// a list nobody had loaded, or reloading that list on every asset move.
    ///
    /// `hasLoaded` is the guard ``reconcile(using:)`` has to APPROXIMATE with
    /// `!collections.isEmpty` — the database always has Unsorted, so a non-empty
    /// folder list means "loaded". A saved-search list has no such floor: zero is a
    /// perfectly ordinary answer, and it is exactly the answer produced by deleting
    /// the last smart collection while looking at it. So the model states outright
    /// whether its list is an answer, and this reads it rather than guessing.
    func reconcileSavedSearches(using searches: [SavedSearch], hasLoaded: Bool) {
        guard hasLoaded,
              case .savedSearch(let id) = sidebarSelection,
              !searches.contains(where: { $0.id == id })
        else { return }
        fallBackFromSavedSearch()
    }

    /// Leave a smart-collection route for Home — the deleted-row fallback, and the
    /// one path that also handles "the last one was deleted".
    ///
    /// Home rather than the previous destination: there is no back stack for a
    /// sidebar selection (`path` is within-collection drill-down only), and Home
    /// is the one always-valid target — the same answer
    /// ``reconciled(selection:path:existing:)`` gives a deleted collection.
    func fallBackFromSavedSearch() {
        guard case .savedSearch = sidebarSelection else { return }
        // Same cleanup a delete-driven route change owes anywhere else (355): the
        // pane unmounts, so its detail overlay's host goes with it.
        presentedItemID = nil
        sidebarSelection = .home
        navigationPulse &+= 1
        if !path.isEmpty { path = [] }
    }
}
