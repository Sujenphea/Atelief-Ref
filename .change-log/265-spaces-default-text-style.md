# 265 — New text is 16pt white

## Summary

A new text box arrived 22pt and near-black (`#111111`). Both dated from when the
board was a light surface; on today's dark canvas the default box is a large,
barely visible one. New text is **16pt white** now.

## Fix

`ElementRendering.defaultFontSize` 22 → 16, and the colour moved from a hex literal
to `defaultTextColor` (white) with `defaultTextColorHex` derived from it via the
existing `hex(from:)`. That direction matters: the same near-black was written out
in three places as the fallback for a row with NO colour of its own — the draw path
(`textStyle(for:)`), the inspector's seed, and the inline editor's live glyphs — so
a legacy row would have stayed invisible while new boxes went white. All three read
the token now.

## Files changed

- `AtelierRefs/AtelierRefs/ElementRendering.swift` — the two defaults, plus the
  draw-path fallback.
- `AtelierRefs/AtelierRefs/ElementInspector.swift`,
  `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — fallbacks read the token.

## Tests

No new tests: everything that reads a default reads it symbolically, which is why
the suite passed unchanged (`AtelierRefsTests` green). The one assertion that names
it — the format bubble's size label — compares against
`ElementRendering.defaultFontSize` rather than the number.

## Migration notes

Existing boxes are untouched: a stored `fontSize` / `textColor` still wins, and both
are written on creation. What changes for existing content is rows with **no**
colour stored — pre-062 legacy or hand-written JSON — which now draw white rather
than near-black. A box that was deliberately black keeps its stored `#111111`.

Note that `defaultFontSize` is also the fallback for a row with no size, so such a
row now measures and draws at 16pt. `refitTextRows` re-derives heights on load, so
those boxes correct themselves the moment their board is opened.
