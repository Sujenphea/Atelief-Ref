# 003 — Multi-Kind Items: Tweet / Link / Color as First-Class Kinds

> Covers the "Save" group: **tweet**, **links**, **colors** (**images** are done; video
> too). The structural epic of the feature set: today every asset is a blob. Settled
> direction (user): a true multi-kind, mymind-style library — not screenshot-plus-
> metadata approximations.

## Current state

- `asset.kind ∈ {image, video}` and **every byte column is NOT NULL**
  (`Migrator.swift:86–101`; non-optional fields in `Asset.swift`). Every asset
  RESTRICT-references a `source` — provenance can never be null.
- Grid renders `detail.asset.blobHash` unconditionally (`LibraryView.swift:207–210`);
  detail switches on kind with only image/video arms (`ItemDetailView.swift:105–125`).
- Dedup (18A) is byte-based: `blob_hash` + (`original_url` | `platform`)
  (`AppServices.findDuplicate:912–932`).
- FTS5 covers `source(title, author_handle, author_name)` only (`Migrator.swift:181–186`).
- The pipeline **requires decodable media bytes** and never throws
  (`IngestPipeline.swift:84–194`).
- The extension **already harvests tweet substance**: text/author/tweet-id land in
  `source.title`/`raw_metadata` (`extractors/twitter.js:47–56`,
  `bulk-twitter.js:98–133`) — but only as a byproduct of saving the image.

## Options

### O1 — "Media-less asset": extend `asset.kind`, byte columns become nullable — recommended
Add kinds `tweet | link | color`; a media-less asset has `blob_hash IS NULL`; kind
content lives in a new nullable `asset.payload` JSON column.

- ✅ **Maximally DRY** — one Asset, one CollectionItem, one grid/canvas/detail, one
  ingest funnel, one ledger. Everything that keys on `asset.id` (membership, placement,
  manual order, tags, jobs, delete/GC) works **unchanged**.
- ✅ Existing image/video rows untouched (columns stay populated).
- ❌ `Asset.blobHash: String → String?` ripples through every consumer — wide but
  mechanical, and the compiler finds every site (a feature, per "handle every case").

### O2 — Item/asset supertype split
New `item` table becomes what collections contain; `asset` stays blob-only; a tweet-item
owns 0..n asset children.

- ✅ Conceptually clean; `asset` keeps its non-null guarantee; models "tweet with 3
  images" naturally.
- ❌ **Rename-the-world**: `collection_item.asset_id`, every read join
  (`collectionItems`/`searchAssets`/`getAsset`, `AppServices.swift:489–588`), the view
  layer, and the ledger all reference asset. A rewrite of the read layer for three
  kinds — premature abstraction by the user's own standard. **Rejected.**

### O3 — Parallel per-kind tables
Three of everything: ingest paths, joins, renderers, dedup rules. Anti-DRY. **Rejected.**

## Recommendation — O1, with these concrete calls

- **Payload lives on `asset.payload`** (new nullable JSON TEXT), NOT in
  `source.raw_metadata` — provenance and content stay separate concerns.
- **Nullable bytes via a proper table rebuild**, not sentinel values (`blob_hash=''`,
  dims 0): sentinels bake a lie into the data and defeat compiler-guided auditing. A
  12-step SQLite rebuild (new table → copy → drop → rename, preserving FKs/indices) in a
  new append-only migration satisfies the never-edit-shipped-bodies rule.
- **One exhaustive `AssetContent` enum** computed from `(kind, blobHash, payload)` —
  `.image/.video/.tweet/.link/.color` — so views switch **once** instead of nil-checking
  bytes everywhere. This is the seam that keeps nullable columns from leaking branches
  across the app.
- **Kind-aware dedup**: new nullable `asset.dedup_key` (tweet-id / normalized URL /
  canonical hex, e.g. `#FFF → #ffffff`). `findDuplicate` branches: blob kinds keep
  blob+source matching; media-less kinds match `(kind, dedup_key, source)`.
- **Content search**: new FTS5 `asset_fts` over a `search_text` column (tweet text, link
  title+description, color name), wired like `source_fts`. Keeps provenance-FTS and
  content-FTS separate; `searchAssets` unions/branches (see
  [007](./007-search-sort.md) — coordinate).
- **Thumbnails**: a link's og:image / a tweet's card image is stored as the asset's
  **own `blob_hash`** when available — the grid renders it for free; `payload` carries
  the structured content. Color has no blob → grid renders a swatch from `payload.hex`.
  (Rejected for v1: a separate `thumbnail_hash` column — honest but adds a second blob
  reference path; revisit if "primary asset has no bytes" purity ever matters.)

## Schema / migration impact (the next free migration slot — do NOT hard-code "v4"; see sequencing note below)

- Rebuild `asset` with: byte columns nullable, + `payload TEXT NULL`,
  + `dedup_key TEXT NULL`, + `search_text TEXT NULL`; preserve all FKs/indices; add
  `asset_fts` (FTS5, synchronized) + an index on `dedup_key`.
- New kind cases in `AssetKind`; `Validation` grows per-kind branches (byte kinds require
  blob+dims; media-less kinds require payload and forbid blob; color hex validity; link
  URL validity; non-empty tweet).
- Append the new identifier to `Migrator.registeredIdentifiers` + the pinned migration
  test list.

