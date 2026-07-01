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
    static let registeredIdentifiers = ["v1", "v2"]

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
}
