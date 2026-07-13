# 109 — Multi-kind items: media-less core seam (003 · C0)

The structural foundation for a true multi-kind library (003 · O1): an asset no
longer has to be a blob. `image` / `video` stay byte-backed; new `tweet` / `link`
/ `color` kinds are **media-less** — their substance lives in a JSON `payload`,
their `blob_hash` is `NULL`. Pure Core + the app-wide nullability sweep; the
first user-facing kind (color) ships in 110.

## The seam

- **`AssetKind`** gains `tweet` / `link` / `color`, plus `isByteBacked` — the one
  place the byte-vs-content split is declared.
- **`Asset` byte columns are now optional** (`blobHash` / `mimeType` / `width` /
  `height` / `fileSize` → `?`), plus three new nullable fields: `payload` (kind
  substance as JSON TEXT), `dedupKey` (kind-aware dedup), `searchText` (content
  FTS).
- **`AssetContent`** — the exhaustive render projection computed from `(kind,
  blobHash, payload)`: `.image` / `.video` / `.color` / `.unknown`. Views switch
  on this ONCE instead of nil-checking bytes everywhere, so the now-nullable
  columns don't leak `if let blobHash` branches across the app.
- **`AssetPayload` / `ColorPayload`** — the all-optional-struct payload carrier
  (the `ElementStyle` idiom), with `ColorPayload.canonicalHex` (`#F0A` → `#ff00aa`,
  the dedup key).

## Migration v6 — the table rebuild

SQLite can't relax a `NOT NULL` in place, so this is the canonical 12-step
**table rebuild** (honest nullability over sentinel lies): new `asset` table with
nullable byte columns + `payload`/`dedup_key`/`search_text`, copy every existing
row byte-for-byte, drop, rename, recreate all v1/v5 indices + a `dedup_key`
index, and add `asset_fts` (FTS5 over `search_text`, synchronized). Runs under
GRDB's default **deferred foreign-key checks**, so the drop/rename is legal while
`collection_item` / `collection.cover` / `space` / `space_item` / `asset_tag`
reference `asset`, with a full `foreign_key_check` after. The riskiest migration
in the roadmap — tested with an upgrade fixture asserting image/video rows
survive verbatim.

## Ingest, dedup, search

- **`ingestContent(_:from:into:)`** — the media-less sibling of `ingest`: no
  bytes, born `.downloaded`, substance in `payload`. `Validation.contentDraft`
  normalizes per-kind (canonical hex) and derives `dedupKey` / `searchText`.
- **Kind-aware dedup** — `findDuplicateContent` matches `(kind, dedup_key,
  source)`; blob kinds keep blob+source matching.
- **Content FTS** — `searchAssets` now OR-combines provenance (`source_fts`) with
  content (`asset_fts`), so media-less items are findable by substance.
- New errors: `.invalidContentKind`, `.missingPayload`, `.invalidColor`.

## App-wide nullability sweep

`blobHash` optionality is compiler-guided across every consumer: the grid/search/
add-from-library thumbnails route through a new `AssetContentThumbnail` (swatch
for color, `AsyncThumbnail` for byte kinds, placeholder for `.unknown`); the
detail page media area + metadata switch on `AssetContent`; canvas/space
aspect-ratio + mime/blob-URL helpers guard nil; cover-lookup joins skip NULL
`blob_hash`; `deleteAssets` reclaims a blob only for byte-backed assets.

## Files changed

- Core: `Enums.swift`, `Asset.swift`, `AssetPayload.swift` (new),
  `AssetContent.swift` (new), `Migrator.swift`, `AppServices.swift`,
  `Validation.swift`, `ServiceTypes.swift`, `AtelierError.swift`.
- App: `SharedThumbnail.swift` (render seam + `Color(hexString:)`),
  `ItemDetailView.swift`, `CollectionView.swift`, `LibrarySearch.swift`,
  `AddFromLibrarySheet.swift`, `SpaceView.swift`, `CanvasContent.swift`,
  `SpaceContent.swift`, `SpaceLayout.swift`, `IngestionModel.swift`.

## Tests

Core **284** green (+25): migration v6 shape / content-FTS / **upgrade fixture**
(rows survive byte-identical, cascade/RESTRICT preserved); `AssetContent` mapping
matrix; `ColorPayload` canonicalization + payload round-trip; `ingestContent`
color ingest / dedup / validation matrix / content search / media-less delete.
Migration pin + `AssetKind` count + asset-column contract updated. App builds
clean; Ingestion + Server rebuild against the model change.

## Migration notes

v6 is append-only and additive to existing data — image/video rows are untouched
and gain three NULL columns. Take an 008 snapshot before applying (the roadmap's
strongest argument for shipping snapshots early). No API break: every existing
`Asset(...)` call site is source-compatible (non-optional args promote to
optional; new params default).
