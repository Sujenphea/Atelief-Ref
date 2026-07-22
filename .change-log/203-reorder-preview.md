# 203 — Live reorder drop preview (040, complete) + AssetDragPayload test de-flake

## Summary

The masonry grid's manual reorder is now **WYSIWYG**: while an eligible
same-collection drag hovers the grid, the cells slide aside to show the order
that WOULD result from dropping there — the dragged block dimmed as a "ghost" at
its previewed slot — and the drop commits exactly what is shown, with no jump on
release. Implements `.docs/040-reorder-preview-plan.md` end to end (steps 1–6).

This replaces the old "drop onto a cell with an invisible before/after rule",
whose result was unpredictable on a round-robin masonry (one insertion reshuffled
the whole tail; feed-adjacency ≠ visual-adjacency at column boundaries; the
reflow teleported). It also fixes the cursor lying: a non-manual sort now shows
NO preview and reports "no drop" instead of a `.move` that was then refused.

## What changed

**Pure math (`MasonryReorderPreview.swift`, new; `GridReorder.swift`)**
- `previewDisplayOrder(count:blockIndices:slot:)` — the block-at-slot display
  permutation (block gathered in feed order, slot clamped).
- `previewFrames(...)` — solves the masonry over the permuted arrangement and
  maps frames back to DATA order; cell sizes ride their cells, so a preview never
  re-buckets or re-decodes a thumbnail.
- `masonryInsertionSlot(...)` — pointer → slot: before/after by pointer vs cell
  midX, ghost-hit stability (hovering the block never oscillates), nearest-cell
  fallback for gaps / below content / top inset.
- `masonryShouldReslot(...)` + `masonryReslotHysteresis` (8 pt) — the jitter
  guard.
- `reorderedIDs(ids:movingIDs:insertAt:)` — the WYSIWYG commit; shares the gather
  rule with `previewDisplayOrder`, so preview and commit can never disagree (a
  test cross-checks every slot). The old directional `toIndexOf` variants are
  DELETED (the grid was their only caller — DRY).

**Layout (`MasonryCollectionLayout.swift`)**
- `preview: MasonryPreviewFrames?` renders in place of the real solve when set;
  every geometry accessor rides it, guarded on a matching item count (a stale
  preview across a reload is ignored).
- Preview frames sit at PERMUTED positions, breaking the round-robin column
  structure the marquee rect query culls by — so `layoutAttributesForElements`
  and `hitTestIndex` fall back to a plain intersection scan while a preview is
  active (O(N), drag-only). Width-only invalidation is unchanged.

**Coordinator (`MasonryGridHost.swift`)**
- `draggingEntered`/`draggingUpdated` gate eligibility (same collection + manual
  sort + the block resolves to current rows), compute the slot (hysteresis),
  re-solve + animate only when the slot changes, and dim the ghost block
  (`alphaValue` 0.35, re-applied in `configure` for cells scrolled in mid-drag).
- `draggingExited` slides back; `draggingSession(_:endedAt:)` is the stale-preview
  net; `gridPerformDrop` commits the slot via `onReorderCommit`.
- Frame continuity (decision 7): the commit keeps the preview until the model
  republish clears it in `update(configuration:)` — the new order's real solve
  reproduces the preview frame-for-frame, so there is no jump. The preview is
  torn down only on a real data change (version bump), never a cosmetic rebuild.
- Animation (decision 8 / step 3): `NSAnimationContext` +
  `allowsImplicitAnimation` + `invalidateLayout` + `layoutSubtreeIfNeeded`,
  isolated in `setLayoutPreview(_:animated:)`. **Needs a visual check in the
  running app** — if cells teleport instead of slide, swap that one helper for
  `collectionView.animator().performBatchUpdates(nil)` (the known-good fallback).

**Routing / model / config**
- `DropTarget.cell(collectionID:sortMode:)` → `.slot(collectionID:sortMode:index:)`;
  `DropOutcome.reorder(assetIDs:)` → `.reorder(assetIDs:insertAt:)`.
- `GridHostConfiguration`: `canReorder` + `onReorderCommit` replace `onCellDrop`.
- `CollectionView.handleCellDrop` → `handleSlotDrop(_:insertAt:)`.
- `IngestionModel.reorderItems(movingAssetIDs:toIndexOf:)` →
  `reorderItems(movingAssetIDs:insertAt:)` (same optimistic apply + undo pair).

**Test de-flake (`AssetDragPayloadTests.swift`)** — asserted byte-identity between
two independent `JSONEncoder` outputs; JSON key order isn't stable between encoder
instances, so it flaked (seen live). Both byte comparisons are now
cross-decodability assertions — the actual SwiftUI-interop contract.

## Files changed

- `AtelierRefs/AtelierRefs/MasonryReorderPreview.swift` (new)
- `AtelierRefs/AtelierRefs/GridReorder.swift`
- `AtelierRefs/AtelierRefs/MasonryCollectionLayout.swift`
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift`
- `AtelierRefs/AtelierRefs/DropRouter.swift`
- `AtelierRefs/AtelierRefs/IngestionModel.swift`
- `AtelierRefs/AtelierRefs/CollectionView.swift`
- Tests: `MasonryReorderPreviewTests.swift` (new), `MasonryCollectionLayoutTests.swift`,
  `GridReorderTests.swift`, `DropRouterTests.swift`, `AppUndoTests.swift`,
  `AssetDragPayloadTests.swift`

## Verification

App target builds; full `AtelierRefsTests` bundle green. The pure layer + layout
are exhaustively unit-tested; the coordinator drag session is verified by
compilation + the unchanged existing suites (headless coordinator drag tests are
deliberately omitted — the 193 harness destabilised the thumbnail timing suites).

## Manual verification still needed (drag is not headlessly testable)

- Single + multi (non-contiguous) reorder slides and commits without a jump.
- The animation SLIDES (not teleports) — see the fallback note above.
- Drop on the ghost = no-op; drop past the end lands last.
- Drag out to a sidebar row mid-preview slides back and the row drop still works.
- A non-manual sort shows no preview and no `.move`; an external drag is
  unaffected; a large folder stays smooth.

## Migration notes

`DropTarget.cell` / `DropOutcome.reorder(assetIDs:)` /
`reorderItems(...toIndexOf:)` / `reorderedIDs(...toIndexOf:)` /
`GridHostConfiguration.onCellDrop` are removed. Callers move to the slot-based
forms above.
