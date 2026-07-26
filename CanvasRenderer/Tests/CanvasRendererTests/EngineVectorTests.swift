import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

/// E3 — the *vector* tile path (decision T3, the hybrid renderer). Frames draw
/// on their pooled layer (fill + world-thickness border); text rides a
/// `CATextLayer` sibling OUTSIDE the recycled pool (like a badge); and dragging a
/// frame carries the tiles it contains. Image tiles are wholly unaffected.
@MainActor
@Suite("Renderer vector tiles (frames + text)")
struct EngineVectorTests {

    /// A provider that tags chosen tiles as frames / text and models frame-group
    /// membership as "tiles whose id is in `group[frameID]`".
    private struct VectorProvider: TileProvider {
        let tiles: [Tile]
        var frames: Set<Int> = []
        var texts: [Int: TextStyle] = [:]
        var frameStyles: [Int: FrameStyle] = [:]
        var group: [Int: [Int]] = [:]

        func content(for tile: Tile) -> TileContent {
            if let style = texts[tile.id] { return .text(style) }
            if frames.contains(tile.id) {
                return .frame(frameStyles[tile.id] ?? FrameStyle(
                    stroke: RGBAColor(red: 0, green: 0, blue: 0), strokeWidth: 2))
            }
            return .image
        }

        func groupMembers(forDraggedTileID id: Int) -> [Int] { group[id] ?? [] }
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

    private func engine(_ provider: VectorProvider) -> CanvasEngine {
        CanvasEngine(
            provider: provider, images: NoImages(),
            transform: CanvasTransform(scale: 1),
            viewportSize: CGSize(width: 4_000, height: 4_000))
    }

    // MARK: Rendering

    @Test("a frame tile paints its pooled layer's border + fill, no image content")
    func frameStylesPooledLayer() {
        var p = VectorProvider(tiles: row)
        p.frames = [1]
        p.frameStyles = [1: FrameStyle(
            fill: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0.5),
            stroke: RGBAColor(red: 0, green: 0, blue: 1), strokeWidth: 4, cornerRadius: 8)]
        let e = engine(p)
        e.sync()
        // No CATextLayer overlays (no labels/text), and the base image path added
        // no cache work for the frame.
        #expect(e.textOverlayCount == 0)
        // 3 tile layers only (frame draws on its own pooled layer, no sibling).
        #expect((e.rootLayer.sublayers?.count ?? 0) == 3)
    }

