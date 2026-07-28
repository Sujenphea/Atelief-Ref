# 264 — Floating format bubble + one-click colour palette

## Summary

Formatting a text box meant selecting it, finding the slider glyph in the bottom
action bar, opening a 280pt form, changing one control, and dismissing it. Nook
puts the same controls where the text is: a palette of eleven colours above the
box and a font/size bubble below it, both floating, both one click. This ports
that, and closes the last open item of 062.

**Palette** — the eleven `EaselColor` values as our hex strings, one click to
recolour. A ring marks the box's current colour; an off-palette colour (set
through the inspector's `ColorPicker`) rings nothing rather than the nearest dot.

**Bubble** — `Aa` opens font family + weight + alignment; the point size opens the
preset list with a check on the current one. Nook's popover is Bold / Italic /
Underline because its style carries traits; ours carries a four-step `TextWeight`
and a `TextAlign` (054 §1.1), so the same shape is expressed in what our model
actually stores. The full-fidelity colour well and the frame controls stay in
`ElementInspector` — this is the fast path, not a replacement.

Both target the box being **edited**, else the sole selected `.text` element.

## Where it lives, and why not where Nook puts it

Nook draws both panels into its canvas `NSView` and routes clicks by hit-testing
rects in `mouseDown`. Ours are SwiftUI over the renderer: `CanvasRenderer` has no
business knowing what an `ElementStyle` is, which is the seam the inline editor
already respects. What carries over unchanged is the geometry — palette above,
bubble below, each flipping to the other side at a viewport edge and stepping past
the other when both want the same side. That math is pure
(`SpaceTextChromeLayout`) and tested directly, because all three ways a floating
panel goes wrong happen at edges, which is where they are hardest to catch by hand.

The panels are **fixed screen size**: 30pt tall at every zoom, because they are
chrome, not content — the same split 060 draws between world layout and screen
rasterization.

## Tracking the box

`SpaceTextChromeAnchor` republishes one `CGRect` and only the two panel views
observe it, so a pan / zoom / move / resize never re-evaluates `SpaceView.body`
(the editor's D6 · R15 posture). It is poked from the two geometry notifications
the editor already listens to, plus `renderRevision` — a restyle re-derives the
box's height in place, so the chrome has to re-read the frame it just changed.

That exposed a gap in the renderer: `onLiveFrameChanged` fired for a resize drag
but not a move drag, so chrome anchored on a dragged tile would detach and snap
back at the drop. `updateDrag` / `endDrag` now fire it too — `endDrag` only when a
drag was actually running, so an ordinary click stays silent.

## Formatting mid-edit

A click on the chrome may blur the editor first, which commits the edit — the same
thing Nook's bubble does. The target is therefore resolved at click time from
`editingTileID` **else** the selection, and both resolve to the same row, so the
format lands where the user aimed it either way.

If the edit does survive the click, the restyle arrives while the `NSTextView` is
live, so `InlineTextEditor` now re-applies typography when the style moves —
guarded on a snapshot, so an unchanged style doesn't reset the font (and with it
the typing attributes) on every SwiftUI update. The restyle writes the STORED
string, never the one being typed: a restyle followed by Esc must still abandon
the edit. The box's height stays honest meanwhile because the editor's height
override is applied last (263).

## Files changed

- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — new: `TextPalette`,
  `SpaceTextChromeLayout`, `SpaceTextChromeAnchor`, `SpaceFormatChrome` + the two
  popovers.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `formatTarget(in:)`, mounts the
  chrome above the editor, refreshes the anchor from the geometry notifications.
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — `applyTypographyIfChanged()`.
- `AtelierRefs/AtelierRefs/ElementInspector.swift` — `TextAlign.symbolName` is now
  shared with the bubble rather than private to the inspector.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `onLiveFrameChanged` fires for a move drag.
- `.../EngineResizeTests.swift` — 3 tests; `AtelierRefsTests/SpaceFormatChromeTests.swift`
  — 13.

## Tests

Placement: palette above / bubble below / centred; neither over the box; flip at
the top and bottom edges; clamped at either side; the two collision cases; and a
sweep of ~500 box positions asserting the panels never overlap anywhere. Palette:
eleven parseable, distinct swatches; a stored colour matches its swatch in any hex
form it may have been written in (`#ff5a5f`, `ff5a5f`, `#FF5A5FFF`); an
off-palette colour — including one channel step off — matches nothing; alpha
counts. Renderer: every drag tick notifies, the drop notifies, a click does not,
and the mid-drag frame is the offset one. CanvasRenderer **308 tests / 36 suites**
green; `AtelierRefsTests` green.

## Outstanding — manual check

**Not yet performed:** select a text box and confirm the palette and bubble appear
above and below it, that they track a pan / zoom / drag / resize, that a swatch
recolours in one click and one ⌘Z, that the size presets and the font popover
apply, and that the panels flip rather than leave the viewport near its edges.

## Known gaps

- **Text only.** A frame carries a fill and a stroke, and "recolour" doesn't say
  which — Nook's shapes have one colour, ours have two. Frames keep the inspector.
- **No multi-selection formatting.** Nook's palette recolours the whole selection;
  ours targets a single box, matching where `SpaceModel.updateStyle` writes today.
- **A click on the chrome ends an open edit** (as Nook's does), costing a second
  undo entry and the caret position. Keeping the edit alive needs the panels in a
  non-activating window.

## Migration notes

None. New chrome only; nothing persisted changed, and `ElementInspector` is
untouched apart from the shared symbol name.
