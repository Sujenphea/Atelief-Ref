import CoreGraphics
import Testing
@testable import CanvasRenderer

/// 099 · P12 — ⌘-wheel zooms about the cursor.
///
/// Split into two halves for the reason 086 gives: a `swift test` process cannot
/// synthesize an `NSEvent`, so anything reachable only through `scrollWheel(with:)`
/// could only be checked by hand. The decision the event drives is therefore a pure
/// function (``CanvasZoomGesture/scrollIntent(commandHeld:scrollDeltaX:scrollDeltaY:precise:)``)
/// and the path it takes afterwards is the engine's own pinch bracket — both testable
/// here, leaving `scrollWheel` a switch with nothing in it to get wrong.
@Suite("Wheel zoom (099 · P12)")
struct CanvasWheelZoomTests {

    // MARK: - What a scroll event means

    @Test("a bare wheel still pans, on both axes")
    func bareWheelPans() {
        let intent = CanvasZoomGesture.scrollIntent(
            commandHeld: false, scrollDeltaX: 12, scrollDeltaY: -8, precise: true)
        #expect(intent == .pan(CGSize(width: 12, height: -8)))
    }

    @Test("⌘ turns the same event into a zoom")
    func commandWheelZooms() {
        let intent = CanvasZoomGesture.scrollIntent(
            commandHeld: true, scrollDeltaX: 12, scrollDeltaY: -8, precise: true)
        guard case .zoom = intent else {
            Issue.record("⌘-wheel must zoom, got \(intent)")
            return
        }
    }

    @Test("the horizontal delta is ignored while zooming — a zoom has one axis")
    func zoomReadsOnlyTheVerticalDelta() {
        let withX = CanvasZoomGesture.scrollIntent(
            commandHeld: true, scrollDeltaX: 400, scrollDeltaY: 10, precise: true)
        let withoutX = CanvasZoomGesture.scrollIntent(
            commandHeld: true, scrollDeltaX: 0, scrollDeltaY: 10, precise: true)
        #expect(withX == withoutX)
    }

    // MARK: - The factor

    @Test("scrolling up zooms in and scrolling down zooms out")
    func directionFollowsTheDelta() {
        #expect(CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 10, precise: true) > 1)
        #expect(CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: -10, precise: true) < 1)
    }

