// AtelierCore — migration suite (chunk 3, decision T10)
//
// Exercises the v1 schema migrator: it migrates cleanly, the table/column/
// index/FTS shape matches the contract, foreign keys are enforced, and the
// cascade policy (decision 17A) behaves exactly. In-memory DatabaseQueue is
// sufficient for schema + FK-action assertions in this chunk (the temp-file
// DatabasePool store helper arrives in a later chunk).

import Foundation
import Testing
import GRDB
@testable import AtelierCore

// MARK: - Helpers

/// A freshly migrated in-memory database. `DatabaseQueue()` opens an in-memory
/// SQLite db; GRDB enables `PRAGMA foreign_keys` on every connection by default.
private func makeMigratedQueue() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try Migrator.makeMigrator().migrate(dbQueue)
    return dbQueue
}

/// The set of base (non-FTS, non-shadow) tables the schema must contain.
private let expectedTables = [
    "source", "asset", "collection", "collection_item", "tag", "asset_tag",
    "job", "job_item", "space", "space_item", "asset_analysis", "saved_search",
]

/// `PRAGMA table_info` → column name ⇒ notnull flag (1 = NOT NULL).
private func columnNotNull(_ db: Database, table: String) throws -> [String: Int] {
    var result: [String: Int] = [:]
    for row in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") {
        let name: String = row["name"]
        result[name] = row["notnull"]
    }
    return result
}

/// Names of indices on a table (`PRAGMA index_list`).
private func indexNames(_ db: Database, table: String) throws -> [String] {
    try Row.fetchAll(db, sql: "PRAGMA index_list(\(table))").map { $0["name"] }
}

// Minimal ISO-8601-ish timestamps + uuid strings for raw-SQL fixtures (the
// real funnel formats these; here any TEXT is fine for schema/FK assertions).
private func newID() -> String { UUID().uuidString.lowercased() }
private let ts = "2026-06-30T12:00:00Z"

// MARK: - Migration runs

@Suite("Migration: runs cleanly")
struct MigrationRunTests {

    @Test("migrate() succeeds on a fresh database without throwing")
    func migratesFreshDB() throws {
        let dbQueue = try DatabaseQueue()
        #expect(throws: Never.self) {
            try Migrator.makeMigrator().migrate(dbQueue)
        }
    }

    @Test("after migrating, the migrator reports completion")
    func reportsCompletion() throws {
        let dbQueue = try makeMigratedQueue()
        let migrator = Migrator.makeMigrator()
        let completed = try dbQueue.read { db in
            try migrator.hasCompletedMigrations(db)
        }
        #expect(completed)
    }

    @Test("migrating twice is idempotent (no throw on re-run)")
    func reMigrateIsIdempotent() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: Never.self) {
            try Migrator.makeMigrator().migrate(dbQueue)
        }
    }
}

// MARK: - Append-only guard

@Suite("Migration: append-only guard")
struct MigrationAppendOnlyTests {

    // PINNED COMMITTED LIST. Editing or removing a shipped migration identifier
    // is FORBIDDEN — it would re-run or diverge already-migrated installs. To
    // change the schema, APPEND a new identifier ("v2", …) here and register it.
    static let committedIdentifiers = ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11"]

    @Test("registered identifiers equal the pinned committed list (DatabaseMigrator.migrations)")
    func registeredIdentifiersMatch() {
        // GRDB exposes the ordered identifiers via `DatabaseMigrator.migrations`.
        #expect(Migrator.makeMigrator().migrations == Self.committedIdentifiers)
    }

    @Test("the migrator's own pinned constant matches the committed list")
    func namespaceConstantMatches() {
        #expect(Migrator.registeredIdentifiers == Self.committedIdentifiers)
    }

    @Test("applied identifiers recorded in grdb_migrations match the committed list")
    func appliedIdentifiersMatch() throws {
        let dbQueue = try makeMigratedQueue()
        let applied = try dbQueue.read { db in
            try String.fetchAll(
                db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier"
            )
        }
        // Compare as sets: grdb_migrations orders identifiers lexically, where
        // "v10" falls between "v1" and "v2" — the applied SET, not its string
        // order, is what must equal the committed list.
        #expect(Set(applied) == Set(Self.committedIdentifiers))
    }
}

// MARK: - v11 · collection sort_index back-fill (043 · 2B)

@Suite("Migration v11: collection sort_index back-fill")
struct MigrationV11Tests {

    /// A migrator applied only THROUGH v10 (pre `sort_index`), so a test can seed
    /// unordered collections and then migrate v11 over them — the upgrade path.
    private func makeQueueThroughV10() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try Migrator.makeMigrator().migrate(dbQueue, upTo: "v10")
        return dbQueue
    }

    @Test("v11 back-fills a dense per-parent sort_index in (name, id) order")
    func backfillDensePerParent() throws {
        let dbQueue = try makeQueueThroughV10()
        // Seed roots + children with NO sort_index (the column doesn't exist yet),
        // deliberately out of name order.
        try dbQueue.write { db in
            func insert(id: String, name: String, parent: String?) throws {
                try db.execute(sql: """
                    INSERT INTO collection (id, name, description, cover_asset_id,
                        created_at, updated_at, parent_collection_id, sort_mode)
                    VALUES (?, ?, NULL, NULL, '2024-01-01 00:00:00.000',
                        '2024-01-01 00:00:00.000', ?, 'manual');
                    """, arguments: [id, name, parent])
            }
            try insert(id: "r-b", name: "Beta", parent: nil)   // roots, reversed
            try insert(id: "r-a", name: "Alpha", parent: nil)
            try insert(id: "c-z", name: "Zed", parent: "r-a")  // Alpha's kids, reversed
            try insert(id: "c-m", name: "Mid", parent: "r-a")
        }

        try Migrator.makeMigrator().migrate(dbQueue)  // apply v11

        let (roots, alphaKids) = try dbQueue.read {
            db -> ([(String, Int)], [(String, Int)]) in
            let roots = try Row.fetchAll(db, sql: """
                SELECT name, sort_index FROM collection
                WHERE parent_collection_id IS NULL ORDER BY sort_index
                """).map { row -> (String, Int) in (row["name"], row["sort_index"]) }
            let kids = try Row.fetchAll(db, sql: """
                SELECT name, sort_index FROM collection
                WHERE parent_collection_id = 'r-a' ORDER BY sort_index
                """).map { row -> (String, Int) in (row["name"], row["sort_index"]) }
            return (roots, kids)
        }

        // Roots by (name, id): Alpha, Beta, then the seeded Unsorted — dense 0..2.
        #expect(roots.map(\.0) == ["Alpha", "Beta", "Unsorted"])
        #expect(roots.map(\.1) == [0, 1, 2])
        // Alpha's children by name: Mid, Zed — dense 0..1.
        #expect(alphaKids.map(\.0) == ["Mid", "Zed"])
        #expect(alphaKids.map(\.1) == [0, 1])
    }
}

// MARK: - Table & column shape

@Suite("Migration: table & column shape")
struct MigrationShapeTests {

