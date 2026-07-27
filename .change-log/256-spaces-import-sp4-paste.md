# 256 — Spaces import: SP4 paste (⌘V) onto a board

Phase SP4 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
⌘V on a focused Space canvas pastes external content (image / file / URL) into
Unsorted and places it at the viewport centre, through the SAME import path as a
drop (SP3). The small phase: mostly reuse.

## Summary

- **Responder-chain paste (mirrors ⌘C / 236).** `CanvasHostView` gains an `@objc
  paste(_:)` action + an `onPaste` seam. Because it rides the responder chain, a
  focused text field (e.g. the inline text editor) still gets ⌘V first — the canvas
  only pastes when IT holds focus. Enabled via `NSUserInterfaceValidations` when a
  handler is wired.
- **Viewport-centre placement.** A paste has no cursor point, so the host computes
  the world point at the viewport centre through the shared `CanvasTransform`
  (no drift), and hands it to `onPaste`. `CanvasView` exposes the seam.
- **Shared import path (DRY).** `SpaceView.importExternal(from:at:)` is now ONE
  method used by BOTH the external drop (SP3) and paste: decode the pasteboard →
  route → ingest into Unsorted → place centred on the point. Drop reports an
  unreadable drop; paste with nothing importable is a silent no-op.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `onPaste` +
  `@objc paste(_:)` + validation.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — `onPaste` exposed.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `importExternal(from:at:)` extracted
  (shared by drop + paste); `onPaste` wired.
- Tests: `CanvasRenderer/Tests/CanvasRendererTests/PasteSeamTests.swift` —
  viewport-centre mapping, no-handler no-op, Paste menu validation.

## Migration notes

None. No schema change. The external-drop behaviour is unchanged — it just calls
the same extracted `importExternal` the paste path does.

## Unrelated pre-existing test note

`CanvasBenchmark.testVectorElementsWithinBudget` fails at the current HEAD
(`activeLayerCount` 0/30, expected > 50 — "benchmark must run over real content"),
independent of this change (verified by running it with SP4 stashed). It builds a
`CanvasEngine` directly and touches none of the paste/drop seams. Likely a
regression from the committed restyle-in-place / text-render work (vector elements
producing no active layers) — worth a separate look. `testFrameUpdateWithinBudget`
is a wall-clock budget that only fails under CPU contention (passes idle).
