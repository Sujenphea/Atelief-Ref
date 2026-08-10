# 084 — An Archive Shelf, and the Second Library Behind It

> "A feature to have another library / archived section." Two requests that look
> alike and are not: **archive** is a place inside this library for things you
> don't want to see; **another library** is a second container entirely.
> Archive is small and was built; the second library is
> [016](feature-todo/016-library-management.md) §C, still deferred, and this doc
> says what archive must not do to it.
>
> Was `feature-todo/023-archive-and-second-library.md`. Promoted on shipping
> phase A, following the ritual of `.change-log/347` / `349` / `365`.

## Status: A shipped, B still deferred (2026-08-10)

**Phase A is complete**, in five commits over `feat/archive-shelf`:

| Phase | Commit | Changelog |
|---|---|---|
| A0 — extract the duplicated gallery-card queries | `44f2e93` | [366](../.change-log/366-gallery-card-queries-extracted.md) |
| A1 — v20 `archived_at`, the verbs, the predicate at every funnel | `64542ed`, `4a23879` | [367](../.change-log/367-the-archive-predicate.md) |
| A2 — `ShelfController` + the Archived destination | `6e8b0fa` | [368](../.change-log/368-the-archived-destination.md) |
| A3 — `ShelfIntent`, `E`, the verb on every surface | `5dede49` | [369](../.change-log/369-the-archive-verb.md) |
| A4 — the 016 stats row + the exhaustiveness guard | (this) | [370](../.change-log/370-what-the-shelf-is-holding.md) |

**Phase B is unchanged**: the second library is still deferred, and nothing in A
regressed its seams. `archived_at` is per-asset and therefore per-library by
construction.

### What was built differently from the plan below

The plan is left intact underneath; these are the four places the build
diverged, each because the code said something the review could not have known.

1. **`includeArchived` went on ONE funnel, not all of them.** Applied literally,
   the non-defaulted parameter was 158 call sites — and on the search side the
   `true` branch is unreachable, since archived items are excluded from search
   outright. It landed on `collectionItems`, which genuinely has callers on both
   sides: browsing passes `false`, and `LibraryArchiveWriter` passes `true`
   because a backup is a copy of the library rather than a view of it. That one
   compile error was the whole value of the decision.
2. **The manifest field moved from A4 to A1.** Once the writer included archived
   rows, carrying `archived_at` stopped being a nicety: without it every restore
   silently un-archives the user's whole shelf.
3. **`ShelfIntent` has no `surface` parameter**, though the plan asked for "per
   selection and surface". The surface is implied by the data — a browsing read
   hides archived items, so a collection selection is all-unarchived by
   construction — and a surface argument would be a second source of truth free
   to disagree with the first.
4. **The exhaustiveness guard became a two-link chain**: schema ⇄ `Asset` record
   (Core), and `Asset` record ⇄ manifest (app). A column added without a thought
   now fails a test twice, and the second failure is the one that matters — a
   field can work perfectly in-app while being dropped from every export.

### What the measurements said

`ScaleHarnessTests` at N=8000 with 2000 archived: `shelfAssets` 84 ms for 2000
rows (~42 µs/row) against ~57 µs/row for the collection read that already
returns a full array. The cost is row materialization, not the scan — the v20
partial index is doing its job — so **pagination stays out of v1 on evidence**,
not on assumption.

### Settled at build time, and worth knowing

- **No drag out, and no ⌘C, from the shelf.** Both are an *add*, and an
  added-but-still-archived item is invisible where it lands. The only way off
  the shelf is Unarchive. If copy-out is ever wanted, the honest version is
  add-implies-unarchive — a rule change in the paste path, not a flag.
- **Archiving from Unsorted is allowed.** Archive changes no membership, so the
  F3 invariant survives, and "not now" is arguably the verb's best use.

## Current state (verified)

- **No archive concept anywhere.** `AtelierCore/Persistence/` has no `archived`,
  `is_archived`, `deleted_at` or any soft-delete column; the schema is at **v19**
  (`Migrator.swift`), so an additive column would be `v20`.
- The only "out of sight" states that exist are:
  - deletion — `deleteAssetsRecoverable` (`AppServices.swift:1371`) captures a
    `DeletedAssetsBackup` for ⌘Z, but it is a *transaction-scoped* undo, not a
    browsable shelf. Blobs are reaped at the next launch.
  - Unsorted — the opposite of an archive (a to-do pile).
