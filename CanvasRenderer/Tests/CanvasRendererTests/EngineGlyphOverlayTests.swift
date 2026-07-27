//
//  EngineGlyphOverlayTests.swift
//  CanvasRendererTests
//
//  061 Step 3 — the engine wiring for `useCoreTextGlyphs`. The suite that
//  matters most here is "Zoom invariance": it asserts at the ENGINE level what
//  059 could not guarantee — that panning and zooming the camera cannot change a
//  tile's shaping inputs, so line breaks are physically incapable of moving.
//
//  Everything else is parity with the `CATextLayer` path it replaces: overlays
//  attach and detach on the same events, an edited tile still blanks, and a tile
//  that leaves the viewport still gives its layer back.
//

import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

@MainActor
@Suite("Engine glyph overlays (060 · flagged)")
struct EngineGlyphOverlayTests {

    private struct VectorProvider: TileProvider {
        let tiles: [Tile]
        var texts: [Int: TextStyle] = [:]
        var frameStyles: [Int: FrameStyle] = [:]

        func content(for tile: Tile) -> TileContent {
            if let style = texts[tile.id] { return .text(style) }
            if let style = frameStyles[tile.id] { return .frame(style) }
            return .image
        }
    }

    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    private func style(_ string: String = "The quick brown fox jumps over the lazy dog",
                       fontSize: Double = 18) -> TextStyle {
        TextStyle(string: string, fontSize: fontSize,
                  color: RGBAColor(red: 0, green: 0, blue: 0))
    }

    /// An engine with the 060 path ON and a viewport large enough that nothing is
    /// culled unless a test moves the camera on purpose.
    private func engine(_ provider: VectorProvider,
                        scale: CGFloat = 1,
                        viewport: CGSize = CGSize(width: 4_000, height: 4_000)) -> CanvasEngine {
        let e = CanvasEngine(
            provider: provider, images: NoImages(),
            transform: CanvasTransform(scale: scale),
            viewportSize: viewport)
        e.useCoreTextGlyphs = true
        e.sync()
        return e
    }

    private func textProvider() -> VectorProvider {
        var p = VectorProvider(tiles: row)
        p.texts = [1: style()]
        return p
    }

    // MARK: - Zoom invariance (the engine-level crux)

    @Test("the shaping key is identical at every zoom — the camera cannot re-break a line")
    func shapeKeyIsInvariantAcrossZoom() {
        let e = engine(textProvider())
        guard let layer = e.glyphLayer(forTileID: 1), let first = layer.shaped else {
            Issue.record("no glyph overlay"); return
        }
        let key = first.key
        let lineCount = first.lines.count
        let origins = first.lines.map(\.origin)
        #expect(lineCount > 1)   // it really wraps — the case that used to reflow

        for scale in [CGFloat(0.25), 0.5, 2, 4, 8] {
            e.setTransform(CanvasTransform(scale: scale))
            guard let shaped = e.glyphLayer(forTileID: 1)?.shaped else {
                Issue.record("overlay lost at \(scale)×"); return
            }
            #expect(shaped.key == key)                    // same layout inputs…
            #expect(shaped.lines.count == lineCount)      // …so the same breaks…
            #expect(shaped.lines.map(\.origin) == origins) // …at the same places.
        }
    }

    @Test("a zoom updates the draw scale; the layout object is reused untouched")
    func zoomOnlyMovesTheDrawScale() {
        let e = engine(textProvider())
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
        #expect(layer.drawScale == 1)
        e.setTransform(CanvasTransform(scale: 3))
        #expect(layer.drawScale == 3)
        #expect(layer.shaped?.key == e.glyphLayer(forTileID: 1)?.shaped?.key)
    }

    @Test("panning changes neither the layout nor the layer's on-screen size")
    func panLeavesRasterizationAlone() {
        let e = engine(textProvider())
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
        let key = layer.shaped?.key
        let size = layer.bounds.size
        let scale = layer.drawScale

        for _ in 0..<8 { e.pan(byScreenDelta: CGSize(width: 11, height: -7)) }

        // Nothing that would force a re-raster moved: same layout, same size,
        // same scale. Only `position` changed.
        #expect(layer.shaped?.key == key)
        #expect(layer.bounds.size == size)
        #expect(layer.drawScale == scale)
    }

    @Test("a zoom resizes the layer (which is what re-rasterizes it); a pan does not")
    func onlyZoomResizesTheLayer() {
        let e = engine(textProvider())
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
        let before = layer.bounds.size
        e.pan(byScreenDelta: CGSize(width: 40, height: 40))
        #expect(layer.bounds.size == before)              // pan: no new raster
        e.setTransform(CanvasTransform(scale: 2))
        #expect(layer.bounds.size != before)              // zoom: new raster
        #expect(layer.bounds.width > before.width)
    }

    // MARK: - Attach / detach parity with the CATextLayer path

    @Test("only text tiles get an overlay, and it is the glyph kind")
    func attachesToTextTilesOnly() {
        let e = engine(textProvider())
        #expect(e.textOverlayCount == 1)
        #expect(e.glyphLayer(forTileID: 1) != nil)
        #expect(e.glyphLayer(forTileID: 0) == nil)
        // The legacy accessor stays empty while the flag is on.
        #expect(e.textLayer(forTileID: 1) == nil)
    }

    @Test("a frame label rides the same glyph layer")
    func frameLabelsUseGlyphLayers() {
        var p = VectorProvider(tiles: row)
        p.frameStyles = [2: FrameStyle(
            stroke: RGBAColor(red: 0, green: 0, blue: 0), strokeWidth: 2,
            label: style("Group label"))]
        let e = engine(p)
        #expect(e.glyphLayer(forTileID: 2) != nil)
        #expect(e.glyphLayer(forTileID: 2)?.shaped?.lines.isEmpty == false)
    }

