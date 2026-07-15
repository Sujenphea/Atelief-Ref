//
//  MarqueeMath.swift
//  AtelierRefs
//
//  009 · N6 — the pure geometry behind rubber-band (marquee) selection. Split in
//  two so the durable half survives the layout change coming in 011:
//
//   • `marqueeIndices(in:frames:)` — the PERMANENT layout-agnostic core: given the
//     drag rect and EVERY item's frame (offscreen included) it returns the hit
//     indices by rect-intersection. This is what 011-U2's `JustifiedLayout` will
//     feed once justified rows land.
//   • `uniformGridFrames(...)` — a TEMPORARY frame source for today's uniform grid
//     (1A). It computes each item's frame from pure math (so offscreen rows are
//     covered too); 011-U2 deletes it and hands `JustifiedLayout`'s exact frames
//     to the same core. Don't grow this — it's scaffolding.
//
//  Kept SwiftUI-free so the whole thing is unit-tested without a running view (the
//  virtualization trap is that `LazyVGrid` only lays out VISIBLE cells, so live
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

/// Every item's frame in a uniform grid of `columns` columns (009 · N6, TEMPORARY
/// — replaced by 011-U2's `JustifiedLayout` frames). Frames are laid out
/// left-to-right, top-to-bottom, starting at `(0, topInset)`, each `cellSize`
/// with `spacing` gaps. Offscreen rows included (that's the point). `columns` is
/// clamped to at least 1; a non-positive count returns no frames.
func uniformGridFrames(
    count: Int, columns: Int, cellSize: CGSize, spacing: CGFloat, topInset: CGFloat = 0
) -> [CGRect] {
    guard count > 0 else { return [] }
    let cols = max(1, columns)
    return (0..<count).map { i in
        let row = i / cols
        let col = i % cols
        return CGRect(
            x: CGFloat(col) * (cellSize.width + spacing),
            y: topInset + CGFloat(row) * (cellSize.height + spacing),
            width: cellSize.width, height: cellSize.height)
    }
}

/// The cell edge length a uniform adaptive grid uses to fill `availableWidth` with
/// `columns` columns and `spacing` gaps — the square side the marquee frames use
/// (mirrors how the grid packs a row). At least 1 to stay drawable.
func uniformCellSide(availableWidth: CGFloat, columns: Int, spacing: CGFloat) -> CGFloat {
    let cols = CGFloat(max(1, columns))
    let side = (availableWidth - (cols - 1) * spacing) / cols
    return max(1, side)
}
