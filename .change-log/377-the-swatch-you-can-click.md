# 377 — The Swatch You Can Click

[085](../.docs/085-color-filter-plan.md) phase **C2**. The colors the analyzer has
been storing since schema v7 finally appear on screen, and clicking one filters.
Plus the wiring that makes the C1 derivation pass actually run.

## The row

A "Colors" section in the item detail sidebar, between the derived facts (Data,
Source) and the editable ones (Details). One chip per palette bucket, ordered
most-dominant-first.

**Each chip is painted with the IMAGE's color, not the palette's.**
`ColorPalette.BucketCoverage` gains `representativeHex` — the hex of the most
dominant swatch that filed under that bucket — so a photograph of a rose shows
`#b76e79` while its click still filters the whole `pink` bucket. Painting
`ColorBucket.referenceHex` instead would make every red picture in the library
show the identical red, which throws away half of why looking at this is
interesting. The tooltip names the bucket and its coverage, which is where the
difference between "what you see" and "what you get" is stated rather than left to
be discovered.

Chips are merged, so chip count equals the number of distinct things a click can
do. Two reds at 12% and 8% are one chip at 20% — clicking either would have run
the same search anyway, and two near-identical swatches that return identical
results read as a bug.

The row reads `asset_analysis.colors`, NOT the `asset_color` rows: the JSON has
the real hexes, and it is present the moment analysis finishes rather than after
the derivation pass catches up. The cost is a window — a picture whose colors are
shown but not yet derived briefly fails to match its own chip — bounded by one
idle pass, against a blank row for longer.

## The click

`SearchToken.color(ColorBucket)`, following `.favorites`: a filter carried as a
token so it lives, clears and renders with every other one. The field's `×` drops
it, the chip row shows it, `isActive` counts it. Multiple colors OR (`.any`), so
picking red then blue widens rather than demanding both.

**This pulls the token forward from C3**, which shrinks to the palette picker and
the `SearchRules` bump. The alternative was shipping a swatch row with no click —
the dead end 012's sparkle chips already are, and the one the plan explicitly
warns against.

A click lands in the **pane's own search**, so on a collection screen (where the
scope defaults to This-collection) it reads as "this color, in here". The model is
published through a new `\.librarySearch` environment value: the detail page is
built deep inside `LibrarySearchable`'s content closure, and threading the model
down would change every call site plus `CollectionView`'s own signature for one
optional handler. Optional rather than an `@EnvironmentObject` so a pane outside a
searchable wrapper reads `nil` and its chips degrade to readouts — no crash, no
special case.

Two properties that are easy to get wrong and are pinned:

- **It toggles.** The swatch row is the same row after the click, so clicking the
  chip you just clicked has to undo it. Otherwise the row is a one-way trip only
  the field's `×` can reverse.
- **It dismisses the page.** The results appear in the pane BEHIND the overlay, so
  filtering without closing looks like the click did nothing.

All three hosts wire it — the collection overlay, the search-results overlay
(where a swatch NARROWS the query that produced the hit), and the Space board.
The board is wrapped in `LibrarySearchable` like every other pane, so a color
there does what typing there does: it leaves the board rather than filtering it.
Same for the shelf, where search never returns archived items ([023 · A1]).

## The semantic arm

`semanticSearchAssets` gains the same color conjunct. Without it, flipping keyword
→ meaning would silently stop applying a filter still visible in the field —
exactly the trap `favoritesOnly` was added to that query to avoid. Same EXISTS
shape, same `.any` / `.all` split.

## The pass finally runs

`AnalysisCoordinator` drains `ColorBucketBackfill` **second**, after
`analyzeAll()` and before embedding: it reads what analysis just wrote, and it
decodes nothing, so an asset analyzed this pass is filterable by color in the same
pass.

Bounded — 25 batches of 200, up to 5,000 assets per pass — rather than a plain
`drain()`. The work itself is cheap (no decode, just hexes already on disk), but
the WRITE scales: `replaceColors` is one transaction per asset, so a first launch
over a large library would be tens of thousands of commits competing with ingest.
A library past the ceiling catches up over successive idle passes, which nobody
sees, because nothing shows a color until it is derived.

## The bug the tests found

`SearchToken.colorID` was first a formatted string —
`"…-0000000c%02x"` — whose final group is **ten hex digits, not twelve**. Every
bucket parsed to `nil` and fell back to one shared constant, so all twelve colors
were the same token: `removeToken` dropped every color chip at once and two colors
could never both be selected. Rebuilt from bytes (`UUID(uuid:)`), which has no
parse to get wrong, and the exact id is now pinned rather than only its
distinctness.

## Tests — 715 in Core (was 710), 396 in Ingestion (was 390), +20 in the app

- **`ColorPaletteTests` (+6)** — the representative hex: it is the dominant
  swatch, input order does not change it, a tie takes the earlier one, an
  unparseable swatch never names a bucket, and every hex returned parses back to
  the bucket it names.
- **`ServicesSemanticSearchTests` (+5)** — color narrows the semantic arm, the
  coverage floor applies there too, two requested colors return the asset ONCE,
  `.all` demands every bucket, and no filter leaves un-derived assets rankable.
- **`LibrarySearchModelTests` (+9)** — id distinctness and shape, the toggle,
  accumulation, `clearQuery` / `removeToken`, the raw values reaching both query
  paths, no-token-means-no-filter, and the dismiss.
- **`AssetTagsStoreColorsTests` (new, 7)** — the load, the image's own hex, the
  three ways to have no colors (un-analyzed / no palette / unreadable — all empty,
  none an error), and that re-binding clears synchronously so a step never shows
  the previous picture's colors.

Mutation-verified: the leader tie-break flipped fails `a tie takes the earlier
swatch`; `toggleColorFilter` reduced to an append fails three tests; `bind` not
clearing `colors` fails two; the semantic conjunct disabled fails three.

## Files changed

- `AtelierIngestion`: `Imaging/ColorPalette.swift` (`representativeHex`),
  `ColorPaletteTests`
- `AtelierCore`: `Services/AppServices.swift` (`semanticSearchAssets` color
  conjunct), `ServicesSemanticSearchTests`
- `AtelierRefs`: new `ColorSwatchRow.swift` (`ColorDot`, `ColorsSection`),
  `AnalysisCoordinator.swift`, `AssetTagsStore.swift`, `ItemDetailView.swift`,
  `LibrarySearch.swift`, `CollectionView.swift`, `SpaceView.swift`, new
  `AssetTagsStoreColorsTests`, `LibrarySearchModelTests`

## Migration notes

No schema change. `ItemDetailView` gains defaulted `colors` / `onSelectColor`, so
older call sites compile unchanged; `DetailSection` and `TagFlowLayout` dropped
`private` so the new file can reuse them rather than growing a second flow layout.

**`AssetTagsStore` now holds colors as well as tags, collections, and name/note.**
The name has understated it for a while and understates it more now;
`AssetDetailStore` would be the honest one. Not renamed here — it touches three
hosts and `DetailSession` — but it is the obvious follow-up.

**`AnalysisCoordinator` has no test.** Neither did it before this change, and its
two existing backfills are wired the same untested way: it builds its
collaborators in `init`, so covering the ordering would mean an injectable
initializer. The pass itself is tested end-to-end
([376](376-the-color-index.md)); what is unpinned is the three lines that call it.

C3 is now just the palette chip picker (a color has no text to prefix-match, so it
cannot be suggested by typing) and the `SearchRules` version bump, which will need
`colorBuckets` — and, while it is there, the `favoritesOnly` that has never been
saveable either.

[023 · A1]: 367-the-archive-predicate.md
