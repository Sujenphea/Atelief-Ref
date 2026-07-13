// AtelierCore — the public App Services mutation surface (chunk 5, A2/A4/C6)
//
// The ONE public type of the package (A2). Every mutation in the app routes
// through this class's single private `write {}` funnel (A4): validation (C8)
// and invariants (C6) run inside or before each transaction, never bypassed,
// and GRDB errors are mapped to `AtelierError` on the way out (C7) so the
// toolkit never leaks. Reads / search are a separate chunk; this is writes only.

import Foundation
import GRDB

/// The public, `Sendable` write surface over the internal ``LibraryDatabase``.
///
/// `final class … Sendable` (A3): the only stored property is the `Sendable`
/// store; no in-memory mutable state. All mutations are `async` and serialized
/// by the underlying `DatabasePool` writer (WAL).
public final class AppServices: Sendable {
    /// The internal store. Never exposed — only the funnel touches its pool.
    private let database: LibraryDatabase

    /// Open (or create) a library at `databasePath`, migrated to the latest
    /// schema.
    public init(databasePath: String) throws {
        self.database = try LibraryDatabase(path: databasePath)
    }

    /// Compose over an existing store (tests / future wiring). `internal` (A2).
    init(database: LibraryDatabase) {
        self.database = database
    }

    // MARK: - The single write funnel (A4)

    /// EVERY mutation routes through here. Runs `op` in the pool's serialized
    /// writer transaction and maps any thrown error to an ``AtelierError`` (C7)
    /// so GRDB types never cross the public boundary (A2). Validation /
    /// `.notFound` thrown inside `op` pass through unchanged.
    private func write<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.write(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    /// The read counterpart of the funnel. Runs `op` in a concurrent snapshot
    /// of the pool (A3) and maps any thrown error to an ``AtelierError`` (C7) so
    /// GRDB never crosses the public boundary (A2). `.notFound` thrown inside
    /// `op` passes through unchanged. Reads do NOT serialize behind the writer —
    /// browse-while-importing (A3).
    private func read<T: Sendable>(
        _ op: @Sendable @escaping (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.pool.read(op)
        } catch {
            throw AtelierError(mapping: error)
        }
    }

    // MARK: - Backup / snapshot (008 H1)

    /// Write a self-consistent, checkpointed copy of the live database to `url`
    /// via `VACUUM INTO` — one statement producing a single portable `.sqlite`
    /// with no `-wal` sidecar. `VACUUM` cannot run inside a transaction, so this
    /// takes the pool's non-transactional writer rather than the `write {}`
    /// funnel. SQLite refuses to overwrite, so `url` must not already exist.
    public func snapshot(to url: URL) async throws {
        do {
            try await database.pool.writeWithoutTransaction { db in
                try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
            }
        } catch {
            throw AtelierError(mapping: error)
        }
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

    // MARK: - Collections

    /// Create a collection (a folder — folders ARE collections, decision F1).
    /// Validates + trims the name (C8); the service generates `id` and
    /// `createdAt`/`updatedAt` (server-authoritative). When `parent` is given it
    /// must exist (`.notFound`) — the new collection nests under it; `nil` ⇒ a
    /// root folder (the existing no-parent behaviour).
    @discardableResult
    public func createCollection(
        name: String, description: String? = nil, parent parentID: UUID? = nil
    ) async throws -> Collection {
        let trimmed = try Validation.collectionName(name)
        let now = Date()
        let collection = Collection(
            id: UUID(), name: trimmed, description: description,
            coverAssetID: nil, createdAt: now, updatedAt: now,
            parentCollectionID: parentID)
        return try await write { db in
            if let parentID {
                guard try Collection.exists(db, key: Self.key(parentID)) else {
                    throw AtelierError.notFound(entity: "collection", id: parentID)
                }
            }
            try collection.insert(db)
            return collection
        }
    }

    /// Rename a collection. Rejects the protected Unsorted folder
    /// (`.protectedCollection`, F3); `.notFound` if absent; bumps `updatedAt`.
    @discardableResult
    public func renameCollection(id: UUID, to name: String) async throws -> Collection {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        let trimmed = try Validation.collectionName(name)
        return try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            collection.name = trimmed
            collection.updatedAt = Date()
            try collection.update(db)
            return collection
        }
    }

    /// Set a collection's cover. Both the collection and the asset must exist
    /// (`.notFound`); bumps `updatedAt`.
    public func setCollectionCover(collectionID: UUID, assetID: UUID) async throws {
        try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            collection.coverAssetID = assetID
            collection.updatedAt = Date()
            try collection.update(db)
        }
    }

    /// Delete a collection (folder). Rejects the protected Unsorted folder
    /// (`.protectedCollection`, F3); `.notFound` if absent. The whole subtree —
    /// descendant folders (parent FK) and every membership (schema 17A) —
    /// CASCADEs at the DB level (F4); descendants are NOT hand-deleted here.
    public func deleteCollection(id: UUID) async throws {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        try await write { db in
            guard try Collection.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
        }
    }

