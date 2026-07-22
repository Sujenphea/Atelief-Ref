//
//  MasonryReorderPreviewTests.swift
//  AtelierRefsTests
//
//  040 §1 — the pure math under the live reorder drop preview. The preview IS
//  the commit contract (WYSIWYG), so the permutation, the frame mapping and the
//  slot hit-testing are covered exhaustively: a wrong slot here would silently
//  persist a different order than the one shown on screen.
//

import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

// MARK: - previewDisplayOrder

@Suite("Reorder preview: display order")
struct PreviewDisplayOrderTests {

    @Test("the block occupies slots s..s+count-1; remaining keep feed order")
    func blockAtSlot() {
        #expect(previewDisplayOrder(count: 6, blockIndices: [0], slot: 2)
                == [1, 2, 0, 3, 4, 5])
    }

    @Test("slot 0 puts the block first")
    func slotZero() {
        #expect(previewDisplayOrder(count: 6, blockIndices: [5], slot: 0)
                == [5, 0, 1, 2, 3, 4])
    }

    @Test("the end slot (remaining.count) puts the block last")
    func endSlot() {
        #expect(previewDisplayOrder(count: 6, blockIndices: [0], slot: 5)
                == [1, 2, 3, 4, 5, 0])
    }

    @Test("a non-contiguous, unsorted block is gathered in FEED order")
    func nonContiguousBlock() {
        #expect(previewDisplayOrder(count: 5, blockIndices: [3, 1], slot: 1)
                == [0, 1, 3, 2, 4])
    }

    @Test("an empty block yields the identity")
    func emptyBlockIsIdentity() {
        #expect(previewDisplayOrder(count: 4, blockIndices: [], slot: 2)
                == [0, 1, 2, 3])
    }

    @Test("the slot clamps at both ends", arguments: [
        (-3, [0, 1, 2, 3]),    // below → 0 (block [0] at front = identity)
        (99, [1, 2, 3, 0]),    // beyond → remaining.count (block last)
    ] as [(Int, [Int])])
    func slotClamps(_ slot: Int, _ expected: [Int]) {
        #expect(previewDisplayOrder(count: 4, blockIndices: [0], slot: slot) == expected)
    }

    @Test("out-of-range block indices are dropped (the reorderedIDs gather rule)")
    func outOfRangeIndicesDropped() {
        #expect(previewDisplayOrder(count: 4, blockIndices: [2, 9, -1], slot: 0)
                == [2, 0, 1, 3])
    }

    @Test("a wholly-dragged grid is just the block; an empty grid is empty")
    func degenerateGrids() {
        #expect(previewDisplayOrder(count: 3, blockIndices: [0, 1, 2], slot: 0)
                == [0, 1, 2])
        #expect(previewDisplayOrder(count: 0, blockIndices: [], slot: 0) == [])
    }

    @Test("the result is always a permutation of 0..<count")
    func alwaysPermutation() {
        for slot in -1...6 {
            let order = previewDisplayOrder(count: 6, blockIndices: [4, 1], slot: slot)
            #expect(order.count == 6)
            #expect(Set(order) == Set(0..<6))
        }
    }
}

// MARK: - previewFrames

@Suite("Reorder preview: frame mapping")
struct PreviewFramesTests {

    // 2 columns spanning 208 with 8pt gaps → columnWidth 100, stride 108.
    private let width: CGFloat = 208
    private let spacing: CGFloat = 8

