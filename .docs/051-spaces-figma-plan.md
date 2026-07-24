# 051 — Spaces Canvas Phase 1: Action Bar + Alignment/Distribution Plan

## Goal

Move the Spaces tool controls into a **context-aware floating action bar** and add
**Figma-style alignment (6) + distribution (2)** over a multi-selection — with zero
model/schema change, reusing the existing batched-placement + one-undo-step path.

Scope is Phase 1 of [050](./050-spaces-figma-overview.md). Rich text (Phase 2) and
usability affordances (Phase 3+) are out of scope here.

This plan is the reviewed-and-chosen output of a full architecture / code-quality /
test / performance review with the user (2026-07-24). Each decision is labelled
`[nX]` matching the review's issue number + option letter. A follow-up evaluation
pass (same day) verified the plan's claims against the code and added the four
`[E-n]` amendments below (all user-approved).

## Current state (verified)

- Action bar is one flat `HStack` of 4 buttons that **dim-not-hide**
  (`SpaceView.swift:184–222`), using shared `SelectionBarButton` +
  `selectionBarChrome()`.
- Tool `Picker` + V/F/T shortcuts + Edit button live in the **header**
  (`SpaceView.swift:65–124`); `toolShortcuts` hides in the picker's `.background`
  (`:98–107`); the empty-state hint says tools are "above" (`:281`).
- `restackSelection` (`SpaceModel.swift:327–357`) already encodes the target shape:
  build `forward`/`backward` placements → guard no-op → `enqueue(persistPlacements
  (forward))` → `registerReversible(forward, backward)`. `flushMoves` (`:266–275`)
  is the same shape with in-memory apply + `reload:false`.
- `livePlacement` (`SpaceModel.swift:361–369`) is the freshest-rect reader (in-memory
  tile if present, else stored row) — required because a drag persists with
  `reload:false`, leaving `items` stale.
- `persistPlacements` (`:138–148`) writes a batch in **one** transaction. No
  alignment/distribution primitives exist anywhere.

## Decisions (reviewed + confirmed)

### Architecture

1. **[1A] Pure `CanvasArrange` kernel** — new app-layer file, geometry only.
   Keeps `SpaceLayout` single-purpose; testable in isolation; no premature renderer
   coupling (folder canvas is on the deprecation path).
2. **[2A] Context-aware bar decomposed inside `SpaceView`** — a computed `barMode`
   enum (`.idle` / `.single` / `.multi`) driving `@ViewBuilder` sub-bars. Explicit,
   colocated with the `tool`/selection state it reads. Promote to a `SpaceActionBar`
   file only if it outgrows ~3 builders (revisit when Phase-2 text adds a sub-bar).
3. **[3A] Align to the selection bounding box** (Figma default). 2+ required for
   align; **3+ for distribute**; **single-item align disabled**. No renderer→model
   viewport data path — the model stays viewport-free. Align-to-viewport is deferred
   to whenever zoom-to-fit adds that seam.
4. **[4A] Extract a shared `applyPlacementEdit(name:, edits:)` helper** — does the
   no-op filter + `enqueue(persist forward)` + `registerReversible(forward,
   backward)` + reload-policy. **Refactor `restackSelection` and `flushMoves` onto
   it**; all 8 new ops call it. One tested placement-mutation path.

### Code quality

5. **[5A] `CanvasArrange` interface: `[CGRect] → [CGRect]`** — identity-agnostic.
   The model maps live rects → `CGRect`, calls the kernel, zips results back to
   selected ids by index. The kernel *structurally* cannot touch ids or z (it never
   receives them) — a stronger guarantee than a comment.
6. **[6A] Equal-gaps distribution** (Figma "distribute spacing"): sort by leading
   edge; first & last fixed as anchors; redistribute free space as equal gaps by
   width. Explicit edge handling: identical positions, **clamp non-negative gaps on
   overlap** (never emit negative overlaps), unequal sizes, `< 3` → no-op.
7. **[7A] Exact-equality no-op guard inside the 4A helper** — filter edits where
   `new == old` (reusing `Placement: Equatable`); if none remain, do nothing (no
   write, no undo entry). Exact equality is correct because targets are *recomputed*,
   not accumulated — no float drift. Every placement op inherits the guard.
