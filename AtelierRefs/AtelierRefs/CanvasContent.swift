//
//  CanvasContent.swift
//  AtelierRefs
//
//  Build-order #5 — productionize the canvas against real data. This is the
//  `CollectionItem`-backed implementation of the renderer's two seams: it maps a
//  folder's items to world-space ``Tile``s (``TileProvider``) and serves each
//  tile's pre-generated thumbnail from the ``MediaStore`` (``TileImageSource``).
//  Swapping the spike's dummy generator for this — with no renderer change — is
//  exactly what the Phase-1 spike's seams (decision A2) were built for.
//
//  Layout: items with an explicit canvas placement (`canvas_x/y/w/h`) keep it;
//  the rest flow into a justified-rows gallery sized by each image's aspect
//  ratio. (Imports don't set placement yet, so today every item is auto-laid;
//  persisting a user-arranged layout is later canvas-editor work.)
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import Foundation

/// Drives the canvas from a folder's ``CollectionItemDetail`` list + the
/// ``MediaStore``. Built once per content version and handed to `CanvasView`;
/// used only on the main actor (the renderer calls its seams during sync).
final class CanvasContent: TileProvider, TileImageSource {
    /// World-space tiles, index-aligned to ``details`` by ``Tile/id``. Mutable
    /// so a canvas drag can update a tile's placement in place (the renderer
    /// reads this next `sync()`), keeping the tile put without a provider rebuild.
    private(set) var tiles: [Tile]

    /// The items behind the tiles; `tile.id` indexes straight into this.
    private let details: [CollectionItemDetail]
    /// The on-disk thumbnail store.
    private let store: MediaStore
    /// A dense cache key per distinct blob hash, so two tiles of the same image
    /// (or content-identical assets) share one decode + cached bitmap per tier.
    private let keyByHash: [String: Int]

    // MARK: Layout constants (world units)

    private static let rowHeight: Double = 240
    private static let spacing: Double = 16
    private static let maxRowWidth: Double = 1600

    init(items: [CollectionItemDetail], store: MediaStore) {
        self.details = items
        self.store = store

        var keyByHash: [String: Int] = [:]
        for detail in items where keyByHash[detail.asset.blobHash] == nil {
            keyByHash[detail.asset.blobHash] = keyByHash.count
        }
        self.keyByHash = keyByHash
        self.tiles = Self.layout(items)
    }

    // MARK: - TileProvider

    // (tiles is the stored property above)

    /// A ▶ badge on video tiles, so a captured video reads as playable.
    func badge(for tile: Tile) -> TileBadge? {
        detail(for: tile.id)?.asset.kind == .video ? .play : nil
    }

    /// The on-disk video file behind a tile, or `nil` if the tile isn't a video
    /// (or is out of range). Used to open a video to play. The extension mirrors
    /// ``IngestionModel/blobURL(for:)`` (round-trips the store-time extension).
    func videoURL(forTileID id: Int) -> URL? {
        guard let detail = detail(for: id), detail.asset.kind == .video else { return nil }
        let ext = ImageMetadata.fileExtension(forMIMEType: detail.asset.mimeType)
        return store.blobURL(hash: detail.asset.blobHash, fileExtension: ext)
    }

    // MARK: - TileImageSource

    func imageKey(for tile: Tile) -> Int {
        guard let detail = detail(for: tile.id) else { return tile.id }
        // Always resolves (tiles align with details); the fallback is defensive.
        return keyByHash[detail.asset.blobHash] ?? tile.id
    }

    func imageData(for tile: Tile, tier: LODTier) -> Data? {
        guard let detail = detail(for: tile.id) else { return nil }
        let url = store.thumbnailURL(
            hash: detail.asset.blobHash,
            size: Self.thumbnailSize(for: tier),
            fileExtension: "jpg")
        // Small pre-sized JPEG; missing tier ⇒ nil (tile stays blank this frame).
        return try? Data(contentsOf: url)
    }

    // MARK: - Placement mutation (canvas drag)

    /// Move `tileID` to a new world-space origin, keeping its current `w/h/z`.
    /// This is the in-memory update the renderer reads next `sync()`, so the
    /// dragged tile stays exactly where it was dropped (the durable DB write via
    /// `setCanvasPlacement` happens separately). A no-op for an out-of-range id.
    func setPlacement(tileID: Int, x: Double, y: Double) {
        guard tiles.indices.contains(tileID) else { return }
        let existing = tiles[tileID]
        tiles[tileID] = Tile(
            id: existing.id, x: x, y: y, w: existing.w, h: existing.h, z: existing.z)
    }

    // MARK: - Lookups

    /// The item a tile draws, or `nil` if the id is out of range. Exposed for the
    /// canvas host to resolve a clicked / right-clicked tile to its asset.
    func detail(forTileID id: Int) -> CollectionItemDetail? {
        detail(for: id)
    }

    /// The tile id showing the membership `id`, or `nil` if it isn't on this
    /// board. Lets the screen reflect the shared selection into the highlight.
    /// (`tile.id` is the index into `details`, so the index IS the tile id.)
    func tileID(forItemID id: UUID) -> Int? {
        details.firstIndex { $0.item.id == id }
    }

    /// The item a tile draws, or `nil` if the id is out of range.
    private func detail(for id: Int) -> CollectionItemDetail? {
        details.indices.contains(id) ? details[id] : nil
    }

    /// Map a renderer LOD tier to the matching pre-generated thumbnail tier.
    /// The pixel sizes line up exactly (128 / 512 / 1280), so no re-scaling.
    static func thumbnailSize(for tier: LODTier) -> Int {
        switch tier {
        case .low: ThumbnailTier.small.rawValue     // 128
        case .medium: ThumbnailTier.medium.rawValue // 512
        case .full: ThumbnailTier.large.rawValue    // 1280
        }
    }

    // MARK: - Justified-rows layout

    /// One ``Tile`` per item (id = index, so it indexes back into `details`).
    /// Explicit placement is honoured; otherwise items pack left→right at a fixed
    /// row height, wrapping when the row would exceed ``maxRowWidth``.
    private static func layout(_ items: [CollectionItemDetail]) -> [Tile] {
        var tiles: [Tile] = []
        tiles.reserveCapacity(items.count)

        var penX: Double = 0
        var penY: Double = 0
        var rowStart = true

        for (index, detail) in items.enumerated() {
            if let x = detail.item.canvasX, let y = detail.item.canvasY,
               let w = detail.item.canvasW, let h = detail.item.canvasH {
                tiles.append(Tile(id: index, x: x, y: y, w: w, h: h,
                                  z: detail.item.canvasZ ?? index))
                continue
            }

            let width = rowHeight * aspect(detail.asset)
            if !rowStart, penX + spacing + width > maxRowWidth {
                penX = 0
                penY += rowHeight + spacing
                rowStart = true
            }
            if !rowStart { penX += spacing }

            tiles.append(Tile(id: index, x: penX, y: penY, w: width, h: rowHeight, z: index))
            penX += width
            rowStart = false
        }
        return tiles
    }

    /// Display aspect ratio (w/h) of an asset; a safe `1` for missing dimensions.
    private static func aspect(_ asset: Asset) -> Double {
        guard asset.width > 0, asset.height > 0 else { return 1 }
        return Double(asset.width) / Double(asset.height)
    }
}
