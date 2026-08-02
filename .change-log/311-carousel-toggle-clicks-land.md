# 311 — carousel toggle clicks land where they were aimed

## Summary

Two UX defects in the grid's carousel expand/collapse (307/309), both of the
form "the thing under the cursor is not the thing the click hits".

### 1. The `⧉ N` chip jumped on every toggle

The chip and the selection circle were anchored to the cell's `contentRect`,
which is inset by the fan geometry (~5–15pt per side) only while the post is
collapsed. Toggling flipped the inset, sliding both diagonally by roughly the
chip's own height — out from under a cursor parked on it.

The controls now pin to the TILE's corners (`view.bounds`); only the artwork
and its rings/scrim still track the fan inset. One shared `layOutBadge()` places
the chip from both `viewDidLayout` and `setPostMemberCount`, so a reconfigure
between layout passes can't leave the drawn capsule and its rect disagreeing.

### 2. Spam-clicking the chip opened a random post/video

**Measured cause** (instrumented build, real repro — the trace is quoted below).
The click path was the ONLY grid interaction that resolved its target through
AppKit's view hit-test plus the cell's live `CALayer`. Hover, marquee and the
context menu all ride the analytic frames, which 038 §3.4 states as the rule:
hit-testing must use `analyticFrame(at:)`, never `cell.view.frame`.

Click 1 opened an 8-image post (14 → 21 items). Click 2, 234ms later, was
dispatched by AppKit to a cell view that the reflow had already recycled and
moved 200pt away — the press converted to `(-179, -259)` in that cell's own
coordinates, i.e. nowhere near it:

```
cell.down id=E8F1 badgeHit=true count=8 expanded=false lead=true clicks=1
host.badge cellSays=E8F1 layoutSays=E8F1 agree=true
=== applyItems 14 → 21 items strategy=snapshot ===
cell.down id=FA5C pt=(-179,-259) badgeHidden=true badgeHit=false expanded=true lead=false
host.cellDown cellSays=FA5C layoutSays=E8F1 agree=false pt=(261,71)
>>> OPEN DETAIL id=FA5C <<<
```

`layoutSays=E8F1` — the layout knew the press was over the lead tile, still
bearing its chip. The cell AppKit picked was an open post's MEMBER, whose chip
is (correctly) hidden, so `badgeHit` was false, the press fell through to
`.tapImage`, and — because `.tapImage` with an empty selection always returns
`.openDetail` — it opened that member. A chip miss had no neutral outcome.

The fix: the cell forwards the raw event and decides nothing. The coordinator
resolves BOTH questions from the analytic frames plus the model — which item
(`layout.hitTestIndex(at:)`) and whether the chip was hit (`gridBadgeZoneHit`,
from the tile's analytic frame + `postGroups` + `expandedPosts`). A chip-zone
press is handled first and never falls through, so a chip-bearing tile either
toggles or does nothing; it can no longer open anything.

Three supporting fixes, all still in place:

- The chip path consumes its own `mouseUp` (in the coordinator now), and
  `GridMarqueeController.mouseUp()` ignores an orphan release (`guard start !=
  nil`) with `end()` resetting the stale `shiftAtStart`. Without this a chip
  click leaked its release to the background handler, which cleared the
  selection — dropping the grid out of selecting mode, where clicks open.
- `applyItems` anchors the viewport across an expand/collapse (capture the
  topmost visible item, restore by its frame DELTA) instead of letting a
  shrinking content height clamp the offset and slide the grid.
- The snapshot path now runs `reconfigureVisibleItems()`, since a diffable apply
  re-vends only INSERTED index paths and surviving cells kept pre-toggle
  fan/chip state.

**Removed:** the timestamp-based stale-press guard from the first pass. The
trace shows it never fired (`stale=false` on the failing click — the press
arrived *after* the reflow), and it was unsound anyway: it can only turn a wrong
click into a dead one, and it drops any event not on the `systemUptime` clock.

## Files changed

- `AtelierRefs/AtelierRefs/MasonryGridItem.swift` — chip/circle pin to
  `view.bounds`; `layOutBadge()` single placement path; `handleViewMouseDown`
  forwards the event only (`badgeHit`/`consumeRelease` gone); new pure
  `gridTileShowsChip` / `gridBadgeRect` / `gridBadgeZoneHit`;
  `MasonryGridInteraction.gridCellMouseDown(event:)` replaces the
  `(id:event:)` + `gridCellBadgeClicked` pair.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — `gridCellMouseDown(event:)`
  resolves the tile analytically and handles the chip zone first; `badgeZoneHit`
  + `consumeRelease`; `GridScrollAnchor` capture/restore; stale-press guard
  removed.
- `AtelierRefs/AtelierRefs/GridMarqueeController.swift` — orphan `mouseUp`
  guard; `end()` resets `shiftAtStart`.
- `AtelierRefs/AtelierRefsTests/MasonryGridItemBadgeTests.swift` — chip frame
  identical across the toggle; reconfigure agrees with layout; the analytic
  chip rect/zone rules.
- `AtelierRefs/AtelierRefsTests/GridMarqueeControllerTests.swift` — new
  click-to-clear guard suite.

## Migration notes

None — no schema, no persisted state. Behavioural deltas:

- The chip and selection circle sit slightly OUTSIDE the fanned artwork on a
  collapsed tile; they are tile chrome now, not artwork chrome.
- A press in a chip-bearing tile's chip zone can never open a detail.
- A press whose analytic hit-test finds no tile (a sub-pixel edge case at a cell
  boundary) is ignored rather than routed to whichever cell view caught it.
- 309's open question — whether the reflow on open wants an animation — remains
  open; this change keeps the instant relayout.
