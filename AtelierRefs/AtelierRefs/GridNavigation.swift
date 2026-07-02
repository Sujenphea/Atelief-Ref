//
//  GridNavigation.swift
//  AtelierRefs
//
//  Pure, testable helpers for keyboard navigation of the Library grid. The grid
//  is a flat ordered list laid out in rows of `columns`; arrow keys walk that
//  list (Left/Right by one, Up/Down by a whole row) and clamp at the ends — no
//  wrap. Kept free of SwiftUI so the movement math can be unit-tested directly.
//

import CoreGraphics

/// A grid-navigation arrow direction (SwiftUI-free so the helpers are testable).
enum GridArrowKey {
    case left, right, up, down
}

/// The index to select after pressing `key`, given the current selection index
/// (`nil` when nothing is selected), the flat item `count`, and the current
/// `columns` per row. Returns `nil` only when there is nothing to select
/// (`count == 0`).
///
/// - Left/Right step by one item; Up/Down step by a whole row (`columns`).
/// - The result is always clamped into `0..<count` — never wraps past an end.
/// - With no current selection, the first arrow selects the first item (`0`).
/// - Up from the top row / Down past the last item leave the selection put.
func nextGridIndex(from current: Int?, key: GridArrowKey, count: Int, columns: Int) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return 0 }
    let cols = max(1, columns)
    switch key {
    case .left:
        return max(0, current - 1)
    case .right:
        return min(count - 1, current + 1)
    case .up:
        let target = current - cols
        return target >= 0 ? target : current
    case .down:
        let target = current + cols
        return target <= count - 1 ? target : current
    }
}

/// The number of columns an adaptive grid fits into `availableWidth` for items of
/// at least `minItemWidth` with `spacing` between them — mirrors how SwiftUI's
/// `GridItem(.adaptive(minimum:))` packs a row. Always at least 1.
func gridColumnCount(availableWidth: CGFloat, minItemWidth: CGFloat, spacing: CGFloat) -> Int {
    guard availableWidth > 0, minItemWidth > 0 else { return 1 }
    let count = Int((availableWidth + spacing) / (minItemWidth + spacing))
    return max(1, count)
}
