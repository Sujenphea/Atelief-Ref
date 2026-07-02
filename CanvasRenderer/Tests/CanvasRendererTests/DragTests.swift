import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

/// Canvas drag-to-place: a live drag offsets ONLY the dragged tile's on-screen
/// frame by exactly the screen delta (leaving others put), and `endDrag()`
/// reports the tile's final world origin as `stored origin + screenDelta/scale`.
/// The sign/orientation is pinned explicitly (positive screen delta ⇒ positive
/// world delta — uniform positive scale, no y-flip in the transform). Plus the
/// pure click-vs-drag threshold. No window needed — pure layer/geometry math.
@MainActor
@Suite("Canvas drag-to-place")
struct DragTests {
    private struct FixedProvider: TileProvider {
        let tiles: [Tile]
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    // Three 200×200 world tiles in a row.
    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    // A non-identity transform (scale 2, offset translation) so the
    // screen→world division is actually exercised, not hidden by scale == 1.
    private func makeEngine() -> CanvasEngine {
        CanvasEngine(
            provider: FixedProvider(tiles: row), images: NoImages(),
            transform: CanvasTransform(scale: 2, translation: CGPoint(x: 50, y: 30)),
            viewportSize: CGSize(width: 4_000, height: 4_000))
    }

    @Test("dragged tile's on-screen frame moves by exactly the screen delta")
    func draggedTileFollowsScreenDelta() {
        let engine = makeEngine()
        engine.sync()
        let before = engine.currentScreenFrame(forTileID: 1)!

        let screenDelta = CGSize(width: 60, height: -40)
        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: screenDelta)

        let after = engine.currentScreenFrame(forTileID: 1)!
        #expect(Approx.equal(
            after.origin,
            CGPoint(x: before.origin.x + screenDelta.width,
                    y: before.origin.y + screenDelta.height)))
        // Size is unchanged — a move, not a resize.
        #expect(Approx.equal(after.size.width, before.size.width))
        #expect(Approx.equal(after.size.height, before.size.height))
    }

    @Test("non-dragged tiles do not move during a drag")
    func othersStayPut() {
        let engine = makeEngine()
        engine.sync()
        let before0 = engine.currentScreenFrame(forTileID: 0)!
        let before2 = engine.currentScreenFrame(forTileID: 2)!

        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: CGSize(width: 60, height: -40))

        #expect(Approx.equal(engine.currentScreenFrame(forTileID: 0)!, before0))
        #expect(Approx.equal(engine.currentScreenFrame(forTileID: 2)!, before2))
    }

    @Test("endDrag returns final world origin = stored origin + screenDelta/scale")
    func endDragWorldOrigin() {
        let engine = makeEngine()
        let scale = engine.transform.scale // 2
        let screenDelta = CGSize(width: 60, height: -40)

        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: screenDelta)
        let result = engine.endDrag()

        #expect(result?.tileID == 1)
        // Stored origin (220, 0) + (60/2, -40/2) = (250, -20). Positive screen
        // delta ⇒ positive world delta (sign is direct, no y-flip in transform).
        #expect(Approx.equal(
            result!.worldOrigin,
            CGPoint(x: 220 + screenDelta.width / scale,
                    y: 0 + screenDelta.height / scale)))
    }

    @Test("endDrag clears drag state and does not move the tile back")
    func endDragClearsOffset() {
        let engine = makeEngine()
        engine.sync()
        let before = engine.currentScreenFrame(forTileID: 1)!

        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: CGSize(width: 60, height: -40))
        _ = engine.endDrag()
        // With the provider unchanged and the offset cleared, a fresh sync draws
        // the tile at its ORIGINAL screen frame (the host mutates the provider
        // between endDrag and sync in the real path; here we verify the offset
        // truly cleared rather than snapping the tile elsewhere).
        engine.sync()
        #expect(Approx.equal(engine.currentScreenFrame(forTileID: 1)!, before))
    }

    @Test("endDrag with nothing dragging returns nil")
    func endDragNilWhenIdle() {
        let engine = makeEngine()
        #expect(engine.endDrag() == nil)
    }

    @Test("the selection highlight follows the dragged tile")
    func highlightFollowsDrag() {
        let engine = makeEngine()
        engine.setSelected(1)
        engine.sync()
        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: CGSize(width: 60, height: -40))
        // Still exactly one highlight (3 tiles + 1), and it stays visible.
        #expect(engine.isSelectionHighlightVisible)
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 4)
    }

    @Test("hit-testing tracks the dragged tile's live position")
    func hitTestFollowsDrag() {
        let engine = makeEngine()
        engine.sync()
        // Tile 1 at world (220,0,200,200) → screen origin (490, 30), size 400.
        // A point just inside its bottom-right corner before the drag.
        let probe = CGPoint(x: 880, y: 420)
        #expect(engine.tile(atScreenPoint: probe)?.id == 1)

        engine.beginDrag(tileID: 1)
        engine.updateDrag(byScreenDelta: CGSize(width: 400, height: 0))
        // The tile moved 400 pt right; the old probe point is now empty space.
        #expect(engine.tile(atScreenPoint: probe)?.id != 1)
        // …and a point 400 pt to the right now hits it.
        #expect(engine.tile(atScreenPoint: CGPoint(x: probe.x + 400, y: probe.y))?.id == 1)
    }

    @Test("click-vs-drag threshold: tiny moves are clicks, larger ones drags")
    func dragThreshold() {
        #expect(CanvasHostView.exceedsDragThreshold(CGSize(width: 2, height: 2)) == false)
        #expect(CanvasHostView.exceedsDragThreshold(CGSize(width: 0, height: 3)) == false)
        #expect(CanvasHostView.exceedsDragThreshold(CGSize(width: 0, height: 4)))
        #expect(CanvasHostView.exceedsDragThreshold(CGSize(width: -5, height: 0)))
    }
}
