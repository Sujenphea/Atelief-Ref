# 217 — Selection-bar overflow: collapsible tree Move to / Add to

## Summary

Reworked the selection action bar's `…` overflow popover (Collection view) from raw
native `Menu` submenus into custom, design-system-aligned sections, and expanded the
destination set to the full collection hierarchy.

- **Collapsible accordion**: Move to / Add to are `SelectionMenuSectionHeader` rows
  (title + chevron, no icon). Both start collapsed; opening one auto-collapses the
  other (`expandedMoreSection` state, animated with `Theme.Motion.snappy`). The
  popover reopens collapsed each time.
- **Full nested destination tree**: each section lists EVERY collection as an indented
  tree (`CollectionTargets.moveTargetTree` → `[MoveTargetNode]`; roots in gallery
  order, children in manual order), 8pt of indent per depth. Previously only the
  current collection's direct subfolders + roots were offered. The current collection
  is shown but **greyed out and disabled** (filing where the items already live is a
  no-op).
- **Height cap + scroll**: the list is a `ScrollView` pinned to `min(content, 240)`.
  A bare `ScrollView` collapses to zero in a content-sized popover, so the content's
  natural height is measured (`MenuListHeightKey` preference) and applied — shrink-to-
  fit for short trees, scroll past 240pt.
- **Design-system rows**: `SelectionMenuRow` — the sidebar row idiom (14pt
  `Theme.Typography.row`, radius-6 `selection` hover fill, per-depth indent, disabled
  rows in `inkSecondary`).
- **Container**: `.selectionMenuChrome()` — a `surface` card, `card` (12pt) corners,
  hairline border, `.hover` elevation, fixed 220pt width; the host popover's own
  chrome is cleared (`.presentationBackground(.clear)`).

New reusable pieces in `SelectionActionBar.swift`: `SelectionMenuSectionHeader`,
`SelectionMenuRow`, `.selectionMenuChrome()`, `MenuListHeightKey`.

Actions are unchanged — Move (undoable), Add (copy), Set as Cover call the exact same
`IngestionModel` methods as before.

## Files changed

- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` (new atoms + chrome + height key)
- `AtelierRefs/AtelierRefs/CollectionView.swift` (`moreActionsMenu`, `destinationList`
  over the tree, `MoreSection` accordion + measured-height state, `…` reset-on-open)
- `AtelierRefs/AtelierRefs/CollectionTargets.swift` (`MoveTargetNode`,
  `moveTargetTree(folders:unsortedID:)`)

## Notes

- The grid's right-click context menu still offers the older "direct subfolders +
  roots" targets (`MoveTargets` via `MasonryGridHost`) — only the popover moved to the
  full tree. Reconcile later if the two should match.
- Pure UI + a new pure target-list function; no persistence/migration changes.