    @Test("each data index gets its display position's frame (hand-solved)")
    func mapsDisplayFramesBackToDataOrder() {
        // Data aspects: d0 square, d1 panorama (h50), d2 skyscraper (h200).
        // Display order [2, 0, 1] → columns: d2 col0 y0, d0 col1 y0, d1 col0 y208.
        let preview = previewFrames(
            displayOrder: [2, 0, 1], aspects: [1, 2, 0.5],
            availableWidth: width, columns: 2, spacing: spacing, topInset: 0)
        #expect(preview.framesByDataIndex == [
            CGRect(x: 108, y: 0, width: 100, height: 100),   // d0 at display 1
            CGRect(x: 0, y: 208, width: 100, height: 50),    // d1 at display 2
            CGRect(x: 0, y: 0, width: 100, height: 200),     // d2 at display 0
        ])
        #expect(preview.contentHeight == 258)   // col0: 200 + 8 + 50
    }

    @Test("cell sizes ride their cells: height is columnWidth / DATA aspect")
    func sizesFollowData() {
        let aspects: [Double] = [1, 2, 0.5, 4]
        let preview = previewFrames(
            displayOrder: [3, 1, 0, 2], aspects: aspects,
            availableWidth: width, columns: 2, spacing: spacing, topInset: 0)
        for (index, aspect) in aspects.enumerated() {
            #expect(preview.framesByDataIndex[index].width == 100)
            #expect(preview.framesByDataIndex[index].height == 100 / CGFloat(aspect))
        }
    }

    @Test("the identity display order reproduces the plain masonry solve")
    func identityMatchesPlainSolve() {
        let aspects: [Double] = [1, 0.5, 2, 1, 1]
        let plain = MasonryLayout.layout(
            aspects: aspects, availableWidth: width, columns: 2,
            spacing: spacing, topInset: 12)
        let preview = previewFrames(
            displayOrder: [0, 1, 2, 3, 4], aspects: aspects,
            availableWidth: width, columns: 2, spacing: spacing, topInset: 12)
        #expect(preview.framesByDataIndex == plain.frames)
        #expect(preview.contentHeight == plain.contentHeight)
    }

    @Test("a stray out-of-range display entry maps nowhere and never traps")
    func outOfRangeEntrySkipped() {
        let preview = previewFrames(
            displayOrder: [1, 0, 7], aspects: [1, 1],
            availableWidth: width, columns: 2, spacing: spacing, topInset: 0)
        #expect(preview.framesByDataIndex.count == 2)
        #expect(preview.framesByDataIndex[1] == CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(preview.framesByDataIndex[0] == CGRect(x: 108, y: 0, width: 100, height: 100))
    }

    @Test("empty input yields no frames and the inset as content height")
    func emptyInput() {
        let preview = previewFrames(
            displayOrder: [], aspects: [],
            availableWidth: width, columns: 2, spacing: spacing, topInset: 24)
        #expect(preview.framesByDataIndex.isEmpty)
        #expect(preview.contentHeight == 24)
    }
}

// MARK: - masonryInsertionSlot

@Suite("Reorder preview: insertion slot")
struct MasonryInsertionSlotTests {

    /// A 2-column all-square preview (columnWidth 100, stride 108, rows every
    /// 108) built by the production pure functions themselves, so the slot math
    /// is tested against exactly the frames the drag would see.
    private func squarePreview(count: Int, blockIndices: [Int], slot: Int)
        -> (order: [Int], frames: [CGRect]) {
        let order = previewDisplayOrder(count: count, blockIndices: blockIndices, slot: slot)
        let preview = previewFrames(
            displayOrder: order, aspects: Array(repeating: 1, count: count),
            availableWidth: 208, columns: 2, spacing: 8, topInset: 0)
        return (order, preview.framesByDataIndex)
    }

    // The fixture: 4 squares, data item 0 dragged, currently previewed at slot 2.
    // Display grid:  [d1][d2]      rows y 0..100 and 108..208, columns x 0..100
    //                [d0][d3]      and 108..208; d0 is the ghost.
    private func fixture() -> (order: [Int], frames: [CGRect]) {
        squarePreview(count: 4, blockIndices: [0], slot: 2)
    }

    @Test("fixture sanity: the ghost sits at display slot 2")
    func fixtureSanity() {
        let (order, frames) = fixture()
        #expect(order == [1, 2, 0, 3])
        #expect(frames[0] == CGRect(x: 0, y: 108, width: 100, height: 100))
    }

