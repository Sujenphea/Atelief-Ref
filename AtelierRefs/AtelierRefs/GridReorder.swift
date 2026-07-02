//
//  GridReorder.swift
//  AtelierRefs
//
//  Pure, testable index math for drag-to-reorder of the Library grid. The grid
//  is a flat ordered list of the folder's asset ids; dropping one thumbnail onto
//  another moves the dragged id to the target's slot. Kept free of SwiftUI so the
//  reorder math can be unit-tested directly (mirrors `GridNavigation.swift`).
//

import Foundation

/// Return `ids` with `movingID` moved next to `targetID` — drop-onto-cell
/// semantics with DIRECTIONAL insertion so adjacent drops swap and there is no
/// dead zone: dragging forward (source before target) the dragged id lands just
/// AFTER the target; dragging backward (source after target) it lands just
/// BEFORE. Either way it takes the slot on the side facing its travel.
///
/// Returns `nil` for a no-op: `movingID == targetID`, or either id is absent from
/// `ids` (e.g. a foreign drop whose payload isn't one of this folder's items). A
/// non-nil result is always a permutation of `ids` with the same count.
func reorderedIDs(ids: [UUID], movingID: UUID, toIndexOf targetID: UUID) -> [UUID]? {
    guard movingID != targetID,
          let fromIndex = ids.firstIndex(of: movingID),
          let toIndex = ids.firstIndex(of: targetID) else { return nil }
    var result = ids
    result.remove(at: fromIndex)
    // Forward: after removal the target sits at `toIndex - 1`, so inserting at
    // `toIndex` drops the item just after it. Backward: the target is unmoved at
    // `toIndex`, so inserting there drops the item just before it.
    result.insert(movingID, at: toIndex)
    return result
}
