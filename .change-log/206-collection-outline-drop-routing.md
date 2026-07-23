# 206 · Outline-view drop routing brain (043 Phase C1)

## Summary

The pure, fully-tested core of the NSOutlineView sidebar rebuild (043 · Phase C),
landed ahead of the AppKit glue so the drag logic is locked down before the
un-unit-testable view wiring. No user-visible change yet — this code is wired up by
the C2 bridge.

## What changed

- **`CollectionTargets.routeOutlineDrop(dragged:into:childIndex:folders:unsortedID:)`**
  — resolves an outline-view drop into `CollectionDrop.move(toParent:index:)` or
  `.reject`. Handles nest-onto-row (`childIndex == nil` → append), insert-between
  (`childIndex == i`), and the same-parent reorder **index normalization** (a drop
  below the dragged item's own slot shifts down by one to match the service's
  "index with the item removed" contract). Rejects via the shared
  `canReparent` predicate (self / descendant / Unsorted). AppKit-free.
- **`CollectionDrop`** enum (in `CollectionDragPayload.swift`): `.reject` /
  `.move(toParent:index:)`. Reparent and same-parent reorder collapse to one op.
- **`CollectionDragPayload` NSPasteboard bridge**: `pasteboardType` /
  `pasteboardData()` / `decode(from:)` / `makePasteboardItem()`, byte-compatible
  with the SwiftUI `CodableRepresentation` (the outline view drags via AppKit).
- **`CollectionTargets.orderedChildren(of:in:)`**: a parent's children in manual
  order — the list the outline view renders and the router indexes against.
- **`IngestionModel.moveFolder(id:toParent:index:)`**: now takes an `index`
  (nil = append) and its undo inverse restores BOTH the old parent AND the old
  slot (captured `sortIndex`), so undoing a drag puts the folder back exactly.
  Plus `applyCollectionDrop(_:dragged:)` to funnel a routed drop through it.

## Tests

- `CollectionDropRoutingTests` (new, 13 · 12A): payload round-trip + garbage-decode;
  nest-onto-row / self / descendant / Unsorted; drag-Unsorted; between-different-
  parent; between-top-level; same-parent reorder down (−1 normalize) and up (no
  shift); between-under-descendant reject. App build + suite green.

## Notes

C2 (the `NSViewRepresentable` + coordinator that delegates drops to
`routeOutlineDrop` and drives disclosure/selection) is the next step and must be
verified in-app — AppKit drag/drop can't be unit-tested.
