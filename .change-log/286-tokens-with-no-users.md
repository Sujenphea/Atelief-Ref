# 286 — tokens with no users

## Summary

The design-system audit turned up a recurring shape: a token exists in `Theme`, and
the code that should draw from it hand-copies the value instead. A token nothing
reads is not a token — it is a comment that the compiler cannot check, and three of
these had already drifted from the value they claimed to mirror.

This pass closes four of them. It is deliberately mechanical: with the exceptions
listed under **Pixel changes**, every surface renders exactly as before.

### 1. `Theme.NS` had zero users

The AppKit mirrors existed while `SidebarOutlineKit` and `FloatingAddButton` wrote
the raw hexes with a trailing comment naming the very token they were copying
(`NSColor(hex: 0x3A3A40) // Theme.Colors.selection`). Both now read from `Theme.NS`,
which gained the mirrors they needed: `selection`, `inkSecondary`, `hairlineStrong`
and `hoverRow`.

### 2. A floating-bar shadow that was not a token

`0.35 / radius 14 / y 5` appeared verbatim in three places — the selection action
bar, the import progress pill, and the Space format bubble — while `Theme.Elevation`
had only `rest` and `hover` and two users. It is now `Elevation.floating`, and those
three call `.elevation(.floating)`.

`Elevation` also stores its shadow ALPHA rather than a finished `Color`, because
`CALayer.shadowOpacity` wants a `Float` and a `Color` cannot be taken apart again.
That makes the token reachable from AppKit, via the new `CALayer.applyElevation(_:)`
— which is how `FloatingAddButton`'s disc now gets the lift its comment already
claimed it had.

### 3. `Motion.toast` was defined for a toast that did not use it

`ToastHost` hardcoded the identical spring. It now reads the token. Two `withAnimation`
calls in `ItemDetailView` spelled out `Theme.Motion.gentle`'s exact value and now name
it; the Space swatch-dot hover fade (`easeInOut 0.12`) joins them.

Left alone on purpose: the export progress ring's `easeOut(0.2)` is a value tween
rather than chrome motion, and the detail zoom's `spring(0.25)` / `interactiveSpring`
belong to direct manipulation. Neither is a drifted copy of anything.

### 4. Two hover languages, one of them mislabelled

`HoverButtonStyle` took a bare `opacity:` and filled with `Color.primary`, which is
appearance-dependent in an app whose palette is not; its AppKit sibling in
`SidebarOutlineKit` used `white` for the same fill. Meanwhile `SelectionMenuRow`
hovered to `Theme.Colors.selection` — the SELECTED-state fill — under a doc comment
claiming it followed the sidebar row idiom, which in fact hovers at 6%.

The app now has exactly two hover strengths, named by role:

- `Colors.hoverRow` (white 6%) — full-width rows: sidebar nav and collection rows,
  the overflow popover's rows and section headers, the search mode segments.
- `Colors.hoverControl` (white 10%) — glyph buttons.

`selection` is no longer used for a hover anywhere. `hoverHighlight` and
`HoverButtonStyle` take `fill: Color` instead of `opacity: Double`, so a call site
picks a role rather than inventing a number.

## Pixel changes

Three, all intentional:

- **Overflow popover rows** hover at 6% instead of the `selection` fill — they no
  longer look selected on hover.
- **Search field's × button** hovers at 10% instead of 15%, matching every other
  glyph.
- **Floating "+" button** rests at radius 14 / y 8 instead of 12 / 6, because it now
  uses `Elevation.hover` rather than a drifted copy. Its hover state still deepens
  from there to 16 / 0.70, unchanged.

## Files changed

- `Theme.swift` — `hoverRow` + `hoverControl`; four new `NS` mirrors; `Elevation`
  stores `opacity` and gains `floating`; new `CALayer.applyElevation(_:)`.
- `HoverButtonStyle.swift` — `opacity: Double` → `fill: Color`.
- `SidebarOutlineKit.swift` — through `Theme.NS`.
- `AddColorForm.swift` — the swatch border off `Color.primary`.
- `FloatingAddButton.swift` — through `Theme.NS` and `applyElevation(.hover)`. These
  hunks landed in `83a196c` (the per-pane floating-add work) rather than here, since
  that commit was authored over them.
- `SelectionActionBar.swift`, `ImportProgressPill.swift`, `SpaceFormatChrome.swift` —
  `.elevation(.floating)`; hover fills through the tokens.
- `SidebarView.swift`, `LibrarySearch.swift` — hover fills through the tokens.
- `ToastHost.swift`, `ItemDetailView.swift` — through `Theme.Motion`.

## Migration notes

`hoverHighlight(cornerRadius:opacity:padding:)` and `HoverButtonStyle(opacity:)` are
gone; pass `fill:` a token instead. `Theme.Elevation(color:radius:y:)` is now
`Elevation(opacity:radius:y:)` — `.color` remains as a computed property, so
`.elevation(_:)` call sites are untouched.

## Not in this pass

The audit's remaining findings stand: the header's "there is NO coloured accent"
claim against 22 live accent uses (a design decision, not a cleanup), the typography
split between `Theme.Typography` and raw `.system(size:)`, and the radius / spacing
literals that sit off the scale. `FanCard` and `ToastCard` keep their own one-off
shadows — they are genuinely different weights, not copies of a token.
