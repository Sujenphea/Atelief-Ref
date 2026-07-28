# 263 — The text box grows on the canvas as you type

## Summary

Typing in an inline editor grew the editor's own `NSTextView` but left the box on
the canvas at its committed height, so the glyphs grew out through the box's own
border and handles and only snapped into place on commit.

This one was deliberate, and is stated in the code it lived in:

```swift
/// Editor-only live growth for auto modes — re-place from the new string; no
/// engine sync per keystroke (§5.2 · R16 / R14).
func textDidChange(_ notification: Notification) { reposition() }
```

Under the three-way resize modes that was the right call: a `.fixed` box's
height belonged to the user and had no business chasing the text, so keeping the
canvas out of the keystroke path cost nothing. **062 removed that premise.** A
text box's height is now *derived* from its text, so a box that doesn't grow as
you type is displaying a size that stopped being true at the first keystroke.

## Fix

`CanvasEngine.setEditingBoxHeight(_:)` — a transient height for `editingTileID`,
applied in `displayWorldFrame`. The editor pushes its measured world height from
`reposition()` (so it stays in step whatever caused the reposition: typing, a
pan/zoom, a resize drag) and clears it on `finish` and on `dismantleNSView`.

Height only, and applied **after** the drag/resize overrides. That ordering is
the 062 split made literal: the width is the user's — stored, or the one a handle
drag is setting right now — and the height is the text's, so while an editor
holds the text it holds the height. It also closes the gap 262 left open: a
resize *while* editing now takes its width from the drag and its height from the
string currently in the editor, not from the last committed one.

Deliberately not a provider mutation and not a write: nothing persists until the
edit commits, so an abandoned edit leaves no trace and the undo stack sees one
entry, not one per keystroke. Per-keystroke cost is a `CGFloat` compare, and on a
real change a `sync()` that relays existing layers — the edited tile's glyphs are
blanked, so nothing re-rasterizes.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `setEditingBoxHeight(_:)`, `editingWorldHeight`, applied in
  `displayWorldFrame`, dropped when `editingTileID` changes; `syncCount`
  introspection.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — forwards it.
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — `CanvasEditingBridge`
  forwards; `reposition()` pushes; `finish` / `dismantleNSView` clear.
- `CanvasRenderer/Tests/.../EngineResizeTests.swift` — 6 tests.

## Tests

The box is drawn at the height its editor asks for while the width is untouched;
handles follow the growing box; clearing restores the stored height; the height
does not outlive its edit; resize-while-typing composes width-from-drag with
height-from-text; and the same height twice does not re-sync. CanvasRenderer
**305 tests / 36 suites** green; `AtelierRefsTests` green.

## Migration notes

None. `setEditingBoxHeight(nil)` is the default state, so a host that never calls
it behaves exactly as before.
