//
//  MasonryCollectionLayoutTests.swift
//  AtelierRefsTests
//
//  036 §2 A1 — the production `NSCollectionViewLayout` (`MasonryCollectionLayout`),
//  the two load-bearing claims 038 §3.4 validated on the spike, re-asserted on the
//  shipping layout:
//
//   1. **Flipped 1:1 mapping.** The layout attributes carry the exact
//      `MasonryLayout` frames (byte-for-byte — the sub-pixel asterisk is about the
//      snapped VIEW frames, not these attributes), and the rect query returns
//      EXACTLY the layout-agnostic `marqueeIndices` oracle over the same rect, so
//      `layoutAttributesForElements(in:)` can never drift from the geometry the
//      marquee / keyboard nav / hit-testing see.
//   2. **Width-only invalidation.** A scroll (moving the bounds ORIGIN) never
//      invalidates — the property that keeps it smooth (036 §A-risks'
//      "invalidation storm"); a width change does.
//
//  Pure/headless: driven through the `explicitWidth` test seam, no live window.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - Fixtures

/// Deliberately UNEVEN aspects: equal aspects make every column identical and a
/// coordinate bug could hide behind the symmetry.
private func testAspects(_ count: Int) -> [Double] {
    (0..<count).map { [0.5, 1.0, 1.5, 0.75, 2.0, 1.25][$0 % 6] }
}

@MainActor
private func makeLayout(
    itemCount: Int = 400, width: CGFloat = 800, columns: Int = 4,
    spacing: CGFloat = 8, topInset: CGFloat = 4
) -> (MasonryCollectionLayout, MasonryFrames) {
    let layout = MasonryCollectionLayout()
    let aspects = testAspects(itemCount)
    layout.aspects = aspects
    layout.density = GridDensity(columns: columns)
    layout.spacing = spacing
    layout.topInset = topInset
    layout.explicitWidth = width
    layout.prepare()

    // The ORACLE: the production math, computed independently here.
    let expected = MasonryLayout.layout(
        aspects: aspects, availableWidth: width,
        columns: GridDensity(columns: columns).columns(forWidth: width),
        spacing: spacing, topInset: topInset)
    return (layout, expected)
}

// MARK: - Claim 1 · frames map 1:1

@MainActor
@Suite("MasonryCollectionLayout: frames map 1:1")
struct MasonryCollectionLayoutMappingTests {

    @Test("every item's attributes carry the exact MasonryLayout frame")
    func attributesMatchAnalyticFrames() {
        let (layout, expected) = makeLayout()
        for index in 0..<expected.frames.count {
            let attributes = layout.layoutAttributesForItem(
                at: IndexPath(item: index, section: 0))
            #expect(attributes?.frame == expected.frames[index])
        }
    }

    @Test("analyticFrame(at:) exposes the same frames for A2/A3 hit-testing")
    func analyticFrameMatches() {
        let (layout, expected) = makeLayout()
        for index in 0..<expected.frames.count {
            #expect(layout.analyticFrame(at: index) == expected.frames[index])
        }
        // Out of range is nil, never a crash.
        #expect(layout.analyticFrame(at: -1) == nil)
        #expect(layout.analyticFrame(at: expected.frames.count) == nil)
    }

    @Test("content size is the analytic content height at the solved width")
    func contentSizeMatches() {
        let (layout, expected) = makeLayout()
        #expect(layout.collectionViewContentSize.height == expected.contentHeight)
        #expect(layout.collectionViewContentSize.width == 800)
    }

    @Test("rect query returns exactly the layout-agnostic marquee oracle")
    func rectQueryMatchesOracle() {
        let (layout, expected) = makeLayout()
        var rects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 800, height: 600),
            CGRect(x: 0, y: expected.contentHeight - 600, width: 800, height: 600),
            CGRect(x: 0, y: 0, width: 800, height: 0),   // a zero-height (click-like) rect
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
            for attribute in attributes {
                guard let index = attribute.indexPath?.item else { continue }
                #expect(attribute.frame == expected.frames[index])
            }
        }
    }

    @Test("the rect query returns cached attribute instances, not fresh allocations")
    func attributesAreCached() {
        let (layout, _) = makeLayout()
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let first = layout.layoutAttributesForElements(in: rect)
        let second = layout.layoutAttributesForElements(in: rect)
        #expect(!first.isEmpty)
        #expect(first.count == second.count)
        // Same identity across queries — the per-index cache built in prepare().
        for (a, b) in zip(first, second) { #expect(a === b) }
    }
}

