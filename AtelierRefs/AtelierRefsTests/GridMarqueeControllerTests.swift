//
//  GridMarqueeControllerTests.swift
//  AtelierRefsTests
//
//  036 §4 A3 — the AppKit marquee's PURE hit mapping (`marqueeHitIDs`) over REAL
//  masonry frames, in the flipped content space `NSCollectionView` uses. The
//  controller's events / `CALayer` / auto-scroll can't run headlessly (named in
//  the change-log, owed to the A4 soak); what IS testable — and where a flipped-
//  coordinate bug would hide — is that the rect→ids math rides the analytic frames
//  correctly through the `topInset` and past-content-bottom cases the §A-risks
//  checklist calls out. The band-narrowed geometry itself is proven equivalent to
//  the core in `MasonryLayoutTests`; here we pin the id mapping + the two edge
//  regions the coordinate helper must handle.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Grid marquee (AppKit) hit mapping")
struct GridMarqueeControllerTests {

    /// A real masonry layout with a non-zero top inset — the exact frame source the
    /// AppKit coordinator vends to the controller (`layout.solvedFrames`).
    private func fixture(
        count: Int = 8, columns: Int = 3, width: CGFloat = 300,
        spacing: CGFloat = 8, topInset: CGFloat = 40
    ) -> (ids: [UUID], frames: [CGRect], columns: Int, contentHeight: CGFloat) {
        // Deterministic aspects (the same round-robin the grid uses).
        let ratios: [Double] = [1.0, 0.72, 1.3, 0.88, 1.15, 0.8, 1.25, 0.95]
        let aspects = (0..<count).map { ratios[$0 % ratios.count] }
        let layout = MasonryLayout.layout(
            aspects: aspects, availableWidth: width, columns: columns,
            spacing: spacing, topInset: topInset)
        let ids = (0..<count).map { _ in UUID() }
        return (ids, layout.frames, layout.columns, layout.contentHeight)
    }

    @Test("a marquee covering everything selects every id, in no missing/extra set")
    func selectsAll() {
        let f = fixture()
        let rect = CGRect(x: 0, y: 0, width: 400, height: f.contentHeight + 100)
        let hits = marqueeHitIDs(
            rect: rect, frames: f.frames, columns: f.columns, itemIDs: f.ids)
        #expect(hits == Set(f.ids))
    }

    @Test("a marquee starting IN the top inset still selects the cells below it")
    func acrossTopInset() {
        let f = fixture(topInset: 40)
        // A box from y=0 (inside the 40pt inset) down through the first row of cells.
        // The first row is indices 0,1,2 (top of each column sits at y=40).
        let firstRowBottom = (0..<f.columns).map { f.frames[$0].maxY }.min() ?? 0
        let rect = CGRect(x: 0, y: 0, width: 400, height: firstRowBottom)
        let hits = marqueeHitIDs(
            rect: rect, frames: f.frames, columns: f.columns, itemIDs: f.ids)
        // Every column's first cell is touched; none of the second-row cells are
        // fully required, but at minimum the three first-row ids must be present.
        #expect(hits.isSuperset(of: Set(f.ids[0..<f.columns])))
    }

    @Test("a click INSIDE the top inset (above every cell) selects nothing")
    func clickInTopInset() {
        let f = fixture(topInset: 40)
        // A zero-size click at y=20 — inside the inset, above the first cell top (40).
        let click = CGRect(x: 30, y: 20, width: 0, height: 0)
        let hits = marqueeHitIDs(
            rect: click, frames: f.frames, columns: f.columns, itemIDs: f.ids)
        #expect(hits.isEmpty)   // empty space → the controller would clear, not select
    }

    @Test("a click PAST the content bottom selects nothing")
    func clickPastContentBottom() {
        let f = fixture()
        let click = CGRect(x: 30, y: f.contentHeight + 50, width: 0, height: 0)
        let hits = marqueeHitIDs(
            rect: click, frames: f.frames, columns: f.columns, itemIDs: f.ids)
        #expect(hits.isEmpty)
    }

    @Test("a precise click on a cell selects exactly that one id")
    func clickOnCell() {
        let f = fixture()
        // Click the centre of index 4's frame.
        let frame = f.frames[4]
        let click = CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0)
        let hits = marqueeHitIDs(
            rect: click, frames: f.frames, columns: f.columns, itemIDs: f.ids)
        #expect(hits == [f.ids[4]])
    }

    @Test("a frames/ids length skew (mid-resize) never indexes past the shorter array")
    func lengthSkewGuard() {
        let f = fixture(count: 8)
        // Simulate the one-render lag: more frames than ids momentarily.
        let fewerIDs = Array(f.ids.prefix(5))
        let rect = CGRect(x: 0, y: 0, width: 400, height: 10_000)
        let hits = marqueeHitIDs(
            rect: rect, frames: f.frames, columns: f.columns, itemIDs: fewerIDs)
        // Only ids that actually exist come back — no crash, no phantom.
        #expect(hits.isSubset(of: Set(fewerIDs)))
        #expect(hits.count <= fewerIDs.count)
    }
}

/// The controller's click-to-clear state machine — the one part of the event side
/// that IS headless (no `CALayer`, no auto-scroll until a real drag). What these
/// pin: a `mouseUp` with no matching `mouseDown` must be INERT. Cells consume
/// their own downs but their ups still bubble to the collection view's background
/// handler (a cell view doesn't override `mouseUp`), so an orphan up used to read
/// as a background click and clear a selection the gesture's owner promised to
/// leave alone — the carousel chip's contract.
@MainActor
@Suite("Grid marquee (AppKit) click-to-clear guards")
struct GridMarqueeClearGuardTests {

    private func makeController(onClear: @escaping () -> Void) -> GridMarqueeController {
        let controller = GridMarqueeController(
            collectionView: MasonryNSCollectionView(frame: .zero))
        controller.onClear = onClear
        return controller
    }

    @Test("an orphan mouse-up (no matching down) never clears")
    func orphanUpIsInert() {
        var cleared = false
        let controller = makeController { cleared = true }
        controller.mouseUp()
        #expect(!cleared)
    }

    @Test("a bare background click (down then up, no drag) still clears")
    func bareClickClears() {
        var cleared = false
        let controller = makeController { cleared = true }
        controller.mouseDown(at: CGPoint(x: 10, y: 10), shiftKey: false)
        controller.mouseUp()
        #expect(cleared)
    }

    @Test("a ⇧-click's modifier does not leak into the NEXT gesture")
    func shiftDoesNotLeak() {
        var clears = 0
        let controller = makeController { clears += 1 }
        // ⇧-click: never clears…
        controller.mouseDown(at: CGPoint(x: 10, y: 10), shiftKey: true)
        controller.mouseUp()
        #expect(clears == 0)
        // …and the next BARE click must clear — a stale `shiftAtStart` would
        // swallow it.
        controller.mouseDown(at: CGPoint(x: 10, y: 10), shiftKey: false)
        controller.mouseUp()
        #expect(clears == 1)
        // The orphan case stays inert even after real gestures ran.
        controller.mouseUp()
        #expect(clears == 1)
    }
}
