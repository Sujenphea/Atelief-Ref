# 132 — Instagram saved sweep rebuilt on O2 (SW cursor replay)

## Summary

Live browser testing of the shipped O1 (interception) Instagram driver revealed it is
**non-functional on Instagram** — it captured 0 items ("saved 0"). Rebuilt the driver on
**O2 (service-worker cursor replay)**, which live-verified to sweep the entire saved feed.
This reverses the settled O1-vs-O2 decision on new evidence (002 §Mechanism).

## Why O1 failed (proven live, 2026-07-16)

Two independent, unfixable blockers:

1. **The hook never sees IG's request.** A real scroll loaded a page (grid 12→21 items)
   while instrumentation counted `window.fetch`=0, `XMLHttpRequest`=0, hook forwards=0.
   IG's saved-feed request bypasses both the page's `fetch` and `XMLHttpRequest` (captured
   reference / worker), so a `document_start` MAIN-world hook cannot intercept it. (X works
   only because it uses XHR, and we patch `XMLHttpRequest.prototype` — unbypassable by a
   reference capture.)
2. **Auto-scroll can't paginate.** IG's saved grid loads more only on a **trusted wheel
   gesture**. Every programmatic scroll (`scrollTo`/`scrollBy`/`scrollTop`/`scrollIntoView`/
   gradual stepping/synthetic wheel+scroll events) left the grid at 12 items; only a
   physical wheel grew it (12→32). A content script can only scroll programmatically.

The parser / fan-out / engine were never at fault — they were simply never fed data.

## O2 — what shipped

`bulk-instagram.js` gains the driver half (the parser is reused unchanged):
- `buildSavedFeedURL` / `savedFeedHeaders` / `makeSavedFeedFetch` / `enumerateSavedFeed`
  / `instagramSavedDriver` — a same-origin credentialled `fetch` to
  `/api/v1/feed/saved/posts/`, paginated by `next_max_id`, mirroring the Pinterest driver.
- **Only required header is `x-ig-app-id: 936619743392459`** — a public constant, verified
  live (no header → 400; `x-csrftoken`/`x-ig-www-claim`/`x-asbd-id` NOT required). Nothing
  is scraped; simpler than Pinterest.
- Challenge / non-200 → throws (`InstagramChallengeError` / `InstagramSavedError`) so the
  engine halts the sweep **resumable**, checkpoint preserved (halt, don't burn — 3A).
- Items carry the cursor that REQUESTED their page (resume re-fetches it; dedup idempotent).

**Live end-to-end walk (real account, 2026-07-16):** 2 pages, **32 posts → 78 media
items**, terminated cleanly. Pagination + `next_max_id` field name confirmed.

## Removed (O1 machinery no longer needed for IG)

- `extension/src/instagram-hook.js`, `extension/src/instagram-source.js`,
  `extension/test/instagram-hook.test.js` — deleted.
- `manifest.json`: the IG MAIN-world `[hook-core, instagram-hook]` content script removed
  (host permission + bulk-loader + web-accessible entries kept — the controller still runs
  on IG pages and makes the fetch).
- `bulk-messages.js`: `IG_SAVED_MESSAGE_SOURCE` / `IG_SAVED_REPLAY_SOURCE` removed.
- `config.js`: `PLATFORM_PACING.instagram.source` removed (no scroll source); the gentler
  `engine` pacing stays (matters more under O2's synthetic requests).
- `bulk-controller.js`: `buildInstagramDriver` rewritten Pinterest-style (credentialled
  fetch, no message wiring, no-op dispose).

`hook-core.js` + `twitter-hook.js` (the B1 shared refactor) stay — X still uses them.

## Files changed

- `extension/src/bulk-instagram.js` — O2 driver added; parser threads the request cursor;
  header comment updated.
- `extension/src/bulk-controller.js`, `config.js`, `bulk-messages.js`, `hook-core.js`,
  `manifest.json` — as above.
- `extension/test/bulk-instagram.test.js` — driver tests (URL/headers/fetch/pagination/
  challenge halt/loop guard); cursor-semantics test updated.
- `extension/test/bulk-instagram-integration.test.js` — rewritten: fixtures → driver →
  engine (multi-page pagination, cursor threading, challenge/non-200 resumable halt).
- `.docs/feature-todo/002-capture-instagram-bulk.md` — mechanism section + settled
  decisions record the O1→O2 reversal with the live evidence.

## Test results

`node --test`: **355 pass / 0 fail**.

## Remaining live-verify step

The O2 fetch was proven from the page (MAIN world). The extension makes it from the
content script (ISOLATED world) — the same pattern the working Pinterest driver uses, so
it's expected to behave identically, but the user's real sweep (reload extension → Start
on the saved page, with one app on port 47321) is the final confirmation. Expect ~78
items captured for this account.

## Migration notes

None (extension-only; the parser/engine/fan-out and the app side are unchanged).
