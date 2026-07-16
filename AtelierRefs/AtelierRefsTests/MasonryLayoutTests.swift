//
//  MasonryLayoutTests.swift
//  AtelierRefsTests
//
//  011-B1 — the round-robin masonry layout, exhaustively (the render itself is
//  only manually verifiable):
//
//   • [10A′] `MasonryLayout.layout` degenerate + property matrix: column
//     membership `i % C`, cumulative stacking, content height, in-bounds frames,
//     positive/finite heights, the aspect guard, and the column-width packing.
//   • [9A′] frame-feed contract: the band-narrowed `masonryMarqueeIndices` MUST
//     return exactly what the general `marqueeIndices` core returns over the same
//     frames — same set, same (ascending) order — across a rect zoo × layout
//     shapes. If it ever diverges the marquee silently mis-selects.
//   • [6A] `aspect(for:)` degenerate matrix: clamp bounds, media-less → 1, zero
//     dims → 1.
//

import AtelierCore
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("MasonryLayout: placement")
struct MasonryLayoutPlacementTests {

    @Test("empty input yields no frames and content height == top inset")
    func empty() {
        let layout = MasonryLayout.layout(
            aspects: [], availableWidth: 500, columns: 4, spacing: 8, topInset: 4)
        #expect(layout.frames.isEmpty)
        #expect(layout.contentHeight == 4)
        #expect(layout.columns == 4)
    }

    @Test("a single square item sits at the top-left, column width square")
    func single() {
        // width 500, 4 cols, spacing 8 → colWidth = (500 - 24)/4 = 119.
        let layout = MasonryLayout.layout(
            aspects: [1], availableWidth: 500, columns: 4, spacing: 8, topInset: 4)
        #expect(layout.columnWidth == 119)
        #expect(layout.frames == [CGRect(x: 0, y: 4, width: 119, height: 119)])
        #expect(layout.contentHeight == 4 + layout.columnWidth)   // top inset + one row
    }

    @Test("items round-robin across columns: column of item i is i % C")
    func roundRobin() {
        let layout = MasonryLayout.layout(
            aspects: Array(repeating: 1.0, count: 7), availableWidth: 300,
            columns: 3, spacing: 0, topInset: 0)
        // colWidth = 100. Column = i % 3, so x = (i % 3) * 100.
        for (i, frame) in layout.frames.enumerated() {
            #expect(frame.minX == CGFloat(i % 3) * 100)
        }
        // Row within a column is i / 3, cells 100 tall, no spacing.
        #expect(layout.frames[0].minY == 0)     // col 0, row 0
        #expect(layout.frames[3].minY == 100)   // col 0, row 1
        #expect(layout.frames[6].minY == 200)   // col 0, row 2
        #expect(layout.frames[1].minY == 0)     // col 1, row 0
    }

    @Test("cells stack by cumulative height within a column (render == frame)")
    func cumulativeStacking() {
        // Mixed aspects so heights differ; verify each cell sits exactly at the
        // running bottom of its column + spacing (what the LazyVStack renders).
        let aspects = [1.0, 2.0, 0.5, 1.0, 1.0, 2.0]   // 3 cols → 2 per column
        let layout = MasonryLayout.layout(
            aspects: aspects, availableWidth: 300, columns: 3, spacing: 10, topInset: 5)
        let cw = layout.columnWidth
        for col in 0..<3 {
            let idxs = stride(from: col, to: aspects.count, by: 3).map { $0 }
            var penY: CGFloat = 5
            for i in idxs {
                let f = layout.frames[i]
                #expect(f.minX == CGFloat(col) * (cw + 10))
                #expect(f.width == cw)
                #expect(f.minY == penY)
                #expect(f.height == cw / CGFloat(aspects[i]))
                penY += f.height + 10
            }
        }
    }

    @Test("content height is the tallest column's bottom (ragged columns)")
    func contentHeightIsTallestColumn() {
        // One very tall item in column 0 (aspect 0.25 → height 4×colWidth) makes
        // column 0 the tallest; content height tracks it, not the short columns.
        let aspects = [0.25, 1.0, 1.0]   // 3 cols, one item each
        let layout = MasonryLayout.layout(
            aspects: aspects, availableWidth: 300, columns: 3, spacing: 0, topInset: 0)
        let cw = layout.columnWidth   // 100
        #expect(layout.frames[0].height == cw / 0.25)   // 400
        #expect(layout.contentHeight == cw / 0.25)      // tallest column bottom
    }

