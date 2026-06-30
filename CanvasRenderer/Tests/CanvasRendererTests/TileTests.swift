import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("Tile")
struct TileTests {
    @Test("worldFrame reflects x/y/w/h")
    func worldFrame() {
        let tile = Tile(id: 1, x: 10, y: 20, w: 30, h: 40, z: 2)
        #expect(tile.worldFrame == CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    @Test("longestWorldEdge is the larger dimension")
    func longestEdge() {
        #expect(Tile(id: 1, x: 0, y: 0, w: 30, h: 40).longestWorldEdge == 40)
        #expect(Tile(id: 2, x: 0, y: 0, w: 90, h: 40).longestWorldEdge == 90)
    }

    @Test("a well-formed tile is not degenerate")
    func validNotDegenerate() {
        #expect(Tile(id: 1, x: -5, y: -5, w: 1, h: 1).isDegenerate == false)
    }

    // Degenerate inputs the culler must drop (decision C7).
    @Test("degenerate geometry is detected", arguments: [
        (0.0, 10.0),    // zero width
        (10.0, 0.0),    // zero height
        (-1.0, 10.0),   // negative width
        (10.0, -1.0),   // negative height
    ] as [(Double, Double)])
    func degenerateSizes(w: Double, h: Double) {
        #expect(Tile(id: 1, x: 0, y: 0, w: w, h: h).isDegenerate)
    }

    @Test("non-finite geometry is degenerate")
    func nonFinite() {
        #expect(Tile(id: 1, x: .nan, y: 0, w: 10, h: 10).isDegenerate)
        #expect(Tile(id: 2, x: 0, y: .infinity, w: 10, h: 10).isDegenerate)
        #expect(Tile(id: 3, x: 0, y: 0, w: .infinity, h: 10).isDegenerate)
    }
}
