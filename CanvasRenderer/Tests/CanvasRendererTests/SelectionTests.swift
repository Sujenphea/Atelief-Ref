import CoreGraphics
import Foundation
import QuartzCore
import Testing
@testable import CanvasRenderer

/// Canvas selection: the engine highlight tracks the selected tile, is created
/// lazily (so an unselected canvas keeps its exact sublayer count), hides when
/// nothing is selected or the selected tile scrolls off-screen, and clears when
/// deselected. Pure layer bookkeeping — no window needed.
@MainActor
@Suite("Canvas selection highlight")
struct SelectionTests {
    private struct FixedProvider: TileProvider {
        let tiles: [Tile]
    }
    private struct NoImages: TileImageSource {
        func imageKey(for tile: Tile) -> Int { tile.id }
        func imageData(for tile: Tile, tier: LODTier) -> Data? { nil }
    }

    // Three 200×200 tiles in a row (identity transform → world == screen).
    private let row = [
        Tile(id: 0, x: 0, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 1, x: 220, y: 0, w: 200, h: 200, z: 0),
        Tile(id: 2, x: 440, y: 0, w: 200, h: 200, z: 0),
    ]

    private func makeEngine() -> CanvasEngine {
        CanvasEngine(
            provider: FixedProvider(tiles: row), images: NoImages(),
            transform: CanvasTransform(), viewportSize: CGSize(width: 1_000, height: 1_000))
    }

    @Test("no selection by default and no highlight layer is created")
    func noSelectionByDefault() {
        let engine = makeEngine()
        engine.sync()
        #expect(engine.selectedTileID == nil)
        #expect(engine.isSelectionHighlightVisible == false)
        // Lazy: three tile layers, no highlight sublayer yet.
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 3)
    }

    @Test("selecting a visible tile shows the highlight above the tiles")
    func selectShowsHighlight() {
        let engine = makeEngine()
        engine.setSelected(1)
        #expect(engine.selectedTileID == 1)
        #expect(engine.isSelectionHighlightVisible)
        // Three tiles + one highlight layer.
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 4)
    }

    @Test("deselecting hides the highlight (layer stays, reused)")
    func deselectHides() {
        let engine = makeEngine()
        engine.setSelected(1)
        engine.setSelected(nil)
        #expect(engine.selectedTileID == nil)
        #expect(engine.isSelectionHighlightVisible == false)
    }

    @Test("selecting a tile then panning it off-screen hides the highlight")
    func offscreenHides() {
        let engine = makeEngine()
        engine.setSelected(1)
        #expect(engine.isSelectionHighlightVisible)
        // Push all content far off-screen.
        engine.setTransform(CanvasTransform(scale: 1, translation: CGPoint(x: -100_000, y: -100_000)))
        #expect(engine.selectedTileID == 1)                  // selection is retained…
        #expect(engine.isSelectionHighlightVisible == false) // …but not drawn while off-screen
        // Panning back re-shows it.
        engine.setTransform(CanvasTransform())
        #expect(engine.isSelectionHighlightVisible)
    }

    @Test("re-selecting the same tile is an idempotent no-op")
    func reselectIdempotent() {
        let engine = makeEngine()
        engine.setSelected(2)
        let before = engine.rootLayer.sublayers?.count ?? 0
        engine.setSelected(2)
        #expect(engine.selectedTileID == 2)
        #expect(engine.isSelectionHighlightVisible)
        #expect((engine.rootLayer.sublayers?.count ?? 0) == before) // no extra layer
    }

    @Test("moving the selection to another tile keeps a single highlight")
    func moveSelectionSingleHighlight() {
        let engine = makeEngine()
        engine.setSelected(0)
        engine.setSelected(2)
        #expect(engine.selectedTileID == 2)
        #expect(engine.isSelectionHighlightVisible)
        // Still exactly one highlight layer (3 tiles + 1).
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 4)
    }
}
