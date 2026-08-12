// AtelierCore — schema migrations (the v1 SQLite schema)
//
// The single source of truth for the on-disk schema, expressed as a GRDB
// `DatabaseMigrator`. This is the Persistence layer, so GRDB is expected here
// (decision A2: GRDB is confined to `AtelierCore`).
//
// ─────────────────────────────────────────────────────────────────────────────
// APPEND-ONLY. Migrations are immutable once shipped.
//
//   • NEVER edit, rename, or remove a migration that has shipped. A migration's
//     string identifier (e.g. "v1") is its permanent name — existing databases
//     in the field record which identifiers they have already applied, and the
//     migrator replays only the *new* ones. Changing a shipped migration's body
//     would silently diverge already-migrated installs from fresh ones; changing
//     its identifier would re-run it and corrupt live data.
//   • To change the schema, register a NEW migration with a NEW identifier
//     ("v2", "v3", …) that ALTERs / creates from the current state.
//
// `eraseDatabaseOnSchemaChange` is deliberately NOT set — it would mask the
// append-only rule by silently nuking and rebuilding on any drift.
//
// On-disk encodings (decision C5): UUIDs, timestamps, and enum rawValues are all
// stored as TEXT, so every `id`, `*_id`, `*_at`, and enum column below is TEXT.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import GRDB

/// Namespace owning the package's `DatabaseMigrator`.
///
/// Internal (decision A2): the schema is an implementation detail of
/// `AtelierCore`; only `AppServices` is public. Built fresh on each call so it
/// holds no shared mutable state.
enum Migrator {

    /// The committed, append-only list of migration identifiers, newest last.
    ///
    /// Pinned by a test — treat as append-only forever. Adding a migration means
    /// appending its identifier here AND in the test's expected list.
    static let registeredIdentifiers = ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21", "v22"]

    /// Builds the migrator with every registered migration, in order.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // v1 — initial schema. SHIPPED: never edit this body (see file header).
        migrator.registerMigration("v1") { db in
            try createV1Schema(db)
        }

        // v2 — nested folders. SHIPPED: never edit this body (see file header).
        migrator.registerMigration("v2") { db in
            try createV2Schema(db)
        }

        // v3 — bulk-import job ledger. SHIPPED: never edit this body.
        migrator.registerMigration("v3") { db in
            try createV3Schema(db)
        }

        // v4 — first-class spaces. SHIPPED: never edit this body.
        migrator.registerMigration("v4") { db in
            try createV4Schema(db)
        }

        // v5 — view tracking + per-collection sort mode. SHIPPED: never edit.
        migrator.registerMigration("v5") { db in
            try createV5Schema(db)
        }

        // v6 — multi-kind items (003 · O1): rebuild `asset` with nullable byte
        // columns + payload/dedup_key/search_text, add `asset_fts`. Registered
        // with the DEFAULT deferred foreign-key checks, so foreign keys are
        // disabled for the duration of the table rebuild and a full
        // `foreign_key_check` runs after — exactly the SQLite table-rebuild
        // contract. SHIPPED: never edit this body.
        migrator.registerMigration("v6") { db in
            try createV6Schema(db)
        }

        // v7 — on-device analysis index (012 · I1): one additive `asset_analysis`
        // table + `analysis_fts` OCR full-text. Independent of the library schema
        // (like v3's ledger), so no table rebuild. SHIPPED once released: never
        // edit this body.
        migrator.registerMigration("v7") { db in
            try createV7Schema(db)
        }

        // v8 — smart collections (015 · saved searches). One additive
        // `saved_search` table, independent of the library schema (like v3's
        // ledger and v7's analysis index — no table rebuild). SHIPPED once
        // released: never edit this body.
        migrator.registerMigration("v8") { db in
            try createV8Schema(db)
        }

        // v9 — normalize tag names: strip a leading `#` from stored `tag.name`
        // (a UI affordance that used to leak into the name, making `sf` search
        // miss a `#sf` tag). Data-only, no schema change; merges onto a canonical
        // twin where one exists. SHIPPED once released: never edit this body.
        migrator.registerMigration("v9") { db in
            try normalizeV9TagNames(db)
        }

        // v10 — user-editable Name + Note on an asset (041 · item-detail
        // redesign). Two additive, nullable TEXT columns — no rebuild (like v5).
        // SHIPPED once released: never edit this body.
        migrator.registerMigration("v10") { db in
            try createV10Schema(db)
        }

        // v11 — manual sibling order for collections (043 · decision 2B). One
        // additive `sort_index` column, back-filled to a dense per-parent order.
        // SHIPPED once released: never edit this body.
        migrator.registerMigration("v11") { db in
            try createV11Schema(db)
        }

        // v12 — search covers user-given Name + Note (044/045 · search overhaul
        // 1A): rebuild `asset_fts` with `name` / `note` columns so the v10 fields
        // become searchable, kept fresh by the regenerated sync triggers.
        migrator.registerMigration("v12") { db in
            try createV12Schema(db)
        }

        // v13 — substring search (044 · 046 search overhaul Phase 2): four
        // `trigram`-tokenized indexes over the SHORT human fields so "air" finds
        // "chair" and the tag-/collection-name arms stop leaning on un-indexed
        // leading-wildcard LIKE scans.
        migrator.registerMigration("v13") { db in
            try createV13Schema(db)
        }

        // v14 — semantic search (044 · 047 search overhaul Phase 3a): one dense
        // text-embedding vector per asset, stored for cosine kNN. Additive table,
        // populated lazily by the embedding backfill (independent model_version).
        migrator.registerMigration("v14") { db in
            try createV14Schema(db)
        }

        // v15 — manual order for spaces (043 · decision 2B, extended to spaces).
        // One additive `sort_index` column, back-filled dense from the prior
        // `created_at DESC` order so existing libraries keep their arrangement.
        migrator.registerMigration("v15") { db in
            try createV15Schema(db)
        }

        // v16 — reconcile the Unsorted home (F3) to its invariant: an asset is in
        // Unsorted if and ONLY if it is in no other collection. Data-only, no
        // schema change (like v9's tag normalization).
        migrator.registerMigration("v16") { db in
            try reconcileV16Unsorted(db)
        }

        // v17 — a board reopens where you left it (018 · Cluster C). One additive
        // `space.camera` TEXT column holding a `SpaceCamera` JSON blob; NULL for
        // every existing row. SHIPPED: never edit this body.
        migrator.registerMigration("v17") { db in
            try createV17Schema(db)
        }

        // v18 — re-tag the pre-platform rednote harvest (020 · K2): rows captured
        // before `Platform.rednote` existed were stored as `web`. Data-only, no
        // schema change (like v9's tag normalization and v16's reconcile).
        migrator.registerMigration("v18") { db in
            try retagV18RednoteSources(db)
        }

