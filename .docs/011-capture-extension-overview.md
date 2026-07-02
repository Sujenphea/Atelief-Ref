# 011 — Capture extension + localhost endpoint: Overview (decisions + research)

> Build-order **step 6** ([004](./004-foundation-plan.md) · [009 §6](./009-mvp-status-overview.md)):
> the primary platform-ingestion path. A Chrome extension captures the current
> post/pin from inside the user's authenticated session and POSTs it — image
> **bytes** + rich provenance — to a **localhost endpoint inside the app**, which
> ingests through the SAME pipeline as paste/drag ([007](./007-ingestion-overview.md)).
> Per design **D5** ([003 §agent-interface](./003-foundation-design.md)) this
> localhost surface is the one the future agent interface reuses.

Produced via an interactive Architecture → Code Quality → Tests → Performance
review. Every fork was chosen by the user (all "A" options).

## Decisions

### Architecture
- **A1 — Transport: FlyingFox.** Embedded pure-Swift async HTTP server (MIT,
  v0.26.2, Swift-6-clean), bound to loopback. Chosen over a hand-rolled `NWListener`
  parser (fragile, large test burden) and Chrome Native Messaging (helper process +
  install friction). *Researched & verified 2026 — see Research below.*
- **A2 — Security: loopback + shared-secret token + `Origin` allowlist.** Bind
  `127.0.0.1` only; two independent barriers — CORS/`Origin` blocks browser drive-by
  (a web page can't forge a `chrome-extension://` origin), the token blocks
  non-browser local processes. Localhost binding alone is NOT isolation.
- **A3 — Image bytes come from the extension**, not an app-side download. The app
  makes NO outbound requests → stays inside the deferred-network boundary, needs no
  `network.client`, and rides the auth session (dodges auth-walled CDNs).
- **A4 — New provenance factory** (`DirectInputReader.remoteInput`) taking a full
  `SourceDraft`. Per-site DOM extraction stays in JS content scripts.

### Code quality
- **CQ1 — Server → shared `IngestCoordinator` off-main + change notification** the
  `@MainActor` view model observes to refresh. The server never imports the view model.
- **CQ2 — One Codable request DTO (JSON, base64 image) + one response DTO.** No
  multipart (FlyingFox has none).
- **CQ3 — One auth+CORS middleware** over all routes (token, Origin, OPTIONS
  preflight, CORS headers) — a single place for security-critical logic.
- **CQ4 — Extension: shared `SiteExtractor` + per-site modules + registry.** Mirrors
  the Swift `SourceAdapter` shape; a new site is one module.

### Tests
- **T1** two-layer server tests (pure handlers + ephemeral-port integration);
  **T2** exhaustive auth/CORS negatives; **T3** table-driven DTO→SourceDraft matrix;
  **T4** extractor unit tests + endpoint-contract tests.

### Performance (single-user localhost — resource safety, not speed)
- **P1** max body size (50 MB → 413); **P2** reuse the existing bounded coordinator
  (no new queue); **P3** respond after ingest (truthful result); **P4** fixed port
  47321, async start, clean shutdown, `SO_REUSEADDR`.

## Binding MV3 facts (verified 2026, not choices)
- The POST **must originate from the extension's service worker**, not a content
  script (content scripts are always CORS-bound). We inject `harvestSignals` via
  `chrome.scripting.executeScript` on a user gesture, then extract + POST from the SW.
- Bind **IPv4 `127.0.0.1`** (FlyingFox's `.loopback` is IPv6 `::1` only; the
  extension POSTs to `http://127.0.0.1`, which loopback-`::1` would refuse). Loopback
  is mixed-content-exempt, so an https page → http-localhost is allowed.
- The server answers the **OPTIONS preflight** (204 + CORS) or the POST never fires;
  `Origin: chrome-extension://<id>` is the allowlist value + the cheap auth gate.

## Research (transport, verified 2026)
FlyingFox: MIT, actively maintained, BSD-sockets+kqueue (not `NWListener`), tiny.
Swifter/Telegraph effectively unmaintained; Hummingbird/Vapor drag in SwiftNIO —
overkill for two loopback routes. Native Messaging is the only serious alternative
(no port/CORS/entitlement) at the cost of a helper process + host-manifest install.
Sources: FlyingFox README/GitHub; Chrome network-requests & native-messaging docs;
W3C Secure Contexts / MDN Mixed Content; Hummingbird docs.

## Shape as built
- **`AtelierServer`** package: `CaptureDTO` (+ pure `CaptureDecoder`), `CaptureAuth`
  (gate + CORS), `CaptureRoutes` (`handleIngest`), `CaptureServer` (FlyingFox actor +
  single root handler). Reuses `DirectInputReader.remoteInput` + `IngestCoordinator`.
- **App**: `network.server` entitlement; `IngestionModel` starts the endpoint in
  `bootstrap`, persists a generated token (UserDefaults), refreshes live on capture;
  a "Browser Capture" toolbar popover shows status + token.
- **`extension/`** (MV3): `harvest.js` (page harvester), `extractors/*` + `registry`,
  `endpoint.js`, `sw.js`, options page. Tests via `node --test` (no deps — extractors
  are pure over harvested signals, so no jsdom needed; a deliberate simplification of
  the plan's jsdom approach).

## Out of scope (deferred)
- App-side URL download / link resolution (Backlog B1, #3 fallback).
- Background capture while the app is closed (LaunchAgent/helper; multi-process DB).
- Safari/Firefox breadth; bulk board/likes backfill (Phase 2).
- The full agent MCP surface — this endpoint is the seam it reuses, not built now.

## Verification
`swift test` green in AtelierServer + AtelierIngestion; app builds + signs with the
entitlement; `npm test` green in `extension/`. Manual (crosses the sandbox / browser):
run the app → endpoint binds; load the unpacked extension → Save on a real post →
asset appears live with correct provenance; drive-by `fetch` from a random page is
rejected; dedup on re-capture; clean quit + relaunch.
