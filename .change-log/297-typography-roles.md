# 297 — typography roles

## Summary

`Theme.Typography` had 4 roles and 21 users. Beside them, 70 text sites used raw
SwiftUI text styles (`.caption` ×25, `.callout` ×19, `.headline` ×12, `.caption2` ×5,
`.title2` ×4, `.subheadline` ×3, `.title3`, `.largeTitle`) and 7 more used literal
point sizes.

There are now **8 roles** and no raw text style left outside `Debug/`.

## The finding that reframed this

The audit counted "37 raw `.system(size:)` calls" as typography drift. **30 of them
size an `Image(systemName:)`** — they are glyph sizing, not typography. Converting
them would have resized icons across the app while claiming to tidy fonts.

Only 7 were text. Six are converted; the seventh is `SpaceFormatChrome`'s "Aa" font
specimen, whose size IS the affordance, now commented as such.

Two sites had the opposite problem — a text role sizing a GLYPH — and both are fixed:

- `ItemDetailView`'s overflow "ellipsis" carried `Typography.row`, a sidebar-row TEXT
  token, so the icon tracked a typography decision it has nothing to do with. (It was
  pre-existing; this change would have shrunk it 1pt as a side effect.)
- `SnapshotsSheet`'s empty-state glyph used `.largeTitle`.

Both now take an explicit glyph size, matching the app's other empty-state glyphs
(`SharedThumbnail` 34, `FanCard` 30).

## Roles are a text style + weight, NOT a point size

This reverses how the original four were written, and the reason is Dynamic Type.

`Font.system(size:)` does not scale with the Accessibility text-size setting. So
converting 70 sites from `.caption`/`.callout` (which scale) to fixed-size tokens
would have been an accessibility regression delivered as a tidy-up.

The obvious fix — exact size *and* scaling — does not exist for system fonts:
`Font.system(size:weight:relativeTo:)` is not an API. `relativeTo:` belongs to
`Font.custom`, which needs a font NAME. Measured, on this machine:

| Name | Resolves to | Ascender @13pt |
| --- | --- | --- |
| `.AppleSystemUIFont` | `.AppleSystemUIFont` | 12.568 — matches the system font |
| `SF Pro Text` | `SFProText-Regular` | 12.378 — a different face, no optical sizing |
| `.SFNS-Regular` | **TimesNewRomanPSMT** | — CoreText warns and falls back silently |

`.AppleSystemUIFont` works, but it is a private dot-prefixed name CoreText explicitly
tells you not to use, and the `.SFNS-Regular` row is what its failure mode looks
like: every string in the app silently becomes Times New Roman. Not a risk worth
taking for the whole app's text.

So the sizes are Apple's and Dynamic Type comes free.

## The roles

| Role | Anchor | pt | Was |
| --- | --- | --- | --- |
| `pageTitle` | `.title2` semibold | 17 | `.title2` ×4 |
| `sectionTitle` | `.title3` semibold | 15 | existing token (15) + `.title3` |
| `navItem` | `.title2` medium | 17 | existing token (**16 → 17**) |
| `row` | `.body` | 13 | existing token (**14 → 13**) |
| `bodyEmphasis` | `.headline` semibold | 13 | `.headline` ×12 |
| `body` | `.callout` | 12 | `.callout` ×19 |
| `label` | `.subheadline` | 11 | existing token (**12 → 11**) |
| `caption` | `.caption2` | 10 | `.caption` ×25, `.caption2` ×5 |

Five of the eight render exactly what they rendered before. Three move by 1pt —
`navItem` up, `row` and `label` down — because 16, 14 and 12 have no macOS text style
and something had to give.

`display` was drafted and then dropped: the app's only `.largeTitle` turned out to be
a glyph, so the role would have shipped with no reader — into the same file that just
had five readerless tokens deleted in 295.

## Pixel changes

- `navItem` 16 → 17; `row` 14 → 13; `label` 12 → 11.
- Four `.title2`/`.title3` headings had `.bold()`; the role carries `.semibold`, so
  they are a touch lighter and now match every other title.
- Text scales with the Accessibility text-size setting where it previously did at 70
  sites and did not at 21 — the two groups behave the same way now.

## Files changed

`Theme.swift` + 19 view files. `Debug/` excluded throughout.

## Migration notes

`Theme.Typography.label` is 11pt, not 12 — use `body` for 12. Sizing an SF Symbol is
`.font(.system(size:))`, never a `Typography` role.

## Verified

`xcodebuild build` and `-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`.

I audited every converted line against the view it attaches to, twice — the first
pass had put two `Image` glyphs onto text roles because a bulk replace matched the
wrong occurrence. Both were caught and reverted before commit. Nothing here is
verified by eye.
