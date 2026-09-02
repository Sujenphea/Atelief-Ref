// AtelierCore — AppServices: collections (the P0 file split).
//
// The folder tree (create / rename / cover / delete / reparent), the bulk and
// arrange verbs that write MEMBERSHIP and order in one transaction each, and the
// collection-scoped reads the grid draws from. Moved verbatim out of
// `AppServices.swift` — same code, same order, same comments.
//
// **This is one half of a type, not a module.** `AppServices` is still ONE class
// with one write funnel (A4) and one public surface (A2); the 4,200-line file it
// used to live in simply stopped being readable. Nothing here may reach past
// `write {}` / `read {}` to the pool — `database` stays private to
// `AppServices.swift` precisely so that rule is still the compiler's to enforce.

import Foundation
import GRDB

extension AppServices {

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
        return try await write { db in
            if let parentID {
                guard try Collection.exists(db, key: Self.key(parentID)) else {
                    throw AtelierError.notFound(entity: "collection", id: parentID)
                }
            }
            // Auto-disambiguate a duplicate sibling name, Finder-style (043 · 2c).
            let unique = Validation.uniqueCollectionName(
                trimmed, among: try Self.siblingNames(parentID, in: db))
            // Append: the new folder lands after its existing siblings, keeping
            // the group dense at `0..<n` (043 · 2B).
            var toInsert = Collection(
                id: UUID(), name: unique, description: description,
                coverAssetID: nil, createdAt: now, updatedAt: now,
                parentCollectionID: parentID)
            toInsert.sortIndex = try Self.childIDsOrdered(parentID, in: db).count
            try toInsert.insert(db)
            return toInsert
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
            var collection = try Self.require(Collection.self, db: db, key: id)
            // Auto-disambiguate against the OTHER siblings (exclude self, so a
            // no-op rename to the current name doesn't drift — 043 · 2c).
            collection.name = Validation.uniqueCollectionName(
                trimmed,
                among: try Self.siblingNames(
                    collection.parentCollectionID, excluding: id, in: db))
            collection.updatedAt = Date()
            try collection.update(db)
            return collection
        }
    }

    /// Set a collection's cover. Both the collection and the asset must exist
    /// (`.notFound`); bumps `updatedAt`.
    public func setCollectionCover(collectionID: UUID, assetID: UUID) async throws {
        try await write { db in
            var collection = try Self.require(Collection.self, db: db, key: collectionID)
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
            let doomed = try Self.require(Collection.self, db: db, key: id)
            let formerParentID = doomed.parentCollectionID
            _ = try Collection.deleteOne(db, key: Self.key(id))
            // The cascade drops this folder's whole subtree; only the FORMER
            // parent's remaining children need renumbering to stay dense (043 · 2B).
            let remaining = try Self.childIDsOrdered(formerParentID, in: db)
            try Self.applyDenseOrder(remaining, in: db)
        }
    }

    /// Reparent AND/OR reposition a folder (decision F6 · 043 · 2B). Rejects the
    /// protected Unsorted folder (`.protectedCollection`, F3); the folder must
    /// exist (`.notFound`). When `newParentID` is non-nil it must exist
    /// (`.notFound`) and must NOT be `id` nor a descendant of `id` — else
    /// `.folderCycle`. `nil` ⇒ the folder becomes a root.
    ///
    /// `index` is the destination position among the destination group's children
    /// **with the moved folder removed** (`0` = first, `nil` = append last); it is
    /// clamped to a valid range. Both the destination group and — when the parent
    /// changed — the former group are renumbered to a dense `0..<n`. Bumps
    /// `updatedAt` (a user-visible change). This single op backs the "Move to ▸"
    /// menu (append via `index: nil`), a same-parent drag reorder (same parent,
    /// explicit `index`), and a reparent-with-position drag.
    public func moveCollection(
        id: UUID, toParent newParentID: UUID?, index: Int? = nil
    ) async throws {
        if id == Collection.unsortedID {
            throw AtelierError.protectedCollection(id: id)
        }
        try await write { db in
            var collection = try Self.require(Collection.self, db: db, key: id)
            let oldParentID = collection.parentCollectionID
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
            // Insert `id` at `index` among the destination group and renumber it
            // dense. The moved row still carries its stale old index, so strip +
            // reinsert rather than trust its position.
            var siblings = try Self.childIDsOrdered(newParentID, in: db)
            siblings.removeAll { $0 == id }
            let target = min(max(index ?? siblings.count, 0), siblings.count)
            siblings.insert(id, at: target)
            try Self.applyDenseOrder(siblings, in: db)
            // A parent change leaves a gap in the former group — close it too.
            if oldParentID != newParentID {
                let formerSiblings = try Self.childIDsOrdered(oldParentID, in: db)
                try Self.applyDenseOrder(formerSiblings, in: db)
            }
        }
    }

    /// The DIRECT children of a folder (decision F5/P13), in manual order —
    /// persisted `sort_index`, tie-broken by `(name, id)` (043 · 2B). `nil` ⇒ the
    /// root folders (`parent_collection_id IS NULL`, including the protected
    /// Unsorted folder). Read.
    public func childCollections(of parentID: UUID?) async throws -> [Collection] {
        try await read { db in
            let filter: QueryInterfaceRequest<Collection>
            if let parentID {
                filter = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
            } else {
                filter = Collection.filter(Column("parent_collection_id") == nil)
            }
            return try filter
                .order(Column("sort_index"), Column("name"), Column("id"))
                .fetchAll(db)
        }
    }

    /// A parent's child ids in canonical order — persisted `sort_index`,
    /// tie-broken by `(name, id)`. `nil` parent = the roots. The single seam used
    /// to renumber a sibling group after a create / delete / move (043 · 2B).
    private static func childIDsOrdered(_ parentID: UUID?, in db: Database) throws -> [UUID] {
        let base: QueryInterfaceRequest<Collection>
        if let parentID {
            base = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
        } else {
            base = Collection.filter(Column("parent_collection_id") == nil)
        }
        return try base
            .order(Column("sort_index"), Column("name"), Column("id"))
            .fetchAll(db).map(\.id)
    }

    /// The names of the folders under `parentID` (`nil` = roots), optionally
    /// EXCLUDING one id (the folder being renamed, so it doesn't collide with its
    /// own name). Feeds `Validation.uniqueCollectionName` (043 · policy 2c).
    private static func siblingNames(
        _ parentID: UUID?, excluding excludedID: UUID? = nil, in db: Database
    ) throws -> [String] {
        let base: QueryInterfaceRequest<Collection>
        if let parentID {
            base = Collection.filter(Column("parent_collection_id") == Self.key(parentID))
        } else {
            base = Collection.filter(Column("parent_collection_id") == nil)
        }
        let query = excludedID.map { base.filter(Column("id") != Self.key($0)) } ?? base
        return try query.fetchAll(db).map(\.name)
    }

    /// Write a dense `0..<n` `sort_index` for `orderedIDs`, in order. A targeted
    /// column UPDATE (not a record `update`) so it does NOT bump `updated_at` — a
    /// renumber is structural bookkeeping, not a user edit.
    private static func applyDenseOrder(_ orderedIDs: [UUID], in db: Database) throws {
        for (position, id) in orderedIDs.enumerated() {
            try db.execute(
                sql: "UPDATE collection SET sort_index = ? WHERE id = ?",
                arguments: [position, Self.key(id)])
        }
    }

    /// The fixed id of the protected default-import "Unsorted" folder (F3), so
    /// the app has a default target without reaching into the domain constant.
    public var unsortedFolderID: UUID { Collection.unsortedID }

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

    /// The next append slot for a collection's manual order: one past the current
    /// max, or 0 when the collection has no ordered items yet. Assigned to a new
    /// membership at insert so a fresh import/add lands at the END of the manual
    /// grid, in insertion order — instead of at a random position (a NULL
    /// `manual_order` sorts first and ties break on the membership's random UUID).
    /// SQLite makes uncommitted inserts visible within the same transaction, so a
    /// batch that calls this per item still increments correctly.
    static func nextManualOrder(_ db: Database, collectionID: UUID) throws -> Int {
        let maxOrder = try Int.fetchOne(
            db,
            sql: """
                SELECT COALESCE(MAX(manual_order), -1) FROM collection_item
                WHERE collection_id = ?
                """,
            arguments: [Self.key(collectionID)]) ?? -1
        return maxOrder + 1
    }

    /// How many ids one `setGridOrder` statement carries (14A).
    ///
    /// Each id spends THREE bound variables — `WHEN ? THEN ?` in the `CASE`, and
    /// one slot in the `IN (…)` list — so a chunk of 500 binds 1,501 with the
    /// collection id. SQLite's `SQLITE_MAX_VARIABLE_NUMBER` is the ceiling this
    /// exists for; a whole-library reorder must not become a statement the engine
    /// refuses to prepare, and "one statement per grid" is not a promise this can
    /// make while the grid is unbounded.
    static let gridOrderChunkSize = 500

    /// Assign `manualOrder` 0,1,2,… to the listed memberships, IN ONE
    /// transaction (P15).
    ///
    /// **Ids that are not members of `collectionID` are IGNORED** (14A). They used
    /// to throw `.notFound` and roll the whole batch back, which made every caller
    /// pre-read the membership set to protect a reorder from an asset deleted in
    /// another window a moment earlier — a full collection read before every drag.
    /// A reorder is a statement about the items that ARE there; an id that is not
    /// one has no position to be given, and dropping it is the whole of what the
    /// caller's pre-read was computing.
    ///
    /// A **missing collection** still throws `.notFound` — asking to reorder a
    /// folder that does not exist is a different mistake from naming an item that
    /// left one, and it is worth telling the caller about. An EMPTY
    /// `orderedAssetIDs` is a no-op and does not look.
    ///
    /// Positions come from an id's index in `orderedAssetIDs`, so ignoring a
    /// non-member leaves a GAP in the sequence (`[gone, a, b]` gives `a` 1 and `b`
    /// 2). Only the relative order is meaningful — the sort reads `manual_order`
    /// ascending — and closing the gaps would mean re-deriving positions the
    /// caller did not ask to change. A duplicated id takes its LAST index, as it
    /// did when this was a loop.
    ///
    /// One chunked `UPDATE … SET manual_order = CASE asset_id WHEN … END` per
    /// ``gridOrderChunkSize`` ids, rather than a SELECT + UPDATE per row: at
    /// 20,000 items that loop took ~52 s, which is a reorder the user watches
    /// happen.
    public func setGridOrder(collectionID: UUID, orderedAssetIDs: [UUID]) async throws {
        guard !orderedAssetIDs.isEmpty else { return }
        // Distinct ids in first-appearance order, each carrying its LAST index.
        // Built here and bound as `let` so the write closure captures immutable
        // values (Sendable), not the mutable accumulators.
        let (distinct, positions): ([UUID], [UUID: Int]) = {
            var positions: [UUID: Int] = [:]
            var distinct: [UUID] = []
            for (index, assetID) in orderedAssetIDs.enumerated() {
                if positions.updateValue(index, forKey: assetID) == nil {
                    distinct.append(assetID)
                }
            }
            return (distinct, positions)
        }()
        let chunkSize = Self.gridOrderChunkSize
        try await write { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            for start in stride(from: 0, to: distinct.count, by: chunkSize) {
                let chunk = distinct[start..<Swift.min(start + chunkSize, distinct.count)]
                var args: [DatabaseValueConvertible] = []
                var whens = ""
                for assetID in chunk {
                    whens += "\n                            WHEN ? THEN ?"
                    args.append(Self.key(assetID))
                    args.append(positions[assetID] ?? 0)
                }
                args.append(Self.key(collectionID))
                args.append(contentsOf: chunk.map(Self.key))
                // The `IN (…)` is what makes the CASE safe: without it every OTHER
                // membership in the collection would match the UPDATE and take the
                // CASE's `ELSE` — NULL — wiping the order of the rows not listed.
                try db.execute(sql: """
                    UPDATE collection_item
                       SET manual_order = CASE asset_id\(whens)
                           END
                     WHERE collection_id = ?
                       AND asset_id IN (\(databaseQuestionMarks(count: chunk.count)))
                    """, arguments: StatementArguments(args))
            }
        }
    }

    /// Set a collection's grid sort mode (007). Persists `collection.sort_mode`
    /// and bumps `updatedAt`, IN ONE write. `.notFound` if absent. Non-destructive
    /// — `manual_order` is untouched, so switching to and from `.manual` restores
    /// the drag arrangement.
    public func setCollectionSortMode(_ mode: SortMode, for collectionID: UUID) async throws {
        try await write { db in
            var collection = try Self.require(Collection.self, db: db, key: collectionID)
            collection.sortMode = mode
            collection.updatedAt = Date()
            try collection.update(db)
        }
    }

    /// Record a view of each listed asset (007 · a view = an Item Detail open),
    /// IN ONE transaction (P15). Each DISTINCT id's `view_count` is incremented
    /// by one and `last_viewed_at` set to `at` — so N opens coalesced by the
    /// caller land as one bump per asset. Unknown ids are silently skipped
    /// (idempotent; a since-deleted asset is a harmless no-op). Duplicate ids in
    /// the batch count once. Negligible against the WAL.
    public func recordViews(_ assetIDs: [UUID], at date: Date = Date()) async throws {
        let distinct = Array(Set(assetIDs))
        guard !distinct.isEmpty else { return }
        try await write { db in
            for id in distinct {
                try db.execute(sql: """
                    UPDATE asset SET view_count = view_count + 1, last_viewed_at = ?
                    WHERE id = ?
                    """, arguments: [date, Self.key(id)])
            }
        }
    }

    /// Bulk-add memberships, IN ONE transaction (P15). Idempotent per asset
    /// (skips ones already members). `.notFound` (rolling back) for a missing
    /// collection or asset.
    ///
    /// Enforces the Unsorted invariant (F3 · "Unsorted means NOT filed"):
    /// - Into a REAL collection, the batch's Unsorted memberships are dropped in
    ///   the same transaction — a filed asset is no longer unsorted, so it stops
    ///   surfacing in both places at once.
    /// - Into Unsorted itself, an asset that already belongs to a real collection
    ///   is SKIPPED. Un-triage is only meaningful for an asset with nowhere else
    ///   to live; filing something into Unsorted alongside its real folders is
    ///   exactly the state this invariant exists to prevent.
    ///
    /// **Returns the assets this add EVICTED from Unsorted** — empty for every add
    /// that did not (into Unsorted itself, or a batch that was already filed). The
    /// first rule above means an "add" is also a removal for exactly one collection,
    /// so a caller watching Unsorted cannot tell from the verb alone whether the
    /// asset just left the feed in front of it (356). Reporting it here keeps that
    /// rule stated once, where it runs, instead of mirrored by every client that
    /// needs to know. `@discardableResult` — most callers legitimately don't care.
    @discardableResult
    public func addAssets(_ assetIDs: [UUID], to collectionID: UUID) async throws -> [UUID] {
        try await write { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            let intoUnsorted = collectionID == Collection.unsortedID
            let now = Date()
            // Append the batch after any existing items, in the given order — each
            // newly-inserted membership takes the next manual slot (skipped assets
            // that are already members don't consume one).
            var order = try Self.nextManualOrder(db, collectionID: collectionID)
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                if intoUnsorted, try Self.isFiled(db, assetID: assetID) { continue }
                let isMember = try Self.membership(
                    db, collectionID: collectionID, assetID: assetID) != nil
                if !isMember {
                    let item = CollectionItem(
                        id: UUID(), collectionID: collectionID,
                        assetID: assetID, addedAt: now, manualOrder: order)
                    try item.insert(db)
                    order += 1
                }
            }
            guard !intoUnsorted else { return [] }
            return try Self.evictFromUnsorted(db, assetIDs: assetIDs)
        }
    }

    /// Bulk-remove memberships, IN ONE transaction (P15). Idempotent — removing
    /// a non-member is a no-op.
    ///
    /// Never orphans (F3): an asset left with NO memberships falls back to the
    /// Unsorted home, so "remove from this folder" always leaves it reachable
    /// somewhere. Removing from Unsorted ITSELF is exempt — otherwise the verb
    /// would re-add what it just removed and the Unsorted grid could never be
    /// cleared (Delete is the verb for leaving the library).
    public func removeAssets(_ assetIDs: [UUID], from collectionID: UUID) async throws {
        try await write { db in
            for assetID in assetIDs {
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(collectionID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
            if collectionID != Collection.unsortedID {
                try Self.rehomeUnfiled(db, assetIDs: assetIDs)
            }
        }
    }

    /// Atomically MOVE memberships between collections (009 · N1), IN ONE
    /// transaction — the domain's triage verb, so a crash can never leave an
    /// asset vanished from both collections or silently duplicated half-moved.
    /// Per asset: gain a membership in `targetID` (skipped when already a
    /// member — the dedup mirrors `addAssets`, so an already-member asset
    /// simply loses its source membership), then lose the `sourceID`
    /// membership (idempotent — a stale payload whose asset was already
    /// removed from the source still honors the "put it there" intent, 9A).
    /// `.notFound` (rolling back the whole batch) for a missing source/target
    /// collection or asset. `sourceID == targetID` and an empty batch are
    /// no-ops. Duplicate ids in one batch land a single membership.
    ///
    /// New target memberships are explicitly APPENDED to the manual order
    /// (`max(manual_order) + 1, +2, …` in batch order) so a move lands at the
    /// target's feed end deterministically (17A). Fresh `addAssets`
    /// memberships stay NULL — which `.manual`'s `ORDER BY manual_order`
    /// sorts FIRST — so without the append a move into an arranged collection
    /// would surface at the front, breaking the "it went to the end" promise
    /// move makes (copy/import keep their existing placement semantics).
    ///
    /// The Unsorted invariant rides along, exactly as in ``addAssets(_:to:)``: a
    /// move into a real collection also drops the batch's Unsorted memberships,
    /// and a move into Unsorted skips the insert for an asset that still belongs
    /// to a real collection OTHER than the source — it leaves the source, but it
    /// is not unsorted, so it never lands in both. Such an asset therefore keeps
    /// at least one membership, which is why no orphan fallback is needed here.
    public func moveAssets(_ assetIDs: [UUID], from sourceID: UUID, to targetID: UUID) async throws {
        guard sourceID != targetID, !assetIDs.isEmpty else { return }
        try await write { db in
            guard try Collection.exists(db, key: Self.key(sourceID)) else {
                throw AtelierError.notFound(entity: "collection", id: sourceID)
            }
            guard try Collection.exists(db, key: Self.key(targetID)) else {
                throw AtelierError.notFound(entity: "collection", id: targetID)
            }
            let intoUnsorted = targetID == Collection.unsortedID
            let now = Date()
            var nextOrder = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(manual_order), -1) + 1 FROM collection_item
                WHERE collection_id = ?
                """, arguments: [Self.key(targetID)]) ?? 0
            for assetID in assetIDs {
                guard try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: assetID)
                }
                // Filed elsewhere → un-triaging into Unsorted is meaningless; the
                // asset just leaves the source. `excluding: sourceID` because that
                // membership is about to go.
                let staysFiled = try intoUnsorted
                    && Self.isFiled(db, assetID: assetID, excluding: sourceID)
                let isMember = try Self.membership(
                    db, collectionID: targetID, assetID: assetID) != nil
                if !isMember, !staysFiled {
                    let item = CollectionItem(
                        id: UUID(), collectionID: targetID,
                        assetID: assetID, addedAt: now, manualOrder: nextOrder)
                    try item.insert(db)
                    nextOrder += 1
                }
                try CollectionItem
                    .filter(Column("collection_id") == Self.key(sourceID))
                    .filter(Column("asset_id") == Self.key(assetID))
                    .deleteAll(db)
            }
            if !intoUnsorted {
                try Self.evictFromUnsorted(db, assetIDs: assetIDs)
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
    /// Returns the reclaimable blobs as ``BlobRef`` so the caller (which
    /// owns the `MediaStore`) can trash the on-disk blob + thumbnail files; Core
    /// itself never touches the filesystem. Tag rows survive (only the
    /// `asset_tag` join cascades), matching ``removeTag(_:from:source:)``.
    @discardableResult
    public func deleteAssets(_ assetIDs: [UUID]) async throws -> [BlobRef] {
        try await write { db in try Self.performDelete(assetIDs, in: db) }
    }

    /// The delete cascade, shared by ``deleteAssets(_:)`` and the recoverable
    /// variant so both run the SAME transaction logic (010 · delete-undo).
    static func performDelete(_ assetIDs: [UUID], in db: Database) throws -> [BlobRef] {
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
            // A media-less asset (003 · O1) has no blob to reclaim — only
            // byte-backed assets contribute an orphan-candidate hash.
            if let hash = asset.blobHash, mimeByHash[hash] == nil {
                mimeByHash[hash] = asset.mimeType ?? ""
                orderedHashes.append(hash)
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
        var orphans: [BlobRef] = []
        for hash in orderedHashes {
            let stillReferenced = try Asset
                .filter(Column("blob_hash") == hash)
                .fetchCount(db) > 0
            if !stillReferenced {
                orphans.append(BlobRef(blobHash: hash, mimeType: mimeByHash[hash]!))
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

    // MARK: - Reads (P16 — collection-scoped reads return full arrays)

    /// Every collection, ordered by `name` then `id` (stable). The library's
    /// collection count is small and bounded, so this returns the full
    /// inventory (P16 — only the unbounded library-wide reads are paged).
    public func listCollections() async throws -> [Collection] {
        try await read { db in
            // Flat `(name, id)` order — a stable, documented contract. Manual
            // sibling order (`sort_index`) is NOT applied here: the UI regroups
            // this flat list into the tree and sorts each parent group itself
            // (`FolderNode.tree` / `CollectionTargets`), so a global sort_index —
            // which repeats across parents — would be meaningless here anyway.
            try Collection.order(Column("name"), Column("id")).fetchAll(db)
        }
    }

    /// One collection by id; `.notFound` if absent.
    public func getCollection(id: UUID) async throws -> Collection {
        try await read { db in
            let collection = try Self.require(Collection.self, db: db, key: id)
            return collection
        }
    }

    /// The P14 joined read for a collection — every membership with its full
    /// asset + source, mapped to the public GRDB-free ``CollectionItemDetail``
    /// (A2). Collection-scoped, so the FULL array is returned (P16 — the views
    /// need every item), which is why no keyset cursor is needed here.
    ///
    /// `sort` (007) selects the ORDER BY; the default `.manual` preserves the
    /// prior behaviour (drag order, source-compatible for existing callers):
    ///   • `.manual` → `collection_item.manual_order, collection_item.id`.
    ///   • `.newest` → `asset.created_at DESC, asset.id DESC`.
    ///   • `.mostViewed` → `asset.view_count DESC, asset.created_at DESC,
    ///     asset.id DESC` (view_count ties are the norm, so the newest/​id
    ///     tie-breaks keep the order deterministic).
    /// Switching modes never rewrites `manual_order`, so it is non-destructive.
    /// `.notFound` if the collection is absent.
    ///
    /// `includeArchived` (023 · A) is deliberately **NOT defaulted**, and this is
    /// the one funnel where that earns its keep, because it has callers on both
    /// sides. Browsing passes `false` — an archived asset keeps its membership
    /// row and is hidden at the READ, which is what lets unarchiving put it back
    /// exactly where it was. The backup writer passes `true`: it walks the
    /// library one collection at a time through this same read, and a default
    /// here would mean every backup silently omitted the user's whole shelf and
    /// every restore lost it — a data-loss bug with no symptom until far too
    /// late. A non-defaulted parameter turns that into a compile error instead.
    public func collectionItems(
        in collectionID: UUID, sort: SortMode = .manual, includeArchived: Bool
    ) async throws -> [CollectionItemDetail] {
        try await read { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            // CollectionItem ⋈ Asset ⋈ Source, all required (P14): one round-trip,
            // no N+1. GRDB qualifies bare base columns to `collection_item`, so
            // the asset-keyed orderings reference the joined `asset` table by
            // name to avoid picking the membership row's columns.
            var assetJoin = CollectionItem.asset.including(required: Asset.source)
            if !includeArchived {
                // On the JOIN rather than as a trailing WHERE: this is a required
                // (INNER) join, so the two are equivalent to SQLite, and putting
                // it here keeps the predicate next to the table it is about.
                assetJoin = assetJoin.filter(Column("archived_at") == nil)
            }
            var request = CollectionItem
                .filter(Column("collection_id") == Self.key(collectionID))
                .including(required: assetJoin)
            switch sort {
            case .manual:
                request = request.order(Column("manual_order"), Column("id"))
            case .newest:
                request = request.order(sql: "asset.created_at DESC, asset.id DESC")
            case .mostViewed:
                request = request.order(
                    sql: "asset.view_count DESC, asset.created_at DESC, asset.id DESC")
            }
            return try CollectionItemRow.fetchAll(db, request).map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    /// ONE membership of `collectionID`, by the membership's own id — the same
    /// P14 join ``collectionItems(in:sort:includeArchived:)`` runs, with a
    /// primary-key predicate and no ORDER BY. `nil` when there is no such
    /// membership IN THIS COLLECTION.
    ///
    /// **Why this exists rather than filtering the collection read.** The phone's
    /// item screen resolves a tapped tile from a pair of ids, and it used to do
    /// that by reading the whole collection and keeping one row — 0.293 s at
    /// 5,000 items (`.change-log/450`), paid on every tap, to throw 4,999 rows
    /// away. The join is identical; what changes is that SQLite is told which row
    /// is wanted, so the two indexed lookups it already has (`collection_item`'s
    /// primary key, then the asset and source primary keys) do the whole job.
    ///
    /// **The collection id is not decoration.** A membership id is unique on its
    /// own, so the predicate could have been the id alone — and then a route
    /// carrying a stale collection would silently resolve an item that is no
    /// longer in the collection the screen says it is showing. The pair is what
    /// the navigation value carries (`BrowseRoute.item`), so the pair is what is
    /// asked.
    ///
    /// `includeArchived` is not defaulted, for the reason
    /// ``collectionItems(in:sort:includeArchived:)`` gives at length: browse
    /// passes `false`, and an archived asset hidden at the READ is what lets
    /// unarchiving put it back exactly where it was. An absent collection is
    /// `.notFound`, not `nil` — "this collection is gone" and "this item is gone
    /// from it" are different sentences and the caller shows different screens.
    public func collectionItem(
        in collectionID: UUID, id itemID: UUID, includeArchived: Bool
    ) async throws -> CollectionItemDetail? {
        try await read { db in
            guard try Collection.exists(db, key: Self.key(collectionID)) else {
                throw AtelierError.notFound(entity: "collection", id: collectionID)
            }
            var assetJoin = CollectionItem.asset.including(required: Asset.source)
            if !includeArchived {
                assetJoin = assetJoin.filter(Column("archived_at") == nil)
            }
            let request = CollectionItem
                .filter(Column("id") == Self.key(itemID))
                .filter(Column("collection_id") == Self.key(collectionID))
                .including(required: assetJoin)
            return try CollectionItemRow.fetchOne(db, request).map {
                CollectionItemDetail(item: $0.item, asset: $0.asset, source: $0.source)
            }
        }
    }

    /// The archive shelf itself (023 · A) — every archived asset with its
    /// provenance, most recently archived first.
    ///
    /// Its own function rather than a flag on a browse read, because it is not a
    /// collection and shares nothing with one: no membership rows, no manual
    /// order, no sort modes, and no scope. It is the whole library filtered to
    /// `archived_at IS NOT NULL`, which is exactly the query the v20 partial
    /// index exists to serve.
    ///
    /// **Returns the full array, no cursor** — a deliberate v1 choice, not an
    /// oversight. `collectionItems` justifies the same shape by being
    /// collection-scoped (P16), and that justification does NOT carry over to a
    /// library-wide read, so this one is measured instead: `ScaleHarnessTests`
    /// times a seeded shelf, and paging lands if and when that says it must.
    /// `archived_at DESC, id DESC` — the id tie-break keeps a batch archived in
    /// one gesture (one `UPDATE`, one timestamp) in a deterministic order.
    public func shelfAssets() async throws -> [AssetDetail] {
        try await read { db in
            let request = Asset
                .filter(sql: "asset.archived_at IS NOT NULL")
                .including(required: Asset.source)
                .order(sql: "asset.archived_at DESC, asset.id DESC")
            return try AssetSourceRow.fetchAll(db, request).map {
                AssetDetail(asset: $0.asset, source: $0.source)
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
    ///
    /// `fallingBackToRecent` (093 § 2) closes the gap between "has a cover" and
    /// "is recognisable": a cover is a thing the user has to have SET, and almost
    /// nobody has, so a surface that shows only explicit covers shows a column of
    /// placeholders. With it on, a collection with no surviving cover maps to its
    /// most recently added byte-backed, non-archived member instead — which is
    /// the same fallback the Mac's gallery already reaches by a different route
    /// (its fan card, ``collectionStackPreviews(limit:includeUnsorted:)``), and is
    /// stated once here rather than a second time in a caller. A collection with
    /// no byte-backed member at all is still absent, which is what lets a caller
    /// draw a folder placeholder for a genuinely empty one.
    ///
    /// It is **off by default** so the gallery keeps the shape it was measured
    /// with: the card wants an explicit cover FIRST and a fan of three second, and
    /// a defaulted-on fallback here would quietly fill the first slot with what
    /// the second is for.
    public func collectionCovers(
        _ ids: [UUID], fallingBackToRecent: Bool = false
    ) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        return try await read { db in
            var covers = try Self.covers(in: db, table: "collection", ids: ids)
            guard fallingBackToRecent else { return covers }
            let uncovered = ids.filter { covers[$0] == nil }
            guard !uncovered.isEmpty else { return covers }
            // `limit: 1` — the same window query the fan uses, asked for one row
            // per collection rather than three, so the two surfaces cannot
            // disagree about which member represents a collection.
            let (_, recent) = try Self.stackPreviews(
                in: db, parentIDs: uncovered,
                childTable: "collection_item", parentColumn: "collection_id",
                recencyColumn: "added_at", limit: 1)
            for (id, hashes) in recent {
                if let hash = hashes.first { covers[id] = hash }
            }
            return covers
        }
    }

    /// Fanned "stack" previews for the Collections gallery cards (009 · N4): every
    /// ROOT collection, ordered `name, id` (stable, matching ``listCollections()``).
    /// Each entry carries the collection, its DIRECT item count, and the blob
    /// hashes of its `limit` most recently added byte-backed items (newest first)
    /// for the fanned thumbnails — one window-function query, not a per-collection
    /// N+1. Media-less kinds (003 · O1) have no thumbnail so they are skipped in
    /// the hashes but still counted; a collection with no byte-backed items simply
    /// fans nothing. `includeUnsorted` toggles the protected Unsorted root: the
    /// gallery shows a card for it, so it opts in.
    public func collectionStackPreviews(
        limit: Int = 3, includeUnsorted: Bool = false
    ) async throws -> [CollectionStackPreview] {
        try await read { db in
            var query = Collection.filter(Column("parent_collection_id") == nil)
            if !includeUnsorted {
                query = query.filter(Column("id") != Self.key(Collection.unsortedID))
            }
            let roots = try query
                .order(Column("name"), Column("id"))
                .fetchAll(db)
            guard !roots.isEmpty else { return [] }

            let (counts, hashes) = try Self.stackPreviews(
                in: db, parentIDs: roots.map(\.id),
                childTable: "collection_item", parentColumn: "collection_id",
                recencyColumn: "added_at", limit: limit)

            return roots.map {
                CollectionStackPreview(
                    collection: $0,
                    itemCount: counts[$0.id] ?? 0,
                    recentBlobHashes: hashes[$0.id] ?? [])
            }
        }
    }
}