8. **[8A] Relocate all three header dependents with the tool picker**: move
   `toolShortcuts` (so V/F/T keep working), fold `editButton` into the `.single` bar
   mode, and fix the empty-state hint copy ("above" → "below"). The relocation isn't
   done until the dependents follow.

### Tests

9. **[9A] `CanvasArrange` — exhaustive table-driven suite + invariant assertions.**
   6 aligns × {2 items, N items, already-aligned no-op, mixed sizes, negative world
   coords}; 2 distributes × {3 even, mixed widths, already-even no-op,
   overlapping→clamp, identical positions, `<3` no-op}. Invariants: align-left ⇒ all
   `minX` equal; distribute ⇒ first/last fixed, input order preserved, gaps equal.
10. **[10A] `SpaceModel` integration suite** over the temp-`AppServices` harness
    (like `SpaceUndoTests`): align/distribute of N ⇒ **one** batched write + **one**
    undo step; undo restores all N; redo reapplies; **no-op align registers no undo
    entry** (`canUndo` unchanged); distribute `<3` is a no-op; ops touch **only x/y**
    (w/h/z preserved); selection survives the op.
11. **[11A] Characterize-first for the 4A refactor** — before refactoring, confirm
    `SpaceUndoTests` / `SpaceMultiSelectTests` pin restack-selection undo *and*
    group-move-coalesces-to-one-undo; backfill gaps; refactor under green. Add one
    **interleaving** test (align → undo → move) exercising the serial `writeChain`
    through the shared helper.
12. **[12A] Bar logic extracted + unit-tested pure** — `barMode(selectionCount:)`
    and enablement predicates (align ≥2, distribute ≥3) as pure statics; test the
    thresholds (catch off-by-ones). Rendering stays compile-only (repo convention).

### Performance

13. **[13A] Apply in-memory (like a drag)** — `content.setPlacement` per changed
    tile + persist `reload:false`; undo/redo use `reload:true`. **Read live rects via
    `livePlacement`** (or align uses stale pre-drag coords). The 4A helper carries a
    reload-policy param (geometry ops → in-memory; z-ops like restack → reload). No
    `contentVersion` bump, no `CanvasView` `.id` rebuild, no thumbnail re-decode on
    the forward op. DRY bonus: align rides the move path.
14. **[14A] Do nothing about the full host rebuild on `reload:true`** — pre-existing
    (`SpaceView.swift:168`), only hit on undo/redo of an align, board is dozens of
    items. Unmeasured + off the hot path → out of scope; revisit only if profiling a
    large board shows undo lag. (Host-diffing would be over-engineering here.)
15. **[15A] Id↔rect bridge — VERIFIED (evaluation pass): it is a linear scan**, not
    dict-backed (`tileID(forSpaceItemID:)` is `rows.firstIndex`,
    `SpaceContent.swift:137–139`). Align of N selected over board M is O(N·M) —
    a **pre-existing** cost shared with `restackSelection`/`livePlacement`, and
    negligible at board scale (dozens–hundreds of items → thousands of UUID
    compares). Per the reviewed decision: **do nothing**; logged here, out of
    Phase-1 scope.

### Evaluation amendments (verified against code, user-approved)

- **[E-1] 15A's verification is complete** — recorded above; no implementation task
  remains for it.
- **[E-2] Shortcuts must not die with mode-switched sub-bars.** SwiftUI
  `keyboardShortcut`s fire only while their button is RENDERED. Therefore:
  **undo/redo are mode-invariant bar residents** (present in `.idle`/`.single`/
  `.multi`, dim-not-hide — so ⌘Z/⌘⇧Z always work), and the hidden V/F/T
  `toolShortcuts` block is hoisted to the **canvas container** (outside any
  mode-switched content), NOT into the `.idle` sub-bar with the picker. This is
  [8A] one level deeper: relocating the picker into a conditional sub-bar without
  hoisting its shortcut block silently breaks V/F/T whenever anything is selected.
- **[E-3] One enum-driven op, not 8 methods.** `CanvasArrange.Operation` — an
  8-case enum, each case carrying its undo action name and `minimumCount` (align 2,
  distribute 3) — with a single kernel entry `CanvasArrange.apply(_:to:)` and a
  single model entry `SpaceModel.arrange(_:)`. Kills 8× repetition across kernel,
  model, and tests (table-driven over `Operation.allCases`); the bar's enablement
  predicates read `op.minimumCount` instead of scattered literals.
