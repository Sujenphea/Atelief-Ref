# 006 — Data Core: Overview (decisions + plan)

> Build-order **step 2** from [004-foundation-plan](./004-foundation-plan.md):
> the GRDB metadata store, the Core Domain models, and the single App Services
> mutation path. Data model spec: [003-foundation-design §data-model](./003-foundation-design.md).
> Blob/thumbnail store + ingestion pipeline are **step 3** — out of scope here.

`AtelierCore` is a local Swift Package (same pattern as `CanvasRenderer`): a
self-contained metadata store the app depends on, exercised headlessly by
`swift test`. GRDB is confined inside the package; the app and canvas never
import it.

## Scope

**In:** schema + explicit migrations, domain value types (Asset, Source,
Collection, CollectionItem, Tag), the persistence layer, the single App Services
mutation path (the write funnel + reads/search).

**Out (step 3+):** content-addressed blob store, thumbnail generation, the
ingestion pipeline, source adapters, the localhost endpoint. Tags are
schema-reserved with minimal apply/remove (the agent interface needs them later).

## Decisions (from interactive review)

### Architecture
- **A1 — Models are GRDB records.** Domain structs conform to GRDB record
  protocols; conformances live in `Persistence/*+GRDB.swift` extension files so
  the struct declarations read as plain domain types. GRDB is confined to
  `AtelierCore`. One type per entity (DRY); a parallel set of record structs is
  premature for a single local backend.
- **A2 — One package/target, seam by access control.** `AppServices` + the
  domain value types are `public`; GRDB records, the migrator, and the
  `DatabasePool` are `internal`. The app can only call `AppServices` — the
  "single mutation path" is enforced by the public surface, not by extra targets.
- **A3 — `DatabasePool` (WAL), async Sendable services.** Concurrent reads +
  serialized writes for the browse-while-importing workload the perf strategy
  names. A `final class … Sendable` suffices (no shared mutable state yet);
  promote to `actor` only when it holds in-memory caches.
- **A4 — Single write funnel now, observation deferred.** Every mutation routes
  through one private `write {}` entry (the home for invariants + future
  attribution/sync hooks). `ValueObservation` live queries are deferred to the
  grid step (step 4), their first real consumer.

### Code quality
- **C5 — Readable text encodings.** UUID → lowercased `uuidString` TEXT,
  timestamps → ISO-8601 UTC TEXT (sortable), enums → **String** rawValue. Set
  once via GRDB global strategies. Agent-readable (`003:27`), and string enum
  rawValues survive case reordering (`003:198` "open-ended" enums); Int rawValues
  would silently corrupt on reorder.
- **C6 — Illegal states unrepresentable.** The public funnel exposes
  `ingest(asset, from: Source, into: Collection.ID)` — `Source` is a required
  parameter, so "Asset with no origin" cannot compile. Dedup-by-hash + membership
  happen in one transaction; the DB adds `NOT NULL` FK as the safety net.
- **C7 — Typed domain errors.** `enum AtelierError: Error` with explicit cases
  (`.notFound`, `.duplicateBlobHash`, `.invalidPlacement`, `.constraintViolation`,
  `.migrationFailed`, …); GRDB/SQLite errors are mapped at the persistence
  boundary so GRDB never leaks out of the package (consistent with A2).
- **C8 — Centralized validation in the funnel.** Trim + reject empty names;
  reject non-finite `canvas_x/y/w/h` (the Phase-1 NaN/inf bug class); reject
  non-positive `width`/`height`/`file_size`; normalize `blob_hash` (lowercased
  hex + length); per-platform `original_url` rules. One place, before any write.

### Tests
- **T9 — Temp-file `DatabasePool` per test.** A shared `makeTestStore()` helper
  builds an isolated temp-file Pool (real WAL), migrated, torn down after.
  Faithful to production (A3); in-memory `DatabaseQueue` would not exercise Pool.
- **T10 — Full migration suite.** Fresh-DB migrate-to-latest succeeds; assert the
  resulting tables/indices/FK/FTS shape (`sqlite_master` snapshot); foreign keys
  enforced (`PRAGMA foreign_keys`); **append-only guard** — a committed list of
  migration identifiers the test pins, so editing a shipped migration fails CI.
- **T11 — Comprehensive invariant + failure suite.** Provenance (no bare-Asset
  path; raw insert without `source_id` rejected); dedup-by-hash (same bytes →
  one blob reference, distinct assets only if provenance differs; identical
  re-ingest → no dup); many-to-many (asset in 2 collections → 2 items, 1 asset
  row); the delete/cascade policy; every `AtelierError` case on its trigger;
  every C8 validation rejection.
- **T12 — Targeted concurrency tests.** Concurrent reads during a sustained write
  succeed with consistent snapshots (no "database is locked", no torn reads); the
  concurrent identical-ingest race (two imports of the same bytes → one blob, no
  duplicate-key crash); writes observably serialized. Verifies the A3 choice.

### Performance
- **P13 — Index the known access paths.** FK columns
  (`CollectionItem.collection_id`, `CollectionItem.asset_id`, `Asset.source_id`);
  **non-unique** `Asset.blob_hash` (dedup = one file for many asset rows,
  `003:189`); `Asset.created_at` (recency); composite
  `CollectionItem(collection_id, manual_order)` (grid ordering);
  `Source.platform` (filter); FTS5 over `Source.title/author`.
- **P14 — Single joined fetch (no N+1).** GRDB associations load
  CollectionItem + Asset + Source in one round-trip — the canonical read shape
  the grid + canvas consume. Kills the N+1 class the perf strategy flags
  (`003:84`).
- **P15 — Bulk in one transaction.** Bulk methods (`addAssets`, `setGridOrder`,
  bulk upsert) route through the funnel's single `write {}` → one transaction,
  one fsync under WAL. The agent/import workloads are inherently bulk.
- **P16 — Bound only unbounded reads.** Collection-scoped reads return full
  arrays (the views need every item); library-wide search/inventory take a
  `limit` (+ keyset pagination option). Reads return lightweight metadata only —
  never blob bytes.

## Deferred decision (chunk 3)
The **delete / cascade policy** (what happens to `CollectionItem`s and assets
when a Collection, Asset, or Source is deleted) is settled in the schema chunk
with concrete options, not guessed here.

## Build sequence (one agent per chunk, sequential — each builds on the last)
1. **Scaffold + GRDB** — `AtelierCore` package, GRDB 7 via SPM, wired into the
   Xcode project (the `CanvasRenderer` pattern). Smoke test it builds + links.
2. **Domain value types** — Asset, Source, Collection, CollectionItem, Tag +
   enums (AssetKind, Platform, DownloadState, TagSource). Invariant tests.
3. **Schema + migrations** — `DatabaseMigrator` v1 (tables, FKs, indices, FTS5);
   the cascade-policy decision; migration suite (T10).
4. **Persistence** — GRDB record conformances (A1), `DatabasePool` setup (A3),
   the joined read (P14). CRUD round-trip tests.
5. **App Services write funnel** — `ingest`, validation (C8), bulk (P15), typed
   errors (C7), invariants (C6). Invariant/failure + concurrency tests (T11/T12).
6. **Read / search API** — list/get + FTS5 search, bounded (P16). Query tests.

## Verification
`swift test` green across the `AtelierCore` suites; full app build succeeds with
the package wired in; migration append-only guard + concurrency tests passing.
