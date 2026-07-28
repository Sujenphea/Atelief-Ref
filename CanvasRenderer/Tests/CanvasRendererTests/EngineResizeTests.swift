//
//  EngineResizeTests.swift
//  CanvasRendererTests
//
//  062 — the engine half of resizing: who gets handles, where a press lands, and
//  what the tile is drawn at mid-drag. `ResizeHandleTests` covers the arithmetic;
//  these cover the policy and the live-drag state machine.
//
//  Handles show on a SINGLE selected tile of any kind — a multi-selection has no
//  one sensible meaning. What differs per kind is how each answers a new width:
//  text re-derives its height from the re-wrapped glyphs, an image holds its ratio
//  so it can never distort, and a frame takes the rect as given.
//
//  A resizing FRAME also previews its membership, which matters because ours is
//  derived from containment rather than stored: a resize silently changes what is
//  inside, and the preview is what makes that aimable instead of a surprise.
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

// MARK: - Prospective frame membership (062)

@MainActor
@Suite("Engine resize — frame membership preview (062)")
struct EngineFrameMembershipTests {

    /// A provider whose frames own whatever tile CENTRES fall inside them — the same
    /// containment rule the app uses, so the preview is asserted against the real
    /// semantics rather than a stand-in.
    private struct FrameProvider: TileProvider {
        let tiles: [Tile]
        let frameIDs: Set<Int>

        func content(for tile: Tile) -> TileContent {
            frameIDs.contains(tile.id)
                ? .frame(FrameStyle(fill: nil, stroke: nil, strokeWidth: 0, cornerRadius: 0))
                : .image
        }

        func groupMembers(forDraggedTileID id: Int) -> [Int] {
            guard tiles.indices.contains(id) else { return [] }
            return groupMembers(forTileID: id, in: tiles[id].worldFrame)
        }

        func groupMembers(forTileID id: Int, in worldRect: CGRect) -> [Int] {
            guard frameIDs.contains(id) else { return [] }
            return tiles.indices.filter { i in
                i != id && worldRect.contains(CGPoint(x: tiles[i].worldFrame.midX,
                                                      y: tiles[i].worldFrame.midY))
            }
        }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    /// Tile 0 is a frame at 0…200. Tile 1's centre is at x = 250 (outside it);
    /// tile 2's centre is at x = 100 (inside it).
    private func engine() -> CanvasEngine {
        let tiles = [
            Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
            Tile(id: 1, x: 240, y: 80, w: 20, h: 20, z: 1),
            Tile(id: 2, x: 90, y: 90, w: 20, h: 20, z: 1),
        ]
        let e = CanvasEngine(
            provider: FrameProvider(tiles: tiles, frameIDs: [0]), images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        e.setSelected(0)
        return e
    }

    @Test("growing a frame over a neighbour previews it as a member")
    func growingAdoptsNeighbour() {
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        #expect(e.prospectiveMembers == [])          // nothing until the first tick

        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 0), snapping: false)
        // Tile 2 was already inside; tile 1's centre (250) is now enclosed too.
        #expect(e.prospectiveMembers == [1, 2])
    }

