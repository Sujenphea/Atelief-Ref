# 002 — Capture: Instagram Saved-Posts Bulk Import

> Covers "Save designs from: bookmarks from X, Instagram". **X is done** — the bulk
> sweep handles X Bookmarks (incl. bookmark folders) and Likes, plus Pinterest boards
> (see [015–018](../015-bulk-import-overview.md)). The gap is **Instagram saved posts**,
> explicitly deferred in 015 §scope. Single-item IG capture already works via the
> context menu.
>
> **Reviewed 2026-07-15** (interactive plan review, 14 issues settled — see §Settled
> decisions). The export-ZIP path was descoped to
> [017](./017-capture-instagram-export.md).

## Current state

- No IG bulk driver. Single-item capture uses the `instagram` extractor
  (`extension/src/extractors/instagram.js`, registered at `registry.js:37`) and works via
  `activeTab` granted by the context-menu gesture, fetching bytes from
  `*.cdninstagram.com` / `*.fbcdn.net` (existing host permissions).
- **`instagram.com` itself is NOT a host permission and has no content script**
  (`manifest.json:7–18, 23–36`) — a bulk driver needs both added.
- The bulk engine is platform-blind: a driver is just
  `{ enumerate(input, {cursor}): AsyncIterable<BulkItem> }` yielding
  `{sourceId, mediaUrl, mediaUrlFallback, provenance, cursor}` (`bulk-engine.js:130–148`).
  Checkpointing, dedup-skip, pacing, ledger, halt-on-wall are all shared.
- The X interception stack is **three** layers, not two: the MAIN-world hook
  (`twitter-hook.js`), the **push→pull source adapter** (`twitter-source.js` — queue,
  auto-scroll, settle timing, stall detection, scope gating), and the pure parser
  (`bulk-twitter.js`). The source currently hardcodes its parser + scope matcher
  (`twitter-source.js:22`) — generalizing it is part of this feature (§B1).
- `Platform.instagram` already exists in the domain (`Enums.swift`), and the `job`/
  `job_item` ledger is platform-generic — the app side needs **zero changes** (holds
  under the per-media fan-out decision, §data model).

## Mechanism (SETTLED — O2, after O1 failed live 2026-07-16)

IG's saved posts live at `instagram.com/{user}/saved/`. The flat feed is a REST call —
`GET instagram.com/api/v1/feed/saved/posts/`, same-origin, `credentials:'include'`,
paginated by a top-level `next_max_id` (+ `?max_id=` on the next request).

> ⚠️ **O1 (MAIN-world interception) was built (B1–B4) then found NON-FUNCTIONAL on
> Instagram by live browser testing (2026-07-16). Two independent, unfixable blockers:**
> 1. **The hook never sees IG's request.** A real scroll loaded a page (grid 12→21), but
>    `window.fetch` calls = 0, `XMLHttpRequest` calls = 0, hook forwards = 0. IG's
>    saved-feed request bypasses BOTH the page's `fetch` and `XMLHttpRequest` (a captured
>    reference / worker) — so a `document_start` hook can't intercept it. (X works because
>    X uses XHR, and we patch `XMLHttpRequest.prototype`, which a reference-capture can't
>    bypass.)
> 2. **Auto-scroll can't paginate.** IG's saved grid only loads more on a **trusted wheel
>    gesture**. Every programmatic method (`scrollTo`/`scrollBy`/`scrollTop`/
>    `scrollIntoView`/gradual stepping/synthetic wheel+scroll events) left the grid at 12
>    items; only a physical wheel grew it (12→32). A content script can only scroll
>    programmatically.

**O2 — service-worker cursor replay — NOW SETTLED (the only mechanism that works).** The
content script REPLAYS the endpoint itself: a same-origin credentialled `fetch` to
`/api/v1/feed/saved/posts/`, following `next_max_id`. Live-verified 2026-07-16:
- The ONLY required header is `x-ig-app-id: 936619743392459` (a **public constant** — no
  header → 400; `x-csrftoken` / `x-ig-www-claim` / `x-asbd-id` NOT required). Nothing is
  scraped — simpler than Pinterest (which needs a scraped app-version + pws-handler).
