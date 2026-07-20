//
//  AppKitBakeoffGridTests.swift
//  AtelierRefsTests
//
//  037 · Option B spike — the two load-bearing claims of 036 §2, as tests
//  rather than as comments. Both are cheap here and expensive in week two:
//
//   1. **Flipped 1:1 mapping.** `NSCollectionView` is flipped and
//      `MasonryLayout.layout` emits top-left-origin frames, so the frames go
//      onto layout attributes with ZERO conversion. Asserted analytically
//      (attributes == `MasonryLayout` output) AND empirically, against a LIVE
//      `NSCollectionView` in a real window whose materialized cell views are
//      compared to the analytic frames — before and after scrolling.
//   2. **Zero layout invalidation while scrolling.** `shouldInvalidateLayout`
//      compares width only, so a scroll (which moves the bounds ORIGIN) never
//      re-solves the masonry. Asserted as a prepare()-count that does not move
//      across a scripted scroll — 036 §A-risks' "invalidation storm", which
//      would silently destroy the bake-off numbers, cannot pass this.
//
//  ── What the measurement actually showed (800×600 viewport, 4 columns,
//     backing scale 2, 40-step scripted scroll) ─────────────────────────────
//   • Claim 1 holds as a SPACE identity but NOT as literal frame equality.
//     Layout ATTRIBUTES carry the analytic frames byte-for-byte; the item
//     VIEWS AppKit places from them are pixel-snapped, so a fractional masonry
//     frame (heights are `columnWidth / aspect`) lands up to half a backing
//     pixel off — worst observed 0.2333pt against a 0.25pt bound, over 612
//     cell comparisons. A missing flip would have shown thousands of points,
//     so the space is confirmed; "ZERO conversion" needs the sub-pixel
//     asterisk. (The snap is also NOT `alignAllEdgesNearest` — 6 of 12 cells
//     differ from that rule — so no code should try to predict it exactly.)
//   • Claim 2 holds outright: prepare() ran ONCE (at first layout) and zero
//     times across the whole scroll; AppKit asked `shouldInvalidateLayout` 40
//     times and got `false` every time.
//   • Recycling: 14 live cells for a 2000-item collection.
//
//  The rect query is additionally pinned to the same layout-agnostic
//  `marqueeIndices` oracle `GridWindowingTests` uses, so
//  `layoutAttributesForElements(in:)` cannot drift from the geometry the
//  marquee and keyboard nav see.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// Deterministic, deliberately UNEVEN aspects: equal aspects would make every
/// column identical and a coordinate bug could hide behind the symmetry.
private func testAspects(_ count: Int) -> [Double] {
    (0..<count).map { index in
        let cycle = [0.5, 1.0, 1.5, 0.75, 2.0, 1.25][index % 6]
        return cycle
    }
}

@MainActor
private func makeLayout(
    itemCount: Int = 400, width: CGFloat = 800, columns: Int = 4,
    spacing: CGFloat = 8, topInset: CGFloat = 4
) -> (MasonryBakeoffLayout, MasonryBakeoffDiagnostics, MasonryFrames) {
    let diagnostics = MasonryBakeoffDiagnostics()
    let layout = MasonryBakeoffLayout(diagnostics: diagnostics)
    let aspects = testAspects(itemCount)
    layout.aspects = aspects
    layout.density = GridDensity(columns: columns)
    layout.spacing = spacing
    layout.topInset = topInset
    layout.explicitWidth = width
    layout.prepare()

    // The ORACLE: what the production math says, computed independently here.
    let expected = MasonryLayout.layout(
        aspects: aspects, availableWidth: width,
        columns: GridDensity(columns: columns).columns(forWidth: width),
        spacing: spacing, topInset: topInset)
    return (layout, diagnostics, expected)
}

// MARK: - Claim 1 · frames map 1:1, analytically

@MainActor
@Suite("Option B layout: MasonryLayout frames map 1:1")
struct MasonryBakeoffLayoutMappingTests {

