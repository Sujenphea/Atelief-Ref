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
enum AppRoute: Hashable {
    /// A deeper collection drilled into from a subfolder chip.
    case collection(UUID)
    /// The list of spaces (legacy route; retained for compatibility).
    case spaces
    /// One open space (freeform board).
    case space(UUID)
}

/// A top-level sidebar destination (006 split-view shell). The sidebar owns this
/// selection; `NavModel.path` is kept only for within-collection drill-down.
enum SidebarItem: Hashable {
    case home
    case search
    case capture
    case settings
    /// A collection selected in the sidebar tree (the panel shows its grid).
    case collection(UUID)
    /// A space selected in the sidebar's Spaces section.
    case space(UUID)
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

    /// Whether the one-shot restore VALIDATION has run (so a later folder refresh
    /// doesn't keep re-checking the seeded collection).
    private var didValidateRestore = false

    // MARK: - Navigation intents

    /// Select a top-level sidebar destination — resets the within-collection
    /// drill-down `path` so the destination renders as the panel root.
    func selectSidebar(_ item: SidebarItem) {
        sidebarSelection = item
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
    /// later, once the folder list loads (`pruneRestoredPathIfMissing`).
    nonisolated private static func restoredSelection() -> SidebarItem {
        guard
            !ProcessInfo.processInfo.arguments.contains("-uitest-fresh-nav"),
            let stored = UserDefaults.standard.string(forKey: lastCollectionKey),
            let id = UUID(uuidString: stored)
        else { return .home }
        return .collection(id)
    }

    /// Fall back to Home if the restored sidebar collection no longer exists, once
    /// the folder list has loaded. Runs at most once; a no-op for the common case.
    /// (Name kept for the `ContentView` call site.)
    func pruneRestoredPathIfMissing(using collections: [Collection]) {
        guard !didValidateRestore, !collections.isEmpty else { return }
        didValidateRestore = true
        guard case .collection(let id) = sidebarSelection else { return }
        if !collections.contains(where: { $0.id == id }) { sidebarSelection = .home }
    }
}

// MARK: - Pure breadcrumb helper (SwiftUI-free, unit-testable)

/// The root→leaf ancestor chain of `collectionID` within the flat `collections`
/// list (004-P1 breadcrumb). Walks UP via `parentCollectionID` collecting each
/// ancestor, then reverses to root-first. **Cycle-safe**: a already-visited id
/// terminates the walk (a corrupt parent cycle can't hang the UI), mirroring
/// `FolderNode.tree`'s defensive posture. Returns `[]` if `collectionID` isn't
/// in the list.
func collectionBreadcrumb(for collectionID: UUID, in collections: [Collection]) -> [Collection] {
    let byID = Dictionary(collections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard var current = byID[collectionID] else { return [] }
    var chain: [Collection] = [current]
    var visited: Set<UUID> = [current.id]
    while let parentID = current.parentCollectionID, let parent = byID[parentID] {
        if !visited.insert(parent.id).inserted { break } // cycle guard
        chain.append(parent)
        current = parent
    }
    return chain.reversed()
}