- **[E-4] Bar mode when a create tool is active with a selection: selection wins.**
  `barMode` stays selection-count-driven; an active Frame/Text tool does not
  override `.single`/`.multi`. Tools remain reachable via the hoisted V/F/T
  shortcuts ([E-2]) regardless of mode.

## Phased implementation

Single PR (small, no schema/model change), built bottom-up so each layer is tested
before the next:

1. **Kernel** — `CanvasArrange.Operation` (8 cases with undo name + `minimumCount`
   [E-3]) + `apply(_:to:)` (`[CGRect]→[CGRect]`, equal-gaps distribute, all edge
   cases) [1A/5A/6A] + exhaustive table (over `allCases`) + invariant tests [9A].
2. **Refactor under green** — audit/backfill restack + group-move undo tests [11A]
   (evaluation note: the baseline is largely in place already — `multiMoveOneUndo`,
   `multiRestackPreservesOrder`, `restackWholeBoardNoOp`, and crucially
   `restackKeepsDraggedPosition` pin the key behaviors; backfill is small); extract
   `applyPlacementEdit(name:, edits:, reload:)` with the no-op guard [4A/7A];
   repoint `restackSelection` + `flushMoves`; add the align→undo→move interleaving
   test [11A].
3. **Model op** — ONE `SpaceModel.arrange(_ op: CanvasArrange.Operation)` [E-3]:
   filter `selectedItemIDs` through `items` (the `restackSelection` pattern — keeps
   `livePlacement`'s force-unwrap unreachable), read live rects, call the kernel,
   apply **in-memory** through the helper [3A/13A] + full integration suite [10A].
4. **Bar** — `barMode` enum + enablement predicates reading `op.minimumCount`
   (pure, tested) [12A]; decompose the action bar into idle/single/multi
   `@ViewBuilder` sub-bars with **undo/redo mode-invariant** [E-2] [2A]; move the
   tool picker + `editButton` down, hoist `toolShortcuts` to the canvas container
   [E-2], fix the hint copy [8A]; wire the ops with gating (align ≥2, distribute ≥3).

## Schema / migration impact

**None.** No new columns, tables, or `AppServices` methods — reuses the existing
batched `setSpaceItemPlacements`. `ElementStyle` is untouched (that's Phase 2).

## Risks & edge cases

- **Stale placements (primary correctness risk)**: ops must read `livePlacement`,
  not `items`, or an align after an un-reloaded drag uses pre-drag coordinates.
  Mirrors the guard `restackSelection` already documents (`SpaceModel.swift:299–304`).
- **No-op undo pollution**: the 4A helper's exact-equality filter [7A] must run, or
  aligning already-aligned items adds empty undo entries + wasted writes.
- **Distribution degeneracies** [6A]: `<3` disabled; identical positions; overlapping
  items clamped to non-negative gaps; first/last always the anchors.
- **Refactor regression** [11A]: consolidating shipped undo code (`restackSelection`,
  `flushMoves`) onto the shared helper — fenced by characterization tests kept green.
- **Gating off-by-ones** [12A]: distribute enabled at 2 or align at 1 — pinned by the
  pure threshold tests.
- **Relocation loose ends** [8A]: silently-broken V/F/T shortcuts, orphaned
  `editButton`, stale "tools above" copy if the move is done half-way.
- **Mode-switched shortcut death** [E-2]: a `keyboardShortcut` on a button that
  isn't rendered doesn't fire — putting V/F/T (or undo/redo) inside a conditional
  sub-bar breaks them in the other modes. Undo/redo stay in every mode; V/F/T
  hoisted to the canvas container.
- **`livePlacement` force-unwrap** (`SpaceModel.swift:367`): safe only for ids
  present in `items` — `arrange(_:)` must filter the selection through `items`
  first (as `restackSelection` does).

## Change-log

Add a `.change-log/` entry on completion (per repo convention).

## Confirmed with user (2026-07-24)

All 15 decisions above (`[1A]`–`[15A]`) are the chosen options from the four-section
review. "Variable text" is scoped as **rich text controls** and deferred to Phase 2
([050](./050-spaces-figma-overview.md)).
