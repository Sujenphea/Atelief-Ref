// AtelierCore — AppServices: spaces (the P0 file split).
//
// The board surface (005 · O1): spaces themselves, their ordering and recoverable
// delete, and the single discriminated `space_item` table's two row shapes —
// asset placements and freeform elements. Moved verbatim out of
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

    // MARK: - Spaces (005 · decision O1)

    /// Create a freeform space (005). Validates + trims the name (C8); the
    /// service generates `id` and `createdAt`/`updatedAt` (server-authoritative).
    @discardableResult
    public func createSpace(name: String) async throws -> Space {
        let trimmed = try Validation.spaceName(name)
        let now = Date()
        return try await write { db in
            // Append: the new space lands after the existing ones, keeping the flat
            // list dense at `0..<n` (043 · 2B, extended to spaces).
            var space = Space(id: UUID(), name: trimmed, createdAt: now, updatedAt: now)
            space.sortIndex = try Self.spaceIDsOrdered(in: db).count
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
            var space = try Self.require(Space.self, db: db, key: id)
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
            var space = try Self.require(Space.self, db: db, key: spaceID)
            guard try Asset.exists(db, key: Self.key(assetID)) else {
                throw AtelierError.notFound(entity: "asset", id: assetID)
            }
            space.coverAssetID = assetID
            space.updatedAt = Date()
            try space.update(db)
        }
    }

    /// Remember where a space was last looked at (018 · Cluster C). Stores the
    /// ``SpaceCamera`` as JSON TEXT in `space.camera`, mirroring
    /// ``updateSpaceItemStyle(itemID:style:)``'s opaque-TEXT write; `nil` clears the
    /// column back to "never opened", which restores as fit-to-content.
    ///
    /// Two deliberate differences from every other space write, and both are the
    /// point rather than an oversight:
    ///
    /// - **It does NOT bump `updatedAt`.** A camera is view state, not content.
    ///   Panning a board is not editing it, and letting a pan touch `updatedAt`
    ///   would make merely *looking* at a board register as a change.
    /// - **It is idempotent, not `.notFound`.** The flush on close (018 · C3) can
    ///   land after the board was deleted, and a camera for a space that no longer
    ///   exists is nothing to raise at the user — the same reasoning as
    ///   ``removeSpaceItem(itemID:)``.
    public func setSpaceCamera(spaceID: UUID, camera: SpaceCamera?) async throws {
        let json = camera?.jsonString()
        try await write { db in
            guard var space = try Space.fetchOne(db, key: Self.key(spaceID)) else { return }
            space.camera = json
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
            // Close the gap the delete left so the list stays dense (043 · 2B).
            try Self.applyDenseSpaceOrder(try Self.spaceIDsOrdered(in: db), in: db)
        }
    }

    /// Reposition a space in the flat manual order (043 · 2B, the space analog of
    /// ``moveCollection(id:toParent:index:)``). The space must exist (`.notFound`).
    /// `index` is the destination slot **with the moved space removed** (`0` =
    /// first, `nil` = append last); it is clamped to a valid range. The whole list
    /// is renumbered to a dense `0..<n`. Bumps `updatedAt` (a user-visible change).
    public func moveSpace(id: UUID, index: Int? = nil) async throws {
        try await write { db in
            var space = try Self.require(Space.self, db: db, key: id)
            space.updatedAt = Date()
            try space.update(db)
            // The moved row still carries its stale index, so strip + reinsert at
            // the target slot rather than trust its position.
            var ordered = try Self.spaceIDsOrdered(in: db)
            ordered.removeAll { $0 == id }
            let target = min(max(index ?? ordered.count, 0), ordered.count)
            ordered.insert(id, at: target)
            try Self.applyDenseSpaceOrder(ordered, in: db)
        }
    }

    /// The space ids in canonical manual order — persisted `sort_index`, tie-broken
    /// by `(created_at DESC, id)` (matching ``listSpaces()``). The single seam used
    /// to renumber the list after a create / delete / move (043 · 2B).
    private static func spaceIDsOrdered(in db: Database) throws -> [UUID] {
        try Space
            .order(Column("sort_index"), Column("created_at").desc, Column("id"))
            .fetchAll(db).map(\.id)
    }

    /// Write a dense `0..<n` `sort_index` for `orderedIDs`, in order. A targeted
    /// column UPDATE (not a record `update`) so it does NOT bump `updated_at` — a
    /// renumber is structural bookkeeping, not a user edit. Mirrors the collection
    /// ``applyDenseOrder(_:in:)``.
    private static func applyDenseSpaceOrder(_ orderedIDs: [UUID], in db: Database) throws {
        for (position, id) in orderedIDs.enumerated() {
            try db.execute(
                sql: "UPDATE space SET sort_index = ? WHERE id = ?",
                arguments: [position, Self.key(id)])
        }
    }

    /// Delete a space AND capture a verbatim backup for undo, in ONE transaction
    /// (UX-batch · space-delete undo). Mirrors ``deleteAssetsRecoverable(_:)``: the
    /// space row and ALL its placements are read BEFORE the cascade runs, so the
    /// backup can't drift from what was deleted. The underlying assets are never
    /// touched, so ``restoreDeletedSpace(_:)`` reinstates the board exactly.
    public func deleteSpaceRecoverable(id: UUID) async throws -> DeletedSpaceBackup {
        try await write { db in
            let space = try Self.require(Space.self, db: db, key: id)
            let items = try SpaceItem
                .filter(Column("space_id") == Self.key(id))
                .fetchAll(db)
            guard try Space.deleteOne(db, key: Self.key(id)) else {
                throw AtelierError.notFound(entity: "space", id: id)
            }
            // Close the gap so the remaining spaces stay dense; the backup keeps
            // the deleted space's own `sortIndex` for `restoreDeletedSpace` (043 · 2B).
            try Self.applyDenseSpaceOrder(try Self.spaceIDsOrdered(in: db), in: db)
            return DeletedSpaceBackup(space: space, items: items)
        }
    }

    /// Reinstate a ``DeletedSpaceBackup`` verbatim — the inverse of
    /// ``deleteSpaceRecoverable(id:)``. ONE transaction, best-effort per row and
    /// idempotent (skip-if-exists), so a redo-after-undo can't duplicate. Ids /
    /// positions / z-order / timestamps are preserved. Resilient: the space's cover
    /// is nulled if that asset was deleted since, and any placement whose asset no
    /// longer exists is skipped (element rows always restore).
    public func restoreDeletedSpace(_ backup: DeletedSpaceBackup) async throws {
        guard let space = backup.space else { return }
        try await write { db in
            if try !Space.exists(db, key: Self.key(space.id)) {
                var restored = space
                // Don't reinstate a dangling cover FK (the asset may be gone).
                if let cover = restored.coverAssetID,
                   try !Asset.exists(db, key: Self.key(cover)) {
                    restored.coverAssetID = nil
                }
                try restored.insert(db)
                // Put it back at (close to) its former slot: reinsert at the stored
                // index among the now-dense survivors, then renumber (043 · 2B).
                var ordered = try Self.spaceIDsOrdered(in: db)
                ordered.removeAll { $0 == restored.id }
                let target = min(max(restored.sortIndex, 0), ordered.count)
                ordered.insert(restored.id, at: target)
                try Self.applyDenseSpaceOrder(ordered, in: db)
            }
            for item in backup.items {
                guard try !SpaceItem.exists(db, key: Self.key(item.id)) else { continue }
                if let assetID = item.assetID,
                   try !Asset.exists(db, key: Self.key(assetID)) {
                    continue // the placed asset was deleted since — skip its row.
                }
                try item.insert(db)
            }
        }
    }

    /// Every space in manual order — persisted `sort_index`, tie-broken by
    /// `(created_at DESC, id)` so equal indices (unmigrated fixtures) keep the prior
    /// newest-first order (043 · 2B). The space count is small and bounded, so this
    /// returns the full inventory (P16).
    public func listSpaces() async throws -> [Space] {
        try await read { db in
            try Space
                .order(Column("sort_index"), Column("created_at").desc, Column("id"))
                .fetchAll(db)
        }
    }

    /// A batch cover lookup for the Spaces list (005 Q2), symmetric to
    /// ``collectionCovers(_:)``: each requested space id that HAS a (surviving)
    /// cover asset maps to that asset's `blob_hash`. Spaces with no cover are
    /// absent from the result.
    public func spaceCovers(_ ids: [UUID]) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        return try await read { db in
            try Self.covers(in: db, table: "space", ids: ids)
        }
    }

    /// Fanned "stack" previews for the Home Spaces cards (009 · N4), the space
    /// analog of ``collectionStackPreviews(limit:includeUnsorted:)``: every space,
    /// in manual order (`sort_index`, tie-broken `created_at DESC, id` — matching
    /// ``listSpaces()`` so Home and the sidebar share ONE order). Each entry carries
    /// the space, its placed-item count, and the blob hashes of its `limit` most
    /// recently added asset items (newest first) for the fan — one window-function
    /// query, not a per-space N+1. Element rows (NULL `asset_id`) and media-less
    /// assets have no thumbnail so they are skipped in the hashes but still counted;
    /// a space with no byte-backed items simply fans nothing.
    public func spaceStackPreviews(limit: Int = 3) async throws -> [SpaceStackPreview] {
        try await read { db in
            let spaces = try Space
                .order(Column("sort_index"), Column("created_at").desc, Column("id"))
                .fetchAll(db)
            guard !spaces.isEmpty else { return [] }

            let (counts, hashes) = try Self.stackPreviews(
                in: db, parentIDs: spaces.map(\.id),
                childTable: "space_item", parentColumn: "space_id",
                recencyColumn: "created_at", limit: limit)

            return spaces.map {
                SpaceStackPreview(
                    space: $0,
                    itemCount: counts[$0.id] ?? 0,
                    recentBlobHashes: hashes[$0.id] ?? [])
            }
        }
    }

    /// One space by id; `.notFound` if absent.
    public func getSpace(id: UUID) async throws -> Space {
        try await read { db in
            let space = try Self.require(Space.self, db: db, key: id)
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

    /// Add MANY asset references to a space in ONE transaction (059 · SP2 / 13A) —
    /// the insert analog of ``setSpaceItemPlacements(_:)``. A drag / import of N
    /// references mints N `space_item` rows in a single atomic write instead of N
    /// round-trips through the serialized writer. The space is validated ONCE; every
    /// asset must exist (`.notFound`) and every placement is validated up front, so
    /// an unknown asset or bad rect rolls the WHOLE batch back (all-or-nothing,
    /// matching the single-item contract). An empty batch is a no-op returning `[]`.
    /// The same asset MAY appear twice (each row has its own id) — a deliberate
    /// caller act, mirroring ``addAssetToSpace``.
    @discardableResult
    public func addAssetsToSpace(
        _ placements: [SpaceAssetPlacement], to spaceID: UUID
    ) async throws -> [SpaceItem] {
        guard !placements.isEmpty else { return [] }
        for p in placements {
            try Validation.spaceItem(kind: .asset, assetID: p.assetID)
            try Validation.canvasPlacement(x: p.x, y: p.y, w: p.w, h: p.h)
        }
        let now = Date()
        let items = placements.map { p in
            SpaceItem(
                id: UUID(), spaceID: spaceID, kind: .asset, assetID: p.assetID,
                x: p.x, y: p.y, w: p.w, h: p.h, z: p.z, style: nil,
                createdAt: now, updatedAt: now)
        }
        return try await write { db in
            guard try Space.exists(db, key: Self.key(spaceID)) else {
                throw AtelierError.notFound(entity: "space", id: spaceID)
            }
            for item in items {
                guard let assetID = item.assetID,
                      try Asset.exists(db, key: Self.key(assetID)) else {
                    throw AtelierError.notFound(entity: "asset", id: item.assetID ?? item.id)
                }
                try item.insert(db)
            }
            return items
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
        // Delegate to the batch write so the single- and multi-tile paths can never
        // diverge on validation / update semantics (049 · D13, DRY).
        try await setSpaceItemPlacements(
            [SpaceItemPlacement(itemID: itemID, x: x, y: y, w: w, h: h, z: z)])
    }

    /// Persist MANY tile placements in ONE transaction (049 · D13) — a multi-select
    /// drag (and its undo/redo) moves N tiles as a single atomic write, not N
    /// round-trips through the serialized queue. Every placement is validated up
    /// front; an unknown id throws `.notFound` and rolls the WHOLE batch back
    /// (all-or-nothing, matching the single-item contract). An empty batch is a
    /// no-op.
    public func setSpaceItemPlacements(_ placements: [SpaceItemPlacement]) async throws {
        guard !placements.isEmpty else { return }
        for p in placements {
            try Validation.canvasPlacement(x: p.x, y: p.y, w: p.w, h: p.h)
        }
        try await write { db in
            let now = Date()
            for p in placements {
                var item = try Self.require(SpaceItem.self, db: db, key: p.itemID)
                item.x = p.x; item.y = p.y; item.w = p.w; item.h = p.h; item.z = p.z
                item.updatedAt = now
                try item.update(db)
            }
        }
    }

    /// Restyle a freeform element (005; wired by E3). `.notFound` if absent;
    /// bumps `updatedAt`. Stores the ``ElementStyle`` as JSON TEXT (nil clears it).
    public func updateSpaceItemStyle(itemID: UUID, style: ElementStyle?) async throws {
        try await write { db in
            var item = try Self.require(SpaceItem.self, db: db, key: itemID)
            item.style = style?.jsonString()
            item.updatedAt = Date()
            try item.update(db)
        }
    }

    /// Restyle a freeform element AND (optionally) move/resize it in ONE
    /// transaction (054 §4.3 · R6 · D5 — 2C). An auto-sized text element's derived
    /// `w`/`h` is *part of* its style change, so the style write and the geometry
    /// write must never half-persist: a single `db.write {}` registers as one undo
    /// step and one atomic edit. `placement == nil` writes style only (the common
    /// `.fixed` path adds zero geometry writes). `.notFound` if the row is absent;
    /// the placement (when present) is validated (C8). Bumps `updatedAt`.
    public func updateSpaceItemStyleAndPlacement(
        itemID: UUID, style: ElementStyle?, placement: SpaceItemPlacement?
    ) async throws {
        if let placement {
            try Validation.canvasPlacement(x: placement.x, y: placement.y, w: placement.w, h: placement.h)
        }
        try await write { db in
            var item = try Self.require(SpaceItem.self, db: db, key: itemID)
            item.style = style?.jsonString()
            if let placement {
                item.x = placement.x; item.y = placement.y
                item.w = placement.w; item.h = placement.h; item.z = placement.z
            }
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
}
