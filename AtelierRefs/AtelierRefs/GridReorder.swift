//
//  GridReorder.swift
//  AtelierRefs
//
//  Pure, testable index math for drag-to-reorder of the Library grid. The grid
//  is a flat ordered list of the folder's asset ids; a drag re-inserts the
//  dragged block at an insertion SLOT chosen by the live preview (040 —
//  `masonryInsertionSlot`), and the commit reproduces exactly what was shown.
//  Kept free of SwiftUI so the reorder math can be unit-tested directly (mirrors
//  `GridNavigation.swift`).
//

import Foundation

/// Return `ids` with the dragged BLOCK `movingIDs` re-inserted at `slot` of the
/// block-removed order — the WYSIWYG commit for the live reorder preview (040):
/// the slot arrives from `masonryInsertionSlot`, so the persisted order is
/// exactly the previewed arrangement. The block is gathered in `ids` (feed)
/// order, foreign ids are dropped, and `slot` clamps to `0...remaining.count` —
/// the same gather rule as `previewDisplayOrder`, so preview and commit can
/// never disagree.
///
/// Returns `nil` when NO member of `movingIDs` is present in `ids` (an empty or
/// wholly-foreign block). A non-nil result is always a permutation of `ids`
/// with the same count — the identity when the block lands back at its own slot
/// (a valid drop, unlike the onto-a-cell rule's self-drop nil).
func reorderedIDs(ids: [UUID], movingIDs: [UUID], insertAt slot: Int) -> [UUID]? {
    let movingSet = Set(movingIDs)
    let block = ids.filter { movingSet.contains($0) }
    guard !block.isEmpty else { return nil }
    var result = ids.filter { !movingSet.contains($0) }
    result.insert(contentsOf: block, at: min(max(0, slot), result.count))
    return result
}

/// Build an asset-id → item dictionary that degrades on duplicate ids (keeps the
/// first) instead of trapping via `Dictionary(uniqueKeysWithValues:)`.
func keyedByAssetID<Item>(_ items: [Item], id: (Item) -> UUID) -> [UUID: Item] {
    Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
}