- A full live walk swept the **entire** saved feed — **2 pages, 32 posts → 78 media
  items** — and terminated cleanly. Pagination + `next_max_id` field name confirmed live.

This sidesteps BOTH O1 blockers (the SW originates the request; cursor pagination, no
scroll). Mechanically it mirrors the working **Pinterest driver** (SW credentialled fetch
+ cursor). The tradeoff O2 was rejected for — a synthetic request pattern carries more
account risk than riding real traffic — stands, but O1 simply does not function on IG, so
the real choice was O2 or no Instagram sweep. The account-risk warning UI (B4) is now
doubly warranted; pacing (13A) matters more, not less.

O3 (official data-export ZIP) remains **descoped to [017](./017-capture-instagram-export.md)**.

> ✅ Endpoint shape resolved by B0 recon (2026-07-15): REST `api/v1/feed/saved/posts/`.
> The response is `{ items: [{ media }], more_available, next_max_id?, status }`; each
> `media` carries `pk`/`id`/`code`, `media_type` (1 image · 2 video/reel · 8 carousel),
> `product_type`, `user.{pk,username,full_name}`, `caption.text`,
> `image_versions2.candidates[]` (poster, largest-first), `video_versions[]` (reels),
> and `carousel_media[]` (children, each its own `pk` + `image_versions2` / optional
> `video_versions`). Sanitized fixture committed: `test/fixtures/instagram-saved.json`.

## Data model: carousel fan-out (settled 1A)

A carousel post fans out to **one `BulkItem` per medium**, `sourceId` = IG's per-media
`pk`, via the **plain-image relay path** (no `content` descriptor) — the Pinterest
model, not the tweet model. (The doc previously cited "X's media_key fan-out"; that
pattern was removed by `fe1a3ee` — a tweet is now ONE item with a `media[]` payload.
IG can't copy that without a new app-side kind, and for a design-reference library the
images are the substance of an IG save.) Consequences:

- Engine dedup-skip works per-media; caption/author repeat in each item's provenance.
- **Poster pick:** `image_versions2.candidates[]` is observed largest-first, but the
  mapper should still take the max-by-width defensively (mirror Pinterest's
  `pickPinImages` sort, `bulk-pinterest.js:101–114`) rather than trust `[0]` — cheap
  insurance against IG reordering. `320px` thumbnails are the fallback URL.
- A first-class `instagramPost` kind can layer on later via 003's additive
  multikind pattern — no migration, just a new capture path.
- **Reels (settled 7A):** poster (`image_versions2`) as the card by default, and the
  best `video_versions[]` URL stashed in `rawMetadata.videoUrl` — the relay already
  forwards that under the existing resolve-video toggle
  (`bulk-controller.js:68–84`), so reel video capture costs one mapper field + a
  `selectBestVideo`-style picker (reuse/adapt `twitter-video.js` if shapes align).

**Schema / migration impact: none** (app-side unchanged).

## Challenge handling (settled 3A): detect in hook/source, not the engine

Under O1 the **page** makes the feed requests — the engine's relay only ever sees CDN
byte fetches and localhost ingests, so a Meta challenge (`checkpoint_required`, feed
429) can never reach `classifyIngestResult`. The original "engine halt-classification"
work item is dropped as dead code. Instead:

- The hook forwards matched saved-feed responses **including non-2xx bodies** (XHR
  `load` fires on 4xx; the body is parseable JSON).
- The IG parser recognizes the challenge shape; the source throws a `ChallengeError`
  (sibling of `TimelineStallError`) → the engine's existing enumeration-error catch
  halts the sweep **resumable** (`bulk-engine.js:196–213`), job closes `paused`,
  checkpoint preserved — with honest copy: "Instagram is challenging this account —
  solve it in the tab, then resume."
- The generic stall path (`maxIdleRounds` → `TimelineStallError`) remains the free
  backstop for challenges that produce no parseable body.

The relay's existing classification already covers what it *can* see: CDN 429 →
retryable, 401/403 → halt-resumable. **Known behavior, documented not changed:** IG
CDN URLs are time-signed (`oe`/`oh` expiry). Within a sweep they're fresh (enumerated
seconds before fetch) and a resume re-enumerates, so a CDN 403 more likely means a
real block — halting on it is the desired "halt, don't burn".

