//
//  CanvasSnappingTests.swift
//  CanvasRendererTests
//
//  062 — snapping a resize to nearby boxes. Pure, so every rule is asserted
//  directly: what snaps, what must NOT snap, and what a snap may never do
//  (break the ratio, cross the minimum, or move an axis the handle doesn't own).
//

import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("Resize snapping (062)")
struct CanvasSnappingTests {

    /// One neighbour: x ∈ [500, 700] (mid 600), y ∈ [100, 300] (mid 200).
    private let neighbour = [CGRect(x: 500, y: 100, width: 200, height: 200)]
    private let threshold: CGFloat = 6

    // MARK: - The threshold is a SCREEN distance

    @Test("the world threshold shrinks as you zoom in, so the feel stays constant")
    func thresholdIsScreenRelative() {
        // 6 screen points is 60 world units at 0.1×, and 3 at 2×. A fixed WORLD
        // radius would be unusably sticky zoomed out and imperceptible zoomed in.
        #expect(CanvasSnapping.worldThreshold(scale: 0.1) == 60)
        #expect(CanvasSnapping.worldThreshold(scale: 1) == 6)
        #expect(CanvasSnapping.worldThreshold(scale: 2) == 3)
    }

    @Test("a degenerate zoom cannot produce an infinite snap radius")
    func degenerateZoomIsClamped() {
        for scale in [CGFloat(0), -1, 0.000_001] {
            let t = CanvasSnapping.worldThreshold(scale: scale)
            #expect(t.isFinite)
            #expect(t <= 600)
        }
    }

    // MARK: - Targets

    @Test("each candidate contributes its leading edge, centre, and trailing edge")
    func targetsIncludeCentres() {
        #expect(CanvasSnapping.targets(in: neighbour, vertical: true) == [500, 600, 700])
        #expect(CanvasSnapping.targets(in: neighbour, vertical: false) == [100, 200, 300])
    }

    // MARK: - Free (unlocked) snapping

    @Test("a dragged edge within the threshold jumps exactly onto the target")
    func nearEdgeSnaps() {
        let (point, guides) = CanvasSnapping.snapPoint(
            CGPoint(x: 497, y: 0), handle: .right, candidates: neighbour, threshold: threshold)
        #expect(point.x == 500)                       // exactly, not approximately
        #expect(guides == [SnapGuide(isVertical: true, position: 500)])
    }

    @Test("an edge outside the threshold is left exactly where the cursor is")
    func farEdgeDoesNotSnap() {
        let (point, guides) = CanvasSnapping.snapPoint(
            CGPoint(x: 480, y: 0), handle: .right, candidates: neighbour, threshold: threshold)
        #expect(point.x == 480)
        #expect(guides.isEmpty)
    }

    @Test("the NEAREST target wins when two are in range")
    func nearestTargetWins() {
        let crowded = [
            CGRect(x: 500, y: 0, width: 200, height: 10),   // edges at 500 / 700
            CGRect(x: 504, y: 0, width: 200, height: 10),   // edges at 504 / 704
        ]
        let (point, _) = CanvasSnapping.snapPoint(
            CGPoint(x: 503, y: 0), handle: .right, candidates: crowded, threshold: threshold)
        #expect(point.x == 504)
    }

    @Test("a side handle never snaps on the axis it cannot move")
    func sideHandleDoesNotSnapOffAxis() {
        // `.right` moves x only. A y right on a target must be left alone, or the box
        // would drift vertically while the user drags its right edge.
        let (point, guides) = CanvasSnapping.snapPoint(
            CGPoint(x: 0, y: 200), handle: .right, candidates: neighbour, threshold: threshold)
        #expect(point.y == 200)   // unchanged — it was never a candidate
        #expect(guides.allSatisfy { $0.isVertical })

        let (vertical, vGuides) = CanvasSnapping.snapPoint(
            CGPoint(x: 502, y: 0), handle: .bottom, candidates: neighbour, threshold: threshold)
        #expect(vertical.x == 502) // `.bottom` moves y only
        #expect(vGuides.allSatisfy { !$0.isVertical })
    }

    @Test("a corner can snap to a different box on each axis")
    func cornerSnapsIndependentlyPerAxis() {
        let boxes = [
            CGRect(x: 500, y: 900, width: 10, height: 10),  // supplies x = 500
            CGRect(x: 900, y: 300, width: 10, height: 10),  // supplies y = 300
        ]
        let (point, guides) = CanvasSnapping.snapPoint(
            CGPoint(x: 502, y: 298), handle: .bottomRight, candidates: boxes, threshold: threshold)
        #expect(point.x == 500)
        #expect(point.y == 300)
        #expect(guides.count == 2)
    }

    @Test("no candidates means no snapping — the cursor is obeyed exactly")
    func noCandidatesNoSnap() {
        let (point, guides) = CanvasSnapping.snapPoint(
            CGPoint(x: 502, y: 198), handle: .bottomRight, candidates: [], threshold: threshold)
        #expect(point == CGPoint(x: 502, y: 198))
        #expect(guides.isEmpty)
    }

    // MARK: - Aspect-locked snapping

    private let frame = CGRect(x: 100, y: 100, width: 200, height: 100) // ratio 2

