//
//  EngineResizeTests.swift
//  CanvasRendererTests
//
//  062 — the engine half of resizing: who gets handles, where a press lands, and
//  what the tile is drawn at mid-drag. `ResizeHandleTests` covers the arithmetic;
//  these cover the policy and the live-drag state machine.
//
//  The policy exists to keep a handle from ever appearing where it would lie:
//  handles are shown only on a SINGLE selected TEXT tile, because text is the one
//  kind whose box the app can re-derive after a width change.
//

import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Engine resize handles (062)")
struct EngineResizeTests {

    private struct VectorProvider: TileProvider {
        let tiles: [Tile]
        var texts: [Int: TextStyle] = [:]

        func content(for tile: Tile) -> TileContent {
            if let style = texts[tile.id] { return .text(style) }
            return .image
        }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// Tile 0 is TEXT, tile 1 is an IMAGE — so every test can contrast the two.
    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 300, h: 200, z: 0),
        Tile(id: 1, x: 400, y: 0, w: 300, h: 200, z: 0),
    ]

    private func provider() -> VectorProvider {
        VectorProvider(
            tiles: row,
            texts: [0: TextStyle(string: "Hello", fontSize: 18,
                                 color: RGBAColor(red: 0, green: 0, blue: 0))])
    }

    private func engine(scale: CGFloat = 1) -> CanvasEngine {
        let e = CanvasEngine(
            provider: provider(), images: NoImages(),
            transform: CanvasTransform(scale: scale, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        return e
    }

    // MARK: - Who gets handles

    @Test("no selection means no handles")
    func noSelectionNoHandles() {
        let e = engine()
        #expect(e.resizeHandleCount == 0)
        #expect(e.resizeHandle(atScreenPoint: .zero) == nil)
    }

    @Test("a selected TEXT tile shows all eight handles")
    func selectedTextShowsHandles() {
        let e = engine()
        e.setSelected(0)
        #expect(e.resizeHandleCount == 8)
    }

    @Test("a selected IMAGE tile shows handles too")
    func selectedImageShowsHandles() {
        let e = engine()
        e.setSelected(1)
        #expect(e.resizeHandleCount == 8)
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 400, y: 0))?.handle == .topLeft)
    }

    @Test("an image keeps its aspect ratio with no modifier held")
    func imageLocksItsAspect() {
        let e = engine()          // tile 1 is a 300×200 image — ratio 1.5
        e.setSelected(1)
        e.beginResize(tileID: 1, handle: .bottomRight)
        // Drag to a point whose free-resize result would be square.
        e.updateResize(toWorldPoint: CGPoint(x: 700, y: 300), snapping: false)
        let frame = e.currentResizeFrame()?.worldFrame
        let ratio = (frame?.width ?? 0) / max(frame?.height ?? 1, 0.0001)
        #expect(abs(ratio - 1.5) < 0.001)   // never distorted
    }

    @Test("a text box does NOT lock its aspect — its height is the text's")
    func textDoesNotLockAspect() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .bottomRight)
        e.updateResize(toWorldPoint: CGPoint(x: 700, y: 900), snapping: false)
        let frame = e.currentResizeFrame()?.worldFrame
        // Width followed the cursor; height came from the wrapped text, so the
        // original 300×200 ratio is emphatically not preserved.
        #expect(frame?.width == 700)
        #expect((frame?.height ?? 0) < 200)
    }

    @Test("a multi-selection shows none, even when it includes the text tile")
    func multiSelectionShowsNoHandles() {
        let e = engine()
        e.setSelected([0, 1])
        #expect(e.resizeHandleCount == 0)
    }

    @Test("deselecting drops the handles again")
    func deselectDropsHandles() {
        let e = engine()
        e.setSelected(0)
        #expect(e.resizeHandleCount == 8)
        e.setSelected(nil)
        #expect(e.resizeHandleCount == 0)
    }

    @Test("a tile that leaves the viewport drops its handles")
    func offscreenDropsHandles() {
        let e = engine()
        e.setSelected(0)
        #expect(e.resizeHandleCount == 8)
        // Pan the text tile far off-screen.
        e.setTransform(CanvasTransform(scale: 1, translation: CGPoint(x: -50_000, y: 0)))
        #expect(e.resizeHandleCount == 0)
    }

    // MARK: - Hit-testing through the transform

    @Test("a press on the selected text tile's corner resolves to that handle")
    func cornerPressResolves() {
        let e = engine()
        e.setSelected(0)
        let hit = e.resizeHandle(atScreenPoint: CGPoint(x: 0, y: 0))
        #expect(hit?.tileID == 0)
        #expect(hit?.handle == .topLeft)
    }

    @Test("the grab zone stays the same SCREEN size when zoomed out")
    func grabZoneIsScreenSized() {
        // At 0.1× the 300pt-wide box is 30pt on screen. A world-space grab zone would
        // shrink with it and become unhittable; a screen-space one does not. This is
        // the regression the world-vs-screen split exists to prevent.
        let e = engine(scale: 0.1)
        e.setSelected(0)
        let nearCorner = CGPoint(x: 5, y: 5) // 50 world units away — but 5 SCREEN points
        #expect(e.resizeHandle(atScreenPoint: nearCorner)?.handle == .topLeft)
    }

    @Test("a press in the tile's interior is not a handle")
    func interiorIsNotAHandle() {
        let e = engine()
        e.setSelected(0)
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 150, y: 100)) == nil)
    }

    // MARK: - The live-drag state machine

    @Test("a resize changes the drawn frame without touching the provider")
    func liveResizeLeavesProviderAlone() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 500, y: 0))

        // The tile is DRAWN at the new width...
        #expect(e.currentScreenFrame(forTileID: 0)?.width == 500)
        #expect(e.currentResizeFrame()?.worldFrame.width == 500)
        // ...but the provider still reports the stored geometry, exactly as a drag does.
        #expect(e.currentVisibleTiles().first { $0.id == 0 }?.w == 300)
    }

    @Test("each update recomputes from the START frame, so a resize cannot drift")
    func updatesDoNotAccumulate() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        for x in [400.0, 450, 500, 480, 460] {
            e.updateResize(toWorldPoint: CGPoint(x: x, y: 0))
        }
        // The final frame depends ONLY on the final cursor position — not on the path
        // taken to get there.
        #expect(e.currentResizeFrame()?.worldFrame.width == 460)
    }

    @Test("handles follow the box live while it is being resized")
    func handlesFollowTheLiveFrame() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 500, y: 0))
        #expect(e.resizeHandleCount == 8)
        // The right handle sits on the LIVE edge, not the stored one. Its y comes
        // from the live frame too: the height is DERIVED from the wrapped text
        // (062), so the box is nothing like the 200pt the provider stores.
        let live = try? #require(e.currentResizeFrame()?.worldFrame)
        #expect(e.resizeHandle(
            atScreenPoint: CGPoint(x: 500, y: live?.midY ?? 0))?.handle == .right)
    }

    @Test("the live height is the text's, not the pointer's — a vertical drag is inert")
    func verticalDragDoesNotSetHeight() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .bottom)
        e.updateResize(toWorldPoint: CGPoint(x: 0, y: 5_000))
        // Yanking the bottom edge 5000pt down must NOT make the box 5000pt tall:
        // "Hello" needs one line, and that is what the box gets.
        let height = e.currentResizeFrame()?.worldFrame.height ?? 0
        #expect(height > 0)
        #expect(height < 200)
    }

    @Test("ending a resize clears the live frame")
    func endResizeClears() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 500, y: 0))
        e.endResize()
        #expect(e.currentResizeFrame() == nil)
        e.sync()
        #expect(e.currentScreenFrame(forTileID: 0)?.width == 300) // back to the provider's
    }

    @Test("an update without a begin is ignored")
    func updateWithoutBeginIsIgnored() {
        let e = engine()
        e.setSelected(0)
        e.updateResize(toWorldPoint: CGPoint(x: 500, y: 0))
        #expect(e.currentResizeFrame() == nil)
        #expect(e.currentScreenFrame(forTileID: 0)?.width == 300)
    }

    @Test("beginning a resize on an unknown tile is a no-op, not a crash")
    func beginOnUnknownTileIsSafe() {
        let e = engine()
        e.beginResize(tileID: 99, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 500, y: 0))
        #expect(e.currentResizeFrame() == nil)
    }

    // MARK: - Snapping

    @Test("a dragged edge snaps to a neighbour and raises a guide")
    func edgeSnapsToNeighbour() {
        // Tile 1 (the image) starts at x = 400. Drag tile 0's right edge to 398.
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 398, y: 0))
        #expect(e.currentResizeFrame()?.worldFrame.maxX == 400)   // landed exactly
        #expect(e.snapGuides == [SnapGuide(isVertical: true, position: 400)])
    }

    @Test("⌘ (snapping off) obeys the cursor exactly and raises no guide")
    func commandDisablesSnapping() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 398, y: 0), snapping: false)
        #expect(e.currentResizeFrame()?.worldFrame.maxX == 398)
        #expect(e.snapGuides.isEmpty)
    }

    @Test("a box never snaps to itself")
    func neverSnapsToItself() {
        // Tile 0's own right edge is at 300. Dragging it to 299 must NOT stick to
        // 300 — a box that snapped to itself could never be resized by small amounts.
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 299, y: 0))
        #expect(e.currentResizeFrame()?.worldFrame.maxX == 299)
    }

    @Test("guides clear when the resize ends")
    func guidesClearOnEnd() {
        let e = engine()
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 398, y: 0))
        #expect(!e.snapGuides.isEmpty)
        e.endResize()
        #expect(e.snapGuides.isEmpty)
    }

    @Test("the snap radius follows the zoom, not the world")
    func snapRadiusFollowsZoom() {
        // 20 world units from the target: out of reach at 1× (6pt ⇒ 6 world), but
        // well within it at 0.1× (6pt ⇒ 60 world).
        let near = engine(scale: 1)
        near.setSelected(0)
        near.beginResize(tileID: 0, handle: .right)
        near.updateResize(toWorldPoint: CGPoint(x: 380, y: 0))
        #expect(near.currentResizeFrame()?.worldFrame.maxX == 380)   // no snap

        let far = engine(scale: 0.1)
        far.setSelected(0)
        far.beginResize(tileID: 0, handle: .right)
        far.updateResize(toWorldPoint: CGPoint(x: 380, y: 0))
        #expect(far.currentResizeFrame()?.worldFrame.maxX == 400)    // snapped
    }
}

