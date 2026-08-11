# 085 — Color Swatches and the Color Filter (012 · I4)

> Surfacing the dominant-color data the analyzer has been computing and storing
> since schema v7 and which nothing has ever read. A swatch row on the item
> detail page, and color as a search conjunct.
>
> Scope settled with the user 2026-08-11: **bucket integer + normalized table**
> for matching, **preset palette chips** for the UI. Parent doc:
> [012](feature-todo/012-intelligence.md) · I4.

## Status

**C0, C1 and C2 shipped. C3 remains.**

| | | |
|---|---|---|
| C0 | shipped | [375](../.change-log/375-the-color-palette.md) |
| C1 | shipped | [376](../.change-log/376-the-color-index.md) |
| C2 | shipped | [377](../.change-log/377-the-swatch-you-can-click.md) |
| C3 | open | the palette chip picker + the `SearchRules` bump |

**Three things below were superseded by the build**; the prose is left as the
record of the thinking, and the changelogs own what actually shipped.

1. **The v21 schema has no `rank` column** and is keyed `(asset_id, bucket)`.
   Merging same-bucket swatches makes a bucket appear at most once per asset, so
   the composite key IS the merge invariant and display order falls out of
   `coverage DESC`. The index is `(bucket, coverage)`.
2. **The derivation queue is a version stamp, not a row count.** "Has colors, no
   `asset_color` rows" cannot mark work done: an unreadable palette derives zero
   rows, which is indistinguishable from "not derived yet", so such an asset was
   handed back forever. `asset_analysis.colors_palette_version` fixed it, and
   storing a VERSION rather than a boolean turned "retune the palette" into a
   WHERE clause instead of a migration — closing the first risk listed below.
3. **The color TOKEN moved from C3 into C2**, because the swatch row needs
   somewhere for its click to go. C3 is now the picker and the `SearchRules` bump
   alone.

## What already exists

- `asset_analysis.colors TEXT` — top-5 `[{"hex", "coverage"}]` JSON, schema v7,
  populated by `AnalysisBackfill` for every analyzed asset.
- `ColorSwatch` + `ColorExtractor` in **AtelierIngestion** — Lab-space k-means,
  pure and tested, returns swatches most-dominant-first.
- `AnalysisBackfill` — a resumable, idle-loop backfill (047 · 3a) that already
  owns "walk assets that need work, do a pass, sleep".

Nothing reads `colors`. `ColorSwatchTile` / `ColorSwatchWell` in the app are the
color-*kind* UI (`AddColorForm`) — a different feature that happens to share a
noun.

## The constraint that shapes everything

`ColorSwatch` and the Lab math live in AtelierIngestion. **AtelierCore cannot see
them** — the package dependency runs Ingestion → Core, and `AssetAnalysis.colors`
is an opaque `String?` in Core.

But the filter must be a WHERE conjunct inside `AppServices.searchAssets`, which
is Core. [367](../.change-log/367-the-archive-predicate.md) settled why: a search
predicate applied after the fetch shortens pages — a page of 50 that loses 7 rows
returns 43 — and the keyset cursor then pages through the gaps.

So the matching happens in SQL, in a package with no color types. The resolution
is the one this repo already uses for `asset_analysis.colors` itself and for
`SearchRules.rules`: **Ingestion owns the shape, Core stores it opaquely.**
Ingestion assigns a palette bucket; Core stores and filters an integer and never
learns what a color is.

## Schema — v21

One additive table. Colors are multi-valued (up to five per asset), so a
normalized table rather than `bucket1…bucket5` and a five-way OR:

```sql
CREATE TABLE asset_color (
    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
    bucket   INTEGER NOT NULL,   -- palette index; meaning lives in Ingestion
    coverage REAL NOT NULL,      -- 0…1, carried from the swatch
    rank     INTEGER NOT NULL,   -- 0 = most dominant
    PRIMARY KEY (asset_id, rank)
);
CREATE INDEX index_asset_color_on_bucket ON asset_color(bucket);
```

