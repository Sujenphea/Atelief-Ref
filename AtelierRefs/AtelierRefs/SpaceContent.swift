//
//  SpaceContent.swift
//  AtelierRefs
//
//  005-E2/E3 — the `SpaceItem`-backed implementation of the renderer's seams.
//  Maps a space's rows to world-space ``Tile``s reading their persisted placement
//  directly (a space_item always has a concrete rect). ASSET rows draw their
//  pre-generated thumbnail via the pooled/decode path (``TileImageSource``); since
//  E3, ELEMENT rows (`.frame`/`.text`) draw as vector tiles via
//  ``TileProvider/content(for:)`` (decision T3 — crisp CA siblings, no decode).
//
//  Frames are group containers (005 open-Q1, chosen): dragging a frame carries
//  the tiles it contains — ``groupMembers(forDraggedTileID:)`` returns every tile
//  whose centre falls inside the frame's current world rect.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation

/// Drives the canvas from a space's ``SpaceItemDetail`` list + the ``MediaStore``.
/// Built ONCE per board and handed to `CanvasView`; every later change — a drag, a
/// restyle, a resize, a reload — mutates this same instance, so the renderer's host
/// (and with it the user's pan and zoom) is never replaced. Used only on the main
/// actor (the renderer calls its seams during sync).
final class SpaceContent: TileProvider, TileImageSource {
    /// World-space tiles, index-aligned to ``rows`` and ``contentByTile`` — but NOT to
    /// ``Tile/id``, which is an opaque identity (see ``index(ofTileID:)``). Mutable so
    /// a canvas drag can update a tile's placement in place.
    private(set) var tiles: [Tile]

    /// The drawable rows behind the tiles (asset + element), index-aligned to
    /// ``tiles``. Asset rows with an unresolved asset are dropped. Mutable so an
    /// inspector / inline restyle can update a row in place (``setElementStyle``).
    private(set) var rows: [SpaceItemDetail]
    /// The renderer content per tile (precomputed: `.image` / `.frame` / `.text`),
    /// index-aligned to ``tiles``. Mutable so a restyle can re-derive one tile's
    /// content without a host rebuild.
    private(set) var contentByTile: [TileContent]
    /// The on-disk thumbnail store.
    private let store: MediaStore
    /// A dense cache key per distinct blob hash, so two tiles of the same image
    /// share one decode + cached bitmap per tier.
    private var keyByHash: [String: Int]

    /// The next identity to hand out. Monotonic and never reused, so a tile id names
    /// one row for as long as this content lives.
    private var nextTileID = 0
    /// `Tile.id` → its index in ``tiles`` / ``rows`` / ``contentByTile``.
    private var indexByTileID: [Int: Int] = [:]
    /// `SpaceItem.id` → the `Tile.id` drawing it.
    private var tileIDBySpaceItemID: [UUID: Int] = [:]

    init(items: [SpaceItemDetail], store: MediaStore) {
        self.store = store
        self.rows = []
        self.tiles = []
        self.contentByTile = []
        self.keyByHash = [:]
        append(Self.drawable(items))
    }

    /// The rows that get a tile at all: an asset row needs its resolved asset; element
    /// rows always draw (they carry only style + geometry).
    private static func drawable(_ items: [SpaceItemDetail]) -> [SpaceItemDetail] {
        items.filter { detail in
            switch detail.item.kind {
            case .asset: return detail.asset != nil
            case .frame, .text: return true
            }
        }
    }

    /// Give each of `details` a fresh tile identity and append it to the three
    /// index-aligned arrays. The ONE place a tile comes into existence.
    private func append(_ details: [SpaceItemDetail]) {
        for detail in details {
            let item = detail.item
            let tileID = nextTileID
            nextTileID += 1
            indexByTileID[tileID] = tiles.count
            tileIDBySpaceItemID[item.id] = tileID
            tiles.append(Tile(id: tileID, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z))
            rows.append(detail)
            contentByTile.append(ElementRendering.tileContent(for: item, asset: detail.asset))
            if let hash = detail.asset?.blobHash, keyByHash[hash] == nil {
                keyByHash[hash] = keyByHash.count
            }
        }
    }

    // MARK: - Reconcile (a reload, applied in place)

