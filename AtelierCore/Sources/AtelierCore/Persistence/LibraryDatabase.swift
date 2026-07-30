// AtelierCore — the persistence store (chunk 4, decisions A3/P14)
//
// An `internal` (A2) wrapper around a GRDB `DatabasePool`: it opens/creates the
// database file, runs the migrations, and exposes read/write access plus the
// single P14 joined read. The public App Services write funnel (chunk 5) is the
// only thing that builds on top of this — the store itself stays internal.

import Foundation
import GRDB

/// A migrated, WAL-backed SQLite store.
///
/// Built on `DatabasePool` (A3): concurrent reads + one serialized writer, for
/// the browse-while-importing workload. A pool puts the database in WAL mode
/// automatically, and GRDB enables `PRAGMA foreign_keys` on every connection by
/// default — so provenance and the cascade policy are enforced through the
/// store, not just in tests.
///
/// `final class … Sendable` (A3): the only stored property is the `Sendable`
/// pool and there is no in-memory mutable state yet (promote to `actor` only
/// when a cache lands).
final class LibraryDatabase: Sendable {
    /// The underlying connection pool. `internal` so the chunk-5 funnel can
    /// route its single `write {}` through it.
    let pool: DatabasePool

    /// Opens (or creates) the database at `path` and migrates it to the latest
    /// schema. WAL is implied by `DatabasePool`; `foreign_keys` is on by default.
    ///
    /// Before migrating, takes a **pre-migration snapshot** (008 H3) when the
    /// on-disk schema is behind: the existing file is copied aside *before the
    /// pool opens* (safe — no writer yet), and that copy is kept as a snapshot
    /// only if a migration is actually pending. A recovery point in case a schema
    /// migration corrupts data; all backup failures are swallowed so a hiccup can
    /// never block opening the library.
    init(path: String) throws {
        let migrator = Migrator.makeMigrator()
        let hadExistingFile = FileManager.default.fileExists(atPath: path)
        // Stage a copy of the existing file BEFORE any connection opens.
        let staged = Self.stagePreMigrationCopy(path: path)
        pool = try DatabasePool(path: path)
        // A read-write pool read avoids the readonly-WAL open hazard. Default to
        // "complete" (discard the staged copy) if the check itself fails.
        let complete = (try? pool.read { try migrator.hasCompletedMigrations($0) }) ?? true
        let promoted = Self.finalizePreMigrationSnapshot(staged: staged, keep: !complete)
        if !complete, hadExistingFile, !promoted {
            // The migration below proceeds WITHOUT its safety copy. Never block
            // the open over it — but never let it pass silently either: the app
            // consumes this marker at bootstrap and tells the user.
            Self.recordPreMigrationSnapshotFailure(path: path)
        }
        try migrator.migrate(pool)
    }

    /// Drop the `.pre-migration-snapshot-failed` marker beside the snapshots so
    /// the app can surface "your library migrated without a safety copy" on the
    /// next bootstrap. Best-effort — a disk that can't take a snapshot may not
    /// take a marker either.
    private static func recordPreMigrationSnapshotFailure(path: String) {
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent(".pre-migration-snapshot-failed")
        try? ISO8601DateFormatter().string(from: Date())
            .write(to: marker, atomically: true, encoding: .utf8)
    }

    // MARK: - Pre-migration snapshot (008 H3)

