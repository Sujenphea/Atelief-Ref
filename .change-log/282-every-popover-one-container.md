# 282 — Every popover, one container

## Summary

The app had two popover looks and four insets. Six of the eight system popovers
authored no container at all — they inherited AppKit's native popover material,
which is a different grey, border and shadow from the `surface` card the selection
bar's overflow menu and the Space format panels use. The insets were `lg`, a
hardcoded `16` meaning the same thing, a one-off `14`, and the system default
`.padding()`.

All eight now go through one modifier, `popoverContent(padding:width:)` in
`Theme.swift`: the inset, an optional fixed width, ``popoverChrome()``, and
`presentationBackground(.clear)`.

| popover | was | now |
| --- | --- | --- |
| Element inspector | native, `lg`, 300 | card, `lg`, 300 |
| Space gap | native, `lg`, 240 | card, `lg`, 240 |
| Moodboard export | native, raw 16, 280 | card, `lg`, 280 |
| Export cancel | native, raw 14, 220 | card, `lg`, 220 |
| Contact sheet export | native, raw 16, 300 | card, `lg`, 300 |
| Add colour | native, `.padding()`, 260 | card, `lg`, 260 |
| Add link | native, `.padding()`, no width | card, `lg`, no width |
| Selection overflow | card, `xs`, 220 | unchanged (via the same modifier) |

The overflow menu keeps `xs` deliberately: its ROWS carry their own inset because
they are the click targets, so a wide outer pad would double it. Every other
popover is a form, and takes `lg`.

Widths stay as they were — each is content-driven, and no two forms want the same
one. The element inspector mattered most: it opens off the same text box as the
format panels, so the two were in different chrome side by side.

## Files changed

- `AtelierRefs/AtelierRefs/Theme.swift` — `popoverContent(padding:width:)`.
- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` — `selectionMenuChrome()` is
  now one call to it.
- `ElementInspector.swift`, `SpaceGapPopover.swift`, `MoodboardExportControls.swift`
  (both panels), `ContactSheetExportControls.swift`, `AddColorButton.swift`,
  `AddLinkButton.swift` — padding + frame replaced by `popoverContent`.

## Migration notes

- **The native arrow is gone from all seven.** A transparent host has nothing to
  draw one from. The overflow menu made that trade first; the card's own shadow
  does the pointing at this size. `arrowEdge:` still decides which side a popover
  opens on, so placement is unchanged.
- New popovers: call `popoverContent(width:)` rather than hand-rolling padding.
  Pass `padding:` only when the content's rows already carry their own inset.
- Inset, then width, then chrome — a background sizes to what it decorates, so
  chrome applied before the frame pads with nothing (281).