`ON DELETE CASCADE` so a deleted asset takes its rows with it, matching
`asset_analysis`. The index is on `bucket` because that is the filter's entry
point — the opposite of v19's no-index decision and for the same reason v20 ships
one: this predicate is the *leading* term of a library-wide scan, not a conjunct
riding an already-bounded query.

**If a later migration ever rebuilds `asset` (the v10 pattern), this table's
foreign key and index must be recreated.**

## The palette

Lives in AtelierIngestion beside `ColorExtractor`, as the one definition the
analyzer and the chip UI both read. The app target already links Ingestion.

Two rules, and the second is the one that is easy to get wrong:

1. **Hue buckets** — a fixed, named set (red, orange, yellow, green, teal, blue,
   purple, pink, brown).
2. **Chroma gate** — a swatch below a chroma threshold is a **neutral** (black /
   gray / white by lightness), regardless of what hue the arithmetic says. Without
   this, an off-white wall lands in whichever hue its 1% cast leans toward and
   every photograph becomes "orange". Neutrals are the majority of real
   photographic pixels and they need their own buckets, not a share of the hue
   ones.

Assignment is nearest-palette-entry in Lab, which is the space `ColorExtractor`
already clusters in — so the bucket agrees with how the swatch was formed.

## Backfill

Bucket assignment is a pure `hex → bucket` derivation. **It needs no blob bytes
and no image decode** — the hex is already in `asset_analysis.colors`.

So: a new resumable pass alongside `AnalysisBackfill`, not a migration body and
not an `analyzer_version` bump.

- A migration body would run at launch — fine at 500 assets, a stall at 50,000.
- An `analyzer_version` bump would re-decode every blob in the library to
  recompute data already sitting on disk.

The pass walks assets that have `colors` but no `asset_color` rows, which makes
it self-limiting and resumable with no new bookkeeping column.

## The conjunct

```sql
EXISTS (SELECT 1 FROM asset_color c
        WHERE c.asset_id = asset.id
          AND c.bucket = ?
          AND c.coverage >= ?)
```

**The coverage floor is applied at query time, not at write time.** All five
swatches are stored; the threshold is a documented constant in the query. Storing
only the ones above a floor would bake today's guess into the data and require a
re-backfill to revisit it.

Open for the build: whether selecting two chips means AND or OR. `tagMatch`
already establishes the vocabulary for that choice and the answer should reuse
it rather than invent a second one.

## Phases

| | What | Notes |
|---|---|---|
| **C0** | The palette + bucket assignment in Ingestion, with tests | Pure. No schema, no UI. The chroma gate is the load-bearing part. |
| **C1** | v21 table, `AppServices` writes + the conjunct, backfill pass | Core + the read-surface guard from [084](084-archive-shelf-plan.md) will fire on the new read. |
| **C2** | The detail swatch row | Clicking a swatch runs the filter — a swatch you cannot act on is the dead end I3's sparkle chips already are. |
| **C3** | The search filter chips + `SearchRules` v-bump | Saved searches gain a color dimension; `referencesUnknownVersion` badge path applies. |

`searchAssets` gains a **defaulted** color parameter. Unlike `includeArchived`
([367](../.change-log/367-the-archive-predicate.md) · 17A), "no color filter" is
correct for every existing call site and there is no caller for whom silence
would be a data-loss bug.

Nothing to do about archive: the conjunct rides the same query and inherits
`archived_at IS NULL`.

## Risks

- **Bucket granularity is fixed at analysis time.** Changing the palette means
  re-running the derivation pass. Cheap (no decode), but it is a re-run.
- **A color wheel is not reachable from this data.** It needs real Lab
  coordinates per swatch. Adding `l, a, b` columns is additive and the pass that
  would populate them is the one built in C1, so the door is open — deliberately
  not opened now.
- **The neutral gate is a judgement call** and the thing most likely to feel
  wrong in use. It gets its own tests and its threshold gets a named constant.
