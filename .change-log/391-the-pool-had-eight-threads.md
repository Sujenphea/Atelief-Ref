# 391 — The pool had eight threads

`swift test` on AtelierIngestion deadlocked. Not slowly — permanently: observed
hanging for over an hour with 365 tests open, taking the whole `verify.sh` gate
with it, twice in one afternoon.

## What it looked like, and why that was misleading

A `sample` of the hung process showed two `-[VNRecognizeTextRequest
internalPerformRevision:inContext:error:]` stuck, an `ANEServicesThread` parked on
`mach_msg`, and 67 Vision frames. It read as a Vision bug — plausibly a concurrent
`VNRequest` deadlock on the Neural Engine.

It was not. Every step of that reading was wrong, and the experiments that killed
it were:

- the OCR suite alone, in parallel, 3× → passes in 5s
- OCR + the NLEmbedding suite together → passes in 5s
- the full suite with the OCR suite **skipped** → **still hangs**

That last one settles it: Vision was a bystander, blocked behind the same
exhausted resource as everything else. A second sample with OCR skipped showed no
Vision frames at all — just `__psynch_cvwait` and `semaphore_wait_trap`, with five
tests stopped inside `FixtureVideos.solidVideo` at `semaphore.wait()`.

## The actual cause

`FixtureVideos.solidVideo` blocked its caller's thread twice: `Thread.sleep` in
the frame loop, and a `DispatchSemaphore` awaiting `finishWriting`. The file
header stated the reasoning outright:

> Synchronous by design: `finishWriting` is awaited with a semaphore, which is
> fine (and simplest) in a test helper

True under XCTest, which gives each test its own thread. **False under
swift-testing**, which runs async tests on the Swift concurrency COOPERATIVE POOL
— one thread per core, and it cannot grow.

Nine call sites across five suites build this video. On an 8-core machine, once
eight are in flight, every cooperative thread is parked in `semaphore.wait()` and
no thread remains to run the `finishWriting` completion handler that would signal
them. Nothing can make progress, ever. It is load-dependent, which is why it
presented as intermittent.

This likely also explains `VisionImageClassifierTests` carrying `.serialized` —
papering over the same deadlock from the victim's side.

## The fix

Nothing in the helper may block a thread. `solidVideo` is `async`:
`await writer.finishWriting()`, and the readiness spin yields with `Task.sleep`
instead of sleeping the thread. The writer is created, used and finished inside
one function and never crosses an isolation boundary, so its non-`Sendable`ness
costs nothing — the concern the old header raised does not arise.

Nine call sites gain `await`; `VideoIngestTests.sniff()` and
`VideoOpenProbeTests.probeVideoURL()` become `async`.

## Result

| | before | after |
|---|---|---|
| `swift test` (parallel) | deadlocks forever | **427 tests, 45 suites, ~1.7s** |
| stability | 4 hangs observed | 5 consecutive clean runs |

## A correction, and one genuine loose end

While the suite was hanging, `--no-parallel` was used to get it to complete, and
it reported 2 failures. Those were initially read as real bugs the deadlock had
been hiding. They are not: in the default parallel mode all 427 pass. They are
artifacts of serializing a suite that was never written to be serialized.

`BoundedWorkTests` "a non-positive limit clamps to serial rather than deadlocking"
asserts a concurrency PEAK, so forcing serial execution is expected to change what
it measures — it passes both ways now.

One does still fail under `--no-parallel` only:

- `EmbeddingBackfillTests` — "OCR re-run with the SAME text is a touch, not a
  re-embed (4A guard)", 3 expectations at `EmbeddingBackfillTests.swift:77/83/84`.

Order-or-state dependent rather than deadlock-related. Left alone here: this
change is about the pool, and `--no-parallel` is not how the suite runs. Worth its
own look if the suite is ever run serially on purpose.

## Files changed

- `AtelierIngestion/Tests/AtelierIngestionTests/TestSupport/FixtureVideos.swift`
- `VideoIngestTests.swift`, `VideoOpenProbeTests.swift`, `AnalysisSourceTests.swift`,
  `AnalysisBackfillTests.swift`, `SuggestionBackfillTests.swift` — `await` at the
  call sites

## Migration notes

Test-only. Any new caller of `solidVideo` must `await` it, which is the point: the
blocking version is gone, so the landmine cannot be re-armed by the next test that
needs a video.
