# 040 — Live reorder drop preview (AppKit grid) — plan

## Context

Manual reorder in the masonry grid works (192) but *feels* random. Root cause
(diagnosed, not a bug): reorder is defined in 1-D feed order while the grid
renders round-robin columns (`column = index % C`, `MasonryLayout.swift`), so

- one insertion shifts every later item one column sideways (the whole tail
  reshuffles),
- feed-adjacency ≠ visual adjacency at column boundaries (drop after a
  last-column cell → the item appears bottom-left of the next band),
- the reflow applies with `animatingDifferences: false`
  (`MasonryGridHost.swift:493`) — an instant teleport,
- the drop affordance is "onto a cell" with an invisible before/after rule
  (`GridReorder.swift:48-50`) — no way to predict the outcome.

**Goal: WYSIWYG reorder.** While an internal same-collection drag hovers the
grid, the grid *shows* the final arrangement — cells slide aside, the dragged
block's future position is visible — and the drop commits exactly what is shown.
No surprise on release.

## UX spec

- Drag starts (grid cell, Manual sort, same collection): the dragged block's
  cells dim in place (~35% opacity). They are the "ghost" — where the block
  currently sits in the previewed order.
- As the pointer moves, the grid continuously re-arranges (~180 ms slide) to
  show the order that WOULD result from dropping here. The ghost follows the
  pointer's insertion slot; other cells make room.
- Drop: commits the previewed order. Zero visual jump — the persisted layout is
  frame-identical to the last preview.
- Drag leaves the grid (to the rail / stack / outside) or the session ends
  without a grid drop: cells slide back to the real order; dimming clears.
- Ineligible drags (non-Manual sort, cross-collection, media-less marker
  payload, external drags): NO preview and the grid reports "no drop" (`[]`) —
  fixing today's inconsistency where hovering shows `.move` but the drop is
  then rejected.

## Design decisions

| # | Decision |
|---|---|
| 1 | **Preview is layout-only.** The data source / `items` / selection are untouched during the drag; only `MasonryCollectionLayout` renders a permuted arrangement. Commit goes through the existing model→snapshot pipeline. |
| 2 | **All math is pure and unit-tested**: insertion-slot hit-testing, preview permutation, preview frame mapping, and the commit reorder are free functions beside the existing tested helpers. |
| 3 | **The insertion slot is computed against the on-screen (preview) frames**, pointer-stable: hits on the ghost's own cells keep the current slot (no oscillation), and an 8 pt hysteresis guards re-slotting. |
| 4 | **Slot semantics**: slot `s ∈ 0...remaining.count` = position in the block-removed order. Over a cell: before/after by pointer x vs the cell's midX. Over a gap / below content: nearest cell by center distance, same rule. Empty remaining → 0. |
| 5 | **Eligibility is decided at `draggingEntered`** from the drag pasteboard (synchronous `AssetDragPayload.fromDragPasteboard()`, proven in 192): payload decodes ∧ `sourceCollectionID == collectionID` ∧ block ids resolve to current rows ∧ new config flag `canReorder` (`sortMode == .manual`). Fail → op `[]`, no preview. |
| 6 | **Commit replaces the target-cell rule.** `routeDrop`'s `.cell` target becomes `.slot(collectionID:sortMode:index:)` → `.reorder(assetIDs:insertAt:)`; the model gains `reorderItems(movingAssetIDs:insertAt:)` on a new pure `reorderedIDs(ids:movingIDs:insertAt:)`. The directional `toIndexOf` variant and its dead branches are deleted (DRY — the grid was its only caller); its tests migrate to the slot form. |
| 7 | **Frame continuity on commit**: the coordinator clears the preview inside the same `update(configuration:)` that delivers the reordered items, so the real solve reproduces the previewed arrangement — frames identical, no jump, and the commit apply stays `animatingDifferences: false`. |
| 8 | **Animation**: slot changes re-solve and invalidate inside `NSAnimationContext` (`allowsImplicitAnimation = true`, ~0.18 s) + `layoutSubtreeIfNeeded()`. Risk: NSCollectionView may not implicitly animate attribute application — verify FIRST (step 3 spike); fallback is `collectionView.animator().performBatchUpdates(nil)`. |
| 9 | **Perf**: re-solve only when the slot actually changes (not per `draggingUpdated` tick). The solve is the existing pure O(N) `masonryFrames` on a permuted aspect array — no thumbnail work: cell sizes ride their cells (width fixed per column count, height = width/aspect), so a preview never re-buckets or re-decodes. Bypass `MasonryLayoutCache` for preview solves (slot permutations would thrash the memo; cache the last `(order, width) → frames` pair locally). |
| 10 | **Cleanup is owned by the drag DESTINATION side plus the source's session end**: `draggingExited` animates back; `draggingSession(_:endedAt:operation:)` clears any stale preview (covers drops on the rail/stack/outside); a mid-drag `update(configuration:)` (reload, density step, width change) clears the preview before re-solving. |

## Implementation steps

### 1. Pure layer (`GridReorder.swift` + a new `MasonryReorderPreview.swift`) + tests

- `reorderedIDs(ids:movingIDs:insertAt:) -> [UUID]?` — gather the block in feed
  order, drop foreign ids, insert at the clamped slot of the remaining order.
  `nil` for empty/foreign block. Replaces `toIndexOf` (deleted).
- `previewDisplayOrder(count:blockIndices:slot:) -> [Int]` — display position →
  data index permutation; block occupies slots `s..s+block.count-1`.
