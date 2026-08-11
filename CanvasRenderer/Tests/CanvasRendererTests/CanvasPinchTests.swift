import CoreGraphics
import Testing
@testable import CanvasRenderer

/// 018 · C7 / 086 — the pinch gesture bracket.
///
/// The gesture seam lives on ``CanvasEngine`` rather than on the host view for
/// exactly this reason: a `swift test` process has no way to make an `NSEvent`, so
/// anything that could only be reached through `magnify(with:)` could only be checked
/// by hand. What is pinned here is the whole contract the smoothing rests on —
/// coalescing N events into one sync must land on the SAME camera as serving them one
/// at a time, or the optimisation is a behaviour change wearing a performance costume.
@MainActor
@Suite("Pinch gesture (018 · C7)")
struct CanvasPinchTests {
    private func makeEngine(scale: CGFloat = 0.5) -> CanvasEngine {
        let provider = DummyTileProvider(
            seed: 0xC7C7,
            config: DummyTileGenerator.Config(count: 600, clusterCount: 12))
        return CanvasEngine(
            provider: provider,
            images: FixtureImageSet(count: 12, seed: 4),
            transform: CanvasTransform(scale: scale, translation: CGPoint(x: 500, y: 350)),
            viewportSize: CGSize(width: 1_000, height: 700))
    }

    /// A dense, uniform board for the LOD tests. The clustered `DummyTileProvider` is
    /// right for the camera arithmetic but wrong here: zooming 10x into a clustered
    /// board can land the viewport in the empty space *between* clusters, and a
    /// re-tier assertion over zero visible tiles passes or fails on spatial luck
    /// rather than on the behaviour. A grid always has tiles under the anchor.
    private func makeGridEngine(scale: CGFloat) -> CanvasEngine {
        let engine = CanvasEngine(
            provider: GridTileProvider(cols: 24, rows: 24, pitch: 260, edge: 200),
            images: FixtureImageSet(count: 8, seed: 7),
            transform: CanvasTransform(scale: scale, translation: CGPoint(x: 0, y: 0)),
            viewportSize: CGSize(width: 1_000, height: 700))
        // The anchor sits over the middle of the grid at any zoom, so the tiles the
        // gesture freezes are the tiles still on screen when it settles.
        engine.setTransform(engine.transform.settingCamera(
            CanvasCamera(centre: CGPoint(x: 24 * 260 / 2, y: 24 * 260 / 2), zoom: scale),
            viewportSize: engine.viewportSize))
        return engine
    }

    private static let anchor = CGPoint(x: 500, y: 350)
    /// One pinch's worth of events — deliberately uneven, so a bug that only shows up
    /// when the factors differ cannot hide behind a uniform sweep.
    private static let factors: [CGFloat] = [1.02, 1.05, 1.01, 1.08, 1.03, 0.99, 1.04]

    // MARK: The equivalence that licenses the coalescing

    @Test("a coalesced gesture lands on the same transform as event-by-event zooms")
    func terminalEquivalence() {
        let direct = makeEngine()
        for factor in Self.factors { direct.zoom(by: factor, aroundScreenPoint: Self.anchor) }

        let gestured = makeEngine()
        gestured.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors { gestured.updateZoomGesture(by: factor) }
        gestured.endZoomGesture()

        #expect(Approx.equal(gestured.transform.scale, direct.transform.scale))
        #expect(Approx.equal(gestured.transform.translation, direct.transform.translation))
    }

    @Test("committing mid-gesture does not change where the gesture ends up")
    func partialCommitsAreInvisible() {
        let whole = makeEngine()
        whole.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors { whole.updateZoomGesture(by: factor) }
        whole.endZoomGesture()

        // The same events, but with a vsync landing after every single one — the
        // worst case for accumulated float drift.
        let stepped = makeEngine()
        stepped.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors {
            stepped.updateZoomGesture(by: factor)
            stepped.commitZoomGesture()
        }
        stepped.endZoomGesture()

        #expect(Approx.equal(stepped.transform.scale, whole.transform.scale))
        #expect(Approx.equal(stepped.transform.translation, whole.transform.translation))
    }

    @Test("the world point under the anchor is fixed for the whole gesture")
    func anchorIsAFixedPoint() {
        let engine = makeEngine()
        let before = engine.transform.screenToWorld(Self.anchor)

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors {
            engine.updateZoomGesture(by: factor)
            engine.commitZoomGesture() // a vsync mid-gesture must not slide the anchor
            #expect(Approx.equal(engine.transform.screenToWorld(Self.anchor), before, tol: 1e-5))
        }
        engine.endZoomGesture()
        #expect(Approx.equal(engine.transform.screenToWorld(Self.anchor), before, tol: 1e-5))
    }

