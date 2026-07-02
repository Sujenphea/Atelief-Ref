# 049 — DecodeScheduler async test awaits real completion

## Summary

`DecodeSchedulerTests."an async request populates the cache and fires
onDecoded"` (`HostTests.swift:149`) was **flaky** (failed roughly 2–3 of 5
full-suite runs). It waited on a fixed 2-second `Task.sleep` for a background
decode plus a main-actor hop, then asserted via a Swift Testing `confirmation`
that `onDecoded` fired. Under parallel suite load the decode sometimes missed
that fixed window, so the confirmation fired 0 times and the test failed
intermittently.

This is an **async-timing flake in the TEST, not a product bug** in
`DecodeScheduler`. The scheduler already exposes a precise completion signal:
the `@MainActor onDecoded` callback, which fires **exactly once** for a key
*after* the decoded image is inserted into the cache and the in-flight entry is
cleared (`DecodeScheduler.request` clears `inFlight[key]` before invoking
`onDecoded`). The fix awaits that real signal instead of guessing a wall-clock
duration, so the test proceeds the instant the decode completes.

## What changed

- **`HostTests.swift` — de-flaked the async decode test.**
  - Replaced the `try? await Task.sleep(for: .seconds(2))` inside the
    `confirmation("onDecoded fires once")` block with a
    `withCheckedContinuation` that bridges the `onDecoded` callback to `await`.
    The continuation resumes the moment `onDecoded` fires, so the confirmation
    body returns as soon as the decode genuinely completes — no fixed window to
    miss under load.
  - The `onDecoded` handler still `#expect`s the fired key equals the requested
    key and still calls the confirmation's `decoded()`, so the "fires **exactly
    once** with the expected key" intent is preserved (the `confirmation` default
    expected count of 1 enforces the "once"). A `resumed` guard flag ensures the
    continuation resumes exactly once (all handler runs are on the main actor, so
    the flag is race-free).
  - Post-block assertions are unchanged: `cache.image(for: key) != nil` (cache
    populated) and `scheduler.inFlightCount == 0`. Because `onDecoded` fires only
    after the cache insert and in-flight clear, awaiting it makes both assertions
    deterministic.
- **No product code touched.** `DecodeScheduler`'s existing `onDecoded` callback
  is a sufficient, already-public (internal/`@testable`) completion seam; no
  new test hook was needed.
- **Sibling tests audited.** The other `DecodeSchedulerTests` cases
  (`decodeBlockingDownsamples`, `retainOnlyCancelsStale`) do **not** use the
  sleep-then-assert pattern (the former is synchronous, the latter deliberately
  asserts in-flight state with no await), so they were left untouched. This was
  the only fixed-sleep async decode flake in the file.

## Files changed

- `CanvasRenderer/Tests/CanvasRendererTests/HostTests.swift` — rewrote the async
  decode test to await the `onDecoded` callback via `withCheckedContinuation`
  instead of a fixed `Task.sleep`.

## Verification

Full package suite (`swift test`), 5 consecutive runs — all green (this test
previously failed ~half the runs):

```
􁁛  Test run with 79 tests in 16 suites passed after 3.365 seconds.
􁁛  Test run with 79 tests in 16 suites passed after 3.285 seconds.
􁁛  Test run with 79 tests in 16 suites passed after 3.280 seconds.
􁁛  Test run with 79 tests in 16 suites passed after 3.307 seconds.
􁁛  Test run with 79 tests in 16 suites passed after 3.325 seconds.
```

## Migration notes

None. Test-only change; no product code, schema, or public-API change.
