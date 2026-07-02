/// The **one stable seam** of the renderer (decision A2).
///
/// The spike drives the canvas from a deterministic dummy generator; at
/// build-order step 5 this same protocol is re-implemented over real
/// `CollectionItem` rows from GRDB — the renderer above it does not change.
///
/// For the spike the provider exposes the full tile set and the culler does the
/// viewport intersection. A real implementation may back ``tiles`` with a
/// spatial index; the contract only promises "the tiles to consider".
///
/// Image *content* access (decode source per tile) is layered on in Checkpoint 4
/// alongside the Core Animation host, so this geometry seam stays minimal.
public protocol TileProvider {
    /// All tiles in world space.
    var tiles: [Tile] { get }

    /// An optional badge to overlay on `tile` — e.g. a play affordance for a
    /// video. Defaults to none, so existing providers need no change.
    func badge(for tile: Tile) -> TileBadge?
}

public extension TileProvider {
    func badge(for tile: Tile) -> TileBadge? { nil }
}

/// A small glyph the renderer overlays on a tile to signal something about its
/// asset (kept minimal + renderer-agnostic; the app maps asset kind → badge).
public enum TileBadge: Sendable {
    /// A ▶ play badge — the tile's asset is a video.
    case play
}
