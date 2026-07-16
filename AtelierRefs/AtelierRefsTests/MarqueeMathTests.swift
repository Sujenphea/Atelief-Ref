//
//  MarqueeMathTests.swift
//  AtelierRefsTests
//
//  009 · N6 — the marquee geometry, exhaustively, since the gesture itself is only
//  manually verifiable: rect normalization from any drag direction and the
//  layout-agnostic intersection core (across column counts, partial rows,
//  zero-size rects, and rects past the content bounds). The masonry frame source
//  that feeds this core in 011-B1 — plus the band-narrowed `masonryMarqueeIndices`
//  fast path proven equivalent to this core — lives in `MasonryLayoutTests`.
//

import CoreGraphics
import Testing
@testable import AtelierRefs

@Suite("Marquee geometry")
struct MarqueeMathTests {

    // MARK: - Rect normalization

    @Test("marqueeRect normalizes a drag from any corner into a positive rect")
    func rectNormalization() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        // All four drag directions between the same two corners.
        #expect(marqueeRect(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)) == expected)
        #expect(marqueeRect(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)) == expected)
        #expect(marqueeRect(from: CGPoint(x: 40, y: 20), to: CGPoint(x: 10, y: 60)) == expected)
        #expect(marqueeRect(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 40, y: 20)) == expected)
    }

    @Test("a zero-distance drag is a zero-size rect")
    func zeroRect() {
        let p = CGPoint(x: 5, y: 5)
        #expect(marqueeRect(from: p, to: p) == CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    // MARK: - Intersection core

    /// A uniform square grid of frames, laid out row-major — a test-local frame
    /// source for exercising the permanent `marqueeIndices` core (the production
    /// uniform-grid source was retired when masonry landed in 011-B1).
    private func grid(
        _ count: Int, columns: Int, cell: CGFloat = 100,
        spacing: CGFloat = 0, topInset: CGFloat = 0
    ) -> [CGRect] {
        let cols = max(1, columns)
        return (0..<count).map { i in
            CGRect(
                x: CGFloat(i % cols) * (cell + spacing),
                y: topInset + CGFloat(i / cols) * (cell + spacing),
                width: cell, height: cell)
        }
    }

    @Test("a rect over the first two cells hits exactly them")
    func hitsFirstRow() {
        let frames = grid(6, columns: 3)   // 3×2, 100pt cells, no spacing
        let rect = CGRect(x: 0, y: 0, width: 150, height: 50)  // covers cols 0-1 of row 0
        #expect(marqueeIndices(in: rect, frames: frames) == [0, 1])
    }

    @Test("a tall rect spans multiple rows, column-limited")
    func hitsColumn() {
        let frames = grid(9, columns: 3)   // 3×3
        // A thin rect down column 0 across all three rows.
        let rect = CGRect(x: 0, y: 0, width: 40, height: 300)
        #expect(marqueeIndices(in: rect, frames: frames) == [0, 3, 6])
    }

    @Test("a rect covering everything selects all indices in order")
    func hitsAll() {
        let frames = grid(6, columns: 3)
        let rect = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(marqueeIndices(in: rect, frames: frames) == [0, 1, 2, 3, 4, 5])
    }

    @Test("a partial last row is handled (no phantom cells)")
    func partialRow() {
        let frames = grid(5, columns: 3)   // row 1 has only 2 cells (indices 3,4)
        let rect = CGRect(x: 0, y: 100, width: 300, height: 100)  // over row 1
        #expect(marqueeIndices(in: rect, frames: frames) == [3, 4])
    }

    @Test("an area marquee whose edge only touches a boundary excludes the neighbour")
    func boundaryTouchExcludesNeighbour() {
        let frames = grid(9, columns: 3)   // 3×3, 100pt cells
        // A marquee snug over column 0 (x∈[0,100]) across all rows: its right edge
        // sits exactly on column 1's left edge (x=100) — strict overlap must NOT
        // pull in column 1.
        let column = CGRect(x: 0, y: 0, width: 100, height: 300)
        #expect(marqueeIndices(in: column, frames: frames) == [0, 3, 6])
        // A marquee snug over row 0 (y∈[0,100]): bottom edge on row 1's top edge.
        let row = CGRect(x: 0, y: 0, width: 300, height: 100)
        #expect(marqueeIndices(in: row, frames: frames) == [0, 1, 2])
    }

    @Test("an axis-aligned thin drag (zero-area) still registers the line it traces")
    func thinDragIsInclusive() {
        let frames = grid(9, columns: 3)   // 3×3
        // A vertical hairline down column 1's interior (x=150, zero width): the
        // degenerate branch stays edge-inclusive so it selects that column.
        let hairline = CGRect(x: 150, y: 0, width: 0, height: 300)
        #expect(marqueeIndices(in: hairline, frames: frames) == [1, 4, 7])
    }

    @Test("a rect past the content bounds simply hits nothing extra")
    func pastBounds() {
        let frames = grid(4, columns: 2)
        let rect = CGRect(x: 500, y: 500, width: 100, height: 100)  // far past the grid
        #expect(marqueeIndices(in: rect, frames: frames).isEmpty)
    }

    @Test("a zero-size rect (a click) hits the single cell it lands inside")
    func zeroSizeClick() {
        let frames = grid(6, columns: 3)
        // Click inside cell index 4 (row 1, col 1): x∈[100,200], y∈[100,200].
        let inside = CGRect(x: 150, y: 150, width: 0, height: 0)
        #expect(marqueeIndices(in: inside, frames: frames) == [4])
        // A click in the dead space past the grid hits nothing.
        let outside = CGRect(x: 350, y: 150, width: 0, height: 0)
        #expect(marqueeIndices(in: outside, frames: frames).isEmpty)
    }

    @Test("empty frames yield no hits for any rect")
    func emptyFrames() {
        #expect(marqueeIndices(in: CGRect(x: 0, y: 0, width: 999, height: 999), frames: []).isEmpty)
    }

    @Test("column count changes the hit set for the same rect")
    func acrossColumnCounts() {
        // Same 6 items, same rect over the top-left 150×150 region.
        let rect = CGRect(x: 0, y: 0, width: 150, height: 150)
        // 3 columns: top row cols 0,1 (0,1); row 1 starts at y=100, cols 0,1 (3,4).
        #expect(marqueeIndices(in: rect, frames: grid(6, columns: 3)) == [0, 1, 3, 4])
        // 2 columns: row 0 = 0,1; row 1 = 2,3 (both within 150 tall). Col span 0-1.
        #expect(marqueeIndices(in: rect, frames: grid(6, columns: 2)) == [0, 1, 2, 3])
    }
}
