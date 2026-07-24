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

enum CollectionTargets {
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

    /// The move/copy targets reachable FROM `currentID` (009 · N5/N6): the
    /// current collection's DIRECT subfolders first (name,id), then every ROOT
    /// (Unsorted included — dragging back to Unsorted is legitimate un-triage).
    /// The current collection itself is excluded from BOTH groups — moving into
    /// where the items already live is a `from == to` no-op, so it is never
    /// offered as a target (and the rail's quick-switch has no use for it either).
    static func moveTargets(
        from currentID: UUID, folders: [Collection], unsortedID: UUID
    ) -> MoveTargets {
        let subfolders = folders
            .filter { $0.parentCollectionID == currentID }
            .sorted { byManualOrder($0, $1) }
        let roots = galleryRoots(folders, unsortedID: unsortedID)
            .filter { $0.id != currentID }
        return MoveTargets(subfolders: subfolders, roots: roots)
    }

    /// The WHOLE collection hierarchy flattened for the selection bar's Move to /
    /// Add to lists — every collection as an indented node (roots in gallery order:
    /// Unsorted first, then manual; children in manual order), so items can be filed
    /// into ANY collection, nested included. The collection currently on screen is
    /// included too (the caller greys it out and disables it — filing where the
    /// items already live is a no-op), so the list reads as the complete tree.
    static func moveTargetTree(
        folders: [Collection], unsortedID: UUID
    ) -> [MoveTargetNode] {
        let childrenByParent = Dictionary(grouping: folders, by: { $0.parentCollectionID })
        var out: [MoveTargetNode] = []
        func walk(_ siblings: [Collection], depth: Int) {
            for c in siblings {
                out.append(MoveTargetNode(collection: c, depth: depth))
                walk((childrenByParent[c.id] ?? []).sorted(by: byManualOrder),
                     depth: depth + 1)
            }
        }
        walk(galleryRoots(folders, unsortedID: unsortedID), depth: 0)
        return out
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
struct MoveTargetNode: Equatable, Identifiable {
    var collection: Collection
    var depth: Int
    var id: UUID { collection.id }
}

/// The two ordered groups of a move/copy target list, kept separate so the UI can
/// render a divider between subfolders and roots. `Equatable` for cheap view
/// diffing.
struct MoveTargets: Equatable {
    /// The current collection's direct subfolders (name,id order).
    var subfolders: [Collection]
    /// The root collections (Unsorted first), current excluded.
    var roots: [Collection]

    /// Subfolders then roots — the flat menu/rail order.
    var all: [Collection] { subfolders + roots }
    /// No reachable target at all (a lone root with no subfolders would still
    /// list the OTHER roots; this is only true in a degenerate one-collection
    /// library).
    var isEmpty: Bool { subfolders.isEmpty && roots.isEmpty }
}

/// A tiny memo for a collection screen's move/copy targets (012 · CQ 1A). The
/// context menu builds EAGERLY for each visible cell, so without this every cell
/// recomputes the IDENTICAL folder target list on every render (measured
/// ~326ms/pass). Keyed on `(from, unsortedID, folders)`: each cell menu in a
/// render shares one computation, and the list also survives across
/// renders while the folder tree is unchanged. Held in plain `@State` (not
/// observed), mirroring ``MasonryLayoutCache``'s discipline.
@MainActor
final class MoveTargetsCache {
    private struct Key: Equatable {
        var from: UUID
        var unsortedID: UUID
        var folders: [Collection]
    }

    private var key: Key?
    private var value = MoveTargets(subfolders: [], roots: [])

    /// The memoized targets for the given inputs — recomputed only when one of
    /// `(from, unsortedID, folders)` changes.
    func targets(from: UUID, folders: [Collection], unsortedID: UUID) -> MoveTargets {
        let k = Key(from: from, unsortedID: unsortedID, folders: folders)
        if key == k { return value }
        value = CollectionTargets.moveTargets(
            from: from, folders: folders, unsortedID: unsortedID)
        key = k
        return value
    }
}
