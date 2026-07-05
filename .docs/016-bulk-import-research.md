# 016 — Bulk Import: Research

> Live 2026 research behind the mechanism choices in
> [015-bulk-import-overview](./015-bulk-import-overview.md). Three streams: X,
> Pinterest, and cross-cutting architecture/legal. Unverified points are flagged
> inline. Sources listed per section.

The consistent finding: **do not forge private API requests, and do not lean on
the official APIs**. Let the site's own client issue its paginated calls while
riding the user's authenticated session; observe (X) or replay with session cookies
(Pinterest). This inherits the platform's own anti-bot tokens and returns
full-resolution + video URLs, at the cost of a ToS-grey (but personal, local,
own-data) posture.

## X / Twitter — Bookmarks + Likes

| Approach | Completeness | Robustness | Auth complexity | ToS/ban risk | Fits arch |
|---|---|---|---|---|---|
| DOM auto-scroll | Partial (no video; images ok) | Medium | Low | Low-med | Strong |
| GraphQL **replay** (SW forges) | High | **Low** (queryId/features/txn-id churn) | High | Medium | Medium |
| **GraphQL response interception** | **Highest live** | **Highest live** | **Lowest live** | Low-med | **Strong** |
| Official API v2 | High + clean | Highest | High (OAuth2 PKCE) | None | Weak-med |
| GDPR archive ZIP | Likes full; **bookmarks absent** | High (static) | Low | None | Weak |

**Chosen: response interception (2b).** Inject a `MAIN`-world hook over
`fetch`/`XHR`; let X's own app issue `Bookmarks`/`Likes` GraphQL as we auto-scroll;
read the JSON. Because X builds the requests we inherit a valid `queryId`, the
`features` blob, the `ct0`↔`x-csrf-token` pairing, and the signed
`x-client-transaction-id` — avoiding the ~10–15 hrs/mo maintenance treadmill of
forging them. JSON carries original image URLs (`name=orig`, 4096px hard cap) and
video-variant URLs (fixing that DOM video is a useless `blob:` URL). Reference
implementation: **prinsss/twitter-web-exporter** (v1.4.0, Feb 2026).

Notes / flags:
- The "800 bookmarks" figure is a **free-account save limit**, not a pagination
  cap; interception walks all bookmarks. **Likes** hit an effective **~3,200 web
  wall** (community-reported, not officially confirmed).
- The **GDPR archive contains Likes (`like.js`, full history, IDs/URLs, no media)
  but NOT bookmarks** — offer as a secondary Likes-beyond-3200 path only.
- Official API v2 is now **pay-per-use** (Feb 2026): owned reads ~$0.001/item
  (~$5 for 5k). Sanctioned, but adds an OAuth2-PKCE redirect and doesn't ride the
  session — keep as an optional "clean" mode. Pricing is officially warned as
  changing; verify live.
- `MAIN`-world injection + reading `ct0` are a modest permissions expansion.

Sources: prinsss/twitter-web-exporter; sytelus/xarchive (queryId discovery from JS
bundles); iSarabjitDhiman/XClientTransaction + swyxio/XClientTransactionJS
(transaction-id); helmetroo/fetch-twitter-bookmarks (endpoint shape);
vladkens/twscrape; docs.x.com rate-limits + pricing + data-dictionary;
seramo/twitter-archive-docs (`like.js`).

## Pinterest — boards + pins

| Approach | Completeness | Robustness | Auth | ToS risk | Fits arch |
|---|---|---|---|---|---|
| DOM auto-scroll | Medium (virtualization drops pins; no terminator) | Medium | Low | Same as today | Excellent |
| **Internal resource API replay** | **High** (all boards, secret, sections, full-res) | Med-high | Low-med (cookies + CSRF + `X-Pinterest-*`) | Higher | **Excellent** |
| Official API v5 | Low-med (**fixed sizes, not `/originals/`**; no sections) | High | High (business acct, OAuth, review) | Lowest | Poor |
| GDPR export | Medium (links, **no media**; 1–2 day latency) | High | Low | Lowest | Poor |

