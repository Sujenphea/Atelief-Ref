# 465 — the corpus goes resident

[099 · P0b](../.docs/099-mac-backlog-plan.md#p0b--the-semantic-corpus-cache-conditional-on-p0s-number)
— the phase [463](463-the-packages-get-their-foundations.md)'s measurement gate scheduled.
P0 timed `semanticSearchAssets` at **1,547 ms warm over 20,000 vectors**, fifteen times the
~100 ms the plan set as the point where a cache earns its memory, and dead linear at ~77 µs
per vector. So: a `Sendable` resident corpus in `AtelierCore`, keyed by model version,
scored with Accelerate, topped-k by partial selection.

AtelierCore only. No file under `AtelierRefs/` was touched; the app calls the same function
with the same signature and does not know anything changed.

## The numbers, before and after

Debug build, one machine, `ATELIER_SCALE_N=<N> swift test --filter ScaleHarness`. **Before**
is the tree at `0632320` re-measured in this session; it reproduced 463's independent run to
within 3% at every N, so the baseline is not in question. **After** is the median of seven
runs per N, because the new numbers are not as stable as the old ones — see the last section.

### Warm — every search after the first

| N | before | after (median of 7) | spread | |
|---|---|---|---|---|
| 300 | 24.7 ms | **3.6 ms** | 3.3 – 5.1 | 7× |
| 1,000 | 78.5 ms | **4.6 ms** | 4.3 – 16.4 | 17× |
| 5,000 | 383 ms | **14.0 ms** | 13.6 – 18.0 | 27× |
| 10,000 | 764 ms | **28.4 ms** | 24.4 – 204 | 27× |
| **20,000** | **1,535 ms** | **58.6 ms** | 46.0 – 114 | **26×** |

Warm, scoped to one collection:

| N | before | after (median of 7) | |
|---|---|---|---|
| 300 | 24.9 ms | 3.9 ms | 6× |
| 1,000 | 77.6 ms | 5.3 ms | 15× |
| 5,000 | 392 ms | 20.0 ms | 20× |
| 10,000 | 778 ms | 43.7 ms | 18× |
| **20,000** | **1,718 ms** | **84.4 ms** | **20×** |

### Cold — the first search of the process, including the corpus load

| N | before | after (median of 7) | spread | |
|---|---|---|---|---|
| 300 | 26.2 ms | **5.9 ms** | 5.2 – 7.1 | 4× |
| 1,000 | 80.5 ms | **10.1 ms** | 9.0 – 51.0 | 8× |
| 5,000 | 387 ms | **47.9 ms** | 36.4 – 51.9 | 8× |
| 10,000 | 789 ms | **94.0 ms** | 81.7 – 222 | 8× |
| **20,000** | **1,676 ms** | **303 ms** | 266 – 1,515 | **5.5×** |

**The plan's ~100 ms threshold is now met warm at every N up to 20,000, and cold up to
10,000.** Cold at 20,000 is 303 ms and is paid once per process.

**Cold is also the number that took two attempts, and the first attempt made it worse.** That
is the substance of this entry.

## Cold was the whole problem, and the first design did not fix it

The obvious shape — hold the vectors, keep the scope query live, intersect — makes the warm
query almost free and leaves cold exactly where it was, because the first query still has to
read and decode every BLOB. The first implementation measured:

| N | before (cold) | first attempt |
|---|---|---|
| 5,000 | 387 ms | 454 ms |
| 10,000 | 789 ms | 862 ms |
| 20,000 | 1,676 ms | 1,691 ms |

Slightly **worse**, and predictably so: the same decode, plus a candidate scan the old single
query did not need. For a user who searches once per launch — which is most searches — the
cache would have bought nothing at all. That is the finding this phase would have had to lead
with, and it was very nearly the one it reported.

A guess at the fix made it worse again. Replacing the per-lane decode with a `memcpy` into
an array that was still grown one row at a time measured 474 / 919 / 1,813 ms — the zero-fill
the append needed cost more than the arithmetic it replaced.

Two guesses, both wrong, both slower. So the load was profiled rather than argued about, at
N = 5,000:

```
a  candidate ids only         8.8 ms
b  COUNT(*)                   0.2 ms
c  fetch all 5,000 blobs      8.6 ms      (10 MB out of SQLite)
d  …plus parsing 5,000 uuids 12.4 ms
e  the whole corpus load     443 ms
f  scalar per-lane decode    397 ms
g  preallocated matrix
   + one memcpy per row       14.5 ms     (including the fetch)
```

**SQLite hands over all 10 MB in 8.6 ms. Turning it into floats one
`loadUnaligned` at a time cost 397.** The 77 µs per vector P0 measured was never I/O and
never the sort — it was `(0..<512).map { … }`, 10.2 million times, in an unoptimized build.

Two changes followed, and together they are the cold column above:

1. **The matrix is allocated once.** `EmbeddingCorpusBuilder` takes a `COUNT(*)` upper bound
   and allocates `rows × 512` floats up front, then writes each row into its window. This is
   the half the two failed guesses missed: growing the matrix per row cost more than decoding
   into it, whichever way the decode was spelled.
2. **A row is a `memcpy`.** The stored layout is pinned little-endian precisely so a library
   file is portable; on a little-endian host that layout IS the in-memory one, so
   `AssetEmbedding.copyVector` copies bytes straight into the matrix's `Float`-typed
   storage. The per-lane path survives behind a `hostMatchesStoredByteOrder` check, which is
   the only thing that makes the pinning mean anything.

The destination is the matrix's own storage, so it is `Float`-aligned by construction and
the `Data`'s alignment — which nothing guarantees — cannot make the copy ill-formed.

## What the cache is, and the one property it rests on

`EmbeddingCorpus` holds `ids: [UUID]`, one contiguous row-major `matrix: [Float]` 512 wide,
and a `[String: Int]` from the stored key form to a row. `EmbeddingCorpusCache` holds exactly
one of them, keyed by `(modelVersion, dimensions)`.

**The cache is never asked what exists.** The structured scope — collection, tag, colour,
favourite, platform, and the archive predicate — still runs as live SQL on every single
query, exactly as it did; what changed is that it now selects `e.asset_id` instead of
`e.asset_id, e.vector`. The corpus answers only "what is this asset's vector", and the two
are intersected by id.

That is not a detail, it is the safety argument. **A stale corpus cannot surface a deleted
or an archived asset**, because membership was decided by a query against the current
snapshot and the corpus was not consulted. Two tests assert it directly by warming the
corpus, archiving an asset without invalidating anything, and demanding it disappear — and
the same for moving an asset out of the scoped collection. The worst a stale corpus can do
is rank something against a vector one re-embed old.

**Keyed by width as well as version**, so the cached path reproduces the old one exactly.
The un-cached query scored a stored vector only when its length matched the query's and
skipped the rest; a corpus is now precisely the set of rows a query of THAT width would have
scored, and the filter moved into SQL as `length(vector) = dimensions * 4`.

### Top-k without a sort

`TopKSelector` is a bounded min-heap of size k — the root is the WORST kept candidate, so an
offer that cannot beat it is rejected in one comparison. The order it produces is the one the
full sort produced and must stay: score descending, then id ascending in `uuidString` order.

The tiebreak compares the uuid's raw bytes rather than building two strings, because
`UUID.uuidString` allocates and the tiebreak is reached on every exact score tie in a
20,000-row scan. The two orders are the same order, and not by luck — `uuidString` is the
bytes as fixed-width hex with the separators at fixed positions, and ASCII orders `0`–`9`
before `A`–`F` in the same order as the values they stand for. A test asserts it against
`uuidString` over 500 random pairs and 500 more that differ only in their final byte, because
that is exactly the kind of claim that should not be taken on trust.

### The generation guard

A cold load of 40 MB is slow enough for a write to commit underneath it. So every load reads
the cache's generation before it starts and publishes only if it has not moved; a corpus
assembled from a snapshot older than the last invalidation is used for the query that asked
for it and then thrown away. Without that, a fast `upsertEmbedding` racing a slow first query
would leave the stale corpus resident with nothing left to clear it.

`invalidate()` runs immediately after its write commits, not atomically with it, so there is
a residual window — a load that read the pre-commit snapshot and publishes inside that gap is
accepted and then dropped a moment later. A query landing there ranks one vector against its
previous value. It is written down on `EmbeddingCorpusCache` rather than papered over.

## The two-writer claim: verified, and it holds

The plan asserts `upsertEmbedding` and the asset delete are the only two writers. Checked
against the tree rather than taken on faith:

- **`asset_embedding` is written by `upsertEmbedding` alone.** Nothing else in any package
  inserts or updates it. `markEmbeddingVerified` touches `embedded_at` / `analysis_seq` and
  never the vector, so it deliberately does not invalidate.
- **Assets are deleted by `Self.performDelete` alone**, reached from exactly two public
  entry points — `deleteAssets` and `deleteAssetsRecoverable` — and `asset_embedding.asset_id`
  CASCADEs. Both entry points invalidate. That the cascade is what removes the row is
  precisely why the invalidation must be spelled at the entry points rather than left to
  whoever remembers it.

Four paths that could plausibly have been a third writer, and were checked:

- **The archive import does not carry embeddings.** `LibraryArchive` excludes
  `asset_analysis` and `asset_embedding` by design — they are recomputable, and writing them
  would freeze an analyzer version into a portability contract. Import goes through `ingest`.
- **Delete-undo does not restore them either.** `captureBackup` snapshots assets, sources,
  memberships, tag links and covers; no embedding row is in a `DeletedAssetsBackup`, so ⌘Z
  brings an asset back un-embedded and the backfill re-embeds it through `upsertEmbedding`.
  A comment at the restore site says so, so the next reader does not have to re-derive it.
- **Snapshot restore replaces the database file BEFORE `AppServices` opens.**
  `SnapshotManager.applyPendingRestore` runs at bootstrap with no writer yet, so a restored
  library gets a fresh services object and an empty cache. No invalidation is needed and none
  would help.
- **Migration v23 writes `asset_embedding.analysis_seq`** — inside `LibraryDatabase.init`,
  before any query can have loaded anything.

**The claim held.** Nothing else writes an embedding or deletes an asset.

## The load-bearing test

`ServicesSemanticCorpusTests` carries a transcription of P0's implementation — the same
scope SQL, the same per-row BLOB decode, the same `vDSP_dotpr`, the same full sort by
(score descending, uuidString ascending), the same `prefix(limit)`. Every equivalence
assertion compares against **that**, not against a memory of it.

The fixture is forty assets over seven distinct vectors, so exact ties are the common case
rather than a path the data never reaches; it spans two collections, one asset in three
favourited, one in five on the shelf, and five embedded at a second model version. The
comparison runs at k = 0, 1, 3, 7, 50 and 500 across four scopes — library-wide, one
collection, favourites, and both at once. A separate test asserts the fixture really does
tie, and that the tied block comes back in id order, so the tiebreak is exercised rather
than assumed.

Both were checked against a deliberately broken build: reversing the tiebreak fails the
service-level equivalence test, the tied-block test, and the pure selector test. The
equivalence test also asserts its own scopes are non-empty, since `[] == []` passes.

## What a malformed vector does, and why

**Skipped, not rejected.** `asset_embedding.vector` is derived data that a re-embed
rewrites, so one bad row is a row the next backfill pass fixes; refusing the whole query over
it would take the library's meaning search down until someone noticed. It is also exactly
what the un-cached path did — it skipped any vector whose length did not match the query's
and carried on ranking the rest.

Three shapes are refused by the builder and counted: a key that is not a uuid, a blob that is
not exactly `dimensions × 4` bytes (too long as well as too short), and a duplicate key. The
skip must not shift the rows after it, which is the half a careless `continue` gets wrong, so
a test asserts the surviving rows keep their indices and their matrix windows.

And because the corpus is keyed by width, "skipped" does not mean "unreachable": a test
overwrites one row with a 4-float vector, shows it drops out of the 512-wide ranking, and
then finds it — and only it — with a 4-float query.

## Memory, stated

**2 KB per embedded asset, resident.** 512 × Float32. At 20,000 that is 39.1 MB of matrix,
plus 0.3 MB of ids and roughly 1.8 MB of key index — the harness prints **41.2 MB** at
N = 20,000 and asserts the corpus really holds all 20,000 rows. The matrix and the ids are
exact; the index figure is an estimate at 96 bytes a row, and it is the only part of the
number that is.

There is **no eviction policy and no bound**, because the plan did not ask for one and a
bound that drops the corpus mid-session hands the user back the query this exists to remove.
One slot rather than a dictionary, so a mid-model-upgrade library still costs one corpus, not
one per version.

**Is 40 MB acceptable without a bound? At 20,000 items, yes** — it is proportional to a
library the user chose to build, and it is what buys a 1.5-second search back. The judgement
that would change is a library an order of magnitude larger:
200,000 items is 400 MB and should not be resident. That is a real ceiling and it is not
addressed here; it is named below rather than solved by an eviction policy nobody asked for.

## Verification

`./scripts/verify.sh` (full):

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target
  ⚠ Extension

All 12 stages passed, 1 with a warning above.
```

Exit 0, `App target` at **TEST SUCCEEDED**. `⚠ Extension` is
[464](464-the-gate-tells-its-two-arms-apart.md)'s stale Instagram fixture, exit 2 — not a
failure and not this phase's.

**It took three runs, and neither of the first two failed on anything this phase wrote.**

**SwiftPM did not notice the new file across a path dependency.** Every package that depends
on `AtelierCore` by path — Capture, Browse, Archive, Ingestion, Server — built AtelierCore
from a source list that predated `EmbeddingCorpus.swift`, and failed with *cannot find
'EmbeddingCorpusCache' in scope* against a file sitting in the directory it was reading.
AtelierCore's own stage was green throughout, so a phase that adds a file to Core and runs
`swift test` only there would not see this at all. One `swift build --build-tests` inside each
consumer cleared it permanently; a failed `swift test` did not, which is why the second run
still carried four of them. Worth knowing before the next phase adds a file to a shared
package and reads the same error as its own bug.

**The app suite flaked once, on timing.** Run 2's `App target` failed with eleven
`ThumbnailPipelineTests` / `ThumbnailWindowPrefetcherTests` cases while the machine carried a
load average of 34 on 8 cores. Those are the fixed-sleep suites 099 · P1 · 11A exists to
replace; nothing in them touches an embedding, and they passed in runs 1 and 3.

## Tests added

**43 new `@Test`s**, no existing test changed. AtelierCore's suite goes 785 → 828.

- `AtelierCoreTests` · `EmbeddingCorpusTests` (31) — the pure half. Byte order IS uuidString
  order (500 random pairs plus 500 last-byte siblings); `precedes` is irreflexive; the
  bounded heap agrees with a full sort at six values of k over forty tie-heavy trials; limit
  0; a negative limit; fewer offers than the limit; an all-tied field; the matrix is
  contiguous and row-major; a wrong-width blob is skipped, counted, and does not shift later
  rows; an over-long blob; an empty blob; a non-uuid key; a duplicate key; an empty corpus;
  the 2 KB-per-vector cost; ranking by dot product; an unknown candidate key; a resident
  vector outside the candidate set; a wrong-width query; limit 0 and an empty candidate set;
  a corpus smaller than the limit; a hit does not reload; invalidate forces a reload; another
  model version evicts; another width evicts; a load that raced an invalidation is never
  published; a quiet load is; a throwing load leaves the slot empty; `copyVector` agrees with
  `vectorFloats` and writes only its own window; `copyVector` on empty data; a 512-wide row
  survives the matrix round trip lane for lane.
- `AtelierCoreTests` · `ServicesSemanticCorpusTests` (12) — the database half. The cached
  path returns exactly what the un-cached path returned; the fixture really ties and the tied
  block is in id order; an upsert invalidates and the next query sees the new vector; an
  asset delete invalidates and the id never returns; the recoverable delete too; a warm
  corpus cannot show an asset the live scope excludes; a warm corpus does not freeze
  collection membership; versions do not mix; an unknown version is empty; an empty corpus, a
  corpus smaller than k, and k = 0; a wrong-width vector on disk is skipped and the rest still
  ranks; the corpus is loaded once and reused.

`ScaleHarnessTests`' semantic row now reports the resident corpus's row count and megabytes,
and asserts the corpus holds every seeded vector.

## Files

Added:

- `AtelierCore/Sources/AtelierCore/Services/EmbeddingCorpus.swift` — `EmbeddingCorpus`,
  `EmbeddingCorpusBuilder`, `TopKSelector`, `EmbeddingCorpusCache`.
- `AtelierCore/Tests/AtelierCoreTests/EmbeddingCorpusTests.swift`
- `AtelierCore/Tests/AtelierCoreTests/ServicesSemanticCorpusTests.swift`

Modified:

- `AppServices.swift` — the `corpusCache` stored property, and the class doc that used to say
  this type had no in-memory state, which is now one considered exception rather than a rule.
- `AppServices+Analysis.swift` — `semanticSearchAssets` in three steps;
  `loadEmbeddingCorpus`; `upsertEmbedding` invalidates. `import Accelerate` went with the dot
  products, and a line says where.
- `AppServices+Collections.swift`, `AppServices+Assets.swift` — the two delete entry points
  invalidate.
- `Domain/AssetEmbedding.swift` — `copyVector(_:into:)` and `hostMatchesStoredByteOrder`, the
  bulk half of the codec, in the file that owns the byte layout.
- `Tests/.../ScaleHarnessTests.swift` — the semantic row reports the resident corpus.
- `.docs/099-mac-backlog-plan.md` — P0b's status row.

## What is still NOT covered

**The new numbers are variable in a way the old ones were not, and the variance is real.** The
un-cached query was CPU-bound end to end and reproduced to within 3% across two sessions on
two different days. What replaced it is a short burst of I/O and a short burst of arithmetic,
both small enough that scheduler noise is a large fraction of them — so seven runs at
N = 20,000 spanned 266–1,515 ms cold and 46–114 ms warm, on a machine carrying a load average
of 7 on 8 cores while a second session built in the next worktree. **Read the medians as "a
few tens of milliseconds warm, a few hundred cold", not as 58.6 and 303.** The direction and
the order of magnitude are not in doubt at any N; the third significant figure is fiction.

Two specific things would move cold down and neither was measured: a release build, and a
checkpointed database — the harness times the cold query immediately after writing 20,000
embedding rows, so it reads a WAL at its largest, which a launched app does not.

**The measurement is a debug build, and the win is partly an artifact of that.** `swift test`
builds unoptimized, and the thing this phase removed — 10.2 million `loadUnaligned` calls
through a `map` — is exactly what an optimizer is best at. A release build would narrow the
before/after gap by an unmeasured factor. That the 20,000-item warm query got dramatically
faster is not in question; the 26× is.

**Nothing here is measured through the app.** The app calls the same function with the same
signature, and no `AtelierRefs/` file was touched, so the wiring is unchanged by
construction — but nobody has typed in the real search field and watched a real 20,000-item
library. The harness is the whole of the evidence.

**40 MB is a number, not a policy.** It is fine at 20,000 and it is 400 MB at 200,000, where
it would not be. There is no eviction, no memory-pressure response, and no lazy release when
the search field closes. The plan asked for a cache and a stated cost, and that is what this
is; the ceiling is a real one and it is unaddressed.

**The residual invalidation window is documented, not closed.** `invalidate()` runs after its
write commits rather than atomically with it, so a query issued in the microseconds between
the two can rank against one vector's previous value. Closing it needs the invalidation to
ride the commit, which the funnel cannot express today. It cannot surface a deleted asset —
that is the point of leaving membership to live SQL — so the exposure is a result being a
moment out of date, which a background embedding backfill produces anyway.

**The big-endian decode path is unexercised.** `copyVector` keeps a per-lane branch for a
host whose byte order does not match the stored one, which is what makes the pinned
little-endian format mean something. No Apple platform takes it, so no test does either; it
is asserted correct by reading, not by running.

**The `[String: Int]` index is a memory choice nobody measured against the alternative.**
Keying the row index by the stored key string rather than by `UUID` takes uuid parsing off
the per-query path at the cost of ~1.9 MB of heap strings at 20,000. The alternative was not
timed; the choice was made from the profile above, where uuid parsing was 12 ms per 5,000
rows, and it may well not matter.

**Concurrency is tested by construction, not under load.** The generation guard has a test
that invalidates from inside the load closure, which is the race written down as a sequence
— not two threads actually racing. No test runs concurrent queries against concurrent writes.