    @Test("a hit on the ghost's own cell keeps the current slot (no oscillation)")
    func ghostHitKeepsSlot() {
        let (order, frames) = fixture()
        #expect(masonryInsertionSlot(
            at: CGPoint(x: 50, y: 150), framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == 2)
    }

    @Test("the left half of a cell inserts BEFORE it", arguments: [
        (CGPoint(x: 30, y: 30), 0),     // left half of d1 (first remaining)
        (CGPoint(x: 150, y: 150), 2),   // left half of d3 — block before it doesn't count
    ] as [(CGPoint, Int)])
    func leftHalfInsertsBefore(_ point: CGPoint, _ expected: Int) {
        let (order, frames) = fixture()
        #expect(masonryInsertionSlot(
            at: point, framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == expected)
    }

    @Test("the right half of a cell inserts AFTER it", arguments: [
        (CGPoint(x: 80, y: 30), 1),     // right half of d1
        (CGPoint(x: 190, y: 150), 3),   // right half of d3 → the end slot
    ] as [(CGPoint, Int)])
    func rightHalfInsertsAfter(_ point: CGPoint, _ expected: Int) {
        let (order, frames) = fixture()
        #expect(masonryInsertionSlot(
            at: point, framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == expected)
    }

    @Test("a gap between cells falls to the nearest cell by center distance")
    func gapFallsToNearest() {
        let (order, frames) = fixture()
        // (106, 55) sits in the column gutter, nearer d2's center (158, 50)
        // than d1's (50, 50); left of d2's midX → before d2 → slot 1.
        #expect(masonryInsertionSlot(
            at: CGPoint(x: 106, y: 55), framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == 1)
    }

    @Test("below the content the nearest bottom cell decides", arguments: [
        (CGPoint(x: 170, y: 400), 3),   // nearest d3, right half → end slot
        (CGPoint(x: 150, y: 400), 2),   // nearest d3, left half → before it
    ] as [(CGPoint, Int)])
    func belowContentFallsToBottomRow(_ point: CGPoint, _ expected: Int) {
        let (order, frames) = fixture()
        #expect(masonryInsertionSlot(
            at: point, framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == expected)
    }

    @Test("above the grid (inside a top inset) falls to the top row")
    func aboveGridFallsToTopRow() {
        let (order, frames) = fixture()
        #expect(masonryInsertionSlot(
            at: CGPoint(x: 30, y: -10), framesByDataIndex: frames,
            displayOrder: order, blockIndices: [0]) == 0)
    }

    @Test("an empty grid answers slot 0")
    func emptyGridIsZero() {
        #expect(masonryInsertionSlot(
            at: CGPoint(x: 50, y: 50), framesByDataIndex: [],
            displayOrder: [], blockIndices: []) == 0)
    }

    @Test("a wholly-dragged grid answers the current slot 0 everywhere")
    func whollyDraggedGrid() {
        let (order, frames) = squarePreview(count: 2, blockIndices: [0, 1], slot: 0)
        for point in [CGPoint(x: 30, y: 30), CGPoint(x: 150, y: 30), CGPoint(x: 300, y: 300)] {
            #expect(masonryInsertionSlot(
                at: point, framesByDataIndex: frames,
                displayOrder: order, blockIndices: [0, 1]) == 0)
        }
    }
}

// MARK: - hysteresis

@Suite("Reorder preview: re-slot hysteresis")
struct MasonryReslotHysteresisTests {

    @Test("travel under the threshold never re-slots", arguments: [
        CGPoint(x: 5, y: 5),    // ~7.07pt
        CGPoint(x: 7, y: 0),
        CGPoint(x: 0, y: 0),
    ])
    func underThresholdHolds(_ to: CGPoint) {
        #expect(!masonryShouldReslot(from: .zero, to: to))
    }

    @Test("travel at or beyond the threshold re-slots", arguments: [
        CGPoint(x: 8, y: 0),    // exactly the threshold
        CGPoint(x: 6, y: 6),    // ~8.49pt
        CGPoint(x: 0, y: 40),
    ])
    func atOrBeyondThresholdReslots(_ to: CGPoint) {
        #expect(masonryShouldReslot(from: .zero, to: to))
    }

    @Test("the threshold is tunable per call")
    func customThreshold() {
        #expect(masonryShouldReslot(from: .zero, to: CGPoint(x: 3, y: 0), threshold: 2))
        #expect(!masonryShouldReslot(from: .zero, to: CGPoint(x: 3, y: 0), threshold: 4))
    }
}

// MARK: - WYSIWYG contract

@Suite("Reorder preview: commit matches preview")
struct ReorderPreviewCommitContractTests {

    @Test("reorderedIDs(insertAt:) commits EXACTLY the previewed order, every slot")
    func commitMatchesPreviewOrder() {
        let ids = (0..<6).map { _ in UUID() }
        let moving = [ids[4], ids[1]]   // non-contiguous, reverse-picked
        for slot in -1...5 {            // includes both clamped extremes
            let committed = reorderedIDs(ids: ids, movingIDs: moving, insertAt: slot)
            let shown = previewDisplayOrder(count: 6, blockIndices: [1, 4], slot: slot)
                .map { ids[$0] }
            #expect(committed == shown, "slot \(slot)")
        }
    }
}
