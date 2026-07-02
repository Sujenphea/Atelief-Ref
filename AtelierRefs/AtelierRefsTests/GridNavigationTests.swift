//
//  GridNavigationTests.swift
//  AtelierRefsTests
//
//  Guards the pure Library-grid keyboard-navigation math: arrow keys walk a flat
//  ordered list (Left/Right by one, Up/Down by a row) and clamp at the ends — an
//  off-by-one here would jump the selection to the wrong image.
//

import CoreGraphics
import Testing
@testable import AtelierRefs

@Suite("Grid keyboard navigation")
struct GridNavigationTests {

    // MARK: - nextGridIndex

    @Test("no items → nil regardless of key")
    func emptyReturnsNil() {
        for key in [GridArrowKey.left, .right, .up, .down] {
            #expect(nextGridIndex(from: nil, key: key, count: 0, columns: 4) == nil)
            #expect(nextGridIndex(from: 2, key: key, count: 0, columns: 4) == nil)
        }
    }

    @Test("no selection → first arrow selects the first item")
    func noSelectionSelectsFirst() {
        for key in [GridArrowKey.left, .right, .up, .down] {
            #expect(nextGridIndex(from: nil, key: key, count: 10, columns: 4) == 0)
        }
    }

    @Test("Left/Right step by one and clamp at the ends")
    func horizontalStepsAndClamps() {
        #expect(nextGridIndex(from: 5, key: .right, count: 10, columns: 4) == 6)
        #expect(nextGridIndex(from: 5, key: .left, count: 10, columns: 4) == 4)
        // Clamp: no wrap past either end.
        #expect(nextGridIndex(from: 9, key: .right, count: 10, columns: 4) == 9)
        #expect(nextGridIndex(from: 0, key: .left, count: 10, columns: 4) == 0)
    }

    @Test("Up/Down step by a whole row (columns)")
    func verticalStepsByRow() {
        #expect(nextGridIndex(from: 6, key: .down, count: 12, columns: 4) == 10)
        #expect(nextGridIndex(from: 6, key: .up, count: 12, columns: 4) == 2)
    }

    @Test("Up from the top row stays put (no wrap)")
    func upFromTopRowStays() {
        #expect(nextGridIndex(from: 2, key: .up, count: 12, columns: 4) == 2)
    }

    @Test("Down past the last item stays put (no wrap into the void)")
    func downPastEndStays() {
        // count 10 (indices 0…9), columns 4: index 6 + 4 = 10 is out of range.
        #expect(nextGridIndex(from: 6, key: .down, count: 10, columns: 4) == 6)
        // Down into a valid partial last row is allowed.
        #expect(nextGridIndex(from: 4, key: .down, count: 10, columns: 4) == 8)
    }

    @Test("columns are floored to at least 1")
    func columnsFlooredToOne() {
        // With columns 0/negative → treat as a single column (Down = +1).
        #expect(nextGridIndex(from: 3, key: .down, count: 10, columns: 0) == 4)
        #expect(nextGridIndex(from: 3, key: .up, count: 10, columns: 0) == 2)
    }

    // MARK: - gridColumnCount

    @Test("column count mirrors an adaptive grid packing a row")
    func columnCountPacksRow() {
        // min 112, spacing 8 → each extra column costs 120pt after the first 112.
        // 480: (480+8)/(112+8) = 488/120 = 4.06 → 4 columns.
        #expect(gridColumnCount(availableWidth: 480, minItemWidth: 112, spacing: 8) == 4)
        // 112 exactly fits one; 231 still one (needs 232 for two).
        #expect(gridColumnCount(availableWidth: 112, minItemWidth: 112, spacing: 8) == 1)
        #expect(gridColumnCount(availableWidth: 231, minItemWidth: 112, spacing: 8) == 1)
        #expect(gridColumnCount(availableWidth: 232, minItemWidth: 112, spacing: 8) == 2)
    }

    @Test("degenerate widths never drop below one column")
    func columnCountNeverZero() {
        #expect(gridColumnCount(availableWidth: 0, minItemWidth: 112, spacing: 8) == 1)
        #expect(gridColumnCount(availableWidth: 50, minItemWidth: 112, spacing: 8) == 1)
        #expect(gridColumnCount(availableWidth: -10, minItemWidth: 112, spacing: 8) == 1)
    }
}
