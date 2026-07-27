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

    @Test("a selected IMAGE tile shows none — only text can be resized")
    func selectedImageShowsNoHandles() {
        let e = engine()
        e.setSelected(1)
        #expect(e.resizeHandleCount == 0)
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 400, y: 0)) == nil)
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
        // The right handle sits on the LIVE edge, not the stored one.
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 500, y: 100))?.handle == .right)
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
}
