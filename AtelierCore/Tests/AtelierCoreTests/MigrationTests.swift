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
    static let committedIdentifiers = ["v1", "v2"]

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
        #expect(applied == Self.committedIdentifiers)
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

    @Test("asset columns: names present, required NOT NULL, optionals nullable")
    func assetColumns() throws {
        let dbQueue = try makeMigratedQueue()
        let nn = try dbQueue.read { try columnNotNull($0, table: "asset") }
        let expected = ["id", "kind", "blob_hash", "mime_type", "width",
                        "height", "duration", "file_size", "download_state",
                        "created_at", "source_id"]
        for c in expected { #expect(nn[c] != nil, "asset missing \(c)") }
        #expect(nn["source_id"] == 1)   // provenance required (C6)
        #expect(nn["blob_hash"] == 1)
        #expect(nn["kind"] == 1)
        #expect(nn["width"] == 1)
        #expect(nn["height"] == 1)
        #expect(nn["file_size"] == 1)
        #expect(nn["download_state"] == 1)
        #expect(nn["created_at"] == 1)
        #expect(nn["duration"] == 0)    // optional
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
