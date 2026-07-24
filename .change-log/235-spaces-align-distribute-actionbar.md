# 235 — Spaces canvas: alignment / distribution + context-aware action bar

Phase 1 of the Figma-grade Spaces work (plan `051`, overview `050`): adds
**6 aligns + 2 distributes** over a multi-selection and restructures the floating
action bar into a **context-aware** pill (idle / single / multi), moving the tool
controls down out of the header. Zero model/schema change — align/distribute reuse
the existing batched-placement + one-undo-step path.

## Summary

- **Pure `CanvasArrange` kernel.** New geometry-only, identity-agnostic
  `[CGRect] → [CGRect]` primitive. One 8-case `Operation` enum (6 aligns + 2
  distributes) carries each op's undo action name + `minimumCount` (align 2,
  distribute 3); a single `apply(_:to:)` entry dispatches. Aligns snap to the
  selection bounding box; distributes are equal-gaps (Figma "distribute spacing"):
  sort by leading edge, first/last anchored, free space shared as equal gaps,
  **clamped non-negative** (overlaps pack left rather than emitting negative gaps).
- **One shared placement-mutation path.** Extracted `SpaceModel.applyPlacementEdit`
  (exact-equality no-op filter → forward persist → one reversible undo group →
  reload policy). `restackSelection` and `flushMoves` were **refactored onto it**;
  align/distribute ride it too.
- **One model op.** `SpaceModel.arrange(_:)` filters the selection through `items`,
  reads live rects, calls the kernel, and applies **in-memory** (flicker-free, like
  a drag) + persists `reload:false` as ONE batched write / ONE undo step. Only x/y
  move — w/h/z are carried from the live placement (the kernel never sees them).
- **Context-aware bar.** A pure `SpaceBarMode` (idle / single / multi) driven by the
  selection count decomposes the bar into `@ViewBuilder` sub-bars. **Undo/redo are
  mode-invariant** (present in every mode, dim-not-hide) so ⌘Z/⌘⇧Z never die. Idle
  shows the tool picker; single folds in the Edit glyph + z-order; multi shows
  align + distribute (gated on `minimumCount`) + z-order.
- **Header/relocation cleanup.** Tool picker + Edit moved from the header (now just
  name + count) into the bar; the hidden V/F/T `toolShortcuts` are **hoisted to the
  canvas container** (not the idle sub-bar) so the create tools stay reachable in
  every mode; empty-state hint copy fixed ("tools above" → "below").

## Files changed

- `AtelierRefs/AtelierRefs/CanvasArrange.swift` — **new**: the pure kernel
  (`Operation` enum + `apply(_:to:)`, equal-gaps distribute with all edge cases).
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `applyPlacementEdit(name:edits:reload:)`
  helper; `restackSelection` + `flushMoves` repointed onto it; new `arrange(_:)`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `SpaceBarMode` + `Operation.isEnabled`
  (pure); decomposed `actionBar` (undo/redo mode-invariant, idle/single/multi
  sub-bars, arrange glyphs with gating); header shrunk; `toolShortcuts` hoisted to
  the canvas; Edit folded into the single bar; hint copy fixed.

## Tests

- `AtelierRefsTests/CanvasArrangeTests.swift` — **new**: exhaustive table-driven
  over `Operation.allCases` (count/size preserved, idempotent, below-minimum no-op)
  + per-op align geometry (2 / N items, mixed sizes, negative coords, already-
  aligned) + distribute (even, mixed widths, already-even, overlap→clamp, identical
  positions, input-order preserved, <3 no-op).
- `AtelierRefsTests/SpaceArrangeTests.swift` — **new**: model integration — one
  batched write + one undo step, undo restores all N, redo reapplies, no-op align
  registers no undo, distribute <3 no-op, only x/y touched, selection survives, and
  the align→undo→move interleaving through the shared write chain.
- `AtelierRefsTests/SpaceBarModeTests.swift` — **new**: `barMode` thresholds + op
  enablement (align ≥2, distribute ≥3) off-by-one pins.

## Migration notes

**None.** No schema/model change, no new `AppServices` methods — reuses the existing
batched `setSpaceItemPlacements`. `ElementStyle` untouched (that's Phase 2). The
`restackSelection` / `flushMoves` refactor is behavior-preserving, fenced by the
existing `SpaceUndoTests` / `SpaceMultiSelectTests` characterization suites.
