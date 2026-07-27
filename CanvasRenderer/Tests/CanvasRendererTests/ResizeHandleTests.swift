//
//  ResizeHandleTests.swift
//  CanvasRendererTests
//
//  062 — the pure half of resizing: where the eight handles sit, which one a press
//  lands on, and the frame a drag produces. All headless; the gesture wiring in
//  `CanvasHostView` is live-only, but every decision it makes is one of these.
//
//  Two things are worth stating because they are easy to get backwards:
//  hit-testing is in SCREEN space (a grab zone must be the same physical size at
//  every zoom, so it cannot be expressed in world units), while the resulting frame
//  is in WORLD space (that is what gets persisted). The tests below pin both.
//

import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("Resize handles (062)")
struct ResizeHandleTests {

    private let box = CGRect(x: 100, y: 50, width: 300, height: 200)

    // MARK: - Placement

    @Test("all eight handles sit on the box's corners and edge midpoints")
    func handlesSitOnTheBox() {
        let centres = Dictionary(
            uniqueKeysWithValues: ResizeGeometry.handleCentres(in: box).map { ($0.handle, $0.centre) })
        #expect(centres.count == 8)
        #expect(centres[.topLeft] == CGPoint(x: 100, y: 50))
        #expect(centres[.top] == CGPoint(x: 250, y: 50))
        #expect(centres[.topRight] == CGPoint(x: 400, y: 50))
        #expect(centres[.right] == CGPoint(x: 400, y: 150))
        #expect(centres[.bottomRight] == CGPoint(x: 400, y: 250))
        #expect(centres[.bottom] == CGPoint(x: 250, y: 250))
        #expect(centres[.bottomLeft] == CGPoint(x: 100, y: 250))
        #expect(centres[.left] == CGPoint(x: 100, y: 150))
    }

    @Test("exactly four handles are corners")
    func fourCorners() {
        #expect(ResizeHandle.allCases.filter(\.isCorner).count == 4)
        #expect(ResizeHandle.allCases.count == 8)
    }

    // MARK: - Hit-testing

    @Test("a press on each handle's centre finds that handle")
    func centreHitsItsOwnHandle() {
        for (handle, centre) in ResizeGeometry.handleCentres(in: box) {
            #expect(ResizeGeometry.handle(atScreenPoint: centre, in: box) == handle)
        }
    }

    @Test("a press in the box's interior finds no handle")
    func interiorMissesEveryHandle() {
        #expect(ResizeGeometry.handle(atScreenPoint: CGPoint(x: 250, y: 150), in: box) == nil)
    }

    @Test("a press well outside the box finds no handle")
    func farOutsideMissesEveryHandle() {
        for point in [CGPoint(x: -500, y: -500), CGPoint(x: 900, y: 150), CGPoint(x: 250, y: 800)] {
            #expect(ResizeGeometry.handle(atScreenPoint: point, in: box) == nil)
        }
    }

