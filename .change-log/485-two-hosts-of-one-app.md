# 485 — two hosts of one app are not two independent tests

## Summary

The App-target stage runs `AtelierRefsTests` **serially** now
(`-parallel-testing-enabled NO`), in `scripts/verify.sh` and in CI.

This is a correctness change, not a flake concession. `AtelierRefsTests` is
hosted **in the app**: every runner process launches a real AtelierRefs, which
boots `IngestionModel` and binds the capture endpoint on a **fixed** port
(`IngestionModel.capturePort()` — `CaptureServer.defaultPort`, or `+1` for a
`.dev` bundle id). Two runner processes race for one socket, and the loser
carries on with `captureEndpointRunning == false`:

```
[FlyingFox] server error: SocketError. Bind(48): Address already in use
```

They also share one sandbox container. Two hosts of this app are not independent,
so running two concurrently is unsound however green it happens to come out.

Measured cost: **46 s serial against ~90 s parallel.**

## What this does NOT claim

**It does not fix `.change-log/482`'s signature A, and it must not be read as
having done so.**

The stage still had an intermittent failure with exactly that signature: a flat
`60.000 s` against a suite's one-minute `.timeLimit`, naming an arbitrary
`@MainActor` test. Twice that test was **synchronous** —
`SwitcherModelTests/emptyLibrary()` is four statements and no `await`. A
synchronous test cannot hang; it can only fail to *start*. So something was
holding the **main actor** for a minute, which is 482's mechanism transposed from
the cooperative pool onto the main thread.

That something was not found. Ruled out, each by experiment:

| candidate | verdict |
|---|---|
| unbounded thread parks (482's cause) | absent — the bounded `DecodeLatch` (10 s ceiling) and two `await`s are the only blocking sites in the target |
| the capture-port collision above | **not the trigger** — a run with the port deliberately held by a second app instance came out green |
| CPU load | not sufficient — green under 16 burners on 8 cores |
| `AppKitBakeoffGridTests.settle()`'s `RunLoop.run(until:)` | one caller, 150 ms, not in a loop |

Four consecutive parallel runs were green once the machine was quiet, after three
reds in six earlier runs. Every red coincided with a concurrent `xcodebuild` —
heavy I/O and process churn rather than CPU alone — but the observer was also the
load, so that correlation is weak evidence and is recorded as such.

So: the concurrency the failures only ever appeared under is gone, and the stage
is deterministic. The underlying main-actor park, if it is real, is still there
and will need a captured sample of a hung runner to find. **A future flat-60 s
failure in any suite means that park, not this.**

## Files changed

- `scripts/verify.sh` — `-parallel-testing-enabled NO` on the app stage, with the
  account above in the function header.
- `.github/workflows/ci.yml` — the same flag, pointing at that header.

## Migration notes

None. Test-harness only; no production code and no test source changed.
