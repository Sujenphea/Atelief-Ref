# 002 — Capture: Instagram Saved-Posts Bulk Import

> Covers "Save designs from: bookmarks from X, Instagram". **X is done** — the bulk
> sweep handles X Bookmarks (incl. bookmark folders) and Likes, plus Pinterest boards
> (see [015–018](../015-bulk-import-overview.md)). The gap is **Instagram saved posts**,
> explicitly deferred in 015 §scope. Single-item IG capture already works via the
> context menu.

## Current state

- No IG bulk driver. Single-item capture uses the `instagram` extractor
  (`extension/src/extractors/instagram.js`, registered at `registry.js:37`) and works via
  `activeTab` granted by the context-menu gesture, fetching bytes from
  `*.cdninstagram.com` / `*.fbcdn.net` (existing host permissions).
- **`instagram.com` itself is NOT a host permission and has no content script**
  (`manifest.json:7–15, 23–41`) — a bulk driver needs both added.
- The bulk engine is platform-blind: a driver is just
  `{ enumerate(input, {cursor}): AsyncIterable<BulkItem> }` yielding
  `{sourceId, mediaUrl, mediaUrlFallback, provenance, cursor}` (`bulk-engine.js:130–148`).
  Checkpointing, dedup-skip, pacing, ledger, halt-on-wall are all shared.
- `Platform.instagram` already exists in the domain (`Enums.swift`), and the `job`/
  `job_item` ledger is platform-generic — the app side needs **zero changes**.

## Mechanism options

IG's saved posts live at `instagram.com/{user}/saved/` (flat "All posts" +
per-collection), populated by private web API calls (`api/v1/feed/saved/…` or GraphQL
`saved_media`) with a `next_max_id` cursor — the same shape as the two existing drivers.

### O1 — MAIN-world response interception (X-style) — recommended
Hook `fetch`/XHR at `document_start`, capture saved-feed responses as the **user
scrolls**, parse `items[].media` → `BulkItem`s. Direct analog of `twitter-hook.js` +
`bulk-twitter.js` — the hook is near-generic (parameterized by URL matcher + message
source) and is the cheap fork target.

- ✅ Rides genuine page traffic at the human's actual scroll cadence — the safest
  possible request pattern against Meta's detection.
- ✅ Maximum reuse; no synthetic headers/signatures to maintain.
- ❌ Progress bounded by the user actually scrolling (auto-scroll assist mitigates, as
  with X).

### O2 — Service-worker cursor replay (Pinterest-style)
Replay `api/v1/feed/saved/` with `next_max_id` from the SW, credentialled, with a scraped
`X-IG-App-ID` + `csrftoken` cookie (both scrape patterns already exist for Pinterest,
`bulk-pinterest.js:51–79`).

- ✅ Self-paced, deterministic pagination; user doesn't scroll.
- ❌ Synthetic request pattern is **exactly** what Meta's anti-bot targets; highest
  account risk of any option. More headers/signatures to drift-track.

**Rejected: O2.** Marginal pacing benefit, worst risk profile.

### O3 — Official data-export ZIP (secondary phase, kept)
Meta's "Download Your Information" export contains `saved_posts.json` (historically:
post URLs + timestamps, no media bytes). Parse → URL list → feed through
[001](./001-capture-link-resolution.md)'s resolution / extension capture at gentle pace.

- ✅ Zero account risk (Meta-sanctioned, offline); deterministic and complete.
- ❌ Stale (user must re-request; hours to generate), URL-only (media still needs
  fetching), no collection structure in older exports. **2026 schema unverified** —
  confirm against a fresh export before building.

## Recommendation

**Settled (user decision): live driver (O1) first** — bookmark freshness outweighs
account risk. O3 ships second as the account-safe complement/backfill.

Account safety remains the *design* driver even with the risk accepted:

- **Pacing**: gentler than X/Pinterest defaults in `config.js`; primary enumeration
  inherits human scroll speed by construction (O1).
