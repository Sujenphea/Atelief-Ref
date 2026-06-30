import CoreGraphics

/// Viewport culling: selects the tiles that actually intersect the visible
/// world rect, so the host only realizes layers for what's on screen.
///
/// Pure and headless (decision C5) — exact inputs, exact outputs — which is what
/// lets Checkpoint 2 unit-test its boundary behaviour against known sets.
///
/// For the spike's ~5k tiles a straight O(n) scan per frame is sub-millisecond,
/// so there's no spatial index yet (deliberately not over-engineered); the
/// Checkpoint 6 benchmark is the signal for whether one is ever needed.
public struct TileCuller {
    public init() {}

    /// Tiles intersecting `worldViewport`, expanded by `margin` world units,
    /// returned in draw order (`z` ascending, ties broken by `id`).
    ///
    /// Behaviour at the edges (decision C7):
    /// - Degenerate tiles (see ``Tile/isDegenerate``) are excluded.
    /// - A zero- or negative-area viewport yields no tiles.
    /// - Tiles that only *touch* the viewport edge (zero-area overlap) are **not**
    ///   considered visible — they contribute no pixels.
    /// - A tile that fully contains the viewport (zoomed in) **is** visible.
    ///
    /// - Parameter margin: world-space inset (negative = expand). Used by the
    ///   host to prefetch a ring of just-offscreen tiles (decision P15).
    public func visibleTiles(
        in tiles: [Tile],
        worldViewport: CGRect,
        margin: CGFloat = 0
    ) -> [Tile] {
        guard worldViewport.width > 0, worldViewport.height > 0 else { return [] }

        let query = margin == 0 ? worldViewport : worldViewport.insetBy(dx: -margin, dy: -margin)
        // insetBy can itself produce a degenerate rect if the margin over-shrinks.
        guard query.width > 0, query.height > 0 else { return [] }

        var visible = tiles.filter { tile in
            !tile.isDegenerate && tile.worldFrame.intersects(query)
        }
        visible.sort { lhs, rhs in
            (lhs.z, lhs.id) < (rhs.z, rhs.id)
        }
        return visible
    }
}
