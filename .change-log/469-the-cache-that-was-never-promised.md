# 469 — the cache that was never promised

`ThumbnailPipelineTests` and `ThumbnailWindowPrefetcherTests` failed together roughly one
gate run in four — about **42 issues across 15 tests**, both suites entire, the other
~1,690 cases in the target green. [465](465-the-corpus-goes-resident.md) hit it on its
second gate run and [468](468-the-mac-gets-a-window-a-keystroke-and-an-order.md) on its
first. Both wrote it up as somebody else's and moved on, because there was nothing to
diagnose: `xcodebuild` records one `Test case '…' failed on 'My Mac' (15.110 seconds)`
line per test and **no assertion text, no recorded issue, no timeout**. Two hypotheses
had been raised and neither survived contact — system starvation (the durations turned
out to be a wall-clock offset, so they prove nothing either way) and the suites'
`.timeLimit(.minutes(1))` (the failing test is recorded well inside it).

The user took it out of the backlog as **099 · P2b** (issue 20A), ahead of P3, on the
grounds that a gate failing once in four runs for no stated reason is a gate nobody
reads — the road [464](464-the-gate-tells-its-two-arms-apart.md) was written to get off.

## Getting the failure to say something

`xcodebuild`'s console output is not where Swift Testing puts its issues. The run
carries them, and `-resultBundlePath` plus

```
xcrun xcresulttool get test-results summary --path <bundle>.xcresult
```

prints a `testFailures` array with the `failureText` of every one. That is the whole of
the tooling problem, and it is worth knowing before the next flake: **the log is a
summary, the bundle is the record.**

Reproducing it took load. Eight runs of `-only-testing:AtelierRefsTests` on an idle
machine produced nothing at all. Under a concurrent build/test load — four package suites
cycling `swift test --parallel` beside the run — it came back, and the seventeenth run of
the exercise printed this:

```
ThumbnailPipelineTests/exactHitWins()
  Expectation failed: (entry?.bucket → nil) == 256
ThumbnailPipelineTests/fallsBackToLargerBucket()
  Expectation failed: (entry?.bucket → nil) == 384
ThumbnailPipelineTests/costBasedEviction()
  Expectation failed: (residentUnderRoomyBudget → 0) == 8
ThumbnailPipelineTests/cachedRequestDoesNotDecodeAgain()
  Expectation failed: (probe.callCount("a") → 3) == 1
ThumbnailPipelineTests/oversizedEntryIsClampedNotDropped()
  Expectation failed: (pipeline.cachedExact(hash: "a", bucket: side) → nil) != nil
ThumbnailWindowPrefetcherTests/keepSetIsNotCancelled()
  Expectation failed: (pipeline.cachedExact(hash: "a", bucket: 256) → nil) != nil
ThumbnailWindowPrefetcherTests/stableHashSurvives()
  Expectation failed: (probe.callCount("b") → 2) == 1
```

Fifteen entries, and every one of them is the same sentence. **The cache is empty.**

`residentUnderRoomyBudget → 0` is the one that settles it. That is the control arm of
`costBasedEviction`: eight one-megabyte bitmaps inserted under a budget **sixty-four
times** their combined size, and not one of them read back. `callCount → 3` is the same
fact from the other side — the pipeline re-decoded a key three times because every lookup
missed.

## What it was, and what it was not

The entries were written. The decode probe counts its calls, and it counted them; a
non-nil decode is followed unconditionally by `store(_:for:)`; and `store` logs a
`notice` whenever it clamps a cost that exceeds the whole budget. **That notice is absent
from the failing run's log**, so the cost charged was inside the budget and the insert was
not refused on arrival. The bitmaps went in, and later they were not there.

So the pipeline was right about everything. `join` does re-check the cache under the lock
— the invariant the loudest test in the suite exists to pin, and the one worth checking
first. The gate, the promotion, the cancellation, the fallback ladder: all correct, all
still correct, none of them changed by this phase.

What was wrong is one line that had been true by luck since 036:

```swift
private let cache = NSCache<NSString, Box>()
```

`NSCache` is the right cache for a shipping app — it hands memory back to the system on
a schedule of its own, which is exactly what several hundred megabytes of thumbnails
should do — and its documentation is explicit that the schedule is not yours: it
"incorporates various auto-eviction policies", and a caller "should not rely on a cache
to store" anything. **Residency is not a guarantee `NSCache` makes.** Fifteen tests were
asserting it.

