# 292 — frame labels on a dark board

> The code hunks landed in `1e67508` rather than here — they were staged into that
> commit by mistake. Documenting them properly rather than rewriting history while
> another branch of work is in flight (same arrangement changelog 286 used).

## Summary

When the canvas went dark, `ElementRendering.defaultTextColor` was flipped to white
with a comment explaining exactly why: "the near-black this used to be … reads as an
invisible box today". Two siblings in the same file were left behind on the same
premise.

A **frame element defaults to no fill** (`defaultFrameStyle()` sets `fillColor: nil`),
so its label draws straight onto the dark board. Both of that label's colour sources
were near-black:

- `defaultLabelColorHex = "#3A3A3C"` — a new frame's label.
- the inline `?? RGBAColor(red: 0.23, green: 0.23, blue: 0.25)` in `tileContent` — a
  legacy frame row with no stored label colour.

Both now resolve to the board's text default. `defaultLabelColorHex` is defined **in
terms of** `defaultTextColorHex` rather than as a second literal, so the two can't
drift apart again — the same reasoning that already justifies `defaultTextColorHex`
existing at all.

## The media-less cards are NOT the same bug

`mediaLessCardFill` (`#EDEDF2`) / `mediaLessLabelColor` (`#3A3A3C`) look like the
same light-canvas leftover and were flagged as one during the audit. They are not,
and they are unchanged.

A media-less tile draws its own **opaque light fill**: it reads as a physical card
lying on the dark board, so its label has to contrast with the CARD. Lightening it
would have made it invisible against the very fill it sits on — the exact bug being
fixed, inverted.

The file comment claimed these matched "the freeform frame/text defaults (a light
canvas)", which stopped being true the moment text went white. It now states the
actual rule: **a filled card's label contrasts with its fill; an unfilled frame's
label contrasts with the board.**

## Pixel changes

- A frame element's label is white instead of `#3A3A3C`. Previously near-invisible.
- Frames created before this keep whatever `textColor` they stored; only the
  colourless fallback moved.

## Files changed

- `ElementRendering.swift` — `defaultLabelColorHex` derives from
  `defaultTextColorHex`; the inline frame-label fallback takes `defaultTextColor`;
  the media-less block comment states the contrast rule.

## Verified

`-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`.
