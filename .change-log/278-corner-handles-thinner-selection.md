# 278 — Corner-only handles, none while editing, thinner selection

## Summary

Selection chrome on the canvas slims down to match the reference look:

- **Only the four corner dots are drawn** on a selected box. The mid-edge handles
  (top / right / bottom / left) keep their grab zones — an edge drag still
  resizes one axis — but no longer draw a dot, which used to sit on top of the
  text in a short box.
- **The box being edited draws no handle dots at all.** Resize-while-editing
  (062) still works through the reduced `editingHitSize` grab zones; it is
  undrawn, not gone.
- **The selection border thins from 3pt to 1.5pt**, matching the handle dots'
  own border weight.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `updateResizeHandles` draws corners only and bails for `editingTileID`;
  `makeSelectionLayer` border 3 → 1.5.
- `CanvasRenderer/Tests/CanvasRendererTests/EngineResizeTests.swift` — handle
  counts 8 → 4, live-drag dot assertions moved to corners, new test pinning
  "editing hides dots, keeps grab zones".
- `CanvasRenderer/Tests/CanvasRendererTests/SelectionTests.swift` — stale
  "eight handles" comment.

## Migration notes

- `ResizeGeometry` (the eight-zone hit-testing and resize math) is unchanged —
  only the *drawing* narrowed. `resizeHandleCount` now reports 4 for a selected
  box and 0 while it is being edited.
