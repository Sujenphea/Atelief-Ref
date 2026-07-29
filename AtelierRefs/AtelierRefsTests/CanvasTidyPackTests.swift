//
//  CanvasTidyPackTests.swift
//  AtelierRefsTests
//
//  066 — Tidy Up and the exact-gap pack.
//
//  `CanvasArrangeTests` already exercises `tidyUp` through its `allCases` invariants
//  (count + size preserved, idempotent, no-op below the minimum), which is most of what
//  matters. What's here is the geometry those generic assertions cannot see: that a row
//  stays a row, a grid stays a grid, and the gap rule is the one documented.
//

import CoreGraphics
import Testing
@testable import AtelierRefs

@Suite("Tidy Up + exact gap (066)")
struct CanvasTidyPackTests {

    private static let eps: CGFloat = 1e-9
    private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= Self.eps }

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 50, _ h: CGFloat = 40) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Tidy Up

    @Test("a messy row tidies into one row at the smallest gap it already had")
    func rowStaysARow() {
        // Vertically overlapping, so they cluster as ONE row. Gaps 10 and 30 → 10 wins.
        let messy = [rect(0, 0), rect(60, 5), rect(140, 12)]
        let out = CanvasArrange.apply(.tidyUp, to: messy)

        // Anchored on the selection's top-left, which does not move.
        #expect(approx(out[0].minX, 0) && approx(out[0].minY, 0))
        // One row: same y throughout, spaced by the smallest observed gap (10).
        #expect(out.allSatisfy { approx($0.minY, 0) })
        #expect(approx(out[1].minX, 60))
        #expect(approx(out[2].minX, 120))
    }

    @Test("a column stays a column — one item per cluster")
    func columnStaysAColumn() {
        // No vertical overlap → three separate rows, i.e. a column.
        let column = [rect(0, 0), rect(8, 60), rect(3, 140)]
        let out = CanvasArrange.apply(.tidyUp, to: column)

        #expect(out.allSatisfy { approx($0.minX, 0) })  // aligned to the box's left
        #expect(approx(out[0].minY, 0))
        #expect(approx(out[1].minY, 60))                // gap 20 → 40 + 20
        #expect(approx(out[2].minY, 120))
    }

    @Test("a 2×2 grid tidies as a grid, uniform gap both ways")
    func gridStaysAGrid() {
        let grid = [
            rect(0, 0), rect(70, 3),      // top row (vertically overlapping)
            rect(2, 60), rect(74, 62),    // bottom row
        ]
        let out = CanvasArrange.apply(.tidyUp, to: grid)

        // Smallest gap present: horizontal 70−50 = 20 and 74−52 = 22, vertical
        // 60−43 = 17 → 17 wins. Row two sits at rowHeight + gap = 40 + 17.
        #expect(approx(out[0].minX, 0) && approx(out[0].minY, 0))
        #expect(approx(out[1].minX, 67) && approx(out[1].minY, 0))
        #expect(approx(out[2].minX, 0) && approx(out[2].minY, 57))
        #expect(approx(out[3].minX, 67) && approx(out[3].minY, 57))
    }

    @Test("tidying twice changes nothing the second time — the whole point")
    func tidyIsStableUnderItsOwnOutput() {
        // Idempotence is checked over `allCases` for one fixture; these are the shapes
        // most likely to break it — a grid, a column, and touching rects at gap 0.
        let cases: [[CGRect]] = [
            [rect(0, 0), rect(70, 3), rect(2, 60), rect(74, 62)],
            [rect(0, 0), rect(8, 60), rect(3, 140)],
            [rect(0, 0), rect(50, 0), rect(0, 40)],   // flush: derived gap is 0
            [rect(0, 0), rect(5, 5), rect(10, 10)],   // all overlapping → default gap
        ]
        for rects in cases {
            let once = CanvasArrange.apply(.tidyUp, to: rects)
            let twice = CanvasArrange.apply(.tidyUp, to: once)
            for (a, b) in zip(once, twice) {
                #expect(approx(a.minX, b.minX) && approx(a.minY, b.minY))
            }
        }
    }

    @Test("a fully overlapping selection falls back to the default gap, never collapses")
    func overlappingFallsBackToDefault() {
        // Every pair overlaps, so no gap is measurable. Collapsing them all onto one
        // point would be the naive result and is the thing to avoid.
        let stacked = [rect(0, 0), rect(5, 5), rect(10, 10)]
        let out = CanvasArrange.apply(.tidyUp, to: stacked)

        #expect(approx(out[1].minX - out[0].maxX, CanvasArrange.defaultTidyGap))
        #expect(Set(out.map(\.minX)).count > 1)  // genuinely spread out
    }

    @Test("tidy preserves every rect's size and count")
    func tidyPreservesSizes() {
        let mixed = [rect(0, 0, 100, 20), rect(120, 4, 30, 90), rect(0, 200, 55, 55)]
        let out = CanvasArrange.apply(.tidyUp, to: mixed)
        #expect(out.count == mixed.count)
        for (before, after) in zip(mixed, out) {
            #expect(approx(before.width, after.width) && approx(before.height, after.height))
        }
    }

    @Test("a row of differing heights shares a top edge, so it re-clusters as one row")
    func rowAlignsTopEdges() {
        let ragged = [rect(0, 0, 50, 20), rect(60, 30, 50, 80), rect(130, 10, 50, 40)]
        let out = CanvasArrange.apply(.tidyUp, to: ragged)
        // They overlap vertically, so this is one row — and after tidying they share a
        // top edge, which is what keeps a second pass finding the same row.
        #expect(out.allSatisfy { approx($0.minY, out[0].minY) })
    }

    // MARK: - Pack at an exact gap

    @Test("pack spaces adjacent edges by exactly the gap, anchored on the first")
    func packUsesTheGivenGap() {
        let rects = [rect(0, 0, 50, 40), rect(200, 0, 30, 40), rect(400, 0, 70, 40)]
        let out = CanvasArrange.pack(rects, axis: .horizontal, gap: 10)

        #expect(approx(out[0].minX, 0))    // the leading rect does not move
        #expect(approx(out[1].minX, 60))   // 0 + 50 + 10
        #expect(approx(out[2].minX, 100))  // 60 + 30 + 10
    }

    @Test("pack orders by leading edge, not by array order")
    func packSortsByPosition() {
        // Deliberately out of order: a selection arrives as a Set-derived array.
        let rects = [rect(400, 0, 70, 40), rect(0, 0, 50, 40), rect(200, 0, 30, 40)]
        let out = CanvasArrange.pack(rects, axis: .horizontal, gap: 0)

        #expect(approx(out[1].minX, 0))    // the leftmost stays put…
        #expect(approx(out[2].minX, 50))   // …then the middle one
        #expect(approx(out[0].minX, 80))   // …then the one that was first in the array
    }

    @Test("pack runs down the page too, and leaves the cross axis alone")
    func packVertical() {
        let rects = [rect(5, 0, 50, 40), rect(90, 300, 50, 20)]
        let out = CanvasArrange.pack(rects, axis: .vertical, gap: 8)

        #expect(approx(out[0].minY, 0))
        #expect(approx(out[1].minY, 48))
        #expect(approx(out[0].minX, 5) && approx(out[1].minX, 90))  // x untouched
    }

    @Test("a negative gap is clamped — a gap is a space, never an overlap")
    func negativeGapClamps() {
        let rects = [rect(0, 0, 50, 40), rect(100, 0, 50, 40)]
        let out = CanvasArrange.pack(rects, axis: .horizontal, gap: -30)
        #expect(approx(out[1].minX, 50))  // flush, not overlapping
    }

    @Test("gap 0 puts them flush")
    func zeroGapIsFlush() {
        let rects = [rect(0, 0, 50, 40), rect(100, 0, 25, 40), rect(300, 0, 50, 40)]
        let out = CanvasArrange.pack(rects, axis: .horizontal, gap: 0)
        #expect(approx(out[1].minX, 50))
        #expect(approx(out[2].minX, 75))
    }

    @Test("fewer than two rects is a no-op")
    func packBelowTwoIsANoOp() {
        let one = [rect(7, 9)]
        #expect(CanvasArrange.pack(one, axis: .horizontal, gap: 12) == one)
        #expect(CanvasArrange.pack([], axis: .vertical, gap: 12).isEmpty)
    }

    @Test("packing twice at the same gap changes nothing")
    func packIsIdempotent() {
        let rects = [rect(0, 0, 50, 40), rect(200, 0, 30, 40), rect(400, 0, 70, 40)]
        for axis in CanvasArrange.Axis.allCases {
            let once = CanvasArrange.pack(rects, axis: axis, gap: 14)
            let twice = CanvasArrange.pack(once, axis: axis, gap: 14)
            for (a, b) in zip(once, twice) {
                #expect(approx(a.minX, b.minX) && approx(a.minY, b.minY))
            }
        }
    }
}