    @Test("the grab zone is forgiving — a near miss still catches the handle")
    func nearMissStillHits() {
        // Slightly OUTSIDE the corner, and slightly inside: both must catch it, or the
        // handle is a pixel-hunt.
        let slop = ResizeGeometry.handleHitSize / 2 - 1
        #expect(ResizeGeometry.handle(
            atScreenPoint: CGPoint(x: 100 - slop, y: 50 - slop), in: box) == .topLeft)
        #expect(ResizeGeometry.handle(
            atScreenPoint: CGPoint(x: 100 + slop, y: 50 + slop), in: box) == .topLeft)
    }

    @Test("corners win where a corner zone overlaps an edge band")
    func cornersBeatEdges() {
        // A point on the left EDGE line but within the top-left corner's zone must
        // resolve to the corner — the handle that does strictly more.
        let justBelowTopLeft = CGPoint(x: 100, y: 50 + ResizeGeometry.handleHitSize / 2 - 1)
        #expect(ResizeGeometry.handle(atScreenPoint: justBelowTopLeft, in: box) == .topLeft)
    }

    @Test("a box smaller than its own grab zones still hit-tests to corners only")
    func tinyBoxResolvesToCorners() {
        let tiny = CGRect(x: 0, y: 0, width: 4, height: 4)
        let hit = ResizeGeometry.handle(atScreenPoint: CGPoint(x: 0, y: 0), in: tiny)
        #expect(hit?.isCorner == true)
    }

    // MARK: - Resize arithmetic

    @Test("dragging the right edge moves only that edge")
    func rightEdgeMovesAlone() {
        let out = ResizeGeometry.resizedFrame(
            box, handle: .right, toWorldPoint: CGPoint(x: 500, y: 999))
        #expect(out.minX == 100)      // anchored
        #expect(out.maxX == 500)      // followed the cursor
        #expect(out.minY == 50)       // the cursor's y is irrelevant to a side handle
        #expect(out.maxY == 250)
    }

    @Test("dragging the left edge moves the origin and pins the far edge")
    func leftEdgePinsFarEdge() {
        let out = ResizeGeometry.resizedFrame(
            box, handle: .left, toWorldPoint: CGPoint(x: 160, y: 0))
        #expect(out.minX == 160)
        #expect(out.maxX == 400)      // pinned — this is what makes a resize feel anchored
        #expect(out.width == 240)
    }

    @Test("a corner moves two edges at once, anchored at the opposite corner")
    func cornerMovesTwoEdges() {
        let out = ResizeGeometry.resizedFrame(
            box, handle: .bottomRight, toWorldPoint: CGPoint(x: 500, y: 400))
        #expect(out.origin == CGPoint(x: 100, y: 50))   // opposite corner anchored
        #expect(out.maxX == 500)
        #expect(out.maxY == 400)
    }

    @Test("every handle moves exactly the edges it owns and no others")
    func handlesMoveOnlyTheirOwnEdges() {
        let target = CGPoint(x: 260, y: 160) // inside the box, so every edge could move
        for handle in ResizeHandle.allCases {
            let out = ResizeGeometry.resizedFrame(box, handle: handle, toWorldPoint: target)
            #expect((out.minX != box.minX) == handle.movesLeft, "minX for \(handle)")
            #expect((out.maxX != box.maxX) == handle.movesRight, "maxX for \(handle)")
            #expect((out.minY != box.minY) == handle.movesTop, "minY for \(handle)")
            #expect((out.maxY != box.maxY) == handle.movesBottom, "maxY for \(handle)")
        }
    }

    // MARK: - Degenerate drags

    @Test("dragging an edge past its anchor clamps to the minimum, never inverts")
    func draggingPastTheAnchorClamps() {
        let minSize = ResizeGeometry.minWorldSize
        // Yank the right edge far to the LEFT of the left edge.
        let out = ResizeGeometry.resizedFrame(
            box, handle: .right, toWorldPoint: CGPoint(x: -9_999, y: 0))
        #expect(out.width == minSize)
        #expect(out.width > 0)        // never negative — a negative box is not drawable
        #expect(out.minX == 100)      // the anchor did not move

        // And the same from the other side, where the ORIGIN is what gets clamped.
        let flipped = ResizeGeometry.resizedFrame(
            box, handle: .left, toWorldPoint: CGPoint(x: 9_999, y: 0))
        #expect(flipped.width == minSize)
        #expect(flipped.maxX == 400)
    }

    @Test("a corner dragged past both anchors clamps on both axes")
    func cornerClampsBothAxes() {
        let minSize = ResizeGeometry.minWorldSize
        let out = ResizeGeometry.resizedFrame(
            box, handle: .bottomRight, toWorldPoint: CGPoint(x: -9_999, y: -9_999))
        #expect(out.width == minSize)
        #expect(out.height == minSize)
    }

    @Test("a zero-size box is resized without producing NaN or a negative edge")
    func degenerateBoxIsSafe() {
        let empty = CGRect.zero
        for handle in ResizeHandle.allCases {
            let out = ResizeGeometry.resizedFrame(
                empty, handle: handle, toWorldPoint: CGPoint(x: 40, y: 40))
            #expect(out.width.isFinite && out.height.isFinite)
            #expect(out.width >= 0 && out.height >= 0)
        }
    }
}