## Account safety posture

- **Pacing (settled 13A):** per-media pacing (fan-out means a 10-image carousel takes
  10 paced slots — slow is the safe direction), with a new **`PLATFORM_PACING` map in
  `config.js`** covering both engine knobs and source timing, selected by the
  controller bootstrap (which currently passes no config —
  `bulk-controller.js:226`). Starting IG values: `MAX_CONCURRENCY: 2`,
  `PACING_MS: 1500`, `PACING_JITTER_MS: 1200`, `settleMs: 3000`, `maxIdleRounds: 5`.
  X/Pinterest keep today's globals.
- **Halt, don't burn:** the ChallengeError path above; never per-item-permanent.
- **Drift canary (settled 12A):** new `checkInstagramSaved` beside
  `checkTimeline`/`checkBoardFeed` (`drift.js`), asserting **exact** carousel fan-out
  counts (a carousel fixture maps to exactly N items with distinct per-media `pk`s),
  `video_versions[]` extraction, `next_max_id` presence, the saved-URL route matcher,
  and the challenge-shape recognizer. The App-ID-scrape check in the earlier draft was
  **O2 residue — dropped** (O1 never builds a request). `drift-baseline.json` is
  restructured to per-platform `{ capturedAt, staleAfterDays }` (X/Pinterest 30d, IG
  **14d**) with `fixtureStaleReminder` reporting per platform.
- **Warning UI (settled 2A):** the popup has **no consent gate today** (Start launches
  on one click, `popup.js:61–75`) — an IG-specific warning/acknowledge row before
  Start is enabled is a **named work item (B4)**, not a copy edit. Mandatory, not
  optional.

## Phased implementation

0. **B0 (S, prerequisite — settled 8A) — recon + fixtures. ✅ MOSTLY DONE (2026-07-15).**
   - ✅ Transport + response shape verified (see §Mechanism); `items[].media` with
     per-media `pk`, `carousel_media[]`, `image_versions2`/`video_versions`.
   - ✅ Sanitized fixture committed (`test/fixtures/instagram-saved.json`): 1 image +
     1 reel + 1 carousel, structure exact, every real id/handle/url/caption replaced,
     raw capture gitignored in `/resources/ig-saved-page1.json`. Leak-checked against
     all 153 real tokens → clean.
   - ✅ Drift baseline seeded (`drift-baseline.json` → `markers.instagram`, 14d window).
   - ✅ **Second fixture + live validation (2026-07-15):** a real page-2 capture
     (`instagram-saved-page2.json`, 11 posts → 25 items incl. an 11-child carousel + 7
     reels) runs CLEAN through the real parser (`drift-check --instagram`, no drift), and
     its `?max_id=<token>` request URL **confirms the pagination request param**.
   - ✅ **CLOSED 2026-07-16 (live recon):** (a) a **non-terminal `next_max_id`** is now
     observed directly — `GET …/saved/posts/?count=12` returns `more_available: true` with
     `next_max_id` populated (the resume cursor is no longer synthesized-only). (c) the
     **collection endpoint** is resolved: `GET /api/v1/feed/collection/<id>/posts/`, same
     envelope/pagination/header as the flat feed (→ collections built, changelog 134).
   - ⚠️ **STILL OPEN:** (b) **Feed ordering** — recon showed the saved feed is **NOT**
     post-time-ordered (`taken_at` is jumbled), consistent with newest-**save**-first, but
     that isn't *proven* read-only (all 32 items were in one collection, so membership-by-
     depth was uninformative). Proving newest-first needs a save-a-fresh-post mutation;
     gates the re-sweep early-stop. (d) a **live challenge body** — nice-to-have.
1. **B1 (M, settled 2A+5A) — shared refactors, X-regression-gated.**
   (a) Extract `hook-core.js`: a classic-script (no import/export)
   `installResponseHook({ isMatch, messageSource, replaySource, target, post })`
   carrying ALL the machinery (fetch wrap, XHR patch, bounded replay buffer, replay
   listener, idempotency guard, never-break-the-page discipline, **4xx-body
   forwarding** for 3A); `twitter-hook.js` shrinks to ~25 lines (matcher + constants +
   install). Manifest entries become ordered pairs `"js": ["src/hook-core.js",
   "src/twitter-hook.js"]`.
   (b) Generalize `twitter-source.js` → `createInterceptSource({ parsePage,
   matchesScope, scroll, sleep, settleMs, maxIdleRounds, scope, host })`; X becomes a
   thin config. Existing X unit/integration suites must pass unchanged — they are the
   regression net for this phase.
