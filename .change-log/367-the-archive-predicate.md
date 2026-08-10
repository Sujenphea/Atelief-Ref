# 367 — The Archive Predicate, at Every Funnel

[084](../.docs/084-archive-shelf-plan.md) phase **A1**. The
shelf now exists in the data layer: a column, two verbs, and one predicate
applied at every read that browses. No UI yet — that is A2.

Builds on [366](366-gallery-card-queries-extracted.md), which extracted the
duplicated cover / stack-preview queries first precisely so this change had one
place to go per pair instead of eight.

## Schema — v20

`asset.archived_at`, nullable TEXT, plus a **partial index** over the archived
rows only. A timestamp rather than a flag, at the same storage cost: it buys the
shelf's "most recently archived first" order and any future purge policy without
a second migration.

v19 (favorites) deliberately shipped no index and pinned that fact in a test;
v20 deliberately ships one and pins that. The difference is the surface: the
favorites conjunct rides an already-bounded query, while the shelf is
`archived_at IS NOT NULL ORDER BY archived_at DESC` across the whole library
with no collection scope, on the one read whose row count only ever grows.

## The verbs

`archive(_:)` / `unarchive(_:)` follow `setFavorite`'s contract exactly — one
transaction, missing ids ignored, changed-row count returned for undo. Two
refinements worth naming:

- **Re-archiving keeps the ORIGINAL timestamp.** The `UPDATE` is filtered to
  `archived_at IS NULL`, so archiving something already on the shelf does not
  quietly reshuffle it to the top.
- `archivedAssetIDs(among:)` mirrors `favoritedAssetIDs(among:)` for the mixed
  selection A3's `ShelfIntent` will ask about.

## Where the predicate went — and where it did not

The plan said one non-defaulted `includeArchived` on every browse funnel. Applied
literally that is **158 call sites**, and on the search side the `true` branch is
unreachable: 023 settles that archived items are excluded from search, full stop.
A parameter with one reachable value is not explicitness, it is noise on every
future call site.

So it went where two answers actually exist:

| Funnel | Shape |
|---|---|
| `collectionItems` | **non-defaulted `includeArchived`** |
| `searchAssets`, the semantic read, `covers`, `stackPreviews` | no parameter — always exclude |
| `shelfAssets` | new function; only archived |
| stats, analysis queues, blob keep-set | untouched — they *want* archived rows |

`collectionItems` earns the parameter because of one caller:
**`LibraryArchiveWriter` walks the library through it to build the backup.** A
default there would mean every backup silently omitted the user's shelf and every
restore lost it. Non-defaulted turns that into a compile error, which is exactly
what happened — and the writer now passes `true`.

That in turn made [081](../.docs/081-backup-plan.md)'s manifest field
load-bearing **now** rather than in A4: exporting archived items without carrying
`archived_at` would restore the shelf into the middle of the user's collections.
So `archived_at` rides the manifest, `ImportItem.isArchived` rides the plan, and
`ImportReplay` applies it like the star — additively, never replaying `false`.

Two details that are easy to get wrong and are written down in the code:

- **In search it is a WHERE conjunct, never a post-filter.** A post-filter
  shortens pages: a page of 50 that loses 7 archived rows returns 43, and the
  keyset cursor then pages through the gaps.
- **The stack-preview count needed a LEFT join.** It did not join `asset` at all
  before. An inner join would have silently dropped a Space's element rows
  (NULL `asset_id`) and made every board card under-count.

## Tests — 680 in Core (was 666), plus 3 app round trips

Three layers, because they fail for different reasons:

1. **Behaviour** (`ServicesShelfReadTests`, 10 tests) — one case per surface:
   grid, search (alone, composed with tag + scope + star, and paged), semantic,
   covers, both stack-preview pairs, the shelf itself, and the orphan sweep.
2. **Shape** (`AssetReadSurfaceTests`) — a source scan over `AppServices.swift`
   pinning all **24** functions that read the `asset` table, each with a written
   reason. This is the only thing that fails when a *new* read is added a year
   from now. Mutation-verified: adding an unpinned read fails it by name.
3. **Losslessness** (`ServicesShelfTests`) — full-fidelity, not count-level: an
   asset in two collections and one space keeps its ordered memberships,
   placement, tags, note and star across archive → unarchive, and ⌘Z restores a
   deleted archived item **still archived**.

The archive round trip follows the favorites trio exactly, including its negative
half: an archive that says "not archived" must not pull an item off a shelf the
user built in the destination library.

## What the harness now says about pagination

`ScaleHarnessTests` archives a quarter of the seeded library and times the shelf.
At **N=8000, 2000 archived**:

```
shelfAssets:     84 ms  (2000 rows, no cursor)
collectionItems: 340 ms (6000 rows, predicate on)   [472 ms for 8000 before]
search 'swatch':  32 ms (page of 50)
```

~42 µs/row for the shelf against ~57 µs/row for the collection read that already
returns a full array — so the cost is row materialization, not the scan, and the
partial index is doing its job. **Pagination is not warranted yet**, which is now
a measurement rather than an assumption.

## Files changed

- `AtelierCore/…/Persistence/Migrator.swift` (v20), `Domain/Asset.swift`
- `AtelierCore/…/Services/AppServices.swift`
- `AtelierRefs/…/LibraryArchive.swift`, `LibraryArchiveWriter.swift`,
  `LibraryArchiveReader.swift`, `ImportPlan.swift`, `ImportReplay.swift`
- Tests: `ServicesShelfTests` (new), `ServicesShelfReadTests` (new),
  `AssetReadSurfaceTests` (new), `MigrationTests`, `ScaleHarnessTests`,
  `LibraryArchiveRoundTripTests`, and every `collectionItems` call site

## Migration notes

**v20 is append-only and shipped.** `registeredIdentifiers` and the pinning test
both carry `"v20"`; the body must never be edited. If a later migration ever
rebuilds `asset` (the v10 pattern), it must recreate
`index_asset_on_archived_at` — indexes drop with their table.

`collectionItems(in:sort:includeArchived:)` is a **source-breaking** signature
change by design. Every call site was updated; a new one must decide. Nothing
else in the public API moved.
