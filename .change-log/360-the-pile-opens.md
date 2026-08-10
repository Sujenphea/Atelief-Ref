# 360 — The pile opens

## Summary

The last piece of [080](../.docs/080-detail-fan-carousel-plan.md): hovering the bottom
strip of the artwork spreads the post into a shallow arc of its members, the open one
raised, click to jump. Increment 3 of §6, and the one the plan was least sure deserved
to exist.

## What it adds over the arrows

Nothing, in reachability — [316](./316-detail-arrows-walk-the-post.md) already made a
post contiguous in the run, so ← / → walks it. The spread makes that walk **visible**,
and adds random access to a member four steps away. That is the whole claim.

## The trigger is a zone, not the pile

070 §3.3 says "hovering the pile spreads it". On the page the pile is *behind* the
artwork — only a few points of tilted corner ever show, which is a mean target, and it
is deliberately hit-transparent ([357](./357-the-pile-follows-the-picture.md)) so it
cannot steal the drag-out.

So the trigger is the bottom 96pt of the **fitted** artwork: where a filmstrip would
live, big enough to find, and nowhere near the middle of the picture — a spread that
appeared on any hover would be in the way of looking at the image, which is the page's
actual job. The zone tracks the fitted rect, not the pane, so it sits on the picture's
own bottom edge when the image is letterboxed (313's rule again).

Gated on the same effective scale as the pile, reusing `showsFanPile` rather than
declaring a second rule: a zoomed page is for looking at one image, and a spread
inviting you elsewhere is noise there.

## The cap is said out loud

A rednote note runs to 15 images, and a 15-card arc is a layout problem before it is a
performance one. `fanSpreadWindow(memberCount:currentIndex:cap:)` draws at most
**7** and reports the rest as `+N` — surfaced, never silently dropped.

The window is centred on the open item and then clamped to the ends, which is the
load-bearing part: walking a 15-post to image 12 slides the window to `8…14` rather
than leaving it at `0…6`. A window that failed that would show a slice of a post the
user is not standing in — worse than showing no spread at all. `capIsOdd` pins the
seven: an odd cap puts the open item dead centre everywhere except the two ends.

## Cold by construction

A collapsed post renders only its representative in the grid, so every other member is
absent from `ThumbnailPipeline`'s cache — the spread is coldest on exactly the posts it
is most wanted for, and can open while `DetailSession` still has a full-res decode in
flight. The cap is the bound, and it is why there is no prefetch: the cheapest decode is
the one a closed spread never asks for.

Each card sizes its own decode via `thumbnailPixelBucket(pointLongSide:scale:)`, as
`FanCard.tile` does. `AsyncThumbnail.bucket` defaults to the 512 ceiling; for a 64pt card
that is sixteen times the pixels it can show, per card, on every cold spread.

A `nil` slot (359) draws a placeholder card, not a gap — the member is real, counted,
and can be jumped to.

## Tests

`DetailFanSpreadTests` — 20 cases, all pure, no view harness:

- **The window** — short posts draw everything with no `+N`; long posts draw the cap and
  report the remainder; the window is contiguous, in post order, and never runs off
  either end.
- **`currentIsAlwaysInside`** — for posts of 3, 7, 15 and 40, *every* position is inside
  its own window. This is the one that would catch a naive `0..<cap`.
- **`tailSlidesTheWindow`** — 080 §5's named case, image 12 of 15 at cap 7 → `8…14`.
- **T4.2** — a stale index past the end of a post shrunk by a reload still yields a
  usable window rather than trapping.
- **T4.3** — the jump clamps in the *callee*, per `ItemDetailPost.jump`'s contract; a
  caller-side guard would be checking a number already stale when it read it.
- **The bucket** — below the 512 default at 1× and 2×, and never under the card's own
  pixels (the pipeline snaps up, so a card is never upscaled at draw).

Full `AtelierRefsTests` target: **TEST SUCCEEDED**, 0 failures.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `FanSpreadWindow` +
  `fanSpreadWindow(...)`, `DetailFanSpreadMetrics`, `DetailFanSpread`, the `fanSpread`
  overlay and its hover state.
- `AtelierRefs/AtelierRefsTests/DetailFanSpreadTests.swift` — new.

## Not verified

The arc's **appearance** — sweep, spacing, the raise, whether 64pt cards are legible
under a picture — is unverified. This was a build-and-test run; the numbers in
`DetailFanSpreadMetrics` are reasoned from the pile's, not tuned on screen.
