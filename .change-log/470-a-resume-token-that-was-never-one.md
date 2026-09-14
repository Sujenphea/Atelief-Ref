# 470 — a resume token that was never one

## Summary

[098](../.docs/098-rednote-sweep-plan.md) T1b — three seam changes the T1a suite
([469](469-the-seam-nobody-tested-directly.md)) was written to guard. All three are
behaviour-preserving for X.

**R1 — the checkpoint stops lying.** `createInterceptSource` now declares
`resumable: "scroll"`, and the engine honours it: no cursor is seeded from a prior
checkpoint, and none is persisted. An intercept source cannot seek — it reads
whatever the page fetches, and the page is driven by scrolling — so every
checkpoint it wrote carried a resume token that nothing would ever read back. It
looked like a working resume and was not one. The checkpoint still carries `counts`
and (via the caller) `jobId`, which are the parts that get used; dedup-skip remains
the real safety net.

**R7 — a degraded page is no longer invisible.** `expandItems` stays fail-open,
which is right for X: a failed `TweetDetail` costs the replies and the bookmarked
tweet still saves. The new `onExpandFailure` hook makes the loss observable, because
the same rule applied to rednote means saving 1 cover instead of 9 images while the
sweep reports a clean success. Reporting only — the fail-open rule is unchanged —
and a throw from the reporter is swallowed, since a hook that describes a sweep must
never be able to kill it.

**R15 — the replay buffer is bounded by size, not only by count.** A count is the
wrong unit when page sizes differ by an order of magnitude: a rednote board page is
~52 KB (25 of them ≈ 1.3 MB), an X timeline page ~871 KB (25 ≈ 21 MB of JSON text,
plus a parsed graph several times larger), pinned in the MAIN world for the life of
the tab whether or not a sweep ever runs.

## What was narrowed, and why

R15 was reviewed as "clear the buffer after a replay **and** bound it by bytes".
The clear was **dropped**. A second sweep on the same tab would replay nothing and
could stall, where today it replays and the overlap is dedup-skipped — trading a
memory saving for a broken sweep. The size bound addresses the actual harm and
changes no replay semantics.

Two honesty notes on the bound: it measures JS string LENGTH (UTF-16 code units),
not real bytes — CJK-heavy rednote content is roughly 3x this in UTF-8 — so it is a
deliberately cheap proxy. And the most recent entry is never evicted: the cap exists
to stop accumulation, not to refuse a single large page a sweep still needs.

## Files changed

- `extension/src/intercept-source.js` — `resumable: "scroll"`, `onExpandFailure`.
- `extension/src/bulk-engine.js` — honour `resumable: "scroll"` when seeding and
  persisting the cursor.
- `extension/src/hook-core.js` — `byteLimit`; entries carry their own size; the
  fetch path parses from `text()` so the size costs nothing extra.
- `extension/test/hook-core.test.js`, `extension/test/intercept-source.test.js`,
  `extension/test/twitter-thread-integration.test.js` — six new tests, and three
  response fakes taught to expose `text()`.

## A note on the fakes

Switching the fetch path to `text()` broke five tests in
`twitter-thread-integration.test.js` and seven in `hook-core.test.js` — every one
because a hand-rolled `clone()` returned only `json()`. A real `Response.clone()`
always exposes both. The fakes were under-specified, so they were corrected rather
than the code: a double that diverges from the browser hides working code paths and
invents broken ones.

## Verification

`npm test` 661 → 667 total, 664 pass, 0 fail. `npm run drift-check` clean.

## Migration notes

An existing checkpoint written by an intercept-source sweep may still hold a stale
`cursor`. It is now ignored on read and overwritten with `null` on the next
checkpoint, so no cleanup is needed.
