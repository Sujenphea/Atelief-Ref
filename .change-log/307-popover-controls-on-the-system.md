# 307 — popover controls on the system

## Summary

`Theme` gave every popover one CONTAINER — `popoverChrome()` / `popoverContent()` —
and that is where it stopped. Inside those cards the controls were still stock macOS:
`.roundedBorder` fields, `.pickerStyle(.segmented)`, default push buttons,
`LabeledContent`, `.regularMaterial`. A popover read as an app-styled frame around a
system dialog.

Four reference frames (`ref/add color.png`, `ref/add link.png`,
`ref/export moodboard.png`, `ref/toast.png`) fix the language for what goes inside:
1pt `hairlineStrong`-outlined controls with no fill, a label in `inkSecondary` with its
control right-aligned, and a full-width outlined primary action at the bottom.

New file `DialogControls.swift` holds the primitives; every popover surface adopts them.

### Selection is an OUTLINE inside a popover

The one place this diverges from the rest of the chrome. A sidebar row, a chip and a
floating bar all mark "active" with a raised `field` / `selection` fill. A popover card
is already `surface`, where a second raised grey reads as a third layer — so the
segments mark the current value by gaining a border instead.

That made the app's SECOND segmented control a problem rather than a precedent.
`SearchModeToggle` was a `field` capsule holding two pills with the live one raised to
`selection`; it now draws from the shared `SegmentedControl` like everything else. A
switch that reads differently in search than in the export panels is a design system
with a hole in it.

### The primitives

- **`.dialogFieldChrome()`** — a `View` extension rather than a `TextFieldStyle`, whose
  conformance needs the underscored `_body` SPI. Apply after `.textFieldStyle(.plain)`.
  The height is a `minHeight` FRAME, not vertical padding: padding sits outside the
  field's own rect, so a click in it would miss the text and fail to focus.
- **`SegmentedControl`** — generic over its label, so one control covers text
  (PDF/PNG), numbers (3–6 columns, 1–3×) and SF Symbols (the inspector's alignment
  row). `fillsWidth: true` divides the space equally for rows too long to hug.
- **`DialogButtonStyle`** — `.fill` for the bottom-of-card primary, `.hug` for inline
  actions. Dims to 0.35 when disabled, the floating bar's dimmed-not-hidden idiom;
  reading `isEnabled` needs a nested view, since a `ButtonStyle` can't see the
  environment in `makeBody`.
- **`DialogRow`** / **`DialogStack`** — label-left and label-above, replacing
  `LabeledContent`.
- **`ColorSwatchWell`** — `NSColorWell` at `.minimal` style. SwiftUI's `ColorPicker`
  draws a fixed-size well with its own chrome and can't wear the tokens.

## Pixel changes

Beyond the four frames, six deliberate ones:

- **Search's keyword/meaning toggle** loses its `field` capsule and its raised
  `selection` pill for the shared outline segments.
- **The toast** loses its leading green-check / orange-undo glyph, and its
  `.regularMaterial` capsule becomes opaque `surface`. A translucent pill tints from
  whatever it floats over, so the same toast rendered a different grey on the grid than
  on the canvas. Its one-off `0.15 / 8 / 3` shadow becomes `Elevation.floating` — 286
  left that shadow alone as "a genuinely different weight"; this reverses that, because
  `floating` is documented for exactly this shape, a pill riding over content it did not
  lay out.
- **Both export panels** widen (moodboard 280 → 320, contact sheet 300 → 320) and the
  **element inspector** widens 300 → 340. At the old widths the longest real labels —
  "Single Page" / "Letter Pages" beside a "Layout" label, and the four text weights —
  truncated where `.pickerStyle(.segmented)` used to compress. The reference frame shows
  those labels in full, and the app's type scale is Dynamic Type roles rather than point
  sizes, so the card width is what gives.
- **Add Link's card** owns its width (320) instead of inheriting it from the field's
  `.frame(width: 320)`, which a full-width button underneath would have had to duplicate.
- **Add Color** loses its `ColorPicker("Pick a color")` row: the swatch beside the hex
  field IS the picker now. The hex stays the single source of truth, and the swatch
  tracks a TYPED hex as well as a picked one — the read-only preview it replaced did
  that for free.
- **Titles** are title case ("Export Moodboard", "Export Contact Sheet").

## Files changed

- `DialogControls.swift` — new; the primitives above.
- `Theme.swift` — `Colors.field`'s doc corrected. It is no longer the fill for "input
  fields, buttons"; a popover's fields and buttons are unfilled on `hairlineStrong`.
  It remains sidebar selection, chips and the floating bars.
- `AddColorForm.swift`, `AddLinkForm.swift`, `MoodboardExportControls.swift`
  (panel + cancel panel), `ContactSheetExportControls.swift`, `ToastHost.swift`,
  `SpaceGapPopover.swift`, `ElementInspector.swift` — adopt the primitives.
- `LibrarySearch.swift` — `SearchModeToggle` reduced to a `SegmentedControl` call;
  its bespoke `ModeSegment` deleted.

## Not in this pass

`Slider`, `Toggle`, `ColorPicker`, `Stepper` and `FontFamilyPicker` stay native — the
reference frames show none of them, and inventing a look for a checkbox is a separate
decision from restyling what they do show. Sheets and alerts are untouched
(`OnboardingSheet`, `SnapshotsSheet`, `SettingsView`, `BulkSweepsView`, and
`NameEntryAlert`, which is a system `.alert` and unstylable by design).

No stroke-width token was added; borders keep the `lineWidth: 1` literal every chip and
field already uses.

## Migration notes

None — no API was removed. `SearchModeToggle` keeps its name and its
`init(mode:)`; only its body changed.
