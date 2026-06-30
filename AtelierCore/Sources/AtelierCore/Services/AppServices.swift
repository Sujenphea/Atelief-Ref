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

    // MARK: - Collections

    /// Create a collection. Validates + trims the name (C8); the service
    /// generates `id` and `createdAt`/`updatedAt` (server-authoritative).
    @discardableResult
    public func createCollection(
        name: String, description: String? = nil
    ) async throws -> Collection {
        let trimmed = try Validation.collectionName(name)
        let now = Date()
        let collection = Collection(
            id: UUID(), name: trimmed, description: description,
            coverAssetID: nil, createdAt: now, updatedAt: now)
        return try await write { db in
            try collection.insert(db)
            return collection
        }
    }

    /// Rename a collection. `.notFound` if absent; bumps `updatedAt`.
    @discardableResult
    public func renameCollection(id: UUID, to name: String) async throws -> Collection {
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

    /// Delete a collection. `.notFound` if absent. Its memberships CASCADE
    /// (schema 17A).
    public func deleteCollection(id: UUID) async throws {
        try await write { db in
            guard try Collection.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "collection", id: id)
            }
        }
    }

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

    // MARK: - Private query helpers

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