    @Test("a text tile adds exactly one CATextLayer sibling, kept out of the pool")
    func textAddsOverlay() {
        var p = VectorProvider(tiles: row)
        p.texts = [2: TextStyle(string: "hello", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let e = engine(p)
        e.sync()
        #expect(e.textOverlayCount == 1)
        #expect(e.activeLayerCount == 3)           // pool unchanged (3 tiles)
        #expect((e.rootLayer.sublayers?.count ?? 0) == 4) // 3 tiles + 1 text overlay
    }

    @Test("an empty text string draws no overlay")
    func emptyTextNoOverlay() {
        var p = VectorProvider(tiles: row)
        p.texts = [0: TextStyle(string: "", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let e = engine(p)
        e.sync()
        #expect(e.textOverlayCount == 0)
        #expect((e.rootLayer.sublayers?.count ?? 0) == 3)
    }

    @Test("a frame label adds a text overlay")
    func frameLabelOverlay() {
        var p = VectorProvider(tiles: row)
        p.frames = [1]
        p.frameStyles = [1: FrameStyle(
            stroke: RGBAColor(red: 0, green: 0, blue: 0), strokeWidth: 2,
            label: TextStyle(string: "Moodboard", fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0)))]
        let e = engine(p)
        e.sync()
        #expect(e.textOverlayCount == 1)
    }

    @Test("text overlays are dropped when their tile is panned out of view")
    func overlayDroppedOffscreen() {
        var p = VectorProvider(tiles: row)
        p.texts = [1: TextStyle(string: "bye", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let e = engine(p)
        e.sync()
        #expect(e.textOverlayCount == 1)
        // Pan far past all tiles → nothing visible, overlay released with its tile.
        e.pan(byScreenDelta: CGSize(width: -100_000, height: 0))
        #expect(e.activeLayerCount == 0)
        #expect(e.textOverlayCount == 0)
        #expect((e.rootLayer.sublayers?.count ?? 0) == 0)
    }

    @Test("image tiles add no overlays and keep exact sublayer counts (regression)")
    func imageTilesUnaffected() {
        let e = engine(VectorProvider(tiles: row))
        e.sync()
        #expect(e.textOverlayCount == 0)
        #expect((e.rootLayer.sublayers?.count ?? 0) == 3)
    }

    // MARK: Rich text style (2A) — family / weight / alignment applied

    @Test("setTextOverlay applies the resolved font family + alignment mode")
    func overlayAppliesFontAndAlignment() {
        var p = VectorProvider(tiles: row)
        p.texts = [2: TextStyle(
            string: "styled", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0),
            fontFamily: "Helvetica", weight: .bold, alignment: .center)]
        let e = engine(p)
        e.sync()
        let layer = e.textLayer(forTileID: 2)
        #expect(layer != nil)
        #expect(layer?.alignmentMode == .center)
        // The layer's font is the CanvasFont-resolved typeface (the requested family).
        if let font = layer?.font {
            #expect(CTFontCopyFamilyName(font as! CTFont) as String == "Helvetica")
        } else {
            Issue.record("text layer has no font")
        }
    }

    @Test("a nil family / default weight overlay still resolves a system font")
    func overlayDefaultsToSystemFont() {
        var p = VectorProvider(tiles: row)
        p.texts = [1: TextStyle(string: "plain", fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let e = engine(p)
        e.sync()
        let layer = e.textLayer(forTileID: 1)
        #expect(layer?.alignmentMode == .left)
        #expect(layer?.font != nil) // never blank — system fallback
    }

    // MARK: Padding reconciliation (2C · 054 §4.4 · R12)

    /// A `.text` tile's overlay is inset by the WORLD pad (`TextMetrics.padding ×
    /// scale`) at every zoom, so the drawn inset equals the world inset the app
    /// measured against — the draw≡measure invariant the auto-box relies on.
    @Test("a .text overlay insets by TextMetrics.padding × scale at each zoom")
    func textTileInsetIsWorldPadded() {
        var p = VectorProvider(tiles: row)
        p.texts = [1: TextStyle(string: "measured", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        for scale in [CGFloat(0.5), 1, 2, 4] {
            let e = CanvasEngine(
                provider: p, images: NoImages(),
                transform: CanvasTransform(scale: scale),
                viewportSize: CGSize(width: 8_000, height: 8_000))
            e.sync()
            let overlay = e.textLayer(forTileID: 1)!.frame
            let tile = e.currentScreenFrame(forTileID: 1)!
            let pad = TextMetrics.padding * scale
            #expect(Approx.equal(overlay, tile.insetBy(dx: pad, dy: pad)))
        }
    }

    /// A frame LABEL keeps the legacy screen-space pad (`min(6, width·0.04)`),
    /// byte-identical to before 2C — frames aren't auto-sized (054 §4.4).
    @Test("a frame label keeps the legacy screen-space pad (byte-identical)")
    func frameLabelKeepsScreenPad() {
        var p = VectorProvider(tiles: row)
        p.frames = [1]
        p.frameStyles = [1: FrameStyle(
            stroke: RGBAColor(red: 0, green: 0, blue: 0), strokeWidth: 2,
            label: TextStyle(string: "Label", fontSize: 18, color: RGBAColor(red: 0, green: 0, blue: 0)))]
        let e = engine(p) // scale 1
        e.sync()
        let overlay = e.textLayer(forTileID: 1)!.frame
        let tile = e.currentScreenFrame(forTileID: 1)!
        let pad = min(6, tile.width * 0.04)
        #expect(Approx.equal(overlay, tile.insetBy(dx: pad, dy: pad)))
    }

    // MARK: Frame-as-group drag

    @Test("dragging a frame carries its group; endDrag reports all final origins")
    func frameGroupDrag() {
        var p = VectorProvider(tiles: row)
        p.frames = [0]
        p.group = [0: [1, 2]] // frame 0 contains tiles 1 and 2
        let e = engine(p)
        e.sync()
        let before1 = e.currentScreenFrame(forTileID: 1)!
        let before2 = e.currentScreenFrame(forTileID: 2)!

        e.beginDrag(tileID: 0)
        e.updateDrag(byScreenDelta: CGSize(width: 100, height: 50))

        // The carried tiles move by the same screen delta as the frame.
        #expect(Approx.equal(
            e.currentScreenFrame(forTileID: 1)!.origin,
            CGPoint(x: before1.origin.x + 100, y: before1.origin.y + 50)))
        #expect(Approx.equal(
            e.currentScreenFrame(forTileID: 2)!.origin,
            CGPoint(x: before2.origin.x + 100, y: before2.origin.y + 50)))

        // Final origins for the frame + both carried tiles (scale 1 ⇒ world == screen delta).
        let origins = e.currentDragOrigins()
        #expect(origins.count == 3)
        #expect(Set(origins.map(\.tileID)) == [0, 1, 2])
        let byID = Dictionary(uniqueKeysWithValues: origins.map { ($0.tileID, $0.worldOrigin) })
        #expect(Approx.equal(byID[1]!, CGPoint(x: 220 + 100, y: 0 + 50)))
    }

    @Test("a non-group drag moves only the dragged tile")
    func plainDragMovesOne() {
        let e = engine(VectorProvider(tiles: row))
        e.sync()
        let before0 = e.currentScreenFrame(forTileID: 0)!
        e.beginDrag(tileID: 1)
        e.updateDrag(byScreenDelta: CGSize(width: 60, height: 0))
        #expect(Approx.equal(e.currentScreenFrame(forTileID: 0)!, before0))
        #expect(e.currentDragOrigins().count == 1)
    }

    // MARK: Multi-selection carry (049 · D3 / D7)

    @Test("alsoCarry carries the whole selection; all move by the same delta")
    func multiSelectCarriesSelection() {
        let e = engine(VectorProvider(tiles: row))
        e.sync()
        let before1 = e.currentScreenFrame(forTileID: 1)!
        let before2 = e.currentScreenFrame(forTileID: 2)!

        // Grab tile 0, carrying a 3-tile selection {0,1,2}.
        e.beginDrag(tileID: 0, alsoCarry: canvasDragCarry(grabbed: 0, selection: [0, 1, 2]))
        e.updateDrag(byScreenDelta: CGSize(width: 100, height: 50))

        #expect(Approx.equal(e.currentScreenFrame(forTileID: 1)!.origin,
                             CGPoint(x: before1.origin.x + 100, y: before1.origin.y + 50)))
        #expect(Approx.equal(e.currentScreenFrame(forTileID: 2)!.origin,
                             CGPoint(x: before2.origin.x + 100, y: before2.origin.y + 50)))
        let origins = e.currentDragOrigins()
        #expect(origins.count == 3)
        #expect(Set(origins.map(\.tileID)) == [0, 1, 2])
    }

