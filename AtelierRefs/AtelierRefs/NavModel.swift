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
    @Published var path: [AppRoute] = []

    /// The membership id of the item shown in the full-window detail overlay, or
    /// `nil`. Reserved for 006; the collection screen keeps a local flag until
    /// then, but the field exists so the wiring is ready.
    @Published var presentedItemID: UUID?

    /// UserDefaults key for the last-opened collection (nav restore, 004 Q3 —
    /// "restore last collection only").
    private static let lastCollectionKey = "AtelierLastCollectionID"

    /// Whether the one-shot relaunch restore has already run (so a later folder
    /// refresh can't re-push the restored collection over the user's navigation).
    private var didRestore = false

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

    /// Reopen the last-viewed collection ONCE, after the folder list first
    /// loads, if that collection still exists (restore last collection only).
    /// Spaces / detail overlays deliberately start closed.
    func restoreIfNeeded(using collections: [Collection]) {
        guard !didRestore, path.isEmpty else { return }
        // Wait until folders have actually loaded before deciding.
        guard !collections.isEmpty else { return }
        didRestore = true
        // UI smoke tests launch with a clean, deterministic root (the Collections
        // gallery) rather than whatever collection was last opened.
        guard !ProcessInfo.processInfo.arguments.contains("-uitest-fresh-nav") else { return }
        guard
            let stored = UserDefaults.standard.string(forKey: Self.lastCollectionKey),
            let id = UUID(uuidString: stored),
            collections.contains(where: { $0.id == id })
        else { return }
        path = [.collection(id)]
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