    @Test("fewer items than columns leaves trailing columns empty")
    func fewerItemsThanColumns() {
        let layout = MasonryLayout.layout(
            aspects: [1, 1], availableWidth: 500, columns: 4, spacing: 8, topInset: 0)
        #expect(layout.frames.count == 2)
        #expect(layout.columns == 4)
        // Only columns 0 and 1 are occupied.
        #expect(layout.frames[0].minX == 0)
        #expect(layout.frames[1].minX == layout.columnWidth + 8)
    }

    @Test("a single column (C=1) stacks everything vertically")
    func singleColumn() {
        let layout = MasonryLayout.layout(
            aspects: [1, 1, 1], availableWidth: 200, columns: 1, spacing: 6, topInset: 0)
        #expect(layout.columnWidth == 200)
        #expect(layout.frames.map(\.minX) == [0, 0, 0])
        #expect(layout.frames[0].minY == 0)
        #expect(layout.frames[1].minY == layout.columnWidth + 6)          // one cell + gap
        #expect(layout.frames[2].minY == 2 * (layout.columnWidth + 6))    // two cells + gaps
    }

    @Test("columns clamp to at least 1")
    func columnsClamp() {
        let layout = MasonryLayout.layout(
            aspects: [1, 1], availableWidth: 200, columns: 0, spacing: 0, topInset: 0)
        #expect(layout.columns == 1)
        #expect(layout.frames.map(\.minX) == [0, 0])
    }

    @Test("a non-finite or non-positive aspect is guarded to a square")
    func aspectGuard() {
        let layout = MasonryLayout.layout(
            aspects: [0, -1, .nan, .infinity], availableWidth: 400, columns: 4,
            spacing: 0, topInset: 0)
        let cw = layout.columnWidth   // 100
        for frame in layout.frames {
            #expect(frame.height == cw)              // treated as aspect 1
            #expect(frame.height.isFinite)
        }
    }

    @Test("all frames are in-bounds, finite, and positive across a shape matrix")
    func propertyMatrix() {
        let widths: [CGFloat] = [120, 375, 800, 1440]
        let columnCounts = [1, 2, 3, 5, 8]
        let spacings: [CGFloat] = [0, 8, 16]
        // A spread of clamped aspects (portrait → landscape).
        let aspects = [0.25, 0.5, 0.8, 1.0, 1.5, 2.0, 4.0, 1.0, 0.6, 3.0, 1.2]
        for width in widths {
            for cols in columnCounts {
                for spacing in spacings {
                    let layout = MasonryLayout.layout(
                        aspects: aspects, availableWidth: width, columns: cols,
                        spacing: spacing, topInset: 4)
                    #expect(layout.frames.count == aspects.count)
                    for (i, f) in layout.frames.enumerated() {
                        #expect(f.minX >= 0)
                        #expect(f.width == layout.columnWidth)
                        #expect(f.height > 0)
                        #expect(f.height.isFinite)
                        #expect(f.minY >= 4)                    // at or below the inset
                        #expect(f.maxY <= layout.contentHeight + 0.001)
                        // Column membership is i % C, and every cell fits the width.
                        #expect(f.minX == CGFloat(i % max(1, cols)) * (layout.columnWidth + spacing))
                        #expect(f.maxX <= width + 0.001)
                    }
                }
            }
        }
    }
}

@Suite("MasonryLayout: marquee contract")
struct MasonryMarqueeContractTests {

    /// The band-narrowed fast path MUST equal the general core over the SAME
    /// frames — same order, same set.
    private func expectSameHits(
        rect: CGRect, aspects: [Double], width: CGFloat, columns: Int,
        spacing: CGFloat, topInset: CGFloat = 0,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let layout = MasonryLayout.layout(
            aspects: aspects, availableWidth: width, columns: columns,
            spacing: spacing, topInset: topInset)
        let general = marqueeIndices(in: rect, frames: layout.frames)
        let analytic = masonryMarqueeIndices(
            in: rect, frames: layout.frames, columns: layout.columns)
        #expect(analytic == general, sourceLocation: sourceLocation)
    }

