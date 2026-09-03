//
//  CanvasArrangeTests.swift
//  AtelierRefsTests
//
//  051 Phase 1 [9A] — the pure `CanvasArrange` kernel, exercised table-driven over
//  `Operation.allCases` plus per-op geometry + invariant assertions. The kernel is
//  identity-agnostic (`[CGRect] → [CGRect]`), so these need no model / DB harness.
//

import CoreGraphics
import Testing
@testable import AtelierRefs

@Suite("CanvasArrange kernel (051 · 9A)")
struct CanvasArrangeTests {

    typealias Op = CanvasArrange.Operation

    /// Floating-point tolerance for coordinate compares (nice inputs stay exact,
    /// but centre/gap divisions can land a hair off).
    private static let eps: CGFloat = 1e-9

    private func approx(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= Self.eps }

    /// A representative spread of overlapping, differently-sized rects at distinct
    /// leading edges — the general case for both aligns and distributes.
    private let spread: [CGRect] = [
        CGRect(x: 0, y: 0, width: 100, height: 40),
        CGRect(x: 30, y: 200, width: 60, height: 120),
        CGRect(x: 250, y: 90, width: 80, height: 80),
        CGRect(x: 500, y: 300, width: 40, height: 200),
    ]

    /// 60 tiles scattered the way a bulk drop leaves a board: overlapping, at slightly
    /// different y, mixed sizes. Four rects is not enough to see a wrap (028) — and it
    /// is not enough to see the creep a wrap can introduce, because a single row
    /// re-clusters into a single row and the idempotence assertion passes trivially.
    /// Coordinates and sizes are whole numbers so every intermediate is exact in binary
    /// floating point: what the assertions below measure is the algorithm, not rounding.
    private static let scatter60: [CGRect] = (0..<60).map { (i: Int) -> CGRect in
        let x: Int = (i * 137) % 900
        let y: Int = (i * 71) % 700
        let w: Int = 100 + (i % 5) * 40
        let h: Int = 80 + (i % 3) * 30
        return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
    }

    /// The fixtures every cross-op invariant runs over: the small general case, and the
    /// many-item case where `tidyUp` wraps (028).
    private var fixtures: [[CGRect]] { [spread, Self.scatter60] }

    // MARK: - Cross-op invariants (over allCases)

    @Test("every op preserves count; all but the two grids preserve each rect's size",
          arguments: Op.allCases)
    func preservesCountAndSize(_ op: Op) {
        for rects in fixtures {
            let out = CanvasArrange.apply(op, to: rects)
            #expect(out.count == rects.count)
            // The two grid ops are the exceptions, by design, and they resize
            // differently: `.reflowGrid` normalises every tile to `gridRowHeight` and
            // lets the width follow the aspect, which is how it justifies a row's
            // bottom edge; `.arrangeGrid` forces one square cell and discards the
            // aspect entirely (099 · P12 / 076 · T3). Excluded here rather than
            // weakening the invariant, because "an op moves an origin and nothing else"
            // is still true of the other nine and is worth holding them to. What each
            // one DOES preserve — count above, reflow's aspect, and arrangeGrid's
            // uniform cell — is asserted in `CanvasTidyPackTests`.
            guard op != .reflowGrid, op != .arrangeGrid else { continue }
            for (before, after) in zip(rects, out) {
                #expect(approx(before.width, after.width))
                #expect(approx(before.height, after.height))
            }
        }
    }

    @Test("every op is idempotent — re-applying changes nothing", arguments: Op.allCases)
    func idempotent(_ op: Op) {
        for rects in fixtures {
            let once = CanvasArrange.apply(op, to: rects)
            let twice = CanvasArrange.apply(op, to: once)
            for (a, b) in zip(once, twice) {
                #expect(approx(a.minX, b.minX))
                #expect(approx(a.minY, b.minY))
            }
        }
    }

    @Test("below the minimum count every op is a no-op", arguments: Op.allCases)
    func belowMinimumIsNoOp(_ op: Op) {
        // One rect is below every op's minimum (align 2 / distribute 3).
        let one = [CGRect(x: 5, y: 7, width: 10, height: 20)]
        #expect(CanvasArrange.apply(op, to: one) == one)
        // Two rects trip only the distributes (minimum 3).
        let two = Array(spread.prefix(2))
        if op.minimumCount > 2 {
            #expect(CanvasArrange.apply(op, to: two) == two)
        }
    }

    @Test("minimumCount matches the align/distribute split", arguments: Op.allCases)
    func minimumCounts(_ op: Op) {
        #expect(op.minimumCount == (op.isDistribute ? 3 : 2))
    }

