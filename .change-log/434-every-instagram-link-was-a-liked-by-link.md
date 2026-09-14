# 434 — every Instagram link was a liked_by link

[096](../.docs/096-tier3-plan.md) § T0's permalink rider, answered by measurement on all
three platforms at a phone viewport. Two of the three came back with something.

## What was measured

The reader's selectors and every post link's path shape, read off live feeds at 390×850 in
Safari's Responsive Design Mode. **Caveat carried forward: the user-agent stayed desktop**,
so these are the responsive desktop apps at phone width, not the mobile sites. Strong
evidence, not the device answer.

| | container selector | post-link shapes (path segments) | verdict |
|---|---|---|---|
| x.com | `article` ✓ | `[3, 4, 5]` — bare, `/analytics`, `/photo/N` | fixed in [432](432-the-tweet-with-only-an-analytics-link.md) |
| instagram.com | `article` ✓ | `[3]` — **`/liked_by/` only, no bare link at all** | fixed here |
| pinterest.com | `[data-test-id="pin"]` ✓ | `[2]` — bare `/pin/{id}/` only | **nothing to fix** |

Every container selector 431 guessed at fired on the first entry in its fallback list.

## Instagram

`permalinkShapes: [3]`, samples `/p/DceVsiRH8HO/liked_by/`, `/p/DcdZzt-mU_K/liked_by/`,
`/p/DceqrKez5_M/liked_by/`. **Not one bare `/p/{code}/` appeared on the page.**

That makes this worse than X's version, which 432 called a fork that bites when the user
right-clicks an image. Here the sub-page link is the *only* link the feed offers, so a
tier-3 capture from an Instagram feed would fork **every time** — and `instagram.js`'s
`isPost` accepts it while `shortcode` still resolves at `segments[1]`, so the capture looks
entirely successful on the way past.

`toPostPermalink(url)` reduces a post URL to `/{p|reel}/{code}/`, applied after candidate
resolution so any source normalizes: the tapped feed link, a live sub-page URL, a stale
canonical.

**The trailing slash is deliberate**, and is not a slip copied from X's slash-less version.
Each platform normalizes to the form its own bulk mapper composes, so the two producers
agree per platform: `bulk-instagram.js:179` builds `https://{host}/{p|reel}/{code}/`;
`bulk-twitter.js:280` builds a status URL with no trailing slash. A test asserts each
against its mapper's string rather than against a house style.

## Pinterest

`permalinkShapes: [2]`, every sample a bare `/pin/{id}/`. No sub-page links exist in the
grid, so there is nothing to normalize — and `bulk-pinterest.js:130` already composes
`/pin/{id}/` with the same trailing slash the DOM links carry. The two agree today.

Recorded rather than skipped: 096 § D4's rule is that a platform is covered when someone
measures it, and "measured, needs nothing" is a different state from "never looked".

## Files changed

- `extension/src/extractors/instagram.js` — `toPostPermalink`, exported and applied.
- `extension/test/extractors.test.js` — six cases: the sub-page suffixes, `/reel/` preserved,
  the trailing slash added to a bare link, idempotence, non-post URLs untouched, the
  `/liked_by/` feed link, and agreement with `bulk-instagram.js:179`.

Full suite: 576 pass, 1 skip. `drift-check` clean.

## Migration notes

**Same one-time recapture cost as 432**, and larger. Anything previously captured from an
Instagram feed link carries a `/liked_by/` `originalURL`; recapturing that post now yields
the canonical permalink and will not dedup against the stored record. Because the sub-page
link was the only shape the feed offered, this plausibly affects *most* Instagram captures
taken via a feed right-click rather than a few.

**Still open, and not settled by this:** Pinterest served `nz.pinterest.com`, while
`bulk-pinterest.js` composes from whatever `host` the response carried and a desktop capture
would typically be on `www.pinterest.com`. Same pin, two `originalURL`s, by country
subdomain rather than by path. Not touched — it is a different fork with a different fix
(canonicalize the host, or key dedup on `pinId`), and it wants its own decision.
