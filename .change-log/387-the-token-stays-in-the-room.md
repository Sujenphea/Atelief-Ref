# 387 — the token stays in the room

The X thread expansion shipped in 384 worked, and it worked by handing the page's
auth around. Reviewing it ([090](../.docs/090-x-post-fidelity-review-plan.md)) turned
up fifteen further items across security, resilience, structure and tests. All of them
are here — including the live capture, which found a production break the moment it was
taken.

## The hook no longer broadcasts credentials

To ask X for a conversation you need the bearer and csrf headers the page just sent.
The MAIN-world hook read them off each timeline request and attached them to the
`window.postMessage` envelope it hands the controller — where **every script on x.com
could read them**, because that bus is shared by everything on the page.

The hook now keeps them in its own closure and never emits them. What crosses is a
boolean, `hasAuth`, which is all a listener actually needs to know. When the sweep
wants a conversation it asks the hook to fetch it:

    controller  →  { source, id, url }        →  hook   (holds the headers)
    controller  ←  { source, id, status, json } ←  hook   (returns only the body)

The hook is now a thing that makes an authenticated request on request, so what bounds
it is how narrow the url gate is: same-origin, https, and exactly
`/i/api/graphql/{id}/TweetDetail`. Nothing else is reachable, and everything is GET by
construction. A conversation body is something any script on that page could already
fetch with the cookie it already has, so proxying it grants nothing new — proxying a DM
endpoint would, which is why the gate is an allowlist of one shape rather than "any
x.com url".

- `src/hook-core.js` — headers into a closure, `proxy` install option, one message
  listener serving both replay and proxy.
- `src/hook-proxy.js` (new) — the isolated-world client. Turns the message round-trip
  into something `fetch`-shaped, owns the correlation ids, the timeout, and disposal.
- `src/twitter-hook.js` — supplies `isProxyableRequest`, the security boundary.
- `src/bulk-controller.js` — harvests `features` + `hasAuth`; the expander's
  `fetchImpl` is the proxy. `fetchThread` now takes a url and nothing else, so the
  sweep side *cannot* hold a credential rather than merely not doing so.

The negative tests serialize everything that crosses the boundary and grep it for the
secret, which catches a leak through any field rather than one expected property.

## Expansion gives up instead of hammering

A rate-limited conversation read was swallowed per item, so a 429 let the sweep keep
firing TweetDetail at X for every remaining bookmark — hundreds of refused requests,
silently, which is the behaviour most likely to turn a rate-limit into a block. A
breaker now trips on the first 429, or three consecutive failures, and expansion goes
quiet for the rest of the sweep with one log line. The sweep itself carries on and
saves everything unexpanded.

For that to work `fetchThread` had to stop swallowing the status: three outcomes yield
no tweets — a conversation that genuinely has none (200), a refused request (4xx), one
that never arrived (0) — and only the caller can tell them apart. It returns
`{ tweets, status }`.

The conversation cache is LRU-bounded at 50. Same-thread bookmarks are adjacent in the
feed, so a small cap keeps essentially all the dedup value at a fixed ceiling.

## The parser got faster and less quiet

- `selfThreadChain` builds a parent→children index once instead of re-scanning every
  tweet at each step — super-linear on exactly the popular conversation most likely to
  be large.
- A self-branching thread still keeps the earliest arm, but now **says so**. The
  heuristic was fine; the silence wasn't. A capture missing an arm is only diagnosable
  if the dropped id is in the log.

## One place writes the grouping contract

`mapThread` had re-implemented `mapTweet`'s group re-stamp — the shared permalink and
running `carouselIndex` that `PostGrouping.swift` reads. Two copies of a cross-language
contract. Extracted to `stampGroup(items, { permalink, startIndex, extraMetadata })`,
called by both; `startIndex` also lets a thread be stamped in one pass instead of
map-then-rewrite.

## Two modules where there was one

`twitter-thread.js` was doing discovery, request, parse, map and orchestration in 521
lines, breaking the seam the other X modules keep.

- `src/twitter-thread.js` (220) — pure. Total functions over a JSON body: the
  conversation walk and `mapThread`. No network, no DOM, no message boundary.
- `src/twitter-detail-client.js` (410, new) — bundle discovery, request building, the
  fetch, the features-drift repair, the expander.