    @Test("band-narrowed path matches the frame-array core across shapes and rects")
    func analyticMatchesGeneral() {
        // Staggered aspects so column bottoms are ragged (the whole point of the
        // y-monotonic binary search): the rects must resolve identically anyway.
        let aspects = [0.4, 1.0, 2.0, 0.5, 1.3, 1.0, 3.0, 0.7, 1.0, 2.5, 0.9, 1.1, 1.0, 0.3]
        let rects = [
            CGRect(x: 0, y: 0, width: 150, height: 50),      // top strip
            CGRect(x: 0, y: 0, width: 40, height: 4000),     // tall thin, column 0
            CGRect(x: 0, y: 0, width: 3000, height: 4000),   // cover everything
            CGRect(x: 0, y: 200, width: 3000, height: 120),  // a horizontal band
            CGRect(x: 150, y: 0, width: 0, height: 4000),    // thin vertical drag
            CGRect(x: 0, y: 150, width: 3000, height: 0),    // thin horizontal drag
            CGRect(x: 130, y: 130, width: 0, height: 0),     // a click
            CGRect(x: 5000, y: 5000, width: 10, height: 10), // wholly past the grid
            CGRect(x: -50, y: -50, width: 200, height: 200), // starts before origin
            CGRect(x: 37, y: 61, width: 220, height: 175),   // arbitrary off-grid rect
        ]
        let shapes: [(CGFloat, Int, CGFloat, CGFloat)] = [
            (300, 3, 0, 0), (300, 3, 10, 4), (500, 4, 8, 0),
            (200, 1, 6, 2), (800, 5, 12, 4), (150, 2, 0, 0),
        ]
        for (width, cols, spacing, inset) in shapes {
            for rect in rects {
                expectSameHits(
                    rect: rect, aspects: aspects, width: width,
                    columns: cols, spacing: spacing, topInset: inset)
            }
        }
    }

    @Test("boundary-snug column marquee excludes the neighbour, matching the core")
    func boundarySnug() {
        // 3 uniform-square columns, no spacing → columns at x = 0,100,200.
        let aspects = Array(repeating: 1.0, count: 9)
        // Snug over column 0: right edge exactly on column 1's left edge (x=100).
        expectSameHits(
            rect: CGRect(x: 0, y: 0, width: 100, height: 300),
            aspects: aspects, width: 300, columns: 3, spacing: 0)
    }

    @Test("empty frames and degenerate columns match the core")
    func degenerate() {
        let big = CGRect(x: 0, y: 0, width: 9999, height: 9999)
        #expect(masonryMarqueeIndices(in: big, frames: [], columns: 3).isEmpty)
        // columns 0 clamps to 1 — same as the layout.
        expectSameHits(rect: big, aspects: [1, 1, 1], width: 200, columns: 0, spacing: 0)
    }
}

@Suite("aspect(for:) clamp + fallbacks")
struct AspectHelperTests {

    private func detail(width: Int?, height: Int?, kind: AssetKind = .image) -> CollectionItemDetail {
        let sourceID = UUID(), assetID = UUID()
        let source = Source(id: sourceID, platform: .web, capturedAt: Date())
        let asset = Asset(
            id: assetID, kind: kind, blobHash: kind == .image ? UUID().uuidString : nil,
            mimeType: kind == .image ? "image/png" : nil, width: width, height: height,
            duration: nil, fileSize: kind == .image ? 100 : nil,
            downloadState: .downloaded, createdAt: Date(), sourceId: sourceID)
        let item = CollectionItem(
            id: UUID(), collectionID: UUID(), assetID: assetID, addedAt: Date())
        return CollectionItemDetail(item: item, asset: asset, source: source)
    }

    @Test("a normal landscape/portrait ratio passes through unclamped")
    func normalRatio() {
        #expect(aspect(for: detail(width: 200, height: 100)) == 2.0)
        #expect(aspect(for: detail(width: 100, height: 200)) == 0.5)
        #expect(aspect(for: detail(width: 100, height: 100)) == 1.0)
    }

    @Test("a panorama / skyscraper clamps to [0.25, 4.0]")
    func clamps() {
        #expect(aspect(for: detail(width: 5000, height: 100)) == 4.0)   // 50 → 4
        #expect(aspect(for: detail(width: 100, height: 5000)) == 0.25)  // 0.02 → 0.25
    }

    @Test("media-less kinds and missing/zero dims fall back to a square")
    func fallbacks() {
        #expect(aspect(for: detail(width: nil, height: nil, kind: .color)) == 1.0)
        #expect(aspect(for: detail(width: 0, height: 100)) == 1.0)
        #expect(aspect(for: detail(width: 100, height: 0)) == 1.0)
    }
}
