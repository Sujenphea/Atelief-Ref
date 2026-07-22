# 199 — Home Spaces section + shared fan card

## Summary

Home is now a two-section overview: **Collections** (the fanned stack cards landed
earlier) and, below, **Spaces** — which get the same fanned "stack" preview, backed by a new
per-space thumbnail read. The fan card is generalized so both entity types render
through one component. The Spaces section is hidden until the user has a space, so a
fresh library stays collection-focused.

Decisions (confirmed with the user): Collections-then-Spaces order; the space fan
shows the space's most-recently-added assets; one shared card for both.

## Files changed

### Core
- `ServiceTypes.swift` — new `SpaceStackPreview` (space + item count + newest blob
  hashes), the space analog of `CollectionStackPreview`.
- `AppServices.swift` — new `spaceStackPreviews(limit:)`: one window-function query
  over `space_item JOIN asset` ordered `created_at DESC, id DESC`, plus a count
  per space. Element rows (NULL `asset_id`) and media-less assets are counted but
  fan no thumbnail — mirroring the collections read.
- `ServicesSpaceTests.swift` — added `stackPreviews`: counts every row, fans asset
  hashes, skips element rows, empty space fans nothing.

### App
- **New** `FanCard.swift` — the entity-agnostic fanned card (title / count / seed /
  hashes / placeholder glyph), plus the pure `fanRotations` helper. Replaces the
  collection-specific `CollectionFanCard`.
- **Deleted** `CollectionStackCard.swift` — folded into `FanCard.swift`.
- `IngestionModel.swift` — added `spaceStackPreviews: [UUID: SpaceStackPreview]` +
  `refreshSpaceStackPreviews()`.
- `CollectionsGalleryView.swift` — rebuilt as the Home overview: `collectionsSection`
  + `spacesSection`, each a labeled grid of `FanCard`s (with a `CoverCard` pre-load
  fallback). Space cards open on tap and carry a Rename / Delete context menu
  (delete routes through the app-global `pendingSpaceDeletion` confirmation). Dropped
  the file's dead `showNewCollection` state (creation lives in the sidebar "+").

## Migration notes

- `FanCard` is shared: collections pass `accent`/`tray`/`folder`; spaces pass the
  `square.on.square.dashed` glyph. Same chrome as `CoverCard`, so the grid is uniform.
- `SpacesListView` remains unrouted/unused (out of scope); Home is the spaces overview.

## Verification

- `xcodebuild -scheme AtelierRefs build` → **BUILD SUCCEEDED**.
- Core: full suite → **425 tests pass** (incl. the new `spaceStackPreviews` test and
  the existing `collectionStackPreviews` suite).
- KNOWN PRE-EXISTING: the `AtelierRefsTests` target still won't compile
  (`NavModelTests` calls a removed `NavModel.openSpaces()` API), so `FanRotationsTests`
  can't run through it; `fanRotations` is byte-identical to its prior passing version.
