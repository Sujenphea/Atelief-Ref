import CoreGraphics

/// A single placeable item on the canvas, in **world space**.
///
/// The fields mirror the real `CollectionItem` canvas placement columns
/// (`canvas_x/y/w/h/z`) exactly (decision A4), so at build-order step 5 a real
/// data-backed ``TileProvider`` maps straight onto this type with no reshaping.
///
/// `id` stands in for the membership/asset identity; the renderer uses it as the
/// key for image lookup and decode caching.
public struct Tile: Equatable, Sendable, Identifiable {
    public let id: Int
    /// World-space origin x (mirrors `canvas_x`).
    public let x: Double
    /// World-space origin y (mirrors `canvas_y`).
    public let y: Double
    /// World-space width (mirrors `canvas_w`).
    public let w: Double
    /// World-space height (mirrors `canvas_h`).
    public let h: Double
    /// Stacking order; lower draws first (mirrors `canvas_z`).
    public let z: Int

    public init(id: Int, x: Double, y: Double, w: Double, h: Double, z: Int = 0) {
        self.id = id
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.z = z
    }

    /// The tile's world-space rectangle.
    public var worldFrame: CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// The longest world-space edge — the basis for LOD selection once scaled to
    /// screen (see ``LODPolicy``).
    public var longestWorldEdge: Double {
        max(w, h)
    }

    /// True when the tile cannot be drawn: non-positive or non-finite geometry
    /// (decision C7). Degenerate tiles are dropped by the ``TileCuller`` rather
    /// than allowed to corrupt layout or crash.
    public var isDegenerate: Bool {
        guard w > 0, h > 0 else { return true }
        return !x.isFinite || !y.isFinite || !w.isFinite || !h.isFinite
    }
}
