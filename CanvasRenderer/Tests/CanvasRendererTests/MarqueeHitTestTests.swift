import CoreGraphics
import Foundation
import Testing
@testable import CanvasRenderer

/// The canvas marquee's pure halves (049 · D2 / D14 / PR 2), mirroring the grid's
/// `MarqueeMathTests`:
///
///  • `CanvasEngine.tiles(inWorldRect:)` — the world-space hit-test over ALL
///    provider tiles (offscreen included, z-independent, degenerate excluded), with
///    the same strict-area / inclusive-degenerate boundary rule the grid uses.
///  • `CanvasHostView.marqueeAutoPanVelocity` — the edge auto-pan velocity ramp
///    (zero in the clear, signed toward the penetrated edge, clamped at maxSpeed).
///
/// Both are exercised without a window — the point of splitting them out.
@MainActor
@Suite("Canvas marquee hit-test + auto-pan (049 · PR 2)")
struct MarqueeHitTestTests {
    private struct FixedProvider: TileProvider {
        let tiles: [Tile]
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    // Three 200×200 tiles spaced 20pt apart on a row (world == screen at identity).
    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    private func engine(_ tiles: [Tile]) -> CanvasEngine {
        CanvasEngine(
            provider: FixedProvider(tiles: tiles), images: NoImages(),
            transform: CanvasTransform(), viewportSize: CGSize(width: 1_000, height: 1_000))
    }

    // MARK: - tiles(inWorldRect:)

    @Test("a box overlapping the first two tiles hits exactly those two")
    func overlapsTwo() {
        let e = engine(row)
        // x∈[100, 300] straddles tile 0 (0–200) and tile 1 (220–420), misses tile 2.
        #expect(e.tiles(inWorldRect: CGRect(x: 100, y: 50, width: 200, height: 50)) == [0, 1])
    }

    @Test("a box in a gap between tiles hits nothing")
    func gapHitsNothing() {
        let e = engine(row)
        // x∈[205, 215] sits in the 20pt gutter between tile 0 and tile 1.
        #expect(e.tiles(inWorldRect: CGRect(x: 205, y: 50, width: 10, height: 50)).isEmpty)
    }

    @Test("a box enclosing the whole row hits every tile")
    func enclosesAll() {
        let e = engine(row)
        #expect(e.tiles(inWorldRect: CGRect(x: -10, y: -10, width: 700, height: 300)) == [0, 1, 2])
    }

    @Test("a box whose edge merely touches a tile edge does NOT sweep it (strict)")
    func strictEdgeNotSwept() {
        let e = engine(row)
        // Right edge lands exactly on tile 1's left edge (x = 220): strict overlap
        // excludes tile 1; tile 0 is genuinely overlapped.
        #expect(e.tiles(inWorldRect: CGRect(x: 100, y: 50, width: 120, height: 50)) == [0])
    }

    @Test("a zero-area box (a click) selects the tile it lands inside (inclusive)")
    func degenerateBoxLandsInside() {
        let e = engine(row)
        // Zero-size rect inside tile 1 — the degenerate path is edge-inclusive so a
        // precise point still registers its tile.
        #expect(e.tiles(inWorldRect: CGRect(x: 300, y: 100, width: 0, height: 0)) == [1])
    }

    @Test("the hit-test is z-independent — stacking order never gates a hit")
    func zIndependent() {
        let stacked = [
            Tile(id: 0, x: 0, y: 0, w: 100, h: 100, z: 99),
            Tile(id: 1, x: 40, y: 40, w: 100, h: 100, z: -5),
        ]
        let e = engine(stacked)
        // A box over both hits both regardless of the wildly different z's.
        #expect(e.tiles(inWorldRect: CGRect(x: 10, y: 10, width: 120, height: 120)) == [0, 1])
    }

    @Test("offscreen tiles are still hit — the test is viewport-independent")
    func offscreenIncluded() {
        // A tile far outside the 1000×1000 viewport; a click-through visible-only
        // test would miss it, but the marquee hit-test spans the whole world.
        let far = row + [Tile(id: 3, x: 5_000, y: 5_000, w: 200, h: 200, z: 0)]
        let e = engine(far)
        #expect(e.tiles(inWorldRect: CGRect(x: 4_900, y: 4_900, width: 400, height: 400)) == [3])
    }

    @Test("degenerate tiles are excluded even when inside the box")
    func degenerateTileExcluded() {
        let withBad = [
            Tile(id: 0, x: 0, y: 0, w: 100, h: 100, z: 0),
            Tile(id: 1, x: 10, y: 10, w: 0, h: 50, z: 0),   // zero width → degenerate
            Tile(id: 2, x: 20, y: 20, w: 50, h: -3, z: 0),  // negative height → degenerate
        ]
        let e = engine(withBad)
        #expect(e.tiles(inWorldRect: CGRect(x: -10, y: -10, width: 200, height: 200)) == [0])
    }

    @Test("a box entirely clear of every tile hits nothing")
    func clearOfAll() {
        let e = engine(row)
        #expect(e.tiles(inWorldRect: CGRect(x: 0, y: 500, width: 640, height: 100)).isEmpty)
    }

    // MARK: - marqueeAutoPanVelocity

    private let viewport = CGSize(width: 800, height: 600)

    @Test("the pointer clear of every edge yields zero velocity")
    func autoPanCenterZero() {
        #expect(CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 400, y: 300), in: viewport) == .zero)
    }

    @Test("near the left / top edges the pan is POSITIVE (world extends toward origin)")
    func autoPanLeftTopPositive() {
        let left = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 5, y: 300), in: viewport)
        #expect(left.width > 0)
        #expect(left.height == 0)
        let top = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 400, y: 5), in: viewport)
        #expect(top.height > 0)
        #expect(top.width == 0)
    }

    @Test("near the right / bottom edges the pan is NEGATIVE (world extends away)")
    func autoPanRightBottomNegative() {
        let right = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 795, y: 300), in: viewport)
        #expect(right.width < 0)
        let bottom = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 400, y: 595), in: viewport)
        #expect(bottom.height < 0)
    }

    @Test("a corner pans on BOTH axes at once")
    func autoPanCornerBothAxes() {
        let v = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 4, y: 4), in: viewport)
        #expect(v.width > 0)
        #expect(v.height > 0)
    }

    @Test("velocity ramps with penetration and clamps at maxSpeed")
    func autoPanRampAndClamp() {
        // Just inside the zone → near minSpeed; hard against the edge → maxSpeed.
        let shallow = CanvasHostView.marqueeAutoPanVelocity(
            pointer: CGPoint(x: CanvasHostView.autoPanEdgeZone - 1, y: 300), in: viewport).width
        let deep = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: 0, y: 300), in: viewport).width
        #expect(shallow > 0)
        #expect(shallow < deep)
        #expect(Approx.equal(deep, CanvasHostView.autoPanMaxSpeed))
        // Past the edge entirely (negative coord) stays clamped, never exceeds max.
        let past = CanvasHostView.marqueeAutoPanVelocity(pointer: CGPoint(x: -50, y: 300), in: viewport).width
        #expect(Approx.equal(past, CanvasHostView.autoPanMaxSpeed))
    }
}
