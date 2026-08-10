# 375 — The Palette a Swatch Is Filed Under

[085](../.docs/085-color-filter-plan.md) phase **C0**. The fixed vocabulary the
color filter will offer, and the rule that files a dominant-color swatch into it.
Pure — no schema, no UI, no database. That is C1 and C2.

## Why a bucket at all

`ColorSwatch` and every line of Lab math live in **AtelierIngestion**, and
**AtelierCore cannot see them** — the package dependency runs Ingestion → Core.
But the filter has to be a WHERE conjunct inside `AppServices.searchAssets`,
which is Core, because [367](367-the-archive-predicate.md) settled that a search
predicate applied after the fetch shortens pages and lets the keyset cursor page
through the gaps.

So Ingestion assigns a bucket and Core stores an integer it cannot interpret —
the same discipline `asset_analysis.colors` and `SearchRules.rules` already
follow. The chip UI reads the same enum, so what a user clicks and what the
analyzer decided cannot drift apart.

## The rule, and why it is not "nearest palette color"

Nearest-anchor-in-Lab is the obvious implementation and it is wrong: anchors sit
at different lightnesses, so lightness ends up deciding hue — a dark navy can
land nearer the brown anchor than the blue one. The rule separates the questions:

1. **Chroma gate** — below `neutralChromaThreshold`, a color is black/gray/white
   by lightness, whatever its hue angle says.
2. **Hue angle** — nearest anchor by angle, which is lightness-independent, so a
   navy and a pale sky-blue file together.
3. **Brown** — a red/orange/yellow-family color that is both dark AND muted.

### The chroma gate is the whole ballgame

Near-neutrals still have a perfectly confident hue angle. An off-white wall
(`#f5f2ec`) computes as orange. Without the gate, every wall, floor and sheet of
paper in the library files under a hue and that hue becomes a junk bucket.

The threshold is **18**, and it is the palette's one real judgement call. At 12 —
the first value tried — beige and cream landed in yellow and turned yellow into
exactly that junk bucket. At 18, walls, concrete, paper and beige are neutral
while sky (C≈26), tan (C≈25) and navy (C≈31) stay colored.

### Brown needs two conditions, not one

Brown has no hue of its own; it is dark muted orange. Lightness alone looked
sufficient until the probe showed **pure red filing as brown** — `#ff0000` is
L=53.2, under the 55 threshold. Filing the reddest color there is under brown is
indefensible, so brown also requires chroma below 70: rust (C≈69) and olive
(C≈58) stay brown, pure red (C≈105) does not.

### The blue/purple anchors were measured

The naive pair `#2050d0` (295.0°) and `#8030c0` (314.0°) put their midpoint at
304.5°. Pure blue is 306.3°, so **the bluest color there is filed as purple**.
The shipped pair sits at 300.2° and 321.3° — midpoint 310.8°, and it lands
correctly.

Worth recording honestly: moving *either* anchor alone would have fixed it. Only
the original pair produced the bug, and the tests catch that pair. A ±2° drift in
one anchor is not caught, and pinning the boundary that tightly would be
over-fitting a number that has no exact right value.

## Merging, which is the reason `bucketCoverages` exists

`ColorExtractor` returns up to five clusters, and a photograph of a red door
easily yields two reds at 12% and 8%. Kept apart, neither clears a 15% filter
floor and the reddest image in the library fails a search for red. Merged, it
matches at 20% — the truth about the picture.

Ties break on the bucket's raw value, because these rows get a **persisted rank**
and Swift's dictionary iteration is seed-randomized per process. Without the tie-
break the stored order shuffles between runs.

## Tests — 22 new, 381 in the package

Four layers, failing for different reasons: the **pin** (raw values are
persisted, so a renumber silently re-labels every stored row), the **anchors**
(all 12 reference colors round-trip), the **rules** (each asserted with the case
that breaks if the rule is gone), and **parsing**.

Mutation-verified, each reverted:

| Break | What failed |
|---|---|
| chroma gate → 0 | 17 assertions, incl. black → pink |
| brown chroma ceiling → ∞ | pure red → brown |
| both blue/purple anchors → naive pair | pure blue → purple |
| merge → last-write-wins | two reds stayed 12%, not 20% |
| tie-break dropped | order shuffled — caught on all 5 runs |

## A pre-existing break this pass uncovered

**AtelierIngestion's test target did not compile.** A1 of the archive shelf made
`collectionItems(in:sort:includeArchived:)` non-defaulted and I updated the Core
and app call sites, but not this package's — five calls across
`IngestPipelineTests`, `IngestCoordinatorTests` and `VideoIngestTests`. It merged
that way because the verification runs covered Core, the app, CanvasRenderer,
Server and Export, and never this package. Fixed here (`includeArchived: false`,
all five are browsing reads).

## Files changed

- New: `AtelierIngestion/Imaging/ColorPalette.swift`,
  `Tests/ColorPaletteTests.swift`
- `IngestPipelineTests.swift`, `IngestCoordinatorTests.swift`,
  `VideoIngestTests.swift` (the compile fix)

## Migration notes

None — no schema, no public API change to anything existing. `ColorBucket` raw
values become persisted in C1; from that point they must never be renumbered.
