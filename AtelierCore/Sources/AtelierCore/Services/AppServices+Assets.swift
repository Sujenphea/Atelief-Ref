// AtelierCore — AppServices: assets (the P0 file split).
//
// An asset's whole life outside of where it is filed: ingest (provenance + the
// 18A dedup), the two-tier delete and its undo, the per-item fields the detail
// page edits, the star, the archive shelf, tags, and the suggestion loop. Moved
// verbatim out of `AppServices.swift` — same code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

    // MARK: - Ingest (C6 provenance + 18A dedup)

    // **`asset.created_at` is the source's `capturedAt`, not the insert's `Date()`**
    // (092 · S3 review, 18A/17A). Both insert sites below seed it that way, and the
    // reason is that `created_at` is what the library ORDERS BY — a collection's
    // "Newest", search results, the paging cursor — so it is a display fact about
    // when the user took the thing, not an audit fact about when a row was written.
    // Those two were the same moment for every producer the app had until the iOS
    // inbox: paste, drag, the clipboard watcher and the capture endpoint all pass
    // `capturedAt: Date()` at the moment they hand bytes over, so nothing about
    // their behaviour changes. The two producers that are NOT happening now do
    // change, and both wanted to:
    //   • a share drained out of `inbox/` may have been sitting there since before
    //     the last reboot, and it should land where the user's afternoon put it,
    //     not at the top of the grid because the Mac was opened on Friday;
    //   • an archive import (068) carries the ORIGINAL capture times in its
    //     manifest, so a restored library now reads in the order the library it
    //     was made from read in, instead of collapsing to the minute of the import.
    // Deliberately NOT retroactive: rows already in a library keep the `created_at`
    // they were stamped with, because rewriting history to fix an ordering would be
    // a worse trade than one seam between old rows and new.

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
                // `created_at` is the source's `capturedAt`, NOT `Date()` — see the
                // note under `MARK: - Ingest` above.
                let newAsset = Asset(
                    id: UUID(), kind: asset.kind, blobHash: blobHash,
                    mimeType: asset.mimeType, width: asset.width, height: asset.height,
                    duration: asset.duration, fileSize: asset.fileSize,
                    downloadState: asset.downloadState, createdAt: source.capturedAt,
                    sourceId: newSource.id)
                try newAsset.insert(db)
                resolvedAsset = newAsset
                wasDeduplicated = false
            }

            // 4. ensure ONE membership (ingest is idempotent on membership; a
            //    second placement of the same asset is a deliberate caller act
            //    via addAssets, not a side effect of re-ingest), honoring the
            //    Unsorted invariant on the 18A dedup path — a re-capture of bytes
            //    already in the library must not land the asset in two homes.
            try Self.placeIngested(
                db, assetID: resolvedAsset.id, in: collectionID, placement: placement)

            return IngestResult(asset: resolvedAsset, wasDeduplicated: wasDeduplicated)
        }
    }

    /// Ingest a MEDIA-LESS asset (003 · O1) — a `color` / `link` / `tweet` — with
    /// its REQUIRED provenance into a collection, in ONE transaction (C6). The
    /// sibling of ``ingest(_:from:into:placement:)`` for the content path: the
    /// asset's substance is its ``AssetPayload`` and it is born `.downloaded`.
    /// Kind-aware dedup reuses an existing asset+source sharing the same
    /// `(kind, dedup_key)` and provenance.
    ///
    /// `blob` (003 · C3, Option 3) is the OPTIONAL card image: when present the
    /// otherwise media-less asset ALSO stores a real blob (its `blob_hash` / mime
    /// / dims / size), so a tweet renders its picture rather than a text card. The
    /// bytes never affect identity — dedup stays keyed on `(kind, dedup_key)` — so
    /// two captures with different card images resolve to one tweet (first capture
    /// wins; a later card image does NOT overwrite an existing asset's blob).
    ///
    /// Steps inside the funnel:
    /// 1. normalize + validate the draft (per-kind payload, canonical dedup key),
    ///    the optional blob facts (dims / size / hash), and the per-platform
    ///    `originalURL` (+ placement if supplied);
    /// 2. assert the target collection exists (`.notFound`);
    /// 3. **kind-aware dedup** — reuse an asset with the same `(kind, dedup_key)`
    ///    whose source matches the incoming provenance;
    /// 4. ensure exactly ONE membership of the resolved asset in the collection.
    @discardableResult
    public func ingestContent(
        _ draft: AssetContentDraft,
        blob: ContentBlobFacts? = nil,
        from source: SourceDraft,
        into collectionID: UUID,
        placement: CanvasPlacement? = nil
    ) async throws -> IngestResult {
        // 1. validate + normalize (fail fast, before opening the write).
        let normalized = try Validation.contentDraft(draft)
        // Validate the optional card-image blob facts (Option 3). Held as a plain
        // tuple so the @Sendable write closure can capture it; the hash is
        // canonicalized (lowercased-hex) exactly like the byte path.
        let normalizedBlob: (hash: String, mimeType: String, width: Int, height: Int, fileSize: Int)?
        if let blob {
            try Validation.dimensions(width: blob.width, height: blob.height)
            try Validation.fileSize(blob.fileSize)
            normalizedBlob = (
                try Validation.blobHash(blob.blobHash), blob.mimeType,
                blob.width, blob.height, blob.fileSize)
        } else {
            normalizedBlob = nil
        }
        // Align the source's `original_url` with the kind's canonical identity so
        // two captures of the same thing dedup even when written differently: a
        // link's `original_url` becomes its canonical URL (003 · C2); a tweet's
        // becomes the deterministic permalink for its id, so `x.com` /
        // `twitter.com` / tracking-param variants share one source (003 · C3).
        // A `let` so the @Sendable write closure can capture it.
        let effectiveSource: SourceDraft = {
            guard let canonical = normalized.dedupKey else { return source }
            var s = source
            switch normalized.kind {
            case .link:
                s.originalURL = canonical
            case .tweet:
                s.originalURL = TweetPayload.canonicalTweetURL(id: canonical)
            default:
                return source
            }
            return s
        }()
        try Validation.originalURL(effectiveSource.originalURL, platform: effectiveSource.platform)
        if let placement {
            try Validation.canvasPlacement(
                x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }

        return try await write { db in
            // 2. the collection must exist.
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }

            // 3. kind-aware dedup — reuse an existing content asset+source on match.
            let resolvedAsset: Asset
            let wasDeduplicated: Bool
            if let existing = try Self.findDuplicateContent(
                db, kind: normalized.kind, dedupKey: normalized.dedupKey, source: effectiveSource) {
                resolvedAsset = existing
                wasDeduplicated = true
            } else {
                let newSource = Source(
                    id: UUID(), platform: effectiveSource.platform,
                    originalURL: effectiveSource.originalURL, authorHandle: effectiveSource.authorHandle,
                    authorName: effectiveSource.authorName, title: effectiveSource.title,
                    capturedAt: effectiveSource.capturedAt, rawMetadata: effectiveSource.rawMetadata)
                try newSource.insert(db)
                // Content in `payload`; born `.downloaded` (its substance is fully
                // present). Byte columns are nil UNLESS a card image was supplied
                // (Option 3) — then the asset also carries a real blob.
                // `created_at` is the source's `capturedAt`, NOT `Date()` — see the
                // note under `MARK: - Ingest` above. `effectiveSource` and `source`
                // agree on `capturedAt` (only `originalURL` is canonicalized), but
                // it is read from the draft the row was BUILT from either way.
                let newAsset = Asset(
                    id: UUID(), kind: normalized.kind,
                    blobHash: normalizedBlob?.hash, mimeType: normalizedBlob?.mimeType,
                    width: normalizedBlob?.width, height: normalizedBlob?.height,
                    duration: nil, fileSize: normalizedBlob?.fileSize,
                    downloadState: .downloaded,
                    createdAt: effectiveSource.capturedAt, sourceId: newSource.id,
                    payload: normalized.payload.jsonString(),
                    dedupKey: normalized.dedupKey, searchText: normalized.searchText)
                try newAsset.insert(db)
                resolvedAsset = newAsset
                wasDeduplicated = false
            }

            // 4. ensure ONE membership (idempotent on membership — matches ingest,
            //    Unsorted invariant included).
            try Self.placeIngested(
                db, assetID: resolvedAsset.id, in: collectionID, placement: placement)

            return IngestResult(asset: resolvedAsset, wasDeduplicated: wasDeduplicated)
        }
    }

    // MARK: - Delete-undo (010)

    /// Delete assets AND capture a verbatim backup for undo, in ONE transaction
    /// (010 · delete-undo). The backup is the exact graph removed — assets, their
    /// sources, memberships (with order), tag links, and the covers the delete
    /// `SET NULL`-ed — captured with set-based `IN (…)` reads (no N+1) BEFORE the
    /// shared cascade runs, so it can't drift from what was deleted.
    ///
    /// Blobs are NOT reaped here (unlike the model's old delete path): reaping is
    /// deferred to the launch orphan-GC, so ``restoreDeletedAssets(_:)`` finds the
    /// bytes still on disk. A delete that is never undone is reclaimed next launch.
    public func deleteAssetsRecoverable(_ assetIDs: [UUID]) async throws -> DeletedAssetsBackup {
        let backup = try await write { db in
            let backup = try Self.captureBackup(assetIDs, in: db)
            _ = try Self.performDelete(assetIDs, in: db)
            return backup
        }
        // The delete half of 099 · P0b's two-writer invalidation. The RESTORE half
        // deliberately does not invalidate: `DeletedAssetsBackup` carries no
        // embedding rows (they are derived, and `captureBackup` never reads them),
        // so ⌘Z brings the asset back UN-embedded and the backfill re-embeds it
        // through `upsertEmbedding`, which invalidates on its own.
        corpusCache.invalidate()
        return backup
    }

    /// Snapshot the full graph the delete will remove (set-based reads).
    private static func captureBackup(_ assetIDs: [UUID], in db: Database) throws -> DeletedAssetsBackup {
        let keys = assetIDs.map(Self.key)
        guard !keys.isEmpty else { return DeletedAssetsBackup() }

        let assets = try Asset.filter(keys.contains(Column("id"))).fetchAll(db)
        guard !assets.isEmpty else { return DeletedAssetsBackup() }

        let sourceKeys = Array(Set(assets.map { Self.key($0.sourceId) }))
        let sources = try Source.filter(sourceKeys.contains(Column("id"))).fetchAll(db)
        let memberships = try CollectionItem.filter(keys.contains(Column("asset_id"))).fetchAll(db)
        let tagLinks = try AssetTag.filter(keys.contains(Column("asset_id"))).fetchAll(db)

        let coverRows = try Row.fetchAll(db, sql: """
            SELECT id AS cid, cover_asset_id AS aid FROM collection
            WHERE cover_asset_id IN (\(databaseQuestionMarks(count: keys.count)))
            """, arguments: StatementArguments(keys))
        let covers = coverRows.compactMap { row -> DeletedAssetsBackup.CoverRef? in
            guard let cid = UUID(uuidString: row["cid"]),
                  let aid = UUID(uuidString: row["aid"]) else { return nil }
            return DeletedAssetsBackup.CoverRef(collectionID: cid, assetID: aid)
        }
        return DeletedAssetsBackup(
            assets: assets, sources: sources, memberships: memberships,
            tagLinks: tagLinks, covers: covers)
    }

    /// Reinstate a ``DeletedAssetsBackup`` verbatim — the inverse of
    /// ``deleteAssetsRecoverable(_:)``. ONE transaction, best-effort per row (010 ·
    /// 4A): idempotent (skip-if-exists), dedup-aware (an asset whose dedup key a
    /// live capture recreated is skipped, not duplicated), and resilient (a
    /// membership whose collection was since deleted is skipped; a cover is
    /// restored only if the collection is still cover-less). Ids / timestamps /
    /// manual order are preserved. Blobs are untouched (never reaped), so restored
    /// byte-backed assets keep their media.
    public func restoreDeletedAssets(_ backup: DeletedAssetsBackup) async throws {
        guard !backup.isEmpty else { return }
        try await write { db in
            // 1. Sources — insert if absent (a shared source may still exist).
            for source in backup.sources where try !Source.exists(db, key: Self.key(source.id)) {
                try source.insert(db)
            }
            // 2. Assets — skip an id that already exists (idempotent) or a dedup key
            //    a live capture recreated (4A). Track which assets are now present
            //    so dependent rows only attach to real assets.
            var presentAssetKeys: Set<String> = []
            for asset in backup.assets {
                let assetKey = Self.key(asset.id)
                if try Asset.exists(db, key: assetKey) {
                    presentAssetKeys.insert(assetKey)
                    continue
                }
                if let dedup = asset.dedupKey,
                   try Asset.filter(Column("dedup_key") == dedup).fetchCount(db) > 0 {
                    continue // content re-created under a new id since the delete.
                }
                // The FK source must exist (inserted above, unless shared+present).
                guard try Source.exists(db, key: Self.key(asset.sourceId)) else { continue }
                try asset.insert(db)
                presentAssetKeys.insert(assetKey)
            }
            // 3. Memberships — the asset must be present, the collection must still
            //    exist, and no membership for (collection, asset) may already exist.
            for item in backup.memberships {
                guard presentAssetKeys.contains(Self.key(item.assetID)) else { continue }
                guard try Collection.exists(db, key: Self.key(item.collectionID)) else { continue }
                guard try Self.membership(
                    db, collectionID: item.collectionID, assetID: item.assetID) == nil else { continue }
                try item.insert(db)
            }
            // 4. Tag links — the asset must be present, the tag must still exist
            //    (tags survive a delete), and the link must be absent.
            for link in backup.tagLinks {
                guard presentAssetKeys.contains(Self.key(link.assetID)) else { continue }
                guard try Tag.exists(db, key: Self.key(link.tagID)) else { continue }
                let already = try AssetTag
                    .filter(Column("asset_id") == Self.key(link.assetID))
                    .filter(Column("tag_id") == Self.key(link.tagID))
                    .fetchCount(db) > 0
                if !already { try link.insert(db) }
            }
            // 5. Covers — restore only if the collection still has no cover (don't
            //    clobber a choice the user made after the delete).
            for cover in backup.covers {
                guard presentAssetKeys.contains(Self.key(cover.assetID)) else { continue }
                guard var collection = try Collection.fetchOne(
                    db, key: Self.key(cover.collectionID)) else { continue }
                if collection.coverAssetID == nil {
                    collection.coverAssetID = cover.assetID
                    collection.updatedAt = Date()
                    try collection.update(db)
                }
            }
        }
    }

    /// Every distinct non-null `blob_hash` an asset currently references — the
    /// "keep" set for the launch orphan-blob GC (010 · delete-undo).
    ///
    /// Hashes only. When the caller also needs each blob's FILE (to copy it, or
    /// to name it on disk), use ``referencedBlobs()`` instead — deriving the
    /// stored extension needs the mime type.
    public func referencedBlobHashes() async throws -> Set<String> {
        try await read { db in
            Set(try String.fetchAll(
                db, sql: "SELECT DISTINCT blob_hash FROM asset WHERE blob_hash IS NOT NULL"))
        }
    }

    /// Every blob an asset currently references, as ``BlobRef`` — the read half
    /// of the file-level operations Core can't perform itself (008 H5's backup
    /// copy set). The symmetric counterpart of ``deleteAssets(_:)``'s return:
    /// same descriptor, opposite guarantee (these are LIVE, never reap them).
    ///
    /// Exactly one row per distinct hash. Two nuances the SQL settles
    /// deliberately rather than leaving to chance:
    /// - `mime_type` is nullable; a NULL yields `""`, which
    ///   `ImageMetadata.fileExtension(forMIMEType:)` also yields for anything it
    ///   can't resolve, and which `MediaStore` stores as a dotless path. So the
    ///   empty string round-trips correctly instead of needing a special case.
    /// - Content-identical assets normally share a mime, but nothing enforces
    ///   it. `MIN` picks one **deterministically** so a backup diff is
    ///   reproducible run-to-run; a caller that finds no file at the derived
    ///   extension must treat it as a miss to report, not a crash — the bytes on
    ///   disk carry whichever extension ingest wrote first.
    public func referencedBlobs() async throws -> [BlobRef] {
        try await read { db in
            try Row.fetchAll(db, sql: """
                SELECT blob_hash, COALESCE(MIN(mime_type), '') AS mime_type
                FROM asset
                WHERE blob_hash IS NOT NULL
                GROUP BY blob_hash
                ORDER BY blob_hash
                """)
                .map { BlobRef(blobHash: $0["blob_hash"], mimeType: $0["mime_type"]) }
        }
    }

    // MARK: - Asset details (041 · Name / Note / Collections)

    /// Set (or clear) an asset's user-given display name. Trims; an empty result
    /// stores `NULL` (the "unnamed" state). `.notFound` if the asset is absent.
    /// Through the write funnel.
    public func setName(_ name: String?, for assetID: UUID) async throws {
        try await write { db in
            var asset = try Self.require(Asset.self, db: db, key: assetID)
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            asset.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try asset.update(db)
        }
    }

    /// Set (or clear) an asset's free-form note. Trims; empty → `NULL`.
    /// `.notFound` if the asset is absent. Through the write funnel.
    public func setNote(_ note: String?, for assetID: UUID) async throws {
        try await write { db in
            var asset = try Self.require(Asset.self, db: db, key: assetID)
            let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            asset.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
            try asset.update(db)
        }
    }

    // MARK: - Favorites (011 · U5)

    /// Set (or clear) the favorite flag on `assetIDs`, in ONE transaction.
    ///
    /// **Idempotent by construction.** The `UPDATE` is filtered to the rows that
    /// are not already at `isFavorite`, so favoriting a favorite writes nothing —
    /// no row version churn, no `updated_at` on the collections that hold it, and
    /// the returned count is the number of rows that actually CHANGED. Callers
    /// (the undo registration in the shell) use that count to decide whether the
    /// action is worth an undo entry at all.
    ///
    /// A missing id is silently ignored rather than a `.notFound`: the caller is a
    /// multi-select over a grid that can be reloaded underneath it, and failing the
    /// whole batch because one tile was deleted a moment ago would be worse than
    /// starring the rest. (`setName` / `setNote` are single-asset editors and do
    /// throw — the distinction is deliberate.) An empty set is a no-op.
    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            var args: [(any DatabaseValueConvertible)?] = [isFavorite]
            args.append(contentsOf: keys.map { $0 as (any DatabaseValueConvertible)? })
            args.append(isFavorite)
            try db.execute(sql: """
                UPDATE asset SET is_favorite = ?
                WHERE id IN (\(placeholders)) AND is_favorite <> ?
                """, arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// Single-asset convenience over ``setFavorite(_:for:)`` — `true` when the row
    /// actually changed.
    @discardableResult
    public func setFavorite(_ isFavorite: Bool, for assetID: UUID) async throws -> Bool {
        try await setFavorite(isFavorite, for: [assetID]) > 0
    }

    /// The ids among `assetIDs` that are currently favorited. The read half of the
    /// ⌘D rule: the shell asks this to decide which way a MIXED selection flips,
    /// and to build the exact inverse an undo has to restore.
    public func favoritedAssetIDs(among assetIDs: [UUID]) async throws -> Set<UUID> {
        let ids = Array(Set(assetIDs))
        guard !ids.isEmpty else { return [] }
        let keys = ids.map(Self.key)
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            let found = try String.fetchAll(db, sql: """
                SELECT id FROM asset WHERE id IN (\(placeholders)) AND is_favorite = 1
                """, arguments: StatementArguments(keys))
            return Set(found.compactMap(UUID.init(uuidString:)))
        }
    }

    // MARK: - Shelf (023 · A — archive / unarchive)

    /// Put `assetIDs` on the archive shelf, in ONE transaction. Returns the
    /// number of rows that actually changed.
    ///
    /// Archiving touches ONE column. It does not remove a membership, move a
    /// space placement, drop a tag or reap a blob — that is the entire
    /// difference between this and a delete, and it is why unarchiving can put
    /// the item back exactly where it was without having to remember anything.
    ///
    /// **Idempotent, and re-archiving keeps the ORIGINAL timestamp.** The
    /// `UPDATE` is filtered to `archived_at IS NULL`, so archiving an already
    /// archived asset writes nothing rather than bumping it to the top of the
    /// shelf. A batch that mixes archived and un-archived assets therefore
    /// archives only the un-archived ones and leaves the rest where they sit,
    /// which is what the shelf's "most recently archived first" order means.
    ///
    /// The timestamp is server-authoritative (the service stamps `Date()`, like
    /// every other `*_at` in this layer). A missing id is silently ignored, for
    /// the same reason ``setFavorite(_:for:)`` ignores one: the caller is a
    /// multi-select over a grid that can be reloaded underneath it, and failing
    /// the whole batch because one tile was deleted a moment ago is worse than
    /// archiving the rest. An empty set is a no-op.
    @discardableResult
    public func archive(_ assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            var args: [(any DatabaseValueConvertible)?] = [Date()]
            args.append(contentsOf: keys.map { $0 as (any DatabaseValueConvertible)? })
            try db.execute(sql: """
                UPDATE asset SET archived_at = ?
                WHERE id IN (\(placeholders)) AND archived_at IS NULL
                """, arguments: StatementArguments(args))
            return db.changesCount
        }
    }

    /// Take `assetIDs` off the shelf, in ONE transaction. Returns the number of
    /// rows that actually changed.
    ///
    /// The inverse of ``archive(_:)`` and lossless by construction: clearing the
    /// timestamp is the whole operation, because archiving never destroyed
    /// anything to restore. Filtered to `archived_at IS NOT NULL`, so
    /// unarchiving something that was never archived writes nothing.
    @discardableResult
    public func unarchive(_ assetIDs: [UUID]) async throws -> Int {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return 0 }
        return try await write { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            try db.execute(sql: """
                UPDATE asset SET archived_at = NULL
                WHERE id IN (\(placeholders)) AND archived_at IS NOT NULL
                """, arguments: StatementArguments(keys))
            return db.changesCount
        }
    }

    /// The ids among `assetIDs` that are currently archived — the read half of a
    /// mixed selection, mirroring ``favoritedAssetIDs(among:)``. `ShelfIntent`
    /// (023 · A3) asks this to decide which way a mixed selection flips and to
    /// build the exact inverse an undo has to restore.
    public func archivedAssetIDs(among assetIDs: [UUID]) async throws -> Set<UUID> {
        let keys = Array(Set(assetIDs)).map(Self.key)
        guard !keys.isEmpty else { return [] }
        return try await read { db in
            let placeholders = databaseQuestionMarks(count: keys.count)
            let found = try String.fetchAll(db, sql: """
                SELECT id FROM asset
                WHERE id IN (\(placeholders)) AND archived_at IS NOT NULL
                """, arguments: StatementArguments(keys))
            return Set(found.compactMap(UUID.init(uuidString:)))
        }
    }

    /// What the archive shelf is holding (023 · A4 / 016 stats): how many items
    /// are on it, and how many bytes deleting all of them would actually free.
    ///
    /// This is the ONE read that deliberately looks at archived rows and reports
    /// them as their own figure rather than hiding or merging them. Archive
    /// creates the question "what can I reclaim", and the Library pane is where
    /// that question is asked.
    ///
    /// `exclusiveBytes` counts a blob only when EVERY asset referencing it is
    /// archived — which is the honest answer, and the reason it is not a simple
    /// `SUM(file_size)`. Blobs are shared (one file, many asset rows), so
    /// summing per-asset sizes would double-count a picture saved into three
    /// collections, and counting a blob an un-archived asset still points at
    /// would promise space that unarchiving nothing could release. A number in a
    /// "reclaim" row that overstates is worse than no number.
    public func archivedUsage() async throws -> ArchivedUsage {
        try await read { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM asset WHERE archived_at IS NOT NULL") ?? 0
            // Per DISTINCT blob: keep it only if no un-archived asset references
            // it, then add its size once. `MAX(file_size)` collapses the rows
            // sharing a hash — they carry the same bytes by construction, so any
            // aggregate would do; MAX is the one that cannot return NULL while a
            // size exists.
            let bytes = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(size), 0) FROM (
                    SELECT MAX(file_size) AS size
                    FROM asset
                    WHERE blob_hash IS NOT NULL
                    GROUP BY blob_hash
                    HAVING SUM(CASE WHEN archived_at IS NULL THEN 1 ELSE 0 END) = 0
                )
                """) ?? 0
            return ArchivedUsage(assetCount: count, exclusiveBytes: bytes)
        }
    }

    /// The collections an asset is a direct member of, name-ordered — the reverse
    /// of ``addAssets(_:to:)``. Powers the Item Detail "Collections" chips; kept
    /// off the joined grid read (``collectionItems``) so the hot path stays a
    /// single round-trip. Empty if the asset has no memberships.
    public func collections(for assetID: UUID) async throws -> [Collection] {
        try await read { db in
            let collectionIDs = try CollectionItem
                .filter(Column("asset_id") == Self.key(assetID))
                .fetchAll(db)
                .map(\.collectionID)
            guard !collectionIDs.isEmpty else { return [] }
            let keys = collectionIDs.map(Self.key)
            return try Collection
                .filter(keys.contains(Column("id")))
                .order(Column("name"), Column("id"))
                .fetchAll(db)
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
            // Find-or-create by (name, source) — user vs agent tags are distinct
            // — then link idempotently. Shared with the suggestion writers.
            return try Self.linkTag(db, name: trimmed, source: source, to: assetID)
        }
    }

    /// Remove a tag from an asset. Idempotent — a no-op if the tag or the link
    /// is absent (the tag row itself is left intact for other assets). Through
    /// the write funnel.
    public func removeTag(_ name: String, from assetID: UUID, source: TagSource) async throws {
        // Same normalization as apply — so removing by a typed "#sf" matches the
        // stored "sf" (chips already pass the normalized name; this is robustness).
        let trimmed = Validation.normalizedTagName(name)
        try await write { db in
            try Self.unlinkTag(db, name: trimmed, source: source, from: assetID)
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

    /// Every tag in the library, ordered `name, source, id` (stable). Small,
    /// bounded inventory (P16) — feeds the search token vocabulary. Includes both
    /// `.user` and `.agent` tags; the caller distinguishes by ``Tag/source``.
    public func allTags() async throws -> [Tag] {
        try await read { db in
            try Tag.order(Column("name"), Column("source"), Column("id")).fetchAll(db)
        }
    }

    /// The search token vocabulary (007 · S3): tags whose `name` case-insensitively
    /// begins with `prefix`, ordered `name, source, id` and limited. A blank
    /// prefix returns the first `limit` tags overall (initial suggestions).
    /// `limit` is clamped to `1...200`.
    ///
    /// **`.user` tags only** (012 · I3). An unconfirmed machine guess is not part
    /// of the library's vocabulary — 012's settled posture is that the curated
    /// library never contains one, and a filter token is the most load-bearing
    /// place a tag can appear: searching `poster` and getting back what Vision
    /// merely thought was a poster is a different, worse product than searching
    /// what you actually labelled. Accepting a suggestion writes a real `.user`
    /// tag (``acceptSuggestion(_:on:)``), and it becomes searchable at that
    /// moment. Agent tags remain readable per asset via ``tags(for:)``, which is
    /// what draws the ✦ chips in the detail sidebar.
    ///
    /// This filter shipped before any suggester existed, so it changed no
    /// behaviour when it landed — it closes the seam ahead of the producer.
    public func tagVocabulary(prefix: String, limit: Int = 50) async throws -> [Tag] {
        let clampedLimit = min(max(limit, 1), 200)
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await read { db in
            var request = Tag.filter(Column("source") == TagSource.user.rawValue)
            if !trimmed.isEmpty {
                // LIKE is case-insensitive for ASCII by default; escape the LIKE
                // wildcards in the user's prefix so `%`/`_` match literally.
                let pattern = Self.escapeLikePrefix(trimmed) + "%"
                request = request.filter(sql: "name LIKE ? ESCAPE '\\'", arguments: [pattern])
            }
            return try request
                .order(Column("name"), Column("source"), Column("id"))
                .limit(clampedLimit)
                .fetchAll(db)
        }
    }

    // MARK: - Suggested tags (012 · I3)

    /// The next batch of asset ids a suggester has not yet looked at, at
    /// `suggestVersion` — the resumable pass, in the shape
    /// ``assetsNeedingAnalysis(analyzerVersion:limit:)`` established. Newest
    /// first, `limit` clamped to `1...1000`.
    ///
    /// An INNER join to `asset_analysis`, not a LEFT one, and that is the load-
    /// bearing difference from the analysis query. The marker being updated lives
    /// on the analysis row, so an asset without one cannot be marked; a LEFT join
    /// would hand back assets whose "done" write silently no-ops, and they would
    /// be re-classified — a full Vision decode each — on every pass forever. An
    /// asset that has no analysis row has failed to decode, and classification
    /// would fail on the same bytes, so nothing suggestable is lost by waiting
    /// for the analysis pass that runs ahead of this one.
    ///
    /// **Video is IN**, on the same poster-frame footing as the analysis queue —
    /// the classifier sees the poster JPEG, not the movie. It was excluded when I3
    /// shipped only because this query was written by mirroring the analysis one,
    /// and inherited a deferral the poster tier had already made unnecessary.
    public func assetsNeedingSuggestions(suggestVersion: Int, limit: Int) async throws -> [UUID] {
        let clampedLimit = min(max(limit, 1), 1000)
        return try await read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT a.id
                FROM asset a
                JOIN asset_analysis an ON an.asset_id = a.id
                WHERE a.kind IN (?, ?)
                  AND a.blob_hash IS NOT NULL
                  AND a.download_state = ?
                  AND (an.suggest_version IS NULL OR an.suggest_version < ?)
                ORDER BY a.created_at DESC
                LIMIT ?
                """, arguments: [
                    AssetKind.image.rawValue,
                    AssetKind.video.rawValue,
                    DownloadState.downloaded.rawValue,
                    suggestVersion,
                    clampedLimit,
                ])
            return ids.compactMap { UUID(uuidString: $0) }
        }
    }

    /// Record one asset's machine suggestions and mark it done, in ONE
    /// transaction (P15). Returns the `.agent` tags actually written — which is
    /// the input minus everything the filters below drop, so an empty return is
    /// an ordinary outcome, not a failure.
    ///
    /// Three things are refused, and all three are refused HERE rather than at
    /// the call site, so no future producer can forget one:
    ///
    /// 1. **Suppressed names** — the user dismissed this exact name on this exact
    ///    asset. This is the clause that makes a suggester-version bump safe: the
    ///    model may change its mind, the refusal does not expire.
    /// 2. **Names the asset already carries as a `.user` tag** — suggesting what
    ///    has already been confirmed (or typed by hand) puts a chip asking to
    ///    accept something already accepted.
    /// 3. **Empty / whitespace-only names**, dropped rather than thrown on. A
    ///    machine producing one junk label must not cost the other four their
    ///    write, and it is nobody's typo to report (the 004 batch-outcome
    ///    discipline, applied inside a single asset).
    ///
    /// The marker is written whether or not anything survived: "this suggester
    /// looked here and had nothing to say" is a completed pass, and recording it
    /// is what stops the asset coming back on the next drain.
    @discardableResult
    public func recordSuggestions(
        _ names: [String], for assetID: UUID, suggestVersion: Int
    ) async throws -> [Tag] {
        // Normalize outside the transaction (pure string work), preserving the
        // producer's confidence order and dropping exact repeats within one batch.
        var seen = Set<String>()
        let normalized = names
            .map(Validation.normalizedTagName)
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            let key = Self.key(assetID)

            let suppressed = Set(try String.fetchAll(
                db, sql: "SELECT tag_name FROM tag_suppression WHERE asset_id = ?",
                arguments: [key]))
            let confirmed = Set(try String.fetchAll(db, sql: """
                SELECT t.name FROM tag t
                JOIN asset_tag at ON at.tag_id = t.id
                WHERE at.asset_id = ? AND t.source = ?
                """, arguments: [key, TagSource.user.rawValue]))

            var written: [Tag] = []
            for name in normalized where !suppressed.contains(name) && !confirmed.contains(name) {
                written.append(try Self.linkTag(db, name: name, source: .agent, to: assetID))
            }

            try db.execute(sql: """
                UPDATE asset_analysis SET suggest_version = ? WHERE asset_id = ?
                """, arguments: [suggestVersion, key])
            return written
        }
    }

    /// Accept a suggestion: the asset drops the `.agent` tag and gains a `.user`
    /// one of the same name, in ONE transaction. Idempotent — accepting twice, or
    /// accepting a name the asset never had suggested, still leaves exactly one
    /// `.user` tag. `.notFound` if the asset is absent.
    ///
    /// **Not a flip of `tag.source`.** A tag row is shared by every asset that
    /// carries it (``applyTag(_:to:source:)`` finds-or-creates by `(name,
    /// source)`), so editing the row in place would promote the suggestion on
    /// every OTHER asset it was suggested for — a one-click accept silently
    /// confirming guesses the user has never seen. The unlink-and-re-apply below
    /// is per-asset, which is the granularity a confirmation actually has. 012's
    /// wording — "source flips → user" — describes the visible effect, not the
    /// write; the write cannot be a flip.
    ///
    /// The cost of doing it this way is that the accepted tag no longer records
    /// that a machine proposed it first. That provenance would need a column on
    /// `asset_tag`, and it buys nothing the user can act on: once confirmed, it is
    /// their tag.
    ///
    /// The orphaned `.agent` tag row is deliberately left behind when no asset
    /// links it any more, exactly as ``removeTag(_:from:source:)`` leaves its
    /// own. Reaping empty tag rows is a library-wide sweep, not a per-click
    /// concern.
    @discardableResult
    public func acceptSuggestion(_ name: String, on assetID: UUID) async throws -> Tag {
        let trimmed = try Validation.tagName(name)
        return try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            try Self.unlinkTag(db, name: trimmed, source: .agent, from: assetID)
            return try Self.linkTag(db, name: trimmed, source: .user, to: assetID)
        }
    }

    /// Dismiss a suggestion: unlink the `.agent` tag AND remember the refusal, in
    /// ONE transaction. Idempotent (the suppression upserts, refreshing its
    /// timestamp). `.notFound` if the asset is absent.
    ///
    /// The two halves are inseparable, which is why this is one method and not a
    /// removal the caller is trusted to follow with a suppression. Unlinking
    /// alone deletes a row the next pass recomputes from unchanged pixels, so a
    /// dismissal that forgot to suppress would look like it worked and quietly
    /// undo itself on the next idle drain — 012's named failure mode, and the
    /// kind that surfaces days later.
    public func dismissSuggestion(_ name: String, on assetID: UUID) async throws {
        let trimmed = try Validation.tagName(name)
        try await write { db in
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            try Self.unlinkTag(db, name: trimmed, source: .agent, from: assetID)
            try TagSuppression(assetID: assetID, tagName: trimmed, suppressedAt: Date())
                .upsert(db)
        }
    }

    /// Forget a refusal, so the name may be suggested again. The undo seam for
    /// ``dismissSuggestion(_:on:)``; idempotent, and a no-op when nothing was
    /// suppressed. It does not re-apply the tag — the next suggester pass decides
    /// that, which is the point.
    public func unsuppressTag(_ name: String, on assetID: UUID) async throws {
        let trimmed = Validation.normalizedTagName(name)
        try await write { db in
            try db.execute(
                sql: "DELETE FROM tag_suppression WHERE asset_id = ? AND tag_name = ?",
                arguments: [Self.key(assetID), trimmed])
        }
    }

    /// The names this asset has refused, oldest refusal first. Read.
    public func suppressedTagNames(for assetID: UUID) async throws -> [String] {
        try await read { db in
            try String.fetchAll(db, sql: """
                SELECT tag_name FROM tag_suppression
                WHERE asset_id = ?
                ORDER BY suppressed_at, tag_name
                """, arguments: [Self.key(assetID)])
        }
    }

    /// Find-or-create the `(name, source)` tag and link it to the asset
    /// idempotently. The shared body of ``applyTag(_:to:source:)`` and the
    /// suggestion writers — one place where "a tag is identified by name AND
    /// source" is expressed, so accept/suggest can never drift from apply.
    /// Caller has already validated the name and checked the asset exists.
    private static func linkTag(
        _ db: Database, name: String, source: TagSource, to assetID: UUID
    ) throws -> Tag {
        let tag: Tag
        if let existing = try Tag
            .filter(Column("name") == name)
            .filter(Column("source") == source.rawValue)
            .fetchOne(db) {
            tag = existing
        } else {
            let created = Tag(id: UUID(), name: name, source: source)
            try created.insert(db)
            tag = created
        }
        let linked = try AssetTag
            .filter(Column("asset_id") == key(assetID))
            .filter(Column("tag_id") == key(tag.id))
            .fetchCount(db) > 0
        if !linked {
            try AssetTag(assetID: assetID, tagID: tag.id).insert(db)
        }
        return tag
    }

    /// Drop the asset's link to the `(name, source)` tag, leaving the tag row
    /// itself intact for other assets. No-op when either is absent.
    private static func unlinkTag(
        _ db: Database, name: String, source: TagSource, from assetID: UUID
    ) throws {
        guard let tag = try Tag
            .filter(Column("name") == name)
            .filter(Column("source") == source.rawValue)
            .fetchOne(db) else { return }
        try AssetTag
            .filter(Column("asset_id") == key(assetID))
            .filter(Column("tag_id") == key(tag.id))
            .deleteAll(db)
    }
}