- **Halt, don't burn**: classify IG challenge responses (429, and 400-with-
  `checkpoint_required` body) as **halt-resumable** in the engine's outcome
  classification (`bulk-engine.js:45–59`), never per-item-permanent — a challenge pauses
  the sweep instead of hammering a flagged account.
- **Drift canary**: new `checkInstagramSaved` beside `checkTimeline`/`checkBoardFeed`
  (`drift.js:23–66`) covering the response shape (`items[].media`, `carousel_media[]`,
  `next_max_id`), the App-ID scrape regex, and the saved-URL route matcher. IG drifts
  faster than X — shorten the fixture-stale reminder window (`drift.js:94–108`).
- **Consent + warning**: the sweep consent gate gains explicit IG-specific copy (account
  throttle/checkpoint risk).

## Schema / migration impact

**None.** Carousel posts fan out to one `BulkItem` per media keyed by IG's per-media
`pk`/`id` — the same pattern as X's `media_key` fan-out (`bulk-twitter.js:107–135`) — so
engine dedup-skip works per-media. Reels/videos: poster-as-image default with a video
resolution path later (mirrors the X approach).

## Phased implementation

1. **B0 (S) — manifest.** Add `*://*.instagram.com/*` host permission, a MAIN-world
   `instagram-hook.js` content script, and a `bulk-loader.js` match. This is the
   risk-bearing permission change — flag in the publish-readiness doc (G14 territory:
   store review + privacy policy surface).
2. **B1 (M) — driver.** `instagram-hook.js` (fork `twitter-hook.js`: URL matcher +
   message source), `bulk-instagram.js` (pure parse → paginate → map → provenance,
   reusing `makeProvenance` from `extractors/base.js`), `resolveSweepSpec` IG arm
   (`bulk-context.js:73–117`), driver-build arm (`bulk-controller.js:220–223`), engine
   halt-classification for checkpoint/429, IG pacing config, `checkInstagramSaved` drift
   check.
3. **B2 (S) — export-ZIP importer.** Pure `parseSavedPostsExport(json)` → URL list →
   001's resolver / extension capture queue. Verify the 2026 export schema first.

## Test strategy

All `node --test`, no live IG (the repo's fixture discipline, 015 T9/T12):

- Pure parser over committed sanitized fixtures: single image, carousel, reel/video,
  private/unavailable tombstone, end-of-feed (`next_max_id` absent), malformed.
- App-ID scrape regex: present / moved / absent.
- `resolveSweepSpec` matrix: `/saved/`, `/saved/{collection}/`, non-saved IG URLs.
- Engine outcome classification: checkpoint/400/429 → halt-resumable.
- Drift check runs against the fixture; live drift via the existing opt-in script.
- Export parser over a committed `saved_posts.json` fixture.

## Effort: **M** (B1 ≈ the Pinterest driver; cheaper thanks to the twitter-hook fork; the extra cost is permission/pacing/drift work)

## Risks & edge cases

- **Account throttle/checkpoint is the dominant risk** — accepted by the user, mitigated
  as above; the UI warning is mandatory, not optional.
- IG renames response fields aggressively; expect drift-canary firings.
- Saved *collections* vs flat Saved (scope like X bookmark folders,
  `bulk-context.js:91–98`).
- Private/expired posts mid-sweep (tombstone → permanentFailed, sweep continues).
- The new host permission expands the store-review/privacy surface (ties to G12–G14 in
  [020](../020-production-readiness-overview.md)).

## Settled decisions

- Live driver first, export-ZIP second (user, 2026-07-13).
- Mechanism O1 (interception), not O2 (replay).

## Open questions

1. Scope v1: flat "All saved" only, or per-collection sweeps too? (Recommend flat first;
   collections are an additive `resolveSweepSpec` arm.)
2. Export schema: confirm whether the 2026 `saved_posts.json` includes media URLs or
   collection structure (needs a fresh export from the user's account).
3. Reels: poster-only in v1 (recommend) or video resolution from the start?