**Migration sequencing (cross-doc):** this rebuild, [005](./005-spaces.md)'s space
tables, and [007](./007-search-sort.md)'s columns are three separate append-only
migrations, numbered by actual ship order. Take an [008](./008-backup.md) snapshot
before each once snapshots exist — this rebuild is the single riskiest migration in the
roadmap and is the strongest argument for shipping 008's snapshot early.

## Pipeline & capture changes

- Sibling entry point `ingestContent(_ draft:)` (skips hash/blob/thumbnail stages, goes
  straight to `services.ingest` with a media-less draft). New fold-not-throw failures:
  `.missingPayload`, `.invalidColor`, `.invalidLinkURL`, `.emptyTweet` — one bad item
  never aborts a batch (existing contract).
- **Extension**: `CaptureDTO` gains optional `kind` + `payload`; `CaptureRoutes` branches
  bytes-present → existing path, content-only → `ingestContent`. The harvest→extract→POST
  spine is unchanged. The `web` extractor's OpenGraph output becomes a **link** item;
  `twitter.js`'s existing text/author harvest becomes a **tweet** item. Later, the bulk X
  sweep produces tweet items instead of bare images — the big payoff.
- **App**: paste `#RRGGBB` / color-picker drop → color item; pasted page URL →
  [001](./001-capture-link-resolution.md)'s resolver → link item (og:image as blob,
  title/description/favicon in payload).

## Phased implementation (recommended order: color → link → tweet)

1. **C0 (L) — core seam.** The migration rebuild, `AssetKind` cases, `blobHash: String?`
   + `payload`, `AssetContent`, per-kind `Validation`, `ingestContent`, kind-aware
   `findDuplicate`, orphan-GC branch (`deleteAssets`, `AppServices.swift:388–391`),
   `asset_fts`. Pure core, fully testable before any UI.
2. **C1 (S) — color.** Simplest kind: zero network, no thumbnail, no extension change.
   Proves the entire media-less path end-to-end (ingest → grid swatch → detail arm →
   dedup by hex). Ship first.
3. **C2 (M) — link.** Depends on 001's `PageResolver` (og:image, title, description,
   favicon). Grid shows the og:image thumbnail; detail shows a link card + open action.
   Extension `web` captures become links.
4. **C3 (M–L) — tweet.** Richest payload (text, entities, media). Resolve the
   media-children question first (below). Extension single + bulk X capture emit tweet
   items.

## Test strategy

- **Migration (hardest-tested code in the epic):** upgrade fixture asserting existing
  image/video rows survive **byte-identical**, FKs/indices preserved, identifier pinned.
- Core: `AssetContent` mapping for every `(kind, blob, payload)` combination; per-kind
  validation matrices; `ingestContent` dedup (same tweet-id/URL/hex → dedup, different →
  new); `asset_fts` search over tweet text + link title; mixed-batch `deleteAssets`;
  media-less orphan GC (nothing to reclaim, no crash).
- Wire: `CaptureDTO` decode matrix for `kind`/`payload` (malformed cases,
  `CaptureDTO.swift:198–219`); `CaptureRoutes` content branch.
- Extension: `web`→link mapping, tweet→content-capture mapping (`node --test`).

## Effort: **XL overall** (C0 = L; kinds S/M/M–L) — but phaseable; color ships early and de-risks everything after

## Risks & edge cases

- **The table rebuild** — copy/FK/index preservation must be exact; test the upgrade
  path hard.
- `blobHash` optionality touches every asset reader: grid, detail, canvas, delete's
  mime/hash tracking, thumbnail cache (`LibraryView.swift:430–446`), cover logic.
  Compiler-guided, but budget the sweep.
- Dedup normalization is policy: URL canonicalization (trailing slash, `utm_*`
  stripping — how aggressive?), hex canonicalization, tweet-id extraction from URL
  variants.
- Two FTS tables must compose in `searchAssets` without breaking keyset paging.
- Text-only tweets need a designed grid card (only kind with neither blob nor swatch).

## Settled decisions

- Multi-kind, first-class (user). O1 media-less asset. Rebuild over sentinels
  (recommended here; confirm at implementation kickoff). Kind order color → link → tweet.

## Open questions

1. **Tweet media children** — RESOLVED (C3, changelog 112): media live in
   `payload.media[]` as URL references (DRY, one row per tweet, zero schema
   change). The "real asset children via `parent_asset_id`" model was rejected for
   v1 (reintroduces a local supertype); revisit only if per-image tag/place/dedup
   is wanted.
2. URL canonicalization aggressiveness for link dedup — RESOLVED (C2a, changelog
   111): "moderate" (scheme/host/fragment/port/trailing-slash + fixed tracking-
   param strip; other query params & path case untouched).
3. Color: single hex v1 (recommended) or palettes — RESOLVED (C1): single hex v1;
   palettes are a later additive `swatches: [String]?` on `ColorPayload`.

## Status (2026-07)

- ✅ **C0** core seam · **C1** color · **C2a** link (structural) · **C3** tweet
  (structural) · **C3 wire** server + ingestion content-capture path — all shipped
  (changelogs 109–113). Plan record: `.docs/025`.
- ⏳ **C3 extension JS** — the browser side that PRODUCES content captures:
  `twitter.js` → tweet `payload`, `web` extractor → link `payload`, bulk X sweep
  → tweets. `CaptureDTO.kind`/`payload` + the `CaptureRoutes` content branch are
  built and unit-tested (113); this is the JS + node-test follow-on, plus a
  content fixture for `capture-contract.json`.
- ⏳ **C2b** link resolver enrichment (= 001 `PageResolver`, SSRF-hardened) —
  deferred; the security-sensitive piece.
