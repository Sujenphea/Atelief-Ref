//
//  MasonryLayout.swift
//  AtelierRefs
//
//  011-B1 — pure, testable frame math for the collection grid's ROUND-ROBIN
//  fixed-column masonry (replaces the old uniform `.adaptive` `LazyVGrid`). Item
//  `i` lives in column `i % C` (round-robin, so feed order == visual reading
//  order and `row = i / C` stays clean for keyboard nav / reorder); within a
//  column, aspect-sized cells stack top-to-bottom by cumulative height.
//
//  Kept SwiftUI-free so the EXACT frames — including the OFFSCREEN cells a
//  windowed render never materializes (012) — drive the marquee hit-test and the
//  keyboard-nav column count (the virtualization trap: only on-screen cells
//  exist, so live cell frames can't see offscreen rows — computed frames must).
//  The windowed render (`CollectionView.masonryWindow`) places each visible cell
//  ABSOLUTELY at its frame here, so render position == frame BY CONSTRUCTION, and
//  the same frames drive the marquee — one geometry source, no drift.
//  `MasonryLayoutTests` asserts the frame math. (The old SwiftUI windowing slice
//  and its `GridWindowingTests` were retired with the SwiftUI grid — 189.)
//

import AtelierCore
import CoreGraphics

/// The computed masonry layout for one grid: every item's frame (offscreen
/// included) plus the total content height and the shared column width. A pure
/// value — no view state.
struct MasonryFrames: Equatable {
    /// Each item's frame in grid content space, index-aligned to the input
    /// aspects. Column `i % C`; `x`/`width` are uniform per column, `y` is the
    /// running height of that column.
    var frames: [CGRect]
    /// The tallest column's bottom edge — the scroll content height (the top
    /// inset when there are no items).
    var contentHeight: CGFloat
    /// The width every cell shares (the column width for the given C + gaps).
    var columnWidth: CGFloat
    /// The clamped column count actually used (≥ 1).
    var columns: Int
}

/// Round-robin fixed-column masonry placement (011-B1). Pure so the frames are
/// unit-tested without a running view.
enum MasonryLayout {
    /// Aspect ratios below this read as a tall skyscraper; above ``maxAspect`` as
    /// a wide panorama. Clamping caps a freak image so `columnWidth / aspect`
    /// can't blow a column's height unbounded (or go to ~0). See ``aspect(for:)``.
    static let minAspect: Double = 0.25
    static let maxAspect: Double = 4.0

    /// The column width that packs `columns` columns with `spacing` gaps into
    /// `availableWidth`. At least 1 to stay drawable (mirrors the old
    /// `uniformCellSide`). `columns` clamps to ≥ 1.
    static func columnWidth(
        availableWidth: CGFloat, columns: Int, spacing: CGFloat
    ) -> CGFloat {
        let cols = CGFloat(max(1, columns))
        let width = (availableWidth - (cols - 1) * spacing) / cols
        return max(1, width)
    }

    /// Lay `aspects` (each `w/h`) into `columns` round-robin columns spanning
    /// `availableWidth`, with `spacing` between cells both ways, starting at
    /// `topInset`. Item `i` → column `i % C`; its width is the shared column
    /// width, its height `columnWidth / aspect`, its `y` the running height of
    /// its column. `columns` clamps to ≥ 1; an empty input yields no frames and a
    /// content height of `topInset`.
    ///
    /// `leadingInset` / `trailingInset` reserve horizontal margins WITHIN
    /// `availableWidth`: the columns pack into `availableWidth - leadingInset -
    /// trailingInset` and every frame's `x` is offset by `leadingInset`. The
    /// collection view can then span the panel edge-to-edge (so the marquee
    /// background covers the margins) while the content still sits inset (200).
    /// Both default to 0, so the pre-inset call sites (and search) are unchanged.
    ///
    /// A non-finite or non-positive aspect is defensively treated as `1` so a
    /// stray value can never produce an infinite / NaN height (callers should
    /// pass ``aspect(for:)``, which already clamps).
    static func layout(
        aspects: [Double], availableWidth: CGFloat, columns: Int,
        spacing: CGFloat, topInset: CGFloat = 0,
        leadingInset: CGFloat = 0, trailingInset: CGFloat = 0
    ) -> MasonryFrames {
        let cols = max(1, columns)
        let contentWidth = availableWidth - leadingInset - trailingInset
        let colWidth = columnWidth(
            availableWidth: contentWidth, columns: cols, spacing: spacing)
        let strideX = colWidth + spacing

        // Each column's running pen-y (the next cell's top), seeded at the inset.
        var penY = [CGFloat](repeating: topInset, count: cols)
        var frames = [CGRect]()
        frames.reserveCapacity(aspects.count)

        for (i, rawAspect) in aspects.enumerated() {
            let col = i % cols
            let aspect = rawAspect.isFinite && rawAspect > 0 ? rawAspect : 1
            let height = colWidth / CGFloat(aspect)
            let y = penY[col]
            frames.append(CGRect(
                x: leadingInset + CGFloat(col) * strideX, y: y,
                width: colWidth, height: height))
            penY[col] = y + height + spacing
        }

        // The tallest column's bottom, backing out the trailing gap each touched
        // column added. An untouched column is still exactly at `topInset`.
        var contentHeight = topInset
        for p in penY where p > topInset {
            contentHeight = max(contentHeight, p - spacing)
        }
        return MasonryFrames(
            frames: frames, contentHeight: contentHeight,
            columnWidth: colWidth, columns: cols)
    }
}

/// The display aspect ratio (`w/h`) to lay a grid cell out with, CLAMPED to
/// `[MasonryLayout.minAspect, MasonryLayout.maxAspect]` (011-B1 · 6A). A
/// media-less kind (no intrinsic dims), a zero/negative dimension, or a
/// NaN-inducing ratio falls back to a square `1`; the clamp caps a panorama /
/// skyscraper so one freak image can't blow a column's height (cell height is
/// `columnWidth / aspect`). Built on ``SpaceLayout/aspect(_:)`` so the raw `w/h`
/// derivation lives in ONE place (6A DRY).
func aspect(for detail: CollectionItemDetail) -> Double {
    let raw = SpaceLayout.aspect(detail.asset)
    guard raw.isFinite, raw > 0 else { return 1 }
    return min(max(raw, MasonryLayout.minAspect), MasonryLayout.maxAspect)
}
