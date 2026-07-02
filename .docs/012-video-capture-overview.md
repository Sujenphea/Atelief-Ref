# 012 — Video capture (store the actual video, poster tile, open-to-play)

## Context

The Chrome capture extension (build-order #6, [011](/.docs/011-capture-extension-overview.md))
saves an **image** per post. On a **video** tweet there is no still on Twitter's
servers — only a poster keyframe — so [032](/.change-log/032-twitter-video-frame-capture.md)
added an on-screen `<canvas>` frame grab. This feature goes further: capture the
**actual video file**, store it, show a poster tile on the canvas, and open it to
play.

## Why this is smaller than it looks (grounded in the code)

The data + storage layers are already medium-agnostic:

- **Ingestion accepts video today.** `ImageMetadata.classify` maps
  `.movie`/`.audiovisualContent` → a `.video` kind (`ImageMetadata.swift:114`);
  video is *not* rejected. `Asset` already carries `kind`, `mimeType`, `duration`
  (`Asset.swift:17–28`).
- **Storage is content-addressed** by SHA-256 + mime (`ContentHasher`,
  `MediaStore`) — it stores video bytes with no change.

So the model/storage work is nil. The real work is three gaps.

## The three gaps and the decisions

### 1. Transport (the one real risk)
`POST /ingest` is base64-image-inside-JSON, **50 MB cap**, whole body buffered in
one `Data` (`CaptureServer.swift:32,130`). A 200 MB video → ~266 MB base64 →
rejected at 50 MB; even uncapped it's a ~0.5 GB memory spike.

**Decision:** a **separate** `POST /ingest-video` route (reusing the auth+CORS
gate). Body is the **raw MP4** (`application/octet-stream`); provenance rides in an
`X-Atelier-Provenance` header (base64 JSON of the existing `ProvenanceDTO`). The
body is **streamed to a temp file** and ingested via a file-URL source, with a
larger cap (~512 MB). The image `/ingest` contract is left fully intact.

*Fallback:* if this FlyingFox version exposes only the whole-buffer `bodyData`,
buffer-then-write — same route/contract, just a transient memory cost.

*Rejected:* raising the cap on the existing base64/JSON route — it inflates the
payload ~33% and peaks at ~3× the video size in memory (JSON string + decoded
`Data`). Unfit for large video.

### 2. Poster frame
`ThumbnailGenerator` uses `CGImageSourceCreateThumbnailAtIndex`
(`ThumbnailTier.swift:65`) — nil for an MP4. **Decision:** branch on a video mime,
extract one poster `CGImage` via `AVAssetImageGenerator` from the stored blob, then
feed the *existing* JPEG thumbnail encoder. The whole tile/LOD engine
(`CanvasEngine.sync`) then works unchanged.

### 3. Display / playback
The canvas is a tiled CALayer **thumbnail** engine, not built for live
`AVPlayerLayer`s. **Decision (scope, confirmed with user):** poster tile + a ▶
badge overlay for `.video` assets + an **open action** → **QuickLook** preview of
the stored file (native, near-free). **Inline in-canvas playback is deferred** — it
would be a renderer rearchitecture + a scroll-performance problem, most of the cost
for marginal benefit over open-to-play.

### Source scope
Only **Twitter/X** video this pass — the MP4 is resolved via Twitter's syndication
API. Other sites keep their image behavior.

## Implementation plan (checkpoints — each committed with a changelog)

- **A — Server transport (`AtelierServer`).** New `/ingest-video` route: raw
  octet-stream body + `X-Atelier-Provenance` header, stream-to-temp-file, larger
  cap, ingest via file-URL source, map outcome → `CaptureResponse`. Decoder +
  route tests; auth negatives reused.
- **B — Ingestion factory (`AtelierIngestion`).** `DirectInputReader.remoteVideo(
  fileURL:provenance:into:)` over `ByteSource.fileURL`. Verify the `.video`
  classify path (no `unsupportedType`). Tests.
- **C — Poster thumbnail (`ThumbnailGenerator`).** Video-mime branch →
  `AVAssetImageGenerator` poster → existing JPEG encoder. Tested against a tiny
  sample MP4.
- **D — Canvas play affordance + open (`CanvasRenderer` + app).** ▶ badge overlay
  for `.video` tiles; double-click / context-menu **open** → QuickLook of the
  stored blob.
- **E — Extension video path (`extension/`).** `manifest.json` gains
  `cdn.syndication.twimg.com` + `video.twimg.com`. Twitter extractor flags a video
  (poster, no `media/` photo) + emits `tweetId`; SW resolves the MP4 variant via
  the syndication API, fetches it in-session, POSTs `/ingest-video`. Image path
  untouched. Tests (mocked fetch).

## Verification
- `swift test` green in AtelierServer (video route incl. header parse, oversized,
  auth negatives) + AtelierIngestion (`remoteVideo`) + AtelierCore (poster
  thumbnail from a sample MP4).
- `node --test` green for the extension (syndication resolve + video POST shape).
- App builds; **manual**: capture a video tweet → poster tile with ▶ appears live
  → open plays in QuickLook; dedup on re-capture; large file doesn't spike memory.

## Out of scope (deferred)
- Inline in-canvas playback (live `AVPlayerLayer`s + scroll perf).
- Non-Twitter video (Instagram/Cosmos) — different resolution per platform.
- HLS reassembly (`.m3u8` → `.ts` concat/remux) — only needed when no progressive
  MP4 variant exists; syndication provides MP4 for the common case.
- Audio-only / very-long-form handling, transcoding.
