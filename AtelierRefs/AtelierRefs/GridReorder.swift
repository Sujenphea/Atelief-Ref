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
    reorderedIDs(ids: ids, movingIDs: [movingID], toIndexOf: targetID)
}

/// Return `ids` with the dragged BLOCK `movingIDs` moved next to `targetID` —
/// the multi-select generalization of the single-item drop (009 · N3). The block
/// is re-gathered in `ids` (feed) order, so a non-contiguous or reverse-picked
/// selection lands as ONE contiguous run in its natural feed order. Insertion is
/// DIRECTIONAL, matching the single-item rule: if the block's first member sat
/// BEFORE the target it lands just AFTER the target, else just BEFORE — so an
/// adjacent drop always moves toward the drop and there is no dead zone.
///
/// Returns `nil` for a no-op: an empty/foreign `movingIDs` (none present in
/// `ids`), a `targetID` absent from `ids`, or a `targetID` that is itself one of
/// the dragged items (dropping the block onto itself). A non-nil result is always
/// a permutation of `ids` with the same count.
func reorderedIDs(ids: [UUID], movingIDs: [UUID], toIndexOf targetID: UUID) -> [UUID]? {
    let movingSet = Set(movingIDs)
    guard !movingSet.isEmpty, !movingSet.contains(targetID),
          let targetOriginalIndex = ids.firstIndex(of: targetID) else { return nil }
    // The block in feed order, dropping any foreign ids not in this folder.
    let block = ids.filter { movingSet.contains($0) }
    guard let firstBlockOriginalIndex = block.first.flatMap({ ids.firstIndex(of: $0) })
    else { return nil }
    let remaining = ids.filter { !movingSet.contains($0) }
    guard let targetNewIndex = remaining.firstIndex(of: targetID) else { return nil }
    let insertAt = firstBlockOriginalIndex < targetOriginalIndex
        ? targetNewIndex + 1   // forward: land just after the target
        : targetNewIndex       // backward: land just before the target
    var result = remaining
    result.insert(contentsOf: block, at: insertAt)
    return result
}

/// Build an asset-id → item dictionary that degrades on duplicate ids (keeps the
/// first) instead of trapping via `Dictionary(uniqueKeysWithValues:)`.
func keyedByAssetID<Item>(_ items: [Item], id: (Item) -> UUID) -> [UUID: Item] {
    Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
}