2. **B2 (S) — manifest.** Add `*://*.instagram.com/*` host permission, the
   `[hook-core, instagram-hook]` MAIN-world pair at `document_start`, `bulk-loader.js`
   match, `web_accessible_resources` match. This is the risk-bearing permission change
   — flag in the publish-readiness doc (G12–G14 territory: store review + privacy
   policy surface, [020](../020-production-readiness-overview.md)).
3. **B3 (M) — driver.** `instagram-hook.js` (thin config over hook-core),
   `bulk-instagram.js` (pure: parse page → fan out per media → `makeProvenance` →
   challenge recognizer → `next_max_id` cursor), IG `createInterceptSource` config +
   `buildInstagramDriver` in `bulk-controller.js` (incl. replay-request wiring),
   `resolveSweepSpec` IG arm (**settled 6A**: flat-only v1 — accept `/{user}/saved/`
   + `/{user}/saved/all-posts/`, **refuse a collection page with a typed reason** +
   honest `REASON_MESSAGE` copy; collections are a later additive arm, as X folders
   were), IG `matchesScope` analog (a browsed collection's **buffered** pages must
   not leak into a flat sweep — the exact contamination bug X fixed),
   `PLATFORM_PACING` + bootstrap lookup, `checkInstagramSaved` + baseline restructure.
4. **B4 (S, settled 2A) — popup warning UI.** IG-specific account-risk warning +
   acknowledge step gating Start (`popup.js` / `popup-view.js`), copy naming
   throttle/checkpoint risk. Tested in `popup-view.test.js`.

## Test strategy

All `node --test`, no live IG (fixture discipline, 015 T9/T12). Settled 9A/10A/11A/12A:

- **Pure parser** over B0's sanitized fixtures: single image, carousel (exact-N
  fan-out, distinct per-media `pk` sourceIds), reel (poster card + `videoUrl`
  stashed), private/unavailable tombstone (skip, sweep continues), end-of-feed
  (`next_max_id` absent), malformed page, challenge body → recognizer.
- **Hook matrix (10A):** classic-load `[core, site]` pairs in order (both platforms)
  and assert install; syntax-guard all three files (`new Function` throws on
  import/export); double-injection idempotency; replay-buffer bound; **4xx-body
  forwarding**; non-matched URLs never post; wrong load order fails loudly (pins the
  manifest ordering constraint).