    // MARK: What the bracket is actually for

    @Test("events accumulate without syncing; only a commit relayouts")
    func updatesDoNotSync() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.syncCount

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors { engine.updateZoomGesture(by: factor) }
        #expect(engine.syncCount == baseline, "accumulating must not touch the layer tree")

        engine.commitZoomGesture()
        #expect(engine.syncCount == baseline + 1, "one commit, one relayout")
    }

    @Test("a whole gesture costs two syncs, not one per event")
    func gestureSyncBudget() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.syncCount

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors { engine.updateZoomGesture(by: factor) }
        engine.endZoomGesture()

        // The commit, plus the re-tier that un-freezes LOD. Seven events, two syncs —
        // the old path would have paid seven.
        #expect(engine.syncCount == baseline + 2)
    }

    @Test("a commit with nothing outstanding costs nothing")
    func idleCommitIsFree() {
        let engine = makeEngine()
        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        engine.sync()
        let baseline = engine.syncCount

        #expect(engine.commitZoomGesture() == false)
        #expect(engine.syncCount == baseline, "a vsync during a pause must not relayout")
    }

    // MARK: Notifications — once, at the end

    @Test("the transform notification fires once per gesture, not once per event")
    func notifiesOnceAtEnd() {
        let engine = makeEngine()
        var notifications = 0
        engine.onTransformChanged = { notifications += 1 }

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for factor in Self.factors {
            engine.updateZoomGesture(by: factor)
            engine.commitZoomGesture()
        }
        #expect(notifications == 0, "listeners must not hear a camera that is still moving")

        engine.endZoomGesture()
        #expect(notifications == 1)
    }

    @Test("a gesture that never moves leaves no trace")
    func restingFingersAreNotACameraChange() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.syncCount
        var notifications = 0
        engine.onTransformChanged = { notifications += 1 }
        let before = engine.transform

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        engine.endZoomGesture()

        #expect(notifications == 0)
        #expect(engine.syncCount == baseline)
        #expect(engine.transform == before)
    }

    // MARK: Lifecycle

    @Test("an unclosed gesture is closed rather than leaked into the next one")
    func reBeginClosesThePrevious() {
        let engine = makeEngine()
        var notifications = 0
        engine.onTransformChanged = { notifications += 1 }

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        engine.updateZoomGesture(by: 1.4)
        // No `.ended` — the device dropped it. The next pinch must still start clean.
        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        #expect(notifications == 1, "the abandoned gesture settled instead of vanishing")
        #expect(engine.isZoomGestureActive)

        engine.endZoomGesture()
        #expect(engine.isZoomGestureActive == false)
    }

    @Test("updates outside a gesture are refused rather than applied silently")
    func updateWithoutBeginIsARefusal() {
        let engine = makeEngine()
        let before = engine.transform
        #expect(engine.updateZoomGesture(by: 1.5) == false)
        #expect(engine.commitZoomGesture() == false)
        #expect(engine.transform == before)
    }

    @Test("a non-finite or non-positive factor cannot collapse or mirror the board")
    func badFactorsAreDiscarded() {
        let engine = makeEngine()
        let before = engine.transform
        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for bad: CGFloat in [0, -1, -0.5, .nan, .infinity] {
            #expect(engine.updateZoomGesture(by: bad) == false)
        }
        engine.endZoomGesture()
        #expect(engine.transform == before)
    }

    // MARK: LOD freeze (the decode churn this exists to kill)

    @Test("tiers are frozen for the gesture and re-tiered once at settle")
    func lodIsFrozenWhilePinching() {
        // Start small on screen (a 200-unit tile at 0.08 is 16pt — tier .low), then
        // zoom hard enough to cross into the next tier: the crossing is what used to
        // request a decode the following event cancelled.
        let engine = makeGridEngine(scale: 0.08)
        engine.sync()
        let sampled = engine.currentVisibleTiles().prefix(20).map(\.id)
        #expect(!sampled.isEmpty, "the test needs tiles on screen")
        let tiersBefore = sampled.map { engine.cacheKey(forTileID: $0)?.tier }

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for _ in 0..<40 {
            engine.updateZoomGesture(by: 1.06)
            engine.commitZoomGesture()
            for (id, before) in zip(sampled, tiersBefore) where engine.cacheKey(forTileID: id) != nil {
                #expect(engine.cacheKey(forTileID: id)?.tier == before,
                        "tile \(id) re-tiered mid-gesture")
            }
        }
        // The frozen tiers of exactly the tiles that will still be on screen when the
        // fingers lift — sampled here rather than from the pre-gesture set, because a
        // ~10x zoom-in carries most of that set off the viewport and a tile that left
        // can say nothing about re-tiering.
        let frozen = engine.currentVisibleTiles().reduce(into: [Int: LODTier]()) { acc, tile in
            if let tier = engine.cacheKey(forTileID: tile.id)?.tier { acc[tile.id] = tier }
        }
        #expect(!frozen.isEmpty, "the settle assertion needs tiles on screen at the end")
        engine.endZoomGesture()

        let moved = frozen.contains { id, tier in engine.cacheKey(forTileID: id)?.tier != tier }
        #expect(moved, "settling must re-tier what the gesture froze")
    }

    @Test("a tile entering the viewport mid-gesture is tiered, not frozen blank")
    func newTilesAreNotFrozen() {
        let engine = makeGridEngine(scale: 0.4)
        engine.sync()
        let known = Set(engine.currentVisibleTiles().map(\.id))

        engine.beginZoomGesture(anchorScreenPoint: Self.anchor)
        for _ in 0..<12 {
            engine.updateZoomGesture(by: 0.92) // zoom OUT — pulls new tiles in
            engine.commitZoomGesture()
        }
        let arrivals = engine.currentVisibleTiles().map(\.id).filter { !known.contains($0) }
        #expect(!arrivals.isEmpty, "zooming out should have pulled in new tiles")
        for id in arrivals {
            #expect(engine.cacheKey(forTileID: id) != nil, "tile \(id) arrived with no tier")
        }
        engine.endZoomGesture()
    }
}

