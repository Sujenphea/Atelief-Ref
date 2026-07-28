# 262 — Resizing a text box while editing it re-wraps the text

## Summary

Dragging a resize handle on a text box that is **in edit mode** moved the box,
its border and its handles live, while the text inside stayed laid out for the
old width — so the box narrowed and the text spilled out of it and never
re-wrapped.

The root cause is a seam, not a shaping bug. Two facts about editing combine:

1. While `editingTileID` is set, the engine **blanks that tile's `CATextLayer`**
   (054 §5.2) so the `NSTextView` overlay above it isn't doubled. Every part of
   the 062 live-resize path — `fittedFrame`, the `displayWorldFrame` shaping
   width, dropping `maxHeight` — draws through that layer, so for the tile being
   edited **all of it is inert**. The glyphs on screen are the editor's.
2. The editor places its overlay imperatively from the tile's on-screen frame,
   and its only trigger to do so again was `onTransformChanged` — which fires
   from `pan` / `zoom` / `setTransform` and nothing else. A resize moves the box
   with the **camera standing still**, so the editor was never told.

The handles are offered on the edited tile (`handleTile` doesn't consult
`editingTileID`), and `PassThroughContainer.hitTest` returns `nil` for its own
area, so a press on the outer half of a handle falls through to the canvas and
starts the resize. Nothing prevented the gesture; only the notification was
missing.

## Fix

A second notification, `CanvasEngine.onLiveFrameChanged`, fired from
`updateResize` (every tick) and `endResize` (the commit), forwarded through
`CanvasHostView` and `CanvasView` and wired in `SpaceView` alongside the
transform one. Both land on `CanvasEditingBridge.geometryDidChange()` — renamed
from `transformDidChange()`, because the editor doesn't care *why* the frame
moved, only that it did. Its `reposition()` already re-measures the current
string against the tile's width, so the re-wrap follows for free.

Kept as a **separate** callback rather than firing `onTransformChanged`: the
camera genuinely did not move, and a notification that lies about its cause is
worse than a second one. `TransformSeamTests`' "exactly once per mutation" pin
stays true.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — new
  `onLiveFrameChanged`; fired in `updateResize` / `endResize`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — forwards it.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — new
  `onLiveFrameChanged:` parameter (defaults to `nil`; existing call sites
  unaffected).
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — `transformDidChange()` →
  `geometryDidChange()`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — both wires into the bridge.
- `CanvasRenderer/Tests/.../EngineResizeTests.swift` — new
  `EngineEditingResizeTests` (4 tests).

## Tests

`EngineEditingResizeTests` pins the two facts that make the seam load-bearing —
the edited tile still offers handles, and it draws no glyphs of its own — then
the notification itself: every tick plus the commit; the frame a listener reads
mid-drag is the live one, not the stored one; and a pan/zoom does **not** fire
it. CanvasRenderer 299 tests / 36 suites green; `AtelierRefsTests` green.

## How this was found, and a correction

Entry 261 claimed the truncation fix ("a text tile never truncates its
overflow") addressed this report. **It did not** — the symptom was unchanged,
because that fix lives on the glyph path, which is switched off while editing.
Two things falsified the earlier diagnosis outright:

- Rendering a `TextRenderLayer` into its own backing store showed truncation was
  never the visible mechanism anyway: a stale-height box shaped 2 lines into a
  16pt layer and drew **1 ink row**. Core Animation clips at the layer's bounds,
  so removing `maxHeight` changed nothing on screen. 261's tests asserted
  `shaped.lines.count` — the *layout* — not what is drawn.
- The live board's three text rows measured **exactly** their derived heights
  (`STALE=false`), and the app binary that produced them postdates 261. So
  nothing persisted was stale, and the migration 261 added, while correct, was
  not what was being reported either.

That is the third time in this feature a suite has been green over a real defect
by asserting a model value where the question was about pixels or about a seam.

## Known gap (not fixed here)

While editing, the engine's `fittedFrame` derives the box height from the
**committed** style, not the editor's uncommitted string. If you type and then
resize without committing, the selection border and handles size to the old
text while the editor's glyphs size to the new. The visible text is correct
either way; only the chrome around it can disagree, and only until commit.
Fixing it means giving the engine the live string, which the app owns.

## Migration notes

None. `onLiveFrameChanged:` defaults to `nil`, so any host that ignores it
behaves exactly as before. The bridge rename is app-internal.
