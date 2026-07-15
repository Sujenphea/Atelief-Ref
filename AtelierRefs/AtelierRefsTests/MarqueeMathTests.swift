//
//  MarqueeMathTests.swift
//  AtelierRefsTests
//
//  009 · N6 — the marquee geometry, exhaustively, since the gesture itself is only
//  manually verifiable: rect normalization from any drag direction, the
//  layout-agnostic intersection core (across column counts, partial rows,
//  zero-size rects, and rects past the content bounds), and the temporary
//  uniform-grid frame source that feeds it today.
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

    // MARK: - Uniform grid frames

    @Test("uniform frames lay out row-major from the top inset")
    func framesLayout() {
        let frames = uniformGridFrames(
            count: 5, columns: 2, cellSize: CGSize(width: 100, height: 100),
            spacing: 10, topInset: 4)
        #expect(frames.count == 5)
        #expect(frames[0] == CGRect(x: 0, y: 4, width: 100, height: 100))     // r0c0
        #expect(frames[1] == CGRect(x: 110, y: 4, width: 100, height: 100))   // r0c1
        #expect(frames[2] == CGRect(x: 0, y: 114, width: 100, height: 100))   // r1c0
        #expect(frames[4] == CGRect(x: 0, y: 224, width: 100, height: 100))   // r2c0 (partial row)
    }

    @Test("zero count → no frames; columns clamp to at least 1")
    func framesDegenerate() {
        #expect(uniformGridFrames(
            count: 0, columns: 3, cellSize: CGSize(width: 10, height: 10), spacing: 2).isEmpty)
        let single = uniformGridFrames(
            count: 3, columns: 0, cellSize: CGSize(width: 10, height: 10), spacing: 2)
        // columns 0 → 1 column, so three stacked rows.
        #expect(single.map(\.minY) == [0, 12, 24])
    }

    @Test("uniformCellSide fills the width across the columns and gaps")
    func cellSide() {
        // 3 cols, 2 gaps of 10 in 320 → (320 - 20) / 3 = 100.
        #expect(uniformCellSide(availableWidth: 320, columns: 3, spacing: 10) == 100)
        // Never below 1 for a degenerate width.
        #expect(uniformCellSide(availableWidth: 0, columns: 4, spacing: 8) == 1)
    }

    // MARK: - Intersection core

    private func grid(_ count: Int, columns: Int) -> [CGRect] {
        uniformGridFrames(
            count: count, columns: columns,
            cellSize: CGSize(width: 100, height: 100), spacing: 0)
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
