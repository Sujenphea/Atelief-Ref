//
//  GridWindowing.swift
//  AtelierRefs
//
//  012 — the pure math behind the collection grid's VIRTUALIZATION (windowing).
//  The grid renders every item's cell eagerly (011-B1 chose eager VStacks so the
//  cross-axis layout settles in one pass); at a few hundred items the live-cell
//  count alone dominates scroll — measured ~7.4s layout + ~2.0s hit-testing on the
//  main thread, both scaling with N. Windowing renders only the cells near the
//  viewport, placed by their analytic ``MasonryLayout`` frame.
//
//  Two composable, SwiftUI-free functions so both are unit-tested without a
//  running view (mirroring `MarqueeMath`'s discipline):
//
//   • ``gridWindow(offsetY:viewportHeight:contentHeight:width:bandHeight:)`` —
//     QUANTIZES the live scroll offset to a coarse band grid, so the render
//     re-materializes only when the scroll crosses a band boundary (a few times
//     per screenful) instead of every scroll tick. Returns a stable ``GridWindow``
//     whose equality gates the re-render.
//   • ``masonryVisibleIndices(in:frames:columns:overscan:)`` — the item indices
//     whose frames fall within a rect (the band's quantized viewport) expanded by
//     `overscan`. Reuses the band-narrowed ``masonryMarqueeIndices`` core over the
//     outset rect, so it stays O(cols + hits + logN) and returns EXACTLY the
//     frames that rect touches — the same oracle the marquee is tested against.
//

import CoreGraphics
import Foundation

/// The vertically-quantized viewport a windowed grid renders for a scroll
/// position (012). `band` is a stable identity — it changes ONLY when the scroll
/// crosses a `bandHeight` boundary, so a published `GridWindow` re-renders the
/// grid a few times per screenful, not once per scroll tick. `rect` is the
/// content-space viewport for that band: full `width` (so column x-culling sees
/// every column) and a y-span that covers the real viewport for ANY offset within
/// the band. The caller adds the overscan buffer via ``masonryVisibleIndices``.
struct GridWindow: Equatable {
    /// The band index the scroll offset falls in (≥ 0). Equality on the whole
    /// value gates the render, but this is the human-readable "which screenful".
    var band: Int
    /// The band's content-space viewport rect, pre-overscan.
    var rect: CGRect
}

/// Quantize `offsetY` to the band grid and return the band's viewport rect (012).
///
/// `band = floor(max(0, offsetY) / bandHeight)`, so any offset within a band maps
/// to the SAME band (stability). The rect starts at `band * bandHeight` and is
/// `bandHeight + viewportHeight` tall — the union of every real viewport
/// `[offsetY, offsetY + viewportHeight]` reachable while the offset stays in the
/// band — so a windowed render off this rect never misses an on-screen cell
/// regardless of where in the band the user paused. Width spans the whole grid so
/// the column x-cull in ``masonryVisibleIndices`` keeps every column.
///
/// Degenerate inputs are clamped so the result is always drawable: `bandHeight`
/// and `viewportHeight` floor at a positive value / zero respectively, and a
/// negative `offsetY` (rubber-band overscroll past the top) reads as band 0. A
/// content shorter than the viewport yields band 0 with a rect covering it all.
func gridWindow(
    offsetY: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat,
    width: CGFloat, bandHeight: CGFloat
) -> GridWindow {
    let band = max(1, bandHeight)
    let vh = max(0, viewportHeight)
    let w = max(0, width)
    // Clamp the offset into the scrollable range before banding: an offset past
    // the bottom (momentum overshoot) shouldn't invent bands beyond the content,
    // and a negative offset (top overscroll) is band 0.
    let maxOffset = max(0, contentHeight - vh)
    let clampedOffset = min(max(0, offsetY), maxOffset)
    let index = max(0, Int((clampedOffset / band).rounded(.down)))
    let top = CGFloat(index) * band
    return GridWindow(
        band: index,
        rect: CGRect(x: 0, y: top, width: w, height: band + vh))
}

/// The item indices whose ``MasonryLayout`` frames intersect `rect` expanded by
/// `overscan` on every side — the cells a windowed masonry render must
/// materialize for that viewport (012). A negative `overscan` is clamped to 0.
///
/// Delegates to the band-narrowed ``masonryMarqueeIndices`` over the OUTSET rect,
/// so it returns exactly what `marqueeIndices(in: outset, frames:)` would (the
/// same layout-agnostic oracle the marquee fast path is tested against) at
/// O(cols + hits + logN) rather than an O(N) frame scan. Ascending order; empty
/// frames yield no indices.
func masonryVisibleIndices(
    in rect: CGRect, frames: [CGRect], columns: Int, overscan: CGFloat
) -> [Int] {
    let pad = max(0, overscan)
    let outset = rect.insetBy(dx: -pad, dy: -pad)
    return masonryMarqueeIndices(in: outset, frames: frames, columns: columns)
}

/// One windowed cell the render will materialize: the item's feed `index` (its
/// identity, stable across scroll) and the analytic `frame` to place it at (012).
struct WindowedCell: Identifiable {
    let index: Int
    let frame: CGRect
    var id: Int { index }
}

/// Pair each visible index with its ``MasonryLayout`` frame — the EXACT input the
/// windowed render iterates (012). It is a pure FILTER, never a re-map: cell
/// `index` always binds to `items[index]` and `frames[index]`, so an off-by-one
/// can't silently show item A at item B's slot. An index out of range of the item
/// count or the frames (a transient skew while a resize recomputes one before the
/// other) is dropped rather than crashing — the marquee applies the same guard.
func windowedCells(visible: [Int], itemCount: Int, frames: [CGRect]) -> [WindowedCell] {
    visible.compactMap { i in
        guard i >= 0, i < itemCount, i < frames.count else { return nil }
        return WindowedCell(index: i, frame: frames[i])
    }
}

/// The hovered cell id after the window changed (012): keep it only while its
/// cell is still materialized, else drop it. Windowing can UNMOUNT the hovered
/// cell (it scrolled out) WITHOUT SwiftUI firing its `.onHover(false)` — which
/// would otherwise strand a phantom selection circle on a cell no longer under
/// the pointer. `nil` stays `nil`; an id still in view is kept unchanged.
func hoverAfterWindowChange(current: UUID?, visibleIDs: Set<UUID>) -> UUID? {
    guard let current, visibleIDs.contains(current) else { return nil }
    return current
}