That is why they always fell over *together* and why the two with no concurrency in them
at all — `exactHitWins`, `fallsBackToLargerBucket` — were in the set. It was never a race
inside any one test. It was fifteen tests sharing one wrong premise, and a quiet machine
hiding it.

**The trigger is NOT established, and this entry does not claim it.** What is established
is that the entries are discarded between the write and the read, under load, without a
budget violation. Which signal does the discarding was chased and not caught: a separate
process holding an identical `NSCache` was untouched through the same load; ballooning one
process's own footprint to 9 GB on this 16 GB machine produced neither a memory-pressure
event nor an eviction; and `memory_pressure -S` needs root this session did not have. The
fix does not depend on knowing, because the tests should not have been betting on the
answer either way.

## The seam

`ThumbnailStore` is now a protocol, and it states the contract in the one place both
implementations can be read against it:

1. `costLimit` is a byte budget; `0` is unbounded.
2. An entry costing more than the **whole** budget is refused outright, not
   admitted-then-evicted. This is `NSCache`'s real behaviour and it is the entire reason
   `store(_:for:)` clamps (measured in `.change-log/284`: at a 64 MB limit, 8 inserts at
   1 MB leave 8 resident; the same 8 at limit+1 leave **zero**).
3. Anything else may be evicted whenever the store likes.

`NSCacheThumbnailStore` is production and is the `NSCache` that was already there, moved
behind the protocol with its cost limit and its deliberate absence of a count limit
intact. `ThumbnailPipeline`'s existing initialiser is now a `convenience` one that builds
it, so `ThumbnailPipeline.shared` and every app call site read exactly as before.

`PinnedThumbnailStore` lives in the test target and adds the one thing `NSCache` will not
promise: it keeps what it is given, evicting only inside `insert` and only when the budget
says so, oldest-first. The two suites build their pipelines through one `pinnedPipeline`
helper that uses it, defaulting to an **unbounded** budget — the scheduling tests are
about coalescing, promotion and cancellation, and a byte budget none of them asked for is
one more reason a lookup could miss. The two tests that are about the budget pass their
own, and both still discriminate: `oversizedEntryIsClampedNotDropped` still fails without
the clamp, because rule 2 is a rule the pinned store honours rather than a quirk it
happens not to have.

**No production behaviour changed.** The app still caches thumbnails in an `NSCache`, at
the same budget, with no count limit, and still gives that memory back under pressure —
which it should. What changed is that the tests stopped depending on it not doing so.

**Not one assertion was weakened or deleted**, and the suite grew: 34 `@Test` in the file
before, **41** after. The seven new ones are the contract itself — the pinned store keeps
an unbounded set, evicts oldest-first only when the budget bites, refuses an over-budget
entry, and replaces a re-inserted key without double-charging — plus two on the
production store that say the things about it that are *decisions* (the budget is the
number it was given; `countLimit` is 0, so 036 §1.4's `countLimit = 512` thrash cannot
come back) and one that the production initialiser still reaches a real cache and a real
decode. That last one deliberately asserts `probe.callCount("a") == 1` and **not**
`cachedExact != nil`: asserting residency against an `NSCache` is the thing this phase is
about not doing.

### The option not taken

The alternative was to give the pipeline a cache it owns in production too — a
cost-bounded dictionary — which would have made the tests deterministic with no seam and
no fake. It was rejected because it is a real behaviour change dressed as a test fix: the
app would then hold up to 512 MB of decoded thumbnails through a system memory warning
and never hand any of it back. Changing what ships to make a test pass is the wrong half
of the trade.

The cost of the option taken is honest and worth naming: `costBasedEviction` and
`oversizedEntryIsClampedNotDropped` now exercise the pinned store's implementation of
rules 1 and 2 rather than `NSCache`'s. The rules are written down in the protocol,
`PinnedThumbnailStoreTests` checks that the pinned store obeys them, and `.change-log/284`
holds the measurement that says `NSCache` does — but nothing in the suite would now catch
`NSCache` changing its mind about rule 2, and nothing could, because the test that would
is the flaky one.

## Verification

Before the fix: **1 failure of this signature in 35 runs** of `-only-testing:AtelierRefsTests`
— 0 in 8 on an idle machine, 1 in 27 under concurrent load. That is well short of the
one-in-four the gate saw, and the difference is probably the gate itself: both recorded
sightings were `verify.sh full` runs, which compile eleven packages and the app before the
unit stage, and this loop used `test-without-building` and compiled nothing.