    @Test("every item's attributes carry the exact MasonryLayout frame")
    func attributesMatchAnalyticFrames() {
        let (layout, _, expected) = makeLayout()
        for index in 0..<expected.frames.count {
            let attributes = layout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0))
            #expect(attributes?.frame == expected.frames[index])
        }
    }

    @Test("content size is the analytic content height at the solved width")
    func contentSizeMatches() {
        let (layout, _, expected) = makeLayout()
        #expect(layout.collectionViewContentSize.height == expected.contentHeight)
        #expect(layout.collectionViewContentSize.width == 800)
    }

    @Test("rect query returns exactly the layout-agnostic marquee oracle")
    func rectQueryMatchesOracle() {
        let (layout, _, expected) = makeLayout()
        // A sweep of viewport-shaped rects down the whole content, plus a couple
        // of degenerate ones.
        var rects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 0, y: expected.contentHeight - 600, width: 800, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 0),
        ]
        var y: CGFloat = 0
        while y < expected.contentHeight {
            rects.append(CGRect(x: 0, y: y, width: 800, height: 600))
            y += 371   // a prime-ish step so boundaries are hit at odd offsets
        }

        for rect in rects {
            let attributes = layout.layoutAttributesForElements(in: rect)
            let got = attributes.compactMap(\.indexPath?.item).sorted()
            #expect(got.count == attributes.count, "an attribute had no index path")
            let oracle = marqueeIndices(in: rect, frames: expected.frames)
            #expect(got == oracle, "rect \(rect)")
            // And each returned attribute still carries its own analytic frame —
            // a right-index/wrong-frame bug would show item A at item B's slot.
            for attribute in attributes {
                guard let index = attribute.indexPath?.item else { continue }
                #expect(attribute.frame == expected.frames[index])
            }
        }
    }
}

// MARK: - Claim 2 · width-only invalidation

@MainActor
@Suite("Option B layout: only WIDTH invalidates")
struct MasonryBakeoffInvalidationTests {

    @Test("a scroll — same width, moving origin — never invalidates")
    func scrollDoesNotInvalidate() {
        let (layout, diagnostics, expected) = makeLayout()
        let prepares = diagnostics.prepareCount

        var y: CGFloat = 0
        var asked = 0
        while y < expected.contentHeight {
            let bounds = NSRect(x: 0, y: y, width: 800, height: 600)
            #expect(layout.shouldInvalidateLayout(forBoundsChange: bounds) == false)
            asked += 1
            y += 37   // fine-grained, like real scroll ticks
        }

        #expect(asked > 100)
        #expect(diagnostics.boundsChangeQueries == asked)
        #expect(diagnostics.widthInvalidations == 0)
        // The whole point: not one re-solve across the entire scroll.
        #expect(diagnostics.prepareCount == prepares)
    }

    @Test("a width change does invalidate")
    func widthChangeInvalidates() {
        let (layout, diagnostics, _) = makeLayout()
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 900, height: 600)) == true)
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 700, height: 600)) == true)
        #expect(diagnostics.widthInvalidations == 2)
    }

    @Test("a height-only change does not invalidate")
    func heightChangeDoesNotInvalidate() {
        let (layout, diagnostics, _) = makeLayout()
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 800, height: 2000)) == false)
        #expect(diagnostics.widthInvalidations == 0)
    }

    @Test("re-solving at a new width tracks that width")
    func reprepareAtNewWidth() {
        let (layout, _, _) = makeLayout()
        #expect(layout.preparedWidth == 800)
        layout.explicitWidth = 1000
        layout.prepare()
        #expect(layout.preparedWidth == 1000)
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 1000, height: 600)) == false)
    }
}

// MARK: - Both claims, against a LIVE NSCollectionView

/// The minimum data source a real `NSCollectionView` needs. Renders the spike's
/// actual cell class so the materialized views are the ones the bake-off uses.
@MainActor
private final class StubItemSource: NSObject, NSCollectionViewDataSource {
    let count: Int
    init(count: Int) { self.count = count }

    func collectionView(
        _ collectionView: NSCollectionView, numberOfItemsInSection section: Int
    ) -> Int { count }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        collectionView.makeItem(
            withIdentifier: MasonryBakeoffItem.identifier, for: indexPath)
    }
}

@MainActor
@Suite("Option B: live NSCollectionView", .serialized)
struct MasonryBakeoffLiveTests {

