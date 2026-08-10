# 364 — Zoom fills the pane

## Summary

Zooming into an image on the detail page enlarged it inside the window it occupied **at
fit**. The letterbox bars either side stayed empty however far you pinched, and the pane's
spare room was unreachable — a 3:2 photo in a 4:3 pane could only ever be inspected
through a 3:2 hole.

## Cause

One line, at the end of `ZoomableImage.body`:

```swift
image
    .resizable()
    .aspectRatio(contentMode: .fit)   // layout bounds become the FIT rect
    .scaleEffect(zoom * pinch)        // render transform — bounds unchanged
    .offset(…)
    .contentShape(Rectangle())
    .clipped()                        // clips to that same FIT rect
```

`.aspectRatio(contentMode: .fit)` does not merely letterbox the drawing: it makes the
view's **layout bounds** the fitted rect. `scaleEffect` and `offset` are render-time
transforms and never widen them. So by the time `.clipped()` runs, the rectangle it clips
to is still the one the picture had before it was scaled.

It is the geometry [`fitRect`](../AtelierRefs/AtelierRefs/ItemDetailView.swift) describes
and the fan pile is *deliberately* laid against (080 §3.2) — the zoom was laid against it
by accident.

Same line, second symptom: `.contentShape(Rectangle())` sat on that fitted frame too, so a
pan drag that BEGAN in the letterbox bars missed the image entirely.

## The fix

**The clip moves out to the pane**, rather than being deleted. Deleting it would spill the
artwork over the sidebar and the top bar, which is the job it was doing one level too far
in.

```swift
mediaArea
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()                     // ← the surface zoom grows across
    .background(alignment: .center) { fanPile }
    .background(Theme.Colors.mediaBackdrop)
    .overlay(alignment: .center) { fanSpread }
```

It goes **before** the backgrounds and overlays deliberately: each is added after the clip
and so escapes it, which preserves the pile's 12pt swing-out past the artwork (080 §3.4).

`ZoomableImage` keeps a frame, for the second symptom:

```swift
.offset(…)
.frame(maxWidth: .infinity, maxHeight: .infinity)
.contentShape(Rectangle())
.gesture(magnify)
.simultaneousGesture(dragToPan)
```

The content shape and the gestures move **after** it, so a pan begun in the letterbox bars
now lands on the picture.

**The FIT inset is untouched.** `mediaArea`'s `lg` padding is inside the new clip, so the
picture is still fitted into `pane − 32`, and the pile, the spread and the zoom controls
(`:404`) still align to that same rect (`mediaContentSize`). Only the GROWING no longer
stops there — a zoomed image runs to the dividers. At `zoom == 1` nothing moves at all.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — the clip moves from `ZoomableImage.body`
  up to the media pane in `body`; `ZoomableImage` keeps a filling frame + content shape

## Notes

**No tests.** The defect is WHICH VIEW owns the clip — which rectangle SwiftUI hands to
`.clipped()` — and there is no pure function in it to pin. A test asserting the modifier
order would restate the source. 363 already recorded the sibling lesson: a passing test
aimed at the wrong rectangle reads as coverage without being any.

**A 16pt ring the pan cannot start in.** `ZoomableImage`'s content shape fills the INSET
box, not the pane, so a drag begun in the outermost 16pt of a zoomed picture does not grab
it. Not a regression — that shape was the fit rect before this, which is smaller still —
and closing it means threading the inset through the view so it can cancel it, for a strip
at the extreme edge of the window. Left, deliberately.

**Still open: pan is unclamped.** `maxZoom` bounds SCALE, not translation, so a zoomed
image can still be shoved mostly out of view; double-tap-to-reset is the only recovery.
The fit-sized clip was masking how far it went, and a full-pane surface makes it plain.
A clamp keeping the scaled rect covering the pane belongs beside `fitRect` as a pure
function with its own tests — deliberately held back to its own change.

No migration.
