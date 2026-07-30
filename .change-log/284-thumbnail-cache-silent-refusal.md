# 284 — Thumbnail pipeline: a cancellable visible load, and a silently refused cache

## Summary

Two defects in `ThumbnailPipeline`, both found while investigating a one-off
failure of 12 tests in `ThumbnailPipelineTests` / `ThumbnailWindowPrefetcherTests`.

**1. A visible load could be cancelled underneath an on-screen cell.**
`join(_:visible:)` returns an already-running task when one exists for the key,
but it did not remove that key from `inFlightPrefetches` — the set
`cancelPrefetch(hashes:)` cancels. So when a hash crossed from the prefetch ring
into the visible window, `image(hash:url:bucket:)` joined the running *prefetch*
task and the next `cancelPrefetch` for that hash could cancel the work the cell
was awaiting. `image` then awaited a task that had skipped its decode and read
back a miss: a cell on screen with nothing drawn in it.

The asymmetry is what gave it away — the branch below it already handles the
same promotion for a request still sitting in the *queue* (`queuedKeys.remove`),
but the already-**started** case had no equivalent. The hazard was known and
documented on `ThumbnailWindowPrefetcher.update(requests:keep:)`, but defended
only caller-side via the `keep` set; the pipeline itself had no guard.

`activePrefetches` is deliberately left alone: the task genuinely still occupies
a decode slot, and `finish` decrements it from the `isPrefetch` captured at task
creation. Its `inFlightPrefetches.remove` becomes a no-op, which is correct.

**2. An over-charged cache entry made the cache hold nothing at all, silently.**
`store` charged `decoded.byteCost` with no upper bound. `NSCache` refuses an
object whose cost exceeds `totalCostLimit` outright rather than evicting to make
room, and it does so with no error — so one oversized charge does not cost you
one entry, it costs you the cache: every insert refused, every read a miss,
every cell re-decoding, indefinitely. Measured against a 64 MB limit:

| charged per object | resident after 8 inserts |
| --- | --- |
| 1 MB | 8 / 8 |
| exactly 64 MB | 1 / 8 |
| 64 MB + 1 byte | **0 / 8** |

`store` now charges `min(cost, totalCostLimit)`, which keeps the bitmap a cell is
waiting on resident. Production cannot currently reach this — the bucket ladder
caps at 512 px ≈ 1 MB against a ≥128 MB budget — so this is a guard against a
*wrong* cost, not a large one, and against the failure being invisible when it
happens.

**3. The clamp made the condition invisible, so it now announces itself.**
Fix 2 trades diagnosability for robustness: before it, a wrong `byteCost` blew
up 12 tests; after it, the same bug would quietly degrade the cache to one entry
and surface only as scroll jank, weeks later, with nothing to point at. That
trade is only acceptable if the condition is reported, so `store` now checks the
cost against the **bucket** rather than the budget — which identifies the actual
pathology independently of how the cache happens to be configured:

- `thumbnailCostIsPlausible(cost:bucket:)` — pure, bound at `bucket² × 16`. A
  real bitmap costs `bucket² × 4` at 8 bits per component and `× 8` at 16, so the
  bound cannot fire on any plausible pixel format; it only trips on a nonsense
  number. Total on degenerate input (zero/negative buckets, overflow) — a guard
  meant to report a bug must never become one.
- On a trip: `AppLog.thumbnails.error` with the cost and bucket, plus
  `assertionFailure` in debug. The next occurrence names its own cause in one
  line instead of costing another day of bisecting.
- Exceeding the *budget* is only `notice`, not an error: a deliberately tiny
  budget is a legitimate configuration (the tests use one) and is not evidence of
  a bug.

The consuming branch is unreachable from a test — `DecodedThumbnail` computes
`byteCost` in its own initialiser, so a wrong one cannot be injected. Hence the
rule is a separate pure function with its own tests, matching how this file
already treats `thumbnailPixelBucket` and `thumbnailCacheCostLimit`.

## Files changed

- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — promote a joined task out
  of `inFlightPrefetches`; clamp the charged cost; report an implausible one;
  new `thumbnailCostIsPlausible(cost:bucket:)` and `cancellablePrefetchKeys`.
- `AtelierRefs/AtelierRefs/Diagnostics.swift` — `AppLog.thumbnails` category.
- `AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift` — five tests.
  `visibleJoinPromotesOutOfPrefetch` and `oversizedEntryIsClampedNotDropped` were
  each confirmed to fail with their respective fix backed out, and *only* those
  two failed, so they are real guards rather than tests written to pass. Three
  more cover the plausibility bound: real costs at every bucket at 8 and 16 bpc,
  corrupt costs, and degenerate input.

An earlier draft of `oversizedEntryIsClampedNotDropped` also asserted *which*
entry survives once several oversized ones compete. That failed, correctly — it
was asserting a retention guarantee `NSCache` does not make, the same mistake
this entry is about. It now asserts only that the cache is not left empty.

## On the original 12-test failure — NOT resolved

These fixes are worth having on their own merits; neither is confirmed to be
what failed. Recorded so it is not re-derived:

- The split was perfectly clean: all 12 tests asserting a cache entry **exists**
  failed; the 4 that assert absence, decode counts, or no cache at all passed.
  Across 12 independent pipeline instances over ~2.8 s the cache retained
  *nothing* — not "evicted some".
- Ruled out with evidence, not inference: **memory pressure** (no pressure
  notification in the system log during the failure window; posting Foundation's
  simulated one purges nothing; process peaked at 325 MB with 36% free);
  **CPU contention** (the failing run's thumbnail tests were the *fastest*
  observed — 0.43–0.58 s, versus 0.87 s and 1.42 s in clean runs, so the
  correlation runs backwards); **cache-clearing code** (no such code in the
  project); **pipeline logic** (decode counts prove coalescing, gating,
  promotion and cancellation all ran correctly).
- Not reproduced in 27 consecutive full-suite runs — 15 plain, 12 under
  concurrent compilation — on source unchanged since 21 Jul.
- Best-fitting hypothesis, unproven: `decoded.byteCost` exceeded
  `totalCostLimit` during that run, which is the only mechanism found that
  reproduces the signature *including* the 64×-headroom control arm. Note the
  test computes its own `cost` from `makeImage` independently of the pipeline's
  `byteCost`, which is why `#expect(cost > 1_000_000)` could pass while every
  insert was being refused. A stale incremental build of `AtelierIngestion`
  (where `DecodedThumbnail` is a non-resilient package struct) against the app
  target would produce this and self-heal on the next full build — consistent
  with it never recurring. Fix 2 above means that, if it happens again, the
  cache degrades gracefully instead of vanishing.

## Also noted, not changed

Nine tests park a Swift cooperative-pool thread on a `DispatchSemaphore` inside
`Task.detached` (8 here, 1 in `DetailImageLoaderTests`) on an 8-core machine.
This is a genuine design smell and it is why the thumbnail suites run 20–70×
slower in the full suite than in isolation. It is *anti*-correlated with the
failure above, so it was not the cause and was left alone.

## Migration notes

None. Both changes are internal to `ThumbnailPipeline`; no call site or API
changes.