        // v19 — favorites (011 · U5 · C3). ONE additive `asset.is_favorite`
        // column, NOT NULL DEFAULT 0, so every existing row reads "not a
        // favorite". No back-fill (there is no prior signal to recover) and no
        // table rebuild. SHIPPED once released: never edit this body.
        migrator.registerMigration("v19") { db in
            try createV19Schema(db)
        }

        // v20 — the archive shelf (023 · A). One additive nullable
        // `asset.archived_at` TEXT column plus a PARTIAL index over the archived
        // rows only. NULL for every existing row, so nothing is archived by an
        // upgrade. SHIPPED once released: never edit this body.
        migrator.registerMigration("v20") { db in
            try createV20Schema(db)
        }

        // v21 — the color filter's index (085 · C1). One additive `asset_color`
        // table, derived from `asset_analysis.colors`, holding the palette bucket
        // each dominant swatch was filed under. Empty on upgrade; a backfill pass
        // fills it. SHIPPED once released: never edit this body.
        migrator.registerMigration("v21") { db in
            try createV21Schema(db)
        }

        // v22 — suggested tags (012 · I3). One additive `tag_suppression` table
        // remembering which suggestions the user refused, plus an additive
        // `asset_analysis.suggest_version` marker. Empty on upgrade: nothing has
        // ever been suggested, so nothing has ever been refused. SHIPPED once
        // released: never edit this body.
        migrator.registerMigration("v22") { db in
            try createV22Schema(db)
        }

