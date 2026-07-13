# 096 — Item detail: open on Return from the grid

Adds keyboard invocation of the detail page from the collection grid
([023-item-detail-plan](../.docs/023-item-detail-plan.md), F3). Single-click
already opens (unchanged, per the confirmed decision); this makes the grid's
keyboard flow complete — arrows select, **Return opens** the selected item.

## Summary

- **`CollectionView` grid**: `.onKeyPress(.return)` opens the selected item via
  the shared `open(_:)` seam (`094`) — `.ignored` when nothing is selected so the
  key still propagates. No change to click, arrow-nav, ⌫-to-delete, or
  drag-reorder.

## Canvas invocation → deferred to F3b

The plan's decision 2 allowed splitting the Space-canvas open path out if it
wasn't a thin lookup. It isn't: `SpaceView.onActivateTile` already handles
video→QuickLook and frame/text→inspector, and an image-asset double-click is the
open gap — but the detail *page* (`ItemDetailView`) is bound to `IngestionModel`'s
collection-scoped `selectedItem` / `items` (prev/next) / folder actions. A space
asset carries a `SpaceItemDetail` (asset + source) with **no `CollectionItem`
membership**, so a correct presentation needs `ItemDetailView` decoupled to accept
an explicit detail. That refactor + the canvas double-click are **F3b** (tracked
in the plan doc), not this commit.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionView.swift` — grid `.onKeyPress(.return)`.
- `.docs/023-item-detail-plan.md` — F3 canvas path recorded as deferred to F3b.

## Migration notes

None — additive keyboard binding.

## Tests

App builds clean; `AtelierRefsTests` green. The binding is UI-gesture wiring over
the already-covered `open(_:)`/selection path; no new unit test.
