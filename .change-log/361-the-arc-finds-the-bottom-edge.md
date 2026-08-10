# 361 — The arc finds the bottom edge

## Summary

The spread ([360](./360-the-pile-opens.md)) opened over the **middle** of the picture
instead of along its bottom edge. One wrong length, in a view body, where nothing could
notice.

## The two lengths

The hover zone is centred on the media pane, and so is the artwork, so the two share a
centre. To sit the zone's bottom edge on the artwork's bottom edge:

```
offset = (fittedHeight − zoneHeight) / 2
```

What was written was:

```
offset = (paneHeight − fittedHeight) / 2      // the letterbox gap
```

Both compile. Both are, in English, "how the picture sits in the pane". And the wrong one
fails in a way that looks like a design choice rather than a bug: it is roughly right on a
heavily letterboxed image, and goes to **zero** exactly when the picture fills its pane —
which is when the arc appears dead centre over the photo.

## The fix, and why it is a function now

`fanSpreadZoneOffset(fittedHeight:zoneHeight:)`, pure and beside `fanSpreadWindow`.

The arithmetic is one line and the temptation is to leave it inline. But an inline
expression in a `body` cannot be wrong in a way a test notices — which is the whole reason
[080](../.docs/080-detail-fan-carousel-plan.md) §5 pulled `fitRect`, `fanSpreadWindow` and
the visibility predicates out in the first place, and the reason `fanPileGeometry`'s own
doc argues for purity: *"instead of being eyeballed at one cell size."* This one was
eyeballed at one aspect ratio.

## Tests

`FanSpreadZoneTests` — the invariant stated in pane coordinates: the bottom of the zone
and the bottom of the artwork are the same line, whatever the letterboxing. Parameterized
over a picture that fills its pane, a letterboxed one, a wide panorama in a tall pane, and
an artwork shorter than the zone itself.

Two of the four cases are named for what they would have caught:

- `fullBleedPictureIsNotCentred` — the regression exactly: no letterbox gap, so the old
  expression returned `0`.
- `shortArtworkNeedsNoOffset` — an artwork shorter than the zone gets a zone its own
  height, and two rectangles that already share a bottom edge need no push.

The test also asserts the answer does **not** depend on the pane height, which is the
property the old expression violated.

Full `AtelierRefsTests` target: **TEST SUCCEEDED**, 0 failures.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `fanSpreadZoneOffset(...)`; the
  `fanSpread` overlay calls it.
- `AtelierRefs/AtelierRefsTests/DetailFanSpreadTests.swift` — `FanSpreadZoneTests`.
