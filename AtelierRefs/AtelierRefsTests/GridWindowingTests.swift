//
//  GridWindowingTests.swift
//  AtelierRefsTests
//
//  012 — the pure windowing math, exhaustively (the windowed render itself is
//  only manually verifiable):
//
//   • `gridWindow` quantization: STABILITY (a sub-boundary scroll keeps the same
//     band → no re-render), one-band advance on crossing, top/bottom clamp, and
//     the empty / short-content degenerate cases.
//   • `masonryVisibleIndices`: it returns EXACTLY what the layout-agnostic
//     `marqueeIndices` oracle returns over the same overscan-outset rect
//     (intersection-iff); the union over a full scroll COVERS every cell (no cell
//     is ever permanently skipped — the failure that would hide an item forever);
//     and it is MONOTONIC in overscan (a bigger buffer only ever adds cells).
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("GridWindow: quantization")
struct GridWindowQuantizationTests {

    @Test("a sub-boundary scroll keeps the same band and rect (stability)")
    func stabilityWithinBand() {
        // bandHeight 800; offsets 10 and 790 are both in band 0 → identical window,
        // so the published value never changes and the grid never re-renders.
        let a = gridWindow(
            offsetY: 10, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        let b = gridWindow(
            offsetY: 790, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        #expect(a == b)
        #expect(a.band == 0)
    }

    @Test("crossing a boundary advances exactly one band")
    func oneBandAdvance() {
        let below = gridWindow(
            offsetY: 799, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        let above = gridWindow(
            offsetY: 801, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        #expect(below.band == 0)
        #expect(above.band == 1)
        #expect(below != above)
        // The rect steps down by exactly one band height.
        #expect(above.rect.minY - below.rect.minY == 800)
    }

    @Test("the band rect covers the whole viewport for any offset in the band")
    func rectCoversViewportAcrossBand() {
        // Rect spans [band*bh, band*bh + bh + vh]. For band 1 (top 800) with
        // vh 600 that is [800, 2200] — a superset of the viewport at both the top
        // (offset 800 → [800,1400]) and bottom (offset ~1600 → [1600,2200]).
        let w = gridWindow(
            offsetY: 1000, viewportHeight: 600, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        #expect(w.band == 1)
        #expect(w.rect.minY == 800)
        // CGFloat(...) so the RHS arithmetic isn't captured as an `Int` (which
        // then mismatches the CGFloat height under Testing's typed comparison).
        #expect(w.rect.height == CGFloat(800 + 600))   // bandHeight + viewportHeight
        #expect(w.rect.width == 500)
    }

    @Test("a negative offset (top overscroll) reads as band 0")
    func negativeOffsetClampsToZero() {
        let w = gridWindow(
            offsetY: -250, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 800)
        #expect(w.band == 0)
        #expect(w.rect.minY == 0)
    }

    @Test("an offset past the bottom clamps to the last scrollable band")
    func bottomClamp() {
        // contentHeight 2000, viewport 800 → maxOffset 1200 → band floor(1200/800)=1.
        // A momentum overshoot to 5000 must not invent band 6.
        let overshoot = gridWindow(
            offsetY: 5000, viewportHeight: 800, contentHeight: 2000,
            width: 500, bandHeight: 800)
        let atMax = gridWindow(
            offsetY: 1200, viewportHeight: 800, contentHeight: 2000,
            width: 500, bandHeight: 800)
        #expect(overshoot == atMax)
        #expect(overshoot.band == 1)
    }

    @Test("content shorter than the viewport is a single band 0 covering everything")
    func shortContent() {
        let w = gridWindow(
            offsetY: 0, viewportHeight: 800, contentHeight: 300,
            width: 500, bandHeight: 800)
        #expect(w.band == 0)
        #expect(w.rect.minY == 0)
        #expect(w.rect.maxY >= 300)   // covers all content
    }

    @Test("empty content yields band 0 and a drawable rect")
    func emptyContent() {
        let w = gridWindow(
            offsetY: 0, viewportHeight: 800, contentHeight: 0,
            width: 500, bandHeight: 800)
        #expect(w.band == 0)
        #expect(w.rect.width == 500)
        #expect(w.rect.height > 0)
    }

    @Test("a degenerate bandHeight is clamped so banding never divides by zero")
    func degenerateBandHeight() {
        let w = gridWindow(
            offsetY: 40, viewportHeight: 800, contentHeight: 10_000,
            width: 500, bandHeight: 0)
        // bandHeight clamps to >= 1; the result stays finite and drawable.
        #expect(w.rect.height.isFinite)
        #expect(w.band >= 0)
    }
}

@Suite("masonryVisibleIndices: visibility")
struct MasonryVisibleIndicesTests {

    /// A staggered layout so column bottoms are ragged (the whole point of the
    /// y-monotone core) — the same aspect spread the marquee contract uses.
    private let aspects = [0.4, 1.0, 2.0, 0.5, 1.3, 1.0, 3.0, 0.7, 1.0, 2.5, 0.9, 1.1, 1.0, 0.3]

    private func layout(width: CGFloat, cols: Int, spacing: CGFloat) -> MasonryFrames {
        MasonryLayout.layout(
            aspects: aspects, availableWidth: width, columns: cols,
            spacing: spacing, topInset: 4)
    }

    @Test("visible set equals the marqueeIndices oracle over the overscan-outset rect")
    func matchesOracleAcrossRectsAndOverscans() {
        let rects = [
            CGRect(x: 0, y: 0, width: 400, height: 300),      // a viewport at the top
            CGRect(x: 0, y: 500, width: 400, height: 300),    // a viewport mid-scroll
            CGRect(x: 0, y: 5000, width: 400, height: 300),   // past the content
            CGRect(x: 0, y: 200, width: 400, height: 50),     // a thin band
        ]
        let overscans: [CGFloat] = [0, 40, 300, 1000]
        for (width, cols, spacing) in [(300.0, 3, 8.0), (500.0, 4, 0.0), (200.0, 1, 6.0)] {
            let frames = layout(width: width, cols: cols, spacing: spacing).frames
            for rect in rects {
                for overscan in overscans {
                    let visible = masonryVisibleIndices(
                        in: rect, frames: frames, columns: cols, overscan: overscan)
                    let oracle = marqueeIndices(
                        in: rect.insetBy(dx: -overscan, dy: -overscan), frames: frames)
                    #expect(visible == oracle)
                }
            }
        }
    }

    @Test("a negative overscan is clamped to zero (no inversion)")
    func negativeOverscanClamps() {
        let frames = layout(width: 300, cols: 3, spacing: 8).frames
        let rect = CGRect(x: 0, y: 100, width: 300, height: 200)
        let clamped = masonryVisibleIndices(in: rect, frames: frames, columns: 3, overscan: -50)
        let zero = masonryVisibleIndices(in: rect, frames: frames, columns: 3, overscan: 0)
        #expect(clamped == zero)
    }

    @Test("sweeping the full scroll covers every cell — none is permanently skipped")
    func fullScrollCoversAllCells() {
        // The load-bearing property: as the user scrolls top→bottom, the union of
        // windowed sets must include EVERY index. A gap here means a cell that is
        // never rendered even when it should be on screen.
        for (width, cols, spacing) in [(300.0, 3, 8.0), (500.0, 4, 0.0), (200.0, 1, 6.0)] {
            let masonry = layout(width: width, cols: cols, spacing: spacing)
            let frames = masonry.frames
            let viewportHeight: CGFloat = 400
            let bandHeight = viewportHeight   // band-aligned overscan quantum (Perf 1A)
            var seen = Set<Int>()
            // Step finer than a band so every band is visited (simulates scroll).
            var offset: CGFloat = 0
            let step = bandHeight / 3
            while offset <= masonry.contentHeight + bandHeight {
                let window = gridWindow(
                    offsetY: offset, viewportHeight: viewportHeight,
                    contentHeight: masonry.contentHeight, width: width, bandHeight: bandHeight)
                // overscan 0 is the tightest coverage; if this covers, any buffer does.
                seen.formUnion(masonryVisibleIndices(
                    in: window.rect, frames: frames, columns: cols, overscan: 0))
                offset += step
            }
            #expect(seen == Set(0..<frames.count))
        }
    }

    @Test("visible set is monotonic in overscan (a bigger buffer only adds cells)")
    func overscanMonotonic() {
        let frames = layout(width: 500, cols: 4, spacing: 8).frames
        let rect = CGRect(x: 0, y: 600, width: 500, height: 400)
        let overscans: [CGFloat] = [0, 50, 200, 600, 2000]
        var previous = Set<Int>()
        for overscan in overscans {
            let current = Set(masonryVisibleIndices(
                in: rect, frames: frames, columns: 4, overscan: overscan))
            #expect(previous.isSubset(of: current))
            previous = current
        }
    }

    @Test("empty frames yield no visible indices at any overscan")
    func emptyFrames() {
        let rect = CGRect(x: 0, y: 0, width: 500, height: 400)
        #expect(masonryVisibleIndices(in: rect, frames: [], columns: 4, overscan: 500).isEmpty)
    }
}

@Suite("windowedCells: identity mapping")
struct WindowedCellsTests {

    @Test("each cell binds its index to THAT index's frame — a pure filter, never a re-map")
    func preservesIndexToFrame() {
        // Distinct frames so a mis-map would be caught: frame i is uniquely placed.
        let frames = (0..<10).map { CGRect(x: CGFloat($0), y: CGFloat($0) * 10, width: 50, height: 40) }
        let visible = [0, 3, 7, 9]
        let cells = windowedCells(visible: visible, itemCount: 10, frames: frames)
        #expect(cells.map(\.index) == visible)   // order + membership preserved
        for cell in cells {
            #expect(cell.frame == frames[cell.index])   // the off-by-one guard
            #expect(cell.id == cell.index)
        }
    }

    @Test("indices out of range of items or frames are dropped, never crash")
    func dropsOutOfRange() {
        let frames = (0..<5).map { CGRect(x: 0, y: CGFloat($0), width: 10, height: 10) }
        // itemCount 4 excludes index 4; 5/6 exceed frames; -1 is negative.
        let visible = [-1, 0, 4, 5, 6, 2]
        let cells = windowedCells(visible: visible, itemCount: 4, frames: frames)
        #expect(cells.map(\.index) == [0, 2])
        for cell in cells { #expect(cell.frame == frames[cell.index]) }
    }

    @Test("an empty visible set yields no cells")
    func emptyVisible() {
        let frames = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        #expect(windowedCells(visible: [], itemCount: 1, frames: frames).isEmpty)
    }
}

@Suite("hover reconciliation on window change")
struct HoverReconcileTests {

    @Test("a hovered cell still in the window is kept")
    func keepsVisible() {
        let id = UUID()
        #expect(hoverAfterWindowChange(current: id, visibleIDs: [id, UUID()]) == id)
    }

    @Test("a hovered cell that scrolled out of the window is dropped")
    func dropsInvisible() {
        let id = UUID()
        #expect(hoverAfterWindowChange(current: id, visibleIDs: [UUID(), UUID()]) == nil)
    }

    @Test("no hover stays no hover")
    func nilStaysNil() {
        #expect(hoverAfterWindowChange(current: nil, visibleIDs: [UUID()]) == nil)
    }

    @Test("an empty window drops any hover")
    func emptyWindowDrops() {
        #expect(hoverAfterWindowChange(current: UUID(), visibleIDs: []) == nil)
    }
}

@Suite("GifAnimationCoordinator: single-slot + idempotent release")
@MainActor
struct GifCoordinatorTests {

    @Test("release is idempotent — a double release leaves the slot free, never underflows")
    func idempotentRelease() {
        let coordinator = GifAnimationCoordinator()
        let a = UUID(), b = UUID()
        #expect(coordinator.claim(a) == true)
        coordinator.release(a)
        coordinator.release(a)              // second release — no-op, not a crash
        #expect(coordinator.claim(b) == true)   // slot is genuinely free again
    }

    @Test("a stale release from a non-holder never frees the holder's slot")
    func staleReleaseNoOp() {
        let coordinator = GifAnimationCoordinator()
        let a = UUID(), b = UUID()
        #expect(coordinator.claim(a) == true)
        coordinator.release(b)              // b never held it → no-op
        #expect(coordinator.claim(b) == false)   // a still holds the slot
    }
}
