# 352 — Floating bars: one container, one glyph unit

## Summary

An audit of every bar that floats over content found nine of them sharing three
fill tokens, three border recipes, four glyph sizes, four item gaps and seven
padding recipes. Four used the shared `selectionBarChrome()`; the other five had
each invented a container, three of them by hand-copying the recipe (two while
naming it in their own doc comment).

This lands the rule set in `.docs/079-floating-bars-design.md`.

**Visible changes** — the detail top bar and the format bubble move; everything
else is pixel-identical or a hair taller:

- Detail top-bar pills gain a shadow and lighten (`filmstrip` → `field`); the
  border halves to 0.5.
- The format bubble grows 34 → 40pt, becomes a Capsule, and its segments hover.
- The detail zoom bar grows 29 → 40pt.
- The import pill loses 2pt of height (V8 → V6), matching the bar it stacks above.
- The toast's fill moves `surface` → `field` and its border strengthens.
- The export success checkmark is no longer green, and no longer narrows the bar.
- Both collection-bar export buttons now dim when unavailable (they never did).
- The text-led bars gain 2pt of trailing inset (6 → 8), so a hovered last button
  clears the capsule's cap by the same 6pt it clears the top and bottom by. At 6
  the fill came within 4.0pt of the border diagonally — the measurement is in
  `.docs/079`.

## Files changed

**Design system**

- `Theme.swift` — added `Typography.barLabel` and `disabledOpacity`; **dropped
  `Colors.filmstrip`** (no consumers left after the top bar moved).
- `SelectionActionBar.swift` — `selectionBarChrome()` → `floatingBarChrome(leading:
  trailing:vertical:)`, appearance only; new `BarGlyphSlot`, `CompactBarIcon`,
  `.barSlot()`; new `CountSelectionBar`; `SelectionBarIcon` rebuilt on the slot and
  now dims itself.
- `ThemeGalleryView.swift` — dropped the `filmstrip` swatch row.

**Bars**

- `CollectionView.swift`, `LibrarySearch.swift`, `CollectionsGalleryView.swift` —
  three duplicated `selectionBar` bodies replaced by `CountSelectionBar`; hosts now
  apply their own bottom inset.
- `SpaceView.swift` — `floatingBarChrome(trailing: .lg)` replaces the modifier plus
  a local `.padding(.trailing, 10)`; three manual `.opacity(0.35)` deleted; the
  element inspector's popover `arrowEdge: .bottom` → `.top` (the last one).
- `SpaceFormatChrome.swift` — private `bubbleChrome` deleted; segment height 22 →
  28, gap 8 → 2, swatch segment 26 → 30, all keyed off `SelectionBarIcon`; segments
  and the align panel rebuilt on `BarGlyphSlot`, so they hover and mark the open
  panel.
- `ItemDetailView.swift` — `topBarPill()` onto the floating recipe; zoom controls
  call the shared chrome with shared glyphs; pager chevrons take `CompactBarIcon`.
- `ImportProgressPill.swift`, `ToastHost.swift` — inline recipes replaced.
- `SpaceArrangeGroups.swift`, `MoodboardExportControls.swift`,
  `ContactSheetExportControls.swift`, `CollectionSiteExportControls.swift` — manual
  dims deleted, `.primary` → `inkPrimary`, ring given a full bar slot.

**Docs**

- `DialogControls.swift`, `FloatingAddControl.swift`, `Theme.swift` — doc
  references to the renamed modifier.

## Migration notes

- **`selectionBarChrome()` is gone.** Call `floatingBarChrome()`, and add the
  bottom inset (`Theme.Spacing.lg`) at the host — the modifier no longer supplies
  placement. An icon-only bar passes `trailing: Theme.Spacing.lg`.
- **Do not write `.opacity(0.35)` beside `.disabled(…)`** on a bar button.
  `BarGlyphSlot` reads `\.isEnabled` and dims itself; a call-site opacity now
  compounds with it.
- **`Theme.Colors.filmstrip` no longer exists.** Use `Colors.field` for chrome and
  `Colors.mediaBackdrop` for a media ground.
- New bars: read `.docs/079-floating-bars-design.md` first.

## Verification

`xcodebuild … test` — **TEST SUCCEEDED**. `SpaceFormatChromeTests`
(`pillIsDrawnAtItsLayoutHeight`, `hoverRingIsConcentric`) pass unchanged against
the bubble's new 40pt geometry, since both read the layout constants rather than
restating them.