    @Test("shrinking a frame away from a member drops it from the preview")
    func shrinkingEvictsMember() {
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 50, y: 0), snapping: false)
        // Tile 2's centre (x = 100) now falls outside the shrunken frame.
        #expect(e.prospectiveMembers == [])
    }

    @Test("the preview tracks the LIVE rect, updating on every tick")
    func previewTracksTheLiveRect() {
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 0), snapping: false)
        #expect(e.prospectiveMembers.contains(1))
        e.updateResize(toWorldPoint: CGPoint(x: 210, y: 0), snapping: false)
        #expect(!e.prospectiveMembers.contains(1))   // pulled back out again
    }

    @Test("resizing a NON-frame previews no membership at all")
    func nonFramePreviewsNothing() {
        let e = engine()
        e.setSelected(1)
        e.beginResize(tileID: 1, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 900, y: 0), snapping: false)
        #expect(e.prospectiveMembers.isEmpty)
    }

    @Test("the preview clears when the resize ends")
    func previewClearsOnEnd() {
        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 0), snapping: false)
        #expect(!e.prospectiveMembers.isEmpty)
        e.endResize()
        #expect(e.prospectiveMembers.isEmpty)
    }

    @Test("the preview agrees with what a later drag would actually carry")
    func previewMatchesTheDragCarry() {
        // The whole point of routing through the provider: the set highlighted mid-
        // resize must equal the set a drag carries once that geometry is committed.
        let grown = [
            Tile(id: 0, x: 0, y: 0, w: 300, h: 200, z: 0),
            Tile(id: 1, x: 240, y: 80, w: 20, h: 20, z: 1),
            Tile(id: 2, x: 90, y: 90, w: 20, h: 20, z: 1),
        ]
        let committed = FrameProvider(tiles: grown, frameIDs: [0])

        let e = engine()
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 0), snapping: false)

        #expect(e.prospectiveMembers == Set(committed.groupMembers(forDraggedTileID: 0)))
    }
}

// MARK: - Overflow (062)

@MainActor
@Suite("Text overflow — a text tile never truncates (062)")
struct EngineTextOverflowTests {

    private struct P: TileProvider {
        let tiles: [Tile]
        var texts: [Int: TextStyle] = [:]
        var frames: [Int: FrameStyle] = [:]
        func content(for tile: Tile) -> TileContent {
            if let s = texts[tile.id] { return .text(s) }
            if let f = frames[tile.id] { return .frame(f) }
            return .image
        }
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private let long = "The quick brown fox jumps over the lazy dog again and again and again and again"

    private func style(_ string: String) -> TextStyle {
        TextStyle(string: string, fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0))
    }

    private func engine(_ provider: P) -> CanvasEngine {
        let e = CanvasEngine(
            provider: provider, images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        return e
    }

    @Test("a text tile whose STORED height is too small still draws every line")
    func staleHeightDoesNotHideText() {
        // The state a row written before 062 is in: a `.fixed`-era height that its
        // text outgrew. Truncating here would hide content the 062 model promises is
        // visible, and the user would have no way to discover it was there.
        let e = engine(P(tiles: [Tile(id: 0, x: 0, y: 0, w: 400, h: 24, z: 0)],
                         texts: [0: style(long)]))
        let drawn = e.textLayer(forTileID: 0)?.shaped
        let full = TextShaper.shape(style(long), maxWidth: 400 - 2 * TextMetrics.padding)
        #expect(drawn?.lines.count == full.lines.count)
        #expect((drawn?.lines.count ?? 0) > 1)   // the box really was too short
    }

    @Test("a frame LABEL still truncates — its box owes nothing to its text")
    func frameLabelStillTruncates() {
        // The contrast that justifies the rule: a frame's box is user-controlled and
        // is NOT derived from its label, so a label too long for it must be cut.
        let e = engine(P(tiles: [Tile(id: 0, x: 0, y: 0, w: 120, h: 24, z: 0)],
                         frames: [0: FrameStyle(fill: nil, stroke: nil, strokeWidth: 0,
                                                cornerRadius: 0, label: style(long))]))
        let drawn = e.textLayer(forTileID: 0)?.shaped
        let full = TextShaper.shape(style(long), maxWidth: 120)
        #expect((drawn?.lines.count ?? 0) < full.lines.count)
    }

    @Test("narrowing a text box grows it and drops no lines")
    func narrowingDropsNoLines() {
        let e = engine(P(tiles: [Tile(id: 0, x: 0, y: 0, w: 400, h: 60, z: 0)],
                         texts: [0: style(long)]))
        e.setSelected(0)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 120, y: 0), snapping: false)

        let drawn = e.textLayer(forTileID: 0)?.shaped
        let full = TextShaper.shape(style(long), maxWidth: 120 - 2 * TextMetrics.padding)
        #expect(drawn?.lines.count == full.lines.count)
        // …and the box grew to hold them, live.
        #expect((e.currentResizeFrame()?.worldFrame.height ?? 0) > 60)
    }
}

// MARK: - Resizing the tile being EDITED (062)

