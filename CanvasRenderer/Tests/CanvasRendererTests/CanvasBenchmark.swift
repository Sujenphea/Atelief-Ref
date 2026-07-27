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
            // 0.25 (not 0.5): the grid is 320×260-pitched, so a half-scale camera
            // only ever covered ~30 elements and the ">50 real content" guard below
            // could not pass. This zoom actually fills the viewport with vectors.
            transform: CanvasTransform(scale: 0.25, translation: CGPoint(x: 720, y: 450)),
            viewportSize: Self.viewport)
        engine.sync()
        XCTAssertGreaterThan(engine.activeLayerCount, 50, "benchmark must run over real content")

        let frames = 240
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<frames {
                // Oscillate BOTH axes. A constant +3 y-step drifted 720 points
                // over the run, walking the board clean off the viewport so the
                // tail of the benchmark measured an empty scene.
                let dx: CGFloat = (i % 2 == 0) ? -6 : 6
                let dy: CGFloat = (i % 2 == 0) ? -3 : 3
                engine.pan(byScreenDelta: CGSize(width: dx, height: dy))
            }
        }
        let perFrameMs = elapsed.milliseconds / Double(frames)
        XCTAssertGreaterThan(engine.activeLayerCount, 50, "board must stay in view for the whole run")
        print("[canvas-benchmark] vector elements=\(engine.activeLayerCount) "
              + "textOverlays=\(engine.textOverlayCount) "
              + "per-frame=\(String(format: "%.3f", perFrameMs))ms budget=\(Self.frameBudgetMs)ms")
        XCTAssertLessThan(perFrameMs, Self.frameBudgetMs,
                          "per-frame vector sync exceeds the 120fps budget")
    }

    // MARK: - 060 Step 4 gate: zoom-stable text

    /// The gate 061 Step 4 rides on. A worst-case board — every tile an
    /// OVERFLOWING text box, the case that used to reflow — swept across zooms on
    /// the CoreText path.
    ///
    /// Two costs are measured separately, because they land in different places:
    ///
    /// 1. **Sync** — the engine's per-frame work (cull, shape lookup, layer
    ///    geometry). This is all `sync()` does; it never rasterizes.
    /// 2. **Raster** — `draw(in:)` for every visible text layer. Core Animation
    ///    normally runs this on the render server AFTER the frame, so a sync-only
    ///    benchmark would silently miss the entire cost of the new path. Here it
    ///    is driven explicitly into a bitmap so it shows up.
    ///
    /// A zoom sweep is the adversarial case: every frame changes the layers'
    /// on-screen size, so every frame re-rasterizes. A pan re-rasterizes nothing.
    @MainActor
    func testGlyphTextWithinBudgetAcrossZooms() {
        let engine = makeTextBenchEngine()
        let overlays = engine.textOverlayCount
        XCTAssertGreaterThan(overlays, 80, "benchmark must run over real content")

        let syncMs = measureZoomSweepSyncMs(engine)
        let rasterMs = measureRasterMs(engine)

        print("[canvas-benchmark] glyph text overlays=\(overlays) "
              + "sync=\(String(format: "%.3f", syncMs))ms "
              + "raster=\(String(format: "%.3f", rasterMs))ms "
              + "total=\(String(format: "%.3f", syncMs + rasterMs))ms "
              + "budget=\(Self.frameBudgetMs)ms")

        XCTAssertLessThan(syncMs + rasterMs, Self.frameBudgetMs,
                          "per-frame zoom-sweep sync+raster exceeds the 120fps budget")
    }

    /// A board of text tiles whose strings comfortably overflow their boxes, so
    /// every tile exercises wrapping AND end-truncation.
    @MainActor
    private func makeTextBenchEngine() -> CanvasEngine {
        let engine = CanvasEngine(
            provider: TextBenchProvider(count: 400), images: FixtureImageSet(count: 1, seed: 1),
            // Half scale so the viewport holds ~120 overflowing boxes at once —
            // a genuinely dense text board, not a handful of notes.
            transform: CanvasTransform(scale: 0.5, translation: CGPoint(x: 40, y: 40)),
            viewportSize: Self.viewport)
        engine.sync()
        return engine
    }

    /// Average `sync()` cost per frame while zooming in and out continuously.
    @MainActor
    private func measureZoomSweepSyncMs(_ engine: CanvasEngine) -> Double {
        let frames = 240
        let anchor = CGPoint(x: Self.viewport.width / 2, y: Self.viewport.height / 2)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<frames {
                // Oscillate so the sweep stays in a sane zoom band while changing
                // scale every single frame.
                let factor: CGFloat = (i / 30) % 2 == 0 ? 1.02 : (1 / 1.02)
                engine.zoom(by: factor, aroundScreenPoint: anchor)
            }
        }
        return elapsed.milliseconds / Double(frames)
    }

    /// Average cost of rasterizing every visible glyph overlay once — the work
    /// Core Animation does per frame whenever the on-screen size changed.
    @MainActor
    private func measureRasterMs(_ engine: CanvasEngine) -> Double {
        let layers = (0..<400).compactMap { engine.textLayer(forTileID: $0) }
        guard !layers.isEmpty else { return 0 }
        guard let ctx = CGContext(
            data: nil, width: Int(Self.viewport.width), height: Int(Self.viewport.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }

        let passes = 20
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0..<passes {
                for layer in layers {
                    ctx.saveGState()
                    layer.draw(in: ctx)
                    ctx.restoreGState()
                }
            }
        }
        return elapsed.milliseconds / Double(passes)
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

/// The 060 worst case: a dense grid of text tiles whose strings overflow their
/// boxes, so every tile wraps to several lines and then end-truncates.
private struct TextBenchProvider: TileProvider {
    let tiles: [Tile]
    private let styles: [TextStyle]

    init(count: Int) {
        let cols = 12
        let body = "The quick brown fox jumps over the lazy dog, and then keeps "
            + "running well past the bottom edge of this box so the layout has to "
            + "wrap several times and truncate."
        var tiles: [Tile] = []
        var styles: [TextStyle] = []
        for i in 0..<count {
            let (r, c) = (i / cols, i % cols)
            tiles.append(Tile(
                id: i, x: Double(c) * 240, y: Double(r) * 180, w: 220, h: 160, z: i))
            styles.append(TextStyle(
                // Vary the string per tile so the shaping memo can't serve every
                // tile from one entry — a board of identical text would flatter it.
                string: "Note \(i). " + body,
                fontSize: 15 + Double(i % 4),
                color: RGBAColor(red: 0.1, green: 0.1, blue: 0.1),
                alignment: [.left, .center, .right][i % 3]))
        }
        self.tiles = tiles
        self.styles = styles
    }

    func content(for tile: Tile) -> TileContent {
        styles.indices.contains(tile.id) ? .text(styles[tile.id]) : .image
    }
}

private extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
