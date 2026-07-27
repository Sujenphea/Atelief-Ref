import CoreGraphics

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

    /// What `tile` draws (E3). Defaults to ``TileContent/image`` so image-only
    /// providers need no change; a provider with freeform elements returns
    /// ``TileContent/frame(_:)`` / ``TileContent/text(_:)`` for those rows.
    func content(for tile: Tile) -> TileContent

    /// The **other** tiles that move together with `id` when it is dragged (E3 —
    /// frame-as-group). Returns the ids of tiles the drag should carry along (a
    /// frame carries the tiles it contains); the dragged tile itself is implicit.
    /// Defaults to none, so a plain drag moves only the dragged tile.
    func groupMembers(forDraggedTileID id: Int) -> [Int]

    /// The tiles that would belong to `id` if its world frame were `worldRect` —
    /// the same grouping rule as ``groupMembers(forDraggedTileID:)``, asked about a
    /// HYPOTHETICAL rect rather than the stored one (062).
    ///
    /// A resize changes a frame's membership, and the renderer needs to show which
    /// tiles will be inside *before* the user lets go. It deliberately asks the
    /// provider rather than re-deriving containment itself: the two answers must
    /// never drift, or the highlight would promise something the drop doesn't
    /// deliver. Defaults to none.
    func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int]
}

public extension TileProvider {
    func badge(for tile: Tile) -> TileBadge? { nil }
    func content(for tile: Tile) -> TileContent { .image }
    func groupMembers(forDraggedTileID id: Int) -> [Int] { [] }
    func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int] { [] }
}

/// A small glyph the renderer overlays on a tile to signal something about its
/// asset (kept minimal + renderer-agnostic; the app maps asset kind → badge).
public enum TileBadge: Sendable {
    /// A ▶ play badge — the tile's asset is a video.
    case play
}