    /// Reparent a folder (decision F6). Rejects the protected Unsorted folder
    /// (`.protectedCollection`, F3); the folder must exist (`.notFound`). When
    /// `newParentID` is non-nil it must exist (`.notFound`) and must NOT be `id`
    /// nor a descendant of `id` — else `.folderCycle`. `nil` ⇒ the folder
    /// becomes a root. Bumps `updatedAt`.
    public func moveCollection(id: UUID, toParent newParentID: UUID?) async throws {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        try await write { db in
            guard var collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            if let newParentID {
                guard try Collection.exists(db, key: Self.key(newParentID)) else {
                    throw AtelierError.notFound(entity: "collection", id: newParentID)
                }
                // Cycle prevention (F6): walk UP the ancestor chain from the
                // proposed parent via parent_collection_id. If the walk reaches
                // `id`, then `id` is an ancestor of newParentID — i.e.
                // newParentID is `id` itself or one of its descendants — so the
                // move would form a cycle. A self-move (newParentID == id) is
                // caught on the very first step.
                var cursor: UUID? = newParentID
                while let current = cursor {
                    if current == id {
                        throw AtelierError.folderCycle
                    }
                    cursor = try Collection
                        .filter(Column("id") == Self.key(current))
                        .select(Column("parent_collection_id"), as: UUID?.self)
                        .fetchOne(db) ?? nil
                }
            }
            collection.parentCollectionID = newParentID
            collection.updatedAt = Date()
            try collection.update(db)
        }
    }