    /// Bring this content in line with `items` WITHOUT changing the tile id of any row
    /// that survived. Returns whether the tile SET changed (an id appeared or vanished).
    ///
    /// This is what lets a reload keep the user's pan and zoom. `SpaceModel.load()` used
    /// to build a whole new `SpaceContent` and bump a version the canvas was `.id`-bound
    /// to, which tore the `CanvasHostView` down and rebuilt it — and a fresh host frames
    /// the board to fit, so every delete, every create, every drop and every undo threw
    /// the viewport away. Updating the instance the renderer already holds means the
    /// camera is never touched at all.
    ///
    /// A survivor takes the incoming row wholesale, geometry included: a reload is a
    /// read of the durable truth, which is exactly what the caller asked for. Its tile
    /// id, its position in the arrays, and its cache key all stay put — so the renderer
    /// keeps its layers and its decoded bitmaps, and a text tile re-rasterizes nothing.
    ///
    /// Array order is deliberately left alone (survivors keep their slots, newcomers
    /// append). Nothing depends on it: the culler sorts what it returns by `(z, id)`,
    /// and draw order comes from `tile.z`.
    @discardableResult
    func reconcile(items: [SpaceItemDetail]) -> Bool {
        let incoming = Self.drawable(items)
        let byItemID = Dictionary(incoming.map { ($0.item.id, $0) }, uniquingKeysWith: { _, last in last })
        var setChanged = false

        // Survivors, refreshed in their existing slots; absentees fall out.
        var keptTiles: [Tile] = []
        var keptRows: [SpaceItemDetail] = []
        var keptContent: [TileContent] = []
        keptTiles.reserveCapacity(tiles.count)
        keptRows.reserveCapacity(rows.count)
        keptContent.reserveCapacity(contentByTile.count)
        var survived: Set<UUID> = []

        for (index, row) in rows.enumerated() {
            guard let fresh = byItemID[row.item.id] else {
                setChanged = true
                tileIDBySpaceItemID.removeValue(forKey: row.item.id)
                continue
            }
            let item = fresh.item
            keptTiles.append(
                Tile(id: tiles[index].id, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z))
            keptRows.append(fresh)
            keptContent.append(ElementRendering.tileContent(for: item, asset: fresh.asset))
            survived.insert(item.id)
        }

        tiles = keptTiles
        rows = keptRows
        contentByTile = keptContent
        indexByTileID = Dictionary(uniqueKeysWithValues: tiles.enumerated().map { ($1.id, $0) })

        // Newcomers get fresh identities. `keyByHash` only ever grows, so a row that
        // leaves and comes back (an undone delete) reuses its decoded bitmap.
        let newcomers = incoming.filter { !survived.contains($0.item.id) }
        if !newcomers.isEmpty {
            setChanged = true
            append(newcomers)
        }
        return setChanged
    }

    // MARK: - Identity

    /// Where a tile id sits in the three parallel arrays, or `nil` if no tile has it.
    ///
    /// A `Tile.id` used to BE this index, which made it a position rather than an
    /// identity: the rows arrive ordered by `(z, id)`, so a bring-to-front reordered
    /// them and silently renumbered every tile. That was survivable only because any
    /// such change rebuilt the whole canvas host and reset the state keyed on those
    /// ids. Once a reload updates the board in place (so the camera holds still), a
    /// renumbering id would leave the selection, the open inline editor and a live drag
    /// all pointing at different rows than they did a moment earlier — so the id is now
    /// handed out once, from ``nextTileID``, and never reused.
    private func index(ofTileID id: Int) -> Int? { indexByTileID[id] }

    /// The tile with this id, or `nil`. Callers must go through this rather than
    /// subscripting ``tiles`` — the id is not a position.
    func tile(forTileID id: Int) -> Tile? {
        index(ofTileID: id).map { tiles[$0] }
    }

    // MARK: - TileProvider

    /// What a tile draws — `.image` for asset rows, `.frame`/`.text` for elements.
    func content(for tile: Tile) -> TileContent {
        index(ofTileID: tile.id).map { contentByTile[$0] } ?? .image
    }

    /// A ▶ badge on video tiles, so a captured video reads as playable.
    func badge(for tile: Tile) -> TileBadge? {
        asset(for: tile.id)?.kind == .video ? .play : nil
    }

    /// Frame-as-group: dragging a `.frame` carries every OTHER tile whose centre
    /// is inside the frame's current world rect. Non-frame drags carry nothing.
    func groupMembers(forDraggedTileID id: Int) -> [Int] {
        guard let tile = tile(forTileID: id) else { return [] }
        return groupMembers(forTileID: id, in: tile.worldFrame)
    }