// MARK: - What is actually DRAWN mid-drag (the live-chrome regressions)

@MainActor
@Suite("Engine resize — live chrome (062)")
struct EngineResizeLiveChromeTests {

    private struct VectorProvider: TileProvider {
        let tiles: [Tile]
        var texts: [Int: TextStyle] = [:]
        func content(for tile: Tile) -> TileContent {
            if let style = texts[tile.id] { return .text(style) }
            return .image
        }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// One wide text tile holding a string long enough that its wrapping visibly
    /// depends on the box width.
    private func engine() -> CanvasEngine {
        let provider = VectorProvider(
            tiles: [Tile(id: 0, x: 0, y: 0, w: 400, h: 200, z: 0)],
            texts: [0: TextStyle(
                string: "The quick brown fox jumps over the lazy dog again and again",
                fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0))])
        let e = CanvasEngine(
            provider: provider, images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        e.setSelected(0)
        return e
    }

    @Test("the handle dots are DRAWN at the live box, not the stored one")
    func handleDotsFollowTheLiveBox() {
        let e = engine()
        let before = e.resizeHandlePositions
        #expect(before[.right]?.x == 400)

        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 250, y: 0))

        let during = e.resizeHandlePositions
        // Every handle that owns the right edge must have moved with it.
        #expect(during[.right]?.x == 250)
        #expect(during[.topRight]?.x == 250)
        #expect(during[.bottomRight]?.x == 250)
        // The left edge is anchored, and the top/bottom midpoints re-centre.
        #expect(during[.left]?.x == 0)
        #expect(during[.top]?.x == 125)
    }

    @Test("the text re-wraps to the live width while the box is being resized")
    func textReflowsDuringResize() {
        let e = engine()
        let wide = e.textLayer(forTileID: 0)?.shaped
        let wideLines = wide?.lines.count ?? 0
        #expect(wideLines > 0)

        // Narrow the box hard: the same string must wrap onto more lines, live.
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 120, y: 0))

        let narrow = e.textLayer(forTileID: 0)?.shaped
        #expect((narrow?.lines.count ?? 0) > wideLines)
        // And the shaping key must have actually changed — not merely been redrawn.
        #expect(narrow?.key != wide?.key)
    }

    @Test("the text layer's frame follows the live box too")
    func textLayerFrameFollowsTheLiveBox() {
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 250, y: 0))
        let frame = e.textLayer(forTileID: 0)?.frame
        // Inset by the world padding on both edges (scale 1).
        #expect(frame?.width == 250 - 2 * TextMetrics.padding)
    }

    @Test("ending the resize returns the chrome and the wrap to the provider's box")
    func endingRestoresStoredGeometry() {
        let e = engine()
        let stored = e.textLayer(forTileID: 0)?.shaped?.key
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 120, y: 0))
        e.endResize()
        e.sync()
        #expect(e.resizeHandlePositions[.right]?.x == 400)
        #expect(e.textLayer(forTileID: 0)?.shaped?.key == stored)
    }
}
