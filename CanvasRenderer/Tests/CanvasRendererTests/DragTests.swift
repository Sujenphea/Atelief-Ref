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
        // Still exactly one highlight, and it stays visible.
        #expect(engine.isSelectionHighlightVisible)
        #expect(engine.selectionHighlightCount == 1)
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

// MARK: - Move snapping (062)

@MainActor
@Suite("Drag snapping (062)")
struct DragSnappingTests {

    private struct Provider: TileProvider {
        let tiles: [Tile]
        let groups: [Int: [Int]]
        func groupMembers(forDraggedTileID id: Int) -> [Int] { groups[id] ?? [] }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// Tile 0 at x ∈ [0, 100]; a stationary neighbour (tile 1) at x ∈ [200, 300].
    /// Tile 2 rides along with tile 0 when it is dragged.
    private func engine(groups: [Int: [Int]] = [:]) -> CanvasEngine {
        let tiles = [
            Tile(id: 0, x: 0, y: 0, w: 100, h: 100, z: 0),
            Tile(id: 1, x: 200, y: 0, w: 100, h: 100, z: 0),
            Tile(id: 2, x: 0, y: 400, w: 100, h: 100, z: 0),
        ]
        let e = CanvasEngine(
            provider: Provider(tiles: tiles, groups: groups), images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        return e
    }

    @Test("a dragged tile's edge snaps to a neighbour and raises a guide")
    func dragSnapsToNeighbour() {
        let e = engine()
        e.beginDrag(tileID: 0)
        // Move 197 right: tile 0's maxX lands at 297, three short of the neighbour's
        // maxX (300). The snap closes the gap.
        e.updateDrag(byScreenDelta: CGSize(width: 197, height: 0))
        #expect(e.currentDragOrigins().first?.worldOrigin.x == 200)
        #expect(!e.snapGuides.isEmpty)
    }

    @Test("⌘ (snapping off) lands exactly where the cursor says")
    func commandDisablesDragSnapping() {
        let e = engine()
        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 197, height: 0), snapping: false)
        #expect(e.currentDragOrigins().first?.worldOrigin.x == 197)
        #expect(e.snapGuides.isEmpty)
    }

    @Test("a tile far from anything is never nudged")
    func farDragIsUntouched() {
        let e = engine()
        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 900, height: 900))
        #expect(e.currentDragOrigins().first?.worldOrigin.x == 900)
        #expect(e.snapGuides.isEmpty)
    }

    @Test("a group snaps as ONE bounding box, so it can't tear itself apart")
    func groupSnapsAsAWhole() {
        // Tile 2 rides with tile 0. Both must take the SAME offset — if members
        // snapped individually their relative positions would drift every drag.
        let e = engine(groups: [0: [2]])
        e.beginDrag(tileID: 0, alsoCarry: [2])
        e.updateDrag(byScreenDelta: CGSize(width: 197, height: 0))

        let origins = Dictionary(
            uniqueKeysWithValues: e.currentDragOrigins().map { ($0.tileID, $0.worldOrigin) })
        #expect(origins[0]?.x == origins[2]?.x)   // same offset, relative layout intact
    }

    @Test("a drag never snaps to a tile it is carrying")
    func neverSnapsToItsOwnGroup() {
        // With tile 1 carried too, nothing stationary is left in range, so the drag
        // must be obeyed exactly — a carried tile moves with you and can't be a target.
        let e = engine(groups: [0: [1]])
        e.beginDrag(tileID: 0, alsoCarry: [1])
        e.updateDrag(byScreenDelta: CGSize(width: 197, height: 0))
        #expect(e.currentDragOrigins().first?.worldOrigin.x == 197)
    }

    @Test("guides clear when the drag ends")
    func guidesClearOnEndDrag() {
        let e = engine()
        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 197, height: 0))
        #expect(!e.snapGuides.isEmpty)
        _ = e.endDrag()
        #expect(e.snapGuides.isEmpty)
    }
}