    @Test("every expected base table exists in sqlite_master")
    func tablesExist() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { db in
            try String.fetchSet(
                db, sql: "SELECT name FROM sqlite_master WHERE type='table'"
            )
        }
        for table in expectedTables {
            #expect(names.contains(table), "missing table: \(table)")
        }
    }

    @Test("source columns: names present, required NOT NULL, optionals nullable")
    func sourceColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "source") }
        let expected = ["id", "platform", "original_url", "author_handle",
                        "author_name", "title", "captured_at", "raw_metadata"]
        for c in expected { #expect(nn[c] != nil, "source missing \(c)") }
        // Required.
        #expect(nn["id"] == 1)
        #expect(nn["platform"] == 1)
        #expect(nn["captured_at"] == 1)
        #expect(nn["raw_metadata"] == 1)
        // Optional.
        #expect(nn["original_url"] == 0)
        #expect(nn["author_handle"] == 0)
        #expect(nn["author_name"] == 0)
        #expect(nn["title"] == 0)
    }

    @Test("asset columns (post-v6): identity/state NOT NULL, byte + content columns nullable")
    func assetColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "asset") }
        let expected = ["id", "kind", "blob_hash", "mime_type", "width",
                        "height", "duration", "file_size", "download_state",
                        "created_at", "source_id", "view_count", "last_viewed_at",
                        "payload", "dedup_key", "search_text"]
        for c in expected { #expect(nn[c] != nil, "asset missing \(c)") }
        // Identity / provenance / lifecycle stay required.
        #expect(nn["source_id"] == 1)   // provenance required (C6)
        #expect(nn["kind"] == 1)
        #expect(nn["download_state"] == 1)
        #expect(nn["created_at"] == 1)
        #expect(nn["view_count"] == 1)  // v5, DEFAULT 0
        // Byte columns are now NULLABLE — a media-less kind has no bytes (003·O1).
        #expect(nn["blob_hash"] == 0)
        #expect(nn["mime_type"] == 0)
        #expect(nn["width"] == 0)
        #expect(nn["height"] == 0)
        #expect(nn["file_size"] == 0)
        #expect(nn["duration"] == 0)
        // Content columns are nullable (only media-less kinds populate them).
        #expect(nn["payload"] == 0)
        #expect(nn["dedup_key"] == 0)
        #expect(nn["search_text"] == 0)
    }

    @Test("collection columns: name & timestamps NOT NULL, optionals nullable")
    func collectionColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "collection") }
        let expected = ["id", "name", "description", "cover_asset_id",
                        "created_at", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "collection missing \(c)") }
        #expect(nn["name"] == 1)
        #expect(nn["created_at"] == 1)
        #expect(nn["updated_at"] == 1)
        #expect(nn["description"] == 0)
        #expect(nn["cover_asset_id"] == 0)
    }

    @Test("collection_item columns: FKs & added_at NOT NULL, placement nullable")
    func collectionItemColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "collection_item") }
        let expected = ["id", "collection_id", "asset_id", "added_at",
                        "manual_order", "canvas_x", "canvas_y", "canvas_w",
                        "canvas_h", "canvas_z"]
        for c in expected { #expect(nn[c] != nil, "collection_item missing \(c)") }
        #expect(nn["collection_id"] == 1)
        #expect(nn["asset_id"] == 1)
        #expect(nn["added_at"] == 1)
        // Placement is all optional.
        for c in ["manual_order", "canvas_x", "canvas_y", "canvas_w", "canvas_h", "canvas_z"] {
            #expect(nn[c] == 0, "\(c) should be nullable")
        }
    }

    @Test("tag columns present and required NOT NULL")
    func tagColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "tag") }
        for c in ["id", "name", "source"] {
            #expect(nn[c] == 1, "tag.\(c) should be NOT NULL")
        }
    }

    @Test("asset_tag has a composite primary key over (asset_id, tag_id) and no own id")
    func assetTagCompositePK() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(asset_tag)")
            let names = Set(rows.map { $0["name"] as String })
            #expect(names == ["asset_id", "tag_id"])
            #expect(!names.contains("id"))
            // Both columns are part of the PK (pk index 1 and 2, non-zero).
            for row in rows {
                let pk: Int = row["pk"]
                #expect(pk > 0, "\(row["name"] as String) should be in the PK")
            }
        }
    }
}

// MARK: - Indices

@Suite("Migration: indices (P13)")
struct MigrationIndexTests {

    @Test("every P13 index exists")
    func indicesExist() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { db in
            try String.fetchSet(
                db, sql: "SELECT name FROM sqlite_master WHERE type='index'"
            )
        }
        let expected = [
            "index_collection_item_on_collection_id",
            "index_collection_item_on_asset_id",
            "index_asset_on_source_id",
            "index_asset_on_blob_hash",
            "index_asset_on_created_at",
            "index_collection_item_on_collection_id_manual_order",
            "index_source_on_platform",
            "index_asset_tag_on_tag_id",
        ]
        for idx in expected {
            #expect(names.contains(idx), "missing index: \(idx)")
        }
    }

    @Test("asset(blob_hash) index is NON-unique (dedup: one blob, many rows)")
    func blobHashIndexIsNonUnique() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let list = try Row.fetchAll(db, sql: "PRAGMA index_list(asset)")
            let blobHash = list.first { ($0["name"] as String) == "index_asset_on_blob_hash" }
            #expect(blobHash != nil)
            let unique: Int = blobHash!["unique"]
            #expect(unique == 0, "blob_hash index must be non-unique")
        }
    }
}

// MARK: - FTS5

@Suite("Migration: FTS5 source_fts (P13)")
struct MigrationFTSTests {

    @Test("source_fts virtual table and its sync triggers exist")
    func ftsTableAndTriggersExist() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let tableExists = try Bool.fetchOne(
                db,
                sql: "SELECT count(*) > 0 FROM sqlite_master WHERE type='table' AND name='source_fts'"
            )
            #expect(tableExists == true)
            // The external-content sync triggers live ON the source table.
            let triggerCount = try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='source'"
            )
            #expect((triggerCount ?? 0) >= 3, "expected insert/update/delete sync triggers")
        }
    }

    @Test("inserting a source indexes it; MATCH on title/author returns it")
    func ftsIndexesOnInsert() throws {
        let dbQueue = try makeMigratedQueue()
        let id = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, original_url, author_handle, author_name, title, captured_at, raw_metadata)
                VALUES (?, 'web', NULL, '@minimalist', 'Dieter', 'Bauhaus typography study', ?, '{}')
                """, arguments: [id, ts])
        }
        // The external-content FTS table stores content by rowid; MATCH returns
        // rows whose rowid joins back to source. Assert via a join.
        try dbQueue.read { db in
            let hits = try String.fetchAll(db, sql: """
                SELECT source.id FROM source
                JOIN source_fts ON source_fts.rowid = source.rowid
                WHERE source_fts MATCH 'bauhaus'
                """)
            #expect(hits == [id])

            let byHandle = try String.fetchAll(db, sql: """
                SELECT source.id FROM source
                JOIN source_fts ON source_fts.rowid = source.rowid
                WHERE source_fts MATCH 'minimalist'
                """)
            #expect(byHandle == [id])

            let byName = try String.fetchAll(db, sql: """
                SELECT source.id FROM source
                JOIN source_fts ON source_fts.rowid = source.rowid
                WHERE source_fts MATCH 'dieter'
                """)
            #expect(byName == [id])
        }
    }

    @Test("updating a title re-indexes: new token matches, old token does not")
    func ftsReindexesOnUpdate() throws {
        let dbQueue = try makeMigratedQueue()
        let id = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata, title)
                VALUES (?, 'web', ?, '{}', 'brutalist concrete')
                """, arguments: [id, ts])
        }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE source SET title = 'pastel watercolor' WHERE id = ?",
                           arguments: [id])
        }
        try dbQueue.read { db in
            let old = try String.fetchAll(db, sql: """
                SELECT source.id FROM source JOIN source_fts ON source_fts.rowid = source.rowid
                WHERE source_fts MATCH 'brutalist'
                """)
            #expect(old == [], "old token must no longer match")
            let new = try String.fetchAll(db, sql: """
                SELECT source.id FROM source JOIN source_fts ON source_fts.rowid = source.rowid
                WHERE source_fts MATCH 'watercolor'
                """)
            #expect(new == [id], "new token must match")
        }
    }

    @Test("deleting a source removes it from the FTS index")
    func ftsRemovesOnDelete() throws {
        let dbQueue = try makeMigratedQueue()
        let id = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata, title)
                VALUES (?, 'web', ?, '{}', 'ephemeral neon')
                """, arguments: [id, ts])
            try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [id])
        }
        try dbQueue.read { db in
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM source_fts WHERE source_fts MATCH 'neon'")
            #expect(hits == 0)
        }
    }
}

// MARK: - Foreign keys enabled

@Suite("Migration: foreign keys enforced")
struct MigrationForeignKeyPragmaTests {

    @Test("PRAGMA foreign_keys returns 1")
    func foreignKeysOn() throws {
        let dbQueue = try makeMigratedQueue()
        let on = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
        }
        #expect(on == 1)
    }

    @Test("inserting an asset with a non-existent source_id is rejected")
    func danglingFKRejected() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
                    VALUES (?, 'image', 'abc', 'image/jpeg', 10, 10, 100, 'downloaded', ?, 'no-such-source')
                    """, arguments: [newID(), ts])
            }
        }
    }
}