    /// Membership against a HYPOTHETICAL rect (062) — the frame being resized asks
    /// this on every tick to show what it is about to contain.
    ///
    /// This is the ONE place containment is decided; the drag path above delegates
    /// to it with the frame's stored rect. Keeping a single rule is the point: the
    /// highlight shown mid-resize and the set a later drag carries are the same
    /// answer to the same question, so they cannot disagree.
    func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int] {
        guard let index = index(ofTileID: id), rows[index].item.kind == .frame else { return [] }
        // Returns tile IDS, not array indices — the two are no longer the same thing,
        // and the renderer keys its carried-set and membership wash on the id.
        return tiles.filter { $0.id != id && worldRect.contains(Self.centre(of: $0)) }.map(\.id)
    }

    /// The on-disk video file behind a tile, or `nil` if the tile isn't a video.
    func videoURL(forTileID id: Int) -> URL? {
        guard let asset = asset(for: id), asset.kind == .video,
              let hash = asset.blobHash else { return nil }
        let ext = ImageMetadata.fileExtension(forMIMEType: asset.mimeType ?? "")
        return store.blobURL(hash: hash, fileExtension: ext)
    }

    // MARK: - TileImageSource

    func imageKey(for tile: Tile) -> Int {
        guard let hash = asset(for: tile.id)?.blobHash else { return tile.id }
        return keyByHash[hash] ?? tile.id
    }

    func imageFileURL(for tile: Tile, tier: LODTier) -> URL? {
        guard let hash = asset(for: tile.id)?.blobHash else { return nil }
        return store.thumbnailURL(hash: hash, size: Self.thumbnailSize(for: tier), fileExtension: "jpg")
    }

    func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }

    // MARK: - Placement mutation (canvas drag)

    /// Move `tileID` to a new world-space origin and, when `w`/`h` are given (a
    /// resize-handle drag, 062), a new size. A `nil` dimension keeps the current one,
    /// so the drag path can keep calling this without naming a size. `z` is never
    /// touched. The in-memory update the renderer reads next `sync()`; the durable
    /// write via `setSpaceItemPlacement` happens separately. No-op for an
    /// out-of-range id.
    func setPlacement(tileID: Int, x: Double, y: Double, w: Double? = nil, h: Double? = nil) {
        guard let index = index(ofTileID: tileID) else { return }
        let existing = tiles[index]
        tiles[index] = Tile(
            id: existing.id, x: x, y: y,
            w: w ?? existing.w, h: h ?? existing.h, z: existing.z)
    }

    // MARK: - Style mutation (inspector / inline restyle)

    /// Update an element tile's style + geometry in place — the style peer of
    /// ``setPlacement(tileID:x:y:)`` (the drag path). Re-derives the tile's drawn
    /// content and rect so an inspector / inline restyle redraws on the next
    /// `sync()` WITHOUT rebuilding the host (which would reset pan/zoom and drop the
    /// double-click sequence). The caller bumps `renderRevision` to trigger the sync.
    /// No-op for an out-of-range id.
    func setElementStyle(tileID: Int, detail: SpaceItemDetail) {
        guard let index = index(ofTileID: tileID) else { return }
        rows[index] = detail
        let item = detail.item
        contentByTile[index] = ElementRendering.tileContent(for: item, asset: detail.asset)
        tiles[index] = Tile(id: tileID, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z)
    }

    // MARK: - Lookups

    /// The full detail a tile draws, or `nil` if no tile has that id.
    func detail(forTileID id: Int) -> SpaceItemDetail? {
        index(ofTileID: id).map { rows[$0] }
    }

    /// The space_item id a tile draws (the unit placement / removal write on).
    func spaceItemID(forTileID id: Int) -> UUID? {
        detail(forTileID: id)?.item.id
    }

    /// The drag-OUT payload for a set of dragged tiles (059 · SP7): the asset ids of
    /// the ASSET tiles among them, z-ordered (matching ⌘C copy), with a
    /// membership-less source (`nilSourceID`) so a drop on a board / collection ADDS
    /// a copy — never a move. Element tiles (frame / text, no asset) are skipped;
    /// `nil` when no dragged tile carries an asset (nothing to drag out).
    func dragOutPayload(forTileIDs ids: Set<Int>) -> AssetDragPayload? {
        let assetIDs = ids
            .compactMap { detail(forTileID: $0) }
            .sorted { $0.item.z < $1.item.z }
            .compactMap { $0.asset?.id }
        guard !assetIDs.isEmpty else { return nil }
        return AssetDragPayload(assetIDs: assetIDs, sourceCollectionID: AssetDragPayload.nilSourceID)
    }

    /// The tile id showing the space_item `id`, or `nil` if it isn't on this
    /// board — lets the screen reflect the shared selection into the highlight.
    func tileID(forSpaceItemID id: UUID) -> Int? {
        tileIDBySpaceItemID[id]
    }

    private func asset(for id: Int) -> Asset? {
        detail(forTileID: id)?.asset
    }

    private static func centre(of tile: Tile) -> CGPoint {
        CGPoint(x: tile.x + tile.w / 2, y: tile.y + tile.h / 2)
    }

    /// Map a renderer LOD tier to the matching pre-generated thumbnail tier.
    static func thumbnailSize(for tier: LODTier) -> Int {
        switch tier {
        case .low: ThumbnailTier.small.rawValue     // 128
        case .medium: ThumbnailTier.medium.rawValue // 512
        case .full: ThumbnailTier.large.rawValue    // 1280
        }
    }
}
