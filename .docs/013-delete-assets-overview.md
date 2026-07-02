# 013 — Delete assets (overview)

## Context

Until now assets could be *added* (paste / drag / browser capture) and *removed
from a folder* only at the service layer (`AppServices.removeAssets`, never
surfaced in the UI). There was no way for a user to get rid of an asset, and no
code path ever deleted an on-disk blob or thumbnail — the `MediaStore` was
append-only. This feature closes that gap: users can remove an asset from the
current folder, or delete it from the library entirely (reclaiming its bytes).

## Decisions (confirmed with the user)

- **Two distinct operations** (the user chose "offer both"):
  - **Remove from Folder** — drops the asset's membership in the *current*
    folder only. The asset, its bytes, and its memberships in other folders are
    untouched. Non-destructive and instantly reversible (re-add), so it runs
    immediately with **no confirmation**. Backed by the existing
    `AppServices.removeAssets(_:from:)`.
  - **Delete** — removes the asset from the library *everywhere*: its `asset`
    row (cascading memberships, tag links, and clearing any folder cover), and —
    when no other asset shares them — its on-disk blob + thumbnail files. Because
    it is destructive it is gated behind a **confirmation dialog**.

- **Recoverability: system Trash** (the user's choice). Orphaned blob/thumbnail
  files are moved to the macOS Trash via `FileManager.trashItem`, not hard
  `removeItem`, so the actual media is recoverable even though the DB rows are
  gone.

- **Three surfaces** (all requested):
  - **Inspector** — a destructive *Delete* button (and a *Remove from Folder*
    button), acting on the selected item. Mirrors the existing action buttons.
  - **Library grid** — right-click context menu (*Remove from Folder* / *Delete*)
    plus the **⌫ / Delete** key on the selected thumbnail.
  - **Canvas** — single-click now *selects* a tile (new; the canvas previously
    only had double-click-to-play), with a selection highlight; right-click menu
    and the **⌫ / Delete** key act on the selection.

## Dedup-safety (the load-bearing invariant)

Assets are content-addressed and de-duplicated: multiple `asset` rows can share
one `blob_hash` (identical bytes, different provenance), and the `MediaStore`
keeps exactly one blob file + one thumbnail-per-tier per hash. So deleting an
asset must **never** delete a blob another asset still points at.

`AppServices.deleteAssets` therefore does reference counting *inside the delete
transaction*: after removing the target `asset` rows it reports a blob hash as
reclaimable **only** if `SELECT COUNT(*) FROM asset WHERE blob_hash = ?` is now
zero. Same idea for `source` rows (schema keeps them via `ON DELETE RESTRICT`
from `asset.source_id`): a source is garbage-collected only when its last asset
is gone. Tags survive (only the `asset_tag` join cascades), matching
`removeTag`'s "leave the tag row for other assets" behaviour.

## Layering (why the delete is split across packages)

`AppServices` lives in **AtelierCore**, which does not depend on
**AtelierIngestion** where `MediaStore` lives — so the DB layer cannot touch
files. The split:

1. **AtelierCore** — `AppServices.deleteAssets(_:) -> [OrphanedBlob]`. One write
   transaction: delete asset rows, GC orphaned sources, and **return** the
   reclaimable blobs as `OrphanedBlob { blobHash, mimeType }` (a public,
   `Sendable` DTO). Knows nothing about paths or files.
2. **AtelierIngestion** — `MediaStore.removeBlob` / `removeThumbnail` (low-level:
   compute the content-addressed URL, move it to the Trash, idempotent no-op if
   absent, return the trashed URL). `MediaReaper` composes them: for an
   `OrphanedBlob` it derives the blob extension from the mime type
   (`ImageMetadata.fileExtension(forMIMEType:)`, the same round-trip readers use)
   and trashes the blob plus every `ThumbnailTier` (`@<size>.jpg`). Best-effort:
   the DB delete already committed, so a leftover file is harmless disk, never a
   correctness problem.
3. **AtelierRefs (app)** — `IngestionModel` orchestrates: call
   `services.deleteAssets`, hand the returned orphans to `MediaReaper` **off the
   main actor**, then refresh the tree + reload the current folder. A single
   `pendingDeletion` state drives one confirmation dialog shared by all three
   surfaces.

## Selection model (canvas)

Selection is unified on the existing `IngestionModel.selectedItemID` (the
membership id already used by the inspector). A canvas single-click resolves the
tile → `CollectionItemDetail` and calls the same `model.select(_:)` the Library
grid uses, so the two tabs share one selection. `CanvasScreen` maps
`selectedItemID` back to a tile index and hands it to the renderer, which draws a
highlight border around that tile. The renderer stays app-agnostic: it exposes
`onSelectTile` / `onRemoveTile` / `onDeleteTile` closures and a `selectedTileID`,
and knows nothing about assets or folders.

## Out of scope (deferred)

- Multi-select on the canvas (single-select only for now).
- Undo inside the app (the system Trash is the recovery path).
- Bulk "empty folder" / "delete all". GC of orphaned *tag* rows.
- Reclaiming blobs orphaned by earlier code paths (there were none — this is the
  first delete path).

## Files

- **AtelierCore**: `Services/OrphanedBlob.swift` (new), `Services/AppServices.swift`
  (+`deleteAssets`), `Tests/…/ServicesDeleteTests.swift` (new).
- **AtelierIngestion**: `Media/MediaStore.swift` (+`removeBlob`/`removeThumbnail`),
  `Media/MediaReaper.swift` (new), `Tests/…/MediaReaperTests.swift` (new),
  `Tests/…/MediaStoreTests.swift` (+trash cases).
- **CanvasRenderer**: `Host/CanvasEngine.swift` (selection highlight),
  `Host/CanvasHostView.swift` (click/menu/key), `Host/CanvasView.swift` (params),
  tests.
- **AtelierRefs**: `IngestionModel.swift`, `CanvasContent.swift`,
  `InspectorView.swift`, `LibraryView.swift`, `CanvasScreen.swift`,
  `ContentView.swift`.

Changelog entries: `.change-log/041…` per checkpoint.