    @Test("an aspect-locked snap scales uniformly, preserving the ratio exactly")
    func aspectSnapPreservesRatio() {
        // Right edge at 300; a target at 302 is within reach.
        let target = [CGRect(x: 302, y: 0, width: 10, height: 10)]
        let (snapped, guides) = CanvasSnapping.snapAspectFrame(
            frame, handle: .right, candidates: target, threshold: threshold)
        #expect(abs(snapped.width / snapped.height - 2) < 0.000_1) // ratio held
        #expect(abs(snapped.maxX - 302) < 0.000_1)                 // edge landed on it
        #expect(guides == [SnapGuide(isVertical: true, position: 302)])
    }

    @Test("an aspect-locked snap keeps its anchor edge pinned")
    func aspectSnapKeepsAnchor() {
        let target = [CGRect(x: 302, y: 0, width: 10, height: 10)]
        let (snapped, _) = CanvasSnapping.snapAspectFrame(
            frame, handle: .right, candidates: target, threshold: threshold)
        #expect(abs(snapped.minX - 100) < 0.000_1)  // the left edge never moved
    }

    @Test("an aspect snap that would breach the minimum is refused outright")
    func aspectSnapRefusesToBreachMinimum() {
        // A target just right of the ANCHOR would scale the box to nearly nothing.
        let target = [CGRect(x: 101, y: 0, width: 0, height: 0)]
        let (snapped, guides) = CanvasSnapping.snapAspectFrame(
            frame, handle: .right, candidates: target, threshold: threshold)
        #expect(snapped == frame)   // unchanged — a snap is never a way past the floor
        #expect(guides.isEmpty)
    }

    @Test("only ONE guide survives an aspect snap — there is only one scale to apply")
    func aspectSnapYieldsASingleGuide() {
        let boxes = [
            CGRect(x: 302, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 202, width: 10, height: 10),
        ]
        let (_, guides) = CanvasSnapping.snapAspectFrame(
            frame, handle: .bottomRight, candidates: boxes, threshold: threshold)
        #expect(guides.count <= 1)
    }

    @Test("nothing in range leaves an aspect-locked frame untouched")
    func aspectSnapNoOp() {
        let (snapped, guides) = CanvasSnapping.snapAspectFrame(
            frame, handle: .right,
            candidates: [CGRect(x: 900, y: 900, width: 10, height: 10)], threshold: threshold)
        #expect(snapped == frame)
        #expect(guides.isEmpty)
    }

    @Test("a degenerate frame is returned untouched rather than dividing by zero")
    func aspectSnapDegenerateFrame() {
        let (snapped, guides) = CanvasSnapping.snapAspectFrame(
            .zero, handle: .right, candidates: neighbour, threshold: threshold)
        #expect(snapped == .zero)
        #expect(guides.isEmpty)
    }
}

// MARK: - Move snapping (bounding box, not a single point)

@Suite("Move snapping (062)")
struct MoveSnappingTests {

    /// A neighbour spanning x ∈ [500, 700] (mid 600), y ∈ [100, 300] (mid 200).
    private let neighbour = [CGRect(x: 500, y: 100, width: 200, height: 200)]
    private let threshold: CGFloat = 6

    /// A moving box, 100×50, positioned by its origin.
    private func box(x: CGFloat, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 100, height: 50)
    }

    @Test("a leading edge near a target is nudged exactly onto it")
    func leadingEdgeAligns() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 497, y: 900), candidates: neighbour, threshold: threshold)
        #expect(offset.width == 3)     // 497 → 500
        #expect(offset.height == 0)    // y is nowhere near a target
        #expect(guides == [SnapGuide(isVertical: true, position: 500)])
    }

    @Test("a TRAILING edge aligns too — not just the leading one")
    func trailingEdgeAligns() {
        // maxX = 502 is within 6 of the neighbour's minX (500).
        let (offset, _) = CanvasSnapping.snapOffset(
            movingBox: box(x: 402, y: 900), candidates: neighbour, threshold: threshold)
        #expect(offset.width == -2)
    }

    @Test("centres align, which is what makes 'centre it on that' work")
    func centreAligns() {
        // midX = 597 is within 6 of the neighbour's midX (600); no edge is closer.
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 547, y: 900), candidates: neighbour, threshold: threshold)
        #expect(offset.width == 3)
        #expect(guides == [SnapGuide(isVertical: true, position: 600)])
    }

    @Test("both axes resolve independently")
    func bothAxesSnap() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 497, y: 98), candidates: neighbour, threshold: threshold)
        #expect(offset.width == 3)    // 497 → 500
        #expect(offset.height == 2)   // 98 → 100
        #expect(guides.count == 2)
    }

    @Test("the smallest adjustment wins across every edge/centre pair")
    func smallestAdjustmentWins() {
        // minX = 499 (1 away from 500) and maxX = 599 (1 away from 600) are both in
        // range; the tie is resolved by the first-found minimum, but either way the
        // magnitude must be the smallest available.
        let (offset, _) = CanvasSnapping.snapOffset(
            movingBox: box(x: 499, y: 900), candidates: neighbour, threshold: threshold)
        #expect(abs(offset.width) == 1)
    }

    @Test("a box out of range is not moved at all")
    func outOfRangeDoesNotMove() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 300, y: 900), candidates: neighbour, threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }

    @Test("no candidates means no adjustment")
    func noCandidates() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 497, y: 98), candidates: [], threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }
}
