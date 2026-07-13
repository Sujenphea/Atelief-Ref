# 025 — Multi-Kind Items · Plan (003 · C0 + C1 + C2a + C3 shipped)

Implementation record for feature 003 (multi-kind items). The roadmap +
option analysis lives in `.docs/feature-todo/003-multi-kind-items.md` (still
live — C2b resolver + C3 extension wiring remain); this captures the kickoff
decisions and what shipped in C0 (core seam) → C1 (color) → C2a (link) → C3
(tweet).

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

## C2a — link, structural (shipped, changelog 111)

- `LinkPayload` (url / title / description) + `canonicalURL` (moderate
  normalization: scheme/host lowercase, drop fragment/default-port/trailing-slash,
  strip `utm_*`/`fbclid`/`gclid`). `AssetContent.link(LinkContent)` carries the
  asset's blob as an optional og:image.
- `ingestContent` for links: canonical URL is the dedup key **and** the
  provenance `original_url` (aligned in the funnel); `searchText` = title +
  description + host. New error `.invalidLinkURL`.
- UI: grid `LinkCardTile`, detail `LinkDetailView` (Open Link), `AddLinkButton`
  toolbar → `IngestionModel.addLink`.
- **No network** — title/description/og:image enrichment is deferred to C2b (=
  001's `PageResolver`), which doesn't exist yet. A bare paste still saves a
  link keyed by its URL.

### Open Q2 resolved (link URL canonicalization)

**Moderate**: normalize scheme/host/fragment/port/trailing-slash and strip a
fixed tracking-param set; leave other query params and path case untouched.
Rationale: aggressive stripping (path case, all query) risks merging distinct
pages; this catches the common share-link duplicates without that risk.

## C3 — tweet, structural (shipped, changelog 112)

- `TweetPayload` (tweetID / text / author / `media: [TweetMedia]`) +
  `canonicalTweetID` (numeric id from a bare id or status URL — `x.com` /
  `twitter.com` / query / `/photo/1` collapse to one key) + `canonicalTweetURL`
  (deterministic permalink for provenance alignment). `AssetContent.tweet` carries
  the asset's blob as an optional card image.
- `ingestContent` for tweets: numeric id is the dedup key; the funnel aligns
  provenance `original_url` to the permalink (the C2a alignment generalized over
  link + tweet). `searchText` = text + author. New error `.emptyTweet` (no usable
  id, or no substance — neither text nor media). A media-only tweet is accepted.
- UI: grid `TweetCardTile`, detail `TweetDetailView` (Open on X).
- **No network** — media are URL references; a card image fills in later (C2b).

### Open Q1 resolved (tweet media children)

**`payload.media[]` URL references**, NOT first-class asset children — one row per
tweet, media carried as references. DRY, zero schema change; the richer "real
asset children via `parent_asset_id`" model was rejected for v1 (reintroduces a
local supertype). Revisit only if per-image tag/place/dedup is wanted.

## C3 wire — content capture path (shipped, changelog 113)

- `IngestInput` carries bytes OR content (`IngestSource` enum); the byte init is
  kept so all existing call sites are unchanged. `IngestPipeline` branches once —
  content skips every byte stage and goes to `ingestContent`. Both flow through
  the SAME coordinator (P2: no second queue), so onCapture / ledger / 7A relay are
  reused — the bulk-X payoff needs exactly this.
- Wire: `CaptureRequest.image` optional + new `kind` / `payload`; `decodeInput`
  routes media-less kinds → `.content` (new errors `.unknownKind` /
  `.missingContentPayload`, both 400). `CaptureRoutes` branches image vs content
  through one shared `ingest(_:)`.
- **Repaired C0 test-bundle drift**: C0 rebuilt only Ingestion/Server *sources*
  when `blobHash`/`mimeType` went optional; their *test* bundles had silently
  stopped compiling. Both are green again (byte tests unwrap via `#require`).
- Remaining for C3: the extension JS that PRODUCES content captures (tweet / link
  payloads, bulk X sweep) — the Swift boundary is ready to receive them.

## C3 card image — Option 3, hybrid ingest (shipped, changelogs 114 + 115)

Resolves "purely tweet cards?": the pure media-less tweet had no blob (a text
card forever, since nothing was scheduled to backfill it), which defeats a visual
library. Option 3 makes a tweet a **hybrid** — it keeps its `kind`/`payload`
content identity AND stores its card image as a real blob.

- **Core** — `ingestContent(_:blob:…)` gains an optional `ContentBlobFacts`; a
  tweet is `kind=.tweet` + `payload` + a real `blob_hash` (→
  `TweetContent.cardImageBlobHash`). Dedup is UNCHANGED — `(kind, tweet-id)` — so
  two captures with different card images resolve to one tweet (first wins; a
  later image never overwrites). No schema change.
- **Ingestion** — `IngestSource.contentWithBytes`: the pipeline runs the shared
  blob-first (A2) + P14 store for the picture, then `ingestContent(_:blob:)`.
  Because dedup is by tweet-id (not bytes), a card image discarded on dedup is
  reclaimed (it would otherwise orphan — the byte path never produces this, since
  there dedup implies the blob already existed). Byte + hybrid share one
  `storeBytesBlobFirst` helper.
- **Server** — `decodeInput` routes a media-less kind carrying an `image` →
  `.contentWithImage`; without an image it stays a text-card `.content`.
- **Extension (115)** — single X capture POSTs a `tweet` with its card-image
  bytes; `tweetContent(provenance)` builds the payload (`null` → plain image
  fallback). Bulk X and web→link are NOT switched (single-capture scope; web
  keeps its thumbnail until C2b).

### Q1 (tweet media children) → Option 3 for the CARD image

The `payload.media[]` URL-reference model (changelog 112) still stands for the
tweet's *attached* media. Option 3 is orthogonal: it stores the ASSET's own card
image as a blob so the grid has a thumbnail now. The two compose — `media[]` are
references; `blob_hash` is the card picture.

## Deviations from the roadmap doc

- **No `thumbnail_hash` column** (as the doc's v1 recommendation): a color has no
  blob; the grid draws a swatch from `AssetContent`. Revisit only if link/tweet
  card images want a blob path separate from the asset's own `blob_hash`.
- **Payload as an all-optional struct** (the `ElementStyle` idiom), not a
  discriminated Codable enum — `kind` is the discriminator, so adding link/tweet
  sub-payloads stays additive.

## Remaining

- **C2b — link resolver enrichment** (= 001's `PageResolver`, not yet built): a
  SSRF-hardened page fetch fills a link's title / description / og:image (and
  could fill a tweet's card image / media dims), upgrading the bare card to a
  rich one. The security-sensitive piece; deferred.
- **C3 extension wiring** — the tweet KIND is complete + rendered, but nothing
  in-app *creates* a tweet yet (a tweet isn't typed by hand). The producer is the
  extension's single + bulk X capture: `CaptureDTO` gains `kind` / `payload`,
  `CaptureRoutes` branches content-only captures into `ingestContent`. That
  wire-level work lands real tweets (and links from `web` captures).
- Board (canvas/space) rendering of media-less kinds is a defensive placeholder
  today; a first-class swatch/link/tweet tile is later polish.
