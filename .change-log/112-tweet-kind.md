# 112 — Tweet kind, structural (003 · C3)

The third and richest media-less kind. A saved tweet is a first-class item —
grid card, detail card with an Open-on-X action, dedup by tweet id — built
structurally on 109's seam, mirroring how color (C1) and link (C2a) went
core-first. **No network:** the tweet's media are URL references, not fetched
bytes; a captured card image is optional and fills in later.

## The modelling call (003 · open Q1 resolved)

Tweet media live in **`payload.media[]` as URL references**, NOT as first-class
asset children (no `parent_asset_id`). One `asset` row per tweet; its images /
video are references carried in the payload — they are not separately taggable /
placeable / dedupable assets. Chosen for DRY-ness and zero schema change; the
richer "real asset children" model was considered and rejected for v1 (it
reintroduces a local supertype). Revisit only if per-image organization is
wanted.

## What ships

- **`TweetPayload`** (`tweetID` / `text` / `authorHandle` / `authorName` /
  `media: [TweetMedia]`) on `AssetPayload`, plus **`TweetMedia`** (url / w / h).
  - **`TweetPayload.canonicalTweetID`** — extracts the numeric id from a bare id
    or a status URL (`/status/`, `/statuses/`, query / fragment / `/photo/1`
    suffix, `x.com` vs `twitter.com`), so the same tweet captured different ways
    yields ONE dedup key.
  - **`TweetPayload.canonicalTweetURL(id:)`** — a deterministic permalink
    (`https://x.com/i/status/<id>`) used as the provenance `original_url`.
- **`AssetContent.tweet(TweetContent)`** — the render projection carries text /
  author / media references + the asset's own `blobHash` as an optional card
  image (nil until captured → the grid draws a text card).
- **`ingestContent` for tweets** — the numeric tweet id is the dedup key, and the
  funnel aligns the provenance `original_url` to the canonical permalink, so a
  tweet captured via `x.com`, `twitter.com`, or with a tracking param collapses
  to one asset. `searchText` = text + author, so a tweet is findable by content
  or by who wrote it. New error `.emptyTweet` (no usable id, or no substance —
  neither text nor media). The `effectiveSource` alignment (added for links in
  C2a) now generalizes over link + tweet.
- **Validation** — a tweet requires a usable id AND substance (text or ≥1 media);
  a whitespace-only text with no media is rejected; a media-only tweet is fine.
- **UI** — grid `TweetCardTile` (speech-bubble glyph + `@handle` + text snippet +
  a media-count badge); detail `TweetDetailView` (author line, text, media
  references as openable rows, a prominent **Open on X** to the permalink; card
  image shown once captured).

## Files changed

- Core: `AssetPayload.swift` (`TweetMedia` / `TweetPayload`), `AssetContent.swift`
  (`TweetContent` + `.tweet` mapping), `Validation.swift` (`.tweet` branch +
  `tweetID`), `ServiceTypes.swift` (`.tweet` factory), `AtelierError.swift`
  (`.emptyTweet`), `AppServices.swift` (generalized provenance alignment).
- App: `SharedThumbnail.swift` (`TweetCardTile` + `.tweet` grid arm),
  `ItemDetailView.swift` (`.tweet` media arm + `TweetDetailView` + `.tweet`
  decode arm).

## Tests

Core **305** green (+11): `TweetPayload.canonicalTweetID` matrix (bare id /
status URL / `x.com`-vs-`twitter.com` collapse / rejection) + `canonicalTweetURL`;
`AssetContent` tweet mapping (bare vs card-image-captured, missing / malformed);
tweet payload round-trip; `ingestContent` tweet ingest / id-canonical dedup /
`.emptyTweet` (no id, empty substance) / media-only accepted / search-by-text-
and-author. App unit bundle green; Ingestion + Server rebuild clean.

## Migration notes

None — rides on v6 (109). No schema change: a tweet is an `asset` row with
`kind='tweet'`, nil bytes, a `payload` JSON (text / author / `media[]`), and
`dedup_key` = numeric tweet id.

## Remaining (003)

- **C2b — link resolver enrichment** (= 001 P1): a SSRF-hardened page fetch fills
  a link's title / description / og:image (and could fill a tweet's card image /
  media dims). Still the security-sensitive piece; deferred.
- **C3 extension wiring** — the structural kind is complete and rendered, but no
  in-app gesture *creates* a tweet yet (a tweet isn't typed by hand). The natural
  producer is the extension's single + bulk X capture: `CaptureDTO` gains
  `kind` / `payload` and `CaptureRoutes` branches content-only captures into
  `ingestContent`. That wire-level work is the follow-on that lands real tweets.

The `003-multi-kind-items.md` feature doc stays live for those.
