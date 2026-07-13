# 086 — Spaces: core entity (005-E1)

First-class **Spaces** in `AtelierCore` — the schema + domain + services + tests
that back the Spaces redesign. No UI here (that is 004/E2); this is the pure
core, fully test-covered, that the app layer builds on.

A Space is its own entity (decision O1) — not a folder: no nesting, no protected
default, no membership dedup. One **discriminated** `space_item` table serves
both ASSET placements (`kind='asset'`, `asset_id` set) and freeform ELEMENT rows
(`kind='frame'/'text'`, `asset_id` NULL, `style` JSON) — the latter wired later
by E3, but validated now.

## Summary

- **Schema v4** (append-only migration): `space` + `space_item` tables + two
  indices. `space_item.space_id` CASCADEs; `space_item.asset_id` is nullable and
  CASCADEs, so deleting an asset vacates ONLY its asset rows and leaves element
  rows untouched. `space.cover_asset_id` SET NULLs on asset delete (mirrors
  `collection`). Geometry (`x/y/w/h/z`) is NOT NULL — every board row has a rect.
- **Domain types**: `Space`, `SpaceItem`, `SpaceItemKind` (`asset`/`frame`/`text`),
  and `ElementStyle` (Codable, with `jsonString()` / `init?(jsonString:)` helpers;
  stored as JSON TEXT in `space_item.style`).
- **Services** (through the existing write/read funnel): `createSpace`,
  `renameSpace`, `deleteSpace`, `listSpaces`, `getSpace`, `setSpaceCover`,
  `addAssetToSpace`, `addElement`, `setSpaceItemPlacement`, `updateSpaceItemStyle`,
  `removeSpaceItem`, `spaceItems(in:)` (LEFT-joined board read → `SpaceItemDetail`).
- **Gallery read** (for 004-P2): `collectionCovers(_:)` → `[UUID: blobHash]`.
- **Validation**: `Validation.spaceName` (trim/reject-empty) and
  `Validation.spaceItem(kind:assetID:)` (the discriminator invariant), plus a new
  `AtelierError.invalidSpaceItem` case.

## Files changed

- `Sources/AtelierCore/Domain/Space.swift` (new)
- `Sources/AtelierCore/Domain/SpaceItem.swift` (new — `SpaceItem`, `SpaceItemKind`, `ElementStyle`)
- `Sources/AtelierCore/Persistence/Space+GRDB.swift` (new)
- `Sources/AtelierCore/Persistence/SpaceItem+GRDB.swift` (new)
- `Sources/AtelierCore/Persistence/Migrator.swift` (v4 migration + `registeredIdentifiers`)
- `Sources/AtelierCore/Persistence/LibraryDatabase.swift` (`SpaceItemRow`)
- `Sources/AtelierCore/Services/ServiceTypes.swift` (`SpaceItemDetail`)
- `Sources/AtelierCore/Services/Validation.swift` (`spaceName`, `spaceItem`)
- `Sources/AtelierCore/Services/AtelierError.swift` (`.invalidSpaceItem`)
- `Sources/AtelierCore/Services/AppServices.swift` (Spaces surface + `collectionCovers`)
- `Tests/AtelierCoreTests/MigrationTests.swift` (v4 shape / cascade / round-trip suites; pinned `v4`)
- `Tests/AtelierCoreTests/ServicesSpaceTests.swift` (new — full service coverage)

## Notes / gotchas

- **GRDB optional-join chaining**: `spaceItems(in:)` joins asset (OPTIONAL, for
  element rows) then source. GRDB fatal-errors on a *required* association behind
  an *optional* one, so the nested source join is also `optional`. An asset row's
  source is NOT NULL by schema (C6), so it is still populated for every asset row.
- Append-only rule respected: v4 is a new identifier; v1–v3 bodies untouched. The
  pinned migration-identifier test was extended to `["v1","v2","v3","v4"]`.

## Migration notes

Append-only, additive. Existing databases gain the two empty tables on next open;
no data backfill. The dormant `collection_item.canvas_*` columns are left as-is —
there is **no** automatic migration of folder canvas layouts into spaces (an
opt-in "New Space from this collection" action, added in E2, is the escape hatch).

## Tests

`swift test` in `AtelierCore` — 223 tests pass, including the new v4 migration
suites (schema shape, FK/cascade — delete-space cascades all rows, delete-asset
vacates only asset rows, cover SET NULL — and record round-trips) and
`ServicesSpaceTests` (CRUD, placement/discriminator validation, add-twice,
move/remove/restyle, ordering, cover) + `collectionCovers`.
