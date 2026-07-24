# 050 — Spaces Canvas: Figma-Grade Arrange, Text & Usability

> Direction (user): make the Spaces canvas feel like Figma — alignment &
> distribution, rich ("variable") text, and a set of usability affordances — and
> **move the top-bar tools into the floating action bar**. Builds on the
> multi-select foundation from [049](./049-spaces-multiselect-plan.md).
>
> This overview is the synthesis + roadmap. The reviewed Phase-1 spec is
> [051](./051-spaces-figma-plan.md). Every Phase-1 decision below was chosen
> through a full architecture / code-quality / test / performance review with the
> user (2026-07-24).

## Current state (verified)

- **Top bar** (`SpaceView.swift:65–124`) holds the tool `Picker` (Select / Frame /
  Text), the contextual Edit button, name + item count, and a hint. V/F/T
  shortcuts ride the picker's `.background` (`toolShortcuts`, `:98–107`).
- **Action bar** — a floating bottom pill over the canvas (`SpaceView.swift:184–222`,
  `.overlay(alignment: .bottom)`), shared `SelectionBarButton` +
  `selectionBarChrome()`. Today: **Undo / Redo / bring-to-front / send-to-back
  only** (dim-not-hide when disabled).
- **Item model** — `SpaceItem` (`AtelierCore/.../Domain/SpaceItem.swift:79–143`) is
  geometry-only: `x/y/w/h/z` + `kind` + optional `style` JSON. **No rotation,
  opacity, lock, or any alignment/distribution logic exists anywhere.**
- **Text** — `ElementStyle` carries `text` / `fontSize` / `textColor` only
  (`SpaceItem.swift:33–38`); edited through the `ElementInspector` popover
  (`ElementInspector.swift`) — no font family, weight, alignment, line-height,
  letter-spacing, resize mode, or inline on-canvas editing.
- **Selection + batched persistence already exist**: `SpaceModel.selectedItemIDs`
  (`SpaceModel.swift:32`); `restackSelection` (`:327–357`) is the exact template for
  batched-placement + one-undo-step ops; `flushMoves` (`:266–275`) does in-memory
  move + `reload:false` for flicker-free drags.

The foundation (selection, batched writes, undo ping-pong) is solid. What's
missing is the **operations** and a **place to put them** — not new plumbing.

## Roadmap

### Phase 1 — Action bar + alignment/distribution (spec: [051](./051-spaces-figma-plan.md))

- **Restructure the action bar into a context-aware bar** (`barMode`: idle /
  single / multi). Idle → tools (Select/Frame/Text) moved down from the header;
  single → align-to-canvas is disabled, Edit + z-order + delete; multi → align +
  distribute + z-order. Header shrinks to name + count.
- **8 ops**: 6 aligns (L / H-center / R / T / V-center / B) + 2 distributes
  (horizontal / vertical, equal-gaps). Pure `CanvasArrange` kernel (`[CGRect] →
  [CGRect]`), persisted through a shared `applyPlacementEdit` helper as **one undo
  step**, applied **in-memory** (like a drag — no host rebuild).
- **No model/schema change.** Reuses `setSpaceItemPlacements` (one transaction).

### Phase 2 — Rich ("variable") text

User's definition of "variable text" = **rich text controls**, not design
tokens/variable-font axes. Scope:

- Extend `ElementStyle` with `fontFamily`, `fontWeight`, `textAlign`, `lineHeight`,
  `letterSpacing`, and a **resize mode** (auto-width / auto-height / fixed — the
  Figma-defining behavior).
- **Inline on-canvas editing** (double-click to type via a transient `NSTextView`
  overlay, per [031](./031-spaces-overview.md)'s T3), replacing popover-only editing.
- Touches: the model (`ElementStyle` + JSON round-trip), the `CATextLayer`
  rendering (`CanvasEngine.setTextOverlay`, `ElementRendering`), the inspector, and
  a new edit overlay with pan/zoom coordinate mapping (the fiddliest UI work).

Biggest lift of the three phases — its own overview/design/plan when it starts.

### Phase 3+ — Usability affordances (prioritize with the user later)

- **Snapping & smart guides** — snap to other items' edges/centers with guide lines
  during drag (hook: the `CanvasEngine` drag loop).
- **Rotation & opacity** — add `rotation` + `opacity` to `SpaceItem`; unlocks
  expressiveness (schema change).
- **Arrow-key nudge** (1px / 10px with Shift) — trivial atop the batched-move path.
- **Numeric inspector** (X/Y/W/H fields) alongside the style inspector.
- **Explicit grouping** — frames are currently *implicit* groups by spatial
  containment (`SpaceContent.groupMembers`); explicit groups are more predictable.
- **Copy / paste / duplicate** (⌘D with offset).
- **Lock** — locked items ignore marquee/drag.
- **Zoom-to-fit** — bundle the renderer→model viewport seam here (deferred from
  Phase-1 Issue 3 — align-to-viewport rides the same seam once it exists).

## Settled decisions (Phase 1)

O1: pure `CanvasArrange` in the app layer. O2: context-aware bar decomposed inside
`SpaceView` via a `barMode` enum + `@ViewBuilder` sub-bars. O3: align to the
**selection bounding box** (single-item align disabled; distribute needs ≥3); no
renderer→model viewport coupling yet. O4: extract a shared `applyPlacementEdit`
helper and refactor `restackSelection` + `flushMoves` onto it. O5: equal-gaps
distribution (first/last anchored, sort by leading edge, clamp non-negative). O6:
exact-equality no-op guard inside the helper. O7: apply **in-memory** (read live
placements), `reload:true` only on undo/redo. Full detail + tradeoffs in
[051](./051-spaces-figma-plan.md).

## Open questions

1. Phase-2 "variable text" confirmed as rich controls — do we also want design
   tokens / variable-font axes eventually (user deferred)?
2. Phase-3 priority order — snapping vs rotation/opacity vs grouping first?
3. Distribution second op ("equal centers") ever wanted, or is equal-gaps enough?
4. Does align-to-canvas (single item, centered on the viewport) get pulled forward
   if zoom-to-fit lands sooner?
