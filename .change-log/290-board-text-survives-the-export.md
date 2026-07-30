# 290 — board text survives the export

## Summary

Text created on a Space board persists **white** (`#FFFFFF` — the default since
40eb684 flipped it for the dark canvas). Every export painted an **opaque white
page**. So every caption a user typed on a board came out invisible in the moodboard
PDF and PNG.

A second, quieter version of the same split: a legacy text row with NO stored colour
drew white on the board (`ElementRendering.swift:83`, `?? defaultTextColor`) and
black in the export (`MoodboardExport.swift:158`, `?? .black`). One element, two
colours, depending on which surface you looked at.

## Changes

### The page ground rides on the mapping, not the config

The obvious fix — flip `RenderOptions`' default from `.white` — is wrong here,
because the **contact sheet renders through the same `MoodboardExport.render`**, and
its captions are `#6B6B6B`, a mid grey chosen to read on paper. Flipping the shared
default would have fixed the board by breaking the sheet.

So `MoodboardExport.Mapping` gained `background: RGBA`. It belongs there rather than
on `ExportConfig` for two reasons:

- it follows from WHAT is being exported, not from what the user picked in the
  popover (format / layout / scale);
- both producers build exactly one `Mapping`, so every entry point — the floating-bar
  button and the File-menu command — inherits the right ground without having to
  remember. An `ExportConfig` field would have had four construction sites to keep in
  step, and a missed one fails silently as a wrong-coloured page.

`MoodboardExport.map` → `.boardGround`. `ContactSheetExport.map` → `.white`, at both
of its returns (the empty-sheet early return included).

### `RGBA.boardGround`

`#141416`, the package-side mirror of `Theme.Colors.mediaBackdrop`. `AtelierExport`
has zero product dependencies by design and cannot see `Theme`, so the value is
restated with a comment naming what it mirrors — the same arrangement `Theme.NS`
uses for the AppKit seams.

### The colourless-text fallback

`MoodboardExport.textStyle`'s `?? .black` → `?? .white`, matching
`ElementRendering.defaultTextColor`.

## Pixel changes

Moodboard PDF and PNG exports now render on `#141416` instead of white. This is the
point of the change — the export looks like the board it was composed from — but it
IS a change to every board export, including boards whose text was manually set dark.
Contact sheets are untouched.

## Files changed

- `AtelierExport/.../Model/RGBA.swift` — `boardGround`; `white` re-documented as the
  contact sheet's ground.
- `MoodboardExport.swift` — `Mapping.background`; `render(…)` takes it; the text
  fallback.
- `ContactSheetExport.swift` — `.white` at both returns.
- `ExportController.swift` — threads `mapping.background` through `start`.
- `MoodboardExportTests.swift`, `ContactSheetExportTests.swift` — the two grounds are
  now asserted, plus the colourless-text default.

## Migration notes

`MoodboardExport.render(pages:provider:config:isCancelled:onProgress:)` gained a
`background:` parameter, unlabelled default omitted on purpose: a new producer must
state which ground it composed against rather than inherit one silently.

## Verified

`swift test` in AtelierExport → 31 tests passed. App `-only-testing:AtelierRefsTests`
→ `** TEST SUCCEEDED **`.

## Not verified

I have not opened an export to look at it. The colour values and the code path are
right; whether a dark moodboard page is what you actually want to hand someone is a
judgement worth making against a real PDF.
