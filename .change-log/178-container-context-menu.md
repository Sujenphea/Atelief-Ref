# 178 — Container-level lazy context menu (036 §4 C4)

Step 3 of the amended `036` sequence, the last SwiftUI-side change before the
DECISION GATE. The per-cell `.contextMenu` is gone; the grid now has ONE menu on
its content container whose target is hit-tested from the cursor on right-click.

## Why

Every windowed cell used to carry its own `.contextMenu`, so a band crossing
built ~100 complete menu trees (two `Menu`s each looping every move/copy
destination, plus buttons and a divider) for a right-click that lands on at most
one cell. 035 §4 measured 122 ms / 20 s at the user's 4 collections, LINEAR in
folder count and paid twice per cell; 038 §3.3 measured stripping the per-cell
wrappers (this menu among them) as the largest SwiftUI-side effect in the
bake-off — frames over 2P went **314 → 8** at 2000 items. C4 captures the menu
share of that without the AppKit rewrite.

## What changed

**One menu, resolved on demand.** A single `.contextMenu` on the grid's content
container. Its body (`containerMenu`) resolves the target cell by hit-testing the
cursor against the **analytic** `MasonryLayout` frames — a zero-size-rect
`masonryMarqueeIndices` query, the same call the marquee runs per drag tick — and
then builds the **unchanged** `cellMenu(for:)` for that one cell. The menu
contents, submenus, counts, and every action are byte-for-byte what they were;
only the number of times the tree is built changed (once per right-click, not
once per cell per rebuild). A cursor over a gap resolves to no target and
presents no menu, matching what right-clicking empty space did before.

Analytic frames, never live cell frames: 038 §6 records that AppKit pixel-snaps
item views and masonry heights are fractional (`columnWidth / aspect`), so
rendered frames drift up to 0.23 pt from the analytic ones. Reusing the marquee's
own hit-test also means the menu and a click-marquee can never name different
cells (asserted in the tests).

**Targeting (the two 036 §4 C4 wrinkles):**

- *Cursor position.* `.onContinuousHover` on the container stores the pointer in
  **viewport** space (a non-published var, like the marquee's per-tick state, so
  it never re-renders the grid). Viewport, not content: a wheel/trackpad scroll
  moves content under a stationary pointer WITHOUT a mouse-moved event, so a
  stored content point would silently go stale and target the wrong cell. The
  live scroll offset (already tracked by `marquee.visibleRect`) is re-added at
  read time.
- *Keyboard invocation.* A menu opened from the Menu key has no cursor; that case
  is `cursorViewport == nil`, and `contextTargetIndex` falls back to the keyboard
  cursor (`lead`) cell, per the spec.

**Lost system highlight.** The per-cell `.contextMenu` drew a focus ring on the
targeted cell for free; a container menu does not. New
`GridContextHighlightLayer` (a sibling of `MarqueeRectangleLayer`, same content
space) draws the analytic frame of the target cell while the menu is open —
accent stroke, radius 8, the same shape as `CollectionCell.cursorRing` but full
opacity to read as stronger than the idle keyboard cursor it may sit over. It is
scoped to menu lifetime via `NSMenu.didBegin/didEndTracking`, gated on the
pointer being over the grid so unrelated menus (toolbar, main bar) don't draw it.

**The scope rule is now pure and shared.** `IngestionModel.actionTargets(...)`
delegates to a new pure `gridActionTargets(isSelected:selectedAssetIDs:cellAssetID:)`.
Finder scope (009 · 7A) is unchanged and now directly unit-tested: right-click
INSIDE the selection acts on the whole selection; OUTSIDE it acts on that one
cell and leaves the selection untouched. **Verified against the current code, not
inferred:** the old per-cell `.contextMenu` never selected the right-clicked
cell (SwiftUI's `.contextMenu` doesn't, and `actionTargets` is a pure read), and
the container menu applies no selection action either — so a right-click still
never changes the selection. (The brief's parenthetical "and per current
behavior, selects" does not match the code; current behavior does not select.)

**Out of scope, as specified.** The drag preview / `.draggable` is untouched — a
drag genuinely originates from one cell and does not collapse the same way.

## Files changed

- `AtelierRefs/AtelierRefs/GridContextMenu.swift` — **new.** Pure
  `gridCursorContentPoint`, `masonryContextTargetIndex`, `gridActionTargets`;
  `GridContextMenuState` (per-tick cursor + published highlight frame) and
  `GridContextHighlightLayer`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — per-cell `.contextMenu`
  removed; container `.contextMenu` + `.onContinuousHover` + NSMenu-tracking
  highlight lifetime; `containerMenu` / `contextTargetIndex` helpers;
  `GridContextHighlightLayer` added to the content ZStack; `contextMenu` state.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `actionTargets` delegates to
  the pure `gridActionTargets`.
- `AtelierRefs/AtelierRefsTests/GridContextMenuTests.swift` — **new**, 17 tests:
  viewport→content conversion (incl. the scroll-invariance case), point→index
  over real fractional masonry frames (cell centres, gutter, top inset, below
  content, empty, shared-edge tie-break, equivalence to the marquee oracle,
  nil/keyboard case), and the selection-vs-single-item scope rule.

`Debug/` untouched, per the bake-off's bit-identical requirement.

## Verification

- **Release build: SUCCEEDED** (judged on xcodebuild's exit status, not a piped
  tail). No new warnings from the changed files; the one warning at the changed
  `CollectionView.swift` drop-destination line is pre-existing (identical on
  HEAD) and untouched.
- **`AtelierRefsTests`, `-parallel-testing-enabled NO`: 370 / 370 passed**, 60
  suites, including the new 17-test "Grid container context menu" suite.
- UI tests were **not** run, per the brief.

## Manual verification still owed (could not be exercised here)

The pure resolution and scope logic is unit-tested; the SwiftUI wiring is not
UI-testable in this environment. Worth a human pass:

1. Right-click a cell mid-scroll and at rest — menu targets the cell under the
   pointer; the highlight ring lands on the same cell.
2. Right-click inside vs outside a multi-selection — counts in "Delete (N)" /
   "Remove (N)" reflect selection vs single, selection unchanged either way.
3. Menu-key (keyboard) invocation with no hover — targets the lead cell.
4. Right-click empty space / a gutter — no menu appears.
5. Confirm `.onContinuousHover(coordinateSpace: .named)` resolves against the
   grid's named content space as expected (the point conversion depends on it).

## Edge case flagged honestly

The highlight is scoped by the global `NSMenu` tracking notifications, gated on
the pointer being over the grid. If an UNRELATED menu opens while the pointer
happens to rest over a grid cell (e.g. a main-menu shortcut), the ring could
draw briefly on that cell and clear when that menu closes. Cosmetic, transient,
and unlikely; SwiftUI exposes no "our context menu opened" hook to scope it more
tightly.

## Nothing to amend in 036

§4 C4 named both wrinkles and the out-of-scope drag preview; all handled as
written. The keyboard-fallback-to-`lead` and the viewport-space cursor capture
are the two design decisions §4 C4 left to the implementer, resolved here.