- `previewFrames(displayOrder:aspects:width:columns:spacing:topInset:)
  -> (framesByDataIndex: [CGRect], contentHeight: CGFloat)` — solve
  `masonryFrames` over the permuted aspects, un-permute back to data order.
- `masonryInsertionSlot(at:framesByDataIndex:displayOrder:blockIndices:columns:)
  -> Int` — decision 4, ghost-hits return the current slot (decision 3).
- Tests (new `MasonryReorderPreviewTests.swift` + `GridReorderTests.swift`
  migration): slot matrix (cell halves, gaps, below content, inside top inset,
  empty, ghost hits, end slot, clamping), permutation cases (front/middle/end,
  non-contiguous block), frame mapping (every data index gets its display
  slot's frame; per-cell sizes preserved; content height), insertAt cases
  (0/middle/end, gather order, foreign dropped, nil cases).

### 2. Layout plumbing (`MasonryCollectionLayout`)

- `var preview: (framesByDataIndex: [CGRect], contentHeight: CGFloat)?` — when
  set, `prepare()` builds `attributesCache` (and `contentSize`) from it instead
  of `solved`; `analyticFrame(at:)`/`solvedFrames` reflect it (hover rings and
  the marquee math stay consistent; the marquee is inactive mid-drag anyway).
- Tests: with a preview set, `analyticFrame`/attributes/content size come from
  the preview; clearing restores `solved`; `shouldInvalidateLayout` unchanged.

### 3. Animation spike (do this EARLY — it is the one uncertain piece)

- Wire a temporary two-state toggle that sets/clears a hardcoded preview inside
  `NSAnimationContext` and confirm cells *slide* (not teleport) in the running
  app. If implicit animation doesn't take, fall back to
  `animator().performBatchUpdates(nil)` (decision 8). The chosen mechanism
  becomes a small `animatePreviewChange(_:)` helper on the coordinator.

### 4. Coordinator drag session (`MasonryGridHost.swift`)

- New state: `reorderPreview: (payload: AssetDragPayload, blockIndices: [Int],
  slot: Int, lastSlotPoint: CGPoint)?`.
- `gridDraggingOperation` (entered + updated): gate per decision 5. Eligible →
  compute slot (hysteresis per decision 3), on change re-solve + animate;
  return `.move`. Ineligible → `[]` (also fixes the lying `.move` today).
- `draggingExited` (new `MasonryGridViewEvents` hook) → clear + animate back.
- `draggingSession(_:endedAt:operation:)` → clear stale preview (no-op after a
  grid commit, which cleared via decision 7).
- `gridPerformDrop`: active preview → `configuration.onReorderCommit(payload,
  slot)`; none → `false`. (`onCellDrop` seam is replaced.)
- Ghost dimming: set the block cells' `view.alphaValue` (restore on clear;
  reconfigure-safe — reapplied in `configure(cell:at:)` while a preview is
  active).
- `update(configuration:)`: clear preview BEFORE applying items (decision 7 —
  order matters: commit path must not animate; cancel path already animated).

### 5. Config + routing + model (`GridHostConfiguration`, `CollectionView`,
   `DropRouter`, `IngestionModel`)

- `GridHostConfiguration`: `canReorder: Bool` + `onReorderCommit:
  (AssetDragPayload, Int) -> Bool` replacing `onCellDrop`.
- `CollectionView` (recently touched — re-read before editing): pass
  `canReorder: model.sortMode(for: collectionID) == .manual`; `handleCellDrop`
  becomes `handleSlotDrop(payloads:insertAt:)` via the reshaped
  `routeDrop(.slot(...))` → `model.reorderItems(movingAssetIDs:insertAt:)`.
- `DropRouter`: `.cell` → `.slot(collectionID:sortMode:index:)`;
  `.reorder(assetIDs:)` → `.reorder(assetIDs:insertAt:)`. Marker/empty payloads
  keep rejecting everywhere. Router tests updated.
- `IngestionModel.reorderItems(movingAssetIDs:insertAt:)` — same optimistic
  apply + undo pair as today, order from the new pure function; `toIndexOf`
  variant deleted.

### 6. Polish + verification + changelog

- Hysteresis tuning; ghost alpha; confirm no re-decode during preview
  (thumbnail bucket unchanged); leak-check the preview clears on every exit
  path (commit / exit / session end / mid-drag reload / collection switch).
- Manual: single + multi (non-contiguous) reorder, drop on ghost (no-op), drop
  past the end, drag out to rail mid-preview (slides back, rail still works),
  non-Manual sort shows no preview and no `.move`, external drag unaffected,
  10k-item folder stays smooth.
- Changelog `193-grid-reorder-preview.md`; note the animation mechanism chosen
  in step 3.

## Risks

- **Implicit animation of layout invalidation** may not work as assumed — hence
  the step-3 spike before any wiring. Both fallbacks are known-good AppKit
  paths.
- **Slot jitter** near column boundaries — mitigated by ghost-hit stability +
  hysteresis; tunable constants live beside the pure slot function.
- **Preview/commit divergence** (a reload lands mid-drag) — decision 10 clears
  the preview on any config change; the drop then simply refuses (no preview →
  no commit), never commits a stale slot.
- Windowed coordinator tests must avoid main-run-loop spins (the 192 harness
  destabilised the thumbnail timing suites); keep them synchronous or omit in
  favour of the pure layer.

## Out of scope (natural follow-ups)

- Edge auto-scroll while dragging (the 192 trade, more wanted once preview
  lands).
- Cross-collection positional drop ("move into this collection at this spot").
- An insertion caret rendering (the sliding preview largely obviates it).
