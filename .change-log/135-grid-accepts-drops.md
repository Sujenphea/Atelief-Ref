# 135 — Grid accepts dropped assets (dropzone removed)

## Summary

Removed the explicit dashed **dropzone** from `CollectionView` and made the whole
collection pane a drop target: a Finder file, a browser image, or a dragged web
URL dropped anywhere on the collection now imports into it. Import progress/status
moved from the dropzone into the header. Per-tile drag-to-reorder is unchanged.

The core risk this surfaced — an external drop landing *on a tile* could be
captured by the tile's reorder drop target and silently lost — is fixed **by
type**: the reorder drag now carries a distinct `AssetDragPayload` (`Transferable`)
instead of a bare `String`, so external image/file/URL content never matches a
tile's drop target and falls through to the collection's container `.onDrop`.

## Changes

- **New `AssetDragPayload`** (`AtelierRefs/AtelierRefs/AssetDragPayload.swift`): a
  minimal single-`assetID` `Codable`/`Transferable` payload for the intra-app grid
  reorder drag. Tiles now `.draggable(AssetDragPayload(...))` +
  `.dropDestination(for: AssetDragPayload.self)`.
- **`CollectionView`**: deleted the `dropZone` view; attached
  `.onDrop(of: [.image, .fileURL, .url])` to the whole `content` pane with the
  targeting highlight as a scoped `.overlay` border (only the overlay redraws on
  hover, not the grid); relocated the progress bar + status line into the header;
  added a shared `dispatch(inputs:orWebURL:undecoded:)` helper used by both
  `paste()` and `handleDrop()`.
- **`DirectInputReader`** (`AtelierIngestion`): added
  `inputs(from providers:into:now:) -> DroppedProviders`, moving the drag
  provider-decoding logic (`input`/`firstWebURL`/`loadURL`/`loadData`) out of the
  View and next to the existing pasteboard decoder — one tested seam for both
  paths. It also returns an `undecodedCount` so a mixed drop with unreadable items
  reports "Imported N, M couldn't be read" instead of dropping them silently.
- **`IngestionModel.run`** gained an optional `undecoded:` argument (defaults to 0,
  all existing callers unchanged) and a `nonisolated static importStatus(...)`
  helper that composes the completion status (imported + failed + unreadable
  clauses). Reload behavior is unchanged.

## Tests

- New `AssetDragPayloadTests` (app target): `Codable` JSON round-trip + inequality.
- New `ImportStatusTests` (app target): the four `importStatus` compositions (7A).
- New `DirectInputReaderProvidersTests` (`AtelierIngestion`): mirrors the pasteboard
  suite for the drag path — file URL → `.localDrag`; image → `.localPaste`; image +
  page URL → `.web`; bare web URL → `webURL` fallback; empty → empty; plain text →
  undecoded; mixed image + unreadable → 1 input + undecoded count.
- All `AtelierIngestion` (18) and the touched `AtelierRefsTests` suites pass; app
  target builds clean.

## Migration notes

- **Grid drag payload type changed** from `String` (asset UUID string) to
  `AssetDragPayload`. Any future drop target that expected the old `String` reorder
  payload must switch to `AssetDragPayload`. This is the single-asset seed of the
  multi-select `AssetDragPayload` planned in
  `.docs/feature-todo/009-multiselect-move.md`.
- **Transfer representation rides on `.json`**, not a bespoke exported UTI: the app
  builds its Info.plist via `GENERATE_INFOPLIST_FILE`, which can't declare a
  `UTExportedTypeDeclarations` array. `.json` is already non-overlapping with the
  external drop types (`.image`/`.fileURL`/`.url`) and plain text, so it preserves
  the type-separation guarantee with no plist work.

## Manual verification (drag routing — not unit-testable)

Launch the app, open a collection, and confirm each cell:

| Drag source        | Dropped on a tile | Dropped on a gap |
|--------------------|-------------------|------------------|
| Finder image file  | imports           | imports          |
| Browser image      | imports (`.web`)  | imports (`.web`) |
| Browser web URL    | imports as link   | imports as link  |
| Internal reorder   | reorders          | no-op            |

Also confirm: the header shows progress during an import; an empty collection still
accepts a drop; a mixed drop containing an unreadable item reports the count.
