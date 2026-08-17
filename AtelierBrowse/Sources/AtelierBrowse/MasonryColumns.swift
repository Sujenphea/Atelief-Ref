// AtelierBrowse — the phone's masonry, as a decomposition rather than a solver
// (093 § 3).
//
// The Mac's grid is round-robin fixed-column masonry: item `i` lives in column
// `i % C` (`MasonryLayout.swift:96`), chosen so feed order equals reading order and
// `row = i / C` stays clean. That choice is what makes this file three functions long.
// Because column membership is a function of the INDEX alone — not of how tall the
// preceding cells turned out — the layout decomposes: column `c` is exactly the
// subsequence `stride(from: c, to: n, by: C)`, stacked top to bottom. An `HStack` of
// `C` `LazyVStack`s reproduces the Mac's frames without porting the solver, without a
// custom `Layout` (which would instantiate every subview and lose windowing), and
// without the `UICollectionView` bridge 092 · S5 forbids.
//
// A shortest-column-first packer would not decompose, and the phone would have had to
// choose between a uniform grid and re-running the 037–039 bake-off. The rhythm
// survives because of how it was chosen.
//
// Nothing here computes a FRAME. `MasonryLayout` must, because the marquee hit-tests
// offscreen cells that a windowed render never materialises; the phone has no marquee
// and no keyboard navigation, so SwiftUI's own stack layout does the arithmetic and
// this file only says which items go in which column and how wide a column is.

import AtelierCore
import Foundation

/// Round-robin fixed-column masonry for the phone (093 § 3).
public enum MasonryColumns {
    // MARK: - Aspect

    /// Aspect ratios below this read as a tall skyscraper, above ``maxAspect`` as a
    /// wide panorama. The clamp caps a freak image so `columnWidth / aspect` cannot
    /// blow a column's height unbounded, or collapse it to nothing.
    /// `MasonryLayout.minAspect` / `.maxAspect` (`MasonryLayout.swift:47`–`:48`).
    public static let minAspect: Double = 0.25
    public static let maxAspect: Double = 4.0

    /// The display aspect ratio (`w/h`) to lay a cell out with, clamped to
    /// `[minAspect, maxAspect]`.
    ///
    /// A media-less kind (003 · O1 — no intrinsic dimensions), a zero or negative
    /// dimension, or a NaN-inducing ratio falls back to a square `1`. The raw
    /// derivation mirrors `SpaceLayout.aspect(_:)` (`SpaceLayout.swift:32`) and the
    /// clamp mirrors `aspect(for:)` (`MasonryLayout.swift:125`).
    public static func aspect(_ asset: Asset) -> Double {
        guard let width = asset.width, let height = asset.height,
              width > 0, height > 0 else { return 1 }
        let raw = Double(width) / Double(height)
        guard raw.isFinite, raw > 0 else { return 1 }
        return min(max(raw, minAspect), maxAspect)
    }

    // MARK: - Column count

    /// The phone's column count: 2 in portrait, 3 in landscape (093 § 3).
    ///
    /// A local constant, deliberately not `GridDensity` (`GridDensity.swift:25`). That
    /// type is pure and width-parameterised, so it would port — and its stored default
    /// of 4 columns puts ~95pt cells on a 390pt screen, while its width floor
    /// `ceil(width / 512)` evaluates to 1 there and catches nothing. Its persisted
    /// notch also lives in `UserDefaults.standard`, which is not the App Group. There
    /// is no ⌘+/⌘− on a phone and pinch-to-change-density is a gesture v1 has no need
    /// to invent, so the count is a function of one bit and nothing stores it.
    public static func phoneColumns(isLandscape: Bool) -> Int {
        isLandscape ? 3 : 2
    }

    // MARK: - Decomposition

    /// The column each index belongs to, as `C` ascending index lists.
    ///
    /// Column `c` is `stride(from: c, to: count, by: C)`. `columns` clamps to at least
    /// 1, and the result always has exactly that many entries — a trailing column with
    /// nothing in it is an EMPTY list rather than a missing one, so the view's `HStack`
    /// keeps its geometry when a collection has fewer items than columns.
    public static func columnIndices(itemCount: Int, columns: Int) -> [[Int]] {
        let count = max(0, itemCount)
        let cols = max(1, columns)
        return (0 ..< cols).map { column in
            Array(stride(from: column, to: count, by: cols))
        }
    }

    /// ``columnIndices(itemCount:columns:)`` applied to a collection, so a view can
    /// hand each `LazyVStack` its own subsequence.
    ///
    /// Order within a column is preserved, and reading the columns left to right, row
    /// by row, replays the input order — which is the round-robin property, and the
    /// reason the grid can be read in feed order at all.
    public static func distribute<Element>(
        _ items: [Element], columns: Int
    ) -> [[Element]] {
        columnIndices(itemCount: items.count, columns: columns)
            .map { indices in indices.map { items[$0] } }
    }

    // MARK: - Geometry

    /// The width one column takes when `columns` of them pack into `availableWidth`
    /// with `spacing` between. At least 1 so a cell stays drawable; `columns` clamps to
    /// at least 1. `MasonryLayout.columnWidth(availableWidth:columns:spacing:)`
    /// (`MasonryLayout.swift:54`).
    public static func columnWidth(
        availableWidth: Double, columns: Int, spacing: Double
    ) -> Double {
        let cols = Double(max(1, columns))
        return max(1, (availableWidth - (cols - 1) * spacing) / cols)
    }
}