// MARK: - Cascade policy (decision 17A)

@Suite("Migration: cascade policy (17A)")
struct MigrationCascadeTests {

    /// Inserts source → asset → collection(cover=asset) → collection_item →
    /// tag → asset_tag, returning their ids.
    private func seed(_ db: Database)
        throws -> (source: String, asset: String, collection: String, item: String, tag: String)
    {
        let sourceID = newID(), assetID = newID(), collectionID = newID()
        let itemID = newID(), tagID = newID()

        try db.execute(sql: """
            INSERT INTO source (id, platform, captured_at, raw_metadata)
            VALUES (?, 'web', ?, '{}')
            """, arguments: [sourceID, ts])
        try db.execute(sql: """
            INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
            VALUES (?, 'image', 'hash1', 'image/jpeg', 100, 100, 2048, 'downloaded', ?, ?)
            """, arguments: [assetID, ts, sourceID])
        try db.execute(sql: """
            INSERT INTO collection (id, name, cover_asset_id, created_at, updated_at)
            VALUES (?, 'Refs', ?, ?, ?)
            """, arguments: [collectionID, assetID, ts, ts])
        try db.execute(sql: """
            INSERT INTO collection_item (id, collection_id, asset_id, added_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [itemID, collectionID, assetID, ts])
        try db.execute(sql: """
            INSERT INTO tag (id, name, source) VALUES (?, 'mood', 'user')
            """, arguments: [tagID])
        try db.execute(sql: """
            INSERT INTO asset_tag (asset_id, tag_id) VALUES (?, ?)
            """, arguments: [assetID, tagID])

        return (sourceID, assetID, collectionID, itemID, tagID)
    }

    private func count(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
    }

    @Test("deleting a collection cascades its items; asset and source survive")
    func deleteCollectionCascadesItems() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db -> (String, String, String) in
            let s = try seed(db)
            return (s.collection, s.asset, s.source)
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [ids.0])
        }
        try dbQueue.read { db in
            let items = try count(db, "SELECT count(*) FROM collection_item WHERE collection_id = ?", [ids.0])
            let assets = try count(db, "SELECT count(*) FROM asset WHERE id = ?", [ids.1])
            let sources = try count(db, "SELECT count(*) FROM source WHERE id = ?", [ids.2])
            #expect(items == 0)
            #expect(assets == 1)
            #expect(sources == 1)
        }
    }

    @Test("deleting an asset cascades items & asset_tags and SET NULLs the cover")
    func deleteAssetCascadesAndSetsNullCover() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [ids.asset])
        }
        try dbQueue.read { db in
            // CASCADE: memberships and tag joins gone.
            let items = try count(db, "SELECT count(*) FROM collection_item WHERE asset_id = ?", [ids.asset])
            let joins = try count(db, "SELECT count(*) FROM asset_tag WHERE asset_id = ?", [ids.asset])
            // SET NULL: the collection survives with a cleared cover.
            let collections = try count(db, "SELECT count(*) FROM collection WHERE id = ?", [ids.collection])
            let cover = try String.fetchOne(
                db, sql: "SELECT cover_asset_id FROM collection WHERE id = ?", arguments: [ids.collection])
            // The tag row itself survives (only the join cascaded).
            let tags = try count(db, "SELECT count(*) FROM tag WHERE id = ?", [ids.tag])
            #expect(items == 0)
            #expect(joins == 0)
            #expect(collections == 1)
            #expect(cover == nil, "cover_asset_id should be NULL after SET NULL")
            #expect(tags == 1)
        }
    }

    @Test("deleting a source with surviving assets is REJECTED (RESTRICT)")
    func deleteSourceWithAssetsRejected() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        // RESTRICT → the delete throws.
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [ids.source])
            }
        }
        // Source is still there.
        try dbQueue.read { db in
            let sources = try count(db, "SELECT count(*) FROM source WHERE id = ?", [ids.source])
            #expect(sources == 1)
        }
    }

    @Test("after removing the asset, the source can be deleted")
    func deleteSourceAfterAssetGone() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        // Remove the dependents (collection references the asset as cover → SET NULL;
        // delete the asset first, then the source has no RESTRICT-ing children).
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [ids.asset])
        }
        #expect(throws: Never.self) {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [ids.source])
            }
        }
        try dbQueue.read { db in
            let sources = try count(db, "SELECT count(*) FROM source WHERE id = ?", [ids.source])
            #expect(sources == 0)
        }
    }

    @Test("deleting a tag cascades its asset_tag joins; the asset survives")
    func deleteTagCascadesJoins() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM tag WHERE id = ?", arguments: [ids.tag])
        }
        try dbQueue.read { db in
            let joins = try count(db, "SELECT count(*) FROM asset_tag WHERE tag_id = ?", [ids.tag])
            let assets = try count(db, "SELECT count(*) FROM asset WHERE id = ?", [ids.asset])
            #expect(joins == 0)
            #expect(assets == 1)
        }
    }
}

// MARK: - v2 · nested folders (F1/F3/F4)

@Suite("Migration v2: nested-folder schema shape")
struct FolderSchemaShapeTests {

    @Test("collection gains a nullable parent_collection_id (TEXT) column")
    func parentColumnExistsNullable() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(collection)")
            let parent = rows.first { ($0["name"] as String) == "parent_collection_id" }
            #expect(parent != nil, "collection missing parent_collection_id")
            #expect((parent?["notnull"] as Int?) == 0, "parent_collection_id must be nullable")
            #expect((parent?["type"] as String?) == "TEXT", "parent_collection_id must be TEXT")
        }
    }

    @Test("index_collection_on_parent_collection_id exists")
    func parentIndexExists() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        #expect(names.contains("index_collection_on_parent_collection_id"))
    }

    @Test("foreign keys stay enforced after v2")
    func foreignKeysStillOn() throws {
        let dbQueue = try makeMigratedQueue()
        let on = try dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(on == 1)
    }
}

@Suite("Migration v2: seeded Unsorted folder (F3)")
struct FolderSeedTests {

    @Test("a protected Unsorted root folder is seeded with the fixed well-known id")
    func unsortedSeeded() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT id, name, parent_collection_id FROM collection WHERE id = ?",
                arguments: [Collection.unsortedID.uuidString.lowercased()]
            )
            #expect(row != nil, "Unsorted folder not seeded")
            #expect((row?["name"] as String?) == "Unsorted")
            #expect((row?["parent_collection_id"] as String?) == nil, "Unsorted must be a root folder")
        }
    }

    @Test("the seeded id matches Collection.unsortedID")
    func unsortedIDMatchesConstant() {
        #expect(Collection.unsortedID == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    }
}

@Suite("Migration v2: subtree cascade (F4)")
struct FolderCascadeTests {

    private func count(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
    }

    /// Builds P → C → G folders, a source+asset, and a membership filing the
    /// asset directly into C. Returns the ids.
    private func seedTree(_ db: Database)
        throws -> (p: String, c: String, g: String, source: String, asset: String, item: String)
    {
        let p = newID(), c = newID(), g = newID()
        let sourceID = newID(), assetID = newID(), itemID = newID()

        try db.execute(sql: """
            INSERT INTO collection (id, name, created_at, updated_at, parent_collection_id)
            VALUES (?, 'P', ?, ?, NULL)
            """, arguments: [p, ts, ts])
        try db.execute(sql: """
            INSERT INTO collection (id, name, created_at, updated_at, parent_collection_id)
            VALUES (?, 'C', ?, ?, ?)
            """, arguments: [c, ts, ts, p])
        try db.execute(sql: """
            INSERT INTO collection (id, name, created_at, updated_at, parent_collection_id)
            VALUES (?, 'G', ?, ?, ?)
            """, arguments: [g, ts, ts, c])
        try db.execute(sql: """
            INSERT INTO source (id, platform, captured_at, raw_metadata)
            VALUES (?, 'web', ?, '{}')
            """, arguments: [sourceID, ts])
        try db.execute(sql: """
            INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
            VALUES (?, 'image', 'hash1', 'image/jpeg', 100, 100, 2048, 'downloaded', ?, ?)
            """, arguments: [assetID, ts, sourceID])
        try db.execute(sql: """
            INSERT INTO collection_item (id, collection_id, asset_id, added_at)
            VALUES (?, ?, ?, ?)
            """, arguments: [itemID, c, assetID, ts])

        return (p, c, g, sourceID, assetID, itemID)
    }

    @Test("deleting root P cascades the whole subtree (P, C, G) + C's memberships; asset & source survive")
    func deleteSubtreeCascades() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seedTree(db) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM collection WHERE id = ?", arguments: [ids.p])
        }
        try dbQueue.read { db in
            // The recursive parent-FK cascade removed every folder in the subtree.
            let pCount = try count(db, "SELECT count(*) FROM collection WHERE id = ?", [ids.p])
            let cCount = try count(db, "SELECT count(*) FROM collection WHERE id = ?", [ids.c])
            let gCount = try count(db, "SELECT count(*) FROM collection WHERE id = ?", [ids.g])
            // C's membership went with it (collection_item.collection_id cascade).
            let itemCount = try count(db, "SELECT count(*) FROM collection_item WHERE id = ?", [ids.item])
            // Library rows survive.
            let assetCount = try count(db, "SELECT count(*) FROM asset WHERE id = ?", [ids.asset])
            let sourceCount = try count(db, "SELECT count(*) FROM source WHERE id = ?", [ids.source])
            #expect(pCount == 0)
            #expect(cCount == 0)
            #expect(gCount == 0)
            #expect(itemCount == 0)
            #expect(assetCount == 1)
            #expect(sourceCount == 1)
        }
    }
}

@Suite("Migration v2: Collection record round-trips parent_collection_id")
struct FolderRoundTripTests {

    private let createdAt = Date(timeIntervalSince1970: 1_700_000_222.500)
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_333.750)

    @Test("a Collection with a non-nil parentCollectionID inserts + fetches back equal")
    func childFolderRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let parent = Collection(
            id: UUID(), name: "Parent",
            createdAt: createdAt, updatedAt: updatedAt)
        let child = Collection(
            id: UUID(), name: "Child",
            createdAt: createdAt, updatedAt: updatedAt,
            parentCollectionID: parent.id)

        try dbQueue.write { db in
            try parent.insert(db)
            try child.insert(db)
        }
        let fetched = try dbQueue.read { db in
            try Collection.filter(Column("id") == child.id.uuidString.lowercased()).fetchOne(db)
        }
        #expect(fetched == child)
        #expect(fetched?.parentCollectionID == parent.id)
    }

    @Test("a root Collection (nil parent) round-trips with parentCollectionID nil")
    func rootFolderRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let root = Collection(
            id: UUID(), name: "Root",
            createdAt: createdAt, updatedAt: updatedAt)

        try dbQueue.write { try root.insert($0) }
        let fetched = try dbQueue.read { db in
            try Collection.filter(Column("id") == root.id.uuidString.lowercased()).fetchOne(db)
        }
        #expect(fetched == root)
        #expect(fetched?.parentCollectionID == nil)
    }
}

// MARK: - v3 · bulk-import job ledger (3A)

@Suite("Migration v3: job / job_item schema shape")
struct JobSchemaShapeTests {

    @Test("job columns: names present, required NOT NULL, optionals nullable")
    func jobColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "job") }
        let expected = ["id", "platform", "scope", "status", "total_estimate",
                        "ingested_count", "created_at", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "job missing \(c)") }
        // Required.
        #expect(nn["id"] == 1)
        #expect(nn["platform"] == 1)
        #expect(nn["status"] == 1)
        #expect(nn["ingested_count"] == 1)
        #expect(nn["created_at"] == 1)
        #expect(nn["updated_at"] == 1)
        // Optional.
        #expect(nn["scope"] == 0)
        #expect(nn["total_estimate"] == 0)
    }

    @Test("job_item columns: FK + status + updated_at NOT NULL, url/blob nullable")
    func jobItemColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "job_item") }
        let expected = ["job_id", "source_id", "source_url", "status",
                        "blob_hash", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "job_item missing \(c)") }
        #expect(nn["job_id"] == 1)
        #expect(nn["source_id"] == 1)
        #expect(nn["status"] == 1)
        #expect(nn["updated_at"] == 1)
        #expect(nn["source_url"] == 0)
        #expect(nn["blob_hash"] == 0)
    }

    @Test("job_item has a composite PK over (job_id, source_id) and no own id")
    func jobItemCompositePK() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(job_item)")
            let pkCols = Set(rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String })
            #expect(pkCols == ["job_id", "source_id"])
            #expect(!rows.contains { ($0["name"] as String) == "id" })
        }
    }

    @Test("v3 indices exist (source_id skip lookup + platform filter)")
    func indicesExist() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        #expect(names.contains("index_job_item_on_source_id"))
        #expect(names.contains("index_job_on_platform"))
    }
}

@Suite("Migration v3: job_item FK behaviour")
struct JobItemForeignKeyTests {

    private func count(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
    }

    private func seedJob(_ db: Database) throws -> String {
        let jobID = newID()
        try db.execute(sql: """
            INSERT INTO job (id, platform, scope, status, total_estimate, ingested_count, created_at, updated_at)
            VALUES (?, 'pinterest', 'board:1', 'open', NULL, 0, ?, ?)
            """, arguments: [jobID, ts, ts])
        return jobID
    }

    @Test("inserting a job_item with a non-existent job_id is rejected")
    func danglingJobIDRejected() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO job_item (job_id, source_id, status, updated_at)
                    VALUES ('no-such-job', 'pin-1', 'ingested', ?)
                    """, arguments: [ts])
            }
        }
    }

    @Test("deleting a job cascades its items (F4-style)")
    func deleteJobCascadesItems() throws {
        let dbQueue = try makeMigratedQueue()
        let jobID = try dbQueue.write { db -> String in
            let id = try seedJob(db)
            try db.execute(sql: """
                INSERT INTO job_item (job_id, source_id, status, updated_at)
                VALUES (?, 'pin-1', 'ingested', ?), (?, 'pin-2', 'skipped', ?)
                """, arguments: [id, ts, id, ts])
            return id
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM job WHERE id = ?", arguments: [jobID])
        }
        try dbQueue.read { db in
            let items = try count(db, "SELECT count(*) FROM job_item WHERE job_id = ?", [jobID])
            #expect(items == 0)
        }
    }

    @Test("the composite PK rejects a duplicate (job_id, source_id)")
    func duplicateItemRejected() throws {
        let dbQueue = try makeMigratedQueue()
        let jobID = try dbQueue.write { db in try seedJob(db) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO job_item (job_id, source_id, status, updated_at)
                VALUES (?, 'pin-1', 'ingested', ?)
                """, arguments: [jobID, ts])
        }
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO job_item (job_id, source_id, status, updated_at)
                    VALUES (?, 'pin-1', 'deduped', ?)
                    """, arguments: [jobID, ts])
            }
        }
    }
}

