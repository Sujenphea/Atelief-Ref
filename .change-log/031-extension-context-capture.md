# 031 — Extension: right-click element capture + fetch guards (build-order #6)

Follow-up fix for two reported issues after 030: Pinterest still captured
`pinterest.com` (because captures came from the FEED, where `location.href` really
is the feed), and Twitter's image didn't copy over (page-level media guessing
missed the real photo).

## Root cause (verified live in-browser)
- On the Pinterest **feed**, `location.href = pinterest.com/` — there is no pin URL
  on the page to use, so page-level extraction can't know which pin you meant.
- Page-level media guessing is inherently unreliable on these SPAs; the user knows
  exactly which image they want.

## Fix — capture the right-clicked element
The context menu already fires with `info.srcUrl` (the exact image) and
`info.linkUrl` (its post link). We now thread that context into extraction:
- **URL**: prefer the right-clicked `linkUrl` when it's a real post (`/pin/{id}`,
  `/status/{id}`, `/p/{code}`), else the live page URL. Verified: right-clicking a
  pin in the feed now yields the pin URL + pinId, not `pinterest.com`.
- **Media**: prefer the right-clicked `srcUrl` (rewritten to full res:
  Pinterest `/originals/`, Twitter `name=orig`), with the rendered size kept as a
  fetch fallback. This hands Twitter the exact image instead of guessing.
- The toolbar button still works on single-post pages (falls back to page-level
  extraction); the feed case needs a right-click.

## Also
- **Content-type guard**: the SW rejects a non-`image/*` fetch response (an
  error/HTML page won't be "successfully" ingested as garbage; it falls through to
  the next candidate).
- **Diagnostics**: the SW logs `[Atelier] capture` (context + provenance),
  `[Atelier] fetched image` (url/type/bytes), and `[Atelier] ingest response`
  (status/body) — so any future misfire is diagnosable from the service-worker
  console.

## Verification
- `extension/`: `node --test` → **16/16** (added feed-right-click + context.srcUrl
  cases).
- Live: on the real Pinterest feed, a simulated right-click context yields the pin
  URL + the clicked image at `/originals/` (both `/originals/` and the rendered
  fallback confirmed 200 image/jpeg).

## Files changed
- `extension/src/extractors/{base,twitter,pinterest,instagram,cosmos,registry}.js`
  (thread `context`), `src/sw.js` (pass click context, content-type guard,
  diagnostics), `test/extractors.test.js`, `README.md`.

## Note
Reload the unpacked extension, and **right-click the image/pin → Save to Atelier**
(the toolbar button is ambiguous on a feed).