    // MARK: - Align geometry (each op, 2 + N items, mixed sizes, negative coords)

    /// The bounding box the aligns snap to.
    private func box(_ rects: [CGRect]) -> CGRect {
        CGRect(x: rects.map(\.minX).min()!, y: rects.map(\.minY).min()!,
               width: rects.map(\.maxX).max()! - rects.map(\.minX).min()!,
               height: rects.map(\.maxY).max()! - rects.map(\.minY).min()!)
    }

    /// The horizontal aligns pin one x-edge/centre to the box; y is untouched.
    @Test("align-left pins every minX to the box left edge; y unchanged")
    func alignLeft() {
        for rects in [Array(spread.prefix(2)), spread, negative] {
            let b = box(rects)
            let out = CanvasArrange.apply(.alignLeft, to: rects)
            for (before, after) in zip(rects, out) {
                #expect(approx(after.minX, b.minX))
                #expect(approx(after.minY, before.minY)) // cross axis frozen
            }
        }
    }

    @Test("align-right pins every maxX to the box right edge")
    func alignRight() {
        let b = box(spread)
        let out = CanvasArrange.apply(.alignRight, to: spread)
        for after in out { #expect(approx(after.maxX, b.maxX)) }
    }

    @Test("align horizontal centre pins every midX to the box centre")
    func alignHCenter() {
        let b = box(spread)
        let out = CanvasArrange.apply(.alignHorizontalCenter, to: spread)
        for after in out { #expect(approx(after.midX, b.midX)) }
    }

    @Test("align-top pins every minY to the box top edge; x unchanged")
    func alignTop() {
        let b = box(spread)
        let out = CanvasArrange.apply(.alignTop, to: spread)
        for (before, after) in zip(spread, out) {
            #expect(approx(after.minY, b.minY))
            #expect(approx(after.minX, before.minX))
        }
    }

    @Test("align-bottom pins every maxY to the box bottom edge")
    func alignBottom() {
        let b = box(spread)
        let out = CanvasArrange.apply(.alignBottom, to: spread)
        for after in out { #expect(approx(after.maxY, b.maxY)) }
    }

    @Test("align vertical centre pins every midY to the box centre")
    func alignVCenter() {
        let b = box(spread)
        let out = CanvasArrange.apply(.alignVerticalCenter, to: spread)
        for after in out { #expect(approx(after.midY, b.midY)) }
    }

    @Test("aligning already-aligned rects is a no-op")
    func alignAlreadyAligned() {
        // All share minX == 10 already.
        let rects = [
            CGRect(x: 10, y: 0, width: 50, height: 50),
            CGRect(x: 10, y: 100, width: 80, height: 30),
            CGRect(x: 10, y: 200, width: 20, height: 20),
        ]
        #expect(CanvasArrange.apply(.alignLeft, to: rects) == rects)
    }

    @Test("aligns handle negative world coordinates")
    func alignNegativeCoords() {
        let b = box(negative)
        let out = CanvasArrange.apply(.alignLeft, to: negative)
        for after in out { #expect(approx(after.minX, b.minX)) }
        #expect(b.minX < 0) // sanity: the box really is in negative space
    }

    /// Rects straddling the origin into negative world space, mixed sizes.
    private let negative: [CGRect] = [
        CGRect(x: -300, y: -150, width: 120, height: 60),
        CGRect(x: -50, y: -400, width: 40, height: 90),
        CGRect(x: -200, y: 20, width: 200, height: 30),
    ]

    // MARK: - Distribute geometry + invariants

    /// Gaps between adjacent items (sorted by leading edge) along the given axis.
    private func gaps(_ rects: [CGRect], horizontal: Bool) -> [CGFloat] {
        let sorted = rects.sorted { (horizontal ? $0.minX : $0.minY) < (horizontal ? $1.minX : $1.minY) }
        return zip(sorted, sorted.dropFirst()).map { a, b in
            horizontal ? b.minX - a.maxX : b.minY - a.maxY
        }
    }

    @Test("distribute horizontally equalises the gaps; anchors stay fixed")
    func distributeHorizontalEven() {
        let out = CanvasArrange.apply(.distributeHorizontal, to: spread)
        let g = gaps(out, horizontal: true)
        for gap in g { #expect(approx(gap, g[0])) }               // gaps equal
        #expect(g[0] >= 0)
        // First (min leading) + last (max trailing) anchors unmoved.
        #expect(approx(out.map(\.minX).min()!, spread.map(\.minX).min()!))
        #expect(approx(out.map(\.maxX).max()!, spread.map(\.maxX).max()!))
        // Cross axis (y) untouched, index-aligned (input order preserved).
        for (before, after) in zip(spread, out) { #expect(approx(before.minY, after.minY)) }
    }

    @Test("distribute vertically equalises the gaps; cross axis frozen")
    func distributeVerticalEven() {
        let out = CanvasArrange.apply(.distributeVertical, to: spread)
        let g = gaps(out, horizontal: false)
        for gap in g { #expect(approx(gap, g[0])) }
        #expect(approx(out.map(\.minY).min()!, spread.map(\.minY).min()!))
        #expect(approx(out.map(\.maxY).max()!, spread.map(\.maxY).max()!))
        for (before, after) in zip(spread, out) { #expect(approx(before.minX, after.minX)) }
    }

    @Test("distribute preserves input order (index alignment), not sort order")
    func distributePreservesInputOrder() {
        // Deliberately out of leading-edge order in the array.
        let rects = [
            CGRect(x: 400, y: 0, width: 50, height: 50), // last by leading edge
            CGRect(x: 0, y: 0, width: 50, height: 50),   // first
            CGRect(x: 180, y: 0, width: 50, height: 50), // middle
        ]
        let out = CanvasArrange.apply(.distributeHorizontal, to: rects)
        // Index 0 is the rightmost anchor → keeps its maxX; index 1 the left anchor.
        #expect(approx(out[1].minX, 0))     // left anchor fixed at its slot
        #expect(approx(out[0].maxX, 450))   // right anchor fixed
        // Same widths in the same index slots (no reordering of the array).
        for (before, after) in zip(rects, out) { #expect(approx(before.width, after.width)) }
        #expect(approx(gaps(out, horizontal: true)[0], gaps(out, horizontal: true)[1]))
    }

    @Test("distribute with mixed widths still yields equal gaps")
    func distributeMixedWidths() {
        let rects = [
            CGRect(x: 0, y: 0, width: 30, height: 10),
            CGRect(x: 100, y: 0, width: 120, height: 10),
            CGRect(x: 300, y: 0, width: 10, height: 10),
            CGRect(x: 500, y: 0, width: 60, height: 10),
        ]
        let out = CanvasArrange.apply(.distributeHorizontal, to: rects)
        let g = gaps(out, horizontal: true)
        for gap in g { #expect(approx(gap, g[0])) }
        #expect(g[0] >= 0)
    }

    @Test("already-even distribution is a no-op")
    func distributeAlreadyEven() {
        // Widths 20, gaps of 30 between each → already evenly distributed.
        let rects = [
            CGRect(x: 0, y: 0, width: 20, height: 10),
            CGRect(x: 50, y: 0, width: 20, height: 10),
            CGRect(x: 100, y: 0, width: 20, height: 10),
        ]
        let out = CanvasArrange.apply(.distributeHorizontal, to: rects)
        for (before, after) in zip(rects, out) { #expect(approx(before.minX, after.minX)) }
    }

    @Test("overlapping items distribute to clamped, non-negative gaps")
    func distributeOverlapClamp() {
        // Wide items packed into a narrow span → free space is negative.
        let rects = [
            CGRect(x: 0, y: 0, width: 200, height: 10),
            CGRect(x: 20, y: 0, width: 200, height: 10),
            CGRect(x: 40, y: 0, width: 200, height: 10),
        ]
        let out = CanvasArrange.apply(.distributeHorizontal, to: rects)
        for gap in gaps(out, horizontal: true) { #expect(gap >= -Self.eps) } // never negative
        // Clamp packs from the left anchor with zero gaps.
        #expect(approx(out.sorted { $0.minX < $1.minX }[0].minX, 0))
    }

    @Test("identical positions distribute without crashing, non-negative gaps")
    func distributeIdenticalPositions() {
        let rects = Array(repeating: CGRect(x: 100, y: 100, width: 50, height: 50), count: 4)
        let out = CanvasArrange.apply(.distributeHorizontal, to: rects)
        #expect(out.count == 4)
        for gap in gaps(out, horizontal: true) { #expect(gap >= -Self.eps) }
    }

    @Test("distribute of fewer than three items is a no-op")
    func distributeUnderThree() {
        let two = Array(spread.prefix(2))
        #expect(CanvasArrange.apply(.distributeHorizontal, to: two) == two)
        #expect(CanvasArrange.apply(.distributeVertical, to: two) == two)
    }
}