// MARK: - Claim 2 · width-only invalidation

@MainActor
@Suite("MasonryCollectionLayout: only WIDTH invalidates")
struct MasonryCollectionLayoutInvalidationTests {

    @Test("a scroll — same width, moving origin — never invalidates")
    func scrollDoesNotInvalidate() {
        let (layout, expected) = makeLayout()
        var y: CGFloat = 0
        var asked = 0
        while y < expected.contentHeight {
            let bounds = NSRect(x: 0, y: y, width: 800, height: 600)
            #expect(layout.shouldInvalidateLayout(forBoundsChange: bounds) == false)
            asked += 1
            y += 37   // fine-grained, like real scroll ticks
        }
        #expect(asked > 100)
    }

    @Test("a width change does invalidate")
    func widthChangeInvalidates() {
        let (layout, _) = makeLayout()
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 900, height: 600)) == true)
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 700, height: 600)) == true)
    }

    @Test("a height-only change does not invalidate")
    func heightChangeDoesNotInvalidate() {
        let (layout, _) = makeLayout()
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 800, height: 2000)) == false)
    }

    @Test("a sub-half-point width wobble does not invalidate")
    func subPixelWidthWobbleIgnored() {
        let (layout, _) = makeLayout()
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 800.4, height: 600)) == false)
    }

    @Test("re-solving at a new width tracks that width")
    func reprepareAtNewWidth() {
        let (layout, _) = makeLayout()
        #expect(layout.preparedWidth == 800)
        layout.explicitWidth = 1000
        layout.prepare()
        #expect(layout.preparedWidth == 1000)
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 1000, height: 600)) == false)
    }
}

// MARK: - 040 · the reorder preview overrides the render

@MainActor
@Suite("MasonryCollectionLayout: reorder preview")
struct MasonryCollectionLayoutPreviewTests {

    /// A preview built by the SAME pure functions the coordinator will use, at
    /// the layout's own solved width/columns — so the preview geometry is exactly
    /// what a real drag would produce. Moves data item 0 to the given slot.
    @MainActor
    private func previewMovingFirstItem(
        in layout: MasonryCollectionLayout, toSlot slot: Int
    ) -> MasonryPreviewFrames {
        let order = previewDisplayOrder(
            count: layout.aspects.count, blockIndices: [0], slot: slot)
        return previewFrames(
            displayOrder: order, aspects: layout.aspects,
            availableWidth: layout.preparedWidth, columns: layout.solvedColumns,
            spacing: layout.spacing, topInset: layout.topInset)
    }

