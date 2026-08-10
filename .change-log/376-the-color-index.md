# 376 — The Color Index, and the Predicate That Uses It

[085](../.docs/085-color-filter-plan.md) phase **C1**. Schema v21, the search
conjunct, and the pass that derives one from the other. No UI yet — that is C2
and C3.

## Schema v21

```sql
CREATE TABLE asset_color (
    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
    bucket   INTEGER NOT NULL,
    coverage REAL NOT NULL,
    PRIMARY KEY (asset_id, bucket)
);
CREATE INDEX index_asset_color_on_bucket ON asset_color(bucket, coverage);
ALTER TABLE asset_analysis ADD COLUMN colors_palette_version INTEGER;
```

Derived, not authoritative: `asset_analysis.colors` stays the source of truth and
stays opaque JSON. These rows exist because the filter must be a SQL predicate —
a post-filter shortens pages and the keyset cursor then pages through the gaps
([367](367-the-archive-predicate.md)) — and AtelierCore cannot see the imaging
types that know what a color is.

**Changed from the plan: no `rank` column, and `(asset_id, bucket)` as the key.**
Because C0 merges same-bucket swatches, a bucket appears at most once per asset,
so the composite key IS the merge invariant; display order falls out of `coverage
DESC`. A stored rank would be a second thing to keep consistent with it.

The index is `(bucket, coverage)` — the filter's own shape. The PK serves the
correlated `asset_id` probe from the other side, so SQLite can drive the join
from whichever end is more selective.

## The conjunct

```sql
EXISTS (SELECT 1 FROM asset_color c
        WHERE c.asset_id = asset.id AND c.bucket IN (…) AND c.coverage >= ?)
```

**EXISTS, not a JOIN.** A join against a multi-row side multiplies the result: an
asset that is both red and blue would come back twice from a search for
red-or-blue, as a duplicate tile in the grid.

`.any` (the default) is one EXISTS over `bucket IN (…)`; `.all` is one per
bucket, AND-combined. Same `TagMatch` vocabulary as the tag filter — a second
word for "match every one of these" would be a second thing to learn.

The coverage floor is a **defaulted parameter** (0.15), applied at query time.
Every bucket is stored, so what counts as "this image is red" can be re-judged
without re-deriving a row. Unlike `includeArchived`, defaulting is right here:
"no color filter" is correct for every existing call site and there is no caller
for whom silence would be a data-loss bug.

## The flaw the tests found

The derivation queue was first written as *"has `colors`, has no `asset_color`
rows"*. `ColorBucketBackfillTests` failed on the case the design comment claimed
to handle: **an asset whose palette JSON is unreadable derives zero rows, which
is indistinguishable from "not derived yet"**, so it is handed back on every pass
forever and `drain()` spins to its batch cap on every launch.

Row count cannot mark work as done. The fix is `colors_palette_version` on
`asset_analysis`, beside the `analyzer_version` it mirrors — and storing the
VERSION rather than a boolean buys a second thing 085 listed as a risk: a palette
change (new bucket, retuned threshold) is now a WHERE clause instead of a
migration. Bump `ColorPalette.version`, and every asset re-derives from the hex
already on disk with nothing decoded.

A third property falls out for free and is pinned rather than left to be
rediscovered: `upsertAnalysis` writes a fresh row whose palette version is nil,
so **re-analysis re-queues the asset** — which is correct, since new colors make
old buckets stale by definition.

## Tests — 710 in Core (was 685), 390 in Ingestion (was 381)

- **`MigrationV21Tests` (5)** — the composite PK, the index's column order, the
  cascade asserted by actually deleting an asset, and that upgrading from v20
  leaves `asset` untouched and the table empty.
- **`ServicesColorTests` (20)** — the write contract (replacement, not append;
  empty clears), the queue, and the conjunct's load-bearing properties: an asset
  matching two requested colors returns ONCE, an archived asset never matches,
  color composes with free text, and a filtered page is full length with a
  working cursor.
- **`ColorBucketBackfillTests` (9)** — the loop, not the arithmetic: resumability,
  the unreadable-palette wedge, the version bump, and one end-to-end case from
  swatch JSON to search hit.

Mutation-verified: the coverage floor set to 0 fails two cases; `.all` reduced to
checking one bucket fails `allMatch`. The read-surface guard from
[084](../.docs/084-archive-shelf-plan.md) fired on `assetIDsNeedingColorBuckets`
and now carries its reason — deliberately queues archived assets, since
unarchiving one that had been skipped would leave a permanent hole in the filter.

## Files changed

- `AtelierCore`: `Migrator.swift` (v21), new `Domain/AssetColor.swift` +
  `Persistence/AssetColor+GRDB.swift`, `Domain/AssetAnalysis.swift`,
  `AppServices.swift`, `MigrationTests`, `AssetReadSurfaceTests`, new
  `ServicesColorTests`
- `AtelierIngestion`: new `Analysis/ColorBucketBackfill.swift` +
  `ColorBucketBackfillTests`, `Imaging/ColorPalette.swift` (`version`)

## Migration notes

**v21 is append-only and shipped.** `registeredIdentifiers` and the pinning test
both carry `"v21"`; the body must never be edited. If a later migration rebuilds
`asset` (the v10 pattern), it must recreate `asset_color`'s foreign key and
index — both drop with their table.

`AssetAnalysis` gains a defaulted `colorsPaletteVersion`, so existing
construction sites compile unchanged. Nothing schedules the backfill yet; C2
wires it into `AnalysisCoordinator`.
