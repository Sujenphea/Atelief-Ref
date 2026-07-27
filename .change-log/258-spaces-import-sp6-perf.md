# 258 — Spaces import: SP6 perf verification (100-image drop)

Phase SP6 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
the 15A measurement pass. Verification, no new machinery.

## The concern (15A)

Point placement lands imported tiles **on-screen** (unlike the flow-below add), so
a 100-image drop could in principle burst 100 simultaneous thumbnail decodes and
spike memory / frame time.

## The finding: bounded by the existing culler — no throttle needed

Imported items are ordinary `space_item`s rendered by the SAME `SpaceContent` →
`CanvasEngine` path as any board, so the existing `TileCuller` + `DecodeScheduler`
already bound the working set to what's VISIBLE. A 100-image drop is
indistinguishable, at the render layer, from opening any 100-tile board — which the
app already handles. `insertPlaced` adds **no** bespoke throttle, and none is
warranted.

Pinned by an automated culling test (`SpaceImportPerfTests`), constructing a
`CanvasEngine` over a real 100-tile `SpaceContent`:

- **Normal viewport (1280×800):** 100 tiles placed, but `activeLayerCount < 100` —
  only the viewport-visible slice activates (→ bounded decode).
- **Whole-block viewport (4000×6000):** `activeLayerCount == 100` — proving the
  small-viewport bound is real *culling*, not an artificial cap.

## Files changed

- `AtelierRefs/AtelierRefsTests/SpaceImportPerfTests.swift` — new culling
  verification (100-tile `SpaceContent` through `CanvasEngine`).

## Migration notes

None. No source change — SP6 confirms the shipped render path already bounds a
large on-screen import. Should a real spike ever surface (e.g. a decode storm on a
very dense block), the escalation point is the shared `DecodeScheduler`, not the
import path.
