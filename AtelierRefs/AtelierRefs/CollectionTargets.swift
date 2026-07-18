//
//  CollectionTargets.swift
//  AtelierRefs
//
//  009 · N2/N5/N6 — the ONE definition of "how collections are ordered" for the
//  UI. The Collections gallery (Unsorted-pinned roots), the batch Move to ▸ /
//  Add to ▸ menus, and the floating drop rail all resolve their list here so the
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
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        return unsorted + rest
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
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
        let roots = galleryRoots(folders, unsortedID: unsortedID)
            .filter { $0.id != currentID }
        return MoveTargets(subfolders: subfolders, roots: roots)
    }
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
/// ~326ms/pass). Keyed on `(from, unsortedID, folders)`: the drop rail plus each
/// cell menu in a render share one computation, and the list also survives across
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
