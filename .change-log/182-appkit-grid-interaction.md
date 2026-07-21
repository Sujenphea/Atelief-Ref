# 182 — AppKit grid: live interaction (036 §4 A2)

Wires the inert A1 seams into live interaction on the AppKit grid path
(`AtelierUseAppKitGrid`, still **default OFF**): selection reconciliation (layer-
only), mouse routing + a click/drag-threshold loop, hover, keyboard, scroll-to,
and density preservation. All logic funnels through the SAME pure tables A1 kept
(`gridPressRouting`/`gridClickAction`, `GridSelection` reducer, `GridNavigation`,
`masonryMarqueeIndices`, `GridSelectionStore`) — A2 is a new AppKit *delivery*
front-end, not a reimplementation.

## Summary

- **Selection is layer-only.** The coordinator subscribes to
  `selectionStore.$selection` and reconciles via new pure
  `selectionCellDelta(from:to:)` (symmetric diff of `ids` ∪ lead moves, plus a
  mode-flip flag) + `selectionReconcileTargets(delta:visibleIDs:)`. A change
  repaints only the CHANGED, VISIBLE cells through
  `MasonryGridItem.applySelectionState` — no snapshot, no relayout. A first-
  select / last-deselect mode flip repaints all visible cells (circles appear /
  vanish). This is the multi-select smoothness win.
- **Mouse.** The cell forwards its image-area `mouseDown` to the coordinator,
  which runs `gridPressRouting` on the down edge, then a ~4pt drag-threshold loop
  (`nextEvent`) to classify click vs drag. A click applies `gridClickAction`
  unless the press consumed the release; a drag calls a named **A3 stub**. The
  circle `NSButton` action routes to `.tapCircle`.
- **Hover.** One `NSTrackingArea` on the collection view; `mouseMoved` and the
  clip-view `boundsDidChange` (scroll) re-hit via a zero-rect
  `masonryMarqueeIndices` over the ANALYTIC frames (`layout.hitTestIndex(at:)`),
  driving the circle's idle-hover visibility layer-only. Structurally fixes
  hover-during-scroll and the stranded-circle case — no `hoverAfterWindowChange`.
- **Keyboard.** The collection view becomes first responder on click;
  `keyDown` handles arrows / return / esc / space / x / delete,
  `performKeyEquivalent` handles ⌘A / ⌘± , and `deleteBackward`/`deleteForward`
  back the delete key. The NSEvent→command map is the pure `gridKeyCommand`; each
  command executes through the reducer / config closures. **Escape falls through
  to `super` when NOT selecting** (the detail overlay's own close still works).
- **scrollTo + density.** Arrow-nav `.scrollTo` →
  `animator().scrollToItems(scrollPosition: .centeredVertically)` (matches
  `proxy.scrollTo(anchor:.center)`). A density step records the topmost visible
  index, re-solves, and restores it (non-animated).

## Files changed

- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — config gains `selectionStore`
  + effect closures (`onOpenDetail`/`onRequestDelete`/`onQuickLook`/`onZoomIn`/
  `onZoomOut`); `MasonryNSCollectionView` becomes first responder and forwards
  keyboard + hover (new `MasonryGridViewEvents`); coordinator conforms to
  `MasonryGridInteraction`/`MasonryGridViewEvents`, adds the `$selection`
  subscription + reconcile, mouse/keyboard/hover routing, scroll-to, density
  restore; new pure `selectionCellDelta`, `selectionReconcileTargets`,
  `gridMouseModifiers`, `gridIsDeleteKey`, `GridKeyCommand` + `gridKeyCommand`.
- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — new `MasonryGridInteraction`
  delegate; cell view forwards `mouseDown`; circle button enabled + wired to
  `.tapCircle`; `applySelectionState` now picks the circle symbol/tint and defers
  visibility to a hover-aware `updateCircleVisibility`; new `setHovered`; `itemID`
  tracked for the coordinator's routing.
- `AtelierRefs/AtelierRefs/MasonryCollectionLayout.swift` — `solvedColumns` (arrow
  nav) + `hitTestIndex(at:)` (hover/mouse) over the analytic frames.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `appKitGrid` populates the new
  config seams. (Flag-off `loadedGrid` path untouched.)
- `AtelierRefs/AtelierRefsTests/SelectionCellDeltaTests.swift` — new: the delta /
  reconcile-targets logic (symmetric diff, lead move, mode flip BOTH directions,
  visible-only, off-screen exclusion) and the NSEvent→action glue (`gridKeyCommand`,
  delete-key predicate, modifier read feeding `gridPressRouting`/`gridClickAction`).

## Wired now vs stubbed for A3

**Wired (flag on):** click/⇧/⌘ selection + open, circle toggle, hover circle,
arrows (+⇧ extend), return/esc/space/x, ⌘A, ⌘±, delete, arrow scroll-into-view,
density anchor. Cells always paint their current selection + hover on
materialize / scroll-in.

**Stubbed / deferred to A3 (named):** the drag hand-off (`beginDragHandoffStub` —
classification is A2, the `NSDraggingSource` session is A3); drop onto cells;
container context menu (already exists SwiftUI-side from C4, not rebuilt);
**marquee rectangle + empty-background click-to-clear + edge auto-scroll**
(bundled with the marquee, A3); GIF hover.

## Parity / honesty notes

- **Body republish.** The coordinator's cell reaction is layer-only and never
  goes through the SwiftUI body. `CollectionView` still observes `selectionStore`
  at the struct level (A0's subscription, unchanged per constraint), so its body
  re-evaluates on a selection change — but on the AppKit path that body renders
  **no cells** (only the host + overlay), so no per-cell work happens and the
  coordinator never relayouts/resnapshots. Fully removing the eval needs the
  A0-noted "move the nine reads into per-cell views" refactor; left for later.
- **Circle click vs mouseDown.** Circle hits route through the button's own hit
  area (→ `.tapCircle`), so the cell's `mouseDown` only ever sees image-area
  clicks — equivalent to §4 A2's "circle hit → `.tapCircle`", cleaner than
  re-hit-testing the circle rect.
- **Delete.** Routed both from the `keyDown` delete-key predicate and the
  `deleteBackward`/`deleteForward` responder methods (the key path is primary
  since `interpretKeyEvents` delivery can't be verified headlessly).
- **Off-screen edge cases.** A cell (or a lead) that changes while scrolled off is
  not touched by reconcile; it repaints correctly from `configure` on scroll-in.

## Verification

- Release build: `xcodebuild build … -configuration Release` exit **0**; no new
  warnings from the changed files (the lone CollectionView warning at :806 is
  pre-existing, in the untouched SwiftUI drop handler).
- `xcodebuild test -only-testing:AtelierRefsTests -parallel-testing-enabled NO`:
  **418 tests / 69 suites passed**, incl. the two new A2 suites; every pre-
  existing (flag-off) suite stays green.
- Not headlessly testable (named, not verified here): `NSTrackingArea` hover
  delivery, first-responder/`keyDown` delivery, live cell recycling, the
  drag-threshold event loop. The extractable pure logic + reconcile-target
  selection are tested instead.

## Amends to `.docs/036`

§4 A2's "circle hit → `.tapCircle`" is delivered via the button's hit area, not a
`mouseDown` rect test. Empty-background click-to-clear is entangled with the
marquee capture layer and was deferred with the marquee to A3 (A2 leaves a
background click a no-op). The whole-body-republish elimination is partial (see
Parity notes) pending the per-cell-view refactor A0 flagged.