- "Archive" is already a **taken word** in this codebase and means something else:
  `LibraryArchive` / `LibraryArchiveWriter` / `ArchiveExportController` are
  [081](081-backup-plan.md)'s portable `.atelier` backup bundle. **Do not overload it.** Use *Shelf*,
  *Archived*, or *Vault* in code; user-facing copy can still say "Archived" if the
  export surface is renamed to "Backup" consistently.
- **Second library**: [016] §C already records the seams (`LibraryLayout` root is
  injected; the capture server + token are per-app not per-library; UserDefaults
  keys are un-namespaced). Nothing has regressed those.

## A — the archive shelf (build this)

### What it is

A per-asset flag that removes an asset from **every browsing surface** without
touching its memberships, its blob, or its history. Unarchiving restores it
exactly where it was — that is the whole point, and it is what a delete cannot
offer.

### The shape

**`asset.archived_at TIMESTAMP NULL`** — a nullable timestamp, not a boolean.
Same cost, and it buys the sort order ("recently archived" first), the "archived
3 months ago" copy, and any future auto-purge policy, for free.

### Code name (settled)

**`Shelf` in Swift, `archived_at` in SQL, "Archived" in the UI.** `LibraryArchive`
and friends keep meaning the backup bundle; nothing is renamed. The column name
stays as specced because [081](081-backup-plan.md)'s manifest field references
it, and the Swift-vs-SQL naming split already exists throughout this schema.

Renaming the backup family to `Backup*` — which is arguably the *correct* fix,
since that type is the actual misnomer — is a worthwhile standalone cleanup and
deliberately **not** ridden on this feature.

### Reads (settled)

One predicate, added at **the funnels, not the call sites**. The rule is
`archived_at IS NULL` unless the caller is the Archived surface, carried by an
`includeArchived: Bool` parameter that is **NOT defaulted**. A default is exactly
the shape that leaks: read #9 gets added and silently omits it. Non-defaulted
means every call site gets a compile error until someone decides, which is the
whole protection.

The funnel list is longer than this doc originally claimed. `AppServices.swift`
has 27 `FROM asset` sites; the ones that browse are:

| Funnel | Line | Note |
|---|---|---|
| `collectionItems(in:sort:)` | `:1693` | the P14 joined read behind every grid |
| `searchAssets(...)` | `:2386` | FTS + trigram + OCR union — **conjunct, see below** |
| the semantic/vector read | `:395` | same conjunct treatment |
| `collectionCovers(_:)` | `:1742` | an archived cover must fall back, not render a hole |
| `collectionStackPreviews(...)` | `:1772` | count **and** hash queries, which must agree |
| `spaceCovers(_:)` | `:2031` | |
| `spaceStackPreviews(...)` | `:2052` | |
| library stats | `:1546`, `:1564`, `:1590` | [016] **wants** archived counted, reported separately |

Two of those pairs are structurally identical copies of each other — see the DRY
note below, which is why the extraction happens **before** the predicate is added
rather than after.

**In `searchAssets` the predicate is a WHERE conjunct**, alongside the existing
`asset.id IN (…)` conjuncts (`:2590`, `:2603`) — never a post-filter over scored
results. Two reasons, and the second is the serious one: archived rows then never
reach the per-row correlated scorer at `:2730` (a speedup), and a post-filter
silently shortens pages — a page of 50 that loses 7 archived rows returns 43.

### Extract the duplicated queries first (settled)

`collectionCovers`/`spaceCovers` and `collectionStackPreviews`/`spaceStackPreviews`
are two structurally identical pairs — same shape, differing only in table names
and recency columns; `spaceStackPreviews`'s own doc comment calls itself "the
space analog of `collectionStackPreviews`". Adding the archive predicate naively
means **8 edits** (four count queries, four hash queries) that must agree
pairwise, and the failure mode when they don't is this doc's own named risk: a
collection reading "12 items" while showing 9.

So A1 begins with a refactor: one private `stackPreviews(parent:child:recency:)`
helper and one `covers(table:)` helper, both taking explicit table/column
parameters (parameters, not a query DSL). The predicate is then added **once**.
Existing `ServicesReadTests` / `LibraryStatsControllerTests` guard the move, plus
a new paired assertion that `itemCount` equals the visible hash count.

