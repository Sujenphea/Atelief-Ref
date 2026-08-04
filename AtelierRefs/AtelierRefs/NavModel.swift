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
    /// A collection selected in the sidebar tree (the panel shows its grid).
    case collection(UUID)
    /// A space selected in the sidebar's Spaces section.
    case space(UUID)
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

    /// Go back one drill-down step (⌘[). A no-op at a sidebar root.
    func goBack() {
        guard !path.isEmpty else { return }
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
}
