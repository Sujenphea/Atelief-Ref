# 131 — Instagram live validation + page-2 fixture (002 · B0 follow-up)

## Summary

Live-validated the IG saved-posts parser against a second real capture and committed it
as a richer fixture. Resolves most of the pagination caveat carried since B0: the
`?max_id=` **request param is now confirmed live**; only `next_max_id` populated in a
non-terminal response body remains unseen (this account returns its whole saved feed in
≤2 fetches).

## What happened

A real page-2 capture (fetched with `?max_id=<token>` — proving the pagination request
mechanism) ran CLEAN through the actual parser via the drift canary:

```
drift-check --instagram <live capture>
✔ Instagram saved feed — posts=11 items=25 videos=7 endOfFeed=true
```

11 posts fan out to 25 items (an 11-child carousel + 2- and 4-child carousels + 7 reels +
1 image), every reel exposes its `videoUrl`, no drift — the driver generalizes beyond the
first small fixture to real, varied data including a large carousel.

## Files changed

- `extension/test/fixtures/instagram-saved-page2.json` — new sanitized fixture (11 posts
  → 25 items). Structure preserved exactly; leak-checked against all 312 real tokens →
  clean. Raw capture gitignored at `resources/ig-saved-page2.json`.
- `extension/test/bulk-instagram.test.js` — new test asserting the 11-post → 25-item
  fan-out with distinct pks, that the largest (11-child) carousel fully fans out (not
  truncated to its cover), and that every reel carries a videoUrl.
- `extension/test/fixtures/README.md` — page-2 fixture row; the pagination gap note
  updated (request param confirmed; response cursor still inferred).
- `extension/test/fixtures/drift-baseline.json` — IG marker note updated with the live
  validation + confirmed request param.
- `.docs/feature-todo/002-capture-instagram-bulk.md` — B0 caveat updated to reflect
  what's now confirmed vs still open.

## Test results

`node --test`: **351 pass / 0 fail** (+1). Drift canary green on both the committed
fixture and the live capture.

## Migration notes

None (test fixtures + docs only). The one remaining verification — `next_max_id` in a
non-terminal body — needs a larger saved feed than the recon account has; the paginating
tests synthesize that shape until then.
