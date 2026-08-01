# 312 — the item detail page comes off the system

## Summary

The detail page was the last surface still wearing stock macOS controls. `307` took
every POPOVER off the system ("an app-styled frame around a system dialog") and `229`
gave every chrome button a hover state — neither swept `ItemDetailView.swift`. This
closes it, and fixes two measured layout bugs found on the way.

### The zoom bar was never behind the image

Reported as a z-order bug: the zoom controls appeared to sit UNDER the artwork. They
did not. An `.overlay` always composites above its content, and the glyphs drew on top
the whole time — verified by rendering the exact view structure in a live `NSHostingView`
and capturing it.

The real cause is that the three buttons carried **no `.buttonStyle` at all**, so they
got macOS's default bezel, which is a *translucent vibrant material*. Over bright
artwork the picture read straight through them and the bar dissolved into the image.

They now wear the app's floating-bar chrome — the `selectionBarChrome()` recipe: an
**opaque** `field` capsule on a `hairlineStrong` border, lifted by `Elevation.floating`.

### The ⋯ pill was half the height of its neighbours

Measured via `NSHostingView.fittingSize`:

| pill | before | after |
|---|---|---|
| Back | 72 × **28** | 72 × **28** |
| Pager | 103.5 × **28** | 103.5 × **28** |
| Overflow ⋯ | 20 × **14** | 39 × **28** |

`.menuStyle(.borderlessButton)` swallows its label's padding whole, so the declared
12/6 inset produced nothing. **This file had already diagnosed that exact trap** — see
`CollectionsField`: *"borderlessButton added an inset that broke the alignment"* — the
overflow menu simply never got the same fix.

`.menuStyle(.button)` alone only reaches 17pt, because the `⋯` glyph is three dots on
the baseline with almost no intrinsic height. So the new shared `TopBarPill` sizes by a
**fixed height frame**, not by vertical padding — the same reasoning `dialogFieldChrome()`
records for its own `minHeight`. Back and the pager land on their existing 28pt, so
neither moves.

### Everything else

- **Ink tokens.** None of the top-bar pills set a `foregroundStyle`, so their labels
  fell back to the system `labelColor` instead of `Theme.Colors.inkPrimary`. The pager
  was drawing its numerals in the token and its chevrons in system white — two whites
  in one pill.
- **Hover + tooltips.** Back, both chevrons, ⋯ and all three zoom buttons were inert
  and untooltipped. Back and ⋯ brighten their whole pill (`filmstrip` → `field`); the
  pager chevrons and zoom glyphs take `HoverButtonStyle`.
