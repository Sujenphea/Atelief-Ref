# 276 — Text boxes hug their text

## Summary

A click-placed text box used to be born 260 world units wide — a literal nobody chose —
so the first thing a short label did was wrap inside a box three times wider than it
needed. A text box can now derive its own width.

- **Click the text tool** → the box is born snug around its text and grows sideways as
  you type.
- **Drag the text tool** → fixed at the width you dragged. You chose it.
- **Width [ Auto | Fixed ]** in both the format bubble and the inspector.
- **Drag a side handle on a hugging box** → it becomes fixed at the width you dropped.

## Reversing a documented decision

062 considered auto-width and rejected it, because with no picker the mode would be
reachable only by gesture — *"a hidden consequence of an action rather than a state the
user can see"*. That was right at the time: the inspector's picker had just been deleted
and the format bubble did not yet exist in its current form. The Width control is the
condition 062 named, so the decision is **answered rather than overruled**, and 062
carries an amendment block saying so.

062's actual invariant is untouched: **the height is always derived from the text and is
never the user's to set.** Auto-width extends that reasoning to the width for boxes that
opt in.

## The legacy field stays inert

`ElementStyle.resizeMode` still carries `fixed` / `autoWidth` / `autoHeight` from before
062. It was **not** revived. Pre-062 `.autoWidth` rows are precisely the runaway
single-line boxes 062 removed, so giving that string meaning again would re-flow existing
boards on load. A new `textAutoWidth` flag starts every existing row at `false`, and a
test pins that a row carrying the legacy token still reads as not hugging.

## One copy of each rule

The width rule and the anchoring rule both ended up in the **renderer**, not the app
layer where the plan put them. The inline editor lives inside `CanvasRenderer` and needs
both to derive the live box, so an app-layer copy would have had a renderer twin — two
answers to "how wide is this box", which is the drift 060 exists to prevent.

The editor anchors on the tile's **committed** frame via a new
`CanvasEngine.storedWorldFrame(forTileID:)`, never on its displayed one. `reposition()`
runs per keystroke and the displayed frame already includes the editor's own override, so
anchoring there would compound into a centred box crawling sideways.

## Conversion is one undo step

A side drag on a hugging box changes both style and geometry, so it routes through
`applyRestyle` — which already folds the two into one entry — rather than the
placement-only path plus a second registration. Two entries would mean two ⌘Zs to undo
one drag, with a half-converted box in between. A `.top` / `.bottom` drag changes no
width and leaves the box hugging.

## A width cap, deliberately unlike Figma

`TextMetrics.maxAutoWidth` = 1200 world units. Figma grows without limit; text arrives
here by paste as often as by typing, and an unbounded hug turns a pasted paragraph into
one line tens of thousands of units wide. Past the cap the box wraps and grows downward
**while staying flagged auto**, so deleting text lets it hug again — a safety valve, not
a second mode.

## The risk that didn't bite

The plan rated one risk *"high if it bites"*: the measurement is CoreText's and the
editor's layout is TextKit's, and a disagreement would show as the last word jumping to a
second line mid-typing. 067 had already measured 0/384 line-break disagreements between
the engines, and `TextAutoWidthTests` pins the arithmetic itself — measure → +2·padding →
re-shape at that width — across strings including an unbreakable token and CJK. Both
pass, so the planned 1pt container-slack fallback is not in the build.

## Files changed

- `AtelierCore/.../SpaceItem.swift` — `textAutoWidth`, `hugsWidth`
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `autosizedFrame` branch, `addText` birth
  state, `resizeTile` conversion, `refitTextRows`
- `AtelierRefs/AtelierRefs/ElementRendering.swift` — carry the flag into `TextStyle`
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift`, `ElementInspector.swift` — Width
- `CanvasRenderer/.../TextMetrics.swift` — `maxAutoWidth`, `size(for:hugging:outerWidth:)`
- `CanvasRenderer/.../TileContent.swift` — `TextStyle.hugsWidth`
- `CanvasRenderer/.../Host/CanvasEngine.swift` — `editingWorldSpan`, `setEditingBoxSpan`,
  `storedWorldFrame`
- `CanvasRenderer/.../Host/CanvasTextEdit.swift` — `canvasInlineEditorAnchoredMinX`,
  the world box's width branch
- `CanvasRenderer/.../Host/CanvasTextEditController.swift` — the `reposition()` branch
- `CanvasRenderer/.../Host/CanvasHostView.swift` — a click reports an origin-only rect;
  `defaultTextWorldWidth` / `defaultTextWorldHeight` deleted

## Migration notes

None. Every existing row decodes with no `textAutoWidth` key, reads `false`, and behaves
exactly as before. Only newly click-placed boxes are born hugging.

## Tests

851 app tests, 390 renderer tests, 553 core tests. New: `SpaceTextAutoWidthTests` (19),
`TextAutoWidthTests` (9), plus `ElementStyleTextTests` +4 and `EngineResizeTests` +7.
`SpaceTextResizeTests` — 062's whole contract — passes unchanged, which is the point:
auto-width is opt-in. Full write-up in `.docs/063-spaces-text-autowidth-plan.md`.
