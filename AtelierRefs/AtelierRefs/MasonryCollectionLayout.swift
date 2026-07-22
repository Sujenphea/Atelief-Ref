//
//  MasonryCollectionLayout.swift
//  AtelierRefs
//
//  036 §2 A1 — the production `NSCollectionViewLayout` for the AppKit grid,
//  ported from the read-only `MasonryBakeoffLayout` spike (`Debug/
//  AppKitBakeoffGrid.swift`, measured in 038 §3.4). It reimplements NO masonry
//  math: `prepare()` calls the SAME memoized ``MasonryLayoutCache`` the SwiftUI
//  grid calls, and `layoutAttributesForElements(in:)` is `masonryMarqueeIndices`
//  — the band-narrowed O(cols + hits + logN) rect query from `MarqueeMath.swift`,
//  which is exactly the question AppKit asks on every scroll tick.
//
//  Two properties are load-bearing and both are the point of choosing AppKit:
//
//   1. **Flipped 1:1 mapping.** `MasonryLayout.layout` emits top-left-origin
//      frames and `NSCollectionView` is flipped, so the analytic frames go onto
//      the layout attributes with ZERO conversion. Confirmed as a coordinate-
//      SPACE identity in 038 §3.4, with a sub-pixel asterisk: AppKit pixel-snaps
//      the item VIEWS it places, so a fractional masonry height
//      (`columnWidth / aspect`) can render up to half a backing pixel off its
//      analytic value. Harmless for drawing, but it means A2/A3 hover, marquee,
//      selection rings and hit-testing must ride these ANALYTIC frames
//      (``analyticFrame(at:)``), never `cell.view.frame`.
//   2. **Zero invalidation while scrolling.** ``shouldInvalidateLayout(forBoundsChange:)``
//      compares WIDTH ONLY. A scroll moves the bounds ORIGIN, never the width, so
//      it answers `false` for every scroll tick and the masonry is never
//      re-solved mid-scroll — the "invalidation storm" 036 §A-risks warns about.
//      `MasonryCollectionLayoutTests` asserts a full scripted scroll produces
//      zero `prepare()` calls while a width change does invalidate.
//
//  Attributes are cached per index in `prepare()` (036 §2 A1) so a scroll query
//  only SELECTS from the cache via the rect math — it never allocates an
//  attributes object per visible cell per tick.
//

import AppKit
import CoreGraphics

/// `NSCollectionViewLayout` over the existing ``MasonryLayoutCache`` (036 §2 A1).
@MainActor
final class MasonryCollectionLayout: NSCollectionViewLayout {
    /// Per-item aspect ratios, index-aligned to the data source's items. Set by
    /// the host coordinator from ``aspect(for:)`` whenever the item set changes.
    var aspects: [Double] = []
    /// The density notch; the rendered column count is `density.columns(forWidth:)`
    /// at the live viewport width, so it matches the SwiftUI grid and keyboard nav.
    var density: GridDensity = .default
    var spacing: CGFloat = 8
    var topInset: CGFloat = 0
    /// Bumped by the host when the item set changes, so the memo key moves and the
    /// masonry re-solves even at an unchanged width.
    var itemsVersion = 0
    /// Test seam: the width to solve at when there is no live collection view.
    /// Production always reads the clip view instead.
    var explicitWidth: CGFloat?

    /// A live reorder-drag preview (040): the frames to RENDER in place of the
    /// real solve while an eligible drag hovers the grid, index-aligned to the
    /// data source's items. The coordinator sets it (then `invalidateLayout()`)
    /// and clears it on every drag-exit path; `nil` in the steady state. It is
    /// read through ``activePreview``, which ignores a preview whose item count
    /// disagrees with the current solve — so a stale preview left across a
    /// reload can never build a mismatched attributes cache.
    ///
    /// The preview frames are in DATA order but sit at the dragged block's
    /// PERMUTED display positions, so a data item may render in a different
    /// column than `i % C`. That breaks the round-robin assumption the marquee
    /// rect query relies on, which is why the preview cull path
    /// (``layoutAttributesForElements(in:)``) is a plain intersection scan.
    var preview: MasonryPreviewFrames?

    /// The SAME memo the SwiftUI grid uses — 036 §1 lists ``MasonryLayoutCache``
    /// among the framework-independent pieces to KEEP, so this pays its real cost,
    /// no more and no less.
    private let cache = MasonryLayoutCache()
    private var solved = MasonryFrames(
        frames: [], contentHeight: 0, columnWidth: 1, columns: 1)
    /// One attributes object per index, rebuilt in `prepare()` (036 §2 A1). The
    /// rect query returns SLICES of this array, so scrolling allocates nothing.
    private var attributesCache: [NSCollectionViewLayoutAttributes] = []
    /// The width the current `solved` was computed at — the ONLY thing a bounds
    /// change is allowed to compare against.
    private(set) var preparedWidth: CGFloat = 0

    /// The reorder preview to actually render — ``preview``, but only while it
    /// still matches the solved item count. A stale preview (left across an
    /// item-count change before the coordinator cleared it, 040 decision 10) is
    /// ignored, so the geometry accessors and the attributes cache can never be
    /// built from a mismatched frame array. `nil` in the steady state.
    private var activePreview: MasonryPreviewFrames? {
        guard let preview, preview.framesByDataIndex.count == solved.frames.count
        else { return nil }
        return preview
    }

