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

This also explains `VisionImageClassifierTests` — **confirmed, not guessed.** That
suite's header documents the same wedge measured from the victim's side (bundle without
it: 418 tests, 2.1s; with it: frozen after ~1.3s; `.serialized`: still frozen) and
concluded that a synchronous `VNClassifyImageRequest.perform` was the culprit. It was
not. The bundle was already one blocked thread from the edge, and that `perform` blocks
a pool thread too, so adding it tipped an already-marginal bundle — which is precisely
why `.serialized` did nothing: the contention was never between those two tests. Note
the bundle was 418 tests then and 427 now; it crossed the threshold as tests were added,
which is what made the failure look like it appeared out of nowhere.

So the `ATELIER_VISION_CLASSIFY_TESTS` gate is REMOVED here. With the fixture fixed, the
suite runs in parallel with everything else — 427 tests, 45 suites, green, three
consecutive runs — and CI runs it like any other suite instead of skipping it. Nothing
in `scripts/` or `.github/` ever set that variable, so the live classification adapter
had no live verification anywhere; the suite passed by skipping.

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

One does still fail:

- `EmbeddingBackfillTests` — "OCR re-run with the SAME text is a touch, not a
  re-embed (4A guard)", 3 expectations at `EmbeddingBackfillTests.swift:77/83/84`.

**Corrected:** this said the failure was `--no-parallel`-only and therefore an artifact
of forcing serial execution. It is not. It fails in BOTH modes — 2 of 3 serial runs, 1 of
2 parallel — and the full-bundle runs above that passed did so by luck. Dismissing it as
a serialization artifact was wrong twice over, because it was not flakiness at all: it
was a real defect in `assetsNeedingEmbedding`, where a re-analysis landing in the same
millisecond as an embedding compared EQUAL and so never re-qualified the asset. Fixed by
a monotonic marker in schema v23 — see changelog 392. Worth its
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
