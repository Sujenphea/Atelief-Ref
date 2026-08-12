//
//  GridContextMenuTests.swift
//  AtelierRefsTests
//
//  036 §4 C4 — the two decisions the container-level context menu makes, both
//  pure and both otherwise only manually verifiable (a right-click cannot be
//  driven from a unit test):
//
//   • WHICH cell the cursor is over — the viewport→content point conversion that
//     keeps the capture scroll-invariant, and the zero-size-rect hit-test over
//     the ANALYTIC masonry frames (038 §6: never live cell frames).
//   • WHAT that cell's action scope is — the Finder rule (009 · 7A) that a
//     right-click inside the selection acts on the whole selection and outside
//     it acts on the one cell, leaving the selection untouched.
//
//  The hit-test's equivalence to the layout-agnostic `marqueeIndices` oracle is
//  already proven in `MasonryLayoutTests`; these tests cover what C4 adds on top.
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@Suite("Grid container context menu")
struct GridContextMenuTests {

    // A 3-column round-robin masonry over 7 items, built by the real layout so
    // the frames under test are the ones the grid actually draws (aspect-varied,
    // therefore fractional heights — the case 038 §6 is about).
    private static let columns = 3
    private static let aspects: [Double] = [1.0, 0.75, 1.5, 1.0, 0.6, 1.25, 0.9]

    private static var layout: MasonryFrames {
        MasonryLayout.layout(
            aspects: aspects, availableWidth: 320, columns: columns, spacing: 8, topInset: 4)
    }

    // MARK: - Viewport → content point

    @Test("a viewport point is offset by the live scroll position")
    func contentPointAddsOffset() {
        let point = gridCursorContentPoint(
            viewport: CGPoint(x: 30, y: 40), contentOffset: CGPoint(x: 0, y: 500))
        #expect(point == CGPoint(x: 30, y: 540))
    }

    @Test("at the top of the content the viewport point IS the content point")
    func contentPointAtOrigin() {
        let point = gridCursorContentPoint(
            viewport: CGPoint(x: 12, y: 7), contentOffset: .zero)
        #expect(point == CGPoint(x: 12, y: 7))
    }

    /// The reason the capture is viewport-relative at all: a scroll moves content
    /// under a stationary pointer WITHOUT a mouse-moved event, so the same stored
    /// capture must resolve to a different content point after scrolling.
    @Test("the same stored cursor resolves to a new content point after a scroll")
    func contentPointFollowsScroll() {
        let stored = CGPoint(x: 50, y: 50)
        let before = gridCursorContentPoint(viewport: stored, contentOffset: .zero)
        let after = gridCursorContentPoint(
            viewport: stored, contentOffset: CGPoint(x: 0, y: 300))
        #expect(before == CGPoint(x: 50, y: 50))
        #expect(after == CGPoint(x: 50, y: 350))
    }

    @Test("no pointer over the grid yields no content point")
    func contentPointNilPassesThrough() {
        #expect(gridCursorContentPoint(viewport: nil, contentOffset: CGPoint(x: 0, y: 90)) == nil)
    }

    // MARK: - Cursor point → target index

