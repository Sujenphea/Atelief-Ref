# 011 — Data core: v1 SQLite schema + migration suite

**Chunk 3** of the data-core build: the on-disk schema as a GRDB
`DatabaseMigrator` (one migration, identifier `"v1"`) plus a thorough migration
test suite. No record types, no store wrapper, no App Services yet — those land
in later chunks. The migration body is treated as **append-only**: shipped once,
never edited.

## Summary

Added the `Persistence/` layer to `AtelierCore` with `Migrator.swift`: an
`internal enum Migrator` (decision A2 — schema is an implementation detail,
only `AppServices` is public) exposing `makeMigrator() -> DatabaseMigrator`. It
registers a single migration `"v1"` that creates the six base tables, the P13
index set, and the `source_fts` FTS5 virtual table. `eraseDatabaseOnSchemaChange`
is deliberately not set.

All `id`/`*_id`/`*_at`/enum columns are `TEXT` (decision C5 — UUIDs, ISO-8601
timestamps, and String enum rawValues are stored as text). Table and column
names follow the singular snake_case contract that chunk 4's records will match
exactly.

## Decisions realized

- **C5 — text encodings.** Every `id`, `*_id`, `*_at`, and enum column
  (`platform`, `kind`, `download_state`, `tag.source`) is `TEXT`.
  `width`/`height`/`file_size`/`manual_order`/`canvas_z` are `INTEGER`;
  `duration`/`canvas_x|y|w|h` are `REAL`; `raw_metadata` is `TEXT NOT NULL`.
- **A2 — internal migrator.** `Migrator` is `internal`, not public; GRDB is
  confined to the Persistence layer (`import GRDB` lives here).
- **P13 — indices + FTS5.** All seven named indices plus `asset_tag(tag_id)`;
  `asset(blob_hash)` is **non-unique** (dedup: one blob, many rows). `source_fts`
  is an external-content FTS5 table over `title`/`author_handle`/`author_name`,
  synchronized with `source` via `t.synchronize(withTable:)` (GRDB auto-generates
  the insert/update/delete triggers).
- **17A — cascade policy (the chunk-3 deferred decision), implemented exactly:**
  - `collection_item.collection_id` → `collection(id)` **ON DELETE CASCADE**
  - `collection_item.asset_id` → `asset(id)` **ON DELETE CASCADE**
  - `asset_tag.asset_id` → `asset(id)` **ON DELETE CASCADE**
  - `asset_tag.tag_id` → `tag(id)` **ON DELETE CASCADE**
  - `collection.cover_asset_id` → `asset(id)` **ON DELETE SET NULL**
  - `asset.source_id` → `source(id)` **ON DELETE RESTRICT** (provenance is
    protected — a source with surviving assets cannot be deleted).
- **C6 — provenance NOT NULL.** `asset.source_id` is `NOT NULL`; every required
  field per 003 is `NOT NULL`, every 003-optional is nullable.
- **T10 — full migration suite** (append-only guard, shape, indices, FTS, FK
  enforcement, cascade actions).

## Append-only guard

Two pins, asserted by tests:
- `DatabaseMigrator.migrations` (GRDB's ordered identifier list) must equal the
  committed `["v1"]`.
- The identifiers actually recorded in the `grdb_migrations` table after a
  migrate must equal `["v1"]`.
The migrator also carries a `Migrator.registeredIdentifiers` constant pinned to
the same list. Editing or removing a shipped identifier is forbidden — schema
changes append a new identifier (`"v2"`, …). The file header and test comments
state this.

## Migration `v1` DDL (the registered migration body)

```sql
CREATE TABLE source (
    id TEXT NOT NULL PRIMARY KEY, platform TEXT NOT NULL, original_url TEXT,
    author_handle TEXT, author_name TEXT, title TEXT,
    captured_at TEXT NOT NULL, raw_metadata TEXT NOT NULL);

CREATE TABLE asset (
    id TEXT NOT NULL PRIMARY KEY, kind TEXT NOT NULL, blob_hash TEXT NOT NULL,
    mime_type TEXT NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
    duration REAL, file_size INTEGER NOT NULL, download_state TEXT NOT NULL,
    created_at TEXT NOT NULL,
    source_id TEXT NOT NULL REFERENCES source(id) ON DELETE RESTRICT);

CREATE TABLE collection (
    id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, description TEXT,
    cover_asset_id TEXT REFERENCES asset(id) ON DELETE SET NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL);

CREATE TABLE collection_item (
    id TEXT NOT NULL PRIMARY KEY,
    collection_id TEXT NOT NULL REFERENCES collection(id) ON DELETE CASCADE,
    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
    added_at TEXT NOT NULL, manual_order INTEGER,
    canvas_x REAL, canvas_y REAL, canvas_w REAL, canvas_h REAL, canvas_z INTEGER);

CREATE TABLE tag (
    id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, source TEXT NOT NULL);

CREATE TABLE asset_tag (
    asset_id TEXT NOT NULL REFERENCES asset(id) ON DELETE CASCADE,
    tag_id   TEXT NOT NULL REFERENCES tag(id)   ON DELETE CASCADE,
    PRIMARY KEY (asset_id, tag_id));

CREATE INDEX index_collection_item_on_collection_id              ON collection_item(collection_id);
CREATE INDEX index_collection_item_on_asset_id                   ON collection_item(asset_id);
CREATE INDEX index_asset_on_source_id                            ON asset(source_id);
CREATE INDEX index_asset_on_blob_hash                            ON asset(blob_hash);        -- non-unique
CREATE INDEX index_asset_on_created_at                           ON asset(created_at);
CREATE INDEX index_collection_item_on_collection_id_manual_order ON collection_item(collection_id, manual_order);
CREATE INDEX index_source_on_platform                            ON source(platform);
CREATE INDEX index_asset_tag_on_tag_id                           ON asset_tag(tag_id);

-- FTS5 (GRDB DSL): external-content, synchronized with `source`.
CREATE VIRTUAL TABLE source_fts USING fts5(
    title, author_handle, author_name, content='source', content_rowid='rowid');
-- + auto-generated source_fts_ai / _au / _ad triggers on `source`.
```

## Files changed

- `AtelierCore/Sources/AtelierCore/Persistence/Migrator.swift` *(new)* —
  `internal enum Migrator`; `makeMigrator()` registers `"v1"`; append-only
  header doc; `registeredIdentifiers` pin.
- `AtelierCore/Tests/AtelierCoreTests/MigrationTests.swift` *(new)* — 26 tests
  across 7 suites: runs-cleanly (+ idempotent re-migrate), append-only guard
  (three checks), table/column shape (NOT NULL spot-checks + composite PK), P13
  indices (+ non-unique blob_hash), FTS5 (insert/update/delete index behavior +
  triggers), `PRAGMA foreign_keys` + dangling-FK rejection, and the full 17A
  cascade matrix.
- `AtelierCore/Package.swift` *(edited)* — test target now also depends on the
  `GRDB` product (the suite imports GRDB to assert on `DatabaseMigrator` /
  `Database`).

## Verification

- `cd AtelierCore && swift test` — **54 tests in 11 suites passed** (the 26 new
  migration tests plus the 28 chunk-1/2 domain + smoke tests, all still green).

## Migration notes

Additive and forward-only. `"v1"` is now a shipped, immutable identifier — never
edit its body or rename it; the next schema change registers `"v2"`. The schema
is created but nothing reads/writes it through records yet (GRDB record
conformances + `DatabasePool` store land in chunk 4, matching these exact
table/column names).