@Suite("Migration v3: Job / JobItem records round-trip")
struct JobRoundTripTests {

    private let createdAt = Date(timeIntervalSince1970: 1_700_000_100.250)
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_200.500)

    @Test("a Job with optionals set round-trips insert + fetch equal")
    func jobRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let job = Job(
            id: UUID(), platform: .twitter, scope: "bookmarks", status: .paused,
            totalEstimate: 42, ingestedCount: 7,
            createdAt: createdAt, updatedAt: updatedAt)
        try dbQueue.write { try job.insert($0) }
        let fetched = try dbQueue.read { db in try Job.fetchOne(db, key: job.id.uuidString.lowercased()) }
        #expect(fetched == job)
    }

    @Test("a Job with nil optionals round-trips")
    func jobNilOptionalsRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let job = Job(
            id: UUID(), platform: .pinterest, status: .open,
            createdAt: createdAt, updatedAt: updatedAt)
        try dbQueue.write { try job.insert($0) }
        let fetched = try dbQueue.read { db in try Job.fetchOne(db, key: job.id.uuidString.lowercased()) }
        #expect(fetched == job)
        #expect(fetched?.scope == nil)
        #expect(fetched?.totalEstimate == nil)
    }

    @Test("a JobItem round-trips including the composite key and nil optionals")
    func jobItemRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let job = Job(id: UUID(), platform: .pinterest, createdAt: createdAt, updatedAt: updatedAt)
        let item = JobItem(
            jobID: job.id, sourceID: "pin-99", sourceURL: "/sampleuser/sample/",
            status: .ingested, blobHash: "abc123", updatedAt: updatedAt)
        try dbQueue.write { db in
            try job.insert(db)
            try item.insert(db)
        }
        let fetched = try dbQueue.read { db in
            try JobItem
                .filter(Column("job_id") == job.id.uuidString.lowercased())
                .filter(Column("source_id") == "pin-99")
                .fetchOne(db)
        }
        #expect(fetched == item)
    }
}

