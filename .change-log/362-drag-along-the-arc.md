# 362 — Drag along the arc

## Summary

The spread ([360](./360-the-pile-opens.md)) could only be clicked, one card at a time.
Now you can press and drag along it: the raise follows the pointer, the page previews
each member as you pass it, and release leaves you on the one you stopped at.

Clicking still works and is unchanged.

## Why the slot is not a hit test

The cards **overlap** — `cardSpacing` (52) is narrower than `cardSide` (64), which is
what makes the arc read as a fanned deck rather than a row of thumbnails. So "the card
under the pointer" cannot be a hit test against drawn bounds: in an overlap, two cards
answer yes, and which one wins is a z-order accident rather than a decision.

`fanSpreadScrubSlot(x:pitch:count:)` maps the pointer to the SLOT its x falls in, at the
spacing's pitch. Monotonic by construction, which is the property a scrub actually needs:
dragging one way must never step back, or the raise stutters under a steady hand.

Clamped at both ends rather than optional — a drag that runs off the arc holds the end
card, the way a scrubber holds its end, instead of blinking out.

## A slot is not a member

The load-bearing distinction, and the one that would have broken the feature quietly:
a slot indexes the **window**, not the post. For any post past the cap those differ by
the window's start — walking a 15-image post to image 12 gives a window of `8…14`, where
slot 0 is member 8. Conflating them would scrub to the wrong image on exactly the long
posts the spread exists for. `slotResolvesThroughTheWindow` pins it, asserting `8` and
`14` rather than `0` and `6`.

## Cost

The jump fires when the member under the pointer **changes**, not per pixel. A sweep
across seven cards therefore costs seven steps — precisely what holding → down already
costs, so `DetailSession`'s LRU and the loader's bucket quantization are the same defences
the walk already relies on. Per-pixel would have been a decode storm.

## The raise is local as well as jumped

`scrubbed` holds the member under the pointer for the duration of the gesture, and the
raise reads `scrubbed ?? post.index`. The jump goes out to the host, which reloads and
returns through `post.index` a beat later; a card that lifted one frame behind the finger
would feel broken in the one gesture meant to feel direct.

## Click and drag together

The gesture is `.simultaneousGesture` with `minimumDistance: 6`, so below the threshold
the card's own `Button` owns the event — keeping its focus ring and accessibility action —
and above it the scrub does. At the end of a scrub the button that fires is the card the
pointer is over, which is the member already jumped to, so the overlap is idempotent
rather than a double-step.

## Tests

`FanSpreadScrubTests` — 6 cases: each slot's span maps to itself; the mapping is monotonic
across the whole arc; both ends clamp; a short arc clamps to its own last card rather than
the cap; degenerate inputs (zero count, zero pitch, NaN, infinity) yield no slot rather
than a crash; and a slot resolves through the window to the right member.

Full `AtelierRefsTests` target: **TEST SUCCEEDED**, 0 failures.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `fanSpreadScrubSlot(...)`, the arc's
  coordinate space, the scrub gesture, `scrubbed`, and the raise reading it.
- `AtelierRefs/AtelierRefsTests/DetailFanSpreadTests.swift` — `FanSpreadScrubTests`.

## Not verified

The **feel** — whether 6pt is the right threshold between a click and a drag, and whether
previewing on every card crossed is responsive or thrashy on a cold post. Build and unit
tests only.
