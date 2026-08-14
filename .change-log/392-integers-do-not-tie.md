# 392 — Integers do not tie

A test that failed about half the time was pointing at a real defect: an asset could
be re-analyzed and never re-embedded, keeping a search vector that no longer matched
its own text. Permanently.

## The defect

`assetsNeedingEmbedding` decided "has the analysis moved since we embedded" by comparing
wall-clock time:

```sql
OR (an.analyzed_at IS NOT NULL AND an.analyzed_at > e.embedded_at)
```

Both columns are `TEXT`, written from `Date()` at millisecond resolution. A re-analysis
landing in the same millisecond as the embedding compares **equal**, not greater — so the
asset does not re-qualify, the new OCR text is never embedded, and nothing ever revisits
it. `embeddingsToReverify` would only catch it if the *content hash* changed, which it
did, but that sweep is oldest-first over the whole library and makes no promise about
when.

Rare in production, where analysis and embedding are usually separate passes. Reachable
whenever a coordinator runs them back to back over one asset.

## How it surfaced

`EmbeddingBackfillTests` "OCR re-run with the SAME text is a touch, not a re-embed"
failed intermittently — 2 of 3 serial runs, 1 of 2 parallel. It had been recorded in
changelog 391 as failing under `--no-parallel` only; **that was wrong**, and 391 is
corrected. It fails in both modes, and the full-bundle runs that passed did so by luck.

Inserting a 5 ms gap before the second write made it pass 6/6 where it had been failing
about half the time. That is the tie, measured.

## The fix — a monotonic marker (schema v23)

`analysis_seq INTEGER` on both `asset_analysis` and `asset_embedding`:

- every analysis write draws a number greater than any issued before, taken inside the
  serialized write transaction;
- an embedding records **which** analysis it accounted for;
- staleness becomes `an.analysis_seq > e.analysis_seq`, an integer comparison that cannot
  tie.

`markEmbeddingVerified` also adopts the current marker. A touch is the acknowledgement
that an analysis was looked at and its text was unchanged; bumping only `embedded_at`
would leave the asset re-qualifying forever once an analysis had drawn a higher number.

**The migration reproduces the old verdict exactly**, so an upgrade changes nothing about
which rows are pending: existing analyses are numbered in `analyzed_at` order (ties broken
by `asset_id`, so the numbering is total), and an embedding adopts its asset's number only
when `analyzed_at <= embedded_at` — precisely when the old predicate said "not stale".
Otherwise it stays NULL and re-qualifies, which is what the old predicate said too.

## The test that nearly wasn't a test

The first regression test wrote the analysis and the embedding back to back and asserted
the asset re-qualified — reproducing the bug by racing for it. **It did not work.**
Reverting the query to the old predicate still passed it five times out of five: the two
service calls are far enough apart that they do not reliably collide.

So the tie is now CONSTRUCTED, not raced for — the test forces
`analyzed_at == embedded_at` and asserts the asset still re-qualifies. Mutation-checked
both ways: 0 of 3 passes against the old predicate, passes with the fix.

This is worth stating plainly because the vacuous version looked completely convincing.
It exercised the right code, asserted the right thing, and passed — while guarding
nothing.

## Files changed

- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` — v23 + backfill
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — allocate/record/compare
- `AtelierCore/Sources/AtelierCore/Domain/AssetAnalysis.swift`, `AssetEmbedding.swift`
- `AtelierCore/Tests/AtelierCoreTests/MigrationTests.swift` — v23 backfill tests, and
  `v23` added to the pinned migration list
- `AtelierCore/Tests/AtelierCoreTests/ServicesEmbeddingTests.swift` — the tie regression,
  marker monotonicity, and that a touch settles the asset

## Migration notes

Additive columns, backfilled in the migration. No behaviour change on upgrade by
construction (see above), and the pinned-identifier test now expects `v23`.
