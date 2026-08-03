# 330 — Coalescing that actually coalesces

## Summary

`ThumbnailPipeline` could decode the same key twice under concurrency, and
`ThumbnailPipelineTests` could hang the entire app-target suite forever when it did.
Both are fixed. The second one is why the first went unnoticed: the test that was
supposed to catch it could only ever *stall* on it, and a stalled `xcodebuild` at 0.0%
CPU with a frozen log looks nothing like a failing assertion.

## The race

`ThumbnailPipeline.image(hash:url:bucket:)` reads the cache, misses, and calls `join`,
which decides whether to start a decode. That decision looked at `inFlight` and nothing
else:

```swift
if let hit = cachedExact(hash: hash, bucket: bucket) { return hit }   // unlocked read
await join(request, visible: true).value                             // takes the lock
```

```swift
private func join(...) -> Task<Void, Never> {
    lock.lock()
    if let existing = inFlight[request.key] { ...; return existing }
    let task = startLocked(request, visible: visible)   // no cache re-check
```

The completing task does `store` **then** `finish`, and `finish` is where `inFlight` is
cleared. So there is a window — from `store` returning to `finish` releasing the lock —
in which the bitmap is already resident and no task is registered. A caller that read the
cache before `store` and was served the lock after `finish` sees a miss it took on the
way in and an empty `inFlight`, and starts a **second decode of a key that is already
cached**.

It needs no exotic scheduling. `NSLock` is not FIFO-fair, so with N callers piling onto
one key the finishing task's `finish` routinely wins the lock ahead of callers that have
been waiting on it. Modelled on the shipped logic: **~1 redundant decode per 3 attempts
at 32 concurrent callers, and it reproduces with as few as 2** (43 extra decodes in 300
two-caller trials). Heavy machine load widens it further but is not required.

`pump` already guards exactly this — it re-checks `cachedExact` under the lock before
`startLocked`. `join` was the one path that did not. The asymmetry was the bug.

### Why it deadlocked the runner rather than failing

`DecodeProbe` blocked chosen hashes on `DispatchSemaphore(value: 0)`, and `release()`
signalled it **once**. One decode of `"a"` was the premise; a second one waited on a
semaphore that would never be signalled again, forever, with no timeout. The task group
in `concurrentRequestsCoalesce` then waited on that child forever, and `xcodebuild` sat
at 0.0% CPU with a log that stopped moving.

That is also why it was intermittent and why it correlated with load: the window opens
only at the instant the blocked decode completes, ~80 ms in, by which time most callers
have already joined. Reproduced on demand by widening it (release at 0 ms instead of
80 ms): **16 of 150 trials deadlock against the shipped pipeline**.

Measured across the four combinations, 150 trials each, 32 callers:

| pipeline | probe gate | result |
| --- | --- | --- |
| as shipped | one-shot semaphore | **6–16 HANG** |
| as shipped | latch + timeout | 0 hang, **15 loud failures** |
| with the re-check | one-shot semaphore | 150 ok |
| with the re-check | latch + timeout | 150 ok |

Read the second row as the point of the test-side change: it does not fix anything, it
converts a silent stall into a failing assertion in 30 ms. The third row is the actual
fix.

## What changed

**`ThumbnailPipeline.join` re-checks the cache under the lock** and returns `nil` when
the bitmap is already there, so `image` has nothing to await and simply reads it. The
return type went `Task<Void, Never>` → `Task<Void, Never>?`; `join` is private and
`image` is its only caller.

**`DecodeProbe` blocks on a latch, not a counting semaphore**, and the wait is bounded at
10 s. `release()` now opens the gate for good, so a decode that starts after it does not
block at all, and a decode that gives up sets `timedOutWaitingForRelease` and proceeds so
the test reaches its assertions. Every blocking test asserts that flag is clear.

This also fixes a leak that had nothing to do with the race.
`outstandingIsTheLatestWindow` released one waiter and left a *second* blocked decode
(`"c"`, started by the gate once `"a"` finished) waiting on the consumed semaphore
permanently — on every run. `Task.detached` bodies run on the cooperative pool, which is
only `activeProcessorCount` threads wide (8 on this machine), so each such waiter retires
a pool thread for the life of the process. That test now also drains the pipeline before
returning instead of leaving work in flight.

**Both pipeline suites carry `.timeLimit(.minutes(1))`.** The probe bounds its own waits;
this is the outer bound that holds for anything added later. No test in this file can now
stall the runner indefinitely.

**New test: `concurrentRequestsCoalesceWithAFastDecode`.** The existing
`concurrentRequestsCoalesce` blocks the decode, which holds the task in flight and so
only ever exercises `join`'s in-flight branch — it cannot reach the window, it can only
hang on it. The new one uses a fast decode across 40 iterations so the task *completes*
while callers are still arriving. Against the unfixed pipeline it records 11 failures in
0.03 s.

## Files changed

- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — `join` re-checks the cache under
  the lock and returns an optional task; `image` unwraps it.
- `AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift` — `DecodeProbe` latch with
  a bounded wait and a `timedOutWaitingForRelease` flag; `.timeLimit` on both pipeline
  suites; bounded the one unbounded spin loop in `visibleJoinPromotesOutOfPrefetch`;
  `outstandingIsTheLatestWindow` drains before returning; new
  `concurrentRequestsCoalesceWithAFastDecode`.

## Notes

No migration. Schema stays at v18 and `Migrator.registeredIdentifiers` is untouched.

**Production impact is waste, not wrong pixels.** The duplicate decode produced the same
bitmap and stored it over itself; nothing was dropped, no cell blanked, no cache entry
corrupted. What it cost was a full extra `ImageIO` decode per racing cell, on the scroll
path, at `.userInitiated` — precisely the work `036 §4 C1` exists to avoid, and precisely
when the main thread is busiest. The pipeline's own doc comment already claimed the
property it was not delivering ("N concurrent requests for the same thumbnail decode
ONCE"); it now does.

**Behavioural note on `join` returning `nil`.** If the entry is evicted between that
re-check and `image`'s final read, `image` returns `nil` for a key it could have
decoded. That was already true of the pre-existing final `cachedExact` and is unchanged
in practice — production budgets are ≥128 MB against ~1 MB entries.

The `assertCostIsPlausible` / clamp behaviour, the fallback ladder, cancellation
semantics and the prefetch gate are all untouched.
