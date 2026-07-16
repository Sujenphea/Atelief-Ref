//
//  MasonryLayoutCache.swift
//  AtelierRefs
//
//  011-B1 · 14A — a tiny memo for the collection grid's masonry frames. The
//  marquee's rubber-band publishes a new selection many times per second, and
//  each publish re-renders `CollectionView` (the selection rings must update);
//  without this the grid would re-run the O(N) `MasonryLayout.layout` on every
//  one of those ticks. The cache recomputes only when its key changes —
//  (itemsVersion, width, columns, spacing, topInset) — so a marquee drag (items /
//  width / columns all fixed) is a pure memo hit, mirroring 009's cached-id
//  discipline. Held in plain `@State`; not observed, so it never itself drives a
//  re-render, and scroll never touches the key (zero recompute on scroll).
//

import CoreGraphics

@MainActor
final class MasonryLayoutCache {
    private struct Key: Equatable {
        var version: Int
        var width: CGFloat
        var columns: Int
        var spacing: CGFloat
        var topInset: CGFloat
    }

    private var key: Key?
    private var value = MasonryFrames(frames: [], contentHeight: 0, columnWidth: 1, columns: 1)

    /// The memoized frames for the given inputs. `aspects` is invoked ONLY on a
    /// miss, so the O(N) per-item aspect derivation never runs on a cache hit.
    func frames(
        version: Int, width: CGFloat, columns: Int, spacing: CGFloat,
        topInset: CGFloat, aspects: () -> [Double]
    ) -> MasonryFrames {
        let k = Key(
            version: version, width: width, columns: columns,
            spacing: spacing, topInset: topInset)
        if key == k { return value }
        value = MasonryLayout.layout(
            aspects: aspects(), availableWidth: width, columns: columns,
            spacing: spacing, topInset: topInset)
        key = k
        return value
    }
}
