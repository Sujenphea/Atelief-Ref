# 090 — X post fidelity: review outcomes + implementation plan

> Review of [089](089-x-post-fidelity-design.md) / branch `feat/x-post-fidelity`,
> conducted 2026-08-13. 16 issues across architecture, code quality, tests,
> performance. Every decision below is the user's, taken interactively. **No code
> was changed during the review** — this is the work queue.

## Status: implemented and closed 2026-08-13.

Every item below is done, including the 1A live capture. See
[387](../.change-log/387-the-token-stays-in-the-room.md) for what shipped.

The capture was worth more than a fixture: taking it revealed that X had already moved
the operation→queryId table out of `api.*.js` into `main.*.js`, so thread expansion had
been silently doing nothing in the field. That fix rides the same commit as the fixture.

Ordering note: several items compose. 3A subsumes 6. 5A carries 16A. 9/10/11/12 are
test work that depends on 1A landing a real fixture. Suggested sequence at the foot.

## Architecture

**1A — Live TweetDetail fixture + drift check. MERGE-BLOCKING. ✅**
The parser is tested only against an invented `conversation()` fixture, so 35 green
tests prove nothing about the real endpoint; a shape mismatch fails soft and silent.
→ Capture one live sweep on a real thread, sanitize, commit as a fixture; add
`checkThreadDetail` to `drift.js` + a `drift-baseline.json` marker (mirrors every
other X parser). **Blocked on the user: needs a manual live capture.**

**2A — Two-way module split. ✅**
`twitter-thread.js` (521 lines) does discovery + request + parse + map + orchestrate,
breaking the seam the other X modules keep. → Pure `twitter-thread.js` (chain walk +
`mapThread`) and a new `twitter-detail-client.js` (bundle discovery, request build,
fetch, features-retry). Mirrors the `twitter-video.js` precedent. Tests split with it.

**3A — Never broadcast auth; hook becomes a request proxy. ✅**
`hook-core.js` + `twitter-hook.js` currently attach bearer + `x-csrf-token` to the
`window.postMessage` envelope on every timeline response — readable by any script on
x.com. → Hook keeps headers in a MAIN-world closure and exposes a "fetch this URL →
return the body" proxy (correlation id + timeout). Invariant to hold and test: **auth
never crosses a message boundary.** ~40 lines across the two hook files + controller.

**4A — Circuit breaker in the expander. ✅**
A rate-limited `fetchThread` is swallowed per item, so the sweep keeps issuing
TweetDetail calls for every remaining bookmark, silently. → Trip a breaker in
`createThreadExpander` on any 429 / N consecutive failures: stop expanding for the
rest of the sweep, log once. Keeps "expansion is a bonus, never a blocker."

## Code quality

**5A — Extract `stampGroup(items, {permalink, startIndex})`. ✅**
`mapThread` re-implements `mapTweet`'s group re-stamp (shared permalink + running
`carouselIndex`) — a JS↔Swift contract now duplicated. → One helper in
`bulk-twitter.js`, called by both. Carries 16A (single-pass stamp).

**6A — Fold header-DRY into the 3A rework. ✅**
`hook-core.js` collects headers two ways (fetch reads object/Headers/array; XHR
accumulates via patched `setRequestHeader`). 3A rewrites this path anyway. → Make "no
duplicate header logic survives" an explicit checkpoint of 3A; no separate change.

**7A — Log dropped forks. ✅**
`selfThreadChain` keeps the earliest-id fork of a self-branching thread and silently
drops the other arm. The defect is the silence, not the heuristic. → `log()` when a
fork is discarded. One line. (Real threads rarely fork; full-fork capture rejected as
over-engineering.)

**8A — Leave `combineQuoteText` as-is (do nothing). ✅ held.**
The composed multiline `title` (quoter + `↩ @author: quoted`) feeds FTS and any
single-line UI, unbounded. But `title` already carries multiline note-tweet text, so
the UI concern isn't new, and a separate `quotedText` field would ship data the Swift
app doesn't read yet. Revisit only if a specific view mis-renders.

## Tests

**9A — Re-point parser tests at the committed fixture** (depends on 1A). ✅ Keep the
synthetic fixtures only for forks/branches a real capture won't contain.

**10A — Negative security tests. ✅** Assert `cookie`, `x-client-transaction-id`, and
arbitrary headers are absent from every forwarded/proxied payload; under 3A, assert
auth never crosses the message boundary. Mirrors the `CaptureAuth` negative suite.