// MARK: - v4 · first-class spaces (005 · O1)

@Suite("Migration v4: space / space_item schema shape")
struct SpaceSchemaShapeTests {

    @Test("space columns: name & timestamps NOT NULL, cover nullable")
    func spaceColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "space") }
        let expected = ["id", "name", "cover_asset_id", "created_at", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "space missing \(c)") }
        #expect(nn["id"] == 1)
        #expect(nn["name"] == 1)
        #expect(nn["created_at"] == 1)
        #expect(nn["updated_at"] == 1)
        #expect(nn["cover_asset_id"] == 0)
    }

    @Test("space_item columns: FK + kind + geometry + timestamps NOT NULL, asset_id/style nullable")
    func spaceItemColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "space_item") }
        let expected = ["id", "space_id", "kind", "asset_id", "x", "y", "w", "h",
                        "z", "style", "created_at", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "space_item missing \(c)") }
        // Required — every board row has an owning space, a kind, and a rect.
        for c in ["space_id", "kind", "x", "y", "w", "h", "z", "created_at", "updated_at"] {
            #expect(nn[c] == 1, "\(c) should be NOT NULL")
        }
        // Optional — element rows have no asset, asset rows have no style.
        #expect(nn["asset_id"] == 0)
        #expect(nn["style"] == 0)
    }

    @Test("v4 indices exist (space_id board read + asset_id cascade lookup)")
    func indicesExist() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { db in
            try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type='index'")
        }
        #expect(names.contains("index_space_item_on_space_id"))
        #expect(names.contains("index_space_item_on_asset_id"))
    }

    @Test("foreign keys stay enforced after v4")
    func foreignKeysStillOn() throws {
        let dbQueue = try makeMigratedQueue()
        let on = try dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(on == 1)
    }
}

@Suite("Migration v4: space_item FK + cascade behaviour (O1)")
struct SpaceItemForeignKeyTests {

    private func count(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
    }

    /// source → asset → space → one asset row + one element row (NULL asset_id).
    private func seed(_ db: Database)
        throws -> (source: String, asset: String, space: String, assetRow: String, elementRow: String)
    {
        let sourceID = newID(), assetID = newID(), spaceID = newID()
        let assetRow = newID(), elementRow = newID()
        try db.execute(sql: """
            INSERT INTO source (id, platform, captured_at, raw_metadata)
            VALUES (?, 'web', ?, '{}')
            """, arguments: [sourceID, ts])
        try db.execute(sql: """
            INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
            VALUES (?, 'image', 'hash1', 'image/jpeg', 100, 100, 2048, 'downloaded', ?, ?)
            """, arguments: [assetID, ts, sourceID])
        try db.execute(sql: """
            INSERT INTO space (id, name, cover_asset_id, created_at, updated_at)
            VALUES (?, 'Board', ?, ?, ?)
            """, arguments: [spaceID, assetID, ts, ts])
        try db.execute(sql: """
            INSERT INTO space_item (id, space_id, kind, asset_id, x, y, w, h, z, style, created_at, updated_at)
            VALUES (?, ?, 'asset', ?, 0, 0, 100, 100, 0, NULL, ?, ?)
            """, arguments: [assetRow, spaceID, assetID, ts, ts])
        try db.execute(sql: """
            INSERT INTO space_item (id, space_id, kind, asset_id, x, y, w, h, z, style, created_at, updated_at)
            VALUES (?, ?, 'text', NULL, 10, 10, 200, 60, 1, '{"text":"hi"}', ?, ?)
            """, arguments: [elementRow, spaceID, ts, ts])
        return (sourceID, assetID, spaceID, assetRow, elementRow)
    }

