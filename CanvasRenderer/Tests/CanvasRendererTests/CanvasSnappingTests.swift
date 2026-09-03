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

// MARK: - Equal spacing (099 · P12)

/// A guide when the moved tile's gap to a neighbour equals that neighbour's gap to
/// the next one along — the rhythm a board acquires once a few tiles are placed, and
/// the thing alignment alone cannot express.
///
/// Every fixture here uses at least TWO static boxes, which is also why none of the
/// 062 suites above changed: a rhythm needs a pair, and each of those tests offers a
/// single neighbour.
@Suite("Equal-spacing snapping (099 · P12)")
struct EqualSpacingSnappingTests {

    /// Two boxes in one band, 40 apart: x ∈ [0,100] and x ∈ [140,240], y ∈ [0,100].
    /// The rhythm continues at 240 + 40 = 280 to the right, and at 0 − 40 = −40 (a
    /// trailing edge) to the left.
    private let run = [
        CGRect(x: 0, y: 0, width: 100, height: 100),
        CGRect(x: 140, y: 0, width: 100, height: 100),
    ]
    private let threshold: CGFloat = 6

    /// A moving box, 100×100, sharing the run's band but level with none of its edges.
    private func box(x: CGFloat, y: CGFloat = 20) -> CGRect {
        CGRect(x: x, y: y, width: 100, height: 100)
    }

    @Test("a tile dropped where the rhythm continues snaps onto it")
    func rhythmContinuesToTheRight() {
        // 283 is 3 short of 280 + nothing; no edge or centre is within 6, so alignment
        // has nothing to say and the rhythm is the only candidate.
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 283), candidates: run, threshold: threshold)
        #expect(offset.width == -3)
        #expect(offset.height == 0)
        #expect(guides == [SnapGuide(isVertical: true, position: 280, kind: .equalSpacing)])
    }

    @Test("the rhythm runs backwards too — a tile placed BEFORE the run")
    func rhythmContinuesToTheLeft() {
        // The trailing edge takes the gap: maxX → 0 − 40 = −40, so minX → −140.
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: -137), candidates: run, threshold: threshold)
        #expect(offset.width == -3)
        #expect(guides == [SnapGuide(isVertical: true, position: -40, kind: .equalSpacing)])
    }

    @Test("a column has a rhythm as well as a row")
    func rhythmWorksVertically() {
        let column = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 140, width: 100, height: 100),
        ]
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: CGRect(x: 20, y: 283, width: 100, height: 50),
            candidates: column, threshold: threshold)
        #expect(offset.height == -3)
        #expect(offset.width == 0)
        #expect(guides == [SnapGuide(isVertical: false, position: 280, kind: .equalSpacing)])
    }

    /// The test that fails if equal spacing is ever promoted from a fallback to a
    /// competitor. `C` is out of the run's band, so it offers an ALIGNMENT target at
    /// 282 but no rhythm; the rhythm's own target is 280. Both are in range from 283,
    /// and the alignment — 1 away rather than 3, and sitting on an edge that really
    /// exists — has to win.
    @Test("an alignment in range beats a rhythm in range, even a nearer one")
    func alignmentOutranksEqualSpacing() {
        let candidates = run + [CGRect(x: 282, y: 500, width: 100, height: 100)]
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 283), candidates: candidates, threshold: threshold)
        #expect(offset.width == -1)
        #expect(guides == [SnapGuide(isVertical: true, position: 282)])
        #expect(guides.allSatisfy { $0.kind == .alignment })
    }

    /// The test that fails without the shared-band filter. The same two boxes are
    /// still 40 apart, but the moving tile is nowhere near them vertically — so the
    /// gap is arithmetic, not something anyone is looking at.
    @Test("a rhythm needs a shared band, not just an arithmetic gap")
    func rhythmNeedsASharedBand() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 283, y: 500), candidates: run, threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }

    /// The test that fails if every pair is considered instead of adjacent ones. With
    /// a third box at [300,400] the run's gaps are 40 and 60; the distance from A's
    /// trailing edge to C's leading edge is 200, which is not a gap the user can see
    /// because B is sitting in it.
    @Test("only ADJACENT pairs make a rhythm — a gap with a box in it is not one")
    func onlyAdjacentPairsCount() {
        let three = run + [CGRect(x: 300, y: 0, width: 100, height: 100)]

        // 400 + 200 = 600 is the phantom an all-pairs rule would offer.
        let (phantom, phantomGuides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 603), candidates: three, threshold: threshold)
        #expect(phantom == .zero)
        #expect(phantomGuides.isEmpty)

        // 400 + 60 is the real one, from the adjacent B→C pair.
        let (real, realGuides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 463), candidates: three, threshold: threshold)
        #expect(real.width == -3)
        #expect(realGuides == [SnapGuide(isVertical: true, position: 460, kind: .equalSpacing)])
    }

    @Test("two overlapping boxes have no gap to repeat")
    func overlapIsNotARhythm() {
        let overlapping = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 60, y: 0, width: 100, height: 100),   // gap is −40
        ]
        // An all-gaps rule would offer 160 + (−40) = 120; a real one offers nothing.
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 123), candidates: overlapping, threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }

    @Test("one neighbour cannot make a rhythm — which is why 062's suites are untouched")
    func oneNeighbourIsNotARun() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 283), candidates: [run[1]], threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }

    @Test("a rhythm out of range is left alone, like every other snap")
    func outOfRangeRhythmIsIgnored() {
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 300), candidates: run, threshold: threshold)
        #expect(offset == .zero)
        #expect(guides.isEmpty)
    }

    @Test("the nearest of two available rhythms wins")
    func nearestRhythmWins() {
        // Gaps of 40 (A→B) and 10 (B→C) both continue past C: at 350 + 10 = 360 and,
        // from the A→B pair, nothing nearby. Dropping at 358 must take 360, not drift.
        let uneven = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 140, y: 0, width: 100, height: 100),
            CGRect(x: 250, y: 0, width: 100, height: 100),
        ]
        let (offset, guides) = CanvasSnapping.snapOffset(
            movingBox: box(x: 358), candidates: uneven, threshold: threshold)
        #expect(offset.width == 2)
        #expect(guides == [SnapGuide(isVertical: true, position: 360, kind: .equalSpacing)])
    }

    @Test("a guide defaults to alignment, so every 062 call site still means what it did")
    func kindDefaultsToAlignment() {
        #expect(SnapGuide(isVertical: true, position: 10).kind == .alignment)
        #expect(SnapGuide(isVertical: true, position: 10)
                == SnapGuide(isVertical: true, position: 10, kind: .alignment))
        #expect(SnapGuide(isVertical: true, position: 10)
                != SnapGuide(isVertical: true, position: 10, kind: .equalSpacing))
    }
}