    @Test("an empty string attaches no overlay")
    func emptyStringDetaches() {
        var p = VectorProvider(tiles: row)
        p.texts = [1: style("")]
        #expect(engine(p).textOverlayCount == 0)
    }

    @Test("a tile leaving the viewport gives its overlay back")
    func recyclesOnViewportExit() {
        let e = engine(textProvider(), viewport: CGSize(width: 300, height: 300))
        #expect(e.textOverlayCount >= 1)
        // Pan the text tile far off-screen.
        e.pan(byScreenDelta: CGSize(width: -10_000, height: 0))
        #expect(e.glyphLayer(forTileID: 1) == nil)
        #expect(e.textOverlayCount == 0)
    }

    @Test("the tile an inline editor owns is blanked (2B), and restored after")
    func blanksWhileEditing() {
        let e = engine(textProvider())
        #expect(e.glyphLayer(forTileID: 1) != nil)
        e.editingTileID = 1
        #expect(e.glyphLayer(forTileID: 1) == nil)
        #expect(e.textOverlayCount == 0)
        e.editingTileID = nil
        #expect(e.glyphLayer(forTileID: 1) != nil)
    }

    // MARK: - The flag itself

    @Test("the flag is off by default — the CATextLayer path still owns text")
    func defaultsToLegacyPath() {
        let p = textProvider()
        let e = CanvasEngine(
            provider: p, images: NoImages(),
            transform: CanvasTransform(scale: 1),
            viewportSize: CGSize(width: 4_000, height: 4_000))
        e.sync()
        #expect(e.useCoreTextGlyphs == false)
        #expect(e.textLayer(forTileID: 1) != nil)
        #expect(e.glyphLayer(forTileID: 1) == nil)
        #expect(e.textOverlayCount == 1)
    }

    @Test("toggling the flag swaps paths without leaking the other's layers")
    func togglingSwapsCleanly() {
        let e = engine(textProvider())
        let rootCount = { e.rootLayer.sublayers?.count ?? 0 }
        let withGlyphs = rootCount()
        #expect(e.glyphLayer(forTileID: 1) != nil)

        e.useCoreTextGlyphs = false
        #expect(e.glyphLayer(forTileID: 1) == nil)
        #expect(e.textLayer(forTileID: 1) != nil)
        #expect(e.textOverlayCount == 1)          // exactly one path is populated
        #expect(rootCount() == withGlyphs)        // no orphaned sublayer left behind

        e.useCoreTextGlyphs = true
        #expect(e.glyphLayer(forTileID: 1) != nil)
        #expect(e.textLayer(forTileID: 1) == nil)
        #expect(e.textOverlayCount == 1)
        #expect(rootCount() == withGlyphs)
    }

    // MARK: - Geometry contract

    @Test("the layer is inset by the world pad, so draw ≡ measure at every zoom")
    func worldPadInsetHolds() {
        let e = engine(textProvider())
        for scale in [CGFloat(0.5), 1, 2, 4] {
            e.setTransform(CanvasTransform(scale: scale))
            guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
            // Tile is 200 world units wide; the pad is world-space, so the layer's
            // world width is a constant 200 − 2·padding at every zoom.
            let worldWidth = layer.bounds.width / scale
            #expect(abs(worldWidth - (200 - 2 * TextMetrics.padding)) < 0.01)
        }
    }

    @Test("the shaping width matches the layer's own world width (measure ≡ draw)")
    func shapingWidthMatchesTheDrawnBox() {
        let e = engine(textProvider())
        guard let layer = e.glyphLayer(forTileID: 1), let shaped = layer.shaped else {
            Issue.record("no overlay"); return
        }
        #expect(abs(shaped.contentWidth - layer.bounds.width / layer.drawScale) < 0.01)
    }

    @Test("a deeply zoomed layer is clamped so its backing store stays bounded")
    func backingStoreIsCapped() {
        let viewport = CGSize(width: 1_000, height: 800)
        let e = engine(textProvider(), viewport: viewport)
        // 200 world units × 64 = 12_800 points a side — far past what a backing
        // store should hold. Translate so the zoomed tile still covers the
        // viewport (otherwise it is simply culled and there is nothing to clamp).
        let scale: CGFloat = 64
        e.setTransform(CanvasTransform(
            scale: scale, translation: CGPoint(x: -220 * scale, y: 0)))
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }

        // Clamped to the viewport plus its pan slack, not the full 80_000.
        #expect(layer.bounds.width <= viewport.width + 1_100)
        #expect(layer.bounds.height <= viewport.height + 1_100)
        // …and the layout is untouched by the clamp — only the window onto it moved.
        #expect(layer.shaped?.key == e.glyphLayer(forTileID: 1)?.shaped?.key)
    }

    @Test("ordinary zooms are never clamped, so pans stay raster-free")
    func ordinaryZoomsAreNotClamped() {
        let e = engine(textProvider(), viewport: CGSize(width: 1_000, height: 800))
        e.setTransform(CanvasTransform(scale: 2))
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
        #expect(layer.worldOffset == .zero)
        // Full box: 200 world × 2, less the world pad on both sides.
        #expect(abs(layer.bounds.width - (200 - 2 * TextMetrics.padding) * 2) < 0.01)
    }

    @Test("the glyph colour reaches the layer without re-shaping")
    func colourIsApplied() {
        var p = VectorProvider(tiles: row)
        var s = style()
        s.color = RGBAColor(red: 1, green: 0, blue: 0)
        p.texts = [1: s]
        let e = engine(p)
        guard let layer = e.glyphLayer(forTileID: 1) else { Issue.record("no overlay"); return }
        #expect(layer.textColor.components?.first == 1)
    }
}
