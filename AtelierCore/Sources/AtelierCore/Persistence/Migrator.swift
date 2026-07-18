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
    static let registeredIdentifiers = ["v1", "v2", "v3", "v4", "v5", "v6", "v7"]

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
}
