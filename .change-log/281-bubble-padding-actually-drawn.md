# 281 — The bubble's padding reaches the screen

## Summary

The format bubble's inset went from 8 to `Theme.Spacing.md` (12), with the pill's
height derived from it (`segmentHeight + bubblePadding` = 34) so the icons breathe
the same above and below as they do at the ends. On screen the pill stayed 22pt
tall — the height of its segments. The number was never wrong; it never reached the
renderer.

`bubbleBar` applied `.bubbleChrome()` to ITSELF, and `body` applied the frame after.
A background sizes to the view it decorates, so the pill was drawn around the
segments (22pt) and the outer `.frame(height: 34)` then centred that pill in 12pt of
nothing. The panels always did it the other way round — frame, then chrome — which
is why the align pill in the same screenshot looked correctly padded and the bubble
above it did not.

- `body` now frames the bar and THEN wraps it: same order as the panels.
- The bar's own `.padding(.horizontal,)` is gone — it was a second way to say what
  `bubbleSize` already says, and with the frame in the right place the frame supplies
  the inset (again, as the align panel already did).

## Files changed

- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — chrome moved out of
  `bubbleBar` to after the frame; redundant horizontal padding dropped;
  `SpaceTextChromeAnchor.init(screenFrame:)` added as a render-test seam.
- `AtelierRefs/AtelierRefsTests/SpaceFormatChromeTests.swift` — `pillHeight` renders
  the chrome and measures the opaque pill down the bubble's centre column;
  `pillIsDrawnAtItsLayoutHeight` asserts the drawn pill matches `bubbleHeight` and is
  taller than `segmentHeight`. Confirmed failing against the old ordering.

## Migration notes

- Decoration goes AFTER the frame in this file. Chrome applied inside a subview and
  framed by its caller silently ignores the frame — geometry the layout enum computes
  is only real if the frame is applied before the background that draws it.
- The existing `bubbleSize` / `alignPanelSize` tests could not have caught this: they
  assert the numbers, and the numbers were right. The new test renders.
