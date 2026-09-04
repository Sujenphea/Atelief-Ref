# 482 — the App-target gate was starving its own thread pool

## Summary

`verify.sh full`'s **App target** stage had been failing intermittently for the
whole of 099's execution — often enough to be useless as a gate, rarely enough
that a re-run usually went green. It named a different test almost every run, and
every named test passed in isolation.

The cause was `DetailImageLoaderTests`' `DecodeProbe`, which blocked chosen
decodes on a `DispatchSemaphore(value: 0)` with an **unbounded** `wait()`. Two
things follow from that, and neither shows up as a failing assertion:

1. **A counting semaphore is not a gate.** One `signal()` admits one waiter, so
   each test hard-coded a decode *count* — `retainOnlyCancelsOutsideWindow`
   released twice for its two blocked hashes. That count is a bet on loader
   internals rather than something the test asserts, and any regression producing
   one extra decode (a preload re-run, a coalesce that stopped coalescing) strands
   the surplus decode on a signal that never comes. The regression each test exists
   to catch is precisely what stops it reporting.
2. **`DispatchSemaphore.wait()` ignores task cancellation.** It parks the OS
   thread. These decodes run on the Swift concurrency cooperative pool —
   `activeProcessorCount`, eight here — so every stranded waiter permanently
   retires an eighth of the runner's concurrency. The suite's `.timeLimit` trait
   does not help: it fails the test, the thread stays parked.

The consequence is the part worth keeping: **the suite that leaks the thread is
not the suite that fails.** Once enough threads were gone, unrelated tests could
not be scheduled and tripped their own time limits — which is why the gate blamed
`CoalescerCancellationTests.cancelTrailingOnAnIdleKey()`, a three-line
*synchronous* test, at a flat `60.000 seconds`. A synchronous test cannot hang. If
one ever times out again, suspect a starved pool, not the test in the report.

`ThumbnailPipelineTests` had already met this exact failure and fixed it in
`.change-log/330` (a latch, bounded) — but the fix stayed local to that file, and
`DetailImageLoaderTests` kept a private copy of the semaphore it had replaced. So
the mechanics now live in one place and the probes share them.

## The gate had TWO causes, and this fixes one and a half

Worth stating plainly, because six earlier changelogs circled it: the App-target
stage was failing from **two independent mechanisms with different signatures**,
and reading them as one story is what kept the diagnosis wrong.

| | signature | cause | status |
|---|---|---|---|
| **A** | a flat `60.000 s` against the suite time limit, on an arbitrary and often *synchronous* test | pool starvation, above | **fixed here** |
| **B** | a timeout at 10–21 s, or a poll that returns false | poll-based tests that stall when the machine does | pre-existing; see below |

Three post-fix runs of the stage: two green, and the one red failed as **B**, at
10.256 s on `PollTests/settlesEarly()`, with no test in the run exceeding 14.7 s
and the whole suite finishing in 25 s elapsed. Signature **A** did not appear.
That is evidence, not proof — A was intermittent — but the mechanism argument is
independent of run count: there are no unbounded thread parks left in this target.

**B is documented in `.change-log/470, 471, 473, 475, 476, 478` and is not fixed
here.** 478's run 5 caught the machine behind it — the data volume at 100 % with
798 MB free — and its closing note is the standing instruction: the named polls
(`CollectionActivationTests/sidebarDraftCommitSelectsNewCollection()`,
`CollectionReadModelTests/ingestBurstCollapses()`, and eleven waits in
`LibrarySearchModelTests`) should be **converted to the event signals their
subjects already publish**, the way 11A converted four of them. Disk was fine for
the run above (42 GB free), so load alone is enough to trip them.

`PollTests/settlesEarly()` is the exception in that list: it is a test *of* `poll`,
so it has no signal to convert to, and it is fixed here instead — see below.

## Files changed

- **`AtelierRefs/AtelierRefsTests/TestSupport/DecodeLatch.swift`** (new) — a
  one-way, bounded gate over `NSCondition`. `open()` admits every waiter, now and
  in future, so there is no count to get wrong; `wait()` gives up after
  `defaultTimeout` (10s, well inside the suites' one-minute `.timeLimit`) and sets
  `timedOutWaiting` so the test reaches its assertions and fails in seconds. The
  header carries the full account above — this is the only blocking primitive
  these suites may use.
- **`AtelierRefs/AtelierRefsTests/DetailImageLoaderTests.swift`** — `DecodeProbe`
  blocks on a `DecodeLatch` instead of a semaphore; it keeps its
  `Task.isCancelled` re-check, which is what makes the `retainOnly` cancel/keep
  assertions deterministic. `retainOnlyCancelsOutsideWindow`'s paired
  `probe.release()` calls collapse to one. All four blocking tests now assert
  `!probe.timedOutWaitingForRelease`.
- **`AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift`** — its probe drops
  the hand-rolled `NSCondition` latch for the shared one, keeping its own
  `everRanOnMainThread` tracking on a plain `NSLock`. Behaviour is unchanged; the
  duplicate mechanics are gone.

- **`AtelierRefs/AtelierRefsTests/EventSignalTests.swift`** — `settlesEarly`'s
  timeout goes `.seconds(2)` → `.seconds(20)`. The assertion never was the clock:
  the condition goes true on the fourth evaluation, so `flips <= 10` is what
  proves it settled early, and that is scale-free. The two-second bound made it a
  wall-clock test by accident — three 1 ms sleeps had to resume inside two
  seconds, so a single stalled `Task.sleep` failed it, which is exactly what
  happened. It still returns in ~3 ms; it now takes a wedged machine, not a busy
  one, to fail.

## Notes

- No production code changed. This is entirely a test-harness defect.
- **Still open, same bug class, not fixed here:**
  `AtelierServer/Tests/.../TestSupport/ServerTestEnv.swift:105` blocks on
  `DispatchSemaphore` + `Thread.sleep` waiting for `AVAssetWriter.finishWriting` —
  byte-for-byte the shape that `AtelierIngestion`'s `FixtureVideos.swift` documents
  as having deadlocked its bundle for over an hour. Five call sites against an
  eight-thread pool, so it has not tipped yet; it is one added blocking test away.
  `FixtureVideos` fixed its copy by going `async`, which is the same move here.
- This is the fourth appearance of "a test helper blocks a cooperative-pool
  thread" in this repo (`FixtureVideos`, `VisionImageClassifierTests`, 330, and
  now this). The pool is eight threads wide and does not grow; a test helper may
  not park one.

## Migration notes

None. Test-only.
