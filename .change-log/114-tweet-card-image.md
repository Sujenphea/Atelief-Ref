# 114 — Tweet card image (003 · C3 · Option 3, hybrid ingest)

A captured tweet now renders its **picture**, not a text card. Resolves the
"purely tweet cards?" question: with the pure media-less path a tweet had no
blob (text card forever, since nothing was scheduled to backfill it), which
defeats a visual reference library. Option 3 makes a tweet a **hybrid** — it
keeps its `kind`/`payload` content identity AND stores its card image as a real
blob, so the grid shows the image while dedup stays keyed on the tweet id.

This is the Swift boundary (core + ingestion + server); the extension JS that
POSTs a tweet with its card image lands separately (115).

## What ships

- **Core — `ingestContent(_:blob:…)`** gains an optional `ContentBlobFacts`
  (hash / mime / dims / size). When present the otherwise media-less asset ALSO
  fills its blob columns, so a tweet is `kind=.tweet` + `payload` + a real
  `blob_hash` (surfaced as `TweetContent.cardImageBlobHash`). Identity is
  UNAFFECTED — dedup is `(kind, dedup_key=tweet-id)`, so two captures with
  different card images resolve to one tweet (first capture wins; a later card
  image never overwrites an existing asset's blob). Blob facts are validated
  (dims / size / lowercased-hex hash) exactly like the byte path.
- **Ingestion — `IngestSource.contentWithBytes`** + `IngestInput(content:image:…)`
  and `DirectInputReader.remoteContentWithImage`. The pipeline runs the shared
  **blob-first (A2) + P14** storage stage for the picture, then persists via
  `ingestContent(_:blob:)`. Because dedup is by tweet-id (not bytes), a card
  image the funnel DISCARDS on dedup would orphan — so it is reclaimed (compared
  case-insensitively against the resolved asset's `blob_hash`). The byte and
  hybrid paths now share one `storeBytesBlobFirst` helper (DRY); the byte path's
  behaviour + phase-timing are unchanged.
- **Server — `decodeInput` routes a media-less kind carrying an `image`** to the
  new `.contentWithImage` (`DecodedContentImageCapture`); without an image it
  stays a pure text-card `.content`. `CaptureRoutes` branches it through the same
  coordinator (ledger / live-refresh / 7A relay shared). Base64 validation is
  factored into `decodeImageBytes` (shared by the image + hybrid paths).

## Files changed

- Core: `ServiceTypes.swift` (`ContentBlobFacts`), `AppServices.swift`
  (`ingestContent` blob param + validated insert).
- Ingestion: `IngestInput.swift` (`.contentWithBytes` + init),
  `IngestPipeline.swift` (`storeBytesBlobFirst` helper + `ingestContentWithBytes`
  + orphan reclaim), `DirectInputReader.swift` (`remoteContentWithImage`).
- Server: `CaptureDTO.swift` (`DecodedContentImageCapture` / `.contentWithImage`
  / `decodeContentWithImage` / `decodeImageBytes`), `CaptureRoutes.swift` (branch).
- Wire fixture: `capture-contract.json` gains a `contentCaptureRequest` (a tweet
  + card image) the Swift decoder now asserts (the JS producer joins in 115).
- Tests: core (tweet-with-card-image, dedup keeps the first image, invalid blob
  rejected), pipeline (blob + tiers on disk + tweet identity, dedup reclaims the
  orphan blob), decoder (`.contentWithImage` routing + malformed base64 + the
  contract fixture), routes (a tweet-with-image capture → blob-backed tweet).

## Tests

Core **308** (+3), Ingestion **94** (+2), Server **85** (+4). App target builds.

## Migration notes

None — no schema change. A tweet-with-card-image is the same `asset` row shape
(`kind` + `payload` + `dedup_key`) that now also has `blob_hash` / dims / mime
populated, which the schema already allowed.

## Remaining (003)

- **C3 extension JS** (115) — the browser producer that POSTs a tweet with its
  card image (this is the receiving boundary). Web→link stays on the image path
  until C2b, so links keep their thumbnail rather than regressing to text cards.
- **C2b — link resolver enrichment** (= 001 `PageResolver`, SSRF-hardened) —
  still deferred; it could also backfill a tweet's card image from `media[]`.
