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
    init(path: String) throws {
        pool = try DatabasePool(path: path)
        try Migrator.makeMigrator().migrate(pool)
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
