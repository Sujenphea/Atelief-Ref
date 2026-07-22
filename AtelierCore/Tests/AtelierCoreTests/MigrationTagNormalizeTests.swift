// AtelierCore — v9 tag-name normalization migration.
//
// v9 strips a leading `#` from stored `tag.name` (a UI affordance that used to
// leak into the name, making `sf` search miss a `#sf` tag). This exercises the
// migration against a pre-v9 database seeded with hashed tags: plain rename,
// merge-onto-canonical-twin (join rows repointed), garbage `#`-only removal,
// non-leading `#` preserved, and source-distinctness (user vs agent) kept.

import Foundation
import Testing
import GRDB
@testable import AtelierCore

@Suite("Migration: v9 tag-name normalization")
struct MigrationTagNormalizeTests {

    /// A queue migrated only up to v8, so v9 can be seeded-then-applied.
    private func makeQueueUpToV8() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Migrator.makeMigrator().migrate(queue, upTo: "v8")
        return queue
    }

    private func makeSource() -> Source {
        Source(
            id: UUID(), platform: .web, originalURL: "https://e/\(UUID().uuidString)",
            authorHandle: nil, authorName: nil, title: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000.5),
            rawMetadata: .object([:]))
    }

    private func makeAsset(sourceId: UUID) -> Asset {
        Asset(
            id: UUID(), kind: .image, blobHash: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            mimeType: "image/png", width: 10, height: 10, duration: nil,
            fileSize: 10, downloadState: .downloaded,
            createdAt: Date(timeIntervalSince1970: 1_700_000_111.25), sourceId: sourceId)
    }

    @Test("v9 renames, merges onto a twin, drops garbage, keeps non-leading and source distinctness")
    func normalizes() throws {
        let queue = try makeQueueUpToV8()
        let source = makeSource()
        let a1 = makeAsset(sourceId: source.id)   // #sf, oak, #(garbage), c#
        let a2 = makeAsset(sourceId: source.id)   // #oak (→ merges into oak), agent #sf

        let hashedSF = Tag(id: UUID(), name: "#sf", source: .user)
        let canonOak = Tag(id: UUID(), name: "oak", source: .user)
        let hashedOak = Tag(id: UUID(), name: "#oak", source: .user)   // twin of canonOak
        let garbage = Tag(id: UUID(), name: "#", source: .user)
        let nonLeading = Tag(id: UUID(), name: "c#", source: .user)    // '#' not leading
        let agentSF = Tag(id: UUID(), name: "#sf", source: .agent)     // distinct source

        try queue.write { db in
            try source.insert(db)
            try a1.insert(db); try a2.insert(db)
            for t in [hashedSF, canonOak, hashedOak, garbage, nonLeading, agentSF] {
                try t.insert(db)
            }
            try AssetTag(assetID: a1.id, tagID: hashedSF.id).insert(db)
            try AssetTag(assetID: a1.id, tagID: canonOak.id).insert(db)
            try AssetTag(assetID: a2.id, tagID: hashedOak.id).insert(db)   // merges → oak
            try AssetTag(assetID: a1.id, tagID: garbage.id).insert(db)
            try AssetTag(assetID: a2.id, tagID: agentSF.id).insert(db)
        }

        // Apply v9.
        try Migrator.makeMigrator().migrate(queue)

        try queue.read { db in
            // No stored name begins with '#'.
            let hashCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name LIKE '#%'")
            #expect(hashCount == 0)

            // #sf → sf (user), still linked to a1.
            let sfID = try String.fetchOne(db, sql:
                "SELECT id FROM tag WHERE name = 'sf' AND source = 'user'")
            #expect(sfID == hashedSF.id.uuidString.lowercased())
            let sfLinked = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM asset_tag WHERE tag_id = ? AND asset_id = ?",
                arguments: [sfID, a1.id.uuidString.lowercased()])
            #expect(sfLinked == 1)

            // #oak merged INTO oak: exactly one user 'oak' tag (the canonical one),
            // #oak deleted, and a2 now carries the canonical oak.
            let oakRows = try String.fetchAll(db, sql:
                "SELECT id FROM tag WHERE name = 'oak' AND source = 'user'")
            #expect(oakRows == [canonOak.id.uuidString.lowercased()])
            let a2Oak = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM asset_tag WHERE tag_id = ? AND asset_id = ?",
                arguments: [canonOak.id.uuidString.lowercased(), a2.id.uuidString.lowercased()])
            #expect(a2Oak == 1)
            let hashedOakGone = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tag WHERE id = ?",
                arguments: [hashedOak.id.uuidString.lowercased()])
            #expect(hashedOakGone == 0)

            // Garbage '#' tag deleted.
            let garbageGone = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tag WHERE id = ?",
                arguments: [garbage.id.uuidString.lowercased()])
            #expect(garbageGone == 0)

            // Non-leading '#' preserved verbatim.
            let cHash = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tag WHERE name = 'c#'")
            #expect(cHash == 1)

            // Agent #sf → agent sf, distinct from the user 'sf' row.
            let agentSfID = try String.fetchOne(db, sql:
                "SELECT id FROM tag WHERE name = 'sf' AND source = 'agent'")
            #expect(agentSfID == agentSF.id.uuidString.lowercased())
            #expect(agentSfID != sfID)
        }
    }

    @Test("v9 is idempotent — a second run is a no-op")
    func idempotent() throws {
        let queue = try makeQueueUpToV8()
        let source = makeSource()
        let a1 = makeAsset(sourceId: source.id)
        let hashed = Tag(id: UUID(), name: "#sf", source: .user)
        try queue.write { db in
            try source.insert(db)
            try a1.insert(db)
            try hashed.insert(db)
            try AssetTag(assetID: a1.id, tagID: hashed.id).insert(db)
        }
        try Migrator.makeMigrator().migrate(queue)
        // Re-running the normalization SQL over already-clean data changes nothing.
        try queue.write { db in try Migrator.normalizeV9TagNames(db) }
        try queue.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM tag ORDER BY name")
            #expect(names == ["sf"])
        }
    }
}
