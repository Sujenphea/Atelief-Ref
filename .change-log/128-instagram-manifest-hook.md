# 128 — Instagram host permission + saved-feed hook (002 · B2)

## Summary

The risk-bearing permission change for the IG saved-posts sweep: add the
`instagram.com` host permission and wire the MAIN-world saved-feed hook. This is the
store-review / privacy surface the plan isolates in its own commit (G14). The extension
stays loadable and every intermediate state is testable — the hook forwards saved-feed
responses to a controller that doesn't consume them until B3 (harmless no-op).

`instagram-hook.js` is a **thin config over hook-core** (B1), not a fork: it supplies
only IG's request-URL matcher (`/api/v1/feed/saved/posts/`, flat-only per 6A — a saved
collection loads from a different path and is deliberately unmatched) and its message
tags. All interception / buffering / replay is the shared core; forwarding is status-blind
so a 4xx `checkpoint_required` body reaches the driver (3A).

## Files changed

- `extension/manifest.json`:
  - `host_permissions` += `*://*.instagram.com/*`.
  - New MAIN-world content-script pair `["src/hook-core.js", "src/instagram-hook.js"]`
    at `document_start` for `instagram.com` (core first — load-order is load-bearing).
  - `bulk-loader.js` matches += `instagram.com` (the ISOLATED controller loads on IG
    pages; it rejects an IG START until the B3 driver arm lands).
  - `web_accessible_resources` matches += `instagram.com` (so the dynamic module import
    is allowed).
- `extension/src/instagram-hook.js` — new: the thin IG hook config.
- `extension/src/bulk-messages.js` — `IG_SAVED_MESSAGE_SOURCE` + `IG_SAVED_REPLAY_SOURCE`
  tags (the single source of truth the hook duplicates as literals, KEEP IN SYNC).
- `extension/test/instagram-hook.test.js` — new: matcher (flat feed ± pagination,
  rejects collections/CDN/null), classic-script syntax guard, wire-constant sync, and
  the load-order pair tests (core-first installs; IG-hook-without-core fails loudly via
  console.error but never throws; inert on a non-IG host).
- `.docs/020-production-readiness-overview.md` — G14 updated: the new host permission
  widens the ToS/privacy surface (Meta ToS + the account-challenge risk B4's warning UI
  must disclose).

## Test results

`node --test`: **320 pass / 0 fail** (+6 IG hook tests). Manifest is valid JSON.

## Migration notes

None (extension-only). The permission expansion must be reflected in the store listing +
privacy policy before publish (G12–G14). No app or schema change.
