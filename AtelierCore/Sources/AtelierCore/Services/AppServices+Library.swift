// AtelierCore — AppServices: the library as a whole (the P0 file split).
//
// Everything whose subject is the LIBRARY rather than anything in it: the
// checkpointed snapshot the backup lane writes, the integrity checks restore
// refuses on, and the storage / count roll-ups Settings shows. Moved verbatim
// out of `AppServices.swift` — same code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

    // MARK: - Backup / snapshot (008 H1)

    /// Write a self-consistent, checkpointed copy of the live database to `url`
    /// via `VACUUM INTO` — one statement producing a single portable `.sqlite`
    /// with no `-wal` sidecar. `VACUUM` cannot run inside a transaction, so this
    /// takes the funnel's ``writeWithoutTransaction(_:)`` door rather than
    /// `write {}`. SQLite refuses to overwrite, so `url` must not already exist.
    public func snapshot(to url: URL) async throws {
        try await writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    /// The newest schema migration this build knows about — what any
    /// library it has opened is migrated to.
    ///
    /// Public so backup and archive manifests (008 · H5/H6) can record the
    /// schema their copy was written from, which is what lets a reader refuse a
    /// file from a FUTURE build instead of misreading it. A build-time constant
    /// rather than a query, because `LibraryDatabase.init` migrates to the
    /// latest on open: an `AppServices` that exists is an `AppServices` whose
    /// database is at this version.
    public static var schemaVersion: String {
        Migrator.registeredIdentifiers.last ?? ""
    }

    /// `PRAGMA integrity_check` on the live database: `true` when SQLite reports
    /// the single `ok` row (healthy), `false` otherwise.
    public func integrityCheck() async throws -> Bool {
        try await read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
        }
    }

    /// Integrity-check a database FILE (a snapshot / backup) without touching the
    /// live pool — opens it read-only, runs `PRAGMA integrity_check`, closes it.
    /// Restore uses this to refuse an unhealthy snapshot before installing it;
    /// GRDB stays confined to Core (A2).
    public static func isHealthy(databaseFileAt url: URL) throws -> Bool {
        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        return try queue.read { db in
            try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"]
        }
    }

    // MARK: - Library stats (016 · A)
    //
    // Three READS, and deliberately nothing else. The storage surface is a pure
    // read layer over data that already exists — these aggregate in SQL (a
    // `GROUP BY`, never a fetch-all-then-count in Swift) so a hundred-thousand
    // item library answers "how many videos?" without loading a hundred thousand
    // rows. On-disk SIZES are not here and never will be: Core cannot touch
    // files (A2), so the size half arrives from `LibraryStorageScanner` and is
    // joined against ``blobUsage()`` a layer up.

    /// How many assets of each ``AssetKind`` the library holds.
    ///
    /// A kind with no assets is ABSENT from the map rather than present as `0`
    /// — callers default, and the UI decides whether an empty kind is worth a
    /// row. A stored rawValue this build doesn't know (a library written by a
    /// newer version) is skipped rather than crashing the whole count: a missing
    /// row is a small lie, a failed stats pane is a big one.
    public func assetCountsByKind() async throws -> [AssetKind: Int] {
        try await read { db in
            var counts: [AssetKind: Int] = [:]
            for row in try Row.fetchAll(
                db, sql: "SELECT kind, count(*) AS n FROM asset GROUP BY kind") {
                guard let kind = AssetKind(rawValue: row["kind"]) else { continue }
                counts[kind] = row["n"]
            }
            return counts
        }
    }

    /// How many assets came from each ``Platform``, via each asset's required
    /// ``Source``. Same absent-means-zero and skip-the-unknown contract as
    /// ``assetCountsByKind()``.
    ///
    /// Counted per ASSET, not per source: one Instagram carousel is one source
    /// and ten images, and "10 from Instagram" is what the user has.
    public func assetCountsByPlatform() async throws -> [Platform: Int] {
        try await read { db in
            var counts: [Platform: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT s.platform AS platform, count(*) AS n
                FROM asset a JOIN source s ON s.id = a.source_id
                GROUP BY s.platform
                """) {
                guard let platform = Platform(rawValue: row["platform"]) else { continue }
                counts[platform] = row["n"]
            }
            return counts
        }
    }

    /// Every distinct blob with the assets that reference it — the DB half of the
    /// largest-items list (the byte sizes come from the filesystem scan).
    ///
    /// One row per hash, like ``referencedBlobs()``, and for the same reason: the
    /// list ranks FILES. `MIN` picks the kind / platform / label deterministically
    /// so two runs over an unchanged library produce byte-identical ordering —
    /// content-identical assets normally agree on all three, but nothing enforces
    /// it, and a top-N list that reshuffles on refresh reads as a bug.
    ///
    /// `group_concat` gathers the asset ids in one pass rather than a query per
    /// row (N+1 over the whole library, to build a list of ten). SQLite does not
    /// define the order WITHIN a group, so the ids are sorted here.
    public func blobUsage() async throws -> [BlobUsage] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.blob_hash AS blob_hash,
                       COALESCE(MIN(a.mime_type), '') AS mime_type,
                       MIN(a.kind) AS kind,
                       MIN(s.platform) AS platform,
                       MIN(COALESCE(a.name, s.title)) AS display_name,
                       group_concat(a.id) AS asset_ids
                FROM asset a JOIN source s ON s.id = a.source_id
                WHERE a.blob_hash IS NOT NULL
                GROUP BY a.blob_hash
                ORDER BY a.blob_hash
                """).compactMap { row -> BlobUsage? in
                    // An unknown kind/platform rawValue drops the ROW, not the
                    // pane — the same forward-compatibility stance as the counts.
                    guard let kind = AssetKind(rawValue: row["kind"]),
                          let platform = Platform(rawValue: row["platform"]) else { return nil }
                    let ids: [UUID] = (row["asset_ids"] as String? ?? "")
                        .split(separator: ",")
                        .compactMap { UUID(uuidString: String($0)) }
                        .sorted { $0.uuidString < $1.uuidString }
                    let name: String? = row["display_name"]
                    return BlobUsage(
                        blobHash: row["blob_hash"], mimeType: row["mime_type"],
                        kind: kind, platform: platform,
                        displayName: name?.isEmpty == true ? nil : name,
                        assetIDs: ids)
                }
        }
    }

    /// Forget every `job_item` whose blob is among `orphanedHashes` and recompute the
    /// `ingested_count` of each job that loses rows — keeping the denormalized count
    /// drift-free, the same in-transaction invariant `recordJobItem` maintains. Shared
    /// by `deleteAssets` (reactive, on orphaning) and `reconcileOrphanedKnownItems`
    /// (proactive GC). Returns the distinct job keys touched. Must run inside a write.
    @discardableResult
    static func forgetOrphanedKnownItems(
        _ orphanedHashes: [String], in db: Database
    ) throws -> Set<String> {
        var forgottenJobKeys: Set<String> = []
        for hash in orphanedHashes {
            let touched = try String.fetchAll(
                db, sql: "SELECT DISTINCT job_id FROM job_item WHERE blob_hash = ?",
                arguments: [hash])
            if !touched.isEmpty {
                try db.execute(
                    sql: "DELETE FROM job_item WHERE blob_hash = ?", arguments: [hash])
                forgottenJobKeys.formUnion(touched)
            }
        }
        for jobKey in forgottenJobKeys {
            let landed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job_item WHERE job_id = ? AND status IN (?, ?)
                """, arguments: [
                    jobKey,
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ]) ?? 0
            try db.execute(
                sql: "UPDATE job SET ingested_count = ? WHERE id = ?",
                arguments: [landed, jobKey])
        }
        return forgottenJobKeys
    }
}