/// The glyph path above is switched OFF for the tile an inline editor owns — its
/// `CATextLayer` is blanked so the `NSTextView` above isn't doubled. So for that
/// one tile, everything the engine draws (box, border, handles) moves with the
/// resize while the text is somebody else's to place. This suite pins the seam
/// that tells them: without it the box narrows and the text, still laid out for
/// the old width, spills straight out of it.
@MainActor
@Suite("Live resize while editing — the app must hear the frame move (062)")
struct EngineEditingResizeTests {

    private struct P: TileProvider {
        let tiles: [Tile]
        var texts: [Int: TextStyle] = [:]
        func content(for tile: Tile) -> TileContent {
            if let s = texts[tile.id] { return .text(s) }
            return .image
        }
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private func editingEngine() -> CanvasEngine {
        let style = TextStyle(string: "The quick brown fox jumps over the lazy dog again and again",
                              fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0))
        let e = CanvasEngine(
            provider: P(tiles: [Tile(id: 0, x: 0, y: 0, w: 400, h: 60, z: 0)], texts: [0: style]),
            images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 1_200, height: 800))
        e.sync()
        e.setSelected(0)
        e.editingTileID = 0
        return e
    }

    @Test("the tile being edited still offers handles, and draws no glyphs of its own")
    func editedTileIsResizableAndBlank() {
        // Both halves matter, and only together: the handles are why a resize can
        // start mid-edit at all, and the blank is why no fix on the glyph path can
        // reach it. Either alone would be harmless.
        let e = editingEngine()
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 400, y: 30))?.handle == .right)
        #expect(e.textLayer(forTileID: 0) == nil)
    }

    @Test("every resize tick notifies, and so does the commit")
    func resizeNotifiesLiveFrame() {
        let e = editingEngine()
        var live = 0
        var transforms = 0
        e.onLiveFrameChanged = { live += 1 }
        e.onTransformChanged = { transforms += 1 }

        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 300, y: 30), snapping: false)
        e.updateResize(toWorldPoint: CGPoint(x: 200, y: 30), snapping: false)
        #expect(live == 2)
        e.endResize()
        #expect(live == 3) // the commit lands the listener on the final frame
        // The camera never moved, which is exactly why the transform seam alone
        // could not carry this — the whole reason the second notification exists.
        #expect(transforms == 0)
    }

    @Test("what the listener reads mid-drag is the LIVE frame, not the stored one")
    func notificationCarriesTheLiveGeometry() {
        // A notification that fired before the geometry was readable would be worse
        // than none: the editor would re-place itself onto the frame it already had.
        let e = editingEngine()
        var seen: CGRect?
        e.onLiveFrameChanged = { seen = e.currentScreenFrame(forTileID: 0) }
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 150, y: 30), snapping: false)
        #expect(seen?.width == 150)
        #expect((seen?.height ?? 0) > 60) // and taller, the text having re-wrapped
    }

    @Test("a pan or zoom does NOT fire it — that stays the transform seam's job")
    func cameraMovesDoNotFireIt() {
        let e = editingEngine()
        var live = 0
        e.onLiveFrameChanged = { live += 1 }
        e.pan(byScreenDelta: CGSize(width: 40, height: 40))
        e.zoom(by: 1.5, aroundScreenPoint: CGPoint(x: 100, y: 100))
        #expect(live == 0)
    }

    // MARK: The box grows as you type (062)

    @Test("the edited box is drawn at the height its editor asks for")
    func editingHeightDrivesTheBox() {
        // The whole visible symptom: without this the box, its border and its handles
        // keep the committed height while the glyphs above them grow past it.
        let e = editingEngine()
        #expect(e.currentScreenFrame(forTileID: 0)?.height == 60)
        e.setEditingBoxHeight(140)
        #expect(e.currentScreenFrame(forTileID: 0)?.height == 140)
        #expect(e.currentScreenFrame(forTileID: 0)?.width == 400) // width is untouched
    }

    @Test("the handles follow the growing box, not the stored one")
    func handlesFollowTheEditingHeight() {
        let e = editingEngine()
        e.setEditingBoxHeight(140)
        // Grab the bottom edge where the box now ENDS; at the stored height there is
        // nothing there.
        #expect(e.resizeHandle(atScreenPoint: CGPoint(x: 200, y: 140))?.handle == .bottom)
    }

    @Test("clearing it hands the height back to the stored geometry")
    func clearingRestoresTheStoredHeight() {
        // Cancelling an edit must leave no trace: the height was never the provider's.
        let e = editingEngine()
        e.setEditingBoxHeight(140)
        e.setEditingBoxHeight(nil)
        #expect(e.currentScreenFrame(forTileID: 0)?.height == 60)
    }

    @Test("it belongs to ONE edit — moving the editor drops it")
    func heightDoesNotOutliveItsEdit() {
        let e = editingEngine()
        e.setEditingBoxHeight(140)
        e.editingTileID = nil
        #expect(e.currentScreenFrame(forTileID: 0)?.height == 60)
    }

    @Test("resizing WHILE typing takes the width from the drag, the height from the text")
    func resizeAndEditCompose() {
        // The two live overrides meet here, and each has to win where it is
        // authoritative: 062 gives the user the width and the text the height.
        let e = editingEngine()
        e.setEditingBoxHeight(140)
        e.beginResize(tileID: 0, handle: .right)
        e.updateResize(toWorldPoint: CGPoint(x: 220, y: 30), snapping: false)
        let frame = e.currentScreenFrame(forTileID: 0)
        #expect(frame?.width == 220)
        #expect(frame?.height == 140)
    }

    @Test("setting the same height again does not re-sync")
    func repeatedHeightIsANoOp() {
        // It is called on every keystroke, and most keystrokes do not change the
        // height — those must cost a compare, not a relayout.
        let e = editingEngine()
        e.setEditingBoxHeight(140)
        let before = e.syncCount
        e.setEditingBoxHeight(140)
        #expect(e.syncCount == before)
    }

    // MARK: A move drag moves the displayed frame too (062)

    /// A plain engine — no edit open. The drag half of the notification exists for
    /// the app's floating format chrome, which anchors on the SELECTED tile and so
    /// has to follow a box that is merely being dragged, not edited.
    private func dragEngine() -> CanvasEngine {
        let e = CanvasEngine(
            provider: P(tiles: [Tile(id: 0, x: 0, y: 0, w: 400, h: 60, z: 0)]),
            images: NoImages(),
            transform: CanvasTransform(scale: 1, translation: .zero),
            viewportSize: CGSize(width: 1_200, height: 800))
        e.sync()
        e.setSelected(0)
        return e
    }

    @Test("every drag tick notifies, and so does the drop")
    func dragNotifiesLiveFrame() {
        let e = dragEngine()
        var live = 0
        var transforms = 0
        e.onLiveFrameChanged = { live += 1 }
        e.onTransformChanged = { transforms += 1 }

        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 30, height: 20), snapping: false)
        e.updateDrag(byScreenDelta: CGSize(width: 60, height: 40), snapping: false)
        #expect(live == 2)
        _ = e.endDrag()
        #expect(live == 3) // the drop lands the listener on the committed frame
        #expect(transforms == 0) // the camera never moved
    }

    @Test("what the listener reads mid-drag is the offset frame")
    func dragNotificationCarriesTheLiveGeometry() {
        let e = dragEngine()
        var seen: CGRect?
        e.onLiveFrameChanged = { seen = e.currentScreenFrame(forTileID: 0) }
        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 30, height: 20), snapping: false)
        #expect(seen?.origin == CGPoint(x: 30, y: 20))
    }

    @Test("a click — mouse down and up with no drag — is silent")
    func endDragWithoutADragIsSilent() {
        // `endDrag()` runs on every mouse-up that wasn't a click-select, so firing
        // unconditionally would turn the notification into a per-click event and make
        // every listener re-read geometry that never moved.
        let e = dragEngine()
        var live = 0
        e.onLiveFrameChanged = { live += 1 }
        _ = e.endDrag()
        #expect(live == 0)
    }
}
