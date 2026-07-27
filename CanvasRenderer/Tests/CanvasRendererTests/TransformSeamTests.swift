import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

/// 2B · 054 §5.1 (R2/R11) — the boundary seam the inline text editor rides. The
/// engine exposes a tile's live on-screen frame and fires ``onTransformChanged``
/// exactly ONCE per transform mutation, so the app can reposition its overlay
/// imperatively (off the SwiftUI diff). `editingTileID` blanks a tile's text
/// overlay while the live `NSTextView` owns it (§5.2). No window needed — pure
/// layer/geometry math + a callback spy.
@MainActor
@Suite("Canvas transform seam (2B · 054 §5.1)")
struct TransformSeamTests {
    private struct FixedProvider: TileProvider {
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

    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    private func makeEngine(_ provider: FixedProvider? = nil) -> CanvasEngine {
        CanvasEngine(
            provider: provider ?? FixedProvider(tiles: row), images: NoImages(),
            transform: CanvasTransform(scale: 2, translation: CGPoint(x: 50, y: 30)),
            viewportSize: CGSize(width: 4_000, height: 4_000))
    }

    // MARK: - screenFrame tracks the transform (R11)

    @Test("after a known pan, a tile's screen frame shifts by exactly that delta")
    func panShiftsScreenFrameByDelta() {
        let engine = makeEngine()
        engine.sync()
        let before = engine.currentScreenFrame(forTileID: 1)!

        let delta = CGSize(width: 60, height: -40)
        engine.pan(byScreenDelta: delta)

        let after = engine.currentScreenFrame(forTileID: 1)!
        #expect(Approx.equal(
            after.origin,
            CGPoint(x: before.origin.x + delta.width, y: before.origin.y + delta.height)))
        // A pan never rescales — size is identical.
        #expect(Approx.equal(after.size.width, before.size.width))
        #expect(Approx.equal(after.size.height, before.size.height))
    }

    @Test("a zoom scales a tile's screen frame about the anchor point")
    func zoomScalesFrameAboutAnchor() {
        let engine = makeEngine()
        engine.sync()
        let anchor = CGPoint(x: 300, y: 200)
        let before = engine.currentScreenFrame(forTileID: 1)!
        let factor: CGFloat = 1.5

        engine.zoom(by: factor, aroundScreenPoint: anchor)
        let after = engine.currentScreenFrame(forTileID: 1)!

        // Size scales by exactly the factor…
        #expect(Approx.equal(after.size.width, before.size.width * factor))
        #expect(Approx.equal(after.size.height, before.size.height * factor))
        // …and every corner moves along the ray from the anchor by that factor
        // (the defining property of a zoom about a fixed screen point).
        #expect(Approx.equal(
            after.origin,
            CGPoint(x: anchor.x + (before.origin.x - anchor.x) * factor,
                    y: anchor.y + (before.origin.y - anchor.y) * factor)))
    }

    @Test("screenFrame is nil for a tile outside the viewport")
    func screenFrameNilOffscreen() {
        let engine = makeEngine()
        engine.setTransform(CanvasTransform(scale: 1, translation: CGPoint(x: -100_000, y: -100_000)))
        #expect(engine.currentScreenFrame(forTileID: 1) == nil)
    }

    // MARK: - onTransformChanged fires exactly once per mutation (R2)

    @Test("onTransformChanged fires exactly once per pan / zoom / setTransform")
    func notifiesOncePerMutation() {
        let engine = makeEngine()
        var count = 0
        engine.onTransformChanged = { count += 1 }

        engine.pan(byScreenDelta: CGSize(width: 10, height: 0))
        #expect(count == 1)

        engine.zoom(by: 1.25, aroundScreenPoint: CGPoint(x: 100, y: 100))
        #expect(count == 2)

        engine.setTransform(CanvasTransform(scale: 1, translation: .zero))
        #expect(count == 3)
    }

    @Test("frameToContent notifies through the same seam exactly once")
    func frameToContentNotifiesOnce() {
        let engine = makeEngine()
        var count = 0
        engine.onTransformChanged = { count += 1 }
        engine.frameToContent()
        #expect(count == 1) // frameToContent routes through setTransform → one emit
    }

    @Test("a plain sync (no transform change) does not notify")
    func syncDoesNotNotify() {
        let engine = makeEngine()
        var count = 0
        engine.onTransformChanged = { count += 1 }
        engine.sync()
        #expect(count == 0)
    }

    // MARK: - editingTileID blanks the CATextLayer (§5.2)

    @Test("setting editingTileID blanks that tile's text overlay; clearing restores it")
    func editingBlanksTextOverlay() {
        var provider = FixedProvider(tiles: row)
        provider.texts = [1: TextStyle(
            string: "hello", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let engine = makeEngine(provider)
        engine.sync()
        #expect(engine.textOverlayCount == 1) // drawn normally

        engine.editingTileID = 1 // the app-layer editor takes over → blank beneath it
        #expect(engine.textLayer(forTileID: 1) == nil)
        #expect(engine.textOverlayCount == 0)

        engine.editingTileID = nil // editor dismissed → the glyphs come back
        #expect(engine.textLayer(forTileID: 1) != nil)
        #expect(engine.textOverlayCount == 1)
    }

    @Test("editingTileID for a different tile leaves the edited-tile overlay drawn")
    func editingOtherTileDoesNotBlank() {
        var provider = FixedProvider(tiles: row)
        provider.texts = [2: TextStyle(
            string: "world", fontSize: 24, color: RGBAColor(red: 0, green: 0, blue: 0))]
        let engine = makeEngine(provider)
        engine.editingTileID = 1 // a non-text (or other) tile
        engine.sync()
        #expect(engine.textLayer(forTileID: 2) != nil) // tile 2's text still draws
    }
}
