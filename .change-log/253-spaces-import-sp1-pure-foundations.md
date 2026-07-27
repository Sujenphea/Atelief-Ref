# 253 — Spaces import: SP1 pure foundations

Phase SP1 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
the host-free, unit-tested primitives that later phases (library drag, external
drop, paste) build on. No UI, no drag wiring yet.

## Summary

- **Origin-seeded flow-in (6A).** `SpaceLayout.flowIn` now packs from an explicit
  top-left `(originX, originY)` instead of a bare `startY`; the wrap boundary
  travels with `originX` so a flow seeded anywhere still wraps at `maxRowWidth`
  worth of content. Added a `centeredOn:` overload that packs then translates so
  the block's bounding box is centred on a world point — the drop-at-point
  seeding, uniform for 1 or N items — plus a pure `boundingBox(_:)` helper.
- **Pure board-drop decision (11A).** New `CanvasDropRouter.swift`:
  `canvasDropRoute(_:) -> CanvasDropRoute` (place / ingestThenPlace / reject) over
  a decoded `CanvasDropContents` classification — the canvas analog of
  `DropRouter`. Deliberately point-free (a board drop always targets the canvas,
  never a tile) and precedence-free (input precedence stays owned by the already
  tested `DirectInputReader`).
- **Screen→world (3A) reused, not rebuilt.** `CanvasTransform.screenToWorld` is
  already the single source of truth for the world↔screen mapping (renderer
  decision C6) and is already unit-tested, so SP1 adds no parallel transform.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceLayout.swift` — `flowIn` origin refactor +
  `centeredOn:` overload + `boundingBox(_:)`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift`,
  `AtelierRefs/AtelierRefs/IngestionModel.swift` — `flowIn` callers updated
  (`startY:` → `originY:`); behaviour unchanged.
- `AtelierRefs/AtelierRefs/CanvasDropRouter.swift` — new pure router.
- `AtelierRefs/AtelierRefsTests/SpaceLayoutTests.swift` — updated existing
  flow-in tests, added centred-flow + bounding-box suites.
- `AtelierRefs/AtelierRefsTests/CanvasDropRouterTests.swift` — new exhaustive
  route matrix.

## Migration notes

None. `flowIn`'s rename is internal (both callers updated in the same change);
the below-content behaviour is byte-identical (`originX` defaults to 0). No schema
change. `CanvasDropContents`/`CanvasDropRoute` are new app-internal types with no
callers yet — SP2 (library drag) wires the AppKit destination to them.