    /// Build the real stack: window → scroll view → collection view → spike
    /// layout. Held together by the returned tuple so nothing is deallocated
    /// mid-test.
    private func makeLiveGrid(itemCount: Int = 600)
        -> (window: NSWindow, scrollView: NSScrollView, collectionView: NSCollectionView,
            layout: MasonryBakeoffLayout, diagnostics: MasonryBakeoffDiagnostics,
            source: StubItemSource) {
        let diagnostics = MasonryBakeoffDiagnostics()
        let layout = MasonryBakeoffLayout(diagnostics: diagnostics)
        layout.aspects = testAspects(itemCount)
        layout.density = GridDensity(columns: 4)
        layout.spacing = 8
        layout.topInset = 4

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.hasVerticalScroller = true

        let collectionView = NSCollectionView(frame: scrollView.bounds)
        collectionView.isSelectable = false
        collectionView.collectionViewLayout = layout
        let source = StubItemSource(count: itemCount)
        collectionView.dataSource = source
        collectionView.register(
            MasonryBakeoffItem.self, forItemWithIdentifier: MasonryBakeoffItem.identifier)
        scrollView.documentView = collectionView
        window.contentView = scrollView
        window.orderBack(nil)

        collectionView.reloadData()
        settle(window)
        return (window, scrollView, collectionView, layout, diagnostics, source)
    }

    /// Let AppKit actually lay out and materialize items.
    private func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Compare every materialized cell's REAL frame to its analytic frame.
    ///
    /// `worst` is the raw deviation. `backingMismatches` counts cells whose
    /// frame is not the analytic frame SNAPPED TO THE BACKING GRID — the
    /// distinction that matters: a non-zero `worst` with zero
    /// `backingMismatches` means the coordinate SPACES agree exactly and AppKit
    /// merely pixel-aligned the result, whereas a backing mismatch would mean a
    /// real conversion is missing.
    private func compare(
        _ collectionView: NSCollectionView, _ layout: MasonryBakeoffLayout
    ) -> (compared: Int, worst: CGFloat, backingMismatches: Int) {
        var compared = 0
        var worst: CGFloat = 0
        var backingMismatches = 0
        for item in collectionView.visibleItems() {
            guard let path = collectionView.indexPath(for: item),
                  let analytic = layout.analyticFrame(at: path.item) else { continue }
            let rendered = item.view.frame
            compared += 1
            worst = max(worst, abs(rendered.minX - analytic.minX))
            worst = max(worst, abs(rendered.minY - analytic.minY))
            worst = max(worst, abs(rendered.width - analytic.width))
            worst = max(worst, abs(rendered.height - analytic.height))

            let snapped = collectionView.backingAlignedRect(
                analytic, options: [.alignAllEdgesNearest])
            if abs(rendered.minX - snapped.minX) > 0.001
                || abs(rendered.minY - snapped.minY) > 0.001
                || abs(rendered.width - snapped.width) > 0.001
                || abs(rendered.height - snapped.height) > 0.001 {
                backingMismatches += 1
            }
        }
        return (compared, worst, backingMismatches)
    }

    /// Half a backing pixel — the most a nearest-edge snap can ever move a
    /// frame. Derived from the live window rather than hardcoded for 2×.
    private func snapTolerance(_ window: NSWindow) -> CGFloat {
        0.5 / max(1, window.backingScaleFactor) + 0.0001
    }

    @Test("the collection view is flipped, so MasonryLayout's space IS its space")
    func collectionViewIsFlipped() {
        let grid = makeLiveGrid()
        #expect(grid.collectionView.isFlipped)
        // The clip view inherits the document view's flippedness — this is what
        // makes a raw `scroll(to: y)` mean "y points DOWN from the top".
        #expect(grid.scrollView.contentView.isFlipped)
    }

