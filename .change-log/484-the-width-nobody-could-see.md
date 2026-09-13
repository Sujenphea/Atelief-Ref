# 484 — the width nobody could see

## Summary

Type into a new text box, press **Fixed** in the format bubble without dismissing,
keep typing, then dismiss. The box commits as **8 × 441** — a one-line caption
wrapped into a column eight world units wide.

The cause is a seam, not an arithmetic slip: **while a box hugs its text, the
width on screen exists only in the renderer.** `CanvasEngine.setEditingBoxSpan`
is documented as writing no row ("deliberately NOT a provider mutation and NOT a
write"), so until the edit commits, the model's width is whatever the box was
*born* at. `ElementStyle.textAutoWidth = false` then asks `autosizedFrame` for a
width, and with `hugsWidth == false` its answer is "the width you already have" —
the birth width.

Measured, on a click-placed box holding `"Hello world this is a caption"`:

| | stored | on screen |
|---|---|---|
| after typing | 8 | 207 |
| after Fixed | **8** | 207 (stale span) |
| after dismiss | **8 × 441** | 8 × 441 |

Only **auto → fixed** is destructive. Fixed → auto self-heals, because the commit
re-derives the hugging width from the real text.

## Why nobody saw it coming

`reposition()` set the auto-width span inside `if style.hugsWidth` and had no
`else`. So when hugging turned off, the span was never cleared: the override
outlived the mode that justified it. The canvas kept drawing — and `reposition()`
kept wrapping to — the hugged width, long after the model had been given a
different one. Everything looked correct right up until `editingTileID = nil`
dropped the span, at which point the box snapped to a width nobody had ever seen.

An invisible corruption that only surfaces on dismiss is worse than a visible
one, so the clear now runs **before** the frame is read, and the rest of the pass
measures against the width the box actually has.

## The fix — `LiveEdit`, and a third frame accessor

`CanvasEngine` had `storedWorldFrame` (what the model has) and `screenFrame`
(that, under the camera). The missing one is what the user can actually see:

```
storedWorldFrame(forTileID:)   // committed
liveWorldFrame(forTileID:)     // + drag / resize / editor overrides   ← new
screenFrame(forTileID:)        // + camera
```

Paired with `CanvasHostView.liveEditingText(forTileID:)`, that gives the app the
two facts the model cannot have mid-edit: the frame the box is drawn at, and the
string the text view holds. `SpaceModel.LiveEdit` bundles them, because they are
useless apart, and `updateStyle(itemID:style:live:)` anchors on them. The bubble
is only ever up while a box is being edited, so `SpaceView` always passes it.

**There is a precedent this should have followed from the start.** `resizeTile`
already handles the *other* route out of hugging, and handles it correctly — it
freezes the **dragged** rect, and `displayWorldFrame` guards
`tile.id != resizeTileID` so the span cannot win during that gesture. The bubble
toggle is the second way to turn hugging off and it skipped that discipline.

### The hole the test found

The first cut still committed an 8pt box. `autosizedFrame` returns `nil` for "the
derived size already equals the one I was given", which without `live` correctly
means *nothing to write* — but with `live` the anchor is not the row, so "already
equals the anchor" is still news to it. The live width was being measured against
and then thrown away. `newPlacement` now falls back to the anchor when the anchor
itself differs from the row.

## Two things fixed alongside, both the same class

**Every mid-edit restyle measured stale text.** `updateStyle` called
`autosizedFrame` with `style.text` from the model, which by contract is stale
while an edit is open — so changing the point size of a hugging box wrote a width
measured from the *last committed* string. Masked on screen (the editor re-pushes
its span) and corrected on commit, but it put wrong geometry on disk and a wrong
entry in the undo stack. `live.text` now rides along on **both** sides of the
undo, so undoing a font change does not also undo the sentence being typed.

**An empty hugging box measured zero wide.** `TextShaper` substitutes a lone
space so an empty string keeps one line of *height*, but a space carries no
advance width — so a newly placed box was `2 × padding` = 8 units of pure inset
around a zero-width text container. `TextMetrics.minAutoWidth(forPointSize:)`
floors it at half an em, so the box is caret-sized and proportional to its own
glyphs. It also stops this bug's worst case being quite so violent.

## How 483 made it reachable

The defect is 063's, but neither half of it was reachable before 483:

- The Width control lived only in `ElementInspector`, behind the selection bar.
  Opening that popover blurs the text view, which **commits the edit** — so the
  model had the real text and a correct hugging width before the flip ever
  landed. 483 put the toggle in the format bubble, which is up *during* an edit.
- 483 also made a new box start empty, which took the frozen birth width from
  ~40 down to 8.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — `liveWorldFrame(forTileID:)`.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `liveWorldFrame` /
  `liveEditingText` passthroughs.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasTextEditController.swift` — clear the
  stale span before reading the frame; `currentText`.
- `CanvasRenderer/Sources/CanvasRenderer/TextMetrics.swift` — `minAutoWidth(forPointSize:)`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `LiveEdit`, `updateStyle(…live:)`, the
  anchor-vs-row fallback.
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — `SpaceTextChromeAnchor.liveEdit()`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — pass it on every bubble restyle.
- `AtelierRefs/AtelierRefsTests/SpaceTextAutoWidthTests.swift` —
  `SpaceTextLiveEditRestyleTests`, five cases.

## Migration notes

None — no schema change. Boards already carrying a box mangled by this keep their
stored width; it is an ordinary resize away from being right again.