    @Test("inserting a space_item with a non-existent space_id is rejected")
    func danglingSpaceIDRejected() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO space_item (id, space_id, kind, x, y, w, h, z, created_at, updated_at)
                    VALUES (?, 'no-such-space', 'asset', 0, 0, 1, 1, 0, ?, ?)
                    """, arguments: [newID(), ts, ts])
            }
        }
    }

    @Test("deleting a space cascades ALL its rows (asset + element); asset & source survive")
    func deleteSpaceCascadesRows() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM space WHERE id = ?", arguments: [ids.space])
        }
        try dbQueue.read { db in
            let rows = try count(db, "SELECT count(*) FROM space_item WHERE space_id = ?", [ids.space])
            let assets = try count(db, "SELECT count(*) FROM asset WHERE id = ?", [ids.asset])
            let sources = try count(db, "SELECT count(*) FROM source WHERE id = ?", [ids.source])
            #expect(rows == 0)
            #expect(assets == 1)
            #expect(sources == 1)
        }
    }

    @Test("deleting an asset vacates ONLY its asset rows; element rows untouched; cover SET NULL")
    func deleteAssetVacatesAssetRowsOnly() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db in try seed(db) }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [ids.asset])
        }
        try dbQueue.read { db in
            // The asset row cascaded away…
            let assetRow = try count(db, "SELECT count(*) FROM space_item WHERE id = ?", [ids.assetRow])
            #expect(assetRow == 0)
            // …the element row (NULL asset_id) is untouched…
            let elementRow = try count(db, "SELECT count(*) FROM space_item WHERE id = ?", [ids.elementRow])
            #expect(elementRow == 1)
            // …the space survives with its cover cleared (SET NULL).
            let spaces = try count(db, "SELECT count(*) FROM space WHERE id = ?", [ids.space])
            let cover = try String.fetchOne(
                db, sql: "SELECT cover_asset_id FROM space WHERE id = ?", arguments: [ids.space])
            #expect(spaces == 1)
            #expect(cover == nil, "cover_asset_id should be NULL after SET NULL")
        }
    }
}

@Suite("Migration v4: Space / SpaceItem records round-trip")
struct SpaceRoundTripTests {

    private let createdAt = Date(timeIntervalSince1970: 1_700_000_444.250)
    private let updatedAt = Date(timeIntervalSince1970: 1_700_000_555.500)

    @Test("a Space round-trips insert + fetch equal (with and without a cover)")
    func spaceRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let space = Space(id: UUID(), name: "Moodboard", createdAt: createdAt, updatedAt: updatedAt)
        try dbQueue.write { try space.insert($0) }
        let fetched = try dbQueue.read { db in try Space.fetchOne(db, key: space.id.uuidString.lowercased()) }
        #expect(fetched == space)
        #expect(fetched?.coverAssetID == nil)
    }

    @Test("an asset SpaceItem round-trips (asset_id set, style nil)")
    func assetItemRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        // A space + a real asset the item can point at (FK).
        let space = Space(id: UUID(), name: "B", createdAt: createdAt, updatedAt: updatedAt)
        let source = Source(id: UUID(), platform: .web, capturedAt: createdAt)
        let asset = Asset(
            id: UUID(), kind: .image, blobHash: "abc", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 100,
            downloadState: .downloaded, createdAt: createdAt, sourceId: source.id)
        let item = SpaceItem(
            id: UUID(), spaceID: space.id, kind: .asset, assetID: asset.id,
            x: 12, y: 34, w: 100, h: 200, z: 3, style: nil,
            createdAt: createdAt, updatedAt: updatedAt)
        try dbQueue.write { db in
            try space.insert(db); try source.insert(db); try asset.insert(db); try item.insert(db)
        }
        let fetched = try dbQueue.read { db in try SpaceItem.fetchOne(db, key: item.id.uuidString.lowercased()) }
        #expect(fetched == item)
    }

    @Test("an element SpaceItem round-trips (asset_id nil, style JSON set)")
    func elementItemRoundTrips() throws {
        let dbQueue = try makeMigratedQueue()
        let space = Space(id: UUID(), name: "B", createdAt: createdAt, updatedAt: updatedAt)
        let item = SpaceItem(
            id: UUID(), spaceID: space.id, kind: .text, assetID: nil,
            x: 0, y: 0, w: 300, h: 80, z: 0,
            style: ElementStyle(text: "hello", fontSize: 18).jsonString(),
            createdAt: createdAt, updatedAt: updatedAt)
        try dbQueue.write { db in try space.insert(db); try item.insert(db) }
        let fetched = try dbQueue.read { db in try SpaceItem.fetchOne(db, key: item.id.uuidString.lowercased()) }
        #expect(fetched == item)
        #expect(fetched?.assetID == nil)
        #expect(ElementStyle(jsonString: fetched?.style)?.text == "hello")
    }
}

@Suite("Migration v5: view tracking + sort mode")
struct MigrationV5Tests {

    @Test("v5 adds asset.view_count / last_viewed_at and collection.sort_mode")
    func columnsExist() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let assetCols = try columnNotNull(db, table: "asset")
            #expect(assetCols["view_count"] == 1)        // NOT NULL
            #expect(assetCols["last_viewed_at"] == 0)     // nullable
            let collectionCols = try columnNotNull(db, table: "collection")
            #expect(collectionCols["sort_mode"] == 1)     // NOT NULL
        }
    }

    @Test("index_asset_on_view_count exists")
    func viewCountIndexed() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let names = try indexNames(db, table: "asset")
            #expect(names.contains("index_asset_on_view_count"))
        }
    }

    @Test("defaults apply to rows inserted without the new columns")
    func defaultsOnExistingShape() throws {
        let dbQueue = try makeMigratedQueue()
        // Insert a source + asset via the pre-v5 column list (no view_count /
        // last_viewed_at) — the defaults must fill them. And the seeded Unsorted
        // collection (v2) must have sort_mode 'manual'.
        try dbQueue.write { db in
            let sid = newID()
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata)
                VALUES (?, 'web', ?, '{}')
                """, arguments: [sid, ts])
            try db.execute(sql: """
                INSERT INTO asset
                    (id, kind, blob_hash, mime_type, width, height, file_size,
                     download_state, created_at, source_id)
                VALUES (?, 'image', 'h', 'image/png', 1, 1, 1, 'downloaded', ?, ?)
                """, arguments: [newID(), ts, sid])
        }
        try dbQueue.read { db in
            let vc = try Int.fetchOne(db, sql: "SELECT view_count FROM asset")
            let lv = try DatabaseValue.fetchOne(db, sql: "SELECT last_viewed_at FROM asset")
            #expect(vc == 0)
            #expect(lv?.isNull == true)
            // The v2-seeded Unsorted folder defaulted to 'manual'.
            let mode = try String.fetchOne(
                db, sql: "SELECT sort_mode FROM collection WHERE id = ?",
                arguments: [Collection.unsortedID.uuidString.lowercased()])
            #expect(mode == "manual")
        }
    }
}

// MARK: - v6 · multi-kind items (003 · O1) — the table rebuild

/// A migrator applied only THROUGH v5 (pre-rebuild), so a test can seed the old
/// shape and then migrate v6 over it — the upgrade path that matters most.
private func makeQueueMigratedThroughV5() throws -> DatabaseQueue {
    let dbQueue = try DatabaseQueue()
    try Migrator.makeMigrator().migrate(dbQueue, upTo: "v5")
    return dbQueue
}

@Suite("Migration v6: rebuilt asset schema shape")
struct MigrationV6ShapeTests {

    @Test("byte columns are nullable, content columns added, identity/state NOT NULL")
    func rebuiltColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "asset") }
        // Newly nullable byte columns (a media-less kind has no bytes).
        for c in ["blob_hash", "mime_type", "width", "height", "file_size", "duration"] {
            #expect(nn[c] == 0, "\(c) must be nullable after v6")
        }
        // New content columns exist and are nullable.
        for c in ["payload", "dedup_key", "search_text"] {
            #expect(nn[c] == 0, "\(c) missing/should be nullable")
        }
        // Identity / lifecycle / provenance / v5 counters survive as required.
        for c in ["id", "kind", "download_state", "created_at", "source_id", "view_count"] {
            #expect(nn[c] == 1, "\(c) must remain NOT NULL")
        }
    }

    @Test("all v1/v5 asset indices are recreated, plus dedup_key")
    func indicesRecreated() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { try indexNames($0, table: "asset") }
        for idx in ["index_asset_on_source_id", "index_asset_on_blob_hash",
                    "index_asset_on_created_at", "index_asset_on_view_count",
                    "index_asset_on_dedup_key"] {
            #expect(names.contains(idx), "missing index after rebuild: \(idx)")
        }
    }

    @Test("blob_hash index stays NON-unique after the rebuild (dedup)")
    func blobHashStillNonUnique() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let list = try Row.fetchAll(db, sql: "PRAGMA index_list(asset)")
            let blob = list.first { ($0["name"] as String) == "index_asset_on_blob_hash" }
            #expect((blob?["unique"] as Int?) == 0)
        }
    }

    @Test("asset(source_id) FK is preserved (dangling source_id still rejected)")
    func fkPreserved() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO asset (id, kind, download_state, created_at, source_id)
                    VALUES (?, 'color', 'downloaded', ?, 'no-such-source')
                    """, arguments: [newID(), ts])
            }
        }
    }
}

@Suite("Migration v6: content FTS (asset_fts)")
struct MigrationV6FTSTests {

    @Test("asset_fts virtual table + sync triggers exist")
    func ftsExists() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let exists = try Bool.fetchOne(
                db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE type='table' AND name='asset_fts'")
            #expect(exists == true)
            let triggers = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='asset'")
            #expect((triggers ?? 0) >= 3, "expected insert/update/delete sync triggers on asset")
        }
    }

    @Test("a media-less asset's search_text is indexed and MATCHes")
    func searchTextIndexed() throws {
        let dbQueue = try makeMigratedQueue()
        let sid = newID(), aid = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata)
                VALUES (?, 'local_paste', ?, '{}')
                """, arguments: [sid, ts])
            try db.execute(sql: """
                INSERT INTO asset (id, kind, download_state, created_at, source_id, payload, dedup_key, search_text)
                VALUES (?, 'color', 'downloaded', ?, ?, '{"color":{"hex":"#ff0000"}}', '#ff0000', 'crimson sunset')
                """, arguments: [aid, ts, sid])
        }
        try dbQueue.read { db in
            let hits = try String.fetchAll(db, sql: """
                SELECT a.id FROM asset a JOIN asset_fts ON asset_fts.rowid = a.rowid
                WHERE asset_fts MATCH 'crimson'
                """)
            #expect(hits == [aid])
        }
    }
}

@Suite("Migration v6: upgrade path — existing rows survive byte-identical")
struct MigrationV6UpgradeTests {

