# 023 — Inspector + preview + open-source (build-order #7)

## Summary

The per-asset **inspector**: select an image in the Library grid to see a large
preview, its intrinsic metadata, and its provenance — and act on the source
(open the original post, open the full-resolution file, reveal it in Finder,
copy the source link). This closes the MVP loop's viewing/open-source tail
(`.docs/009-mvp-status-overview.md`): you can now actually *look* at an imported
reference and get back to where it came from.

Presented as a native trailing `.inspector()` panel (macOS 26 API), toggleable
from the toolbar, with an empty state until an item is selected.

## What changed

- **Selection.** Grid thumbnails are now selectable (a Button per cell); the
  selected item shows an accent selection ring. Selection lives in
  `IngestionModel` keyed by the **membership id**, so it survives a contents
  reload and is pruned automatically when the item leaves the folder (folder
  switch or removal).
- **Preview.** The inspector shows the **1280-tier thumbnail** (already on disk),
  loaded **off-main** with a race guard (a stale load for a since-deselected item
  is dropped). No main-thread decode of a full-resolution original on selection.
- **Metadata** (no new DB read — reuses the grid's `CollectionItemDetail`):
  kind, dimensions, file size, MIME type, capture date; platform, author name /
  handle, title, original URL.
- **Source actions:** Open Original Source (browser), Open Full Resolution
  (blob → Preview), Reveal in Finder, Copy Source Link. Source-dependent actions
  disable when there is no `originalURL`.
- **Blob URL reconstruction.** New pure, unit-tested helper
  `ImageMetadata.fileExtension(forMIMEType:)` inverts the store-time extension
  derivation, so the app can rebuild a blob's content-addressed URL from the
  `Asset`'s persisted `mimeType` alone (the round-trip is exact via the one
  canonical `UTType`).

## Files changed

- `AtelierIngestion/Sources/AtelierIngestion/Imaging/ImageMetadata.swift` —
  add `fileExtension(forMIMEType:)`.
- `AtelierIngestion/Tests/AtelierIngestionTests/ImageMetadataTests.swift` —
  round-trip + known-mapping + unresolvable-MIME tests (suite now 62 tests, +3).
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — selection state
  (`selectedItemID`, derived `selectedItem`), off-main preview loader, stale-
  selection prune in `loadContents`, and `blobURL(for:)` / `openSource` /
  `openBlob` / `revealInFinder` / `copySourceLink` actions.
- `AtelierRefs/AtelierRefs/InspectorView.swift` — **new** inspector panel.
- `AtelierRefs/AtelierRefs/LibraryView.swift` — selectable thumbnails +
  selection ring, `.inspector()` attachment, toolbar toggle.

## Verification

- `swift test` (AtelierIngestion): **62 passed**.
- `xcodebuild -scheme AtelierRefs`: **BUILD SUCCEEDED**.
- SwiftUI (grid selection, inspector panel, actions) is **compile-verified only**
  — no runtime GUI test. A manual click-through remains pending.

## Migration notes

None. No schema change, no data migration; additive app + one additive public
helper in `AtelierIngestion`. The inline preview uses the existing 1280 thumbnail
tier, so no re-ingest is needed.
