# 389 — It blamed the wrong half

Thread expansion was dead in the field, and the log said the X bundle had moved. The
bundle was fine.

## What was actually wrong

Nothing in the code. The `hook-core.js` running on x.com was an OLD BUILD — its
envelopes carried `{ source, url, json }` and no `hasAuth` key, because the field only
landed in `b6f9cef` / `ebcd644`. Measured live: the loaded hook also never answered a
proxy request, confirming it predates the whole 3A seam.

From there the chain is short and entirely silent:

1. `bulk-controller.js` — `if (features && event.data.hasAuth) harvested = { features }`
   never fires, because the key does not exist.
2. `resolveCredentials()` returns null on `!harvested`.
3. `twitter-detail-client.js` sets `credentials = null` and returns every page's items
   untouched, for every sweep, forever.

**Fix: reload the unpacked extension and hard-reload the tab.** MV3 does not pick up
content-script changes on its own.

## What this changed in the code

The failure was invisible for days because both ways of having no credentials logged the
same line — `"thread expansion off: no TweetDetail queryId (X bundle moved?)"` — and the
two causes are at opposite ends of the system. A stale MAIN-world hook read as a moved
bundle and sent the search to the one component that was working.

So the resolver now names its own failure:

- `bulk-controller.js` — `resolveCredentials` resolves to `{ queryId, features }`, or to
  `{ reason }` distinguishing "the hook has not handed over X's auth headers (…or the
  MAIN-world hook is an older build — reload the extension)" from "no TweetDetail
  queryId in any X bundle".
- `twitter-detail-client.js` — logs that `reason` verbatim. A resolver that throws is
  reported as such; a bare `null` still logs, just without specifics, so every existing
  caller keeps working unchanged.

## What was verified live, and is now retired as a risk

The stale hook had been masking two untested assumptions. Both were measured against X
as it shipped on 2026-08-13:

- **`apiBundleURLs` ranking is correct.** `api.*.js` no longer exists on X at all. The
  ranking puts `main.*.js` first and the queryId came out of the FIRST bundle fetched —
  one request, not a scan. The 1A fix holds against the live build.
- **Omitting `x-client-transaction-id` is safe.** Replaying exactly the header set the
  hook forwards (bearer + `ct0`, no transaction id) against `TweetDetail` returned
  **HTTP 200, zero errors, 3 instructions, 15 entries**. This was the largest untested
  assumption in the design — X derives that header per-request, and a replayed one would
  be worse than none, so the whole feature rested on it being optional. It is.

## Files changed

- `extension/src/bulk-controller.js` — `resolveCredentials` returns `{ reason }`
- `extension/src/twitter-detail-client.js` — log the reason; doc the contract
- `extension/test/twitter-detail-client.test.js` — the two causes log distinctly;
  a throwing resolver and a bare `null` both still log

## Migration notes

None. `resolveCredentials` is an injected seam with two in-tree callers, and the
consumer still accepts a bare `null`.

## Not done

A version stamp on the hook envelope would catch the NEXT skew automatically rather than
after a live investigation. Considered and deferred — the stale load came out of active
development, and a reload fixes it.