        return migrator
    }

    // MARK: - v1

    private static func createV1Schema(_ db: Database) throws {
        // Tables are created in FK-dependency order (a referenced table must
        // exist before the table that points at it). All `id`/`*_id`/`*_at`/enum
        // columns are TEXT (C5). FK actions implement decision 17A exactly.

        // source — origin of an asset; no outbound FKs.
        try db.execute(sql: """
            CREATE TABLE source (
                id            TEXT NOT NULL PRIMARY KEY,
                platform      TEXT NOT NULL,
                original_url  TEXT,
                author_handle TEXT,
                author_name   TEXT,
                title         TEXT,
                captured_at   TEXT NOT NULL,
                raw_metadata  TEXT NOT NULL
            );
            """)

        // asset — captured media. source_id is REQUIRED (C6) and RESTRICTed:
        // a source with surviving assets cannot be deleted (17A).
        try db.execute(sql: """
            CREATE TABLE asset (
                id             TEXT    NOT NULL PRIMARY KEY,
                kind           TEXT    NOT NULL,
                blob_hash      TEXT    NOT NULL,
                mime_type      TEXT    NOT NULL,
                width          INTEGER NOT NULL,
                height         INTEGER NOT NULL,
                duration       REAL,
                file_size      INTEGER NOT NULL,
                download_state TEXT    NOT NULL,
                created_at     TEXT    NOT NULL,
                source_id      TEXT    NOT NULL
                    REFERENCES source(id) ON DELETE RESTRICT
            );
            """)

        // collection — named grouping. cover_asset_id is optional; SET NULL on
        // delete so dropping a cover asset just clears the pointer (17A).
        try db.execute(sql: """
            CREATE TABLE collection (
                id             TEXT NOT NULL PRIMARY KEY,
                name           TEXT NOT NULL,
                description    TEXT,
                cover_asset_id TEXT
                    REFERENCES asset(id) ON DELETE SET NULL,
                created_at     TEXT NOT NULL,
                updated_at     TEXT NOT NULL
            );
            """)

        // collection_item — membership + per-view placement. Both FKs CASCADE:
        // deleting a collection or an asset drops the memberships (17A).
        try db.execute(sql: """
            CREATE TABLE collection_item (
                id            TEXT NOT NULL PRIMARY KEY,
                collection_id TEXT NOT NULL
                    REFERENCES collection(id) ON DELETE CASCADE,
                asset_id      TEXT NOT NULL
                    REFERENCES asset(id) ON DELETE CASCADE,
                added_at      TEXT NOT NULL,
                manual_order  INTEGER,
                canvas_x      REAL,
                canvas_y      REAL,
                canvas_w      REAL,
                canvas_h      REAL,
                canvas_z      INTEGER
            );
            """)

        // tag — reserved label; no outbound FKs.
        try db.execute(sql: """
            CREATE TABLE tag (
                id     TEXT NOT NULL PRIMARY KEY,
                name   TEXT NOT NULL,
                source TEXT NOT NULL
            );
            """)

        // asset_tag — many-to-many join. Composite PK (no own id); both FKs
        // CASCADE so the join row dies with either side (17A).
        try db.execute(sql: """
            CREATE TABLE asset_tag (
                asset_id TEXT NOT NULL
                    REFERENCES asset(id) ON DELETE CASCADE,
                tag_id   TEXT NOT NULL
                    REFERENCES tag(id) ON DELETE CASCADE,
                PRIMARY KEY (asset_id, tag_id)
            );
            """)

        // Indices (P13) — the known access paths.
        try db.execute(sql: """
            CREATE INDEX index_collection_item_on_collection_id
                ON collection_item(collection_id);
            CREATE INDEX index_collection_item_on_asset_id
                ON collection_item(asset_id);
            CREATE INDEX index_asset_on_source_id
                ON asset(source_id);
            CREATE INDEX index_asset_on_blob_hash
                ON asset(blob_hash);
            CREATE INDEX index_asset_on_created_at
                ON asset(created_at);
            CREATE INDEX index_collection_item_on_collection_id_manual_order
                ON collection_item(collection_id, manual_order);
            CREATE INDEX index_source_on_platform
                ON source(platform);
            CREATE INDEX index_asset_tag_on_tag_id
                ON asset_tag(tag_id);
            """)

        // FTS5 (P13) — full-text index over source's human-readable fields,
        // kept in sync with `source` via GRDB's external-content
        // synchronization. `synchronize(withTable:)` auto-generates the
        // INSERT/UPDATE/DELETE triggers and back-fills existing rows.
        try db.create(virtualTable: "source_fts", using: FTS5()) { t in
            t.synchronize(withTable: "source")
            t.column("title")
            t.column("author_handle")
            t.column("author_name")
        }
    }

    // MARK: - v2

    /// Nested folders (decision F1/F3/F4). Folders *are* collections, so this
    /// adds a self-referential parent link to `collection` (nullable — `NULL` =
    /// a root folder) with `ON DELETE CASCADE`: deleting a folder recurses through
    /// its descendant folders, and the existing `collection_item.collection_id`
    /// cascade drops their memberships — deleting a whole subtree while the
    /// underlying assets survive (F4).
    private static func createV2Schema(_ db: Database) throws {
        // Add the self-referential FK column. An ALTER-added FK column must be
        // nullable with a NULL default (SQLite requirement).
        try db.execute(sql: """
            ALTER TABLE collection
                ADD COLUMN parent_collection_id TEXT
                    REFERENCES collection(id) ON DELETE CASCADE;
            """)

        // Access path for "children of a folder" (P13).
        try db.execute(sql: """
            CREATE INDEX index_collection_on_parent_collection_id
                ON collection(parent_collection_id);
            """)

        // Seed the protected "Unsorted" root folder (F3): the fixed well-known id
        // (Collection.unsortedID, lowercased), a root (parent NULL). A migration
        // can't call Date(), so timestamps are literal TEXT.
        try db.execute(sql: """
            INSERT INTO collection
                (id, name, description, cover_asset_id, created_at, updated_at, parent_collection_id)
            VALUES
                ('00000000-0000-0000-0000-000000000001', 'Unsorted', NULL, NULL,
                 '2024-01-01 00:00:00.000', '2024-01-01 00:00:00.000', NULL);
            """)
    }

    // MARK: - v3

    /// Bulk-import job ledger (015 · decision 3A). Two tables, independent of the
    /// v1/v2 library schema: `job` (one sweep) and `job_item` (one enumerated
    /// item, composite-PK'd by `(job_id, source_id)` — no id of its own, like
    /// `asset_tag`). `job_item.job_id` CASCADEs, so deleting a job drops its
    /// items. All `id`/`*_id`/`*_at`/enum columns are TEXT (C5); counters/estimates
    /// are INTEGER.
    private static func createV3Schema(_ db: Database) throws {
        // job — one bulk-import sweep. No outbound FKs.
        try db.execute(sql: """
            CREATE TABLE job (
                id             TEXT    NOT NULL PRIMARY KEY,
                platform       TEXT    NOT NULL,
                scope          TEXT,
                status         TEXT    NOT NULL,
                total_estimate INTEGER,
                ingested_count INTEGER NOT NULL,
                created_at     TEXT    NOT NULL,
                updated_at     TEXT    NOT NULL
            );
            """)

        // job_item — one enumerated item. Composite PK (job_id, source_id) makes
        // re-recording the same item idempotent (upsert), which is exactly the
        // resumable-sweep invariant. job_id CASCADEs (F4-style subtree delete).
        try db.execute(sql: """
            CREATE TABLE job_item (
                job_id     TEXT NOT NULL
                    REFERENCES job(id) ON DELETE CASCADE,
                source_id  TEXT NOT NULL,
                source_url TEXT,
                status     TEXT NOT NULL,
                blob_hash  TEXT,
                updated_at TEXT NOT NULL,
                PRIMARY KEY (job_id, source_id)
            );
            """)

        // Indices (P14) — the known access paths.
        //   • source_id: the download-skip lookup ("have we ingested this pin/
        //     tweet in ANY sweep of this platform?") must be O(1), not a scan.
        //   • job.platform: known-sources filters jobs by platform first.
        try db.execute(sql: """
            CREATE INDEX index_job_item_on_source_id
                ON job_item(source_id);
            CREATE INDEX index_job_on_platform
                ON job(platform);
            """)
    }

    // MARK: - v4

    /// First-class spaces (005 · decision O1). A `space` is a freeform board —
    /// its own entity, NOT a folder — and `space_item` is ONE discriminated
    /// placement table serving both ASSET rows (`kind='asset'`, `asset_id` set)
    /// and freeform ELEMENT rows (`kind='frame'/'text'`, `asset_id` NULL,
    /// `style` JSON). All `id`/`*_id`/`*_at`/enum columns are TEXT (C5); geometry
    /// is REAL/INTEGER and always present (every board row has a rect).
    private static func createV4Schema(_ db: Database) throws {
        // space — a freeform board. cover_asset_id is optional; SET NULL on
        // asset delete so dropping a cover asset just clears the pointer (mirrors
        // collection, 17A).
        try db.execute(sql: """
            CREATE TABLE space (
                id             TEXT NOT NULL PRIMARY KEY,
                name           TEXT NOT NULL,
                cover_asset_id TEXT
                    REFERENCES asset(id) ON DELETE SET NULL,
                created_at     TEXT NOT NULL,
                updated_at     TEXT NOT NULL
            );
            """)

        // space_item — one board row. `space_id` CASCADEs (deleting a space
        // drops its rows). `asset_id` is NULLABLE and CASCADEs: deleting an asset
        // vacates ONLY its asset rows — element rows (NULL asset_id) are
        // untouched (005 O1). Geometry is NOT NULL; `style` (ElementStyle JSON)
        // is NULL for asset rows.
        try db.execute(sql: """
            CREATE TABLE space_item (
                id         TEXT    NOT NULL PRIMARY KEY,
                space_id   TEXT    NOT NULL
                    REFERENCES space(id) ON DELETE CASCADE,
                kind       TEXT    NOT NULL,
                asset_id   TEXT
                    REFERENCES asset(id) ON DELETE CASCADE,
                x          REAL    NOT NULL,
                y          REAL    NOT NULL,
                w          REAL    NOT NULL,
                h          REAL    NOT NULL,
                z          INTEGER NOT NULL,
                style      TEXT,
                created_at TEXT    NOT NULL,
                updated_at TEXT    NOT NULL
            );
            """)

        // Indices (P13) — the known access paths: "rows of a space" (the board
        // read) and "space rows referencing an asset" (delete/cascade lookups).
        try db.execute(sql: """
            CREATE INDEX index_space_item_on_space_id
                ON space_item(space_id);
            CREATE INDEX index_space_item_on_asset_id
                ON space_item(asset_id);
            """)
    }

    // MARK: - v5

    /// View tracking + per-collection sort mode (007 · sort). Three additive
    /// columns, each with a NOT-NULL default so existing rows migrate cleanly:
    ///   • `asset.view_count` — a global per-asset counter (one asset, many
    ///     memberships; a view = an Item Detail open), the "most viewed" key.
    ///   • `asset.last_viewed_at` — nullable; `NULL` until first viewed. Makes a
    ///     future "recently viewed" sort free.
    ///   • `collection.sort_mode` — the ``SortMode`` rawValue, default `'manual'`
    ///     so every existing collection keeps its drag order.
    /// An ALTER-added column must be constant-defaulted (SQLite), which all three
    /// are. The `view_count` index backs the `mostViewed` ORDER BY.
    private static func createV5Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE asset ADD COLUMN view_count INTEGER NOT NULL DEFAULT 0;
            """)
        try db.execute(sql: """
            ALTER TABLE asset ADD COLUMN last_viewed_at TEXT;
            """)
        try db.execute(sql: """
            ALTER TABLE collection ADD COLUMN sort_mode TEXT NOT NULL DEFAULT 'manual';
            """)
        try db.execute(sql: """
            CREATE INDEX index_asset_on_view_count ON asset(view_count);
            """)
    }

    // MARK: - v10

    /// User-editable Name + Note on an asset (041). Two additive, nullable TEXT
    /// columns — no default, no rebuild; existing rows read `NULL` (the "unnamed
    /// / no note" state the UI already handles). Kept last so v6's rebuild copies
    /// nothing new and older DBs upgrade with a plain ALTER.
    private static func createV10Schema(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE asset ADD COLUMN name TEXT;")
        try db.execute(sql: "ALTER TABLE asset ADD COLUMN note TEXT;")
    }

    // MARK: - v11

    /// Manual sibling order for collections (043 · decision 2B). One additive
    /// `sort_index` column (NOT NULL, constant `DEFAULT 0` so the ALTER is legal),
    /// then a deterministic back-fill: within each parent group (roots share the
    /// `NULL` group) each row's index becomes the count of siblings that sort
    /// before it by `(name, id)` — i.e. a dense `0..<n` that reproduces the prior
    /// `(name, id)` display order, so existing libraries keep their current order.
    /// The correlated-subquery back-fill avoids depending on window-function
    /// support (explicit over clever). A composite index backs the ordered reads.
    private static func createV11Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE collection ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0;
            """)
        // Dense per-parent back-fill. The NULL-safe parent match keeps root
        // folders in one group; the `(name, id)` predicate is the same order the
        // UI used before manual order existed.
        try db.execute(sql: """
            UPDATE collection AS c
            SET sort_index = (
                SELECT COUNT(*)
                FROM collection AS s
                WHERE (
                        (s.parent_collection_id IS NULL AND c.parent_collection_id IS NULL)
                        OR s.parent_collection_id = c.parent_collection_id
                      )
                  AND (s.name < c.name OR (s.name = c.name AND s.id < c.id))
            );
            """)
        try db.execute(sql: """
            CREATE INDEX index_collection_on_parent_sort_index
                ON collection(parent_collection_id, sort_index);
            """)
    }

    // MARK: - v15

    /// Manual order for spaces (043 · decision 2B, extended to the flat space
    /// list). One additive `sort_index` column (NOT NULL, constant `DEFAULT 0` so
    /// the ALTER is legal), then a deterministic back-fill: each row's index
    /// becomes the count of spaces that sorted before it under the prior
    /// `created_at DESC, id` order — a dense `0..<n` that reproduces the old
    /// newest-first arrangement, so existing libraries are visually unchanged.
    /// The correlated-subquery back-fill avoids depending on window-function
    /// support (explicit over clever). An index backs the ordered read.
    private static func createV15Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE space ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0;
            """)
        // `s` sorts before `c` when it is NEWER (created_at DESC), the id ASC
        // tie-break settling a same-instant batch — the exact order `listSpaces`
        // used before manual order existed.
        try db.execute(sql: """
            UPDATE space AS c
            SET sort_index = (
                SELECT COUNT(*)
                FROM space AS s
                WHERE s.created_at > c.created_at
                   OR (s.created_at = c.created_at AND s.id < c.id)
            );
            """)
        try db.execute(sql: """
            CREATE INDEX index_space_on_sort_index ON space(sort_index);
            """)
    }

    // MARK: - v6

    /// Multi-kind items (003 · O1). Makes `asset` byte-columns NULLABLE (a
    /// media-less `tweet`/`link`/`color` has no blob) and adds three content
    /// columns: `payload` (kind substance as JSON), `dedup_key` (kind-aware
    /// dedup), `search_text` (content FTS). SQLite cannot relax a `NOT NULL`
    /// constraint in place, so this is the canonical 12-step TABLE REBUILD —
    /// honest nullability over sentinel lies (003 · "rebuild over sentinels").
    ///
    /// Runs under the migrator's DEFAULT deferred foreign-key checks: FKs are
    /// off during the body (so dropping/renaming `asset` while `collection_item`,
    /// `collection.cover_asset_id`, `space`, `space_item`, and `asset_tag`
    /// reference it is allowed) and a full `foreign_key_check` runs afterward.
    ///
    /// Existing `image`/`video` rows are copied byte-for-byte — every prior
    /// column value survives; the three new columns default to NULL. All v1/v5
    /// indices are recreated on the rebuilt table (they were dropped with the old
    /// one), plus a new `dedup_key` index, plus the `asset_fts` FTS5 table
    /// synchronized over `search_text`.
    private static func createV6Schema(_ db: Database) throws {
        // 1. New table: byte columns nullable, + payload/dedup_key/search_text.
        //    Same FK to source (RESTRICT, C6) and the v5 view columns.
        try db.execute(sql: """
            CREATE TABLE asset_new (
                id             TEXT    NOT NULL PRIMARY KEY,
                kind           TEXT    NOT NULL,
                blob_hash      TEXT,
                mime_type      TEXT,
                width          INTEGER,
                height         INTEGER,
                duration       REAL,
                file_size      INTEGER,
                download_state TEXT    NOT NULL,
                created_at     TEXT    NOT NULL,
                source_id      TEXT    NOT NULL
                    REFERENCES source(id) ON DELETE RESTRICT,
                view_count     INTEGER NOT NULL DEFAULT 0,
                last_viewed_at TEXT,
                payload        TEXT,
                dedup_key      TEXT,
                search_text    TEXT
            );
            """)

        // 2. Copy every existing row verbatim (byte-identical). The three new
        //    columns are omitted, so they take their NULL default.
        try db.execute(sql: """
            INSERT INTO asset_new
                (id, kind, blob_hash, mime_type, width, height, duration,
                 file_size, download_state, created_at, source_id,
                 view_count, last_viewed_at)
            SELECT
                id, kind, blob_hash, mime_type, width, height, duration,
                file_size, download_state, created_at, source_id,
                view_count, last_viewed_at
            FROM asset;
            """)

        // 3. Swap the old table out (its indices drop with it) and rename in.
        try db.execute(sql: "DROP TABLE asset;")
        try db.execute(sql: "ALTER TABLE asset_new RENAME TO asset;")

        // 4. Recreate every v1/v5 index on the rebuilt table, plus dedup_key.
        try db.execute(sql: """
            CREATE INDEX index_asset_on_source_id   ON asset(source_id);
            CREATE INDEX index_asset_on_blob_hash   ON asset(blob_hash);
            CREATE INDEX index_asset_on_created_at  ON asset(created_at);
            CREATE INDEX index_asset_on_view_count  ON asset(view_count);
            CREATE INDEX index_asset_on_dedup_key   ON asset(dedup_key);
            """)

        // 5. Content FTS (003 · O1): full-text over the media-less `search_text`,
        //    external-content-synchronized with `asset` (auto INSERT/UPDATE/DELETE
        //    triggers + back-fill), mirroring `source_fts`. Kept SEPARATE from
        //    provenance FTS so `searchAssets` can branch/union the two (007).
        try db.create(virtualTable: "asset_fts", using: FTS5()) { t in
            t.synchronize(withTable: "asset")
            t.column("search_text")
        }
    }

    // MARK: - v12

    /// Fold the v10 user-given `name` / `note` into the content FTS (044/045 · 1A).
    ///
    /// v6 built `asset_fts` over `search_text` alone, so naming or annotating an
    /// asset left it unfindable by that name/note — the strongest user-supplied
    /// signal was invisible to search. FTS5 columns are fixed at creation, so
    /// widening the index means rebuilding the virtual table.
    ///
    /// The `asset` table itself is untouched (no rebuild, no FK dance): only the
    /// derived index is dropped and recreated. GRDB's `synchronize(withTable:)`
    /// regenerates the INSERT/UPDATE/DELETE triggers AND runs the `'rebuild'`
    /// backfill, so every existing row's `search_text` / `name` / `note` is
    /// re-indexed in one transactional step (15A) and future `setName`/`setNote`
    /// writes stay searchable via the triggers — no derivation logic duplicated.
    private static func createV12Schema(_ db: Database) throws {
        // 1. Drop the old sync triggers first — a bare `DROP TABLE asset_fts`
        //    leaves them dangling, and the next `asset` write would fire a trigger
        //    referencing a table that no longer exists. GRDB names them
        //    `__asset_fts_ai/ad/au`; this helper drops exactly those.
        try db.dropFTS5SynchronizationTriggers(forTable: "asset_fts")

        // 2. Drop the narrow index. External-content FTS5 stores no content of its
        //    own (it shadows `asset`), so nothing but the index is lost.
        try db.execute(sql: "DROP TABLE asset_fts;")

        // 3. Recreate over the wider column set. `synchronize` re-establishes the
        //    triggers and back-fills every existing asset from the content table.
        try db.create(virtualTable: "asset_fts", using: FTS5()) { t in
            t.synchronize(withTable: "asset")
            t.column("search_text")
            t.column("name")
            t.column("note")
        }
    }

    // MARK: - v13

    /// Substring search over the short human fields (044 · 046 Phase 2).
    ///
    /// The v1/v6/v12 indexes use the `unicode61` tokenizer, which matches whole
    /// WORDS only: "air" cannot find "chair", and tag/collection names lived in no
    /// index at all — the query layer fell back to un-indexed leading-wildcard
    /// `LIKE '%…%'` scans. FTS5's `trigram` tokenizer indexes every 3-character
    /// window, so `MATCH '"air"'` is a true (indexed) substring test.
    ///
    /// Four SEPARATE trigram tables (a tokenizer is table-wide, so trigram can't
    /// share the unicode61 tables) mirror the external-content pattern — each
    /// `synchronize(withTable:)` regenerates INSERT/UPDATE/DELETE triggers and
    /// back-fills existing rows in one transactional step, so future writes stay
    /// indexed with no derivation logic duplicated:
    ///   • `source_trigram`  — title / author (provenance short fields)
    ///   • `asset_trigram`   — the user-given `name`
    ///   • `tag_trigram`     — tag name
    ///   • `collection_trigram` — collection name
    ///
    /// Scope is deliberately the SHORT fields only. OCR (`analysis_fts`) and the
    /// asset's `note` / `search_text` stay unicode61: a trigram index over long
    /// prose bloats ~1 row per character for no substring-recall win a user asks
    /// for. `case_sensitive 0` + `remove_diacritics 1` match the unicode61 indexes'
    /// folding, so "cafe" finds "Café" here too. Trigram needs ≥3 characters; the
    /// query layer keeps a unicode61 / LIKE fallback for 1–2 char queries.
    private static func createV13Schema(_ db: Database) throws {
        let trigram = FTS5TokenizerDescriptor(
            components: ["trigram", "case_sensitive", "0", "remove_diacritics", "1"])

        try db.create(virtualTable: "source_trigram", using: FTS5()) { t in
            t.tokenizer = trigram
            t.synchronize(withTable: "source")
            t.column("title")
            t.column("author_handle")
            t.column("author_name")
        }
        try db.create(virtualTable: "asset_trigram", using: FTS5()) { t in
            t.tokenizer = trigram
            t.synchronize(withTable: "asset")
            t.column("name")
        }
        try db.create(virtualTable: "tag_trigram", using: FTS5()) { t in
            t.tokenizer = trigram
            t.synchronize(withTable: "tag")
            t.column("name")
        }
        try db.create(virtualTable: "collection_trigram", using: FTS5()) { t in
            t.tokenizer = trigram
            t.synchronize(withTable: "collection")
            t.column("name")
        }
    }

    // MARK: - v14

    /// Semantic text search index (044 · 047 Phase 3a).
    ///
    /// One dense embedding vector per asset, capturing the MEANING of its human
    /// text (title / name / note / OCR) so search can rank by concept, not just
    /// keyword. Additive and independent of `asset_analysis`:
    ///
    /// - `asset_id` is PK and FK → `asset(id) ON DELETE CASCADE` — one embedding
    ///   per asset, dropped with the asset (no orphan sweep, mirrors v7).
    /// - `vector` is the opaque BLOB (512 × Float32 little-endian); AtelierCore
    ///   never interprets it — the analyzer (AtelierIngestion) owns the encoding.
    /// - `content_hash` is a hash of the exact embedded text; the backfill re-embeds
    ///   on a mismatch, so a rename / late-arriving OCR re-indexes even though
    ///   `asset` carries no `updated_at` (047 · 4A staleness signal).
    /// - `model_version` records the embedding model; an upgrade re-embeds via a
    ///   `WHERE model_version < …` scan (the indexed access path), not a schema
    ///   change — decoupled from `asset_analysis.analyzer_version`.
    ///
    /// No FTS here: semantic ranking is Swift-side cosine kNN over these vectors
    /// (SQLite has no vector index), so the vectors are a plain BLOB column.
    private static func createV14Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE asset_embedding (
                asset_id      TEXT    NOT NULL PRIMARY KEY
                    REFERENCES asset(id) ON DELETE CASCADE,
                model_version INTEGER NOT NULL,
                content_hash  TEXT    NOT NULL,
                vector        BLOB    NOT NULL,
                embedded_at   TEXT    NOT NULL
            );
            """)

        // Backfill access path (047): "rows produced by an older model" is a
        // version comparison, so a model upgrade is a WHERE-clause scan.
        try db.execute(sql: """
            CREATE INDEX index_asset_embedding_on_model_version
                ON asset_embedding(model_version);
            """)
    }

    // MARK: - v7

    /// On-device analysis index (012 · I1). One additive `asset_analysis` table,
    /// independent of the v1–v6 library schema (mirrors v3's ledger — no table
    /// rebuild), holding the derived passive metadata a later analyzer produces.
    ///
    /// - `asset_id` is the PRIMARY KEY (one analysis per asset) and REFERENCES
    ///   `asset(id) ON DELETE CASCADE`, so an asset's analysis dies with it — no
    ///   orphan sweep needed (17A discipline).
    /// - `ocr_text` / `colors` / `phash` are all NULLABLE: analysis is derived,
    ///   possibly-absent data (an image with no legible text has no `ocr_text`;
    ///   a media-less kind is never analyzed at all). `colors` is opaque JSON to
    ///   this layer (the analyzer at the AtelierIngestion seam owns its shape);
    ///   `phash` is the 64-bit signature stored as signed `INTEGER` (SQLite has no
    ///   unsigned type — the `UInt64`↔`Int64` bitcast happens at that same seam).
    /// - `analyzed_at` / `analyzer_version` are always present so the backfill can
    ///   locate never-analyzed or stale-version rows with a plain WHERE clause.
    private static func createV7Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE asset_analysis (
                asset_id         TEXT    NOT NULL PRIMARY KEY
                    REFERENCES asset(id) ON DELETE CASCADE,
                ocr_text         TEXT,
                colors           TEXT,
                phash            INTEGER,
                analyzed_at      TEXT    NOT NULL,
                analyzer_version INTEGER NOT NULL
            );
            """)

        // Backfill access path (012): "rows produced by an older analyzer" is a
        // version comparison, so re-analysis after an algorithm upgrade is a
        // WHERE-clause scan, not a schema event.
        try db.execute(sql: """
            CREATE INDEX index_asset_analysis_on_analyzer_version
                ON asset_analysis(analyzer_version);
            """)

        // OCR content FTS (012 · I2): full-text over `ocr_text`, external-content
        // synchronized with `asset_analysis` (auto INSERT/UPDATE/DELETE triggers +
        // back-fill), mirroring `source_fts` / `asset_fts`. `searchAssets` adds it
        // as a third MATCH arm so text INSIDE images (screenshots, type specimens)
        // becomes findable — kept a SEPARATE index (derived data) so analysis
        // writes never touch the content-FTS.
        try db.create(virtualTable: "analysis_fts", using: FTS5()) { t in
            t.synchronize(withTable: "asset_analysis")
            t.column("ocr_text")
        }
    }

    // MARK: - v8

    /// Smart collections (015 · saved searches). A smart collection IS a saved
    /// query — its own entity, NOT a `collection` flag (015 · the 005 O3 lesson:
    /// don't overload the folder table with rows that have no memberships, no
    /// manual order, and can't hold drops). Independent of the library schema
    /// (like v3 / v7), so no table rebuild.
    ///
    /// - `rules` is a VERSIONED JSON blob — opaque TEXT to this layer (the
    ///   `SearchRules` codec at the Services seam owns its shape, the same
    ///   opaque-serialized discipline as `asset_analysis.colors`). The embedded
    ///   `version` field lets the rule shape grow (kinds, color, favorite) without
    ///   a migration; an unknown-newer blob still parses what it understands.
    /// - No FK to `asset`/`tag`: a saved search references tags by id INSIDE its
    ///   rules JSON, not via a relational column, so a deleted tag can't cascade
    ///   the search away — evaluation drops the missing conjunct and badges it
    ///   (015 · "explicit over silently-empty"). Deleting a saved search therefore
    ///   never touches assets.
    /// - The table is small (a handful of rows), so `ORDER BY created_at` needs no
    ///   dedicated index — a scan of a few dozen rows is free (P13: index the
    ///   paths that scale; this one doesn't).
    private static func createV8Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE saved_search (
                id         TEXT NOT NULL PRIMARY KEY,
                name       TEXT NOT NULL,
                rules      TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            """)
    }

    // MARK: - v9

    /// Data-only: normalize `tag.name` by dropping a single leading `#` (matching
    /// `Validation.normalizedTagName`). `trim(substr(name, 2))` computes the
    /// canonical form. Because `(name, source)` has no unique constraint, a hashed
    /// tag may collide with an existing canonical twin — those are merged (join
    /// rows repointed, hashed row deleted) before renaming the rest. Idempotent:
    /// after it runs no `tag.name` begins with `#`, so a re-run is a no-op.
    /// Internal (not private) so the migration test can re-invoke it for the
    /// idempotency assertion; not part of the public surface.
    static func normalizeV9TagNames(_ db: Database) throws {
        // A hashed tag is "removable" when it either normalizes to empty ("#"
        // garbage) or has a canonical twin (same source, same normalized name) to
        // merge into. NB: foreign keys are OFF during a GRDB migration (a full
        // `foreign_key_check` runs afterward), so ON DELETE CASCADE does NOT fire
        // here — join rows must be deleted EXPLICITLY or the post-migration check
        // would flag them as dangling.
        let removableHashed = """
            SELECT hashed.id FROM tag hashed
            WHERE hashed.name LIKE '#%'
              AND (
                trim(substr(hashed.name, 2)) = ''
                OR EXISTS (
                    SELECT 1 FROM tag canon
                    WHERE canon.source = hashed.source
                      AND canon.name = trim(substr(hashed.name, 2))
                      AND canon.id <> hashed.id
                )
              )
            """

        // 1. Merge: point each hashed tag's assets at its canonical twin.
        //    INSERT OR IGNORE respects the composite PK, so an asset already
        //    carrying the twin is untouched.
        try db.execute(sql: """
            INSERT OR IGNORE INTO asset_tag (asset_id, tag_id)
            SELECT at.asset_id, canon.id
            FROM asset_tag at
            JOIN tag hashed ON hashed.id = at.tag_id
            JOIN tag canon
              ON canon.source = hashed.source
             AND canon.name = trim(substr(hashed.name, 2))
             AND canon.id <> hashed.id
            WHERE hashed.name LIKE '#%';
            """)

        // 2. Explicitly drop the join rows of every removable hashed tag.
        try db.execute(sql: "DELETE FROM asset_tag WHERE tag_id IN (\(removableHashed));")

        // 3. Delete the removable hashed tags themselves (twin-merged or garbage).
        try db.execute(sql: "DELETE FROM tag WHERE id IN (\(removableHashed));")

        // 4. Rename the remaining hashed tags (no twin, non-empty) in place.
        try db.execute(sql: """
            UPDATE tag
            SET name = trim(substr(name, 2))
            WHERE name LIKE '#%';
            """)
    }

    // MARK: - v16

    /// Data-only: back-fill the Unsorted invariant (F3) that `AppServices` now
    /// enforces on every membership write — an asset sits in Unsorted if and ONLY
    /// if it sits in no other collection. Two halves, matching the two rules:
    ///
    /// 1. **Filed ⇒ not unsorted.** Drop the Unsorted membership of every asset
    ///    that also belongs to a real collection. Before the invariant, "Add to ▸"
    ///    and the item-detail chips left the asset showing in BOTH places.
    /// 2. **Unfiled ⇒ unsorted.** Give an Unsorted membership to every asset that
    ///    belongs to no collection at all. The grid's Remove had no fallback, so it
    ///    could strand an asset outside every folder — reachable only from search.
    ///
    /// New memberships are APPENDED to Unsorted's manual order (oldest asset
    /// first), so the re-homed items land at the end of the feed rather than
    /// jumping ahead of what is already there. `added_at` is the asset's own
    /// `created_at` — the membership is a repair of history, not a fresh filing,
    /// and a migration has no clock (see v2). Idempotent: after it runs both
    /// halves match nothing, so a re-run is a no-op.
    ///
    /// The Unsorted id is the same literal v2 seeds (`Collection.unsortedID`),
    /// inlined rather than referenced so this shipped body can never drift with
    /// the Domain type.
    static func reconcileV16Unsorted(_ db: Database) throws {
        let unsorted = "00000000-0000-0000-0000-000000000001"

        // 1. Filed ⇒ not unsorted.
        try db.execute(sql: """
            DELETE FROM collection_item
            WHERE collection_id = ?
              AND EXISTS (
                SELECT 1 FROM collection_item other
                WHERE other.asset_id = collection_item.asset_id
                  AND other.collection_id <> ?
              );
            """, arguments: [unsorted, unsorted])

        // 2. Unfiled ⇒ unsorted. Resolved into Swift first: an `INSERT … SELECT`
        // whose correlated subquery reads the table being written to would race
        // its own rows.
        let orphans = try Row.fetchAll(db, sql: """
            SELECT a.id AS id, a.created_at AS created_at
            FROM asset a
            WHERE NOT EXISTS (
                SELECT 1 FROM collection_item ci WHERE ci.asset_id = a.id
            )
            ORDER BY a.created_at, a.id;
            """)
        guard !orphans.isEmpty else { return }

        var order = try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(manual_order), -1) + 1 FROM collection_item
            WHERE collection_id = ?
            """, arguments: [unsorted]) ?? 0
        for orphan in orphans {
            let assetID: String = orphan["id"]
            let createdAt: String = orphan["created_at"]
            try db.execute(sql: """
                INSERT INTO collection_item
                    (id, collection_id, asset_id, added_at, manual_order)
                VALUES (?, ?, ?, ?, ?);
                """, arguments: [
                    UUID().uuidString.lowercased(), unsorted, assetID, createdAt, order,
                ])
            order += 1
        }
    }

    // MARK: - v17

    /// Per-space camera persistence (018 · Cluster C). ONE additive column, NULL
    /// on every existing row and **no back-fill**: there is no historical camera to
    /// recover, and NULL already means what the first open has always done — fit
    /// the board to the window (`CanvasEngine.frameToContent(padding:)`).
    ///
    /// TEXT holding a ``SpaceCamera`` JSON blob rather than three REAL columns,
    /// mirroring `space_item.style` (v4): the value is opaque to SQLite, every
    /// field inside it is optional, and growing the shape later — a saved "home"
    /// view, a per-window camera — is a change to the Swift type rather than a
    /// second migration. Both halves of that are load-bearing here, because the
    /// decode is forgiving by design: a partial or malformed blob resolves to
    /// nothing and falls back to the same fit, so this column can never make a
    /// board unopenable.
    ///
    /// No index: the camera is only ever read as part of its own `space` row.
    private static func createV17Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE space ADD COLUMN camera TEXT NULL;
            """)
    }

    // MARK: - v18

    /// Data-only: promote the pre-platform rednote harvest to `Platform.rednote`.
    ///
    /// The 2026-07-31 manual run landed its notes before `rednote` existed as a
    /// platform, so every one of those sources was stored as `platform = 'web'`
    /// with the origin recorded only in `raw_metadata` as `{"source":"rednote"}`.
    /// Now that the case exists, those rows must carry it too — otherwise they
    /// filter, display and dedup as generic web captures forever.
    ///
    /// Scope is deliberately narrow: only `web` rows whose `raw_metadata` is valid
    /// JSON carrying exactly that marker. A `web` row without the marker, a row
    /// already on another platform, and a row whose `raw_metadata` is garbage (or,
    /// defensively, NULL — the column is `NOT NULL`, but a migration should not
    /// depend on that) are all left alone. The `json_valid` guard rides inside a
    /// `CASE`, not as a preceding `AND`: only `CASE` guarantees the `json_extract`
    /// is not evaluated on a malformed value, which would abort the migration.
    ///
    /// Idempotent: after it runs the flipped rows are no longer `web`, so a second
    /// pass matches nothing.
    static func retagV18RednoteSources(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE source
            SET platform = 'rednote'
            WHERE platform = 'web'
              AND CASE
                    WHEN json_valid(raw_metadata)
                    THEN json_extract(raw_metadata, '$.source') = 'rednote'
                    ELSE 0
                  END;
            """)
    }

    // MARK: - v19

    /// Favorites (011 · U5). ONE additive `asset.is_favorite` column — `INTEGER
    /// NOT NULL DEFAULT 0`, the boolean encoding SQLite actually has, and a
    /// CONSTANT default, which is what makes the `ALTER` legal (same shape as
    /// v5's `view_count`). Existing rows therefore read `false`: nothing was a
    /// favorite before the flag existed, so there is no history to back-fill
    /// (contrast v11 / v15, which had a prior display order to reproduce).
    ///
    /// The flag lives on `asset`, NOT on `collection_item`: an asset in three
    /// collections is one item the user starred once, and hanging it off the
    /// membership would make "favorite" mean something different in each folder
    /// and lose the star the moment the membership moved.
    ///
    /// **No index, deliberately.** P13 is "index the paths that scale", and this
    /// one does not yet: the favorites filter is a conjunct on a query that is
    /// already bounded (`searchAssets` clamps to ≤500 rows and is normally
    /// narrowed further by FTS, a tag set or a collection scope), so the planner
    /// reaches `is_favorite` with a small row set in hand. A partial
    /// `WHERE is_favorite = 1` index is the right answer if a favorites-only
    /// sweep of a large library ever measures hot — it can be added by a later
    /// migration without touching this one, which is exactly why it is not
    /// speculatively added here.
    private static func createV19Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE asset ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0;
            """)
    }

    // MARK: - v20

    /// The archive shelf (023 · A). ONE additive `asset.archived_at` column —
    /// nullable TEXT, the timestamp encoding this schema uses throughout (C5).
    /// Every existing row is NULL, i.e. not archived, which is the truth: nothing
    /// could have been archived before the column existed, so there is nothing to
    /// back-fill.
    ///
    /// A **timestamp, not a boolean**, at the same storage cost: it buys the
    /// shelf's "most recently archived first" order, "archived 3 months ago"
    /// copy, and any future purge policy without a second migration.
    ///
    /// The flag lives on `asset` for the same reason `is_favorite` (v19) does: an
    /// asset in three collections is ONE item the user put away once. On
    /// `collection_item` it would mean something different per folder and would
    /// be lost the moment a membership moved — and unarchiving could not then
    /// restore memberships it had itself destroyed, which is the whole point of
    /// archiving rather than deleting.
    ///
    /// **A partial index ships with the column** — unlike v19, which deliberately
    /// shipped none. The difference is the surface each one serves. The favorites
    /// filter is a conjunct on an already-bounded query (`searchAssets` clamps to
    /// ≤500 rows), so the planner meets it holding a small row set. The Archived
    /// destination is the opposite: `WHERE archived_at IS NOT NULL ORDER BY
    /// archived_at DESC` across the WHOLE library with no collection scope, and
    /// `asset` carries no index that helps it (`source_id`, `blob_hash`,
    /// `created_at`, `view_count`, `dedup_key`). Unindexed, every open of the
    /// shelf is a full table scan plus a sort — on the one surface whose row
    /// count only ever grows, because archiving is how it grows.
    ///
    /// Partial (`WHERE archived_at IS NOT NULL`) so it indexes only archived
    /// rows: tiny in a library where almost nothing is archived, and it costs the
    /// hot un-archived path nothing, since a NULL check over a column that is
    /// NULL for ~everything is not a lookup an index can improve.
    ///
    /// If a later migration ever REBUILDS `asset` (the v10 pattern — SQLite
    /// cannot drop a column in place), it must recreate this index along with the
    /// v1/v5 ones; indexes drop with their table.
    private static func createV20Schema(_ db: Database) throws {
        try db.execute(sql: """
            ALTER TABLE asset ADD COLUMN archived_at TEXT;
            CREATE INDEX index_asset_on_archived_at ON asset(archived_at)
                WHERE archived_at IS NOT NULL;
            """)
    }

    // MARK: - v21

    /// The color filter's index (085 · C1). One additive `asset_color` table
    /// holding, per asset, which palette buckets its dominant colors fell into
    /// and how much of the image each covers.
    ///
    /// **Derived, not authoritative.** `asset_analysis.colors` remains the source
    /// of truth; these rows are `ColorPalette.bucketCoverages` applied to it. The
    /// table exists because the filter must be a SQL predicate — a post-filter
    /// shortens pages and the keyset cursor then pages through the gaps (023 ·
    /// A1) — and AtelierCore cannot see the imaging types that know what a color
    /// is. So Ingestion decides the bucket and this layer stores an integer it
    /// never interprets, exactly as it stores `colors` as opaque JSON.
    ///
    /// - `(asset_id, bucket)` is the PRIMARY KEY: swatches that land in the same
    ///   bucket are MERGED upstream (two reds at 12% and 8% are one red at 20%,
    ///   or neither clears a filter floor), so a bucket appears at most once per
    ///   asset. No `rank` column — display order falls out of `coverage DESC`,
    ///   and a stored rank would be a second thing to keep consistent with it.
    /// - `ON DELETE CASCADE` mirrors `asset_analysis`: the rows die with the
    ///   asset, so no orphan sweep is needed (17A discipline).
    /// - The index is `(bucket, coverage)` because that is the filter's own
    ///   shape — `bucket = ? AND coverage >= ?` is a range scan over it. The PK
    ///   already serves the correlated `asset_id` probe from the other direction,
    ///   so between them SQLite can drive the join from whichever side is more
    ///   selective.
    ///
    /// Empty after this migration: it is populated by a backfill pass, not here.
    /// Deriving ~5 rows per asset at launch is fine at 500 assets and a stall at
    /// 50,000, and the derivation needs no blob bytes — only the hex already
    /// stored in `asset_analysis.colors`.
    private static func createV21Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE asset_color (
                asset_id TEXT    NOT NULL
                    REFERENCES asset(id) ON DELETE CASCADE,
                bucket   INTEGER NOT NULL,
                coverage REAL    NOT NULL,
                PRIMARY KEY (asset_id, bucket)
            );
            CREATE INDEX index_asset_color_on_bucket
                ON asset_color(bucket, coverage);
            """)

        // The derivation marker, on `asset_analysis` beside `analyzer_version`
        // it mirrors. NULL means "these colors have not been filed into buckets
        // at any palette version".
        //
        // Without it, "derived and produced nothing" is indistinguishable from
        // "not derived yet" — the row count is zero either way — so an asset
        // whose `colors` JSON is unreadable, or whose every hex is malformed,
        // would be handed to the backfill on every pass forever. A queue that
        // never drains is worse than a slow one: `drain()` would spin to its
        // batch cap on every launch.
        //
        // Storing the VERSION rather than a boolean also makes a palette change
        // a WHERE clause instead of a schema event, exactly as
        // `analyzer_version` does for the analyzer: widen a threshold or add a
        // bucket, bump the constant, and every asset re-derives — from the hex
        // already on disk, with no image decoded.
        try db.execute(sql: """
            ALTER TABLE asset_analysis ADD COLUMN colors_palette_version INTEGER;
            """)
    }

    // MARK: - v22

    /// Suggested tags (012 · I3). The suggest-and-confirm posture needs two
    /// things the schema has never had: somewhere to remember a REFUSAL, and a
    /// marker saying which suggester has already looked at an asset.
    ///
    /// **`tag_suppression` is the whole design.** A dismissed suggestion cannot
    /// simply delete its `asset_tag` row, because the next suggester pass would
    /// compute the same label from the same pixels and put it straight back —
    /// and 012's own risk list names that resurrection as the failure mode. So a
    /// refusal is recorded as its own durable fact, keyed on the NAME rather
    /// than on a `tag.id`:
    ///
    /// - Keyed on `tag_name` because the tag row it refers to may not exist. The
    ///   dismissal deletes the join row, and nothing keeps an orphaned `.agent`
    ///   tag alive once no asset carries it; a `tag_id` FK would either resurrect
    ///   the tag to hold the reference or CASCADE the suppression away, which is
    ///   exactly the memory loss this table exists to prevent.
    /// - The name stored is the NORMALIZED one (``Validation/tagName(_:)`` —
    ///   trimmed, leading `#` stripped), so a suppression matches the name a
    ///   suggester would apply, character for character.
    /// - Per (asset, name), not global: refusing "poster" on one screenshot says
    ///   nothing about the next one. A library-wide never-suggest list is a
    ///   defensible later addition, and it would be a second table, not a
    ///   widening of this one.
    /// - `ON DELETE CASCADE` on `asset_id`, like every other per-asset derived
    ///   table here (17A): the refusal dies with the thing it was about.
    /// - No secondary index. Every read is "what has this asset refused",
    ///   which the `(asset_id, tag_name)` primary key already serves as a
    ///   prefix scan.
    ///
    /// `suggest_version` sits on `asset_analysis` beside `analyzer_version` and
    /// `colors_palette_version`, and is deliberately SEPARATE from
    /// `analyzer_version` rather than folded into it. Bumping the analyzer
    /// version re-runs OCR, colors and the perceptual hash over every image in
    /// the library — a full re-decode — so tying classification to it would mean
    /// a tag-model change costs a complete re-OCR, and the two things change on
    /// entirely different schedules. NULL means "no suggester has run here yet".
    ///
    /// Both are empty/NULL after this migration. Suggestions are produced by a
    /// backfill pass, not by a migration: it decodes bytes and runs a Vision
    /// model, which is not work a database upgrade may do.
    private static func createV22Schema(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE tag_suppression (
                asset_id      TEXT NOT NULL
                    REFERENCES asset(id) ON DELETE CASCADE,
                tag_name      TEXT NOT NULL,
                suppressed_at TEXT NOT NULL,
                PRIMARY KEY (asset_id, tag_name)
            );
            """)

        try db.execute(sql: """
            ALTER TABLE asset_analysis ADD COLUMN suggest_version INTEGER;
            """)
    }
}
