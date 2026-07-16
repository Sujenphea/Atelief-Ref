//
//  MarqueeMath.swift
//  AtelierRefs
//
//  009 · N6 — the pure geometry behind rubber-band (marquee) selection. Split so
//  the durable half survived the 011 layout change:
//
//   • `marqueeIndices(in:frames:)` — the PERMANENT layout-agnostic core: given the
//     drag rect and EVERY item's frame (offscreen included) it returns the hit
//     indices by rect-intersection. `MasonryLayout` (011-B1) feeds it real frames.
//   • `masonryMarqueeIndices(in:frames:columns:)` — the 011-B1 · 13A′ fast path
//     for round-robin masonry: band-narrows the rect to the columns/rows it can
//     touch (analytic column membership `i % C`, y-monotonic binary search within
//     a column) and delegates the exact overlap to the SAME `rectsIntersect` the
//     core uses, so it returns exactly what the general core would — O(cols + hits
//     + logN per hit column) instead of the O(N) frame-array scan.
//
//  The 009 uniform-grid source (`uniformGridFrames` / `uniformMarqueeIndices` /
//  `uniformCellSide`) was retired here when masonry landed — see git history.
//
//  Kept SwiftUI-free so the whole thing is unit-tested without a running view (the
//  virtualization trap is that a lazy stack only lays out VISIBLE cells, so live
//  cell frames can't drive offscreen hit-testing — computed frames must).
//

import CoreGraphics

/// The normalized selection rect for a drag from `a` to `b` (corners in any
/// order) — always a rect with non-negative size.
func marqueeRect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(
        x: min(a.x, b.x), y: min(a.y, b.y),
        width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// The indices of `frames` the selection `rect` touches, in frame order (009 · N6
/// permanent core). A zero-size rect (a click, not a drag) selects the frames it
/// lands INSIDE — so a precise click on a cell still hits it — while never
/// touching neighbors. Intersection is inclusive of shared edges.
func marqueeIndices(in rect: CGRect, frames: [CGRect]) -> [Int] {
    frames.enumerated().compactMap { index, frame in
        rectsIntersect(rect, frame) ? index : nil
    }
}

/// Overlap between the marquee `a` and a cell frame `b`, boundary-aware:
///
/// - A marquee with area uses STRICT overlap, so a drag stopping exactly on a
///   row/column boundary doesn't sweep in the neighbouring line (a cell whose
///   edge merely touches the marquee's edge is not a hit).
/// - A degenerate marquee — a click (zero-size) or an axis-aligned thin drag
///   (`isEmpty`) — falls back to edge-INCLUSIVE overlap so it still registers the
///   cell it lands inside (unlike `CGRect.intersects`, false for a zero-area rect).
private func rectsIntersect(_ a: CGRect, _ b: CGRect) -> Bool {
    if a.isEmpty {
        return a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }
    return a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

/// The hit indices for a ROUND-ROBIN masonry grid (011-B1 · 13A′), band-narrowed
/// over the layout's REAL (aspect-staggered) frames. The general core scans all N
/// frames on EVERY marquee / auto-scroll tick; here column membership is analytic
/// (`i % C`) so the rect's x-range culls whole columns in O(1) each, and within a
/// surviving column the frames are y-monotonic (cumulative stacking) so a binary
/// search finds the first candidate and we walk forward only while the y-band can
/// still overlap — O(cols + hits + logN per hit column).
///
/// The exact overlap is the SAME `rectsIntersect` the general core uses (the
/// x-cull is edge-INCLUSIVE — a superset — so the strict/inclusive boundary call
/// is always left to that per-cell test, never pre-pruned), so the result is
/// identical to `marqueeIndices(in: rect, frames: frames)` — asserted in
/// `MasonryLayoutTests`. Indices come back ascending to match the core's order.
///
/// `frames` must be `MasonryLayout.layout(...)`'s output for `columns`; `columns`
/// clamps to ≥ 1. Empty frames yield no hits.
func masonryMarqueeIndices(in rect: CGRect, frames: [CGRect], columns: Int) -> [Int] {
    guard !frames.isEmpty else { return [] }
    let cols = max(1, columns)
    var hits: [Int] = []
    for col in 0..<min(cols, frames.count) {
        // Column `col`'s items are indices col, col+cols, col+2·cols, … . Its
        // count and x-span (every cell in a column shares x/width) come from the
        // first item.
        let colCount = (frames.count - col + cols - 1) / cols
        let first = frames[col]
        // O(1) x-cull, edge-inclusive: a column whose x-span can't touch the rect
        // is skipped whole. The exact strict-vs-inclusive call is `rectsIntersect`.
        guard rect.minX <= first.maxX, first.minX <= rect.maxX else { continue }
        // Binary search the first position whose cell BOTTOM reaches the rect top;
        // frames down a column are y-monotonic, so this lower bound is exact and
        // edge-inclusive (`>=`) — a boundary-touching click is never pruned.
        var lo = 0, hi = colCount
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[col + mid * cols].maxY >= rect.minY { hi = mid } else { lo = mid + 1 }
        }
        var p = lo
        while p < colCount {
            let index = col + p * cols
            let frame = frames[index]
            if frame.minY > rect.maxY { break }   // past the band (y-monotonic)
            if rectsIntersect(rect, frame) { hits.append(index) }
            p += 1
        }
    }
    return hits.sorted()
}
