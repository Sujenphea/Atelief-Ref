# 025 — Multi-Kind Items · Plan (003 · C0 + C1 shipped)

Implementation record for feature 003 (multi-kind items). The roadmap +
option analysis lives in `.docs/feature-todo/003-multi-kind-items.md` (still
live — C2/C3 remain); this captures the kickoff decisions and what shipped in
C0 (core seam) + C1 (color).

## Kickoff decisions (confirmed at implementation)

1. **O1 media-less asset** — one `Asset`, nullable byte columns, kind substance
   in a `payload` JSON column. (Not O2's item/asset split.)
2. **Full table rebuild** over sentinel values — honest nullability; SQLite can't
   relax `NOT NULL` in place.
3. **Color v1 = single hex** — one canonical `#rrggbb` per color item; palettes
   are a later additive `swatches: [String]?` on `ColorPayload`, not a reshape.
4. Kind order **color → link → tweet** (color first: no network, no thumbnail,
   no extension change — proves the whole path).

## C0 — the core seam (shipped, changelog 109)

- `AssetKind` + `tweet`/`link`/`color` + `isByteBacked`.
- `Asset` byte columns → optional; new `payload` / `dedupKey` / `searchText`.
- `AssetContent` — the exhaustive render projection from `(kind, blobHash,
  payload)`; the single switch every view uses.
- `AssetPayload` / `ColorPayload` (+ `canonicalHex`).
- **Migration v6** — 12-step rebuild under GRDB deferred FK checks; `asset_fts`
  (content FTS) added alongside `source_fts` (provenance FTS).
- `ingestContent` (media-less sibling of `ingest`); `Validation.contentDraft`;
  kind-aware `findDuplicateContent`; `searchAssets` OR-combines the two FTS
  tables; `deleteAssets` reclaims blobs only for byte-backed assets.
- App-wide `blobHash`-optionality sweep behind `AssetContentThumbnail`.

## C1 — color (shipped, changelog 110)

- `AddColorButton` (toolbar) → `IngestionModel.addColor(hex:)` → `ingestContent`.
- Grid `ColorSwatchTile`; detail `ColorDetailView` + Hex row; blob actions
  disabled for media-less.
- Dedup by canonical hex.

## Deviations from the roadmap doc

- **No `thumbnail_hash` column** (as the doc's v1 recommendation): a color has no
  blob; the grid draws a swatch from `AssetContent`. Revisit only if link/tweet
  card images want a blob path separate from the asset's own `blob_hash`.
- **Payload as an all-optional struct** (the `ElementStyle` idiom), not a
  discriminated Codable enum — `kind` is the discriminator, so adding link/tweet
  sub-payloads stays additive.

## Remaining

- **C2 — link.** Depends on 001's `PageResolver` (og:image → blob, title /
  description / favicon → payload). Extension `web` captures become links. URL
  canonicalization policy for `dedupKey` is an open question.
- **C3 — tweet.** Richest payload. Resolve the media-children modeling question
  first (payload `media[]` vs real asset children via `parent_asset_id`).
- Board (canvas/space) rendering of media-less kinds is a defensive placeholder
  today; a first-class swatch/link/tweet tile is later polish.
