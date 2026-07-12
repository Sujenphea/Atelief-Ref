import Foundation

/// The renderer's **image-content seam** — the second stable seam alongside
/// ``TileProvider`` (decision A2).
///
/// ``TileProvider`` says *where* tiles are; this says *what each tile draws*.
/// The spike backs it with ``FixtureImageSet`` (procedural bytes); at build-order
/// step 5 the app re-implements it over real assets — reading pre-generated
/// thumbnails from the on-disk media store — with **no change to the renderer**.
///
/// ``imageKey`` / ``imageFileURL`` / ``imageData`` are called by ``CanvasEngine``
/// on the **main actor** during the per-frame sync. Prefer ``imageFileURL`` for
/// on-disk thumbnails so the engine loads bytes **off-main** via
/// ``DecodeScheduler``; ``imageData`` is for in-memory fixtures (and must stay
/// cheap when used on the sync path).
public protocol TileImageSource {
    /// A stable cache identity for the image `tile` draws. Tiles that draw the
    /// **same** underlying image must return the **same** key, so they share a
    /// single decode and one cached bitmap per LOD tier; distinct images must
    /// return distinct keys (a collision would paint the wrong image).
    func imageKey(for tile: Tile) -> Int

    /// On-disk encoded bytes for `tile` at `tier`, when the source is a file.
    /// The engine reads this URL off-main. Default `nil` (in-memory sources).
    func imageFileURL(for tile: Tile, tier: LODTier) -> URL?

    /// The encoded image bytes for `tile` at `tier`, to be decoded/downsampled to
    /// the tier's pixel size, or `nil` when nothing is available yet (the tile's
    /// layer stays blank until a later frame can supply bytes). Prefer
    /// ``imageFileURL(for:tier:)`` for disk-backed sources so the sync path does
    /// not perform synchronous file I/O.
    func imageData(for tile: Tile, tier: LODTier) -> Data?
}

extension TileImageSource {
    public func imageFileURL(for tile: Tile, tier: LODTier) -> URL? { nil }
}
