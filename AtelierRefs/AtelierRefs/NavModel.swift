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

/// A screen in the top-bar navigation. The gallery of collections is the
/// UNPUSHED root, so it has no case here; everything else is a pushed route.
enum AppRoute: Hashable {
    /// One collection's items (drill-down from the gallery or a subfolder chip).
    case collection(UUID)
    /// The list of spaces.
    case spaces
    /// One open space (freeform board).
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

    /// - Parameter initialPath: the starting nav path. Defaults to the relaunch
    ///   restore (the last-opened collection); tests pass `[]` for a clean root.
    init(initialPath: [AppRoute] = NavModel.restoredInitialPath()) {
        self.path = initialPath
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

    /// Push a collection screen (drill-down). A no-op if it's already on top.
    func openCollection(_ id: UUID) {
        if path.last != .collection(id) { path.append(.collection(id)) }
        UserDefaults.standard.set(id.uuidString, forKey: Self.lastCollectionKey)
    }

    /// Push the spaces list (idempotent if already on top).
    func openSpaces() {
        if path.last != .spaces { path.append(.spaces) }
    }

    /// Push an open space (idempotent if already on top).
    func openSpace(_ id: UUID) {
        if path.last != .space(id) { path.append(.space(id)) }
    }

    /// Go back one screen (⌘[ / toolbar back). A no-op at the root gallery.
    func goBack() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Return to the Collections gallery.
    func goToRoot() { path.removeAll() }

    // MARK: - Relaunch restore (004 Q3)

    /// The nav path to START at: the last-opened collection, seeded as the initial
    /// value so relaunch shows it WITHOUT a runtime push during launch. UI smoke
    /// tests launch at a clean gallery root. Existence is validated later, once the
    /// folder list loads (`pruneRestoredPathIfMissing`) — at construction we can't
    /// yet know whether the collection survives.
    nonisolated private static func restoredInitialPath() -> [AppRoute] {
        guard
            !ProcessInfo.processInfo.arguments.contains("-uitest-fresh-nav"),
            let stored = UserDefaults.standard.string(forKey: lastCollectionKey),
            let id = UUID(uuidString: stored)
        else { return [] }
        return [.collection(id)]
    }

    /// Clear a seeded restore whose collection no longer exists, once the folder
    /// list has loaded. Runs at most once; a no-op for the common case (the
    /// collection still exists) and whenever the user has already navigated away —
    /// so the common launch performs NO path mutation, which is the whole point.
    func pruneRestoredPathIfMissing(using collections: [Collection]) {
        guard !didValidateRestore, !collections.isEmpty else { return }
        didValidateRestore = true
        guard path.count == 1, case .collection(let id)? = path.first else { return }
        if !collections.contains(where: { $0.id == id }) { path = [] }
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
