//
//  DropRouter.swift
//  AtelierRefs
//
//  009 · N3 — the ONE pure decision for "what does this drop do?", shared by all
//  three drop surfaces (grid cell = reorder, stack card / rail row = move/copy).
//  Views decode the payload, read the ⌥ modifier, then call ``routeDrop`` and
//  execute the returned ``DropOutcome`` — they never hand-roll accept/reject
//  guards, so the edge cases (from==to, foreign source, empty payload,
//  non-manual reorder, ⌥ both ways) live in ONE unit-tested place (12A).
//

import AppKit
import AtelierCore
import Foundation

/// Where a drop landed — the two structurally different targets.
enum DropTarget: Equatable {
    /// A reorder SLOT in a collection's grid (040): `index` is the insertion
    /// position in the block-removed order, computed by the live preview
    /// (`masonryInsertionSlot`). Only a SAME-collection, manual-sort drop is a
    /// reorder; anything else is refused (cross-collection moves go via the
    /// sidebar rows / "Move to" menus, not by dropping onto the grid).
    case slot(collectionID: UUID, sortMode: SortMode, index: Int)
    /// A collection drop target (a sidebar collection row): a move, or a copy
    /// when ⌥ is held; a `from == to` drop is refused.
    case collection(UUID)
}

/// The resolved effect of a drop. `reorder` carries the dragged ids PLUS the
/// insertion slot (040) — the WYSIWYG commit reproduces exactly the previewed
/// order via `reorderedIDs(ids:movingIDs:insertAt:)`.
nonisolated enum DropOutcome: Equatable {
    /// Refuse the drop (no state change, never a crash).
    case reject
    /// Reorder the dragged block to `insertAt` in the block-removed order.
    case reorder(assetIDs: [UUID], insertAt: Int)
    /// Move the dragged assets out of `from` into `to`.
    case move(assetIDs: [UUID], from: UUID, to: UUID)
    /// Copy (add) the dragged assets into `to`, leaving the source intact.
    case copy(assetIDs: [UUID], to: UUID)
}

/// Decide what `payload` does when dropped on `target`, with `optionDown` = ⌥.
/// Pure — the AppKit modifier read that supplies `optionDown` is isolated in
/// ``ModifierReading`` so this stays trivially testable in both ⌥ states.
func routeDrop(
    _ payload: AssetDragPayload, onto target: DropTarget, optionDown: Bool
) -> DropOutcome {
    guard !payload.assetIDs.isEmpty else { return .reject }
    switch target {
    case let .slot(collectionID, sortMode, index):
        // Reorder is meaningful only within the SAME collection AND only in manual
        // sort (007's rule) — otherwise refuse (the drag has no reorder meaning).
        guard payload.sourceCollectionID == collectionID, sortMode == .manual else {
            return .reject
        }
        return .reorder(assetIDs: payload.assetIDs, insertAt: index)
    case let .collection(targetID):
        guard targetID != payload.sourceCollectionID else { return .reject } // from == to
        // A membership-less drag (the sentinel source — library search results / a
        // Space board) has no collection to move OUT of, so it can only COPY (add).
        // A real source moves by default, copies with ⌥.
        let sourceless = payload.sourceCollectionID == AssetDragPayload.nilSourceID
        return optionDown || sourceless
            ? .copy(assetIDs: payload.assetIDs, to: targetID)
            : .move(assetIDs: payload.assetIDs, from: payload.sourceCollectionID, to: targetID)
    }
}

/// The ⌥ (copy) read at drop time. `dropDestination` doesn't surface modifiers,
/// so we read the global `NSEvent.modifierFlags` — isolated behind this protocol
/// so move-vs-copy routing is unit-testable without AppKit global state. (The UX
/// caveat: a live cursor badge can't fully match AppKit's `NSDraggingDestination`
/// without dropping to AppKit later.)
protocol ModifierReading {
    var isOptionDown: Bool { get }
}

struct LiveModifierReader: ModifierReading {
    var isOptionDown: Bool { NSEvent.modifierFlags.contains(.option) }
}