    /// The frames currently DISPLAYED — the reorder preview when active, else the
    /// real solve. Every geometry accessor rides this so what is shown, what
    /// hit-tests, and what a drop commits stay one source (040 · WYSIWYG).
    private var displayedFrames: [CGRect] {
        activePreview?.framesByDataIndex ?? solved.frames
    }

    /// The analytic frame for an index — the geometry A2/A3 hover / marquee /
    /// selection rings must ride (the pixel-snap asterisk above). Reflects the
    /// reorder preview while one is active (040), so a selection ring tracks the
    /// cell to its previewed slot.
    func analyticFrame(at index: Int) -> CGRect? {
        let frames = displayedFrames
        guard index >= 0, index < frames.count else { return nil }
        return frames[index]
    }

    /// The solved column width, for callers deriving a thumbnail bucket before a
    /// frame exists. Unchanged by a preview — the column geometry is fixed; only
    /// which slot a cell occupies moves.
    var solvedColumnWidth: CGFloat { solved.columnWidth }

    /// The full analytic frame array (all items, offscreen included), for the A3
    /// marquee's `masonryMarqueeIndices` rect query — the virtualization trap is
    /// that only VISIBLE cells are materialized, so a live-frame scan can't drive
    /// offscreen hit-testing; these computed frames must (038 §3.4). Index-aligned
    /// to the data source's items. Reflects the reorder preview while one is
    /// active (the marquee is inactive mid-drag, but hover rings stay consistent).
    var solvedFrames: [CGRect] { displayedFrames }

    /// The solved column count at the current width — the ONE source A2 keyboard
    /// nav (`nextGridIndex`'s `± columns`) and the coordinator's arrow routing read,
    /// so the index math matches the frames (mirrors `CollectionView.gridColumns`).
    var solvedColumns: Int { max(1, solved.columns) }

    /// The item index at a content-space `point` (A2 mouse / hover hit-testing), via
    /// a zero-size ``masonryMarqueeIndices`` query over the ANALYTIC frames — never
    /// the pixel-snapped view frames (038 §3.4). `nil` in a gap between cells; the
    /// first hit wins (masonry cells never overlap, so there is at most one).
    func hitTestIndex(at point: CGPoint) -> Int? {
        if activePreview != nil {
            // Preview frames don't obey the round-robin column structure the
            // marquee query culls by, so hit-test with a plain scan (first hit
            // wins — masonry cells never overlap). Rarely exercised: the mouse
            // is captured by the drag session while a preview is up.
            return displayedFrames.firstIndex { $0.contains(point) }
        }
        return masonryMarqueeIndices(
            in: CGRect(origin: point, size: .zero),
            frames: solved.frames, columns: solved.columns).first
    }

    // MARK: Solving

    /// The width to lay out in: the CLIP view's width, not the collection view's
    /// own. The collection view's width is derived FROM `collectionViewContentSize`,
    /// so reading it here would be circular and would latch the first value.
    private func availableWidth() -> CGFloat {
        if let clipWidth = collectionView?.enclosingScrollView?.contentSize.width,
           clipWidth > 0 {
            return clipWidth
        }
        if let explicitWidth { return explicitWidth }
        return max(collectionView?.bounds.width ?? 0, 1)
    }

    override func prepare() {
        super.prepare()
        let width = max(availableWidth(), 1)
        let columns = density.columns(forWidth: width)
        solved = cache.frames(
            version: itemsVersion, width: width, columns: columns,
            spacing: spacing, topInset: topInset,
            aspects: { [aspects] in aspects })
        preparedWidth = width
        // The reorder preview (040) renders in place of the real solve when set;
        // `displayedFrames` picks it, guarded on a matching item count.
        attributesCache = displayedFrames.enumerated().map { index, frame in
            let attributes = NSCollectionViewLayoutAttributes(
                forItemWith: IndexPath(item: index, section: 0))
            // ZERO conversion — flipped content space is `MasonryLayout`'s space.
            attributes.frame = frame
            return attributes
        }
    }

    override var collectionViewContentSize: NSSize {
        let height = activePreview?.contentHeight ?? solved.contentHeight
        return NSSize(width: preparedWidth, height: max(height, 1))
    }

    // MARK: Queries

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        // While a reorder preview is active, a data item renders at its permuted
        // slot's column, breaking the round-robin structure `masonryMarqueeIndices`
        // culls by — so fall back to a plain intersection scan. It is O(N) like
        // the prepare() solve itself, and only runs during an active drag.
        if activePreview != nil {
            return attributesCache.filter { $0.frame.intersects(rect) }
        }
        // `masonryMarqueeIndices` (MarqueeMath.swift:77) IS this query: analytic
        // column membership culls whole columns in O(1), and the y-monotonic
        // stacking within a column makes the vertical span a binary search.
        let hits = masonryMarqueeIndices(
            in: rect, frames: solved.frames, columns: solved.columns)
        return hits.compactMap { index in
            index >= 0 && index < attributesCache.count ? attributesCache[index] : nil
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < attributesCache.count else { return nil }
        return attributesCache[indexPath.item]
    }

    /// WIDTH ONLY (036 §2 A1). Scrolling changes the bounds ORIGIN, never the
    /// width, so this answers `false` for every scroll tick and the masonry is
    /// never re-solved mid-scroll. Answering `true` here — the obvious mistake a
    /// naive `return true` or a full-rect comparison would make — is the
    /// "invalidation storm" of 036 §A-risks: it would re-run the O(N) solve on
    /// every frame.
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        abs(newBounds.width - preparedWidth) > 0.5
    }
}
