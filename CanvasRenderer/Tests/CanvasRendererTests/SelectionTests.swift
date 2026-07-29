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
        // Exactly one highlight layer. (Asserted directly rather than as a total
        // sublayer count: a selected tile also carries its corner resize handles,
        // and this test is about the highlight, not the chrome around it.)
        #expect(engine.selectionHighlightCount == 1)
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
        // Still exactly one highlight layer — the old one moved, not a second added.
        #expect(engine.selectionHighlightCount == 1)
    }

    // MARK: - Multi-selection highlights (049 · D4 / D12 / D16)

    @Test("selecting N visible tiles draws N highlight layers")
    func multiSelectDrawsNHighlights() {
        let engine = makeEngine()
        engine.setSelected([0, 1, 2])
        #expect(engine.selectedTileIDs == [0, 1, 2])
        #expect(engine.selectionHighlightCount == 3)
        // Single-select convenience is nil when the selection isn't exactly one.
        #expect(engine.selectedTileID == nil)
        // Three tiles + three highlights.
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 6)
    }

    @Test("partially deselecting drops exactly the deselected tiles' highlights")
    func partialDeselectDropsRightLayers() {
        let engine = makeEngine()
        engine.setSelected([0, 1, 2])
        #expect(engine.selectionHighlightCount == 3)
        engine.setSelected([0, 2]) // drop tile 1
        #expect(engine.selectedTileIDs == [0, 2])
        #expect(engine.selectionHighlightCount == 2)
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 5) // 3 tiles + 2 highlights
    }

    @Test("an off-screen selected tile draws no highlight (bounded by the viewport)")
    func offscreenSelectedDrawsNoHighlight() {
        let engine = makeEngine()
        engine.setSelected([0, 1, 2])
        #expect(engine.selectionHighlightCount == 3)
        // Push all content far off-screen: selection is retained, highlights are not
        // drawn (layer count is bounded by the VISIBLE set, not the selection size).
        engine.setTransform(CanvasTransform(scale: 1, translation: CGPoint(x: -100_000, y: -100_000)))
        #expect(engine.selectedTileIDs == [0, 1, 2]) // retained…
        #expect(engine.selectionHighlightCount == 0)  // …but nothing drawn
        #expect(engine.isSelectionHighlightVisible == false)
        // Panning back re-draws all three.
        engine.setTransform(CanvasTransform())
        #expect(engine.selectionHighlightCount == 3)
    }

    @Test("repeated select/deselect cycles do not leak highlight layers")
    func selectDeselectDoesNotLeak() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.rootLayer.sublayers?.count ?? 0 // 3 tile layers, no highlights
        for _ in 0..<50 {
            engine.setSelected([0, 1, 2])
            engine.setSelected([])
        }
        #expect(engine.selectionHighlightCount == 0)
        // Back to the exact baseline — highlight layers were removed, not accreted.
        #expect((engine.rootLayer.sublayers?.count ?? 0) == baseline)
    }

    @Test("clearing a multi-selection removes every highlight")
    func clearMultiRemovesAll() {
        let engine = makeEngine()
        engine.setSelected([0, 1, 2])
        engine.setSelected([])
        #expect(engine.selectedTileIDs.isEmpty)
        #expect(engine.selectionHighlightCount == 0)
        #expect(engine.isSelectionHighlightVisible == false)
        #expect((engine.rootLayer.sublayers?.count ?? 0) == 3) // just the tile layers
    }
}
