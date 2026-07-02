# 046 — Keyboard navigation for the Library grid

## Summary

The Library grid thumbnails were selectable by **click only**. This adds
**arrow-key navigation** over the grid, so you can walk the folder's items from
the keyboard and drive the inspector without the mouse:

- **Left / Right** move to the previous / next item in the flat ordered list.
- **Up / Down** move by one grid **row** (i.e. by the current column count).
- Selection **clamps** at the ends — no wrap past the first / last item; Up from
  the top row and Down past the last item leave the selection put.
- With nothing selected yet, the first arrow key selects the first item.
- The newly-selected thumbnail is **scrolled into view**.

Selection already drives the inspector, so moving the selection is the whole
interaction — no separate "open" step. Click-to-select and the existing ⌫ /
Delete command are untouched.

## What changed

- **Pure movement math** (SwiftUI-free, unit-tested):
  - `nextGridIndex(from:key:count:columns:)` — given the current selection index
    (`nil` = nothing selected), the flat item count, and the columns per row,
    returns the index to select next. Left/Right step by one; Up/Down step by a
    whole row (`columns`). Always clamped into `0..<count`; returns `nil` only for
    an empty grid; a `nil` current selection yields the first item.
  - `gridColumnCount(availableWidth:minItemWidth:spacing:)` — mirrors how
    `GridItem(.adaptive(minimum:))` packs a row, so Up/Down step by the **actual**
    on-screen column count. Always at least 1.
  - `GridArrowKey` — a small direction enum keeping the helpers free of SwiftUI.
- **Grid wiring** (`LibraryView.grid`):
  - Wrapped the grid in a `GeometryReader` (to know the width the adaptive grid
    packs into → the live column count) and a `ScrollViewReader` (to scroll the
    new selection into view). Each cell carries `.id(detail.item.id)`.
  - The scroll view is now `.focusable()` so it receives key events; four
    `.onKeyPress(.upArrow/.downArrow/.leftArrow/.rightArrow)` handlers call a
    private `move(_:width:proxy:)` that resolves the current index from
    `selectedItemID`, computes the target via `nextGridIndex`, selects it (only
    when it changes), and `scrollTo`s it (`.center`). Returns `.handled` when a
    grid item exists to act on, `.ignored` for an empty folder.
  - The adaptive grid's `minimum` (112) and `spacing` (8) are now shared
    constants (`gridItemMinWidth`, `gridSpacing`) so the layout and the column-
    count math cannot drift apart.

## Files changed

- `AtelierRefs/AtelierRefs/GridNavigation.swift` (new) — the pure helpers +
  `GridArrowKey`.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — `GeometryReader` +
  `ScrollViewReader` around the grid, `.focusable()`, the four `.onKeyPress`
  handlers, `move(_:width:proxy:)`, and the shared sizing constants.
- `AtelierRefs/AtelierRefsTests/GridNavigationTests.swift` (new) — 9 tests over
  the two pure helpers.

## Verification

- `cd AtelierRefs && xcodebuild -project AtelierRefs.xcodeproj -scheme AtelierRefs
  -destination 'platform=macOS' build` — **BUILD SUCCEEDED**.
- `xcodebuild … test -only-testing:AtelierRefsTests/GridNavigationTests` —
  **TEST SUCCEEDED, 9 tests passed**. They cover the empty grid (`nil`), the
  no-selection-selects-first rule, Left/Right stepping + clamp, Up/Down by a row,
  Up-from-top / Down-past-end staying put, columns floored to ≥ 1, and the
  adaptive column-count packing (incl. degenerate widths → 1 column).
- The SwiftUI wiring (`.focusable()`, `.onKeyPress`, `ScrollViewReader`,
  `GeometryReader`) is **compile-verified only** — no runtime GUI test; a manual
  arrow-key click-through remains pending (consistent with the repo's
  runtime-UI-verification-pending note).

## Migration notes

None. Additive behavior; no schema, data, or public-API change. New app-target
file `GridNavigation.swift` (picked up automatically by the project's
file-system-synchronized group — no `.xcodeproj` edit). Click-to-select and the
existing `.onDeleteCommand` are preserved.
