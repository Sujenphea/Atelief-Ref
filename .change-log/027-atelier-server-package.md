# 027 — AtelierServer package: localhost capture endpoint (build-order #6, checkpoint 2)

The heart of #6: a new local Swift package owning the loopback HTTP endpoint the
Chrome extension POSTs to. It reuses the existing ingestion pipeline wholesale and
never imports the app.

## Summary
New package `AtelierServer` (depends on `AtelierCore` + `AtelierIngestion`; adds
FlyingFox as the app graph's 2nd remote SPM dep after GRDB). Layers:

- **`CaptureDTO`** (CQ2) — `CaptureRequest` (base64 image + `ProvenanceDTO` +
  optional `collectionId`) / `CaptureResponse`, and `CaptureDecoder.decode` — the
  pure JSON→`SourceDraft` seam. Server owns `capturedAt` (not client-trusted);
  field-level provenance rules stay with `AppServices` (one authority).
- **`CaptureAuth`** (A2/CQ3) — pure token + `Origin`-allowlist gate + CORS headers +
  constant-time compare. Two independent barriers (foreign web origins blocked by
  CORS; non-browser local processes blocked by the token).
- **`CaptureRoutes`** (CQ1/P2/P3) — pure `handleIngest(body:now:)`: decode → build
  `IngestInput` via `DirectInputReader.remoteInput` → run the shared bounded
  `IngestCoordinator` → map outcome to status + body; fires `onCapture(collectionID,
  outcomes)` so the app can refresh (server stays view-model-free).
- **`CaptureServer`** (A1/P1/P4) — FlyingFox actor bound to **IPv4 `127.0.0.1`**
  (not FlyingFox's IPv6-only `.loopback`, which the extension's `http://127.0.0.1`
  POST could not reach), fixed port 47321 (0 ⇒ ephemeral for tests), single root
  handler centralizing auth+CORS+body cap (50 MB), `start()`/`stop()` lifecycle,
  `CaptureToken.generate()` (256-bit secret).

## Tests (34, all green)
- `CaptureDecoderTests` (T3) — full mapping + malformed matrix (bad JSON, wrong
  shape, bad base64, empty image, unknown platform) + every platform string.
- `CaptureAuthTests` (T2) — authorized / missing / wrong token / foreign origin /
  preflight / pinned-id / CORS shape / constant-time.
- `CaptureRoutesTests` (T1 pure) — success + persistence, dedup, default routing,
  onCapture hook, non-image→422, bad base64→400, bogus collection→422 (real temp
  library).
- `CaptureServerIntegrationTests` (T1 socket) — ephemeral-port URLSession round-trips:
  valid POST, preflight 204+ACAO, missing-token 403, foreign-origin 403, oversized
  413, `/health` 200.

## Files changed
- Create `AtelierServer/` (Package.swift, 4 sources, 4 test suites + TestSupport).

## Migration notes / caveats
- Not yet wired into the Xcode app target (checkpoint 3) — no runtime behavior change.
- `swift test` is UNSANDBOXED, so the integration tests prove HTTP/CORS/handler
  logic but NOT the sandbox `network.server` bind — that stays a manual app check.
