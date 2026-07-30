# 296 — radius on the scale

## Summary

`Theme.Radius` had 6 tokens and 10 users. Alongside them sat **22 raw
`cornerRadius:` literals** at 4, 5, 6, 7, 8, 10, 12 and 20 — three of those values
not on the scale at all.

20 of the 22 now name a token. The other two are documented as deliberately off it.

## Mapped

| Was | Now | Sites |
| --- | --- | --- |
| `12` | `Radius.card` | `FanCard` ×3, `SharedThumbnail` ×2, `ItemDetailView` ×2 |
| `6` | `Radius.chip` | `SidebarView` ×5, `SelectionActionBar` ×2 |
| `8` | `Radius.tile` | `OnboardingSheet` |
| `7` | `Radius.control` (new) | `SelectionActionBar`, `HoverHighlight`/`HoverButtonStyle` defaults ×3 |
| `10` | `Radius.card` | `BulkSweepsView`, `OnboardingSheet` |
| `20` | `Radius.panel` | `ColorDetailView` ×2 |

## Two new facts written into `Theme`

**`Radius.control = 7` is a real role, not a rounding of `chip`.** It is the glyph
button's hover fill — a 15pt icon in a 30×28 hit area — and it recurred in four
places, including as `HoverHighlight`'s own default. A role with four users and its
own justification is exactly what a token is for.

**`chip` and `field` share the value 6 on purpose.** They read as a duplicate. They
are not: everything small in this app rounds the same, and the two names record what
a call site *is* rather than two independent measurements. Written down so the next
audit doesn't "fix" it by merging them.

## Two literals kept off the scale

`LibrarySearch`'s two clear buttons use 5 and 4. Both are `HoverButtonStyle` at
reduced padding — a 12pt glyph at 3pt, and an 8pt glyph at 2pt, the smallest control
the app draws. Their radius tracks the control's size, not a design step:
`Radius.control`'s 7 would round the smaller one to a near-circle. Forcing them onto
the scale would have made the scale a lie about what it means. Both now carry a
comment saying so.

## Pixel changes

Four, all ≤2pt:

- `BulkSweepsView`'s sweep card and `OnboardingSheet`'s step card: 10 → 12.
- `ColorDetailView`'s hero swatch and its border: 20 → 16.

Everything else mapped to the value it already had.

## Files changed

- `Theme.swift` — `Radius.control`; `chip`/`field` and `panel` documented.
- `HoverButtonStyle.swift` — both defaults and the `hoverHighlight(…)` default.
- `FanCard.swift`, `SharedThumbnail.swift`, `ItemDetailView.swift`,
  `SelectionActionBar.swift`, `SidebarView.swift`, `OnboardingSheet.swift`,
  `BulkSweepsView.swift` — literals → tokens.
- `LibrarySearch.swift` — the two deliberate exceptions, commented.

## Not in this pass

`Debug/` is excluded throughout — the bakeoff harness is measurement scaffolding, and
pinning it to app chrome tokens would make it track design changes it exists to be
independent of.

The typography half of the same finding (21 token uses against 37 raw
`.system(size:)` and 52 semantic roles) is untouched: the 4 existing roles do not
cover 89 sites, so it needs a role set decided before anything is converted.

## Verified

`-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`. Not looked at running —
the four ≤2pt changes are below what I would trust myself to judge from a diff.
