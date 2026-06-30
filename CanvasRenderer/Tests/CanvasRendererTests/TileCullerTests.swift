import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("TileCuller")
struct TileCullerTests {
    let culler = TileCuller()
    // A 100×100 world viewport at the origin, used by most cases.
    let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test("empty input yields no visible tiles")
    func emptyInput() {
        #expect(culler.visibleTiles(in: [], worldViewport: viewport).isEmpty)
    }

    @Test("a zero-area viewport yields no visible tiles")
    func zeroViewport() {
        let tiles = [Tile(id: 1, x: 0, y: 0, w: 10, h: 10)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: CGRect(x: 0, y: 0, width: 0, height: 100)).isEmpty)
    }

    @Test("a fully-contained tile is visible")
    func fullyContained() {
        let tiles = [Tile(id: 1, x: 25, y: 25, w: 10, h: 10)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).map(\.id) == [1])
    }

    @Test("a tile straddling the edge is visible")
    func straddling() {
        let tiles = [Tile(id: 1, x: 90, y: 40, w: 40, h: 20)] // extends past right edge
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).map(\.id) == [1])
    }

    @Test("a fully-outside tile is not visible")
    func fullyOutside() {
        let tiles = [Tile(id: 1, x: 500, y: 500, w: 10, h: 10)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).isEmpty)
    }

    @Test("a tile only touching the edge (zero-area overlap) is not visible")
    func touchingEdgeOnly() {
        // Right edge of viewport is x=100; this tile starts exactly at x=100.
        let tiles = [Tile(id: 1, x: 100, y: 0, w: 10, h: 10)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).isEmpty)
    }

    @Test("a tile that contains the whole viewport (zoomed in) is visible")
    func tileContainsViewport() {
        let tiles = [Tile(id: 1, x: -1000, y: -1000, w: 5000, h: 5000)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).map(\.id) == [1])
    }

    @Test("degenerate tiles are excluded even if their origin is inside the viewport")
    func degenerateExcluded() {
        let tiles = [
            Tile(id: 1, x: 10, y: 10, w: 0, h: 50),   // zero width
            Tile(id: 2, x: 10, y: 10, w: 20, h: 20),  // valid
        ]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).map(\.id) == [2])
    }

    @Test("results are ordered by z ascending, ties broken by id")
    func drawOrder() {
        let tiles = [
            Tile(id: 3, x: 0, y: 0, w: 10, h: 10, z: 5),
            Tile(id: 1, x: 0, y: 0, w: 10, h: 10, z: 1),
            Tile(id: 2, x: 0, y: 0, w: 10, h: 10, z: 1),
            Tile(id: 4, x: 0, y: 0, w: 10, h: 10, z: 5),
        ]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).map(\.id) == [1, 2, 3, 4])
    }

    @Test("a positive margin admits just-offscreen tiles (prefetch ring)")
    func marginPrefetch() {
        // 20×20 tile sitting 10 world units past the right edge — outside the
        // viewport, but inside a 25-unit prefetch margin.
        let tiles = [Tile(id: 1, x: 110, y: 40, w: 20, h: 20)]
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport).isEmpty)
        #expect(culler.visibleTiles(in: tiles, worldViewport: viewport, margin: 25).map(\.id) == [1])
    }

    // A deterministic grid lets us assert the *exact* visible set (decision T12).
    @Test("over a known grid, exactly the intersecting cells are returned")
    func knownGrid() {
        // 10×10 grid of 8×8 tiles spaced every 10 units, ids 0..99 (row-major).
        var tiles: [Tile] = []
        for row in 0..<10 {
            for col in 0..<10 {
                tiles.append(Tile(id: row * 10 + col, x: Double(col) * 10, y: Double(row) * 10, w: 8, h: 8))
            }
        }
        // Viewport covering cols 2–4 and rows 1–3 (world 20..49 in both axes,
        // but tiles are 8 wide so col 5 at x=50 won't intersect x<50).
        let vp = CGRect(x: 20, y: 10, width: 30, height: 30)
        let ids = Set(culler.visibleTiles(in: tiles, worldViewport: vp).map(\.id))
        var expected = Set<Int>()
        for row in 1...3 {
            for col in 2...4 {
                expected.insert(row * 10 + col)
            }
        }
        #expect(ids == expected)
    }
}
