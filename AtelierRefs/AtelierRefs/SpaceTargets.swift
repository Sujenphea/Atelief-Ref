//
//  SpaceTargets.swift
//  AtelierRefs
//
//  043 (spaces) — the ONE definition of "how spaces are ordered" for the UI, the
//  flat-list analog of ``CollectionTargets``. The sidebar spaces outline and the
//  Home Spaces cards both resolve their order here so the rule can't drift (DRY).
//  Pure + SwiftUI/AppKit-free, so the ordering + drop routing are unit-tested
//  directly. Spaces don't nest, so this is a strict subset of the collection
//  machinery: no descendants, no cycle checks, no reparent — only a slot change.
//

import AtelierCore
import Foundation

nonisolated enum SpaceTargets {
    /// The spaces in manual order (043 · 2B): persisted `sortIndex` first, then
    /// `(createdAt DESC, id)` as a stable tiebreak — the exact order
    /// `AppServices.listSpaces` returns, so the view and the drop-index math agree.
    static func ordered(_ spaces: [Space]) -> [Space] {
        spaces.sorted(by: byManualOrder)
    }

    /// The shared manual-order comparator: `sortIndex`, then newest-first, then id.
    /// The `createdAt DESC` tie-break reproduces the pre-migration order when
    /// indices are equal (e.g. unmigrated fixtures).
    static func byManualOrder(_ a: Space, _ b: Space) -> Bool {
        if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
        if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// Resolve an `NSOutlineView` drop into a concrete reorder (the flat analog of
    /// ``CollectionTargets/routeOutlineDrop``). A space list is flat, so every drop
    /// is a same-list reorder — there is no nest case.
    ///
    ///   • `childIndex == nil` — append (dropped past the last row / in empty space).
    ///   • `childIndex == i`   — the i-th slot, counting the CURRENT list (which
    ///     still includes the dragged space).
    ///
    /// Returns `.reject` only when `dragged` isn't in the list. For a reorder the
    /// index is normalized to the service's "position with the dragged item removed"
    /// contract (a drop below the current slot shifts down by one), exactly as the
    /// collection router does.
    static func routeOutlineDrop(
        dragged: UUID, childIndex: Int?, spaces: [Space]
    ) -> SpaceDrop {
        let ids = ordered(spaces).map(\.id)
        guard ids.contains(dragged) else { return .reject }
        guard let childIndex else { return .move(index: nil) }
        var index = max(childIndex, 0)
        if let current = ids.firstIndex(of: dragged), childIndex > current {
            index -= 1
        }
        return .move(index: index)
    }
}