/// A uniform grid of image tiles — dense everywhere, so a zoom never lands the
/// viewport on empty world space (see ``CanvasPinchTests/makeGridEngine(scale:)``).
private struct GridTileProvider: TileProvider {
    let tiles: [Tile]

    init(cols: Int, rows: Int, pitch: Double, edge: Double) {
        tiles = (0..<(cols * rows)).map { i in
            Tile(id: i, x: Double(i % cols) * pitch, y: Double(i / cols) * pitch,
                 w: edge, h: edge, z: i)
        }
    }
}

/// The pure accumulator, checked on its own so a failure above is never ambiguous
/// between "the arithmetic is wrong" and "the engine wired it up wrong".
@Suite("CanvasZoomGesture")
struct CanvasZoomGestureTests {
    @Test("factors multiply")
    func accumulates() {
        var gesture = CanvasZoomGesture(anchor: .zero)
        gesture.accumulate(2)
        gesture.accumulate(3)
        #expect(gesture.pendingFactor == 6)
        #expect(gesture.totalFactor == 6)
    }

    @Test("taking the pending factor moves it to committed")
    func takeMovesPendingToCommitted() {
        var gesture = CanvasZoomGesture(anchor: .zero)
        gesture.accumulate(2)
        #expect(gesture.takePending() == 2)
        #expect(gesture.pendingFactor == 1)
        #expect(gesture.committedFactor == 2)

        gesture.accumulate(3)
        #expect(gesture.takePending() == 3)
        #expect(gesture.committedFactor == 6, "committed is the running product")
        #expect(gesture.totalFactor == 6)
    }

    @Test("nothing outstanding takes nothing")
    func takeWithNothingPending() {
        var gesture = CanvasZoomGesture(anchor: .zero)
        #expect(gesture.takePending() == nil)
        gesture.accumulate(1.5)
        _ = gesture.takePending()
        #expect(gesture.takePending() == nil)
    }

    @Test("unusable factors are refused and change nothing")
    func rejectsBadFactors() {
        var gesture = CanvasZoomGesture(anchor: .zero)
        for bad: CGFloat in [0, -2, .nan, .infinity, -.infinity] {
            #expect(gesture.accumulate(bad) == false)
        }
        #expect(gesture.pendingFactor == 1)
        #expect(gesture.hasMoved == false)
    }

    @Test("hasMoved covers both committed and pending motion")
    func hasMoved() {
        var gesture = CanvasZoomGesture(anchor: .zero)
        #expect(gesture.hasMoved == false)
        gesture.accumulate(1.2)
        #expect(gesture.hasMoved, "pending motion counts")
        _ = gesture.takePending()
        #expect(gesture.hasMoved, "committed motion still counts")
    }

    @Test("the anchor is captured once and never drifts")
    func anchorIsStable() {
        var gesture = CanvasZoomGesture(anchor: CGPoint(x: 12, y: 34))
        gesture.accumulate(1.5)
        _ = gesture.takePending()
        #expect(gesture.anchor == CGPoint(x: 12, y: 34))
    }
}
