# 035 — Server: /ingest-video streaming route (video capture, checkpoint A)

Adds a second capture endpoint for video that avoids the base64-in-JSON memory
trap of `/ingest`.

## Transport
`POST /ingest-video` (behind the same auth+CORS gate):
- Body is the **raw video** (`application/octet-stream`) — NOT base64/JSON.
- Provenance rides in the `X-Atelier-Provenance` header as base64 JSON of a new
  `VideoCaptureHeader { provenance, collectionId? }` (added to the CORS
  `Access-Control-Allow-Headers` so the browser lets the POST through).
- The body is **streamed to a temp file** chunk-by-chunk (`HTTPBodySequence` async
  sequence), enforcing a separate 512 MB cap as bytes arrive — so a large clip
  never sits in a single in-memory `Data`. The route ingests via
  `DirectInputReader.remoteVideo` (a file-URL source); the temp file is removed
  once ingest has read it.

## Structure (kept DRY / testable)
- `CaptureDTO`: `VideoCaptureHeader` + `DecodedVideoCapture`; the
  `ProvenanceDTO → SourceDraft` mapping is factored into one shared
  `makeSourceDraft` used by both the image body and video header decoders.
  New `CaptureDecodeError.missing/​malformedProvenanceHeader`.
- `CaptureRoutes.handleIngestVideo(fileURL:provenanceHeader:now:)` — pure logic
  (temp file + header in → `HandlerResult`); the image and video paths share one
  `ingest(_:into:)` outcome-mapper.
- `CaptureServer`: dispatch by `(method, path)`; the video path streams to disk,
  the image path is unchanged. `maxVideoBodyBytes` (default 512 MB) is injectable.

## Verification
- `swift test` (AtelierServer) → **44/44** (+10): decoder header matrix
  (valid / missing / non-base64 / wrong-JSON / unknown-platform), route
  (persisted `.video` + duration; missing header → 400), and over-the-wire
  integration (octet-stream → 200 `.video`; no header → 400; over-cap → 413).

## Files changed
- `Sources/AtelierServer/{CaptureDTO,CaptureRoutes,CaptureServer,CaptureAuth}.swift`
- `Tests/.../{ServerTestEnv(+mp4/header),CaptureDecoderTests,CaptureRoutesTests,CaptureServerIntegrationTests}.swift`