- **Challenge path (11A):** parser/source level (challenge fixture → `ChallengeError`
  with the right reason; feed 429 likewise) AND one integration case: challenge
  mid-sweep → `runSweep` returns `halted`, checkpoint survives, job closes `paused`.
  (Replaces the earlier draft's engine-classification tests — dead code under O1.)
- **Integration parity (9A):** mirror `bulk-twitter-integration.test.js` — IG fixture
  → source → engine full sweep (carousel fan-out asserted end-to-end: one post → N
  relay calls), plus the IG replay-contamination test (buffered collection page fed
  to a flat sweep ingests nothing).
- **`resolveSweepSpec` matrix:** flat `/saved/`, `/saved/all-posts/`, a collection
  page (typed refusal), non-saved IG URLs, non-IG URLs.
- **Drift:** `checkInstagramSaved` against the fixture; per-platform stale windows in
  `fixtureStaleReminder`; live drift via the existing opt-in script.
- **Popup:** warning row gates Start; acknowledge flow; IG copy.
- X suites pass unchanged through B1 (regression gate).

## Deferred (documented, not built)

- **Re-sweep early-stop (settled 14A):** every re-sweep re-scrolls the whole saved
  feed (skips are cheap — no pace, no relay, no ledger write — but the scroll isn't).
  Design when wanted: engine config `STOP_AFTER_CONSECUTIVE_SKIPS` (IG-only),
  completing the sweep once K contiguous known items pass. **Blocked on:** B0
  confirming save-time ordering, and an early-stop guard for stranded
  `retryableFailed` items (e.g. only early-stop when the prior job closed
  `complete`). v1 matches X's current full-re-scroll behavior — no regression.
- ~~**Collections (6A):**~~ **BUILT 2026-07-16** (changelog 134). Live recon settled the
  endpoint (`GET /api/v1/feed/collection/<id>/posts/` — identical envelope + `?max_id=`
  pagination + `x-ig-app-id` header to the flat feed) and the URL shape
  (`/{user}/saved/{slug}/{numericId}/`). Additive `resolveSweepSpec` arm +
  `isCollectionFeedRequest` matcher + `saved:collection:<id>` checkpoint scope; driver reads
  `input.collectionId`. Same account-risk gate applies.
- **First-class `instagramPost` kind (1C):** additive via 003's multikind pattern if
  post-level grouping is ever wanted.
- **Export-ZIP backfill:** [017](./017-capture-instagram-export.md).

## Effort: **M–L** (B1 refactors added ~S–M over the original M; B0 is an hour of the
user's time; everything else shrank or moved out)

## Risks & edge cases

- **Account throttle/checkpoint is the dominant risk** — accepted by the user
  (2026-07-13), mitigated by pacing/challenge-halt/warning UI as above.
- IG renames response fields aggressively; expect drift-canary firings (14d window).
- Time-signed CDN URLs: fresh within a sweep; a 403 halts resumable (desired).
- Private/expired posts mid-sweep: tombstone → skipped/permanentFailed, sweep continues.
- Memory: per-media known-set grows ~3–5× faster than posts (a few MB at 50k ids —
  fine, don't pre-optimize); the source queue only grows if the user out-scrolls the
  paced engine (harmless lag).
- The new host permission expands the store-review/privacy surface (G12–G14 in
  [020](../020-production-readiness-overview.md)).
- Add the IG parser a bounded deep-search fallback (à la `findInstructions`) **only if
  recon/drift shows nesting volatility** — that resilience is earned, not free.

## Settled decisions

- Live driver first; export-ZIP second → then **descoped to 017** (user, 2026-07-13 /
  2026-07-15).
- Mechanism O1 (interception), not O2 (replay) (user, 2026-07-13) — **REVERSED
  2026-07-16**: O1 was built (B1–B4) but live browser testing proved it non-functional on
  Instagram (hook can't intercept IG's request; auto-scroll can't paginate — see
  §Mechanism). **Rebuilt on O2** (SW cursor replay), live-verified to sweep the whole feed
  (2 pages, 32 posts → 78 media). User approved the rebuild ("try and build", 2026-07-16).
- 2026-07-15 plan review (all user-confirmed):
  1. **1A** carousel → per-media fan-out, plain-image path (per-media `pk` sourceId).
  2. **2A** generalize `twitter-source.js` → `createInterceptSource`; warning UI is a
     named work item (no consent gate exists today).
  3. **3A** challenge detection in hook/source (`ChallengeError`); engine
     classification item dropped as dead code under O1.
  4. **4A** export-ZIP descoped to its own doc (001 auth-wall dead-end; unplanned
     tab-driving queue).
  5. **5A** shared classic `hook-core.js` + thin per-site hook configs.
  6. **6A** flat-only v1; collections refused with typed reason.
  7. **7A** reels: poster default + `rawMetadata.videoUrl` so the existing
     resolve-video toggle works.
  8. **8A** recon-first: no parser code before live-captured, sanitized fixtures.
  9. **9A** integration-test parity with X (incl. replay-contamination).
  10. **10A** full hook test matrix.
  11. **11A** challenge-path tests at parser/source + integration depth.
  12. **12A** drift canary respec'd to O1 (App-ID check dropped; per-platform stale
      windows, IG 14d; exact-count assertions).
  13. **13A** `PLATFORM_PACING` map (engine + source knobs), per-media pacing kept.
  14. **14A** re-sweep early-stop deferred, documented above.

## Open questions

1. B0 recon may still revise parser details (transport, field names, feed ordering) —
   the decisions above fix the *architecture*, not the observed shapes.
2. Warning-UI form: inline acknowledge checkbox vs a two-click confirm — decide at B4
   (copy matters more than the widget).
