import CoreGraphics
import QuartzCore
import Testing
@testable import CanvasRenderer

/// Layer-pool invariants under scripted pan/zoom/resize (decision T11). These are
/// the checks that catch the recycling bugs — leaked or over-allocated layers —
/// that would silently wreck the memory profile the spike must prove.
@MainActor
@Suite("CanvasEngine invariants")
struct EngineInvariantTests {
    /// A realistic clustered board so visible counts genuinely vary as the camera
    /// moves (a uniform grid would never exercise growth).
    private func makeEngine(margin: CGFloat = 0) -> CanvasEngine {
        let provider = DummyTileProvider(
            seed: 0xBEEF,
            config: DummyTileGenerator.Config(count: 2_000, clusterCount: 25)
        )
        let engine = CanvasEngine(
            provider: provider,
            images: FixtureImageSet(count: 16, seed: 2),
            // Zoomed out and centred on the world origin (cluster centres are
            // distributed around it), so the viewport actually sees hundreds of
            // tiles — otherwise the invariants would only ever compare 0 == 0.
            transform: CanvasTransform(scale: 0.05, translation: CGPoint(x: 500, y: 350)),
            viewportSize: CGSize(width: 1_000, height: 700)
        )
        engine.prefetchMarginScreen = margin
        return engine
    }

    /// The three invariants, checked at every scripted step.
    /// - realized layers == culled-visible tiles,
    /// - every active layer is attached to the root (none orphaned),
    /// - total allocated layers == the running peak visible count
    ///   (bounded; idle layers are parked, never leaked or grown past peak).
    private func checkInvariants(_ engine: CanvasEngine, runningMax: inout Int, _ label: String) {
        let visible = engine.currentVisibleTiles().count
        #expect(engine.activeLayerCount == visible, "realized != visible @ \(label)")
        #expect((engine.rootLayer.sublayers?.count ?? 0) == engine.activeLayerCount,
                "orphaned/under-attached layers @ \(label)")
        runningMax = max(runningMax, visible)
        #expect(engine.allocatedLayerCount == runningMax,
                "allocated \(engine.allocatedLayerCount) != peak \(runningMax) @ \(label)")
    }

    @Test("invariants hold across a pan / zoom / resize script")
    func scriptedCameraPath() {
        let engine = makeEngine()
        var runningMax = 0
        engine.sync()
        #expect(engine.activeLayerCount > 0, "camera should start over content")
        checkInvariants(engine, runningMax: &runningMax, "initial")

        // Pan across the board.
        for step in 1...8 {
            engine.pan(byScreenDelta: CGSize(width: -350, height: -220))
            checkInvariants(engine, runningMax: &runningMax, "pan \(step)")
        }
        // Zoom in (fewer, larger tiles) then out (many tiles — likely the peak).
        engine.zoom(by: 3.0, aroundScreenPoint: CGPoint(x: 500, y: 350))
        checkInvariants(engine, runningMax: &runningMax, "zoom in")
        engine.zoom(by: 0.05, aroundScreenPoint: CGPoint(x: 500, y: 350))
        checkInvariants(engine, runningMax: &runningMax, "zoom out")

        // Resize larger, then smaller.
        engine.viewportSize = CGSize(width: 1_600, height: 1_000)
        engine.sync()
        checkInvariants(engine, runningMax: &runningMax, "resize up")
        engine.viewportSize = CGSize(width: 600, height: 400)
        engine.sync()
        checkInvariants(engine, runningMax: &runningMax, "resize down")
    }

    @Test("oscillating back-and-forth pans do not leak or grow the pool")
    func oscillationNoLeak() {
        let engine = makeEngine()
        var runningMax = 0
        engine.sync()
        checkInvariants(engine, runningMax: &runningMax, "start")

        // 20 round-trips around the same path. If layers leaked, allocated would
        // climb past the peak; checkInvariants asserts it never does.
        for i in 0..<20 {
            engine.pan(byScreenDelta: CGSize(width: 400, height: 300))
            checkInvariants(engine, runningMax: &runningMax, "out \(i)")
            engine.pan(byScreenDelta: CGSize(width: -400, height: -300))
            checkInvariants(engine, runningMax: &runningMax, "back \(i)")
        }
    }

    @Test("returning to the start transform reproduces the same visible set")
    func returnToStartIsStable() {
        let engine = makeEngine()
        let start = engine.transform
        engine.sync()
        let startVisible = Set(engine.currentVisibleTiles().map(\.id))

        engine.pan(byScreenDelta: CGSize(width: -1_234, height: 880))
        engine.zoom(by: 2.0, aroundScreenPoint: CGPoint(x: 300, y: 200))
        engine.setTransform(start) // back exactly

        #expect(Set(engine.currentVisibleTiles().map(\.id)) == startVisible)
        #expect(engine.activeLayerCount == startVisible.count)
    }

    @Test("a prefetch margin realizes strictly more tiles than no margin")
    func marginExpandsRealizedSet() {
        let noMargin = makeEngine(margin: 0)
        noMargin.sync()
        let withMargin = makeEngine(margin: 300)
        withMargin.sync()
        #expect(withMargin.activeLayerCount > noMargin.activeLayerCount)
        // And the invariant still holds with a margin.
        #expect(withMargin.activeLayerCount == withMargin.currentVisibleTiles().count)
    }
}