**Chosen: resource-API cursor replay** from the SW. `BoardsResource` → per board
`BoardFeedResource` (+ `BoardSectionsResource`/`BoardSectionPinsResource`), plus
`UserPinsResource` for the global sweep. Pagination via the `options.bookmarks`
cursor until `-end-` (a real terminator → **verifiable completeness**). Rides
session cookies (secret boards + All-Pins work); add `X-CSRFToken` (from the
`csrftoken` cookie) + `X-Pinterest-*` / `X-APP-VERSION`. Full-res via the
`/originals/` rewrite the harvester already does; video pins expose `.mp4` URLs.

Notes / flags:
- Endpoints are undocumented but have backed **gallery-dl** and **py3-pinterest**
  for years (still working 2025–2026, periodic breakage patched). Most brittle bit
  is `X-APP-VERSION` — **scrape it from the page bootstrap at runtime**, don't
  hardcode; try omitting it first.
- Official v5 returns **fixed CDN sizes (≤~1200px), not `/originals/`**, has **no
  section-pins endpoint**, uncertain secret-board readability, and flaky
  trial-access approval for individuals — unsuitable as primary.
- GDPR export lists every board/pin (good completeness cross-check) but **bundles no
  media** and takes 1–2 days — can't be the fetch path.

Sources: gallery-dl `pinterest.py`; py3-pinterest `Pinterest.py`; pinterest-dl;
pinback (bookmarklet, links-only); developers.pinterest.com v5 rate-limits + access
tiers + boards-list_pins; community threads on trial-access friction.

## Cross-cutting — architecture, lifecycle, pacing, legal

- **MV3 SW lifecycle.** SW killed after ~30s idle / 5-min hard cap; a single stalled
  `fetch` counts against it. Keep-alive (offscreen doc / alarms) is a discouraged,
  fragile hack. → Put the long loop in the **content script** (page context, lives
  as long as the tab); SW is a thin event-driven relay kept alive by item traffic;
  checkpoint everything to `chrome.storage.local`. Correctness must survive
  arbitrary SW death (it does, via checkpointing) — never rely on keep-alive.
- **Transport.** Keep **per-item POST**; the server is deliberately network-free and
  rides no auth session, so it CANNOT fetch auth-walled CDNs — bytes come from the
  extension. Per-item is already idempotent (content-addressed) with natural
  backpressure. Wrap it in a thin `/jobs` handshake for identity/progress; do NOT
  build a server-side batch-fetch endpoint.
- **Resumability + dedup.** Two-tier state (extension cursor + app job ledger).
  Skip the **download** (not just the ingest) by loading the app's known-`source_id`
  set once; SHA-256 content-addressing stays the authoritative dedup backstop (the
  `source_id` skip is an optimization, not the correctness layer).
- **Rate-limit etiquette.** Cap concurrency at 2–3; jittered human-scale delays;
  `Retry-After`-aware exponential backoff with ±50% jitter; detect 429/403/503 AND
  DOM "something went wrong"/captcha walls as **hard-pause** signals that checkpoint
  and prompt the user. Protecting the user's own account > speed.
- **Legal.** Own-data + own-session + local-only maps to data-portability rights
  (GDPR Art. 20/15, CCPA); *hiQ v. LinkedIn* makes CFAA a poor fit. But *hiQ* LOST
  the **contract** claim — ToS "no automated access" clauses are enforceable, and
  *Meta v. Bright Data* (2024) turned on exactly the **logged-in own-account** state
  this feature uses. Realistic risk = **account throttling/suspension, not
  litigation**. Mitigate with pacing + user-initiated, human-paced, own-data-only
  scope + an explicit consent/disclosure step. Not legal advice.

Sources: developer.chrome.com SW lifecycle + offscreen + longer-ESW-lifetimes;
Zuplo/Postman/IO-Tools on HTTP 429 + backoff; gdpr-info Art. 20; EFF/Jenner/Morgan
Lewis on hiQ; Bright Data/Zyte/Quinn Emanuel on Meta v. Bright Data.

## Claude-in-Chrome vs the custom extension (evaluated separately)

Agentic browser automation (Claude-in-Chrome) is the **wrong engine** for the
shippable feature — a screenshot+reason loop is too slow/expensive at 2,000 items,
non-deterministic on completeness, and only "sees" the page (so it degrades to
DOM-scrape limits: `blob:` video, downsized images). It also can't ship as an app
button (it's a dev-driven agent). It IS valuable as (1) a **reverse-engineering
aid** to capture the current live request shapes/fixtures (Phase 0), and (2) a
one-off tiny personal grab. Conclusion: use it to build/validate the extension,
ship the extension as the engine.