Tests split with it, sharing `test/fixtures/x-conversation.js`. That helper is not a
test file, so `npm test` now globs `test/*.test.js` rather than the whole directory.

## The capture, and what it caught immediately

The parser had never seen a real `TweetDetail` response — 35 green tests against an
invented body, pinning its own logic and proving nothing about the live endpoint.

It has now. `test/fixtures/x-thread-detail.json` is a real 29-tweet conversation: 13
authors, a 5-tweet self-thread, and **12 of the thread author's own replies to
commenters** — the exact trap the walk exists to avoid, on real data rather than a
hand-built approximation. Sanitized: handles, display names, bios, ids, base64 node ids,
media/profile/`t.co` urls and post text are all synthetic; keys, nesting and every reply
relationship are verbatim. Audited to zero surviving identifiers from the original.

`checkThreadDetail` passes against it — `tweets=29 withParent=28 withAuthor=29 chain=5
items=8` — asserting what a real capture has to satisfy: tweets still collect from both
entry shapes, the reply link and the author path still resolve (named separately,
because they fail identically from the outside and have different fixes), a self-thread
of 2+ still walks out, and it still maps to one permalink with a contiguous open order.

**Making the capture found a live break.** X no longer ships `api.*.js`. The
operation→queryId table now lives in `main.*.js`, so `apiBundleURLs` — which matched
that one filename — returned nothing, `resolveQueryId` returned null, and thread
expansion was silently off for every sweep. It degrades to "this tweet wasn't a thread",
which is precisely why nothing surfaced it. The net is now any `responsive-web` bundle,
RANKED rather than filtered (`api.*`, then `main.*`, then the rest); the first hit wins,
so the common case is still one fetch and the tail survives the next move.

That is the argument for 1A in one afternoon: the fixture meant to protect against a
future drift found a current one instead.

## What mutation-testing found that neither fixture did

Re-pointing the tests (9A) and then trying to break the code showed that NEITHER the
live capture nor the synthetic bodies exercised the "only the author's own replies are
candidates" guard. In both, every continuation was posted before any reply arrived, so
"earliest child wins" happened to give the right answer even with the guard removed.

A stranger who replies to the head within seconds — before the author posts part 2 —
gets the lower id, and would have been followed straight out of the thread, filing their
words under the author's post. Real, and now covered.

## Files

    src/hook-core.js              headers in a closure; the request proxy
    src/hook-proxy.js             new — the isolated-world proxy client
    src/twitter-hook.js           isProxyableRequest; proxy tags
    src/bulk-controller.js        proxy-backed expander; hasAuth
    src/bulk-messages.js          HOOK_PROXY_{REQUEST,REPLY}_SOURCE
    src/twitter-thread.js         pure: the walk + mapThread (was 521 lines)
    src/twitter-detail-client.js  new — discovery, request, fetch, expander, breaker,
                                  and the api.*.js -> main.*.js bundle fix
    src/bulk-twitter.js           stampGroup
    src/drift.js                  checkThreadDetail
    scripts/drift-check.js        reports a check with no fixture as awaiting one
    test/fixtures/x-thread-detail.json  new — the live sanitized capture
    test/fixtures/drift-baseline.json   xThread marker, dated + queryId recorded
    test/fixtures/x-conversation.js     new — shared synthetic bodies
    test/twitter-thread-integration.test.js  new — hook → proxy → expander → engine

462 → 517 tests.

## Migration notes

None. No stored shape changed: `originalURL`, `carouselIndex`, `threadId`,
`threadIndex` and `repostedBy` are written exactly as before — `stampGroup` is where
they are written from, not what they are. The message protocol between the hook and the
controller did change (`headers` is gone, `hasAuth` and the proxy pair are new), but
both sides ship in the same extension, so there is no version skew to handle beyond
reloading it.

`fetchThread` returns `{ tweets, status }` rather than an array, and no longer accepts
`headers` — internal to the extension, no caller outside it.

One operational note: because the `api.*.js` match had already broken, thread expansion
was doing nothing in the field before this branch. Sweeps run after it will start
issuing TweetDetail calls again — that is the feature working, not a regression, and the
4A breaker is what bounds it if X pushes back.