    /// The one that fails if the factor is ever rewritten as `1 + k·delta`.
    ///
    /// Zoom composes by multiplication, so "scroll up 40, scroll back down 40" is the
    /// product of the two factors. Only `exp` makes that product exactly 1; with a
    /// linear factor `(1 + k)(1 − k) = 1 − k²`, so every up-down pair shrinks the
    /// board by a hair and a minute of fiddling has visibly zoomed out.
    @Test("opposite deltas cancel EXACTLY, which is why the factor is exponential")
    func oppositeDeltasCancelExactly() {
        for delta: CGFloat in [1, 7.5, 40, 113] {
            for precise in [true, false] {
                let up = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: precise)
                let down = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: -delta, precise: precise)
                #expect(Approx.equal(up * down, 1),
                        "delta \(delta), precise \(precise) drifted to \(up * down)")
            }
        }
    }

    @Test("a whole gesture is the product of its events, in any grouping")
    func factorsComposeAcrossEvents() {
        // Three events of 10 must land where one event of 30 does — otherwise the
        // accumulator's coalescing would change the result of a wheel sweep.
        let stepped = (0..<3).reduce(CGFloat(1)) { product, _ in
            product * CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 10, precise: true)
        }
        let whole = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 30, precise: true)
        #expect(Approx.equal(stepped, whole))
    }

    @Test("a trackpad point is worth less than a mouse-wheel line")
    func preciseDeltasAreGentler() {
        // Precise deltas arrive in screen points, tens per event; line deltas arrive
        // one to three per notch. Sharing an exponent would make one of the two
        // devices unusable.
        let precise = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 1, precise: true)
        let line = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 1, precise: false)
        #expect(precise < line)
        #expect(CanvasZoomGesture.preciseWheelExponent < CanvasZoomGesture.lineWheelExponent)
    }

    @Test("a resting wheel leaves no trace at all")
    func zeroDeltaIsExactlyANoOp() {
        let factor = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 0, precise: true)
        #expect(factor == 1)

        var gesture = CanvasZoomGesture(anchor: .zero)
        gesture.accumulate(factor)
        #expect(gesture.takePending() == nil, "a no-op factor must not cost a commit")
        #expect(gesture.hasMoved == false)
    }

    @Test("a non-finite delta cannot reach the transform")
    func nonFiniteDeltaIsRejected() {
        for delta in [CGFloat.nan, .infinity, -.infinity] {
            #expect(CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true) == 1)
        }
    }

    /// Clamped rather than left to overflow. `exp(10_000 × 0.01)` is `+inf`, and
    /// ``CanvasZoomGesture/accumulate(_:)`` silently discards a non-finite factor — so
    /// without the clamp a spurious hardware event would zoom by nothing at all, which
    /// is the one outcome the user cannot explain.
    @Test("an absurd delta is clamped to something the accumulator will still take")
    func hugeDeltaStaysUsable() {
        for delta: CGFloat in [10_000, -10_000, 1e12] {
            let factor = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true)
            #expect(factor.isFinite)
            #expect(factor > 0)

            var gesture = CanvasZoomGesture(anchor: .zero)
            let accepted = gesture.accumulate(factor)
            #expect(accepted, "delta \(delta) produced an unusable factor")
        }
    }

    // MARK: - Through the pinch's bracket

    @MainActor
    private func makeEngine() -> CanvasEngine {
        CanvasEngine(
            provider: DummyTileProvider(
                seed: 0x9312,
                config: DummyTileGenerator.Config(count: 600, clusterCount: 12)),
            images: FixtureImageSet(count: 8, seed: 11),
            transform: CanvasTransform(scale: 0.5, translation: CGPoint(x: 500, y: 350)),
            viewportSize: CGSize(width: 1_000, height: 700))
    }

    /// One trackpad ⌘-scroll's worth of deltas — uneven, so a bug that only shows up
    /// when the events differ cannot hide behind a uniform sweep.
    private static let deltas: [CGFloat] = [6, 14, 3, 21, -4, 9]
    private static let cursor = CGPoint(x: 640, y: 210)

    @MainActor
    @Test("the world point under the CURSOR is what stays still — not the centre")
    func zoomsAboutTheCursor() {
        let engine = makeEngine()
        let under = engine.transform.screenToWorld(Self.cursor)

        engine.beginZoomGesture(anchorScreenPoint: Self.cursor)
        for delta in Self.deltas {
            engine.updateZoomGesture(
                by: CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true))
            engine.commitZoomGesture()
            #expect(Approx.equal(engine.transform.screenToWorld(Self.cursor), under, tol: 1e-5))
        }
        engine.endZoomGesture()

        #expect(Approx.equal(engine.transform.screenToWorld(Self.cursor), under, tol: 1e-5))
        #expect(engine.transform.scale != 0.5, "the sweep must actually have zoomed")
    }

    @MainActor
    @Test("a bracketed wheel sweep lands where event-by-event zooms would")
    func bracketMatchesDirectZooms() {
        let direct = makeEngine()
        for delta in Self.deltas {
            direct.zoom(by: CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true),
                        aroundScreenPoint: Self.cursor)
        }

        let bracketed = makeEngine()
        bracketed.beginZoomGesture(anchorScreenPoint: Self.cursor)
        for delta in Self.deltas {
            bracketed.updateZoomGesture(
                by: CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true))
        }
        bracketed.endZoomGesture()

        #expect(Approx.equal(bracketed.transform.scale, direct.transform.scale))
        #expect(Approx.equal(bracketed.transform.translation, direct.transform.translation))
    }

    /// The reason the wheel goes through the bracket rather than through
    /// `zoom(by:aroundScreenPoint:)`: the tier is frozen while the gesture is open, so
    /// a sweep re-lays the layers it has and re-tiers once at settle. Zooming directly
    /// would sync — and request, then cancel, a decode — on every event.
    @MainActor
    @Test("a wheel sweep freezes the tier until it settles, and costs two syncs")
    func sweepIsBracketedNotServed() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.syncCount

        engine.beginZoomGesture(anchorScreenPoint: Self.cursor)
        for delta in Self.deltas {
            engine.updateZoomGesture(
                by: CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: delta, precise: true))
            #expect(engine.isZoomGestureActive, "the tier must stay frozen mid-sweep")
        }
        #expect(engine.syncCount == baseline, "accumulating must not touch the layer tree")

        engine.endZoomGesture()
        #expect(!engine.isZoomGestureActive)
        // The commit plus the re-tier — six events, two syncs.
        #expect(engine.syncCount == baseline + 2)
    }

    /// A mouse-wheel notch reports no phase, so `scrollWheel` brackets it on its own
    /// (`zoomDiscretely`). It must still be a whole gesture: frozen across the commit,
    /// re-tiered once, and one notification — not a bare `zoom(by:)`.
    @MainActor
    @Test("a single unphased notch is still a whole gesture")
    func oneNotchIsOneGesture() {
        let engine = makeEngine()
        engine.sync()
        let baseline = engine.syncCount
        var notifications = 0
        engine.onTransformChanged = { notifications += 1 }

        let factor = CanvasZoomGesture.wheelZoomFactor(scrollDeltaY: 3, precise: false)
        engine.beginZoomGesture(anchorScreenPoint: Self.cursor)
        engine.updateZoomGesture(by: factor)
        engine.endZoomGesture()

        #expect(!engine.isZoomGestureActive)
        #expect(notifications == 1, "one notch, one camera notification")
        #expect(engine.syncCount == baseline + 2)
        #expect(Approx.equal(engine.transform.scale, 0.5 * factor))
    }
}