- **Disabled state now dims.** `HoverHighlight` wraps `.plain`-family labels, which drop
  the system's own dimming — so a disabled chrome button rendered *pixel-identical* to a
  live one (the pager's ← on the first item looked pressable). Added the `0.35` dim
  `DialogButtonStyle` already documents. **App-wide**, not just this page.
- **The zoom bar overhung the artwork by 4pt** — the overlay inset was `md` (12) while
  `mediaArea`'s own padding is 16. Now `lg` on both, so the bar's edges line up with
  the picture's.
- **`.borderedProminent`** on the link / tweet "Open" buttons paints the system ACCENT
  in a palette that is monochrome by design → `DialogButtonStyle(width: .hug)`.
- **`.secondary` / `.tertiary` / `Color.primary.opacity(0.1)` / `.quaternaryLabelColor`**
  in the link, tweet and colour detail views → `inkPrimary` / `inkSecondary` / `hairline`
  / `field`.
- **Off-scale literals** — `spacing: 16/20`, `.padding(40)`, `.padding()`, `spacing: 4`
  → `Theme.Spacing`.

## Sidebars

### The detail panel's own buttons were 9.5pt targets

`DetailSidebar`'s controls were bare `.plain` glyphs — so, per `229`, they had neither
hover NOR a working tooltip: a template `Image`'s only hit-testable area is its opaque
pixels, so `.help()` had nothing to track.

| control | hit area before | after |
|---|---|---|
| chip remove `×` | **9.5 × 9.5** | 13.5 × 13.5 |
| Tags `✦` wand | 15.5 × 14 | 23.5 × 22 |

The `×` now matches `LibrarySearch`'s token-remove `×` exactly
(`HoverButtonStyle(cornerRadius: 4, padding: 2)`) — literally the same control, styled
two different ways. At `padding: 2` the chip's own height is unchanged.

The **Add** chips (Collections and Tags) and the **Visit** button gained hover too. All
three paint their own opaque `field` fill, so the wash composites OVER it via a
`hovered` flag rather than through `HoverHighlight`'s `.background` — which would sit
behind the fill and never show. `TopBarPill` now uses that same rule, so there is ONE
hover mechanism on the page instead of a token swap in one place and a wash in another.

Visit also gained the `hairline` border every other `field`-filled surface in the panel
(`DetailField`, `DetailChip`) already carries; it was drawn fill-only.

### The app sidebar's sort menu carried phantom chrome

Third instance of the `.menuStyle(.borderlessButton)` trap in this pass. Measured
against the trash button — same 14pt glyph, same 5pt hover pad:

| | width | height |
|---|---|---|
| `sortMenu` (borderless) | **34.0** | 25.0 |
| `sortMenu` (`.button`) | 29.5 | 25.5 |
| `trashButton` (reference) | 25.5 | 27.5 |

So the sort glyph sat off the rail's vertical axis and its hover fill was wider than
every sibling's. `.menuStyle(.button)` + `.plain` leaves only the genuine
glyph-width difference. This is the anomaly `railIcon`'s comment describes as "the sort
`Menu` in particular carries its own chrome" — the 28×28 square is left in place, since
it still usefully centres the rail, but it is no longer papering over a bug.

## Files changed

- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — new `TopBarPill` metrics,
  `.topBarPill()` container and `TopBarPillButtonStyle`; `backButton` / `pager` /
  `overflowMenu` rebuilt on them; `zoomControls` on the floating-bar chrome with the
  ⌘= mirror moved out of the styled `HStack` (inside it, the bar's button style gave
  the zero-size button a hover pad and stray width); `LinkDetailView`,
  `TweetDetailView`, `ColorDetailView` retokenized.
  `DetailChip` gains `hovered`; new `DetailAddChip`; the chip `×` and Tags wand get
  real hit areas; `VisitButton` gains hover, a hairline and a tooltip.
- `AtelierRefs/AtelierRefs/HoverButtonStyle.swift` — `HoverHighlight` dims when
  disabled.
- `AtelierRefs/AtelierRefs/SidebarView.swift` — `sortMenu` off `.borderlessButton`.

## Migration notes

None — presentation only. All three `ItemDetailView` hosts (collection grid, Space
board, library search) inherit it.

## Verify

- Open an image item → the zoom bar reads as an opaque pill over the artwork, its
  right/bottom edges flush with the picture's; hover fills each glyph; ⌘− / ⌘+ / ⌘= /
  ⌘0 still zoom and fit; zoom-out is visibly dimmed at 100%.
- Top bar → Back, `N / count` and ⋯ are the same height and share one baseline; each
  has a tooltip; Back and ⋯ brighten on pointer-over; the pager's ← is dimmed on the
  first item and → on the last.
- A link / tweet / colour item → no blue system button anywhere.
- Detail panel → the chip `×` and the Tags wand are hoverable and now show their
  tooltips; the Add chips and Visit brighten on pointer-over; removing a chip still
  takes one click at the chip's unchanged height.
- App sidebar → the sort glyph sits on the same vertical axis as trash in the collapsed
  rail, and its hover fill is the same width as its siblings'.
- **Not covered by tests** — this is presentation-only and the pill geometry was
  verified by measuring `NSHostingView.fittingSize`, not by an assertion in the suite.

## Not done

- `Theme.Spacing.xs + 2` (i.e. **6**) appears 10× in this file and nowhere else in the
  app, while `selectionBarChrome()` writes the same value as a bare `6`. Six is a real,
  used step that the 4/8/12/16/24/40 scale does not name. Adding a token for it is an
  app-wide design-system call, so it is left flagged rather than taken here.
- `Divider()` at the top-bar and media/sidebar seams draws the system separator rather
  than `Theme.Colors.hairline` — but so do the seven other `Divider()` sites
  (`AppShellView`, `SnapshotsSheet`, `ElementInspector`). Changing only this file would
  add drift, not remove it; it wants one sweep.
- `ZoomableImage`'s `.clipped()` clips a zoomed image to its FIT rect rather than to
  the media pane, so zooming a landscape photo leaves the letterbox bars empty instead
  of filling the pane. Confirmed by render (identical bounds at 100% and 300%). May be
  intentional; left alone as a behaviour change rather than a chrome fix.
