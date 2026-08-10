# 363 — The arc is where you press it

## Summary

The spread drew along the bottom of the picture while the thing that responded to the
pointer stayed in the middle of it. Hovering the centre of an image opened the arc;
pressing the arc did nothing; and with the arc unpressable, [362](./362-drag-along-the-arc.md)'s
scrub could not start at all.

## Cause

[361](./361-the-arc-finds-the-bottom-edge.md) fixed the arc's *position* by computing an
offset. It moved the pixels and left the target behind:

```swift
.frame(width: fitted.width, height: zoneHeight, alignment: .bottom)
.offset(y: fanSpreadZoneOffset(...))     // renders at the bottom
.contentShape(Rectangle())               // …hit-tests at the centre
.onHover { isSpreadHovered = $0 }
```

`contentShape` applied after `offset` defines the hit region in the view's
**untransformed** space. So the zone rendered at the offset position and tested for hits
at its layout position — two rectangles that the code never says are different, and that
no test could catch, because the arithmetic 361 added was *correct*. It was answering a
question that had stopped being the right one.

## The fix

Stop computing the position. The zone now sits at the bottom of a box the size of the
fitted artwork, pushed there by a `Spacer`:

```swift
VStack(spacing: 0) {
    Spacer(minLength: 0)          // no content shape — the upper picture stays the artwork's
    zone.frame(height: zoneHeight).contentShape(Rectangle()).onHover { … }
}
.frame(width: fitted.width, height: fitted.height)
```

Layout frame, pixels and hit region are one rectangle by construction. There is no
arithmetic left to be right or wrong.

The one remaining `offset` is the arc's open/closed slide, and it is safe for a reason
worth stating: it is **zero whenever the arc is interactive** (`allowsHitTesting(open)`),
so the drawn arc and the hittable arc can never disagree — only the closed,
hit-transparent one is displaced.

## What this deletes

`fanSpreadZoneOffset(fittedHeight:zoneHeight:)` and its `FanSpreadZoneTests` suite, both
added by 361. The invariant they existed to protect — *the zone's bottom edge is the
artwork's bottom edge* — is now true by layout rather than by calculation, and a passing
test for a function nothing calls is worse than no test: it reads as coverage.

Losing them is not a regression in rigour. 361's tests proved the arithmetic; they could
not prove the arithmetic was being applied to the right rectangle, which was the actual
defect both times.

## The lesson, since this is twice

Two bugs in the same fifteen lines, both from positioning by calculation rather than by
layout:

| | wrote | needed |
|---|---|---|
| 361 | the letterbox gap | the distance to the artwork's bottom edge |
| 363 | a correct offset | no offset at all |

A computed position can disagree with a drawn one, and a drawn one can disagree with a
hittable one. A laid-out position cannot do either.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `fanSpread` restructured; the offset
  helper removed.
- `AtelierRefs/AtelierRefsTests/DetailFanSpreadTests.swift` — `FanSpreadZoneTests` removed.

Full `AtelierRefsTests` target: **TEST SUCCEEDED**, 0 failures, 26 spread cases passing.
