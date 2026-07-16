//
//  JumpSelection.swift
//  AtelierRefs
//
//  011-B4 · 12A — the pure post-load selection a "Saved — Jump" toast applies. The
//  Jump is deterministic, NOT a timing hack: the target's asset ids are stashed
//  as a pending selection, and this builds the `GridSelection` once the collection
//  finishes loading (against the freshly loaded items). Pure so the mapping is
//  unit-tested without a database or a running load.
//

import AtelierCore
import Foundation

/// The selection to apply after a Jump loads `items`: every membership whose
/// asset is in `assetIDs`, with the lead/anchor pinned to the FIRST such item in
/// feed order (so the detail cursor lands on the earliest arrival). Assets no
/// longer present are naturally dropped; an all-missing set yields an empty
/// (idle) selection — the graceful stale-target no-op.
func jumpSelection(in items: [CollectionItemDetail], assetIDs: Set<UUID>) -> GridSelection {
    let picked = items.filter { assetIDs.contains($0.asset.id) }
    guard let first = picked.first else { return GridSelection() }
    var selection = GridSelection()
    selection.ids = Set(picked.map { $0.item.id })
    selection.anchor = first.item.id
    selection.lead = first.item.id
    return selection
}