    /// The DIRECT children of a folder (decision F5/P13), ordered by `name` then
    /// `id` (stable). `nil` ⇒ the root folders (`parent_collection_id IS NULL`,
    /// including the protected Unsorted folder). Read.
    public func childCollections(of parentID: UUID?) async throws -> [Collection] {
        try await read { db in
            let filter: QueryInterfaceRequest<Collection>
            if let parentID {
                filter = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
            } else {
                filter = Collection.filter(Column("parent_collection_id") == nil)
            }
            return try filter.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// The fixed id of the protected default-import "Unsorted" folder (F3), so
    /// the app has a default target without reaching into the domain constant.
    public var unsortedFolderID: UUID { Collection.unsortedID }

    // MARK: - Ingest (C6 provenance + 18A dedup)

    /// Ingest an asset with its REQUIRED provenance into a collection, in ONE
    /// transaction (C6 — `source` is non-optional, so "asset with no origin"
    /// cannot compile). Implements the 18A dedup rule and is idempotent on
    /// re-ingest of identical bytes + provenance into the same collection.
    ///
    /// Steps inside the funnel:
    /// 1. validate dimensions / fileSize / blobHash / per-platform originalURL
    ///    (+ placement if supplied);
    /// 2. assert the target collection exists (`.notFound`);
    /// 3. **18A dedup** — reuse an existing asset (and its source) sharing the
    ///    blob hash whose source matches the incoming provenance;
    /// 4. ensure exactly ONE membership of the resolved asset in the collection.
    @discardableResult
    public func ingest(
        _ asset: AssetDraft,
        from source: SourceDraft,
        into collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) async throws -> IngestResult {
        // 1. validate (fail fast, before opening the write).
        try Validation.dimensions(width: asset.width, height: asset.height)
        try Validation.fileSize(asset.fileSize)
        let blobHash = try Validation.blobHash(asset.blobHash)
        try Validation.originalURL(source.originalURL, platform: source.platform)
        if let placement {
            try Validation.canvasPlacement(
                x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }

        return try await write { db in
            // 2. the collection must exist.
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }

            // 3. 18A dedup — reuse an existing asset+source on match.
            let resolvedAsset: Asset
            let wasDeduplicated: Bool
            if let existing = try Self.findDuplicate(db, blobHash: blobHash, source: source) {
                resolvedAsset = existing
                wasDeduplicated = true
            } else {
                let newSource = Source(
                    id: UUID(), platform: source.platform,
                    originalURL: source.originalURL, authorHandle: source.authorHandle,
                    authorName: source.authorName, title: source.title,
                    capturedAt: source.capturedAt, rawMetadata: source.rawMetadata)
                try newSource.insert(db)
                let newAsset = Asset(
                    id: UUID(), kind: asset.kind, blobHash: blobHash,
                    mimeType: asset.mimeType, width: asset.width, height: asset.height,
                    duration: asset.duration, fileSize: asset.fileSize,
                    downloadState: asset.downloadState, createdAt: Date(),
                    sourceId: newSource.id)
                try newAsset.insert(db)
                resolvedAsset = newAsset
                wasDeduplicated = false
            }

            // 4. ensure ONE membership (ingest is idempotent on membership; a
            //    second placement of the same asset is a deliberate caller act
            //    via addAssets, not a side effect of re-ingest).
            let alreadyMember = try Self.membership(
                db, collectionID: collectionID, assetID: resolvedAsset.id) != nil
            if !alreadyMember {
                let item = CollectionItem(
                    id: UUID(), collectionID: collectionID, assetID: resolvedAsset.id,
                    addedAt: Date(), manualOrder: nil,
                    canvasX: placement?.x, canvasY: placement?.y,
                    canvasW: placement?.w, canvasH: placement?.h, canvasZ: placement?.z)
                try item.insert(db)
            }

            return IngestResult(asset: resolvedAsset, wasDeduplicated: wasDeduplicated)
        }
    }

    // MARK: - Arrange / bulk (P15 — each ONE transaction)

    /// Set (or clear) the canvas placement of an asset's membership. Validates
    /// finite/positive (C8); `.notFound` if the asset is not a member.
    public func setCanvasPlacement(
        collectionID: UUID, assetID: UUID,
        x: Double?, y: Double?, w: Double?, h: Double?, z: Int?
    ) async throws {
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        try await write { db in
            guard var item = try Self.membership(
                db, collectionID: collectionID, assetID: assetID) else {
                throw AtelierError.notFound(entity: "collection_item", id: assetID)
            }
            item.canvasX = x
            item.canvasY = y
            item.canvasW = w
            item.canvasH = h
            item.canvasZ = z
            try item.update(db)
        }
    }

    /// Assign `manualOrder` 0,1,2,… to the listed memberships, IN ONE
    /// transaction (P15). `.notFound` (rolling back the whole batch) if a listed
    /// asset is not a member.
    public func setGridOrder(collectionID: UUID, orderedAssetIDs: [UUID]) async throws {
        try await write { db in
            for (index, assetID) in orderedAssetIDs.enumerated() {
                guard var item = try Self.membership(
                    db, collectionID: collectionID, assetID: assetID) else {
                    throw AtelierError.notFound(entity: "collection_item", id: assetID)
                }
                item.manualOrder = index
                try item.update(db)
            }
        }
    }

    /// Bulk-add memberships, IN ONE transaction (P15). Idempotent per asset
    /// (skips ones already members). `.notFound` (rolling back) for a missing
    /// collection or asset.
    public func addAssets(_ assetIDs: [UUID], to collectionID: UUID) async throws {
        try await write { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            let now = Date()
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                let isMember = try Self.membership(
                    db, collectionID: collectionID, assetID: assetID) != nil
                if !isMember {
                    let item = CollectionItem(
                        id: UUID(), collectionID: collectionID,
                        assetID: assetID, addedAt: now)
                    try item.insert(db)
                }
            }
        }
    }

    /// Bulk-remove memberships, IN ONE transaction (P15). Idempotent — removing
    /// a non-member is a no-op.
    public func removeAssets(_ assetIDs: [UUID], from collectionID: UUID) async throws {
        try await write { db in
            for assetID in assetIDs {
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(collectionID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
        }
    }

    /// Delete assets ENTIRELY from the library (not just one folder membership),
    /// IN ONE transaction. Idempotent — an unknown / already-deleted id is
    /// skipped, not an error (so concurrent or repeated deletes are safe).
    ///
    /// For each existing target the `asset` row is removed, which CASCADEs its
    /// memberships (17A) and tag links, and clears any folder cover
    /// (`cover_asset_id` → NULL) at the DB level. Then two GC passes run in the
    /// same transaction:
    /// - **Sources** — a `source` is kept by `asset.source_id`'s `ON DELETE
    ///   RESTRICT`, so we delete each touched source whose last asset is now
    ///   gone (an orphaned source would otherwise linger and defeat 18A dedup).
    /// - **Blobs** — a blob hash is reported reclaimable ONLY when no remaining
    ///   asset shares it (dedup-safe: content-identical assets keep the file).
    ///
    /// Returns the reclaimable blobs as ``OrphanedBlob`` so the caller (which
    /// owns the `MediaStore`) can trash the on-disk blob + thumbnail files; Core
    /// itself never touches the filesystem. Tag rows survive (only the
    /// `asset_tag` join cascades), matching ``removeTag(_:from:source:)``.
    @discardableResult
    public func deleteAssets(_ assetIDs: [UUID]) async throws -> [OrphanedBlob] {
        try await write { db in
            // Resolve the targets that actually exist and remove them. Track a
            // representative mime per distinct hash (for extension round-trip)
            // and the set of sources touched, both in stable first-seen order.
            var mimeByHash: [String: String] = [:]
            var orderedHashes: [String] = []
            var orderedSourceKeys: [String] = []
            var seenSourceKeys: Set<String> = []
            for assetID in assetIDs {
                guard let asset = try Asset.fetchOne(db, key: Self.key(assetID)) else {
                    continue // idempotent: unknown / already-deleted id.
                }
                if mimeByHash[asset.blobHash] == nil {
                    mimeByHash[asset.blobHash] = asset.mimeType
                    orderedHashes.append(asset.blobHash)
                }
                let sourceKey = Self.key(asset.sourceId)
                if seenSourceKeys.insert(sourceKey).inserted {
                    orderedSourceKeys.append(sourceKey)
                }
                try asset.delete(db)
            }

            // GC sources whose last asset is gone (RESTRICT keeps them otherwise).
            for sourceKey in orderedSourceKeys {
                let stillReferenced = try Asset
                    .filter(Column("source_id") == sourceKey)
                    .fetchCount(db) > 0
                if !stillReferenced {
                    try Source.deleteOne(db, key: sourceKey)
                }
            }

            // A blob is reclaimable only when no remaining asset shares its hash.
            var orphans: [OrphanedBlob] = []
            for hash in orderedHashes {
                let stillReferenced = try Asset
                    .filter(Column("blob_hash") == hash)
                    .fetchCount(db) > 0
                if !stillReferenced {
                    orphans.append(OrphanedBlob(blobHash: hash, mimeType: mimeByHash[hash]!))
                }
            }
            // "Delete is forgotten": the orphaned bytes are leaving the store, so drop
            // the bulk-import ledger rows that marked this content known — a future
            // sweep then re-ingests it. Keyed on blob ORPHANING (not per-asset): while
            // any asset still shares the blob, the content is present and legitimately
            // known.
            try Self.forgetOrphanedKnownItems(orphans.map(\.blobHash), in: db)
            return orphans
        }
    }

    /// Forget every `job_item` whose blob is among `orphanedHashes` and recompute the
    /// `ingested_count` of each job that loses rows — keeping the denormalized count
    /// drift-free, the same in-transaction invariant `recordJobItem` maintains. Shared
    /// by `deleteAssets` (reactive, on orphaning) and `reconcileOrphanedKnownItems`
    /// (proactive GC). Returns the distinct job keys touched. Must run inside a write.
    @discardableResult
    private static func forgetOrphanedKnownItems(
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

    // MARK: - Reads (P16 — collection-scoped reads return full arrays)

    /// Every collection, ordered by `name` then `id` (stable). The library's
    /// collection count is small and bounded, so this returns the full
    /// inventory (P16 — only the unbounded library-wide reads are paged).
    public func listCollections() async throws -> [Collection] {
        try await read { db in
            try Collection.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// One collection by id; `.notFound` if absent.
    public func getCollection(id: UUID) async throws -> Collection {
        try await read { db in
            guard let collection = try Collection.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
            return collection
        }
    }

    /// The P14 joined read for a collection — every membership with its full
    /// asset + source, in the store's order (`manual_order` then `id`), mapped
    /// to the public GRDB-free ``CollectionItemDetail`` (A2). Collection-scoped,
    /// so the FULL array is returned (P16 — the views need every item).
    /// `.notFound` if the collection is absent.
    public func collectionItems(in collectionID: UUID) async throws -> [CollectionItemDetail] {
        try await read { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            // CollectionItem ⋈ Asset ⋈ Source, all required (P14): one round-trip,
            // no N+1. GRDB qualifies the base columns to `collection_item`.
            let request = CollectionItem
                .filter(Column("collection_id") == Self.key(collectionID))
                .including(required: CollectionItem.asset
                    .including(required: Asset.source))
                .order(Column("manual_order"), Column("id"))
            return try CollectionItemRow.fetchAll(db, request).map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    /// One asset with its required provenance; `.notFound` if absent. Metadata
    /// only (P16) — never the blob bytes.
    public func getAsset(id: UUID) async throws -> AssetDetail {
        try await read { db in
            let request = Asset
                .filter(Column("id") == Self.key(id))
                .including(required: Asset.source)
            guard let row = try AssetSourceRow.fetchOne(db, request) else {
                throw AtelierError.notFound(entity: "asset", id: id)
            }
            return AssetDetail(asset: row.asset, source: row.source)
        }
    }

    /// A batch cover lookup for the collections gallery (004-P2): each requested
    /// collection id that HAS a cover asset maps to that asset's `blob_hash` (so
    /// the UI can resolve the on-disk thumbnail). Collections with no cover — or
    /// a cover asset that was deleted (`SET NULL`) — are simply absent from the
    /// result. One joined round-trip; ids not present in the store are skipped.
    public func collectionCovers(_ ids: [UUID]) async throws -> [UUID: String] {
        let keys = ids.map(Self.key)
        guard !keys.isEmpty else { return [:] }
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT collection.id AS cid, asset.blob_hash AS hash
                FROM collection
                JOIN asset ON asset.id = collection.cover_asset_id
                WHERE collection.id IN (\(databaseQuestionMarks(count: keys.count)))
                """, arguments: StatementArguments(keys))
            var covers: [UUID: String] = [:]
            for row in rows {
                guard let cid = UUID(uuidString: row["cid"]) else { continue }
                covers[cid] = row["hash"]
            }
            return covers
        }
    }

    // MARK: - Spaces (005 · decision O1)

    /// Create a freeform space (005). Validates + trims the name (C8); the
    /// service generates `id` and `createdAt`/`updatedAt` (server-authoritative).
    @discardableResult
    public func createSpace(name: String) async throws -> Space {
        let trimmed = try Validation.spaceName(name)
        let now = Date()
        let space = Space(id: UUID(), name: trimmed, createdAt: now, updatedAt: now)
        return try await write { db in
            try space.insert(db)
            return space
        }
    }

    /// Rename a space. `.notFound` if absent; bumps `updatedAt`. (Spaces have no
    /// protected member, unlike the Unsorted folder.)
    @discardableResult
    public func renameSpace(id: UUID, to name: String) async throws -> Space {
        let trimmed = try Validation.spaceName(name)
        return try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            space.name = trimmed
            space.updatedAt = Date()
            try space.update(db)
            return space
        }
    }

    /// Set a space's cover (005 Q2). Both the space and the asset must exist
    /// (`.notFound`); bumps `updatedAt`.
    public func setSpaceCover(spaceID: UUID, assetID: UUID) async throws {
        try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            space.coverAssetID = assetID
            space.updatedAt = Date()
            try space.update(db)
        }
    }

    /// Delete a space; `.notFound` if absent. Its rows CASCADE at the DB level
    /// (schema O1) — asset rows and element rows alike; the underlying assets
    /// survive (only the placements go).
    public func deleteSpace(id: UUID) async throws {
        try await write { db in
            guard try Space.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
        }
    }

    /// Every space, newest first (`created_at DESC`, then `id`). The space count
    /// is small and bounded, so this returns the full inventory (P16).
    public func listSpaces() async throws -> [Space] {
        try await read { db in
            try Space.order(Column("created_at").desc, Column("id")).fetchAll(db)
        }
    }

    /// A batch cover lookup for the Spaces list (005 Q2), symmetric to
    /// ``collectionCovers(_:)``: each requested space id that HAS a (surviving)
    /// cover asset maps to that asset's `blob_hash`. Spaces with no cover are
    /// absent from the result.
    public func spaceCovers(_ ids: [UUID]) async throws -> [UUID: String] {
        let keys = ids.map(Self.key)
        guard !keys.isEmpty else { return [:] }
        return try await read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT space.id AS sid, asset.blob_hash AS hash
                FROM space
                JOIN asset ON asset.id = space.cover_asset_id
                WHERE space.id IN (\(databaseQuestionMarks(count: keys.count)))
                """, arguments: StatementArguments(keys))
            var covers: [UUID: String] = [:]
            for row in rows {
                guard let sid = UUID(uuidString: row["sid"]) else { continue }
                covers[sid] = row["hash"]
            }
            return covers
        }
    }

    /// One space by id; `.notFound` if absent.
    public func getSpace(id: UUID) async throws -> Space {
        try await read { db in
            guard let space = try Space.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            return space
        }
    }

    /// Place an asset on a space (005). Validates the placement finite/positive
    /// (C8) and the discriminator (an asset row requires the id); the space and
    /// asset must exist (`.notFound`). Returns the created ``SpaceItem``. The same
    /// asset MAY be added twice (each row has its own id) — a deliberate caller
    /// act, mirroring `addAssets`.
    @discardableResult
    public func addAssetToSpace(
        assetID: UUID, to spaceID: UUID,
        x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws -> SpaceItem {
        try Validation.spaceItem(kind: .asset, assetID: assetID)
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        let now = Date()
        let item = SpaceItem(
            id: UUID(), spaceID: spaceID, kind: .asset, assetID: assetID,
            x: x, y: y, w: w, h: h, z: z, style: nil, createdAt: now, updatedAt: now)
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            try item.insert(db)
            return item
        }
    }

    /// Add a freeform element (frame / text) to a space (005 O1; wired by E3).
    /// Validates the placement (C8) and the discriminator (an element row must
    /// NOT carry an asset id); the space must exist (`.notFound`). `style` is the
    /// element's ``ElementStyle`` and is stored as JSON TEXT.
    @discardableResult
    public func addElement(
        to spaceID: UUID, kind: SpaceItemKind, style: ElementStyle?,
        x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws -> SpaceItem {
        try Validation.spaceItem(kind: kind, assetID: nil)
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        let now = Date()
        let item = SpaceItem(
            id: UUID(), spaceID: spaceID, kind: kind, assetID: nil,
            x: x, y: y, w: w, h: h, z: z, style: style?.jsonString(),
            createdAt: now, updatedAt: now)
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            try item.insert(db)
            return item
        }
    }

    /// Move / resize a space item, keeping its kind + style. Validates the
    /// placement (C8); `.notFound` if the row is absent. Bumps `updatedAt`.
    public func setSpaceItemPlacement(
        itemID: UUID, x: Double, y: Double, w: Double, h: Double, z: Int
    ) async throws {
        try Validation.canvasPlacement(x: x, y: y, w: w, h: h)
        try await write { db in
            guard var item = try SpaceItem.fetchOne(db, key: Self.key(itemID)) else {
                throw AtelierError.notFound(entity: "space_item", id: itemID)
            }
            item.x = x; item.y = y; item.w = w; item.h = h; item.z = z
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Restyle a freeform element (005; wired by E3). `.notFound` if absent;
    /// bumps `updatedAt`. Stores the ``ElementStyle`` as JSON TEXT (nil clears it).
    public func updateSpaceItemStyle(itemID: UUID, style: ElementStyle?) async throws {
        try await write { db in
            guard var item = try SpaceItem.fetchOne(db, key: Self.key(itemID)) else {
                throw AtelierError.notFound(entity: "space_item", id: itemID)
            }
            item.style = style?.jsonString()
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Remove one row from a space (a placement, not the asset). Idempotent — an
    /// unknown / already-removed id is a no-op, not an error.
    public func removeSpaceItem(itemID: UUID) async throws {
        try await write { db in
            _ = try SpaceItem.deleteOne(db, key: Self.key(itemID))
        }
    }

    /// Re-insert a full ``SpaceItem`` row **verbatim** — the inverse of
    /// ``removeSpaceItem(itemID:)`` and the primitive undo/redo uses to restore a
    /// deleted row or re-create an undone one with its **id preserved** (so the
    /// undo chain stays stable). Validates the discriminator (C8) + placement; the
    /// space (and, for an asset row, the asset) must exist (`.notFound`). A no-op
    /// on an id that already exists (idempotent redo).
    public func restoreSpaceItem(_ item: SpaceItem) async throws {
        try Validation.spaceItem(kind: item.kind, assetID: item.assetID)
        try Validation.canvasPlacement(x: item.x, y: item.y, w: item.w, h: item.h)
        try await write { db in
            guard try Space.exists(db, key: Self.key(item.spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: item.spaceID)
            }
            if let assetID = item.assetID {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
            }
            guard try !SpaceItem.exists(db, key: Self.key(item.id)) else { return }
            try item.insert(db)
        }
    }

    /// The space's board: every row with its media (asset rows carry the full
    /// ``Asset`` + ``Source``; element rows carry neither), ordered by `z` then
    /// `id` so draw order is stable. Space-scoped, so the FULL array is returned
    /// (P16). `.notFound` if the space is absent.
    public func spaceItems(in spaceID: UUID) async throws -> [SpaceItemDetail] {
        try await read { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            // SpaceItem ⟕ Asset ⟕ Source: BOTH joins are OPTIONAL (LEFT) —
            // element rows have a NULL asset_id. The nested source must also be
            // optional: GRDB forbids chaining a required association behind an
            // optional one. An asset row's source is NOT NULL by schema (C6), so
            // it is still populated for every asset row. One round-trip, no N+1.
            let request = SpaceItem
                .filter(Column("space_id") == Self.key(spaceID))
                .including(optional: SpaceItem.asset
                    .including(optional: Asset.source))
                .order(Column("z"), Column("id"))
            return try SpaceItemRow.fetchAll(db, request).map {
                SpaceItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    // MARK: - Search (P16 bounded + FTS5)

    /// Search assets library-wide, bounded (P16) and keyset-paged.
    ///
    /// - `text`: when non-nil/non-empty, full-text matched against `source_fts`
    ///   (the source `title` / `author_handle` / `author_name`); the matching
    ///   sources' assets are returned. When nil/blank, lists all assets
    ///   (optionally platform-filtered) — still bounded.
    /// - `platform`: optional filter on the asset's source.
    /// - Ordered `created_at DESC, id DESC` (stable), so the keyset cursor is
    ///   well-defined.
    /// - `limit` is clamped to `1...500`; at most `limit` rows are returned.
    /// - `after`: a keyset cursor (P16) — only rows STRICTLY after it in the
    ///   order are returned (`(created_at, id) < (cursor.createdAt, cursor.id)`),
    ///   so paging never drifts or repeats as new assets land (no OFFSET).
    ///
    /// Returns ``AssetDetail`` (asset + source) — metadata only, never blob
    /// bytes (P16).
    public func searchAssets(
        text: String? = nil,
        platform: Platform? = nil,
        limit: Int = 50,
        after cursor: AssetPageCursor? = nil
    ) async throws -> [AssetDetail] {
        let clampedLimit = min(max(limit, 1), 500)
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await read { db in
            // The source is required and carries the platform filter when given,
            // so the included join doubles as the filter (inner join).
            var sourceAssociation = Asset.source
            if let platform {
                sourceAssociation = sourceAssociation.filter(
                    Column("platform") == platform.rawValue)
            }
            var request = Asset.including(required: sourceAssociation)

            // FTS5: restrict to assets whose source MATCHes the sanitized query.
            // The subquery maps `source_fts.rowid` → `source.rowid` → `source.id`
            // (external-content FTS), keeping the base asset query unqualified.
            if let trimmedText, !trimmedText.isEmpty {
                request = request.filter(sql: """
                    source_id IN (
                        SELECT source.id FROM source
                        JOIN source_fts ON source_fts.rowid = source.rowid
                        WHERE source_fts MATCH ?
                    )
                    """, arguments: [Self.ftsMatchQuery(trimmedText)])
            }

            // Keyset seek: rows strictly after the cursor in the DESC order.
            // GRDB qualifies these `Column`s to the base `asset` table; the Date
            // binds to the same sortable text encoding the column stores (C5).
            if let cursor {
                request = request.filter(
                    Column("created_at") < cursor.createdAt
                    || (Column("created_at") == cursor.createdAt
                        && Column("id") < Self.key(cursor.id)))
            }

            request = request
                .order(Column("created_at").desc, Column("id").desc)
                .limit(clampedLimit)

            return try AssetSourceRow.fetchAll(db, request).map {
                AssetDetail(asset: $0.asset, source: $0.source)
            }
        }
    }

    // MARK: - Tags (schema-reserved; the agent interface needs these)

    /// Apply a tag to an asset. Validates + trims the name (C8); finds-or-creates
    /// the `(name, source)` tag, then links it idempotently (no duplicate join
    /// row). `.notFound` if the asset is absent. Through the write funnel.
    @discardableResult
    public func applyTag(_ name: String, to assetID: UUID, source: TagSource) async throws -> Tag {
        let trimmed = try Validation.tagName(name)
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            // Find-or-create by (name, source): user vs agent tags are distinct.
            let tag: Tag
            if let existing = try Tag
                .filter(Column("name") == trimmed)
                .filter(Column("source") == source.rawValue)
                .fetchOne(db) {
                tag = existing
            } else {
                let created = Tag(id: UUID(), name: trimmed, source: source)
                try created.insert(db)
                tag = created
            }
            // Idempotent link — skip if the join row already exists.
            let linked = try AssetTag
                .filter(Column("asset_id") == Self.key(assetID))
                .filter(Column("tag_id") == Self.key(tag.id))
                .fetchCount(db) > 0
            if !linked {
                try AssetTag(assetID: assetID, tagID: tag.id).insert(db)
            }
            return tag
        }
    }

    /// Remove a tag from an asset. Idempotent — a no-op if the tag or the link
    /// is absent (the tag row itself is left intact for other assets). Through
    /// the write funnel.
    public func removeTag(_ name: String, from assetID: UUID, source: TagSource) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try await write { db in
            guard let tag = try Tag
                .filter(Column("name") == trimmed)
                .filter(Column("source") == source.rawValue)
                .fetchOne(db) else { return }
            try AssetTag
                .filter(Column("asset_id") == Self.key(assetID))
                .filter(Column("tag_id") == Self.key(tag.id))
                .deleteAll(db)
        }
    }

    /// An asset's tags, ordered by `name` then `id` (stable). Read.
    public func tags(for assetID: UUID) async throws -> [Tag] {
        try await read { db in
            try Tag
                .filter(sql: "id IN (SELECT tag_id FROM asset_tag WHERE asset_id = ?)",
                        arguments: [Self.key(assetID)])
                .order(Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: - Bulk-import jobs (015 · decision 3A ledger)

    /// Open a new bulk-import sweep. The service owns `id` / `createdAt` /
    /// `updatedAt` and starts the sweep `open` with a zero `ingestedCount`. The
    /// extension tags each subsequent item POST with the returned id.
    @discardableResult
    public func createJob(
        platform: Platform, scope: String? = nil, totalEstimate: Int? = nil
    ) async throws -> Job {
        let now = Date()
        let job = Job(
            id: UUID(), platform: platform, scope: scope, status: .open,
            totalEstimate: totalEstimate, ingestedCount: 0,
            createdAt: now, updatedAt: now)
        return try await write { db in
            try job.insert(db)
            return job
        }
    }

    /// Record (or re-record) one enumerated item's outcome, in ONE transaction
    /// (P15). Upsert on the `(job_id, source_id)` PK makes a retried record
    /// idempotent — the resumable-sweep invariant. In the SAME transaction the
    /// job's `ingested_count` is RECOMPUTED from the `job_item` rows (not
    /// incremented), so a crash between items leaves the counter exactly
    /// consistent with the committed items — no drift, ever (7A/11A). `.notFound`
    /// if the job is absent.
    @discardableResult
    public func recordJobItem(
        jobID: UUID, sourceID: String, sourceURL: String? = nil,
        status: JobItemStatus, blobHash: String? = nil
    ) async throws -> JobItem {
        let now = Date()
        let item = JobItem(
            jobID: jobID, sourceID: sourceID, sourceURL: sourceURL,
            status: status, blobHash: blobHash, updatedAt: now)
        return try await write { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            // Upsert by composite PK (explicit over clever — matches the codebase's
            // fetch-then-insert/update idiom rather than relying on save() semantics).
            let exists = try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .filter(Column("source_id") == sourceID)
                .fetchCount(db) > 0
            if exists { try item.update(db) } else { try item.insert(db) }

            // Recompute the denormalized progress counter from the source of truth
            // in the same transaction (no drift on crash / re-record).
            let landed = try Int.fetchOne(db, sql: """
                SELECT count(*) FROM job_item WHERE job_id = ? AND status IN (?, ?)
                """, arguments: [
                    Self.key(jobID),
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ]) ?? 0
            try db.execute(
                sql: "UPDATE job SET ingested_count = ?, updated_at = ? WHERE id = ?",
                arguments: [landed, now, Self.key(jobID)])
            return item
        }
    }

    /// The set of platform source ids already ingested for this job's platform,
    /// across ALL jobs (P14 download-skip). A source is "known" (its bytes are in
    /// the store, so the extension must NOT re-download it) only when some
    /// `job_item` for the SAME platform reached `ingested` or `deduped` — a
    /// `retryableFailed`/`permanentFailed`/`skipped` item is not itself proof the
    /// bytes exist. Scoped by platform so a tweet id can never mask a pin id.
    /// `.notFound` if the job is absent. Content-addressing remains the
    /// authoritative dedup backstop; this only avoids the costly re-download.
    public func knownSourceIDs(forJob jobID: UUID) async throws -> Set<String> {
        try await read { db in
            guard let platform = try String.fetchOne(
                db, sql: "SELECT platform FROM job WHERE id = ?",
                arguments: [Self.key(jobID)]) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try String.fetchSet(db, sql: """
                SELECT DISTINCT job_item.source_id
                FROM job_item
                JOIN job ON job.id = job_item.job_id
                WHERE job.platform = ? AND job_item.status IN (?, ?)
                """, arguments: [
                    platform,
                    JobItemStatus.ingested.rawValue, JobItemStatus.deduped.rawValue,
                ])
        }
    }

    /// Transition a job's lifecycle (7A) — e.g. `.complete` at the cursor
    /// terminator, `.paused` on a user pause, `.halted` on a fatal auth /
    /// rate-limit wall. Bumps `updatedAt`. `.notFound` if the job is absent.
    public func setJobStatus(jobID: UUID, to status: JobStatus) async throws {
        try await write { db in
            guard var job = try Job.fetchOne(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            job.status = status
            job.updatedAt = Date()
            try job.update(db)
        }
    }

    /// Pause every `open` sweep whose last activity (`updatedAt`) is older than
    /// `seconds` before `now`. A browser sweep whose tab/worker dies can no longer
    /// send its own close, so its job would otherwise linger forever as a phantom
    /// "running" entry; this reconciles it to `paused` (resumable). `seconds == 0`
    /// pauses ALL open jobs — used at launch, when no sweep can possibly be running.
    /// Staleness check and pause run in one write transaction (G9). `now` is
    /// injected for deterministic tests.
    @discardableResult
    public func pauseStaleOpenJobs(olderThan seconds: TimeInterval, now: Date) async throws -> [UUID] {
        let cutoff = now.addingTimeInterval(-seconds)
        // Single write transaction: filter + mutate together so a job touched in
        // the gap between a prior read and write is not wrongly paused (G9).
        return try await write { db in
            let stale = try Job
                .filter(Column("status") == JobStatus.open.rawValue)
                .filter(Column("updated_at") <= cutoff)
                .fetchAll(db)
            guard !stale.isEmpty else { return [] }
            var paused: [UUID] = []
            for var job in stale {
                job.status = .paused
                job.updatedAt = now
                try job.update(db)
                paused.append(job.id)
            }
            return paused
        }
    }

    /// Proactive GC of the `known ⟺ blob present` invariant. `deleteAssets` forgets a
    /// blob's ledger rows the instant it orphans, but an asset removed by any OTHER
    /// path (a delete predating the forget feature, a future non-`deleteAssets` caller)
    /// strands its `job_item` as stale-"known" — and a later sweep would then
    /// dedup-skip that source forever despite the bytes being gone, so it never
    /// re-imports. This sweeps every `job_item` whose blob has no backing asset,
    /// forgets it, and recomputes the affected jobs' counts. Check + delete run in
    /// ONE write transaction so a concurrent ingest can't be wrongly pruned (G9).
    /// Returns the job ids reconciled.
    @discardableResult
    public func reconcileOrphanedKnownItems() async throws -> [UUID] {
        try await write { db in
            let orphanedHashes = try String.fetchAll(db, sql: """
                SELECT DISTINCT blob_hash FROM job_item
                 WHERE blob_hash IS NOT NULL
                   AND NOT EXISTS (
                     SELECT 1 FROM asset WHERE asset.blob_hash = job_item.blob_hash)
                """)
            guard !orphanedHashes.isEmpty else { return [] }
            let touched = try Self.forgetOrphanedKnownItems(orphanedHashes, in: db)
            return touched.compactMap { UUID(uuidString: $0) }
        }
    }

    /// One job by id (progress UI). `.notFound` if absent. Read.
    public func getJob(id: UUID) async throws -> Job {
        try await read { db in
            guard let job = try Job.fetchOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "job", id: id)
            }
            return job
        }
    }

    /// A job's items, ordered by `source_id` (stable). `.notFound` if the job is
    /// absent. Read — for progress detail (skipped/failed/dedup breakdown).
    public func jobItems(forJob jobID: UUID) async throws -> [JobItem] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return try JobItem
                .filter(Column("job_id") == Self.key(jobID))
                .order(Column("source_id"))
                .fetchAll(db)
        }
    }

    /// All jobs, newest first (the progress UI's list). Read.
    public func listJobs() async throws -> [Job] {
        try await read { db in
            try Job.order(Column("created_at").desc, Column("id")).fetchAll(db)
        }
    }

    /// A job's per-outcome item tally (the progress breakdown: ingested / deduped /
    /// skipped / retryable / permanent). Aggregated in SQL (a `GROUP BY`, not by
    /// loading every row) so a large sweep's progress reads stay cheap. A status
    /// with no items is absent from the map (callers default to 0). `.notFound` if
    /// the job is absent. Read.
    public func jobItemCounts(forJob jobID: UUID) async throws -> [JobItemStatus: Int] {
        try await read { db in
            guard try Job.exists(db, key: Self.key(jobID)) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, count(*) AS n FROM job_item WHERE job_id = ? GROUP BY status
                """, arguments: [Self.key(jobID)])
            var counts: [JobItemStatus: Int] = [:]
            for row in rows {
                if let status = JobItemStatus(rawValue: row["status"]) {
                    counts[status] = row["n"]
                }
            }
            return counts
        }
    }

    /// A job's current lifecycle status (the relay feedback the extension polls per
    /// item to honour an app-side pause/cancel — 7A). `.notFound` if absent. Read.
    public func jobStatus(forJob jobID: UUID) async throws -> JobStatus {
        try await read { db in
            guard let raw = try String.fetchOne(
                db, sql: "SELECT status FROM job WHERE id = ?", arguments: [Self.key(jobID)]),
                let status = JobStatus(rawValue: raw) else {
                throw AtelierError.notFound(entity: "job", id: jobID)
            }
            return status
        }
    }

    // MARK: - Private query helpers

    /// Sanitize arbitrary user text into a safe FTS5 MATCH query. Each
    /// whitespace-separated term is wrapped as a quoted FTS5 string (doubling
    /// any embedded `"` per FTS5's escaping rule) and the quoted terms are joined
    /// with spaces (implicit AND). So `brass wood` → `"brass" "wood"` (both must
    /// match) and punctuation / stray quotes can never form malformed MATCH
    /// syntax (no syntax-error throw). Quoting also neutralizes the FTS5
    /// operators (`*`, `:`, `^`, `-`, `(`, `OR`, …) as literal text.
    static func ftsMatchQuery(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { term in "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    /// The on-disk key form of a UUID (lowercased TEXT, C5) — what GRDB's
    /// key-based fetch and the column filters must bind to.
    private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The (collection, asset) membership row, if any.
    private static func membership(
        _ db: Database, collectionID: UUID, assetID: UUID
    ) throws -> CollectionItem? {
        try CollectionItem
            .filter(Column("collection_id") == key(collectionID))
            .filter(Column("asset_id") == key(assetID))
            .fetchOne(db)
    }

    /// 18A dedup lookup: an existing asset sharing `blobHash` whose source
    /// matches the incoming provenance — same `original_url` when one is given,
    /// else same `platform` (the local-capture case where no URL exists). The
    /// shared blob hash means the bytes are identical; the source match means
    /// the provenance is identical, so reuse is safe.
    private static func findDuplicate(
        _ db: Database, blobHash: String, source: SourceDraft
    ) throws -> Asset? {
        // Candidate sources whose provenance matches the incoming draft.
        let matchingSources: QueryInterfaceRequest<Source>
        if let url = source.originalURL,
           !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matchingSources = Source.filter(Column("original_url") == url)
        } else {
            matchingSources = Source.filter(Column("platform") == source.platform.rawValue)
        }
        let sourceIDs = try String.fetchAll(
            db, matchingSources.select(Column("id")))
        guard !sourceIDs.isEmpty else { return nil }

        // The first asset sharing the blob hash AND one of those sources.
        return try Asset
            .filter(Column("blob_hash") == blobHash)
            .filter(sourceIDs.contains(Column("source_id")))
            .fetchOne(db)
    }
}
