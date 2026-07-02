# 030 — Fix SPA extraction: real DOM media + live URL (build-order #6)

Fixes two capture bugs reported in use: Twitter captured a generic og:image
instead of the post's media, and Pinterest captured `pinterest.com` + the generic
Pinterest logo instead of the pin.

## Root cause
Twitter/X, Pinterest, Instagram and Cosmos are **client-rendered SPAs whose
`<meta og:image>` and `<link rel=canonical>` are stale or generic** — verified live
in-browser:
- Pinterest pin page → `canonical = https://www.pinterest.com/` (root!) and
  `og:image = s.pinimg.com/images/facebook_share_image.png` (the share logo). The
  real pin is only in the DOM as `i.pinimg.com/…`.
- X status page (client-rendered) → **no og/meta at all**; the real media is only in
  the DOM as `pbs.twimg.com/media/…`.

The extractors trusted `canonical` (→ wrong URL) and `og:image` (→ wrong image).

## Fix
- **Harvest real DOM media.** `harvestSignals` now also collects `<img>`/`<video>`
  elements (src + natural dimensions). Extractors pick the post's media by host
  pattern; og:image is a last-resort fallback.
  - Twitter: first `pbs.twimg.com/media/…` in DOM order (the focused tweet renders
    first), rewritten to `name=orig`; video tweets use the poster.
  - Pinterest: largest `i.pinimg.com` image (the closeup; related pins are smaller),
    rewritten to `/originals/`, with the rendered size kept as a **fetch fallback**
    (`/originals/` can 404 → SW retries the rendered URL).
  - Instagram/Cosmos: largest CDN image; web fallback keeps og:image (reliable on
    non-SPA articles).
- **Use the live URL** (`location.href`, kept correct by SPA pushState), cleaned of
  query/hash, instead of `canonical`. Fixes the `pinterest.com` provenance bug.
- **SW fetch tries candidates in order** (`mediaUrl` → `mediaUrlFallback`) so a
  full-res 404 falls back rather than failing the capture.

## Verification
- `extension/`: `node --test` → **14/14** green (new fixtures encode the stale-
  canonical + generic-og scenarios and the full-res rewrites/fallback).
- Live in-browser check on a real pin: extraction now yields the pin URL +
  `i.pinimg.com/originals/…` (200 image/jpeg), not `pinterest.com` + the logo.

## Files changed
- `extension/src/harvest.js` (DOM media), `extractors/base.js` (liveURL/cleanURL +
  media helpers), `extractors/{twitter,pinterest,instagram,cosmos}.js`,
  `extractors/registry.js` (web), `src/sw.js` (candidate fetch), `test/extractors.test.js`.

## Note
Reload the unpacked extension in `chrome://extensions` to pick up the change.