    /// Copy the existing DB (+ `-wal`/`-shm` sidecars) to a staging file next to
    /// it, before any connection opens. Returns the staging base URL, or `nil`
    /// when there's nothing to copy (fresh library) or the copy fails.
    ///
    /// Performance invariant: this runs on EVERY launch (the pending-migration
    /// check needs an open pool, which must come after the copy), but on APFS
    /// `copyItem` is a copy-on-write clone — metadata-cheap at any DB size — so
    /// stage-then-discard is deliberately unguarded by a schema pre-check. Keep
    /// anything with real cost (checkpointing, integrity checks) in
    /// `finalizePreMigrationSnapshot`, which only runs when a migration is
    /// actually pending; this hot path must stay clone + delete.
    private static func stagePreMigrationCopy(path: String) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }
        let fileURL = URL(fileURLWithPath: path)
        let dir = fileURL.deletingLastPathComponent()
            .appendingPathComponent("snapshots", isDirectory: true)
        let staging = dir.appendingPathComponent(
            ".staging-\(UUID().uuidString.prefix(8).lowercased()).sqlite")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // All-or-nothing: a copy missing its WAL is a snapshot missing
            // committed transactions — fail the whole staging instead.
            try SQLiteFileSet(base: fileURL).copy(to: SQLiteFileSet(base: staging))
            return staging
        } catch {
            SQLiteFileSet(base: staging).remove() // no partial staging litter
            return nil
        }
    }

    /// Promote the staged copy to a `pre-migration-…` snapshot (`keep`), or delete
    /// it (migration wasn't needed / no staging). Best-effort.
    ///
    /// Promotion first NORMALIZES the staged copy — checkpoints its WAL so the
    /// snapshot is one self-contained `.sqlite` file, like every `VACUUM INTO`
    /// snapshot. Without this, a copy taken after an unclean exit carries a live
    /// `-wal`/stale `-shm`, and a sidecar-carrying snapshot is fragile: read-only
    /// opens may need WAL recovery they cannot perform, and every downstream
    /// consumer (size, delete, prune, restore) has to know about sidecars. If
    /// normalization fails (the copy can't even open), the snapshot is promoted
    /// as-is with its sidecars — a degraded recovery point beats none.
    /// Returns whether the snapshot obligation was met: `true` when the staged
    /// copy was promoted, or when no promotion was wanted (`keep == false`);
    /// `false` when a wanted snapshot could not be produced (no staging, or the
    /// promote itself failed) — the caller surfaces that.
    @discardableResult
    private static func finalizePreMigrationSnapshot(staged: URL?, keep: Bool) -> Bool {
        guard let staged else { return !keep }
        let stagedSet = SQLiteFileSet(base: staged)
        guard keep else {
            stagedSet.remove()
            return true
        }
        normalize(staged: staged)
        let dest = SnapshotFile.makeURL(
            in: staged.deletingLastPathComponent(), reason: .preMigration, date: Date())
        do {
            try stagedSet.move(to: SQLiteFileSet(base: dest))
            return true
        } catch {
            // Couldn't promote — don't leave staging litter behind.
            stagedSet.remove()
            return false
        }
    }

    /// Fold the staged copy's WAL into its main file AND leave the file in
    /// rollback-journal mode, so the promoted snapshot is one self-contained
    /// `.sqlite` — the same shape as `VACUUM INTO` output. Both halves matter:
    /// macOS SQLite runs persistent-WAL (sidecars survive a clean close), and a
    /// read-only open of a WAL-mode file REQUIRES its sidecars (`SQLITE_CANTOPEN`
    /// without them — verified against macOS 26's SQLite), so merely checkpointing
    /// and deleting the sidecars would produce a snapshot that health checks
    /// cannot open. `journal_mode=DELETE` checkpoints, removes the `-wal`, and
    /// rewrites the header; the leftover `-shm` is removed explicitly. Restore
    /// installing this file is fine — `DatabasePool` flips it back to WAL.
    /// Best-effort — see the caller for the promote-as-staged fallback.
    private static func normalize(staged: URL) {
        do {
            let queue = try DatabaseQueue(path: staged.path)
            try queue.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                try db.execute(sql: "PRAGMA journal_mode=DELETE")
            }
            try queue.close()
            for s in SQLiteFileSet.sidecarSuffixes {
                try? FileManager.default.removeItem(atPath: staged.path + s)
            }
        } catch {
            // Leave the copy (and its sidecars) exactly as staged.
        }
    }

    // MARK: - Access

    /// Run a read in a concurrent snapshot. Thin wrapper over `pool.read`.
    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    /// Run a write in the serialized writer transaction. Thin wrapper over
    /// `pool.write`; the chunk-5 funnel layers invariants on top.
    func write<T>(_ block: (Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    // MARK: - P14: the single joined read

    /// Every membership of `collectionID`, each carrying its full ``Asset`` and
    /// that asset's ``Source``, loaded in ONE round-trip via GRDB associations
    /// (P14 — no N+1). Ordered deterministically by `manual_order` (NULLs first,
    /// SQLite ascending) then `id`, so grid order is stable.
    func collectionItemDetails(in collectionID: UUID) throws -> [CollectionItemRow] {
        try read { db in
            // CollectionItem ⋈ Asset ⋈ Source, all required (inner joins): every
            // item has an asset (FK NOT NULL) and every asset has a source (C6).
            // `including(required:)` nests the asset scope, and the source scope
            // under it; `CollectionItemRow` flattens both via the scope tree.
            let request = CollectionItem
                .filter(Column("collection_id") == collectionID.uuidString.lowercased())
                .including(required: CollectionItem.asset
                    .including(required: Asset.source))
                .order(Column("manual_order"), Column("id"))
            return try CollectionItemRow.fetchAll(db, request)
        }
    }
}

/// One row of the P14 joined read: a membership plus its decoded asset + source.
///
/// INTERNAL (A2) — a GRDB `FetchableRecord`. The public read API maps this to
/// the GRDB-free ``CollectionItemDetail`` value type so no toolkit type leaks.
///
/// GRDB resolves `asset` and `source` through the request's scope tree (the
/// `source` scope is nested under `asset`, but the breadth-first scope lookup
/// finds it), and decodes `item` from the base `collection_item` columns.
struct CollectionItemRow: FetchableRecord, Decodable, Equatable {
    var item: CollectionItem
    var asset: Asset
    var source: Source
}

/// One row of the asset read/search join: an asset plus its required source,
/// loaded via `Asset.including(required: Asset.source)` in one round-trip.
///
/// INTERNAL (A2) — a GRDB `FetchableRecord`. `asset` has no matching row scope
/// so GRDB decodes it from the base `asset` columns; `source` matches the
/// included scope. The read API maps this to the GRDB-free ``AssetDetail``.
struct AssetSourceRow: FetchableRecord, Decodable, Equatable {
    var asset: Asset
    var source: Source
}

/// One row of the space-board read (005): a ``SpaceItem`` plus its OPTIONAL
/// asset + source. Asset rows join their `asset` (and that asset's required
/// `source`); element rows (NULL `asset_id`) decode both as `nil` via the LEFT
/// join. `internal` (A2). The read API maps this to the GRDB-free
/// ``SpaceItemDetail``.
struct SpaceItemRow: FetchableRecord, Decodable, Equatable {
    var item: SpaceItem
    var asset: Asset?
    var source: Source?
}