    @Test("an active preview drives attributes, analytic frames and content size")
    func previewDrivesGeometry() {
        let (layout, _) = makeLayout(itemCount: 6, width: 400, columns: 2)
        let preview = previewMovingFirstItem(in: layout, toSlot: 5)   // to the end
        layout.preview = preview
        layout.prepare()

        for index in 0..<6 {
            #expect(layout.analyticFrame(at: index) == preview.framesByDataIndex[index])
            #expect(layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame
                    == preview.framesByDataIndex[index])
        }
        #expect(layout.solvedFrames == preview.framesByDataIndex)
        #expect(layout.collectionViewContentSize.height == preview.contentHeight)
        // The column geometry (width) is unchanged by the preview.
        #expect(layout.collectionViewContentSize.width == layout.preparedWidth)
    }

    @Test("the rect query culls by PREVIEW position, not the real solve")
    func rectQueryCullsByPreview() {
        let (layout, _) = makeLayout(itemCount: 6, width: 400, columns: 2)
        let preview = previewMovingFirstItem(in: layout, toSlot: 5)
        layout.preview = preview
        layout.prepare()

        // Each cell is found by a rect at its OWN preview frame. For the moved
        // item 0 (now at the end) this is the discriminator: a solved-order cull
        // would return whatever sat at that slot originally, never index 0.
        for index in 0..<6 {
            let hits = layout.layoutAttributesForElements(in: preview.framesByDataIndex[index])
                .compactMap(\.indexPath?.item)
            #expect(hits.contains(index), "cell \(index) not found at its preview frame")
        }
        // The full content rect returns every cell exactly once, each carrying
        // its preview frame.
        let full = CGRect(
            x: 0, y: 0, width: layout.collectionViewContentSize.width,
            height: layout.collectionViewContentSize.height)
        let attributes = layout.layoutAttributesForElements(in: full)
        #expect(Set(attributes.compactMap(\.indexPath?.item)) == Set(0..<6))
        for attribute in attributes {
            guard let index = attribute.indexPath?.item else { continue }
            #expect(attribute.frame == preview.framesByDataIndex[index])
        }
    }

    @Test("hitTestIndex reflects the preview arrangement")
    func hitTestReflectsPreview() {
        let (layout, _) = makeLayout(itemCount: 6, width: 400, columns: 2)
        let preview = previewMovingFirstItem(in: layout, toSlot: 5)
        layout.preview = preview
        layout.prepare()
        // The center of item 0's PREVIEW frame hit-tests to item 0.
        let center = CGPoint(
            x: preview.framesByDataIndex[0].midX, y: preview.framesByDataIndex[0].midY)
        #expect(layout.hitTestIndex(at: center) == 0)
    }

    @Test("clearing the preview restores the real solved frames")
    func clearingRestoresSolve() {
        let (layout, expected) = makeLayout(itemCount: 6, width: 400, columns: 2)
        layout.preview = previewMovingFirstItem(in: layout, toSlot: 5)
        layout.prepare()
        #expect(layout.solvedFrames != expected.frames)   // preview diverged

        layout.preview = nil
        layout.prepare()
        #expect(layout.solvedFrames == expected.frames)
        #expect(layout.collectionViewContentSize.height == expected.contentHeight)
        for index in 0..<6 {
            #expect(layout.analyticFrame(at: index) == expected.frames[index])
        }
    }

    @Test("an identity-order preview is indistinguishable from the plain solve")
    func identityPreviewMatchesSolve() {
        let (layout, expected) = makeLayout(itemCount: 6, width: 400, columns: 2)
        let identity = previewFrames(
            displayOrder: Array(0..<6), aspects: layout.aspects,
            availableWidth: layout.preparedWidth, columns: layout.solvedColumns,
            spacing: layout.spacing, topInset: layout.topInset)
        layout.preview = identity
        layout.prepare()
        #expect(layout.solvedFrames == expected.frames)
        #expect(layout.collectionViewContentSize.height == expected.contentHeight)
    }

    @Test("a preview whose item count disagrees with the solve is IGNORED")
    func mismatchedCountPreviewIgnored() {
        let (layout, expected) = makeLayout(itemCount: 6, width: 400, columns: 2)
        // A stale 4-item preview (e.g. left across a reload) must not be rendered
        // — the guard falls back to the real solve rather than building a
        // mismatched attributes cache.
        layout.preview = MasonryPreviewFrames(
            framesByDataIndex: Array(repeating: .zero, count: 4), contentHeight: 999)
        layout.prepare()
        #expect(layout.solvedFrames == expected.frames)
        #expect(layout.collectionViewContentSize.height == expected.contentHeight)
        #expect(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame
                == expected.frames[0])
    }

    @Test("width-only invalidation is unchanged while a preview is active")
    func invalidationUnchangedUnderPreview() {
        let (layout, _) = makeLayout(itemCount: 6, width: 400, columns: 2)
        layout.preview = previewMovingFirstItem(in: layout, toSlot: 5)
        layout.prepare()
        // A scroll (origin move, same width) still never invalidates.
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 300, width: 400, height: 600)) == false)
        // A width change still does.
        #expect(layout.shouldInvalidateLayout(
            forBoundsChange: NSRect(x: 0, y: 0, width: 500, height: 600)) == true)
    }
}