**11A — End-to-end seam integration test. ✅** A fake page yields a threaded tweet, a
fake fetch returns the conversation; assert enumerated items are the whole thread.
Plus a throw-in-`expandItems` case asserting graceful degrade to the raw page (the
load-bearing "expansion never blocks a sweep" property, currently unit-only).

**12A — Failure-path tests. ✅** `scrapeQueryId` on HTML/empty/truncated bundle input →
null (X serving an error page is a likely real input); exact-boundary assertion that
retry stops at `MAX_FEATURE_RETRIES`.

## Performance

**13A — Bound `chainCache` with an LRU (~50). ✅** Reuse the bounded-buffer pattern from
`hook-core.js`'s replay buffer (DRY). Same-thread bookmarks are adjacent in the feed,
so a small cap keeps ~all the dedup value at a fixed memory ceiling.

**14B — Do nothing beyond the 4A breaker. ✅ held.** Root probing (one TweetDetail per
bookmarked root with replies, ~doubling requests on a reply-heavy feed) is the D9 cost
already chosen deliberately. 4A handles the failure case; success-but-expensive is
working as designed. Revisit only with real sweep data — not to be assumed.

**15A ✅ — Build a `parentId → children[]` index once** in `selfThreadChain`, replacing
the per-descendant `filter` (super-linear on a huge conversation). Also simplifies the
walk — faster and clearer at once.

**16A — Rides 5A. ✅** Give `stampGroup` a `startIndex` so `mapThread` stamps in one pass
instead of map-then-rewrite. No standalone work.

## Suggested implementation sequence

1. **1A** first (blocked on user's live capture) — it gates 9A and de-risks everything.
2. **3A** (+ 6A checkpoint, + 10A tests) — the security rework, self-contained.
3. **5A** (+ 16A) then **15A**, **7A** — parser/chain refactors, pure, well-covered.
4. **4A** then **13A** — expander resilience + memory bound.
5. **2A** — module split last, once the code inside has settled (avoids re-splitting).
6. Test work **9A / 11A / 12A** alongside the code each covers.

`14B` and `8A` are no-ops (decisions to hold the line).

## 1A outcome

Captured 2026-08-13 from a real threaded post, sanitized, committed as
`extension/test/fixtures/x-thread-detail.json`.

- **29 tweets, 13 authors, a 5-tweet self-thread, and 12 of the author's own replies to
  commenters** — the trap `selfThreadChain` exists to avoid, finally on real data.
- `checkThreadDetail` passes against it: `tweets=29 withParent=28 withAuthor=29 chain=5
  items=8`. It is registered as the `x-thread` check and now runs from the committed
  fixture on every `npm run drift-check`.
- The `xThread` baseline marker is dated and records the live `queryId`
  (`XMOz5h24KAZ86qKffKTLdQ`), the bundle it came from, and the field paths the walk
  depends on.
- Sanitization: handles, display names, bios, ids, base64 node ids, media/profile/`t.co`
  urls and post text are synthetic; keys, nesting and every reply relationship are
  verbatim. Audited to zero surviving identifiers from the original response.

### What it caught

**A production break, immediately.** X no longer ships `api.*.js`; the
operation→queryId table is in `main.*.js`. `apiBundleURLs` matched only the `api.*`
filename, so it returned nothing, `resolveQueryId` returned null, and expansion was off
for every sweep — invisibly, because "no queryId" degrades to "this tweet wasn't a
thread". Fixed by widening the net to any `responsive-web` bundle, ranked (`api.*`,
`main.*`, rest) so the first hit still costs one fetch.

**A coverage gap neither fixture closed.** Mutation-testing the re-pointed tests showed
that the live capture and the synthetic bodies BOTH passed with the "only the author's
own replies are candidates" guard removed: in each, every continuation predates every
reply, so "earliest child wins" gave the right answer by accident. A stranger replying
before the author posts part 2 gets the lower id and would be followed out of the
thread. Now covered by a targeted synthetic case.

### Standing reminder

The `xThread` fixture carries a 30-day staleness window, the same as the other X
markers, because the queryId rotates every 2-4 weeks and the bundle layout evidently
moves too. `npm run drift-check` reports it. Re-capture with:

    npm run drift-check -- --x-thread <fresh capture>
