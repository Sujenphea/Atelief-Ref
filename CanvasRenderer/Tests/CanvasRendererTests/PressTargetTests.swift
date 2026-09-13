//
//  PressTargetTests.swift
//  CanvasRendererTests
//
//  The precedence a mouse-DOWN resolves through (049 · D8 · 062). Pulled out of
//  `CanvasHostView.mouseDown` into `canvasPressTarget` precisely so this order is
//  pinned here rather than implied by a nested `if` chain in an `NSView` that no
//  headless test can reach.
//
//  The case that matters is `doubleClickBeatsALiveHandle`. It is a regression test:
//  the handle test used to come first, and because the handles belong to the SELECTED
//  tile — which the first click of a double-click selects — the second click of every
//  double-click on a short box landed in a grab zone and was swallowed. A 16pt text
//  box is ~28 screen points tall while each zone reaches `handleHitSize / 2` = 11pt
//  inward from every edge, so almost nothing of it was double-clickable, and
//  double-click-to-edit simply never fired.
//

import CoreGraphics
import Testing
@testable import CanvasRenderer

@Suite("Press target precedence")
struct PressTargetTests {

    /// A press that hits BOTH tile 7 and one of its handles — the ambiguous case the
    /// whole function exists to resolve.
    private func target(tool: CanvasTool = .select,
                        clickCount: Int,
                        tileID: Int? = 7,
                        handle: (tileID: Int, handle: ResizeHandle)? = (tileID: 7, handle: .top),
                        resizeEnabled: Bool = true) -> CanvasPressTarget {
        canvasPressTarget(
            tool: tool, clickCount: clickCount, tileID: tileID,
            handle: handle, resizeEnabled: resizeEnabled)
    }

    // MARK: - The regression

    @Test("a double-click on a tile beats a live resize handle over the same point")
    func doubleClickBeatsALiveHandle() {
        #expect(target(clickCount: 2) == .activate(tileID: 7))
    }

    @Test("the same point at one click is still a resize candidate")
    func singleClickStillResizes() {
        #expect(target(clickCount: 1) == .resize(tileID: 7, handle: .top))
    }

    @Test("above two clicks the handle keeps precedence, exactly as before")
    func tripleClickIsNotAnActivation() {
        #expect(target(clickCount: 3) == .resize(tileID: 7, handle: .top))
    }

    // MARK: - The rest of the order

    @Test("a create tool takes the press at any click count")
    func createToolWinsOutright() {
        for tool in [CanvasTool.frame, .text] {
            for clicks in 1...3 {
                #expect(target(tool: tool, clickCount: clicks) == .create)
            }
        }
    }

    @Test("a handle beats the tile BODY beneath it")
    func handleBeatsTheBody() {
        #expect(target(clickCount: 1) == .resize(tileID: 7, handle: .top))
    }

    @Test("with resizing disabled a handle hit falls through to the body")
    func handleIsInertWhenResizingIsOff() {
        #expect(target(clickCount: 1, resizeEnabled: false) == .tile(tileID: 7))
    }

    @Test("a press on a tile with no handle under it is the body")
    func bodyWithoutAHandle() {
        #expect(target(clickCount: 1, handle: nil) == .tile(tileID: 7))
    }

    @Test("a press on empty space is empty, at one click and at two")
    func emptySpaceIsNeverAnActivation() {
        #expect(target(clickCount: 1, tileID: nil, handle: nil) == .empty)
        #expect(target(clickCount: 2, tileID: nil, handle: nil) == .empty)
    }

    @Test("a handle whose tile is not the one under the cursor still routes by handle")
    func handleCarriesItsOwnTileID() {
        // The handle ring extends OUTSIDE the box, so a press can land on tile 7's
        // handle while the body hit-test finds the tile behind it (or nothing).
        #expect(target(clickCount: 1, tileID: 3) == .resize(tileID: 7, handle: .top))
        #expect(target(clickCount: 1, tileID: nil) == .resize(tileID: 7, handle: .top))
    }

    // MARK: - The geometry that made the bug bite

    @Test("a 16pt text box leaves almost no body once its handles are live")
    func shortBoxIsAlmostEntirelyHandle() {
        // A default text box at 1× zoom: 260 × 28 screen points (16pt text + 2 × 4pt
        // world padding, rounded). Every point of its vertical extent except a thin
        // middle strip resolves to a handle.
        let short = CGRect(x: 0, y: 0, width: 260, height: 28)
        let interior = (Int(short.minY)...Int(short.maxY)).filter { y in
            ResizeGeometry.handle(
                atScreenPoint: CGPoint(x: short.midX, y: CGFloat(y)), in: short) == nil
        }
        // Fewer than a quarter of the box's rows were double-clickable, which is why
        // the old order made double-click-to-edit feel broken rather than merely fiddly.
        #expect(interior.count < Int(short.height) / 4)
        // …and `canvasPressTarget` no longer cares: a double-click anywhere on the box
        // activates, including dead-centre on the top edge.
        #expect(target(clickCount: 2, handle: (tileID: 7, handle: .top)) == .activate(tileID: 7))
    }
}

// MARK: - What a text rubber-band chose

/// The width-only rule in `CanvasHostView.finishCreate`.
///
/// A regression suite. The gate used to demand BOTH a minimum width and a minimum
/// height, which is a sensible test for a frame and a wrong one for text: a text box's
/// height follows its wrapped glyphs, so the natural gesture — sweep out the column
/// width you want, barely moving vertically — failed it. The drag was then reported as
/// a click and the width the user had just drawn was thrown away.
///
/// `@MainActor` because ``CanvasHostView`` is — the rule is pure arithmetic, but it
/// lives on the view whose gesture it belongs to.
@MainActor
@Suite("Text create — the drag's WIDTH is the only thing it chose")
struct TextCreateGateTests {
    private var edge: CGFloat { CanvasHostView.minCreateWorldEdge }

    @Test("a wide, shallow band is a deliberate drag — the height is not a choice")
    func shallowDragKeepsItsWidth() {
        let band = CGRect(x: 0, y: 0, width: 400, height: 1)
        #expect(CanvasHostView.textDragChoseWidth(worldRect: band))
        // Zero height too: a perfectly horizontal sweep still states a width.
        #expect(CanvasHostView.textDragChoseWidth(
            worldRect: CGRect(x: 0, y: 0, width: 400, height: 0)))
    }

    @Test("a narrow drag is a click, however tall it is")
    func narrowDragIsAClick() {
        #expect(!CanvasHostView.textDragChoseWidth(
            worldRect: CGRect(x: 0, y: 0, width: edge - 1, height: 500)))
        #expect(!CanvasHostView.textDragChoseWidth(worldRect: .zero))
    }

    @Test("the minimum is inclusive, and it is the same edge a frame is held to")
    func theThreshold() {
        #expect(CanvasHostView.textDragChoseWidth(
            worldRect: CGRect(x: 0, y: 0, width: edge, height: 0)))
        #expect(!CanvasHostView.textDragChoseWidth(
            worldRect: CGRect(x: 0, y: 0, width: edge.nextDown, height: 0)))
    }
}