While that query is open, **scope the count aggregate to the roots being
rendered**. Today `SELECT collection_id, COUNT(*) FROM collection_item GROUP BY
collection_id` (`:1786`) is unfiltered — it counts every collection in the
library on every Home render and throws the non-roots away in Swift. The root ids
are already in hand two lines above, so this is a `WHERE … IN` over data we have,
not new machinery. Archive would otherwise turn a full aggregate into a full
indexed join.

### The surface

A sidebar destination beside Home / Spaces — **not** a collection. It is a view
over `archived_at IS NOT NULL` ordered newest-first, reusing the existing grid
host wholesale. Actions on it: **Unarchive** (clears the timestamp; the item
returns to its collections), **Delete** ([073]'s ⌘⌫, unchanged), and open detail.
Nothing else — no move, no add-to, no reorder: an archive you can reorganise is
just another collection.

Reachable from everywhere an item is: context menu "Archive", and a binding
worth having ([077] owns the map — `E` for a bare-key triage verb is the natural
slot next to `X`).

### Why a flag rather than a system collection

A reserved collection (the Unsorted pattern) was considered and rejected:
archiving would then *change memberships*, so unarchiving could not restore them,
and every "is this item in collection X" query would need to special-case the
reserved id anyway. The flag leaves memberships untouched, which is what makes
the round-trip lossless.

### Interactions

- **[073] delete**: ⌫ (remove) and archive are different verbs — remove drops one
  membership, archive hides the asset from all of them. Both stay.
- **[081] backup**: `archived_at` ships in the manifest and round-trips, or a
  restore silently un-archives the user's whole shelf.
- **[016] stats**: the Library pane should report archived count + bytes — that
  is precisely the "what can I reclaim" question archive creates. Note this is
  the one read that deliberately **includes** archived rows.
- **Blobs are NOT reaped for archived assets — and this needs no work.** An
  earlier draft of this doc said "the orphan sweep must skip them explicitly, or
  the shelf becomes a shelf of missing files." That was **wrong**.
  `referencedBlobHashes()` (`AppServices.swift:1489`) is
  `SELECT DISTINCT blob_hash FROM asset WHERE blob_hash IS NOT NULL` — an
  archived asset is still an `asset` row, so its blob is in the keep set by
  construction. What this needs is a **regression test**, not a code change.

### Four edge cases, settled before building (2026-08-10)

1. **An archived cover renders a hole.** `collectionCovers` (`:1746`) joins
   `asset ON asset.id = collection.cover_asset_id`. A *deleted* cover is handled
   by `SET NULL`; an *archived* cover is not null, so it stays a live cover of an
   invisible item. Fix: `AND asset.archived_at IS NULL` in the join, and the card
   falls back to its most-recent non-archived member — the same class of fallback
   a deleted cover already gets.
2. **The orphan sweep is safe already** — see above. Regression test only.
3. **Counts must join `asset`.** The count queries don't join it at all today.
   Covered by the extraction above and its paired count-vs-visible assertion.
4. **Destructive and write verbs on an archived asset.** Settled:
   - Delete an archived item → a normal recoverable delete, and **⌘Z restores it
     archived** — so `DeletedAssetsBackup` must carry `archived_at`. This is the
     assertion that catches a "restore forgets the flag" regression.
   - Archived assets stay **taggable and favoritable**. Archive hides an item from
     browsing; it does not freeze it, and a write verb that silently no-ops is
     worse than one that works on something you can't currently see.
   - Archived assets are **excluded from search** (both the FTS/trigram and the
     semantic path) and **included in [016] stats**, counted separately.

## B — another library (still deferred — [016] §C)

Nothing here changes that verdict. Two additions to the seam list, both created
by work landed since [016] was written:

6. `Collection.unsortedID` is referenced as a **constant** in UI code
   (`ItemDetailView.swift:1110`, and the `unsortedID` parameter threaded through
   `CollectionTargets`). If Unsorted becomes per-library, every one of those is a
   lookup, not a constant. Keep threading the id as a parameter — the existing
   `CollectionTargets` signatures already do this correctly; don't let new code
   reach for the static.
7. `archived_at` (A, above) is per-asset and therefore per-library by
   construction — no new coupling, provided the Archived sidebar destination
   scopes to the active library like every other destination.

If the second library is ever wanted sooner, the cheapest honest version is
**"open a different library root"** (relaunch-scoped, one window, one server) —
the `-library-root` launch argument already exercised by the grid bake-off
already proves the injection works. Simultaneous libraries in two windows is the
expensive version and is what [016] §C actually deferred.

## Schema / migration impact

- **v20**: `ALTER TABLE asset ADD COLUMN archived_at`. Additive, nullable, no
  backfill. Remember to append `"v20"` to `registeredIdentifiers`
  (`Migrator.swift:40`) **and** to the pinning test.
- **The partial index ships with v20** (revised): `CREATE INDEX … ON
  asset(archived_at) WHERE archived_at IS NOT NULL`.

  The original reasoning — that the un-archived predicate is the hot one and an
  index is useless for a null check on a column that is null for ~everything — is
  correct **for the hot path** and does not extend to the shelf itself. The
  Archived destination is `WHERE archived_at IS NOT NULL ORDER BY archived_at
  DESC` across the **whole library, with no collection scope**, and `asset` has
  no index that helps it (`source_id`, `blob_hash`, `created_at`, `view_count`,
  `dedup_key` — `Migrator.swift:617-621`). Without the index, every open of the
  shelf is a full `asset` scan plus a sort, on the one surface whose row count
  only ever grows: archiving is how you accumulate.

  A partial index over archived rows only is tiny and costs nothing on the hot
  path. One line at v20; a whole migration at v21. Ship it now.

  Pagination is explicitly **not** in v1. Note that `collectionItems`' "return the
  FULL array, no keyset cursor needed" reasoning (`:1682`) is justified by the
  read being *collection-scoped* — that justification does not hold for a
  library-wide shelf. Let the harness (below) say whether it ever matters.
- [081]'s manifest gains one optional field.

## Phased implementation

0. **A0 (M) — the query extraction**, before any archive code: the shared
   `stackPreviews` / `covers` helpers, plus scoping Home's count aggregate to its
   roots. Pure refactor; existing tests must be green before A1 starts.
1. **A1 (S–M)** — v20 migration (`archived_at` **+ the partial index**) +
   `archive` / `unarchive` in `AppServices` + the **non-defaulted**
   `includeArchived` parameter on the read funnels + the search conjuncts on both
   the FTS/trigram and semantic paths.
2. **A2 (M)** — `ShelfController` + the Archived sidebar destination (grid host
   reuse) + Unarchive. The controller follows the shipped feature-controller
   pattern (`@MainActor final class … ObservableObject`, own test file) already
   used by `LibraryStatsController`, `DuplicateReviewController`,
   `RestoreController` and `BackupController` — **not** another ~200 lines inside
   `IngestionModel.swift`, which is already the largest file in the repo at 3,599
   lines.
3. **A3 (S)** — a pure `ShelfIntent` deciding verb availability and label per
   selection and surface, consumed by the grid / detail / space context menus and
   the key binding ([077]). Mirrors `DeleteIntent` + `DeleteIntentTests`: the
   mixed-selection question (some archived, some not) is real logic and belongs
   somewhere testable, not inline in a view body.
4. **A4 (S)** — [081] manifest field + [016] stats row + the orphan-sweep
   regression test (no code change — see Interactions) + the manifest
   exhaustiveness guard.
5. **B (0)** — discipline only; no code.

## Test strategy

**Round trip, at full fidelity.** Archive → absent from collection read, space
read, search, counts, gallery previews → unarchive → **byte-identical memberships
and order**. Not a count-level assertion: capture the ordered membership arrays,
the `manual_order` values, the space placement rows, tags and note *before*
archiving and assert identity after, over an asset that is in **≥2 collections
and ≥1 space**. Losslessness is the feature's entire justification over delete,
so this is the assertion that makes its premise falsifiable — and it is exactly
where a delete-and-recreate-memberships implementation would pass a weaker test
and fail this one. `ServicesCollectionOrderTests` / `ServicesSpaceOrderTests` are
the precedent for order-level assertions.

**The funnel predicate, in two layers** — they catch different failures:

1. *Shape*: a source-scan test in **`AtelierCoreTests`** that reads
   `AppServices.swift` via `#filePath` and asserts every `FROM asset` / `JOIN
   asset` site is in an explicit allowlist with a stated reason. This is the only
   thing that fails when a **new** read is added. It must live in the SwiftPM
   target: the app test host is the sandboxed app and cannot read repo source
   files — `ConfigContractTests.swift:8-16` documents the EPERM. Precedent for
   shape-level canaries: the extension's `src/drift.js` `CHECKS`.
2. *Behaviour*: seed one archived asset, call each browse read, assert absence —
   this is the only thing that fails when a read **misapplies** the predicate.

**Verb availability**: `ShelfIntent` over all-archived / none-archived / mixed /
empty selections, on the shelf itself, and on the protected Unsorted case.

**Orphan sweep** over a library whose only reference to a blob is an archived
asset → blob survives. Asserts the by-construction safety, so a future change to
`referencedBlobHashes` can't quietly break it.

**Backup round-trip**, following the favorites precedent exactly — that trio is
the template ([081]'s suite already has "Favorites survive…", "A favorite on a
multi-collection asset survives in every collection", "Re-importing an unstarred
archive never unstars what is here"). Plus **one exhaustiveness guard**: every
`asset` column is either in the manifest or in a named derived-and-excluded list.
[081] already states that rule in prose (`asset_analysis` and embeddings are
derived and excluded); nothing currently *enforces* it, which is how a future
column gets silently dropped from a backup.

**Delete an archived item** → normal recoverable delete; ⌘Z restores it
*archived* (so `DeletedAssetsBackup` carries the column).

**Measurement**: extend `ScaleHarnessTests` — which already seeds N assets at an
env-overridable count and times `collectionItems` + FTS search, the two funnels
this feature modifies — with a seeded-archived variant (N assets, M archived)
timing the shelf read, both stack-preview calls, and the search conjunct. It is
env-gated, so CI cost is zero, and it turns the index and aggregate decisions
above into measured ones rather than asserted ones.

## Effort: **A: M–L total (A0 M · A1 S–M · A2 M · A3 S · A4 S) · B: 0**

Larger than the original "A: M" estimate, because A0 (the query extraction) was
added and A1 grew the search conjuncts, the index and the source-scan test. The
extraction is not overhead: without it the same predicate work happens eight
times over instead of once.

## Risks & edge cases

- ~~**The word collision with `LibraryArchive`.**~~ **Resolved**: `Shelf` in
  Swift, `archived_at` in SQL, "Archived" in the UI. Nothing is renamed.
- ~~An archived item that is a **collection cover**.~~ **Resolved**: filter the
  join and fall back to the most-recent non-archived member (edge case 1).
- ~~An archived item **placed on a Space board**.~~ **Resolved**: the tile
  vanishes and unarchive restores the placement.
- **Counts are the sneaky surface** — a collection reading "12 items" while
  showing 9 is worse than either number being wrong. This is why A0 extracts the
  duplicated queries *before* the predicate is added: the naive route is 8 edits
  that must agree pairwise, and one missed edit produces exactly this.
- **The read surface is bigger than four funnels.** The source-scan test exists
  because a hand-maintained list of reads is the thing that drifts.

## Open questions — closed 2026-08-10

1. ~~Code name?~~ **`Shelf` in Swift, `archived_at` in SQL, "Archived" in the
   UI.** Nothing is renamed; the `Backup*` rename of the existing archive family
   is a worthwhile separate cleanup, deliberately not ridden on this feature.
2. ~~Does archiving a **collection** make sense?~~ **Assets only in v1.**
   Archiving a container makes an asset in two collections ambiguous — unarchiving
   one collection would have to decide whether shared assets come back — and that
   ambiguity is precisely what the per-asset flag avoids. The lossless round trip
   stays trivially true.
3. ~~Auto-purge after N months?~~ **Never automatically.** Surface archived age
   and bytes in [016]'s stats and let the user act. A scheduled deleter is a large
   new risk surface for a feature whose whole premise is that nothing is lost.
4. **Second library**: still open, still deferred. If it is ever wanted sooner,
   the cheapest honest version is the relaunch-scoped "open a different library
   root" described in §B — not simultaneous libraries in two windows.

### Also settled

**An archived asset placed on a Space board: the tile vanishes**, and unarchiving
restores the placement exactly — which works only because the placement row is
never touched. "Archived" then means one thing everywhere rather than something
different on boards.
