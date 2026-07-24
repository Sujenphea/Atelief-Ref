# 233 — Spaces canvas marquee (PR 2: rubber-band select)

Completes the Spaces multi-select story (plan `049`): dragging on **empty**
canvas now rubber-bands a selection box. ⇧-drag is additive onto the current
selection; a bare drag replaces it; a bare click on the void still clears. This is
the canvas peer of the Collection/Search grid marquee — reusing the same pure math
shape, not the grid's `NSCollectionView`-bound controller.

## Summary

- **World-anchored marquee.** `CanvasHostView` anchors the box at the world point
  under the `mouseDown` and tracks the opposite corner through the *current*
  transform every tick. Anchoring in world space (not screen) is what lets edge
  auto-pan grow the box correctly while the transform moves under a still pointer.
- **All-world hit-test.** New `CanvasEngine.tiles(inWorldRect:)` intersects the
  box against **every** provider tile (offscreen included, z-independent,
  degenerate excluded) — O(N)/tick, correct at the edges under auto-pan, where a
  visible-only test would silently miss tiles (049 · D14). Boundary rule matches
  the grid's `marqueeIndices`: strict overlap for an area box (stopping on a tile
  edge doesn't sweep it), edge-inclusive for a degenerate (click) box.
- **Live selection via the reducer.** Each tick applies
  `CanvasSelection.marquee(hits:base:)` through the existing `onSelectTiles`
  callback — the box unions its hits onto the ⇧-captured base, so the model and
  highlights update continuously with zero new plumbing.
- **Edge auto-pan.** When the pointer enters a screen-edge band the host drives a
  `CADisplayLink`, panning the transform by a pt/sec velocity ramp × the frame's
  real duration (the grid marquee's `edgeZone`/`minSpeed`/`maxSpeed` feel). A
  minimal in-renderer peer of `DisplayLinkPump` — inlined to keep `CanvasRenderer`
  dependency-free (049 · D5's "no cross-module coupling for a small predicate",
  applied to the pump). The link is invalidated if the view leaves its window.
- **Explicit gesture precedence (049 · D8).** One documented branch in `mouseDown`:
  create tool → new-element rubber-band; `.select` on a tile → drag candidate;
  `.select` on empty space → marquee (below-threshold up = click-to-clear). A
  shared `resetGestureState()` clears all transient press/drag/marquee state so no
  gesture inherits a stale candidate.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — new
  `tiles(inWorldRect:)` all-world hit-test + the `marqueeIntersects` boundary rule.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — marquee
  state + overlay layer, world-anchored `updateMarquee`, the `marqueeAutoPanVelocity`
  ramp + `CADisplayLink` auto-pan, the `mouseDown/Dragged/Up` precedence branch, and
  `resetGestureState` / `viewDidMoveToWindow` cleanup.

No `CanvasView` / `SpaceView` / model / service changes — the marquee is entirely
internal to the host; PR 1's selection set, batched persistence, and highlights
carry it end to end.

## Tests

- `CanvasRendererTests/MarqueeHitTestTests.swift` — **new** (14): the
  `tiles(inWorldRect:)` hit contract (overlap, gap, enclose, strict-edge,
  degenerate-click, z-independent, offscreen-included, degenerate-tile excluded,
  clear-of-all) mirroring `MarqueeMathTests`, plus the `marqueeAutoPanVelocity`
  ramp (zero in the clear, signed per edge, both-axis corner, ramp + clamp).
- The `.marquee(hits:base:)` reducer union was already covered by PR 1's
  `CanvasSelectionTests`; the NSView-level gesture plumbing stays untested by
  design (the pure statics — threshold, hit-test, auto-pan ramp — carry the logic).

## Migration notes

- **No schema, service, or public-API change.** `tiles(inWorldRect:)` is an
  additive engine method; everything else is host-internal.
- Full CanvasRenderer suite: 144/144 pass (130 + 14). `AtelierRefs` scheme builds.
