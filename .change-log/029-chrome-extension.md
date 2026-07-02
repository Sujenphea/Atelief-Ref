# 029 — Chrome extension (MV3) + JS tests (build-order #6, checkpoint 4)

The capture front-end: an MV3 extension that harvests provenance from the current
post/pin and POSTs image bytes to the app's localhost endpoint. Completes #6.

## Summary
`extension/` (MV3, decision CQ4):
- **`src/harvest.js`** — the only page-context code (injected via
  `chrome.scripting.executeScript` on a user gesture): serializes generic signals
  (meta tags, canonical link, title, url). Site-agnostic.
- **`src/extractors/`** — `base.js` helpers + `twitter`/`pinterest`/`instagram`/
  `cosmos` modules + a `registry` (with a generic `web` Open-Graph fallback). Each is
  a pure `extract(harvest) → provenance` function; mirrors the Swift `SourceAdapter`
  shape — a new site is one module + one registry line.
- **`src/endpoint.js`** — `buildCaptureRequest` (matches Swift `CaptureRequest`:
  base64 image + provenance; `collectionId` omitted → Unsorted) + `postCapture`
  (injectable fetch).
- **`src/sw.js`** — service worker orchestration: harvest → extract → fetch media
  bytes in the auth session → base64 → POST with the token → badge feedback. Toolbar
  action + context-menu entry. The POST comes from the SW (MV3 requires it).
- **`src/options.{html,js}`** — paste + persist the shared-secret token.
- **`manifest.json`** — `host_permissions` for 127.0.0.1 + known media CDNs; module
  service worker; activeTab/scripting/storage/contextMenus.

## Tests (13, `node --test`, zero deps)
- `test/extractors.test.js` — per-site extraction from harvest fixtures (handle/id
  parsing, og:image media, canonical preference, web fallback, no-image → null,
  routing).
- `test/endpoint.test.js` — request mapping (full + missing optionals), header/body
  wiring via injected fetch, non-JSON tolerance.

Extractors are pure over harvested signals, so no jsdom is needed — a deliberate
simplification of the plan's jsdom approach that still fully covers the fragile part.

## Files changed
- Create `extension/` (manifest, src/*, test/*, package.json, README, .gitignore).
- `.docs/011-capture-extension-overview.md` — decisions + transport research.

## Migration notes / caveats
- `sw.js` glue + the real localhost round-trip + sandbox bind are MANUAL checks
  (load unpacked, Save on a real post). The extraction + contract logic is unit-tested.
- Media-fetch host coverage is per-platform (Phase 2 broadens it); extraction is
  Open-Graph-first (richer per-site DOM is Phase 2).
