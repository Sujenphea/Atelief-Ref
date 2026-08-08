# 079 — Floating bars: one container, two glyph units

**Kind:** design (spec) · **Status:** implemented · **Supersedes nothing; see `.change-log/352`**

The app draws nine pieces of chrome that ride over content they did not lay out.
Before this pass, four of them shared a container and the other five had each
invented one. This doc is the rule they now all follow, written down so the tenth
bar inherits it rather than rediscovering it.

## 1 · What counts as a floating bar

Anything that sits **over** content it did not lay out and offers controls or a
readout for it. Today, all nine:

| Bar | Owner |
|---|---|
| Collection selection bar | `CollectionView` |
| Search selection bar | `LibrarySearch` |
| Home / gallery selection bar | `CollectionsGalleryView` |
| Space board action bar | `SpaceView` |
| Text format bubble | `SpaceFormatChrome` |
| Detail zoom controls | `ItemDetailView` |
| Detail top-bar pills | `ItemDetailView` |
| Import progress pill | `ImportProgressPill` |
| Toast | `ToastHost` |

A **popover / panel** is not a floating bar. It is a transient layer opened *from*
one, and it keeps its own container (`popoverChrome()`: `surface` on a plain
`hairline`, `Elevation.hover`). `field` on `surface` is the app's bar-on-popover
contrast and it is deliberate — see `Theme`'s note on the popover's inverted
border/shadow balance.

## 2 · The container

One modifier, `floatingBarChrome(leading:trailing:vertical:)`, in
`SelectionActionBar.swift`:

- **Shape** — `Capsule`.
- **Fill** — `Theme.Colors.field` (#2C2C30), opaque. Never a material: a
  translucent pill tints from whatever it happens to float over, so the same bar
  rendered a different grey on a grid than on artwork.
- **Border** — `Theme.Colors.hairlineStrong`, `lineWidth: 0.5`.
- **Lift** — `Theme.Elevation.floating`.

**It carries appearance only.** It used to end with `.padding(.bottom, 16)`, which
is placement — so the modifier could only be used at the bottom of a pane, and any
caller who wanted the look elsewhere copied the four lines instead. Three did, and
the copies had drifted on padding and shape by the time they were counted. Hosts
now apply their own inset (`Theme.Spacing.lg` at the bottom of a pane, which is
also what `floatingAdd` uses, so the "+" and a bar share a baseline).

### Insets

The defaults are asymmetric — **16 leading, 6 trailing** — because a bar that opens
with TEXT needs the count to breathe while the last glyph's own 30×28 hit area
already supplies the right margin.

An **icon-only** bar passes `trailing: Theme.Spacing.lg` to balance it. That is the
one knob, and it is a knob rather than a second modifier because it is the only
thing that legitimately varies. (The board's action bar used to reach the same
number by stacking a local `.padding(.trailing, 10)` on the modifier's 6, which
read as the bar disagreeing with the chrome instead of as a documented second
case.)

The **format bubble** passes zero on all three. Its size is computed *before*
layout by `SpaceTextChromeLayout.bubbleSize(sizeLabel:)` — the flip-at-a-viewport-
edge maths needs a rect first — so `bubblePadding` is already folded into the frame
and the chrome supplies the surface only. It also takes `md` rather than `lg`,
being the one bar sized to the thing it formats.

The **toast** takes `md/md/sm`: it holds a sentence, not a glyph row.

## 3 · The glyph unit

**Two units, and the rule is where the glyph sits.**

| | Standalone bar | Nested in a pill |
|---|---|---|
| Type | `SelectionBarIcon` | `CompactBarIcon` |
| Size | 30 × 28 | 24 × 22 |
| Radius | `Radius.control` (7) | `Radius.chip` (6) |
| Symbol | 15pt medium | 13pt medium |
| Hover | `hoverControl` | `hoverControl` |
| Disabled | `Theme.disabledOpacity` | `Theme.disabledOpacity` |

The nested unit exists for exactly one reason: the detail pager lives in a 28pt-tall
pill, which a 28pt glyph would fill edge to edge. "Smaller because it is nested" is
now a stated rule with one size behind it, rather than whatever each pill's
`HoverButtonStyle` padding happened to produce (which was four sizes and two radii
for the same class of button).

Both are `BarGlyphSlot` with a symbol inside. Reach for `BarGlyphSlot` directly when
the content is not an SF Symbol — the format bubble's segments are a swatch dot, an
"Aa" specimen and a point size, and welding the hover fill to `Image(systemName:)`
was why they were the only buttons in the app that gave no pointer feedback.

A **non-glyph** item in a bar row takes `.barSlot()` so the row keeps its rhythm —
the export progress ring draws 16pt and used to dent the bar mid-export. Apply it
*inside* each branch of a conditional, never to the enclosing `Group`: a `Group`
whose branches all fail contributes no subview, which is what stops an idle bar
reserving an empty slot.

## 4 · State

- **Ink** — `Theme.Colors.inkPrimary`. Never `.primary`: the system semantic
  resolves to pure #FFFFFF on a dark appearance, and the board's bar carried both,
  so one row rendered two whites.
- **Active / current** — the raised `Theme.Colors.selection` fill (`isOn`), the same
  marker a sidebar row and a chip use. The hover fill steps aside underneath it.
  Not an outline: `SegmentedControl` marks with an outline because it sits on a
  popover's `surface` where another raised grey would read as a third layer; a bar
  has the opposite constraint.
- **Disabled** — `.disabled(…)` alone. `BarGlyphSlot` reads `\.isEnabled` and dims
  to `Theme.disabledOpacity` itself. Do not add `.opacity(0.35)` at a call site;
  six did, and the two that forgot stayed fully bright while unavailable.
- **No accent.** The theme has none. `Theme.Colors.warning` is the single semantic
  colour, for a job that stopped without finishing. Success is carried by glyph
  shape, not by green.

## 5 · Popovers hung off a bar

Always `arrowEdge: .top`. A bar popover opening downward is clipped by the floating
capsule. Applies to the overflow menu, the group panels, all three export
configuration panels, the progress ring's cancel panel and the element inspector.

## 6 · What this pass deliberately did not unify

- **`SpaceView`'s three bar layouts** (`.idle` / `.single` / `.multi`). The mode
  switch is a genuine variant, not drift — it is eight glyphs wide in every mode by
  design (069).
- **The toast's content.** It shares the container but not the row: a message, a
  `DialogButtonStyle` action and a dismiss, at `md` gaps.

## 7 · Dropped

`Theme.Colors.filmstrip` (#1A1A1C). It named the detail filmstrip's thumb ground
and the Back-button fill; the thumbs stopped drawing it, and the top bar's pills —
its last holder — moved onto `field`. Dropped per `.change-log/295`'s policy rather
than left standing for something to pick up by mistake.
