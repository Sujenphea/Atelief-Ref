# 195 — Sidebar drag-to-space / drag-to-collection

## Summary

The dark-studio sidebar's Spaces and Collections rows are now asset drop targets,
mirroring the collection screen's drop rail. Drag a selection out of the grid and
drop it onto:

- **A collection row** — MOVES the assets into that collection (hold ⌥ to COPY),
  routed through the shared `routeDrop` decision so `from == to` / empty drops are
  refused in one place. Same semantics as the trailing `CollectionDropRail`.
- **A space row** — ADDS the assets to that space's board (a space is a placement
  board, so it is always additive — the source collection is untouched). The assets
  flow into justified rows below the space's current content; a first drop into an
  empty space also seeds its cover.

The dragged-over row highlights with an accent border. Nav rows (Home / Capture /
Settings) opt out by passing no drop handler, so a drag over them is a no-op.

## Files changed

- `IngestionModel.swift` — new `addAssetsToSpace(assetIDs:to:)`: resolves the
  dragged ids to assets (for aspect-ratio flow-in), appends below current content
  via `SpaceLayout.flowIn`, seeds the cover on first content, refreshes the list.
- `SidebarView.swift` — `treeRow` gains optional `dropID` + `onDrop`; new
  `handleCollectionDrop` / `handleSpaceDrop` routers; `rowHighlight` gains a
  `targeted` state; new `RowDropModifier` attaches the `.onDrop` only to rows that
  accept drops; `dropTargetID` state drives the highlight.

## Migration notes

None. The existing `CollectionDropRail` on the collection screen is unchanged; the
sidebar is an additional surface using the same `AssetDragPayload` / `routeDrop`
contract, so an AppKit grid drag lands on either identically.