    /// The riskiest migration in the roadmap: seed a v5-shape image + video, run
    /// v6, and assert every column value is preserved verbatim through the
    /// drop/rename rebuild — and that the new content columns are NULL.
    @Test("image + video rows are copied byte-for-byte through the rebuild")
    func existingRowsSurvive() throws {
        let dbQueue = try makeQueueMigratedThroughV5()
        let sid = newID(), imageID = newID(), videoID = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, original_url, captured_at, raw_metadata)
                VALUES (?, 'web', 'https://example.com/x', ?, '{}')
                """, arguments: [sid, ts])
            // A fully-populated image row (with a view already recorded).
            try db.execute(sql: """
                INSERT INTO asset
                    (id, kind, blob_hash, mime_type, width, height, duration,
                     file_size, download_state, created_at, source_id,
                     view_count, last_viewed_at)
                VALUES (?, 'image', 'abc123', 'image/jpeg', 800, 600, NULL,
                        204800, 'downloaded', ?, ?, 3, ?)
                """, arguments: [imageID, ts, sid, ts])
            // A video row (duration set).
            try db.execute(sql: """
                INSERT INTO asset
                    (id, kind, blob_hash, mime_type, width, height, duration,
                     file_size, download_state, created_at, source_id,
                     view_count, last_viewed_at)
                VALUES (?, 'video', 'def456', 'video/mp4', 1920, 1080, 12.5,
                        1048576, 'downloaded', ?, ?, 0, NULL)
                """, arguments: [videoID, ts, sid])
        }

        // Apply v6 (the rebuild).
        try Migrator.makeMigrator().migrate(dbQueue)

        try dbQueue.read { db in
            let image = try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [imageID])!
            #expect((image["kind"] as String) == "image")
            #expect((image["blob_hash"] as String) == "abc123")
            #expect((image["mime_type"] as String) == "image/jpeg")
            #expect((image["width"] as Int) == 800)
            #expect((image["height"] as Int) == 600)
            #expect((image["file_size"] as Int) == 204800)
            #expect((image["view_count"] as Int) == 3)
            #expect((image["last_viewed_at"] as String?) == ts)
            #expect((image["source_id"] as String) == sid)
            // New content columns default to NULL for migrated byte assets.
            #expect((image["payload"] as String?) == nil)
            #expect((image["dedup_key"] as String?) == nil)
            #expect((image["search_text"] as String?) == nil)

            let video = try Row.fetchOne(db, sql: "SELECT * FROM asset WHERE id = ?", arguments: [videoID])!
            #expect((video["duration"] as Double?) == 12.5)
            #expect((video["blob_hash"] as String) == "def456")

            // Both rows are still present (no loss in the copy).
            let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM asset") ?? -1
            #expect(count == 2)
        }
    }

    @Test("cascade policy survives the rebuild: deleting a source with assets is RESTRICTed")
    func restrictSurvivesRebuild() throws {
        let dbQueue = try makeMigratedQueue()  // fully migrated (through v6)
        let sid = newID(), aid = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata)
                VALUES (?, 'web', ?, '{}')
                """, arguments: [sid, ts])
            try db.execute(sql: """
                INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
                VALUES (?, 'image', 'h', 'image/png', 1, 1, 1, 'downloaded', ?, ?)
                """, arguments: [aid, ts, sid])
        }
        // RESTRICT (17A) still enforced on the rebuilt table's FK.
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM source WHERE id = ?", arguments: [sid])
            }
        }
    }
}

// MARK: - v7 · on-device analysis index (012 · I1)

@Suite("Migration v7: asset_analysis schema shape")
struct MigrationV7ShapeTests {

    @Test("asset_analysis columns: asset_id + analyzed_at + analyzer_version NOT NULL, data nullable")
    func columns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "asset_analysis") }
        let expected = ["asset_id", "ocr_text", "colors", "phash",
                        "analyzed_at", "analyzer_version"]
        for c in expected { #expect(nn[c] != nil, "asset_analysis missing \(c)") }
        // Required.
        #expect(nn["asset_id"] == 1)
        #expect(nn["analyzed_at"] == 1)
        #expect(nn["analyzer_version"] == 1)
        // Derived data is all nullable.
        #expect(nn["ocr_text"] == 0)
        #expect(nn["colors"] == 0)
        #expect(nn["phash"] == 0)
    }

    @Test("asset_id is the sole primary key (one analysis per asset, no own id)")
    func assetIDPrimaryKey() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(asset_analysis)")
            let pkCols = Set(rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String })
            #expect(pkCols == ["asset_id"])
            #expect(!rows.contains { ($0["name"] as String) == "id" })
        }
    }

    @Test("phash column is INTEGER-affinity (signed storage of the 64-bit hash)")
    func phashInteger() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(asset_analysis)")
            let phash = rows.first { ($0["name"] as String) == "phash" }
            #expect((phash?["type"] as String?) == "INTEGER")
        }
    }

    @Test("index_asset_analysis_on_analyzer_version exists")
    func versionIndexed() throws {
        let dbQueue = try makeMigratedQueue()
        let names = try dbQueue.read { try indexNames($0, table: "asset_analysis") }
        #expect(names.contains("index_asset_analysis_on_analyzer_version"))
    }

    @Test("foreign keys stay enforced after v7")
    func foreignKeysStillOn() throws {
        let dbQueue = try makeMigratedQueue()
        let on = try dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA foreign_keys") }
        #expect(on == 1)
    }
}

@Suite("Migration v7: asset_analysis FK + cascade")
struct MigrationV7ForeignKeyTests {