After the fix: **22 consecutive runs under that same load, 0 failures in either thumbnail
suite.** Three of the 22 failed on something else entirely — `LibrarySearchModelTests`
twice and `CollectionActivationTests` once, all of them `poll` / `waitUntil` timeouts, all
of them artifacts of a load set heavier than any real gate (see below). No run failed on a
cache lookup.

A repetition tally against a one-in-thirty-five base rate is weak evidence on its own, and
it is not the argument. The argument is structural: after this change **no assertion in
either suite reads from an `NSCache`**, and "a key that was inserted reads back" is now a
tested property of the store they do read from rather than a hope. The fifteen failure
texts above are, every one, an instance of that hope failing.

`./scripts/verify.sh full`:

```
── summary ──
  ✓ AtelierCore
  ✓ AtelierCapture
  ✓ AtelierLibraryPaths
  ✓ AtelierBrowse
  ✓ AtelierArchive
  ✓ AtelierTokens
  ✓ AtelierIngestion
  ✓ AtelierServer
  ✓ CanvasRenderer
  ✓ AtelierExport
  ✓ App target
  ✓ App target (UI)
  ✓ App target (Release)
  ⚠ Extension

All 14 stages passed, 1 with a warning above.
```

Exit 0, first run. `⚠ Extension` is the stale Instagram drift fixture, non-fatal since
[464](464-the-gate-tells-its-two-arms-apart.md) and not this phase's.

## What is still NOT covered

**The trigger.** This entry establishes that the entries are discarded and that the tests
had no right to expect otherwise. It does **not** establish which signal discards them.
That question is now unforced rather than answered, and if it matters later the way in is
an `NSCacheDelegate` on the production store logging evictions, run in a loop until it
recurs — which was not done here because the fix does not depend on it.

**`DetailImageCache` has the identical latent flake and was left alone.**
`DetailImageCacheTests` asserts `resident(8, in: roomy) == 8` against an `NSCache` — the
same sentence as `costBasedEviction`, on the same kind of object — and
`DetailImageLoaderTests` reads `loader.cached(…) != nil` after an `await`. Neither has
been seen to fail; both can. They survive today because their insert-then-read windows are
microseconds of straight-line code where the thumbnail suites' are seconds across task
hops, which narrows the window rather than closing it. The seam that would fix them is the
one this phase just built. It is a named follow-up, not a fix, because P2b was scoped to
the suites that were actually failing the gate.

**Three other flakes surfaced under load and none were touched.** With four package suites
cycling beside the run, `PollTests/settlesEarly()` failed twice (`Expectation failed: met`
— its 2-second bound with a 1 ms interval does not survive a saturated machine),
`LibrarySearchModelTests` failed 11-then-3 tests on `poll`'s 3-second timeout, and
`CollectionActivationTests` failed 5 on `waitUntil`. One run took **1,137 seconds**. These
are timeout-shaped, not cache-shaped, and they are artifacts of a load deliberately set
heavier than a real gate — but 099 · 11A's bounded waits carry fixed timeouts, and a fixed
timeout is a fixed bet. Nothing here says what the right bound is or whether the gate will
ever push them.

**The reproduction was never made cheap.** One in thirty-five, only under load, only in
the whole-target run — the suites pass in isolation, as they always did. Nothing in this
change makes the *next* cache flake easier to catch; what it leaves behind is the
`xcresulttool` recipe above, which makes the next one easier to read.

## Files

- `AtelierRefs/AtelierRefs/ThumbnailPipeline.swift` — `ThumbnailStore` protocol and its
  contract; `NSCacheThumbnailStore`; `ThumbnailPipeline` takes a store, with the previous
  initialiser kept as a `convenience` one. No behaviour change.
- `AtelierRefs/AtelierRefsTests/TestSupport/PinnedThumbnailStore.swift` — new. The
  deterministic store, and the failure text that made it necessary.
- `AtelierRefs/AtelierRefsTests/ThumbnailPipelineTests.swift` — the two suites build
  through `pinnedPipeline`; two new suites (`PinnedThumbnailStoreTests`,
  `NSCacheThumbnailStoreTests`), 7 new tests, 34 → 41.
- `.docs/099-mac-backlog-plan.md` — P2b section and status row.

No `project.pbxproj` change: the test target is a `PBXFileSystemSynchronizedRootGroup`,
so the new `TestSupport/` file is picked up from the filesystem.