    @Test("a point inside a cell resolves to that cell's index")
    func hitsEachCell() {
        let layout = Self.layout
        for (index, frame) in layout.frames.enumerated() {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            #expect(
                masonryContextTargetIndex(
                    at: center, frames: layout.frames, columns: layout.columns) == index,
                "cell \(index) should be hit at its own centre")
        }
    }

    @Test("a point in the gutter between two columns resolves to nothing")
    func missesColumnGutter() {
        let layout = Self.layout
        // The spacing band between column 0's right edge and column 1's left.
        let a = layout.frames[0]
        let b = layout.frames[1]
        let gutterX = (a.maxX + b.minX) / 2
        #expect(gutterX > a.maxX && gutterX < b.minX)
        let point = CGPoint(x: gutterX, y: a.midY)
        #expect(
            masonryContextTargetIndex(
                at: point, frames: layout.frames, columns: layout.columns) == nil)
    }

    @Test("a point in the top inset above every cell resolves to nothing")
    func missesTopInset() {
        let layout = Self.layout
        let point = CGPoint(x: layout.frames[0].midX, y: 1)
        #expect(layout.frames[0].minY > 1)
        #expect(
            masonryContextTargetIndex(
                at: point, frames: layout.frames, columns: layout.columns) == nil)
    }

    @Test("a point past the bottom of the content resolves to nothing")
    func missesBelowContent() {
        let layout = Self.layout
        let point = CGPoint(x: layout.frames[0].midX, y: layout.contentHeight + 50)
        #expect(
            masonryContextTargetIndex(
                at: point, frames: layout.frames, columns: layout.columns) == nil)
    }

    @Test("an absent cursor resolves to nothing (the keyboard-invoked case)")
    func nilPointHitsNothing() {
        let layout = Self.layout
        #expect(
            masonryContextTargetIndex(
                at: nil, frames: layout.frames, columns: layout.columns) == nil)
    }

    @Test("an empty grid resolves to nothing")
    func emptyFramesHitNothing() {
        #expect(masonryContextTargetIndex(at: .zero, frames: [], columns: 3) == nil)
    }

    /// Frames only share an edge at zero spacing; when they do, the tie-break is
    /// the later index — the one the window's `ForEach` draws on top.
    @Test("a point on a shared edge targets the cell drawn on top")
    func tieBreaksToTheTopmostCell() {
        // One column, zero spacing: cell 0 is [0, 100), cell 1 is [100, 200).
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 0, y: 100, width: 100, height: 100),
        ]
        let onTheSeam = CGPoint(x: 50, y: 100)
        // Both cells are hit (the zero-size query is edge-inclusive)…
        #expect(
            masonryMarqueeIndices(
                in: CGRect(origin: onTheSeam, size: .zero), frames: frames, columns: 1) == [0, 1])
        // …and the resolution picks the later one.
        #expect(masonryContextTargetIndex(at: onTheSeam, frames: frames, columns: 1) == 1)
    }

    /// The hit-test must agree with the marquee's own oracle everywhere, since a
    /// disagreement would mean the menu and a click-marquee name different cells.
    @Test("the target always matches the layout-agnostic marquee core")
    func agreesWithTheMarqueeCore() {
        let layout = Self.layout
        for y in stride(from: CGFloat(0), through: layout.contentHeight, by: 7) {
            for x in stride(from: CGFloat(0), through: 320, by: 11) {
                let point = CGPoint(x: x, y: y)
                let expected = marqueeIndices(
                    in: CGRect(origin: point, size: .zero), frames: layout.frames).last
                let actual = masonryContextTargetIndex(
                    at: point, frames: layout.frames, columns: layout.columns)
                #expect(actual == expected, "disagreement at \(point)")
            }
        }
    }

    // MARK: - Action scope (selection vs single item)

    private static let assetA = UUID()
    private static let assetB = UUID()
    private static let assetC = UUID()

    @Test("a right-click INSIDE the selection acts on the whole selection")
    func selectedCellTargetsTheSelection() {
        let targets = gridActionTargets(
            isSelected: true,
            selectedAssetIDs: [Self.assetA, Self.assetB, Self.assetC],
            cellAssetIDs: [Self.assetB])
        #expect(targets == [Self.assetA, Self.assetB, Self.assetC])
    }

    @Test("a right-click OUTSIDE the selection acts on that one cell only")
    func unselectedCellTargetsItself() {
        let targets = gridActionTargets(
            isSelected: false,
            selectedAssetIDs: [Self.assetA, Self.assetB],
            cellAssetIDs: [Self.assetC])
        #expect(targets == [Self.assetC])
    }

    /// The scope rule reads the selection but never writes it — the returned
    /// targets are the ONLY output, so nothing here can select the clicked cell.
    /// (The behavioural half of that promise lives in `CollectionView`, which
    /// applies no selection action on right-click.)
    @Test("an idle grid with no selection targets just the clicked cell")
    func idleGridTargetsTheCell() {
        let targets = gridActionTargets(
            isSelected: false, selectedAssetIDs: [], cellAssetIDs: [Self.assetA])
        #expect(targets == [Self.assetA])
    }

    @Test("a vanished cell yields no targets, and therefore no menu")
    func missingCellYieldsNoTargets() {
        #expect(
            gridActionTargets(
                isSelected: false, selectedAssetIDs: [Self.assetA], cellAssetIDs: []).isEmpty)
    }

    /// Order matters: the destructive verbs are labelled with the target COUNT,
    /// and the selection is kept in feed order by the model's cache.
    @Test("the selection's feed order is preserved in the targets")
    func selectionOrderPreserved() {
        let ordered = [Self.assetC, Self.assetA, Self.assetB]
        #expect(
            gridActionTargets(
                isSelected: true, selectedAssetIDs: ordered, cellAssetIDs: [Self.assetA]) == ordered)
    }

    // MARK: - The out-flow group (011 · A2/A3)

    @Test("a surface that binds NEITHER verb gets no rows — and no stray separator")
    func neitherVerbYieldsNothing() {
        // The shelf's case. Its menu is three verbs on purpose (022 · D5 / 023 · A2),
        // and the likeliest bug here is a divider appearing above them with nothing
        // underneath it.
        #expect(outFlowMenuRows(canShare: false, canExport: false, targetCount: 1) == [])
        #expect(outFlowMenuRows(canShare: false, canExport: false, targetCount: 12) == [])
    }

    @Test("both verbs come as a group behind one separator, share first")
    func bothVerbsOrdered() {
        #expect(outFlowMenuRows(canShare: true, canExport: true, targetCount: 1)
            == [.separator, .share, .exportAssets(title: "Export Assets…")])
    }

    @Test("either verb alone still opens the group with its separator")
    func eitherVerbAloneKeepsTheSeparator() {
        #expect(outFlowMenuRows(canShare: true, canExport: false, targetCount: 1)
            == [.separator, .share])
        #expect(outFlowMenuRows(canShare: false, canExport: true, targetCount: 1)
            == [.separator, .exportAssets(title: "Export Assets…")])
    }

    @Test("the export title counts multiple targets and stays bare for one")
    func exportTitleCountsTargets() {
        func title(_ count: Int) -> String? {
            outFlowMenuRows(canShare: false, canExport: true, targetCount: count)
                .compactMap { if case .exportAssets(let t) = $0 { return t } else { return nil } }
                .first
        }
        #expect(title(1) == "Export Assets…")
        #expect(title(2) == "Export Assets (2)…")
        #expect(title(40) == "Export Assets (40)…")
        // Matches `countSuffix`: no "(1)", and the ellipsis stays last because the
        // verb opens a save dialog.
        #expect(title(0) == "Export Assets…")
    }

    @Test("share is present exactly when the payload resolved to something")
    func sharePresenceFollowsThePayload() {
        // `canShare` folds together "the surface binds it" and "the targets yielded
        // a shareable payload" — a selection of nothing but media-less refs with no
        // text produces no item, so no row.
        #expect(outFlowMenuRows(canShare: false, canExport: true, targetCount: 3)
            .contains(.share) == false)
        #expect(outFlowMenuRows(canShare: true, canExport: true, targetCount: 3)
            .contains(.share))
    }
}
