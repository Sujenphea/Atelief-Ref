import CoreGraphics
import XCTest
@testable import CanvasRenderer

/// The spike's go/no-go gate (decision T10): does the Core Animation renderer
/// hold the 120fps per-frame budget at the P13 target (~5,000 tiles), and is the
/// memory profile bounded?
///
/// `measure {}` (Swift Testing has no perf-measurement story, so this is XCTest)
/// records `XCTClockMetric` + `XCTMemoryMetric` for regression baselines. The
/// hard pass/fail gate is the explicit per-frame budget assertion, which works
/// headlessly under `swift test` without a stored baseline.
///
/// This measures the **main-thread** per-frame cost — cull + layer sync — with
/// the cache pre-warmed so off-main decode (decision P15) is correctly excluded.
/// Real on-screen fps is a manual Instruments check, not this test.
final class CanvasBenchmark: XCTestCase {
    /// P13: ~5,000 tiles; 120fps ⇒ 8.33ms/frame.
    private static let tileCount = 5_000
    private static let frameBudgetMs = 8.33
    private static let viewport = CGSize(width: 1_440, height: 900)

    @MainActor
    private func makeWarmEngine() -> CanvasEngine {
        let provider = DummyTileProvider(
            seed: 0xCAFE,
            config: DummyTileGenerator.Config(count: Self.tileCount, clusterCount: 40)
        )
        let engine = CanvasEngine(
            provider: provider,
            images: FixtureImageSet(count: 24, seed: 9),
            // Zoomed out + centred so the viewport covers many clusters at once.
            transform: CanvasTransform(scale: 0.06, translation: CGPoint(x: 720, y: 450)),
            viewportSize: Self.viewport
        )
        engine.prefetchMarginScreen = 200
        engine.sync()
        engine.warmVisibleBlocking() // decode out of the measured frame path
        engine.sync()
        return engine
    }

    /// Hard gate: average per-frame cull + layer-sync stays under the 120fps
    /// budget while continuously panning.
    @MainActor
    func testFrameUpdateWithinBudget() {
        let engine = makeWarmEngine()
        XCTAssertGreaterThan(engine.activeLayerCount, 100, "benchmark must run over real content")

        let frames = 240
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<frames {
                // Small oscillating pan: stresses cull + reposition while staying
                // within the warmed region (so we measure sync, not decode).
                let dx: CGFloat = (i % 2 == 0) ? -6 : 6
                engine.pan(byScreenDelta: CGSize(width: dx, height: 3))
            }
        }

        let perFrameMs = elapsed.milliseconds / Double(frames)
        print("[canvas-benchmark] tiles=\(engine.activeLayerCount) "
              + "per-frame=\(String(format: "%.3f", perFrameMs))ms "
              + "budget=\(Self.frameBudgetMs)ms "
              + "cacheMB=\(engine.cacheResidentBytes / (1024 * 1024))")
        XCTAssertLessThan(perFrameMs, Self.frameBudgetMs,
                          "per-frame cull+layer-sync exceeds the 120fps budget")
    }

    /// E3 regression guard (decision T3): a board of many *vector* elements —
    /// frames (pooled-layer border/fill) + text (`CATextLayer` siblings) — stays
    /// well within the per-frame budget while panning. Vector tiles bypass decode
    /// entirely, so no warming is needed; the cost is cull + layer/overlay sync.
    @MainActor
    func testVectorElementsWithinBudget() {
        let elementCount = 400
        let provider = VectorBenchProvider(count: elementCount)
        let engine = CanvasEngine(
            provider: provider, images: FixtureImageSet(count: 1, seed: 1),
            transform: CanvasTransform(scale: 0.5, translation: CGPoint(x: 720, y: 450)),
            viewportSize: Self.viewport)
        engine.sync()
        XCTAssertGreaterThan(engine.activeLayerCount, 50, "benchmark must run over real content")

        let frames = 240
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<frames {
                let dx: CGFloat = (i % 2 == 0) ? -6 : 6
                engine.pan(byScreenDelta: CGSize(width: dx, height: 3))
            }
        }
        let perFrameMs = elapsed.milliseconds / Double(frames)
        print("[canvas-benchmark] vector elements=\(engine.activeLayerCount) "
              + "textOverlays=\(engine.textOverlayCount) "
              + "per-frame=\(String(format: "%.3f", perFrameMs))ms budget=\(Self.frameBudgetMs)ms")
        XCTAssertLessThan(perFrameMs, Self.frameBudgetMs,
                          "per-frame vector sync exceeds the 120fps budget")
    }

    /// Records clock + memory metrics for regression baselines; also asserts the
    /// cache stays within its ceiling (the bounded memory profile P13 requires).
    @MainActor
    func testFrameCostMetrics() {
        let engine = makeWarmEngine()
        let start = engine.transform

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            engine.setTransform(start) // reset so each iteration is comparable
            for i in 0..<60 {
                let dx: CGFloat = (i % 2 == 0) ? -8 : 8
                engine.pan(byScreenDelta: CGSize(width: dx, height: 4))
            }
        }

        // Cache ceiling default is 256 MB; the working set must stay well under.
        XCTAssertLessThan(engine.cacheResidentBytes, 256 * 1024 * 1024)
        print("[canvas-benchmark] resident cache = \(engine.cacheResidentBytes / (1024 * 1024)) MB")
    }
}

/// A deterministic grid of alternating frame + text elements for the E3 vector
/// benchmark. Every tile is a vector element (no images), laid out so a chunk is
/// visible in the benchmark viewport.
private struct VectorBenchProvider: TileProvider {
    let tiles: [Tile]
    private let kinds: [TileContent]

    init(count: Int) {
        let cols = 20
        var tiles: [Tile] = []
        var kinds: [TileContent] = []
        for i in 0..<count {
            let (r, c) = (i / cols, i % cols)
            tiles.append(Tile(
                id: i, x: Double(c) * 320, y: Double(r) * 260, w: 300, h: 220, z: i))
            if i.isMultiple(of: 2) {
                kinds.append(.frame(FrameStyle(
                    fill: RGBAColor(red: 0.9, green: 0.9, blue: 0.95, alpha: 0.3),
                    stroke: RGBAColor(red: 0.2, green: 0.2, blue: 0.3), strokeWidth: 3,
                    cornerRadius: 6,
                    label: TextStyle(string: "Frame \(i)", fontSize: 16,
                                     color: RGBAColor(red: 0, green: 0, blue: 0)))))
            } else {
                kinds.append(.text(TextStyle(
                    string: "Note \(i)\nsecond line", fontSize: 18,
                    color: RGBAColor(red: 0.1, green: 0.1, blue: 0.1))))
            }
        }
        self.tiles = tiles
        self.kinds = kinds
    }

    func content(for tile: Tile) -> TileContent {
        kinds.indices.contains(tile.id) ? kinds[tile.id] : .image
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