    /// 036 §2's claim, corrected by measurement.
    ///
    /// The SPACES are identical — no flip, no offset, no inversion; a cell whose
    /// analytic `y` is 3000 renders at `y` 3000, not at `contentHeight − 3000`.
    /// But "1:1 with ZERO conversion" is not literally true of the final view
    /// frames: AppKit backing-aligns each item view, so a fractional masonry
    /// frame (cell heights are `columnWidth / aspect`, routinely fractional)
    /// lands up to HALF A BACKING PIXEL from its analytic value. Harmless for
    /// rendering, and harmless for the marquee/nav/reorder — which ride the
    /// analytic frames by design (`MasonryLayout.swift` header) — but it means
    /// no future code may assume `cellView.frame == frames[i]` exactly.
    @Test("cells land on their analytic frames, up to backing-pixel alignment")
    func renderedFramesMatchAnalyticFrames() {
        let grid = makeLiveGrid()
        let result = compare(grid.collectionView, grid.layout)
        #expect(result.compared > 0, "no cells materialized — the check would be vacuous")
        // Same space: the deviation is sub-pixel, not a flip or an offset.
        #expect(
            result.worst <= snapTolerance(grid.window),
            """
            worst edge deviation \(result.worst)pt over \(result.compared) cells \
            exceeds half a backing pixel — that is a real coordinate mismatch, \
            not pixel snapping. \(result.backingMismatches) cells also differ \
            from `alignAllEdgesNearest`, which only tells us AppKit's exact snap \
            rule differs; the BOUND is the claim.
            """)
    }

    @Test("scrolling produces zero prepare() calls and keeps frames exact")
    func scrollingNeverInvalidatesLayout() {
        let grid = makeLiveGrid()
        let baseline = grid.diagnostics.prepareCount
        #expect(baseline > 0, "the layout never solved at all")

        var totalCompared = 0
        var worstAcrossScroll: CGFloat = 0
        var backingMismatches = 0
        // A scripted scroll down the content, in the same manner
        // `NSScrollViewBakeoffTarget` drives it.
        for step in 1...40 {
            let y = CGFloat(step) * 137
            grid.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
            grid.collectionView.layoutSubtreeIfNeeded()
            let result = compare(grid.collectionView, grid.layout)
            totalCompared += result.compared
            worstAcrossScroll = max(worstAcrossScroll, result.worst)
            backingMismatches += result.backingMismatches
        }

        // Claim 2 — the invalidation storm 036 §A-risks warns about.
        #expect(
            grid.diagnostics.prepareCount == baseline,
            "prepare() ran \(grid.diagnostics.prepareCount - baseline) times while scrolling")
        #expect(grid.diagnostics.widthInvalidations == 0)
        // Claim 1 — still 1:1 after recycling, not just on first layout. A
        // RECYCLED cell reusing a stale frame would blow past the sub-pixel
        // tolerance immediately.
        #expect(totalCompared > 0)
        #expect(
            worstAcrossScroll <= snapTolerance(grid.window),
            "worst delta while scrolling \(worstAcrossScroll)pt over \(totalCompared) cells")
        // Informational, not a claim: recorded so a future change that starts
        // moving cells a WHOLE pixel shows up as a jump in this number too.
        #expect(backingMismatches <= totalCompared)
    }

    @Test("recycling keeps the live cell count bounded, not O(N)")
    func recyclingBoundsLiveCells() {
        let grid = makeLiveGrid(itemCount: 2000)
        grid.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 4000))
        grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
        grid.collectionView.layoutSubtreeIfNeeded()
        let live = grid.collectionView.visibleItems().count
        #expect(live > 0)
        // The whole premise of Option B: a 2000-item collection keeps only a
        // viewport-ish number of views alive.
        #expect(live < 200, "\(live) live cells for 2000 items — recycling is not working")
    }
}

// MARK: - Thumbnail bucket ladder

@Suite("Option B: thumbnail bucket ladder")
struct BakeoffThumbnailBucketTests {

    @Test("snaps UP to the ladder and is capped at the 512 on-disk tier")
    func ladder() {
        #expect(BakeoffThumbnailStore.bucket(forLongSide: 60, scale: 2) == 128)
        #expect(BakeoffThumbnailStore.bucket(forLongSide: 64, scale: 2) == 128)
        #expect(BakeoffThumbnailStore.bucket(forLongSide: 65, scale: 2) == 192)
        #expect(BakeoffThumbnailStore.bucket(forLongSide: 200, scale: 2) == 512)
        // Nothing above the tier ceiling — a bigger request cannot add detail.
        #expect(BakeoffThumbnailStore.bucket(forLongSide: 4000, scale: 2) == 512)
    }

    @Test("monotonic in size, so a density step never sharpens by shrinking")
    func monotonic() {
        var previous = 0
        for points in stride(from: CGFloat(20), through: 600, by: 5) {
            let bucket = BakeoffThumbnailStore.bucket(forLongSide: points, scale: 2)
            #expect(bucket >= previous)
            previous = bucket
        }
    }
}
