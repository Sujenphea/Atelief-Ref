# 049 — Spaces Canvas Multi-Select Drag Plan

## Goal

Add **multi-selection dragging** to the Spaces canvas so a user can select
several tiles (⌘/⇧-click or rubber-band marquee) and drag them together — bringing
the board to parity with the Collection/Search grids, which already multi-select
and multi-drag through shared brains.

This plan was produced by a full architecture / code-quality / test / performance
review; every decision below is the reviewed-and-chosen option.

## Current state (verified)

- **On-canvas drag is hand-rolled AppKit**, not SwiftUI drag-and-drop:
  `CanvasHostView` (`NSView`) owns `mouseDown/Dragged/Up` with a 3pt click-vs-drag
  threshold (`CanvasHostView.swift:119-194`); `CanvasEngine` runs a live-drag state
  machine that translates real CALayers by `dragWorldOffset` (no drag image)
  (`CanvasEngine.swift:146-219`).
- **Selection is strictly single**: `CanvasEngine.selectedTileID: Int?`
  (`:52`), surfaced via `CanvasHostView.selectedTileID` (`:67`), mirrored as
  `SpaceModel.selectedItemID: UUID?` (`SpaceModel.swift:29`).
- **The only multi-tile carry today is frame-as-group**: dragging a `.frame`
  carries the tiles it contains, via `groupMembers(forDraggedTileID:)` +
  `dragGroupIDs` (`CanvasEngine.swift:63-66, 152-157`).
- **Multi-tile move persistence + undo already exist**: `currentDragOrigins()`
  emits every carried tile (`:201-212`); the host fires `onMoveTile` per tile
  (`CanvasHostView.swift:189-191`); `SpaceModel` coalesces the burst into one undo
  step via `pendingMoves`/`flushMoveUndo` (`SpaceModel.swift:63, 230-247`). What is
  missing is **multi-selection**, not multi-move.
- **Two identity spaces**: the engine works in `Int` tile indices (`Tile.id` is the
  index into the provider's rows); the model works in `UUID` space-item ids; bridged
  by `content.tileID(forSpaceItemID:)` / `spaceItemID(forTileID:)`.
- **The grid's selection spine does not fit the canvas**: `GridSelection` is built
  around a linear feed `order: [UUID]` + `columns` (range/arrow/lead/open-detail),
  none of which a free-form, zoomable, z-ordered board has. Reuse the *pure kernels*
  (`marqueeRect`, the `.marquee(hits:base:)` union shape, `ModifierReading`,
  `DisplayLinkPump`), not the whole reducer or `GridMarqueeController`.

## Decisions (reviewed + confirmed)

### Architecture
1. **Selection state**: engine owns `selectedTileIDs: Set<Int>` (geometry lives
   there); `SpaceModel` mirrors `selectedItemIDs: Set<UUID>` (persistence). The
   existing single-select APIs (`selectedTileID`/`selectedItemID`) become **derived**
   conveniences (`count == 1` case), never stored in parallel.
2. **Marquee**: a **canvas-native** rubber-band in `CanvasHostView`/`CanvasEngine`,
   world-space — reusing only the pure `marqueeRect` + `DisplayLinkPump`, *not*
   `GridMarqueeController` (bound to `NSCollectionView`/scroll view/feed order).
3. **Drag carry**: the **host** decides the carried set and passes it in —
   `beginDrag(tileID:, alsoCarry:)`. Host applies the Finder-scope rule (grab a
   selected tile → carry the selection; grab an unselected tile → select-only it);
   the engine unions `alsoCarry` with its frame-group members. UI policy stays in the
   host, off the renderer.
4. **Highlights**: a per-tile highlight-layer dictionary `selectionLayers: [Int:
   CALayer]`, managed exactly like `badges`/`textLayers` (siblings outside the
   `LayerPool`, created/dropped in `sync()`). Preserves the engine's window-free
   design and pool invariants; single-highlight becomes the `count == 1` case.

### Code quality
5. **DRY**: extract the Finder-scope carry/select-on-grab rule as a **shared
   id-generic helper** (`dragScope<ID>(grabbed:selection:)`) used by both the grid
   and the canvas — the grid keeps its `UUID`, the canvas passes `Int`.
6. **Reducer**: a small **canvas-local `CanvasSelection`** pure value + reducer
   (`selectOnly / toggle / add-⇧ / marquee(hits:base:) / clear`), reusing the shared
   `ModifierReading` seam and the marquee-union shape — not `GridSelection` wholesale.
   ⇧-click on the board is **additive** (no linear order to range over).
7. **Edge cases handled now** (all four): carried-set **de-dup** (selection ∩
   frame-group appears once), selection-set **pruning on reload**, **batched**
   multi-delete / multi-restack undo, **Delete-key acts on the whole set**.
8. **Gesture routing**: one **explicit precedence branch** in `mouseDown` —
   `tool != .select` → create rubber-band; empty-space → marquee (below-threshold up
   = click-to-clear); tile hit → drag candidate. Documented in one comment.

### Tests
9. **`CanvasSelection`**: comprehensive pure suite mirroring `GridSelectionTests`
   (every action + pruning + edges: ⇧-additive, marquee union-with-base,
   toggle-to-empty, reload prune).
10. **Engine**: carry via `alsoCarry`, the selection ∩ frame-group **de-dup** guard
    (a tile appears once in `currentDragOrigins()`), unselected-grab-carries-one, and
    a pure `tiles(inScreenRect:)` suite (empty box, partial overlap, z-independent,
    off-screen excluded) mirroring `MarqueeMathTests`. No window.
11. **Model**: multi-move settles to N placements as **one** undo (also closes the
    pre-existing frame-group coalescing gap), multi-delete one undo, multi-restack
    relative order preserved, selection-set pruning on reload. Over the real
    temp-`AppServices` harness `SpaceUndoTests` already uses.
12. **Highlights**: extend `SelectionTests` — N selected → N highlight layers,
    partial deselect drops the right layers, off-screen selected draws none,
    select/deselect cycles **don't leak** (bounded sublayer count).
    *Gesture plumbing stays untested at the `NSView` level; extract click-vs-drag /
    precedence as pure statics (like `exceedsDragThreshold`) and test those.*

### Performance
13. **Persistence**: add a **batch** `setSpaceItemPlacements([(id, placement)])`
    (one transaction); route the drop **and** `applyMoves` (undo) **and**
    multi-restack through it. O(1) transactions instead of O(N), and fewer code paths.
14. **Marquee hit-test**: hit-test the marquee's **world** rect against **all**
    `provider.tiles` (O(N)/tick, correct at edges under auto-pan) — not just visible
    tiles (fast but wrong). No spatial index (premature at board scale).
15. **Drop-time lookups**: replace `provider.tiles.first(where:{$0.id==id})` in
    `currentDragOrigins`/`endDrag` with guarded O(1) `provider.tiles[id]` (the
    documented id==index invariant). Lowest-stakes item (drop-time, not per-frame).
16. **Highlight memory**: highlight layers are **visible ∩ selected** only
    (recycled off-viewport like badges) — layer count bounded by the viewport, not
    the selection size, so select-all on a large board stays cheap.

## Phased implementation (two PRs)

### PR 1 — Click-based multi-select + multi-drag (no marquee yet)
1. `CanvasSelection` pure reducer (D6) + comprehensive tests (D9).
2. Extract `dragScope<ID>` (D5); repoint the grid's existing call (keep grid tests
   green).