    @Test("a selected tile inside a dragged frame is carried ONCE (de-dup)")
    func selectionIntersectingFrameGroupDeDups() {
        var p = VectorProvider(tiles: row)
        p.frames = [0]
        p.group = [0: [1, 2]] // frame 0 contains tiles 1 and 2
        let e = engine(p)
        e.sync()

        // Grab the frame (0) while {1,2} are ALSO selected — so tile 1 and 2 are
        // both frame-group members AND in the carried selection.
        e.beginDrag(tileID: 0, alsoCarry: canvasDragCarry(grabbed: 0, selection: [0, 1, 2]))
        e.updateDrag(byScreenDelta: CGSize(width: 30, height: 0))

        let origins = e.currentDragOrigins()
        // Exactly {0,1,2}, each once — no doubled move that would corrupt the undo.
        #expect(origins.count == 3)
        #expect(Set(origins.map(\.tileID)).count == origins.count)
        #expect(Set(origins.map(\.tileID)) == [0, 1, 2])
    }

    @Test("grabbing an UNSELECTED tile carries only it, not the selection")
    func unselectedGrabCarriesOne() {
        let e = engine(VectorProvider(tiles: row))
        e.sync()
        // Selection is {2} but the grab lands on tile 0 (not selected).
        e.beginDrag(tileID: 0, alsoCarry: canvasDragCarry(grabbed: 0, selection: [2]))
        let origins = e.currentDragOrigins()
        #expect(origins.count == 1)
        #expect(origins.first?.tileID == 0)
    }

    @Test("the primary tile is never doubled even if alsoCarry includes it")
    func primaryNeverDoubled() {
        let e = engine(VectorProvider(tiles: row))
        e.sync()
        // canvasDragCarry returns a set that INCLUDES the grabbed tile.
        e.beginDrag(tileID: 1, alsoCarry: canvasDragCarry(grabbed: 1, selection: [0, 1]))
        let origins = e.currentDragOrigins()
        #expect(origins.count == 2)
        #expect(Set(origins.map(\.tileID)) == [0, 1])
    }

    // MARK: Rubber-band normalization (pure)

    @Test("normalizedRect is corner-order independent and positive-size")
    func normalizedRect() {
        let a = CGPoint(x: 100, y: 80), b = CGPoint(x: 40, y: 200)
        let r1 = CanvasHostView.normalizedRect(from: a, to: b)
        let r2 = CanvasHostView.normalizedRect(from: b, to: a)
        #expect(r1 == r2)
        #expect(r1 == CGRect(x: 40, y: 80, width: 60, height: 120))
    }
}
