# 133 — Instagram media-host allowlist (the "saved 0" fix) + sweep tracing

## Summary

The O2 Instagram driver fetched the saved feed correctly (200, 21 items/page) but **every
item failed to ingest** — the sweep showed `permanentFailed`, 0 saved. Live tracing
pinned it: each relay returned **`blocked-host`**. The service worker's SSRF media-host
allowlist (`media-hosts.js`) had entries for `twitter` and `pinterest` but **none for
`instagram`**, so it denied every IG CDN URL by default (deny-by-default, 3A) before
fetching the bytes. Single-item IG capture was unaffected because it fetches via
`activeTab`, not this bulk guard.

## Fix

- `media-hosts.js`: add an `instagram` predicate allowing `*.cdninstagram.com` and
  `*.fbcdn.net` (e.g. `scontent.cdninstagram.com`, `instagram.f<edge>-<n>.fna.fbcdn.net`)
  — the hosts observed live, both already in the manifest `host_permissions`. Suffix-spoof
  resistance (`hostIs`) and cross-platform denial are preserved.

## Also: sweep tracing (kept, refined)

Added a prefixed `[Atelier bulk]` console trace to the sweep path so "why did my sweep do
nothing" is no longer invisible (a bulk sweep is a rare, user-initiated action):
- `START <platform>`, `driver built …`, `sweep SETTLED <status> <counts>` — lifecycle.
- IG driver fetch: `IG fetch status <n> items <n> more <bool>` (or `IG fetch THREW …`).
- Per-item relay: logs **only a non-`saved` result** (blocked-host / fetch-error /
  unreachable / …) — quiet on the happy path, self-explaining on a broken one.

This is what localized the bug in one sweep; it earns its place for future triage.

## Files changed

- `extension/src/media-hosts.js` — the `instagram` allowlist entry (the fix).
- `extension/test/media-hosts.test.js` — IG allow set (real CDN hosts), cross-platform
  denial, suffix-spoof denial; the stale "IG denied" assertion (from before the entry
  existed) flipped; unknown-platform check repointed to a genuinely unknown platform.
- `extension/src/bulk-controller.js` — the sweep trace (lifecycle + relay-anomaly logging).
- `extension/src/bulk-instagram.js` — `makeSavedFeedFetch` takes an optional `log` and
  reports each page's status/item-count (and a thrown fetch).

## Test results

`node --test`: **356 pass / 0 fail** (+1 IG media-host test).

## Migration notes

None (extension-only). With this, an IG saved sweep ingests its media (verified: the
driver produces 21 items/page; the allowlist entry lets the SW fetch their bytes). Any
future platform's media CDN must be added to `media-hosts.js` too — the manifest
`host_permissions` alone is not enough; this guard is a second, deny-by-default gate.
