//
//  CollectionTargets.swift
//  AtelierRefs
//
//  009 · N2/N5/N6 — the ONE definition of "how collections are ordered" for the
//  UI. The Collections gallery (Unsorted-pinned roots), the batch Move to ▸ /
//  Add to ▸ menus, and the sidebar rows all resolve their list here so the
//  ordering rules can never drift apart (DRY). Pure + SwiftUI-free, so the split
//  and ordering are unit-tested directly.
//

import AtelierCore
import Foundation

nonisolated enum CollectionTargets {
    /// The root collections ordered for the home gallery (004-P2): the protected
    /// Unsorted folder pinned FIRST, then the rest by `(name, id)` — a stable,
    /// deterministic order (id breaks a duplicate-name tie).
    static func galleryRoots(_ folders: [Collection], unsortedID: UUID) -> [Collection] {
        let roots = folders.filter { $0.parentCollectionID == nil }
        let unsorted = roots.filter { $0.id == unsortedID }
        let rest = roots
            .filter { $0.id != unsortedID }
            // Manual order (043 · 2B): persisted `sortIndex`, tie-broken by
            // `(name, id)` so equal indices (unmigrated fixtures) stay stable.
            .sorted { byManualOrder($0, $1) }
        return unsorted + rest
    }

    /// The shared sibling-order comparator (043 · 2B): persisted `sortIndex`
    /// first, then `(name, id)` as a stable tiebreak. Used wherever one sibling
    /// group is displayed in manual order (gallery roots, a collection's
    /// subfolders); the flat cross-tree `folderMoveTargets` list stays alphabetical
    /// because `sortIndex` is only meaningful within a single parent.
    static func byManualOrder(_ a: Collection, _ b: Collection) -> Bool {
        (a.sortIndex, a.name, a.id.uuidString) < (b.sortIndex, b.name, b.id.uuidString)
    }

    /// The WHOLE collection hierarchy as a RECURSIVE tree — **the one destination
    /// ordering** (027 · G2 / 026 · I1). Roots in gallery order (Unsorted pinned
    /// first, then manual `sortIndex`), each parent's children in manual order.
    /// Every collection is present, nested ones included: the collection currently
    /// on screen is **not filtered out** — the renderers grey it (filing where the
    /// items already live is a no-op), so the list reads as the complete tree,
    /// which is what makes it navigable.
    ///
    /// This is the single source both destination renderers derive from — the
    /// SwiftUI ``CollectionDestinationList`` (via ``moveTargetTree``, a flatten of
    /// this) and the AppKit nested ``CollectionDestinationMenu``. A parallel
    /// implementation on either side is the bug 027 §A was filed for: the grid's
    /// old `moveTargets` computed a *narrower* answer (direct subfolders + roots),
    /// so anything two levels down was unreachable by right-click at any depth.
    ///
    /// Cycle-safe: a corrupt `parentCollectionID` loop can't recurse forever
    /// because a node already on the current path is dropped (mirroring
    /// ``descendantIDs``'s `visited` guard).
    static func destinationTree(
        folders: [Collection], unsortedID: UUID
    ) -> [DestinationTreeNode] {
        let childrenByParent = Dictionary(grouping: folders, by: { $0.parentCollectionID })
        func build(_ siblings: [Collection], onPath: Set<UUID>) -> [DestinationTreeNode] {
            siblings.map { c in
                var path = onPath
                path.insert(c.id)
                let children = (childrenByParent[c.id] ?? [])
                    .filter { !path.contains($0.id) }
                    .sorted(by: byManualOrder)
                return DestinationTreeNode(
                    collection: c, children: build(children, onPath: path))
            }
        }
        return build(galleryRoots(folders, unsortedID: unsortedID), onPath: [])
    }

    /// ``destinationTree`` FLATTENED with a depth per row, for the SwiftUI
    /// destination list's indentation (the selection bar's Move to / Add to, and
    /// the item-detail page's add chip). Pre-order, so a parent is immediately
    /// followed by its subtree — the same sequence the nested menu walks.
    static func moveTargetTree(
        folders: [Collection], unsortedID: UUID
    ) -> [MoveTargetNode] {
        flatten(destinationTree(folders: folders, unsortedID: unsortedID))
    }

    /// Pre-order flatten of a destination tree into indented rows.
    static func flatten(_ tree: [DestinationTreeNode], depth: Int = 0) -> [MoveTargetNode] {
        tree.flatMap { node in
            [MoveTargetNode(collection: node.collection, depth: depth)]
                + flatten(node.children, depth: depth + 1)
        }
    }

    /// The collections `folderID` may be REPARENTED under (043). A valid new
    /// parent is any collection EXCEPT: `folderID` itself, any of its descendants
    /// (that would form a cycle — the service's `moveCollection` rejects it too),
    /// its CURRENT parent (moving there is a no-op), and the protected Unsorted
    /// root (you un-nest to top level via the separate "(Top Level)" action, and
    /// Unsorted is not a user-facing folder to file things under). Ordered by
    /// `(name, id)` for a stable menu. Pure — unit-tested directly.
    static func folderMoveTargets(
        for folderID: UUID, folders: [Collection], unsortedID: UUID
    ) -> [Collection] {
        let currentParent = folders.first { $0.id == folderID }?.parentCollectionID
        var blocked = descendantIDs(of: folderID, in: folders)
        blocked.insert(folderID)
        blocked.insert(unsortedID)
        if let currentParent { blocked.insert(currentParent) }
        return folders
            .filter { !blocked.contains($0.id) }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// A collection's siblings (children of `parent`, `nil` = roots) in manual
    /// order — `sortIndex`, tie-broken by `(name, id)`. The order the outline view
    /// renders and the drop router indexes against.
    static func orderedChildren(of parent: UUID?, in folders: [Collection]) -> [Collection] {
        folders.filter { $0.parentCollectionID == parent }.sorted(by: byManualOrder)
    }

    /// Resolve an `NSOutlineView` drop into a concrete move (043 · Phase C · 12A).
    /// Pure + AppKit-free so the drag brain is unit-tested without a live view.
    ///
    /// The coordinator translates the AppKit drop into these terms:
    ///   • `childIndex == nil` — dropped ON the `proposedParent` row: NEST the
    ///     dragged folder into it and append (`NSOutlineViewDropOnItemIndex`).
    ///   • `childIndex == i` — dropped BETWEEN rows, as the i-th child of
    ///     `proposedParent` (`nil` = the root group). `i` counts positions in the
    ///     parent's CURRENT child list, which INCLUDES the dragged folder when it
    ///     is already a child there.
    ///
    /// Returns `.reject` when the move is structurally invalid (via
    /// ``canReparent(_:into:folders:unsortedID:)``), else a `.move(toParent:index:)`
    /// that feeds straight into `moveCollection` — both a reparent and a
    /// same-parent reorder are the same op. For a same-parent reorder the index is
    /// normalized to the service's "position with the dragged item removed"
    /// contract (drop below the current slot shifts down by one).
    static func routeOutlineDrop(
        dragged: UUID, into proposedParent: UUID?, childIndex: Int?,
        folders: [Collection], unsortedID: UUID
    ) -> CollectionDrop {
        guard canReparent(dragged, into: proposedParent, folders: folders, unsortedID: unsortedID)
        else { return .reject }
        // Dropped onto the row itself → nest + append.
        guard let childIndex else { return .move(toParent: proposedParent, index: nil) }
        // Dropped between rows. Normalize only when it's a same-parent reorder:
        // the incoming index counts the dragged item's own slot, but the service
        // indexes the list with it removed.
        let currentParent = folders.first { $0.id == dragged }?.parentCollectionID
        var index = max(childIndex, 0)
        if currentParent == proposedParent {
            let siblings = orderedChildren(of: proposedParent, in: folders).map(\.id)
            if let current = siblings.firstIndex(of: dragged), childIndex > current {
                index -= 1
            }
        }
        return .move(toParent: proposedParent, index: index)
    }

    /// Whether `dragged` may be REPARENTED under `newParent` (043 · 5A) — the ONE
    /// structural gate shared by every drag surface (the sidebar tree, the Home
    /// gallery) so the "valid drop" rule can't drift between them. Validates
    /// STRUCTURE only, not whether the move is a no-op: a same-parent drop is
    /// structurally fine (the drop coordinator treats it as a reorder). A move is
    /// rejected when `dragged` is the protected Unsorted folder (it can't be
    /// moved), when `newParent` is Unsorted (folders aren't filed under it), or
    /// when it would form a cycle (`newParent` is `dragged` itself or one of its
    /// descendants). `newParent == nil` (top level) is always structurally valid.
    /// The service's `moveCollection` re-checks the cycle as the authoritative
    /// backstop; this mirrors it for the live drag cursor.
    static func canReparent(
        _ dragged: UUID, into newParent: UUID?, folders: [Collection], unsortedID: UUID
    ) -> Bool {
        if dragged == unsortedID { return false }
        guard let newParent else { return true }
        if newParent == unsortedID { return false }
        if newParent == dragged { return false }
        return !descendantIDs(of: dragged, in: folders).contains(newParent)
    }

    /// Every descendant id of `folderID` (its subfolders, their subfolders, …),
    /// walked over the flat `folders` list. Cycle-safe via the `visited` set so a
    /// corrupt parent loop can't spin. Excludes `folderID` itself.
    static func descendantIDs(of folderID: UUID, in folders: [Collection]) -> Set<UUID> {
        let childrenByParent = Dictionary(grouping: folders, by: { $0.parentCollectionID })
        var result: Set<UUID> = []
        var stack: [UUID] = [folderID]
        while let id = stack.popLast() {
            for child in childrenByParent[id] ?? [] where !result.contains(child.id) {
                result.insert(child.id)
                stack.append(child.id)
            }
        }
        return result
    }
}

/// One collection in a flattened, indented move/copy destination tree — the
/// collection plus its `depth` (0 = root) so the UI can indent nested folders.
nonisolated struct MoveTargetNode: Equatable, Identifiable {
    var collection: Collection
    var depth: Int
    var id: UUID { collection.id }
}

/// One collection in the RECURSIVE destination hierarchy — the collection plus its
/// ordered children (027 · G2). The nested shape an `NSMenu` needs; the flat
/// ``MoveTargetNode`` list is this tree flattened, so the two renderings can only
/// ever agree.
nonisolated struct DestinationTreeNode: Equatable, Identifiable {
    var collection: Collection
    var children: [DestinationTreeNode]
    var id: UUID { collection.id }
}

/// A tiny memo for a screen's destination hierarchy (012 · CQ 1A). Historically
/// the SwiftUI context menu built EAGERLY for each visible cell, so every cell
/// recomputed the IDENTICAL folder target list on every render (measured
/// ~326ms/pass); the native `NSMenu` now builds on right-click only, but the grid
/// configuration still carries the tree as a value, so one memo per body pass is
/// still what keeps the grouping + sorts off the render path.
///
/// Keyed on `(unsortedID, folders)`. 027 · G2 dropped `from` out of the key: the
/// tree is the same seen from anywhere, because the current collection is now a
/// render-time *disable* rather than a filter — which also means a collection
/// switch no longer invalidates it. Held in plain `@State` (not observed),
/// mirroring ``MasonryLayoutCache``'s discipline.
@MainActor
final class MoveTargetsCache {
    private struct Key: Equatable {
        var unsortedID: UUID
        var folders: [Collection]
    }

    private var key: Key?
    private var value: [DestinationTreeNode] = []
    /// Cache misses since init — read by the perf harness to prove the memo hits
    /// across renders instead of rebuilding per body pass.
    private(set) var buildCount = 0

    /// The memoized destination tree for the given inputs — recomputed only when
    /// `(unsortedID, folders)` changes.
    func destinationTree(folders: [Collection], unsortedID: UUID) -> [DestinationTreeNode] {
        let k = Key(unsortedID: unsortedID, folders: folders)
        if key == k { return value }
        value = CollectionTargets.destinationTree(folders: folders, unsortedID: unsortedID)
        key = k
        buildCount += 1
        return value
    }
}
