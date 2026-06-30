import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("CanvasTransform")
struct CanvasTransformTests {

    // Representative axes for the parameterized sweeps. Deterministic by
    // construction (decision T12) — no RNG needed here.
    static let scales: [CGFloat] = [0.02, 0.1, 0.5, 1, 2.5, 10, 64]
    static let translations: [CGPoint] = [
        .zero, CGPoint(x: 13, y: -27), CGPoint(x: -500, y: 800), CGPoint(x: 1024, y: 768)
    ]
    static let points: [CGPoint] = [
        .zero, CGPoint(x: 1, y: 1), CGPoint(x: -42, y: 17),
        CGPoint(x: 1_000, y: -2_000), CGPoint(x: 10_000_000, y: -10_000_000) // large-coord precision (C7)
    ]

    // MARK: Round-trip (the bug class C6 exists to prevent)

    @Test("screen↔world round-trips to the same point", arguments: scales, translations)
    func pointRoundTrip(scale: CGFloat, translation: CGPoint) {
        let t = CanvasTransform(scale: scale, translation: translation)
        for p in Self.points {
            let back = t.screenToWorld(t.worldToScreen(p))
            #expect(Approx.equal(back, p), "world→screen→world drifted for \(p) at scale \(scale)")
            let forward = t.worldToScreen(t.screenToWorld(p))
            #expect(Approx.equal(forward, p), "screen→world→screen drifted for \(p) at scale \(scale)")
        }
    }

    @Test("rect round-trips through screen space", arguments: scales)
    func rectRoundTrip(scale: CGFloat) {
        let t = CanvasTransform(scale: scale, translation: CGPoint(x: 100, y: -50))
        let r = CGRect(x: -300, y: 120, width: 640, height: 480)
        #expect(Approx.equal(t.screenToWorld(t.worldToScreen(r)), r))
    }

    // MARK: Zoom clamping (C7)

    @Test("scale is clamped into [minScale, maxScale] at construction")
    func scaleClampedOnInit() {
        let t1 = CanvasTransform(scale: 1000, minScale: 0.1, maxScale: 8)
        #expect(t1.scale == 8)
        let t2 = CanvasTransform(scale: 0.0001, minScale: 0.1, maxScale: 8)
        #expect(t2.scale == 0.1)
    }

    @Test("a zero / negative scale request clamps to a positive minScale (no divide-by-zero)")
    func scaleZeroGuard() {
        let t = CanvasTransform(scale: 0, minScale: 0.05, maxScale: 8)
        #expect(t.scale == 0.05)
        let world = t.screenToWorld(CGPoint(x: 123, y: 456))
        #expect(world.x.isFinite && world.y.isFinite)
    }

    @Test("zoom respects the clamp limits", arguments: [0.0001, 0.5, 2, 100_000] as [CGFloat])
    func zoomClamped(factor: CGFloat) {
        let t = CanvasTransform(scale: 1, minScale: 0.1, maxScale: 8)
        let zoomed = t.zoomed(by: factor, aroundScreenPoint: CGPoint(x: 400, y: 300))
        #expect(zoomed.scale >= 0.1 && zoomed.scale <= 8)
    }

    // MARK: Zoom keeps the anchor fixed

    @Test("zooming around an anchor keeps that screen point's world position fixed",
          arguments: [0.25, 0.5, 2, 4] as [CGFloat])
    func zoomAnchorStaysFixed(factor: CGFloat) {
        let t = CanvasTransform(scale: 1.5, translation: CGPoint(x: 60, y: -40), minScale: 0.1, maxScale: 32)
        let anchor = CGPoint(x: 512, y: 384)
        let worldUnderAnchor = t.screenToWorld(anchor)
        let zoomed = t.zoomed(by: factor, aroundScreenPoint: anchor)
        // The same world point must still sit under the anchor on screen.
        #expect(Approx.equal(zoomed.worldToScreen(worldUnderAnchor), anchor))
    }

    @Test("anchor stays fixed even when the zoom saturates a clamp")
    func zoomAnchorFixedAtClamp() {
        let t = CanvasTransform(scale: 7, translation: .zero, minScale: 0.1, maxScale: 8)
        let anchor = CGPoint(x: 300, y: 200)
        let worldUnderAnchor = t.screenToWorld(anchor)
        let zoomed = t.zoomed(by: 100, aroundScreenPoint: anchor) // would exceed maxScale
        #expect(zoomed.scale == 8)
        #expect(Approx.equal(zoomed.worldToScreen(worldUnderAnchor), anchor))
    }

    // MARK: Pan

    @Test("panning shifts the translation and screen positions by the delta")
    func panShiftsByDelta() {
        let t = CanvasTransform(scale: 2, translation: CGPoint(x: 10, y: 10))
        let delta = CGSize(width: 25, height: -15)
        let panned = t.panned(byScreenDelta: delta)
        #expect(Approx.equal(panned.translation, CGPoint(x: 35, y: -5)))
        let p = CGPoint(x: 4, y: 4)
        let expected = CGPoint(x: t.worldToScreen(p).x + 25, y: t.worldToScreen(p).y - 15)
        #expect(Approx.equal(panned.worldToScreen(p), expected))
    }

    @Test("panning leaves scale unchanged")
    func panKeepsScale() {
        let t = CanvasTransform(scale: 3.3)
        #expect(t.panned(byScreenDelta: CGSize(width: 99, height: 99)).scale == 3.3)
    }

    // MARK: Visible world rect

    @Test("visibleWorldRect equals the viewport mapped back to world space", arguments: scales)
    func visibleWorldRectMatchesMapping(scale: CGFloat) {
        let t = CanvasTransform(scale: scale, translation: CGPoint(x: -200, y: 75))
        let size = CGSize(width: 1280, height: 800)
        let rect = t.visibleWorldRect(viewportSize: size)
        #expect(Approx.equal(rect.origin, t.screenToWorld(.zero)))
        #expect(Approx.equal(rect.size.width, size.width / scale))
        #expect(Approx.equal(rect.size.height, size.height / scale))
    }

    @Test("zooming out enlarges the visible world rect")
    func zoomOutEnlargesVisibleRect() {
        let size = CGSize(width: 1000, height: 1000)
        let zoomedIn = CanvasTransform(scale: 4).visibleWorldRect(viewportSize: size)
        let zoomedOut = CanvasTransform(scale: 0.25).visibleWorldRect(viewportSize: size)
        #expect(zoomedOut.width > zoomedIn.width)
        #expect(zoomedOut.height > zoomedIn.height)
    }
}
