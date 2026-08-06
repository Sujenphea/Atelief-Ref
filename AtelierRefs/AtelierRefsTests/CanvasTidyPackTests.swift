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
//  028 added the wrap: rows have a width bound now, and clustering no longer chains
//  transitively. Those tests sit at N=60 on purpose — at N=4 a row re-clusters into a
//  row and every assertion here passes whether the bound creeps or not.
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

    // MARK: - Tidy Up wraps (028)

    /// Distinct row tops in a tidied result, ascending — a tidied row shares one top
    /// edge, so this is the row count.
    private func rowTops(_ rects: [CGRect]) -> [CGFloat] {
        Set(rects.map(\.minY)).sorted()
    }

    /// The rects sitting on `top`, left to right.
    private func row(_ rects: [CGRect], at top: CGFloat) -> [CGRect] {
        rects.filter { approx($0.minY, top) }.sorted { $0.minX < $1.minX }
    }

    /// 60 tiles of one size, all vertically overlapping, so clustering alone yields ONE
    /// row — the shape that used to come out ~13,000pt wide. Only the wrap can break it.
    private static let uniform60: [CGRect] = (0..<60).map { (i: Int) -> CGRect in
        CGRect(x: CGFloat(i * 10), y: 0, width: 200, height: 150)
    }

    @Test("60 tiles wrap into rows instead of one enormous row")
    func manyTilesWrap() {
        let rects = Self.uniform60
        let bound = CanvasArrange.tidyMaxRowWidth(rects)
        let out = CanvasArrange.apply(.tidyUp, to: rects)
        let tops = rowTops(out)

        #expect(tops.count > 1)                       // the bug, in one assertion
        #expect(tops.count == 9)                      // 7 per row at the derived bound
        // No row runs past the bound, measured from the anchor the rows start at.
        let left = out.map(\.minX).min()!
        for top in tops {
            #expect(row(out, at: top).map(\.maxX).max()! - left <= bound + Self.eps)
        }
        // Every row starts at the anchor — including the last, which is ragged, not
        // justified: tidy fills left to right and stops.
        for top in tops { #expect(approx(row(out, at: top).first!.minX, left)) }
        #expect(row(out, at: tops.last!).count == 4)  // 8 × 7 + 4 = 60
        #expect(row(out, at: tops.first!).count == 7)
    }

    @Test("wrapped rows are spaced by the derived gap, same as clustered ones")
    func wrappedRowsUseTheDerivedGap() {
        // Fully overlapping horizontally → no measurable gap → the default (20).
        let out = CanvasArrange.apply(.tidyUp, to: Self.uniform60)
        let tops = rowTops(out)
        for (above, below) in zip(tops, tops.dropFirst()) {
            // 150 tall + the derived gap; the wrap does not invent its own spacing.
            #expect(approx(below - above, 150 + CanvasArrange.defaultTidyGap))
        }
    }

    @Test("a staircase does not chain into one row")
    func staircaseDoesNotChain() {
        // Each rect overlaps ONLY its neighbour: extents are [30i, 30i+40), so i and
        // i+2 do not touch. Clustering on the running maximum of member bottoms made
        // this one row of ten; clustering on the row's band makes it five rows of two.
        let staircase: [CGRect] = (0..<10).map { (i: Int) -> CGRect in
            CGRect(x: CGFloat(i * 30), y: CGFloat(i * 30), width: 50, height: 40)
        }
        let out = CanvasArrange.apply(.tidyUp, to: staircase)
        #expect(rowTops(out).count > 1)
        #expect(rowTops(out).count == 5)
        // Well inside the wrap bound, so this is the clustering doing the work, not
        // the width bound.
        #expect(out.map(\.maxX).max()! < CanvasArrange.tidyMaxRowWidth(staircase))
    }

    @Test("tidying 60 scattered tiles twice changes nothing — no creep")
    func tidyIsStableAtSixty() {
        // The case where creep would actually show: a bound re-derived from the
        // selection's box would shrink on every pass, because a wrap narrows the box.
        let scattered: [CGRect] = (0..<60).map { (i: Int) -> CGRect in
            let x: Int = (i * 137) % 900
            let y: Int = (i * 71) % 700
            let w: Int = 100 + (i % 5) * 40
            let h: Int = 80 + (i % 3) * 30
            return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
        }
        let once = CanvasArrange.apply(.tidyUp, to: scattered)
        var previous = once
        for _ in 0..<4 {   // four more presses; creep compounds, so look past the first
            let next = CanvasArrange.apply(.tidyUp, to: previous)
            for (a, b) in zip(previous, next) {
                #expect(approx(a.minX, b.minX) && approx(a.minY, b.minY))
            }
            previous = next
        }
        // The bound itself is unchanged, which is why the layout is: it comes from the
        // rects' total area, not from the box the wrap just narrowed.
        #expect(approx(CanvasArrange.tidyMaxRowWidth(scattered),
                       CanvasArrange.tidyMaxRowWidth(once)))
        #expect(rowTops(once).count > 1)
    }

    @Test("a wrapped tidy still preserves every tile's size — it is not a uniform grid")
    func wrappedTidyPreservesSizes() {
        let mixed: [CGRect] = (0..<60).map { (i: Int) -> CGRect in
            let w: Int = 60 + (i % 7) * 50
            let h: Int = 40 + (i % 4) * 60
            return CGRect(x: CGFloat(i * 13), y: CGFloat(i * 5), width: CGFloat(w), height: CGFloat(h))
        }
        let out = CanvasArrange.apply(.tidyUp, to: mixed)
        #expect(out.count == mixed.count)
        for (before, after) in zip(mixed, out) {
            #expect(approx(before.width, after.width) && approx(before.height, after.height))
        }
        #expect(Set(out.map(\.width)).count > 1)   // sanity: they really do differ
    }

    @Test("a pile at one point falls back to the borrowed row width, and still wraps")
    func degeneratePileFallsBackToMaxRowWidth() {
        // Zero-width bounding box: a box-derived bound would be 0 here (or a division
        // by it). 24 tiles at 200 wide would then be one row 5,260pt across.
        let pile = Array(repeating: rect(100, 100, 200, 150), count: 24)
        #expect(approx(CanvasArrange.tidyMaxRowWidth(pile), CanvasArrange.fallbackMaxRowWidth))
        let out = CanvasArrange.apply(.tidyUp, to: pile)
        #expect(rowTops(out).count > 1)
        #expect(rowTops(out).count == 4)           // 7 per row at 1600
        let left = out.map(\.minX).min()!
        for top in rowTops(out) {
            #expect(row(out, at: top).map(\.maxX).max()! - left <= CanvasArrange.fallbackMaxRowWidth)
        }
    }

    @Test("zero-area rects derive no bound and do not divide by zero")
    func zeroAreaFallsBack() {
        let empty = Array(repeating: CGRect(x: 5, y: 5, width: 0, height: 0), count: 3)
        #expect(approx(CanvasArrange.tidyMaxRowWidth(empty), CanvasArrange.fallbackMaxRowWidth))
        let out = CanvasArrange.apply(.tidyUp, to: empty)
        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.minX.isFinite && $0.minY.isFinite })
    }

    @Test("the borrowed constants mirror SpaceLayout — the copies must not drift")
    func fallbackMirrorsSpaceLayout() {
        // `CanvasArrange` keeps its own copies so the kernel stays free of the space
        // layer; this is the guard that a copy stays a copy. Reflow's two matter most:
        // its whole claim is that a repacked block matches a freshly bulk-added one,
        // and that claim is only true while these numbers are `SpaceLayout`'s.
        #expect(CanvasArrange.fallbackMaxRowWidth == CGFloat(SpaceLayout.maxRowWidth))
        #expect(CanvasArrange.gridRowHeight == CGFloat(SpaceLayout.rowHeight))
        #expect(CanvasArrange.gridSpacing == CGFloat(SpaceLayout.spacing))
    }

    @Test("an item wider than the bound still lands, alone on its row")
    func oversizeItemStillPlaced() {
        // A frame far wider than the bound alongside small tiles. A row that could
        // refuse every item would never terminate, so a row always takes its first.
        let frame = CGRect(x: 0, y: 0, width: 5000, height: 200)
        let rects = [frame, rect(0, 0, 100, 100), rect(200, 10, 100, 100), rect(400, 20, 100, 100)]
        let bound = CanvasArrange.tidyMaxRowWidth(rects)
        #expect(frame.width > bound)

        let out = CanvasArrange.apply(.tidyUp, to: rects)
        #expect(out.count == 4)
        #expect(approx(out[0].width, 5000))                    // unresized
        #expect(approx(out[0].minX, 0) && approx(out[0].minY, 0))
        #expect(row(out, at: out[0].minY).count == 1)          // alone on its row
        #expect(rowTops(out).count == 2)                       // the three tiles follow
    }

    // MARK: - Reflow into grid

    /// The resized set a reflow actually flows: every tile at ``gridRowHeight``, width
    /// following its aspect. The wrap bound is derived from THIS, not from the input —
    /// the tests below re-derive it the same way, so a bound taken from the originals
    /// would show up as a row running past it.
    private func resized(_ rects: [CGRect]) -> [CGRect] {
        rects.map { r in
            let aspect = (r.width > 0 && r.height > 0) ? r.width / r.height : 1
            return CGRect(x: r.minX, y: r.minY,
                          width: CanvasArrange.gridRowHeight * max(aspect, 0.01),
                          height: CanvasArrange.gridRowHeight)
        }
    }

    /// The indices of `rects` in reading order — top-to-bottom, then left-to-right.
    private func readingOrder(_ rects: [CGRect]) -> [Int] {
        rects.indices.sorted { a, b in
            let (ra, rb) = (rects[a], rects[b])
            if !approx(ra.minY, rb.minY) { return ra.minY < rb.minY }
            return ra.minX < rb.minX
        }
    }

    /// 24 tiles at five aspect ratios and three heights, scattered the way a bulk drop
    /// leaves a board. Mixed on purpose: "the row's bottom edge lines up" is only a real
    /// claim when the tiles did not already share a height, and it is the property tidy
    /// structurally cannot deliver.
    private static let mixedScatter: [CGRect] = (0..<24).map { (i: Int) -> CGRect in
        CGRect(x: CGFloat((i * 137) % 900), y: CGFloat((i * 71) % 700),
               width: CGFloat(100 + (i % 5) * 40), height: CGFloat(80 + (i % 3) * 30))
    }

    @Test("reflow puts every tile at one row height and keeps its aspect")
    func reflowNormalisesHeightKeepsAspect() {
        let out = CanvasArrange.apply(.reflowGrid, to: Self.mixedScatter)
        #expect(out.count == Self.mixedScatter.count)
        for (before, after) in zip(Self.mixedScatter, out) {
            #expect(approx(after.height, CanvasArrange.gridRowHeight))
            #expect(approx(after.width / after.height, before.width / before.height))
        }
        // Sanity: the input really did carry more than one height, so the normalisation
        // is doing work rather than agreeing with what was already there.
        #expect(Set(Self.mixedScatter.map(\.height)).count > 1)
        #expect(Set(out.map(\.width)).count > 1)   // …and widths still differ
    }

    @Test("reflowing twice changes nothing the second time — the design constraint")
    func reflowIsStableUnderItsOwnOutput() {
        // The three ways idempotence could break, each with a fixture: the resize could
        // not be the identity on its own output; the bound could be re-derived from a
        // changed area; the reading order could re-cluster differently once laid out.
        let cases: [[CGRect]] = [
            Self.mixedScatter,                                       // wraps, mixed aspects
            [rect(0, 0), rect(70, 3), rect(2, 60), rect(74, 62)],    // a small 2×2
            [rect(0, 0), rect(8, 60), rect(3, 140)],                 // a column
            Array(repeating: rect(100, 100, 200, 150), count: 24),   // a pile at one point
        ]
        for rects in cases {
            let once = CanvasArrange.apply(.reflowGrid, to: rects)
            var previous = once
            for _ in 0..<4 {   // creep compounds, so look past the first re-press
                let next = CanvasArrange.apply(.reflowGrid, to: previous)
                for (a, b) in zip(previous, next) {
                    #expect(approx(a.minX, b.minX) && approx(a.minY, b.minY))
                    #expect(approx(a.width, b.width) && approx(a.height, b.height))
                }
                previous = next
            }
        }
    }

    @Test("the block wraps at the bound derived from the RESIZED tiles")
    func reflowWrapsAtTheResizedBound() {
        let input = Self.mixedScatter
        let bound = CanvasArrange.tidyMaxRowWidth(resized(input))
        let out = CanvasArrange.apply(.reflowGrid, to: input)
        let left = input.map(\.minX).min()!

        #expect(rowTops(out).count > 1)                     // it really did wrap
        for r in out { #expect(r.maxX <= left + bound + Self.eps) }

        // The bound from the INPUT rects is a different number here — which is the whole
        // reason it is derived post-resize. Taking it from the originals would give pass
        // one and pass two different row counts.
        #expect(!approx(CanvasArrange.tidyMaxRowWidth(input), bound))
    }

    @Test("rows are justified — one row shares a top edge AND a bottom edge")
    func reflowJustifiesRows() {
        // Tidy cannot give you this: it preserves sizes, so a row of mixed heights lines
        // up along its top and is ragged along its bottom. Reflow's uniform height is
        // what buys the second edge, and it is the visible difference between the two.
        let out = CanvasArrange.apply(.reflowGrid, to: Self.mixedScatter)
        let tops = rowTops(out)
        #expect(tops.count > 1)
        for top in tops {
            let members = row(out, at: top)
            #expect(members.count >= 1)
            #expect(members.allSatisfy { approx($0.minY, top) })
            #expect(members.allSatisfy { approx($0.maxY, members[0].maxY) })
        }
        // Consecutive rows step by exactly one tile plus the fixed gap — no running row
        // height to accumulate, because every row is the same height.
        for (above, below) in zip(tops, tops.dropFirst()) {
            #expect(approx(below - above, CanvasArrange.gridRowHeight + CanvasArrange.gridSpacing))
        }
        // Every row starts at the anchor; adjacent tiles sit exactly `gridSpacing` apart.
        let left = Self.mixedScatter.map(\.minX).min()!
        for top in tops {
            let members = row(out, at: top)
            #expect(approx(members.first!.minX, left))
            for (a, b) in zip(members, members.dropFirst()) {
                #expect(approx(b.minX - a.maxX, CanvasArrange.gridSpacing))
            }
        }
    }

    @Test("reflow keeps the reading order the user built, and discards only the shape")
    func reflowKeepsReadingOrder() {
        // Index 2 is top-left, index 0 top-right (overlapping it vertically, so the same
        // row), index 1 alone below. Array order is none of that — a selection arrives
        // from a Set, so the sequence has to come from the positions.
        let scattered = [rect(300, 5, 100, 100), rect(0, 400, 100, 100), rect(0, 0, 100, 100)]
        let out = CanvasArrange.apply(.reflowGrid, to: scattered)

        #expect(readingOrder(out) == [2, 0, 1])
        // Anchored on the input's top-left; three squares fit one row at the bound.
        #expect(approx(out[2].minX, 0) && approx(out[2].minY, 0))
        #expect(approx(out[0].minX, CanvasArrange.gridRowHeight + CanvasArrange.gridSpacing))
        #expect(out.allSatisfy { approx($0.minY, 0) })

        // And it survives a wrap. Two clean input rows of five, shuffled in the array so
        // array order is nobody's answer; six fit a row at the bound, so the wrap falls
        // mid-way through the FIRST input row — the case where a naive implementation
        // would restart the sequence at each input cluster instead of flowing through it.
        let twoRows: [CGRect] = [
            rect(600, 0, 100, 100),    // 0 — input row 1, fifth
            rect(150, 200, 100, 100),  // 1 — input row 2, second
            rect(0, 0, 100, 100),      // 2 — input row 1, first
            rect(300, 200, 100, 100),  // 3 — input row 2, third
            rect(300, 0, 100, 100),    // 4 — input row 1, third
            rect(0, 200, 100, 100),    // 5 — input row 2, first
            rect(450, 0, 100, 100),    // 6 — input row 1, fourth
            rect(600, 200, 100, 100),  // 7 — input row 2, fifth
            rect(150, 0, 100, 100),    // 8 — input row 1, second
            rect(450, 200, 100, 100),  // 9 — input row 2, fourth
        ]
        let wrapped = CanvasArrange.apply(.reflowGrid, to: twoRows)
        #expect(readingOrder(wrapped) == [2, 8, 4, 6, 0, 5, 1, 3, 9, 7])
        #expect(rowTops(wrapped).count == 2)
        #expect(row(wrapped, at: rowTops(wrapped).first!).count == 6)  // 6 fit at the bound
    }

    @Test("reflow anchors on the selection's top-left — the block does not jump")
    func reflowAnchorsOnTheBoundingBox() {
        let offset = Self.mixedScatter.map { $0.offsetBy(dx: -700, dy: 1200) }
        let out = CanvasArrange.apply(.reflowGrid, to: offset)
        #expect(approx(out.map(\.minX).min()!, offset.map(\.minX).min()!))
        #expect(approx(out.map(\.minY).min()!, offset.map(\.minY).min()!))
    }

    @Test("reflow loses no tile — every index still carries a rect")
    func reflowPreservesCount() {
        for input in [Self.mixedScatter, Self.uniform60] {
            let out = CanvasArrange.apply(.reflowGrid, to: input)
            #expect(out.count == input.count)
            #expect(out.allSatisfy { $0.minX.isFinite && $0.minY.isFinite })
            // No two tiles land on the same spot — a lost tile would show up as a
            // duplicated origin rather than a short array.
            #expect(Set(out.map { "\($0.minX),\($0.minY)" }).count == out.count)
        }
    }

    @Test("a degenerate rect reflows to a square rather than a NaN")
    func reflowSurvivesDegenerateInput() {
        // Zero height would divide by zero deriving an aspect; zero width would give a
        // zero-width tile nothing can grab. Both fall back the way `SpaceLayout` does.
        let degenerate = [CGRect(x: 0, y: 0, width: 100, height: 0),
                          CGRect(x: 200, y: 0, width: 0, height: 80),
                          CGRect(x: 400, y: 0, width: 120, height: 60)]
        let out = CanvasArrange.apply(.reflowGrid, to: degenerate)

        #expect(out.count == 3)
        #expect(out.allSatisfy { $0.minX.isFinite && $0.minY.isFinite })
        #expect(out.allSatisfy { $0.width.isFinite && $0.height.isFinite })
        #expect(out.allSatisfy { approx($0.height, CanvasArrange.gridRowHeight) })
        // The two degenerate ones become squares (aspect 1); the honest one keeps its 2:1.
        #expect(approx(out[0].width, CanvasArrange.gridRowHeight))
        #expect(approx(out[1].width, CanvasArrange.gridRowHeight))
        #expect(approx(out[2].width, CanvasArrange.gridRowHeight * 2))
        // …and it is still stable, which is the case a fallback most easily breaks.
        let twice = CanvasArrange.apply(.reflowGrid, to: out)
        for (a, b) in zip(out, twice) { #expect(a == b) }
    }

    @Test("reflow is a no-op below two, like every other arrange op")
    func reflowBelowTwoIsANoOp() {
        let one = [rect(7, 9)]
        #expect(CanvasArrange.apply(.reflowGrid, to: one) == one)
        #expect(CanvasArrange.Operation.reflowGrid.minimumCount == 2)
        #expect(CanvasArrange.Operation.reflowGrid.isDistribute == false)
        #expect(CanvasArrange.Operation.reflowGrid.actionName == "Reflow Into Grid")
    }

    @Test("tidy is untouched by reflow existing — it still preserves every size")
    func tidyRemainsSizePreserving() {
        // Reflow is additive. The one way this change could have gone wrong invisibly is
        // by teaching tidy to resize as well, so pin it next to its sibling.
        let out = CanvasArrange.apply(.tidyUp, to: Self.mixedScatter)
        for (before, after) in zip(Self.mixedScatter, out) {
            #expect(approx(before.width, after.width) && approx(before.height, after.height))
        }
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
