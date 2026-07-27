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

/// Drives the canvas from a space's ``SpaceItemDetail`` list + the
/// ``MediaStore``. Built once per content version and handed to `CanvasView`;
/// used only on the main actor (the renderer calls its seams during sync).
final class SpaceContent: TileProvider, TileImageSource {
    /// World-space tiles, index-aligned to ``rows`` by ``Tile/id``. Mutable so a
    /// canvas drag can update a tile's placement in place.
    private(set) var tiles: [Tile]

    /// The drawable rows behind the tiles (asset + element); `tile.id` indexes
    /// straight into this. Asset rows with an unresolved asset are dropped. Mutable
    /// so an inspector / inline restyle can update a row in place (``setElementStyle``).
    private(set) var rows: [SpaceItemDetail]
    /// The renderer content per tile (precomputed: `.image` / `.frame` / `.text`).
    /// Mutable so a restyle can re-derive one tile's content without a host rebuild.
    private(set) var contentByTile: [TileContent]
    /// The on-disk thumbnail store.
    private let store: MediaStore
    /// A dense cache key per distinct blob hash, so two tiles of the same image
    /// share one decode + cached bitmap per tier.
    private let keyByHash: [String: Int]

    init(items: [SpaceItemDetail], store: MediaStore) {
        // Drawable rows: an asset row needs its resolved asset; element rows
        // always draw (they carry only style + geometry).
        let drawable = items.filter { detail in
            switch detail.item.kind {
            case .asset: return detail.asset != nil
            case .frame, .text: return true
            }
        }
        self.rows = drawable
        self.store = store

        var keyByHash: [String: Int] = [:]
        for detail in drawable {
            guard let hash = detail.asset?.blobHash, keyByHash[hash] == nil else { continue }
            keyByHash[hash] = keyByHash.count
        }
        self.keyByHash = keyByHash
        self.tiles = drawable.enumerated().map { index, detail in
            let item = detail.item
            return Tile(id: index, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z)
        }
        self.contentByTile = drawable.map { ElementRendering.tileContent(for: $0.item, asset: $0.asset) }
    }

    // MARK: - TileProvider

    /// What a tile draws — `.image` for asset rows, `.frame`/`.text` for elements.
    func content(for tile: Tile) -> TileContent {
        contentByTile.indices.contains(tile.id) ? contentByTile[tile.id] : .image
    }

    /// A ▶ badge on video tiles, so a captured video reads as playable.
    func badge(for tile: Tile) -> TileBadge? {
        asset(for: tile.id)?.kind == .video ? .play : nil
    }

    /// Frame-as-group: dragging a `.frame` carries every OTHER tile whose centre
    /// is inside the frame's current world rect. Non-frame drags carry nothing.
    func groupMembers(forDraggedTileID id: Int) -> [Int] {
        guard tiles.indices.contains(id) else { return [] }
        return groupMembers(forTileID: id, in: tiles[id].worldFrame)
    }

    /// Membership against a HYPOTHETICAL rect (062) — the frame being resized asks
    /// this on every tick to show what it is about to contain.
    ///
    /// This is the ONE place containment is decided; the drag path above delegates
    /// to it with the frame's stored rect. Keeping a single rule is the point: the
    /// highlight shown mid-resize and the set a later drag carries are the same
    /// answer to the same question, so they cannot disagree.
    func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int] {
        guard rows.indices.contains(id), rows[id].item.kind == .frame else { return [] }
        return tiles.indices.filter { i in
            i != id && worldRect.contains(Self.centre(of: tiles[i]))
        }
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
        guard tiles.indices.contains(tileID) else { return }
        let existing = tiles[tileID]
        tiles[tileID] = Tile(
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
        guard rows.indices.contains(tileID) else { return }
        rows[tileID] = detail
        let item = detail.item
        contentByTile[tileID] = ElementRendering.tileContent(for: item, asset: detail.asset)
        tiles[tileID] = Tile(id: tileID, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z)
    }

    // MARK: - Lookups

    /// The full detail a tile draws, or `nil` if out of range.
    func detail(forTileID id: Int) -> SpaceItemDetail? {
        rows.indices.contains(id) ? rows[id] : nil
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
        rows.firstIndex { $0.item.id == id }
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
