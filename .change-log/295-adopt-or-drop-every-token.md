# 295 — adopt or drop every token

## Summary

Changelog 286 set out to close "a token exists in `Theme`, and the code that should
draw from it hand-copies the value instead". It closed four. **Seven were still
unread** when the audit re-ran: `Colors.canvasOuter`, `Colors.mediaBackdrop`,
`NS.field`, `NS.panel`, `NS.hairline`, `Radius.sheet`, `Elevation.rest`.

Every one is now either adopted by the surface its own documentation names, or
deleted. The rule this pass applies: **a token earns its place by having a reader.**
Where the doc claimed a surface, the surface now draws it; where nothing could
plausibly read it, it goes.

## Adopted (3)

### `Colors.mediaBackdrop` → the grid cell and the detail media area

Its doc has said "Grid tiles + the detail media area — the art's stable dark ground"
since it was written. Neither drew it.

- **`MasonryGridItem`** used `NSColor.quaternaryLabelColor` for the tile ground and
  the no-image placeholder. That is a *translucent, appearance-derived* system grey —
  its actual tone depended on whatever showed through, and it is precisely the drift
  `Theme`'s own header calls out ("an `NSColor(hex:)` literal in a view file is a
  token that has drifted"). Now `Theme.NS.mediaBackdrop`.
- **`ItemDetailView.mediaArea`** had no background at all and inherited
  `Colors.panel` (`#212121`). Now `#141416`, a shade below the panel, so a pale image
  and a dark one sit on the same ground instead of the image's own edges reading as
  chrome.

### `Colors.canvasOuter` → beneath the window material

The token described itself as "the opaque fallback / reference value" under the
translucent window — a fallback that was referenced nowhere, so there was no
fallback. With Reduce Transparency on, or anywhere `NSVisualEffectView` has nothing
to sample, the outer ground fell through to whatever AppKit picked. It is now painted
beneath the material, which is what it always claimed to be.

## Dropped (4)

| Token | Why nothing could read it |
| --- | --- |
| `NS.field`, `NS.panel`, `NS.hairline` | Mirrored speculatively; no AppKit seam draws a field, a panel or a plain hairline. A mirror with no reader is a second copy that can fall out of step with the `Colors` original — which is how three of the mirrors had already drifted before 286 caught them. |
| `Radius.sheet` | The app's three sheets are system `.sheet` presentations; **AppKit draws their corners**. The token named a radius the app never got to choose. |
| `Elevation.rest` | Nothing rested at 0.40 / 2 / 1. |

`Elevation.rest` deserves its own note, because deleting it is the opposite of what a
token pass usually does. The two small resting shadows the app draws — `ToastCard`
(0.15 / 8 / 3) and `FanCard` (0.2 / 3 / 2) — are neither of them 0.40 / 2 / 1, and
286 had already assessed them as "genuinely different weights, not copies of a
token". Collapsing them onto `rest` would be inventing a rule; keeping `rest` unread
would be pretending one exists. So it goes, and the reasoning is left in the file.

## The two home cards, onto tokens

`FanCard` and `SharedThumbnail`'s `CoverCard` share near-identical chrome and were
both still on appearance-dependent system colours — `Color(.controlBackgroundColor)`,
`Color(.windowBackgroundColor)`, `Color(.quaternaryLabelColor)` — inside an app whose
palette is fixed and dark. Both now read `Theme`: `surface` for the card,
`mediaBackdrop` for the thumbnail well and the empty placeholder, `field` for the
accented placeholder, `inkPrimary`/`inkSecondary` for the glyph, and
`Radius.cover` / `Radius.card` for their `14`/`12` literals.

They remain two views. Extracting the shared chrome is a separate change and wants
the radius sweep to land first.

## Pixel changes

Five, all intentional:

- **Grid tile ground** is `#141416` instead of a translucent system grey. Most
  visible on a cell whose image hasn't decoded yet, and while a media-less card sits
  on it.
- **Detail media area** is `#141416` instead of `#212121`.
- **Home cards** (`FanCard`, `CoverCard`) sit on `surface` rather than a 50%
  `controlBackgroundColor`.
- **Card placeholders** lose the accent tint: an accented empty card is now the
  `field` grey with `inkPrimary` glyph, not a 12% accent wash with an accent glyph.
- **Outer window ground** gains an opaque `#131313` under the material. Invisible
  unless the material can't sample — which is exactly when it matters.

## Files changed

- `Theme.swift` — three tokens deleted with their reasoning; `canvasOuter` re-documented.
- `MasonryGridItem.swift`, `ItemDetailView.swift`, `ContentView.swift` — adoptions.
- `FanCard.swift`, `SharedThumbnail.swift` — cards onto tokens.

## Migration notes

`Theme.NS.field` / `.panel` / `.hairline`, `Theme.Radius.sheet` and
`Theme.Elevation.rest` no longer exist. Add a mirror back when a seam needs it.

## Verified

`xcodebuild build` → `** BUILD SUCCEEDED **`; `-only-testing:AtelierRefsTests` →
`** TEST SUCCEEDED **`.

Not verified by eye — five surfaces changed tone here and I have not looked at any of
them running. The values are the documented ones; whether the detail media area
wants to be a shade below the panel is a judgement worth making against the real
window.

## Still open

`Color.accentColor` survives in ~14 more places (selection rings, gallery drop
targets, the search chip, the export ring) against `Theme`'s "there is NO coloured
accent". That is the monochrome pass, not this one.