3. Engine: `selectedTileIDs: Set<Int>`; per-tile highlight layers (D4, D16
   visible-only); `selectedTileID` becomes the `count==1` shim + highlight invariant
   tests (D12).
4. Drag carry: `beginDrag(tileID:, alsoCarry:)` + engine de-dup (D3/D7) + O(1)
   lookups (D15) + engine carry/de-dup tests (D10, carry half).
5. Host: click routing (plain/⌘/⇧/empty-clear), Delete-key on the set (D7).
6. Model: `selectedItemIDs: Set<UUID>` mirror + derived `selectedItemID`; reload
   pruning (D7); batch `setSpaceItemPlacements` feeding drop + `applyMoves` (D13);
   batched multi-delete/multi-restack undo (D7) + model tests (D11); action-bar
   gating on `!isEmpty`.

### PR 2 — Marquee (rubber-band)
7. Canvas-native marquee (D2, D14): world-space box reusing `marqueeRect` +
   `DisplayLinkPump`; all-world `tiles(inScreenRect:)`; edge auto-pan pans the
   transform + pure hit-test tests (D10, hit-test half).
8. Full gesture precedence branch (D8).

## Schema / migration impact

**None for schema.** The one persistence addition is an **additive** batch method
`setSpaceItemPlacements([...])` over existing `space_item` rows (one transaction);
the single-item `setSpaceItemPlacement` stays. No new tables or columns.

## Risks & edge cases

- **Carried-set double-count** (primary correctness risk): a selected tile also
  inside a dragged frame must appear **once** in `currentDragOrigins()` — union into
  a single `Set<Int>`, keep the existing `dragGroupIDs.remove(primary)` guard.
  Emitting it twice corrupts the undo burst silently. Directly tested (D10).
- **Empty-space gesture contention**: create-tool rubber-band vs marquee vs
  click-to-clear share one gesture — the explicit precedence branch (D8) is
  mandatory, not emergent.
- **Selection survives reload only for present ids** — extend the existing
  stale-`selectedItemID` guard (`SpaceModel.swift:174-176`) to intersect the set.
- **Large selections**: batch writes (D13) keep drop + undo O(1) transactions;
  highlight layers stay viewport-bounded (D16). Neither degrades with selection size.
- **`⇧`-additive assumption**: confirmed with user — a spatial board has no linear
  order, so ⇧ adds rather than ranges.

## Confirmed with user (2026-07-24)

- All 16 reviewed decisions above are the chosen options.
- ⇧-click on the canvas is **additive**, not a range.
- Adding a **batch** `AppServices` placement method is in scope.
- Sequence: PR 1 (click multi-select + multi-drag) first, PR 2 (marquee) second.

## Change-log

Add a `.change-log/` entry per PR on completion (per repo convention).
