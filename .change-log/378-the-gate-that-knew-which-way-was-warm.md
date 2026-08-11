# 378 — The Gate That Knew Which Way Was Warm

Three fixes to [085](../.docs/085-color-filter-plan.md) · C2, all reported from
use within an hour of shipping it: chips whose name did not match their color,
chips that returned nothing, and the pass that fed them running behind the slowest
queue in the app.

Measured against a real 510-image library rather than argued about.

## 1 · The chroma gate is hue-dependent now

**Reported:** "a purplish color can be gray too."

**Cause.** The gate was ONE number (18). It cannot be. How much chroma reads as
"colored" is not constant around the wheel — the eye discounts a warm cast as
white balance and notices a cool one. Splitting the 12–18 chroma band of the real
library by hue: **41% warm** (beige, cream, tan — correctly neutral) and **~59%
cool** (lilac, pale blue, sage, seafoam — named by their color by any person
looking at them). One threshold has to be wrong about one group or the other, and
at 18 it was wrong about the cool half:

| swatch | chroma | hue | was | now |
|---|---|---|---|---|
| `#ddc9e6` | 16.9 | 316° | White | **Purple** |
| `#ccacc3` | 17.2 | 335° | Gray | **Purple** |
| `#d5d6f4` | 15.7 | 290° | White | **Blue** |
| `#b9c6e6` | 17.5 | 277° | Gray | **Blue** |
| `#9fcfcb` | 16.7 | 191° | Gray | **Teal** |
| `#465840` | 16.9 | 136° | Gray | **Green** |

**Fix.** `neutralChromaThreshold` drops to 14; `warmNeutralChromaThreshold` stays
18 for the sector where the junk actually lives. **The sector is stated as the
`.orange` and `.yellow` FAMILIES, not as an angle range** — `nearestHue` already
knows where those sectors are, and writing `48°...116°` would be the anchors'
numbers copied out a second time, free to drift when an anchor moves.

This required resolving the hue family BEFORE the gate, inverting the order of the
first two steps of the rule. A handful of wasted angle comparisons for a color
that turns out neutral, which is the cheaper half of the trade.

Reclassifies **79 of 2550** stored swatches, every one from a neutral to a real
color, and moves no beige. `ColorPalette.version` → **2**, so every asset
re-derives on the next pass from hexes already on disk — the payoff for storing a
version rather than a boolean in [376](376-the-color-index.md).

## 2 · The row and the filter share one floor

**Reported:** an item showing a Yellow chip, clicking it, no results.

**Cause, and it was mine.** [377](377-the-swatch-you-can-click.md) drew every
bucket with no coverage floor. `searchAssets` defaults to **0.15**. So a chip below
that could never return the picture it was drawn on — and inside a collection,
where the search scopes to This-collection, it returned nothing at all.

Not an edge case:

- **56.6%** of every chip drawn (1141 of 2017) was below the search floor.
- **94.3%** of analyzed assets (481 of 510) showed at least one dead chip.
- Yellow: drawn on **165** assets; only **35** assets in the whole library have
  yellow at ≥15%.

A dead chip was pixel-identical to a working one. That is the worst version of
this bug — nothing about it says "this will do nothing."

**Fix.** The row filters by `AppServices.defaultColorCoverageFloor`, the same
constant the query enforces, read from the service rather than copied. The row
drops from 3.95 to 1.72 chips per asset and **no asset loses its section entirely**
(0 of 510).

Merging still happens BEFORE the floor, which is the whole reason merging exists:
two reds at 8% are a red picture at 16%.

## 3 · Colors no longer run behind the analysis drain

**Cause.** [377](377-the-swatch-you-can-click.md) put the color pass second in
`runPass`, after `analyzeAll()`, because it reads what analysis writes. But
`analyzeAll` drains to COMPLETION and decodes every image it touches. On a library
with a real analysis backlog nothing downstream ran for a long time, and an
analysis error skipped the rest of the pass outright — so the cheap queue was
starved by the one queue guaranteed to be slow, and the color filter silently
returned nothing the whole while.

**Fix.** Colors run FIRST, on whatever the previous pass analyzed. A
newly-ingested asset waits one 90s pass for its colors; in exchange the cheap
queue can never be blocked by the expensive one. It stays bounded at 5,000 per
pass so a big first catch-up cannot become the new blocker.

## Tests — 400 in Ingestion (was 396), +4 in the app

- **`ColorPaletteTests` (+4)** — the cool tints that prompted this, by hex; the
  warm neutrals that must NOT move (the ones that put the gate at 18 originally);
  that the warm gate stays strictly above the cool one; and that a very faint cool
  tint is still neutral, so "lower the gate" and "remove the gate" cannot pass the
  same tests.
- **`AssetTagsStoreColorsTests` (+4)** — a sub-floor bucket is not drawn, the
  floor IS the service's constant (a hair above and a hair below it), merging
  happens before flooring, and an image with only faint colors shows nothing.

Mutation-verified: restoring the flat 18 gate fails 7 expectations across two
tests; removing the row's floor fails three.

`CanvasRenderer`'s `testFrameUpdateWithinBudget` failed once during a full
verify (11.1ms against an 8.33ms budget) and passes on a quiet machine — a
timing benchmark under `xcodebuild` load, and no CanvasRenderer code changed.

## Files changed

- `AtelierIngestion`: `Imaging/ColorPalette.swift`, `ColorPaletteTests`
- `AtelierRefs`: `AssetTagsStore.swift`, `AnalysisCoordinator.swift`,
  `AssetTagsStoreColorsTests`

## Migration notes

**No schema change, and nothing to run by hand.** `ColorPalette.version = 2`
re-queues every asset; the pass re-derives from `asset_analysis.colors` with no
image decode, bounded at 5,000 assets per idle pass.

The detail row will look SPARSER after this — that is the fix, not a regression.
A chip that is there is a chip that finds its own picture.