    private func count(_ db: Database, _ sql: String, _ args: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: args) ?? -1
    }

    /// source → image asset, returning (source, asset).
    private func seedAsset(_ db: Database) throws -> (source: String, asset: String) {
        let sid = newID(), aid = newID()
        try db.execute(sql: """
            INSERT INTO source (id, platform, captured_at, raw_metadata)
            VALUES (?, 'web', ?, '{}')
            """, arguments: [sid, ts])
        try db.execute(sql: """
            INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
            VALUES (?, 'image', 'hash1', 'image/jpeg', 100, 100, 2048, 'downloaded', ?, ?)
            """, arguments: [aid, ts, sid])
        return (sid, aid)
    }

    @Test("inserting an analysis row for a non-existent asset is rejected")
    func danglingAssetRejected() throws {
        let dbQueue = try makeMigratedQueue()
        #expect(throws: DatabaseError.self) {
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO asset_analysis (asset_id, analyzed_at, analyzer_version)
                    VALUES ('no-such-asset', ?, 1)
                    """, arguments: [ts])
            }
        }
    }

    @Test("deleting an asset cascades its analysis row")
    func deleteAssetCascadesAnalysis() throws {
        let dbQueue = try makeMigratedQueue()
        let ids = try dbQueue.write { db -> (source: String, asset: String) in
            let s = try seedAsset(db)
            try db.execute(sql: """
                INSERT INTO asset_analysis (asset_id, ocr_text, colors, phash, analyzed_at, analyzer_version)
                VALUES (?, 'label text', '[{"hex":"#ff0000","coverage":1.0}]', 42, ?, 1)
                """, arguments: [s.asset, ts])
            return s
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM asset WHERE id = ?", arguments: [ids.asset])
        }
        try dbQueue.read { db in
            let rows = try count(db, "SELECT count(*) FROM asset_analysis WHERE asset_id = ?", [ids.asset])
            #expect(rows == 0)
        }
    }

    @Test("phash round-trips a full 64-bit value as signed INTEGER")
    func phashSignedRoundTrip() throws {
        let dbQueue = try makeMigratedQueue()
        // UInt64.max bit-cast to Int64 is -1: the signed storage must preserve the
        // exact bit pattern so the analyzer can cast it back.
        let signed = Int64(bitPattern: UInt64.max)
        let ids = try dbQueue.write { db -> String in
            let s = try seedAsset(db)
            try db.execute(sql: """
                INSERT INTO asset_analysis (asset_id, phash, analyzed_at, analyzer_version)
                VALUES (?, ?, ?, 1)
                """, arguments: [s.asset, signed, ts])
            return s.asset
        }
        try dbQueue.read { db in
            let stored = try Int64.fetchOne(
                db, sql: "SELECT phash FROM asset_analysis WHERE asset_id = ?", arguments: [ids])
            #expect(stored == signed)
            #expect(UInt64(bitPattern: stored ?? 0) == UInt64.max)
        }
    }
}

@Suite("Migration v7: analysis_fts (OCR full-text)")
struct MigrationV7FTSTests {

    @Test("analysis_fts virtual table + sync triggers exist")
    func ftsExists() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let exists = try Bool.fetchOne(
                db, sql: "SELECT count(*) > 0 FROM sqlite_master WHERE type='table' AND name='analysis_fts'")
            #expect(exists == true)
            let triggers = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='asset_analysis'")
            #expect((triggers ?? 0) >= 3, "expected insert/update/delete sync triggers on asset_analysis")
        }
    }

    @Test("inserting ocr_text indexes it; MATCH returns the asset")
    func ftsIndexesOnInsert() throws {
        let dbQueue = try makeMigratedQueue()
        let sid = newID(), aid = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata) VALUES (?, 'web', ?, '{}')
                """, arguments: [sid, ts])
            try db.execute(sql: """
                INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
                VALUES (?, 'image', 'h', 'image/png', 10, 10, 100, 'downloaded', ?, ?)
                """, arguments: [aid, ts, sid])
            try db.execute(sql: """
                INSERT INTO asset_analysis (asset_id, ocr_text, analyzed_at, analyzer_version)
                VALUES (?, 'Helvetica specimen poster', ?, 1)
                """, arguments: [aid, ts])
        }
        try dbQueue.read { db in
            let hits = try String.fetchAll(db, sql: """
                SELECT an.asset_id FROM asset_analysis an
                JOIN analysis_fts ON analysis_fts.rowid = an.rowid
                WHERE analysis_fts MATCH 'helvetica'
                """)
            #expect(hits == [aid])
        }
    }

    @Test("updating ocr_text re-indexes; deleting the row removes it from the index")
    func ftsReindexAndDelete() throws {
        let dbQueue = try makeMigratedQueue()
        let sid = newID(), aid = newID()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO source (id, platform, captured_at, raw_metadata) VALUES (?, 'web', ?, '{}')
                """, arguments: [sid, ts])
            try db.execute(sql: """
                INSERT INTO asset (id, kind, blob_hash, mime_type, width, height, file_size, download_state, created_at, source_id)
                VALUES (?, 'image', 'h', 'image/png', 10, 10, 100, 'downloaded', ?, ?)
                """, arguments: [aid, ts, sid])
            try db.execute(sql: """
                INSERT INTO asset_analysis (asset_id, ocr_text, analyzed_at, analyzer_version)
                VALUES (?, 'brutalist', ?, 1)
                """, arguments: [aid, ts])
        }
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE asset_analysis SET ocr_text = 'watercolor' WHERE asset_id = ?",
                           arguments: [aid])
        }
        try dbQueue.read { db in
            let old = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM analysis_fts WHERE analysis_fts MATCH 'brutalist'")
            let new = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM analysis_fts WHERE analysis_fts MATCH 'watercolor'")
            #expect(old == 0, "old token must no longer match")
            #expect(new == 1, "new token must match")
        }
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM asset_analysis WHERE asset_id = ?", arguments: [aid])
        }
        try dbQueue.read { db in
            let hits = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM analysis_fts WHERE analysis_fts MATCH 'watercolor'")
            #expect(hits == 0)
        }
    }
}

@Suite("Migration v7: AssetAnalysis record round-trips")
struct AssetAnalysisRoundTripTests {

    private let analyzedAt = Date(timeIntervalSince1970: 1_700_000_777.250)

    /// A real source + image asset the analysis row can reference (FK).
    private func seed(_ db: Database) throws -> Asset {
        let source = Source(id: UUID(), platform: .web, capturedAt: analyzedAt)
        let asset = Asset(
            id: UUID(), kind: .image, blobHash: "abc", mimeType: "image/png",
            width: 10, height: 10, duration: nil, fileSize: 100,
            downloadState: .downloaded, createdAt: analyzedAt, sourceId: source.id)
        try source.insert(db)
        try asset.insert(db)
        return asset
    }

    @Test("a fully-populated analysis row round-trips insert + fetch equal")
    func fullRoundTrip() throws {
        let dbQueue = try makeMigratedQueue()
        let asset = try dbQueue.write { try seed($0) }
        let analysis = AssetAnalysis(
            assetID: asset.id, ocrText: "type specimen",
            colors: "[{\"hex\":\"#0a141e\",\"coverage\":0.5}]",
            phash: Int64(bitPattern: 0xDEAD_BEEF_CAFE_F00D),
            analyzedAt: analyzedAt, analyzerVersion: 3)
        try dbQueue.write { try analysis.insert($0) }
        let fetched = try dbQueue.read { db in
            try AssetAnalysis.fetchOne(db, key: asset.id.uuidString.lowercased())
        }
        #expect(fetched == analysis)
    }

    @Test("an analysis row with all-nil data fields round-trips")
    func nilDataRoundTrip() throws {
        let dbQueue = try makeMigratedQueue()
        let asset = try dbQueue.write { try seed($0) }
        let analysis = AssetAnalysis(
            assetID: asset.id, analyzedAt: analyzedAt, analyzerVersion: 1)
        try dbQueue.write { try analysis.insert($0) }
        let fetched = try dbQueue.read { db in
            try AssetAnalysis.fetchOne(db, key: asset.id.uuidString.lowercased())
        }
        #expect(fetched == analysis)
        #expect(fetched?.ocrText == nil)
        #expect(fetched?.colors == nil)
        #expect(fetched?.phash == nil)
    }
}

// MARK: - v8 · smart collections (saved searches, 015)

@Suite("Migration v8: saved_search schema shape")
struct SavedSearchSchemaTests {

    @Test("saved_search columns: id + name + rules + timestamps, all NOT NULL")
    func columns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "saved_search") }
        let expected = ["id", "name", "rules", "created_at", "updated_at"]
        for c in expected { #expect(nn[c] != nil, "saved_search missing \(c)") }
        #expect(Set(nn.keys) == Set(expected), "unexpected saved_search columns")
        // Every column is NOT NULL — a saved search always has a name and a rule
        // (even an empty "whole library" rule is a real JSON blob).
        for c in expected { #expect(nn[c] == 1, "\(c) should be NOT NULL") }
    }

    @Test("id is the single-column primary key")
    func primaryKey() throws {
        let dbQueue = try makeMigratedQueue()
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(saved_search)")
            let pk = rows.filter { ($0["pk"] as Int) > 0 }.map { $0["name"] as String }
            #expect(pk == ["id"])
        }
    }

    @Test("foreign keys stay enforced after v8")
    func foreignKeysOn() throws {
        let dbQueue = try makeMigratedQueue()
        let on = try dbQueue.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(on == true)
    }
}

@Suite("Migration v8: SavedSearch record round-trips")
struct SavedSearchRoundTripTests {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_888.125)

    @Test("a saved search round-trips insert + fetch equal")
    func roundTrip() throws {
        let dbQueue = try makeMigratedQueue()
        let search = SavedSearch(
            id: UUID(), name: "Pinterest UI",
            rules: #"{"platform":"pinterest","tag_match":"all","version":1}"#,
            createdAt: stamp, updatedAt: stamp)
        try dbQueue.write { try search.insert($0) }
        let fetched = try dbQueue.read { db in
            try SavedSearch.fetchOne(db, key: search.id.uuidString.lowercased())
        }
        #expect(fetched == search)
    }

    @Test("saved searches have no asset/tag FK — deleting one touches nothing else")
    func noOutboundFKs() throws {
        let dbQueue = try makeMigratedQueue()
        // A saved search referencing a tag id INSIDE its rules JSON — that id need
        // not exist as a real row, and deleting the search is a plain row delete.
        let search = SavedSearch(
            id: UUID(), name: "By a ghost tag",
            rules: #"{"tag_ids":["\#(UUID().uuidString.lowercased())"],"tag_match":"all","version":1}"#,
            createdAt: stamp, updatedAt: stamp)
        try dbQueue.write { try search.insert($0) }
        let deleted = try dbQueue.write { db in
            try SavedSearch.deleteOne(db, key: search.id.uuidString.lowercased())
        }
        #expect(deleted == true)
    }
}
