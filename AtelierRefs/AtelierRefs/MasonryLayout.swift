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

import AtelierBrowse
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
    /// The aspect clamp and the column width are ``MasonryColumns``' (098 · finding 6).
    ///
    /// They were `static let minAspect` / `maxAspect` and a `columnWidth` function here
    /// until 093 § 3 restated all three inside `AtelierBrowse` for the phone, with a
    /// comment citing the line numbers in this file. That package's header gave the
    /// reason — 092 · S5 could not edit the macOS app — and that reason expired two
    /// slices later. The Mac links `AtelierBrowse` as of 098 · P4, so the numbers live
    /// in one place and the citations are no longer a promise anybody has to keep.
    ///
    /// **What did NOT move is the solver below.** The phone's grid is an `HStack` of
    /// `LazyVStack`s and computes no frame at all; this one must, because the marquee
    /// hit-tests offscreen cells a windowed render never materialises. Only the
    /// constants and the width arithmetic are shared — which is exactly the part that
    /// would drift silently, because a disagreement about a clamp is invisible until
    /// somebody compares two screens side by side.

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
        let colWidth = CGFloat(MasonryColumns.columnWidth(
            availableWidth: contentWidth, columns: cols, spacing: spacing))
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
/// `[MasonryColumns.minAspect, MasonryColumns.maxAspect]` (011-B1 · 6A). A
/// media-less kind (no intrinsic dims), a zero/negative dimension, or a
/// NaN-inducing ratio falls back to a square `1`; the clamp caps a panorama /
/// skyscraper so one freak image can't blow a column's height (cell height is
/// `columnWidth / aspect`).
///
/// A one-line forward to ``MasonryColumns/aspect(_:)`` since 098 · finding 6. That
/// function is this one with ``SpaceLayout/aspect(_:)`` inlined — same guard, same
/// fallback, same clamp — and it was written by copying this one. The name survives
/// because two grid hosts, the contact sheet and the bake-off grid all call it, and
/// because `CollectionItemDetail` is a macOS-app type the package cannot name.
func aspect(for detail: CollectionItemDetail) -> Double {
    MasonryColumns.aspect(detail.asset)
}
