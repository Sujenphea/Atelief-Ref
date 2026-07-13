//
//  SpaceContent.swift
//  AtelierRefs
//
//  005-E2 — the `SpaceItem`-backed implementation of the renderer's two seams,
//  the space sibling of `CanvasContent`. It maps a space's ASSET rows to
//  world-space ``Tile``s (``TileProvider``) reading their persisted placement
//  directly (a space_item always has a concrete rect — no justified-rows
//  fallback here; new items are placed at ADD time via `SpaceLayout`), and
//  serves each tile's pre-generated thumbnail from the ``MediaStore``
//  (``TileImageSource``). Zero renderer changes (decision T3): images ride the
//  existing pooled/culled/LOD path.
//
//  Freeform ELEMENT rows (`kind == .frame/.text`) are intentionally SKIPPED in
//  v1 — they need a vector tile path that doesn't exist yet (E3). They round-trip
//  in the store untouched; only their on-canvas rendering is deferred.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Foundation

/// Drives the canvas from a space's ``SpaceItemDetail`` list + the
/// ``MediaStore``. Built once per content version and handed to `CanvasView`;
/// used only on the main actor (the renderer calls its seams during sync).
final class SpaceContent: TileProvider, TileImageSource {
    /// World-space tiles, index-aligned to ``assetItems`` by ``Tile/id``.
    /// Mutable so a canvas drag can update a tile's placement in place.
    private(set) var tiles: [Tile]

    /// The ASSET rows behind the tiles; `tile.id` indexes straight into this.
    /// (Element rows are filtered out — see the file header.)
    private let assetItems: [SpaceItemDetail]
    /// The on-disk thumbnail store.
    private let store: MediaStore
    /// A dense cache key per distinct blob hash, so two tiles of the same image
    /// share one decode + cached bitmap per tier.
    private let keyByHash: [String: Int]

    init(items: [SpaceItemDetail], store: MediaStore) {
        // Only asset rows are drawable in v1; keep their placement + media.
        let assetOnly = items.filter { $0.item.kind == .asset && $0.asset != nil }
        self.assetItems = assetOnly
        self.store = store

        var keyByHash: [String: Int] = [:]
        for detail in assetOnly {
            guard let hash = detail.asset?.blobHash, keyByHash[hash] == nil else { continue }
            keyByHash[hash] = keyByHash.count
        }
        self.keyByHash = keyByHash
        self.tiles = assetOnly.enumerated().map { index, detail in
            let item = detail.item
            return Tile(id: index, x: item.x, y: item.y, w: item.w, h: item.h, z: item.z)
        }
    }

    // MARK: - TileProvider

    /// A ▶ badge on video tiles, so a captured video reads as playable.
    func badge(for tile: Tile) -> TileBadge? {
        asset(for: tile.id)?.kind == .video ? .play : nil
    }

    /// The on-disk video file behind a tile, or `nil` if the tile isn't a video.
    func videoURL(forTileID id: Int) -> URL? {
        guard let asset = asset(for: id), asset.kind == .video else { return nil }
        let ext = ImageMetadata.fileExtension(forMIMEType: asset.mimeType)
        return store.blobURL(hash: asset.blobHash, fileExtension: ext)
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

    /// Move `tileID` to a new world-space origin, keeping its current `w/h/z`.
    /// The in-memory update the renderer reads next `sync()`; the durable write
    /// via `setSpaceItemPlacement` happens separately. No-op for an out-of-range id.
    func setPlacement(tileID: Int, x: Double, y: Double) {
        guard tiles.indices.contains(tileID) else { return }
        let existing = tiles[tileID]
        tiles[tileID] = Tile(
            id: existing.id, x: x, y: y, w: existing.w, h: existing.h, z: existing.z)
    }

    // MARK: - Lookups

    /// The full detail a tile draws, or `nil` if out of range.
    func detail(forTileID id: Int) -> SpaceItemDetail? {
        assetItems.indices.contains(id) ? assetItems[id] : nil
    }

    /// The space_item id a tile draws (the unit placement / removal write on).
    func spaceItemID(forTileID id: Int) -> UUID? {
        detail(forTileID: id)?.item.id
    }

    /// The tile id showing the space_item `id`, or `nil` if it isn't on this
    /// board — lets the screen reflect the shared selection into the highlight.
    func tileID(forSpaceItemID id: UUID) -> Int? {
        assetItems.firstIndex { $0.item.id == id }
    }

    private func asset(for id: Int) -> Asset? {
        detail(forTileID: id)?.asset
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
