# 126 — Instagram saved-feed recon + fixtures (002 · B0)

## Summary

B0 groundwork for the Instagram bulk driver ([002](../.docs/feature-todo/002-capture-instagram-bulk.md)):
captured, verified, and sanitized the saved-feed response shape so parser work can
start against a committed fixture (no live IG). Recon-first (settled 8A) — no parser
code lands before this.

Verified from a real logged-in capture (2026-07-15):

- **Transport is REST**, not GraphQL: `GET instagram.com/api/v1/feed/saved/posts/`,
  same-origin, `credentials:'include'`, `x-ig-app-id` + `x-csrftoken` headers.
- **Response shape:** `{ items: [{ media }], more_available, next_max_id?, status }`.
  Each `media` carries `pk`/`id`/`code`, `media_type` (1 image · 2 video/reel · 8
  carousel), `product_type`, `user.{pk,username,full_name}`, `caption.text`,
  `image_versions2.candidates[]` (largest-first poster), `video_versions[]` (reels),
  `carousel_media[]` (children, each its own `pk`).
- **Per-media `pk` present** → the 1A carousel fan-out dedup key works.

## Known gap (recorded, non-blocking)

The recon account is single-page (`more_available: false`, no `next_max_id`), so the
fixture is a verified **end-of-feed** page. The mid-feed cursor field name is IG
convention, **not live-observed** — the paginating test synthesizes it and the drift
baseline flags re-verification. Feed ordering (save-time?) also unconfirmed; it only
gates the deferred re-sweep early-stop (14A).

## Files changed

- `extension/test/fixtures/instagram-saved.json` — new sanitized fixture (1 image +
  1 reel + 1 carousel). Structure preserved exactly; every real id/handle/caption/URL
  replaced. Leak-checked against all 153 real tokens from the raw capture → clean.
- `extension/test/fixtures/README.md` — IG fixture row + transport note + the
  mid-feed-cursor gap.
- `extension/test/fixtures/drift-baseline.json` — `markers.instagram` seeded
  (route, media_type map, 14-day stale window; the per-platform `staleAfterDays`
  restructure lands with `checkInstagramSaved` in B3).
- Raw capture stored gitignored at `resources/ig-saved-page1.json` (never committed).

## Migration notes

None. Fixtures + docs only; no source or schema change.
