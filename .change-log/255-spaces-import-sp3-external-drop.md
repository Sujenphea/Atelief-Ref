# 255 — Spaces import: SP3 external drop (Finder / browser)

Phase SP3 of the [059 import-into-spaces plan](../.docs/059-spaces-import-plan.md) —
dragging files / images / a web URL from Finder or a browser onto an open Space
canvas ingests them into Unsorted and places them centred on the drop point.

## Summary

- **One ingest core (1A/2A).** Extracted the awaitable
  `IngestionModel.importInputs(_:undecoded:) async -> [Asset]` — runs the batch
  through the coordinator, drives `progress`/`status`, and RETURNS the
  dedup-resolved assets (collapsed by id, so a same-file-twice drop yields one
  asset — 059 · Q2). `run()` (the grid fire-and-forget path) is now a thin wrapper
  that awaits it then reloads the folder; the canvas awaits it then places.
- **Awaitable remote URL (SP3).** Split `resolveLinkAndIngest` into an
  input-producing `resolveLinkInput`; added `importRemoteURL(_:into:) async ->
  [Asset]` (download an image URL, or resolve a page → link) so a dragged URL
  ingests-and-returns for placement, sharing one resolution with the grid path.
- **Import-and-place seam (10A).** `SpaceModel.importAndPlace(at:ingest:)` runs the
  injected ingest step OFF the serial write chain (a slow download never freezes
  board edits), then enqueues the fast placement when assets are ready. The
  injectable `ingest` closure makes ingest→place unit-testable with a fake.
- **Drop wiring (4A/8A) + self-ingest guard.** SpaceView now registers the file /
  image / URL types too. An `.assetIDs` drag is treated as a PLACEMENT ONLY (never
  external) — an internal drag also carries file promises since drag-out (011), and
  re-ingesting our own promised file would duplicate the asset (mirrors
  `CollectionView.handleDrop`'s guard). External content decodes via the shared
  pasteboard path (`DirectInputReader.inputs(from:pasteboard)` + `firstWebURL`),
  identical to paste (SP4 will reuse it).
- **Shared web-URL reader (DRY).** Extracted `CollectionView.firstWebURL` into
  `ImportPasteboard.firstWebURL(on:)` + a cheap `hasImportableContent(on:)` for the
  hover-accept decision (no byte reads per tick).
- **Reporting (5A).** Extracted the floating import-progress pill into the shared
  `ImportProgressPill`; the board now shows the SAME live batch progress the grid
  does, driven by the shared `IngestionModel.progress`.

## Known limitation

A drop that is a FILE PROMISE only (no bytes / URL on the drag pasteboard — rare;
some Photos / sandboxed-app drags) is reported as unreadable rather than resolved,
since the AppKit destination decodes the pasteboard, not async `NSItemProvider`s.
Finder file drops and browser image/URL drags (the common cases) carry usable
pasteboard types and import fine.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `importInputs`, `run` refactor,
  `resolveLinkInput` split, `importRemoteURL`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `importAndPlace(at:ingest:)`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — external-drop wiring + progress overlay.
- `AtelierRefs/AtelierRefs/ImportPasteboard.swift` — new shared web-URL / importable
  reader.
- `AtelierRefs/AtelierRefs/ImportProgressPill.swift` — new shared progress pill.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `firstWebURL` extracted;
  `importIndicator` → shared pill.
- Tests: `AtelierRefsTests/SpaceImportPlaceTests.swift` — `importAndPlace` seam
  (success / zero-results / space-deleted-mid-import / undo-keeps-asset).

## Migration notes

None. `run()` and the link-resolution path are behaviourally unchanged (the grid
import + `LinkResolutionTests` still pass). No schema change. Full `AtelierRefsTests`
target green.
