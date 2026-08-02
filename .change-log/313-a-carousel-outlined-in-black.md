# 313 — A selected carousel was outlined in black

## Summary

In a collection, selecting a collapsed carousel tile drew it outlined in **black**
while every ordinary tile drew outlined in **white**. The white ring was still there —
it had just been left hugging the inset artwork while its dark backing hairline was
laid out against the cell's OUTER bounds, so the thing at the tile's edge, the thing
that reads as "the outline", was the black one.

## Cause

A selected cell draws two concentric strokes: `selectionRingLayer` (white,
`Theme.NS.selectionMark`) and `selectionContrastLayer` nested just inside it — 2pt of
half-opaque black, so the edge survives a pale photo the same way the white survives a
dark one. They are only ever *seen* as one border because the inner one is derived from
the outer one's rect.

Since 307 a collapsed post insets its artwork to make room for the fanned pile behind
it, and all the cell's chrome tracks that inset rect (`contentRect`) rather than
`view.bounds`. `viewDidLayout` does this correctly for both layers. But
`applySelectionState` — the layer-only path the coordinator calls on a selection change
— re-placed the hairline against `view.bounds`:

```swift
layOutContrastHairline(in: view.bounds)   // was
layOutContrastHairline(in: contentRect)   // now
```

For an un-fanned tile the two rects are identical, which is why this was invisible
everywhere except on a carousel. For a fanned one the inset is 5–12pt depending on the
cell's aspect ratio (`fanPileGeometry`), so the black hairline sat that far OUTSIDE the
white ring, as a rectangle around the whole cell rather than a lining inside the ring.

Nothing corrected it afterwards. Selection is deliberately layer-only — no relayout, no
snapshot, that being the thing that keeps multi-select smooth (036 §4 A2) — so no
`viewDidLayout` follows a selection change to re-place it. The misplacement persisted
until some unrelated layout pass, e.g. a scroll or a window resize.

## Also fixed

`setPostMemberCount` placed the `⧉ N` chip from `view.bounds` too, so a fanned cell put
its chip in the cell's corner instead of the artwork's. That one *was* self-correcting —
the method sets `view.needsLayout`, and `viewDidLayout` re-places the badge from
`contentRect` — but not before the current frame drew it in the wrong corner. Both call
sites now read `contentRect`.

`showCard` / `showGif` also assign `view.bounds`, and are left alone: those are
first-mount frames on subviews that carry `autoresizingMask` and are re-framed from
`contentRect` on the next layout, which is guaranteed to run before either can be seen.

## Files changed

- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — `applySelectionState` and
  `setPostMemberCount` place their layers from `contentRect`, not `view.bounds`.

## Verification

`xcodebuild -scheme AtelierRefs -destination platform=macOS build` — **BUILD SUCCEEDED**.

Not verified in the running app: the fix is a one-rect substitution on a path with no
test coverage (nothing currently pins the contrast hairline's placement — see below), so
what it actually looks like on a selected carousel over real artwork has not been
watched.

## Still to do

The hairline's placement is unpinned in either direction. `pileNeverClips` (307) pins
the pile's geometry against the cell's rounded rect, but no test asserts that the two
selection strokes stay concentric — which is exactly the invariant that broke here, and
it broke on the ONE code path where the two rects differ. A test that selects a fanned
cell and checks `selectionContrastLayer.frame` is contained by `selectionRingLayer.frame`
would have caught it and would catch the next chrome layer that forgets the inset.
