# 113 — Content capture wire (003 · C3 · server + ingestion)

The producer side of the media-less kinds. A capture POST can now carry a
`tweet` / `link` / `color` instead of image bytes, and it flows through the SAME
ingest coordinator as an image — so a (future) bulk X sweep of tweets gets the
same bounded concurrency, bulk-ledger recording, and live-refresh for free
(P2: no second queue). The extension JS that emits these captures is the
remaining follow-on; this is the Swift boundary, fully unit-tested.

## What ships

- **`IngestInput` carries bytes OR content** — new `IngestSource` enum
  (`.bytes(ByteSource)` / `.content(AssetContentDraft)`). The byte-source
  initializer is kept, so every existing factory / call site is unchanged;
  `IngestInput(content:…)` and `DirectInputReader.remoteContent(draft:…)` are the
  new media-less entries.
- **`IngestPipeline` branches once** — a content input skips every byte stage
  (hash / metadata / blob / thumbnail) and goes straight to
  `AppServices.ingestContent`; a rejected draft folds to
  `.failed(.persistence(…))` exactly like any other stage (C8 batch-safety).
- **Wire (`CaptureRequest`)** — `image` is now optional; new optional `kind` +
  `payload` (the `AssetPayload` the extension extracted). `CaptureDecoder`
  `decodeInput` routes: a media-less `kind` → `.content`, an absent / byte kind →
  the existing `.image` path. New decode errors `.unknownKind` /
  `.missingContentPayload` (both 400). The funnel stays the single content
  authority — decode only rejects the structurally unusable.
- **`CaptureRoutes.handleIngest`** branches image vs content, then runs BOTH
  through the shared `ingest(_:)` helper — so `onCapture`, the 7A job-status
  relay, and bulk-ledger recording are reused unchanged (a content item's
  ledger row simply has a nil `blobHash`).

## Repaired: C0 test-bundle drift

C0 (109) made `Asset.blobHash` / `mimeType` optional and rebuilt only the
Ingestion + Server *sources*, so their *test* bundles silently stopped
compiling (they pass `asset.blobHash` to `hasBlob(hash: String)`). This change
recompiles + fixes them: byte-asset tests unwrap with `try #require` (a
byte-backed asset always has a hash), and the `IngestSource` refactor updates the
`input.source` pattern matches. Both suites are green again.

## Files changed

- Ingestion: `Pipeline/IngestInput.swift` (`IngestSource` + content init),
  `Pipeline/IngestPipeline.swift` (branch + `ingestContent`),
  `Input/DirectInputReader.swift` (`remoteContent`).
- Server: `CaptureDTO.swift` (optional image, `kind`/`payload`,
  `DecodedContentCapture` / `DecodedInput`, `decodeInput`, new errors),
  `CaptureRoutes.swift` (content branch).
- Tests: `IngestPipelineTests` (content ingest + invalid-folds-clean; +C0-debt
  unwraps), `IngestCoordinatorTests` / `VideoIngestTests` / `DirectInputReaderTests`
  / `RemoteImageFetcherTests` (unwraps + `.bytes(…)` matches),
  `CaptureDecoderTests` (content routing matrix), `CaptureRoutesTests` (content
  persist / canonical-URL dedup / 422 invalid / 400 unknown-kind).

## Tests

Ingestion **92** green (+2 content), Server **81** green (+8: 4 decode + 4 route).
App unit bundle green; the cross-language capture-contract fixture still decodes
(the wire change is additive). Core unchanged (305).

## Migration notes

None — no schema change. A content capture becomes the same `asset` row
`ingestContent` already writes (kind, nil bytes, `payload` JSON, `dedup_key`).

## Remaining (003)

- **C3 extension JS** — the browser side that PRODUCES content captures:
  `twitter.js` emits a tweet `payload` (id / text / author / `media[]`), the
  `web` extractor emits a link `payload`, and the bulk X sweep posts tweets
  instead of bare images. The Swift boundary (this change) is ready to receive
  them; a content fixture should join `capture-contract.json` when it lands.
- **C2b — link resolver enrichment** (= 001 P1, SSRF-hardened) — still deferred.

The `003-multi-kind-items.md` feature doc stays live for those.
