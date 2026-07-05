# 064 — Bulk import: Pinterest resource 403 fix (x-pinterest-pws-handler)

Phase 9 live verification ([.docs/019](../.docs/019-bulk-import-verification.md) §T10)
surfaced the Phase-0 403: the credentialled `BoardFeedResource` fetch our driver sent
was rejected with **HTTP 403** even with a correctly-scraped `X-APP-VERSION` +
`csrftoken`. Captured the real request and **bisected the header set live** against the
running board — holding URL/params constant, varying only headers:

| Headers | Result |
|---|---|
| `X-APP-VERSION` + `X-Requested-With` (ours) | 403 |
| + `accept` | 403 |
| + `x-pinterest-appstate` only | 403 |
| + `x-pinterest-source-url` only | 403 |
| **+ `x-pinterest-pws-handler` only** | **200** |

**`x-pinterest-pws-handler` is the sole 403 gatekeeper.** Its value
`www/[username]/[slug].js` is a LITERAL board-page route constant (the brackets are not
interpolated). `X-APP-VERSION` is app-identifying but not the 403 trigger; `accept` /
`appstate` / `source-url` are irrelevant to it. This is exactly the escalation the
Phase-0 comment anticipated ("if forged headers 403, capture from a real request").

## The fix (`extension/src/bulk-pinterest.js`)

- **`PWS_HANDLERS`** — a resource→handler map (`BoardFeedResource` →
  `www/[username]/[slug].js`); only the verified BoardFeed entry, others added as real
  requests are captured. **`resourceNameFromURL`** parses the `/resource/{Name}/get/`
  segment.
- **`makeResourceFetch`** now builds headers **per request** (was once-per-driver):
  derives `x-pinterest-pws-handler` from the resource name and `x-pinterest-source-url`
  from the request's own `source_url` param — generic, no per-call plumbing through the
  paginators. An unmapped resource sends no handler (and will 403 — acceptable while
  that path is deferred).
- **`boardFeedHeaders`** gained `pwsHandler` + `sourceUrl` params and emits the
  `x-pinterest-*` headers. It also sends `x-pinterest-appstate: active` to mirror the
  real client — NOT strictly required per the bisection, kept as cheap fidelity against
  Pinterest tightening its checks. Only `pws-handler` is load-bearing.

## Verified

- **Live:** reload → re-sweep the real board → `status: "complete"`, `error: null`,
  `ingested: 1` (the board's single pin). No 403.
- **Unit:** `npm test` **168** (+4: pws-handler present in `boardFeedHeaders` /
  `makeResourceFetch` for a BoardFeed URL, absent for the unmapped BoardsResource,
  `resourceNameFromURL` extraction).
- `drift-baseline.json` gains the `pwsHandler` marker (the new volatile live constant).

## Files changed

- `extension/src/bulk-pinterest.js` (PWS_HANDLERS, resourceNameFromURL, per-request
  header derivation), `extension/test/bulk-pinterest.test.js` (+4 tests),
  `extension/test/fixtures/drift-baseline.json` (pws-handler marker),
  `.docs/019-bulk-import-verification.md` (T10 result).

## Not yet covered

T1 ran against a **single-pin** board, so multi-page enumeration, cross-page dedup, and
resume-from-checkpoint (T3/T4) are still unexercised live — re-run T1 on a larger board
to cover pagination.
