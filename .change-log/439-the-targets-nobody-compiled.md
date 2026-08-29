# 439 — the targets nobody compiled

CI has four jobs and none of them built the phone.

`swift-packages` runs nine suites on macOS. `ios-packages` cross-builds the five packages
that ship inside an iOS process. `extension` runs 608 node tests and the drift check. `app`
runs `xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'`, restricted to
`-only-testing:AtelierRefsTests`.

Between them they never touched `AtelierRefsMobile` (1,837 lines) or `AtelierRefsShare`
(951). A syntax error in `ShareViewController.swift` went green.

## Why this is the file it had to happen to

The share extension is the one place in the repo with **no unit test host at all**. That is
a deliberate choice — 092 · S4b-ii pushed everything decidable into `AtelierCapture` so it
could be tested under `swift test`, and what stayed behind is the residue that genuinely
needs a process. The trade only holds if the residue is at least *compiled*: a file with no
tests and no build is a file with nothing.

Its 951 lines are also the ones about to be edited. Three planned changes — moving tier 2's
precedence rules into `ShareCapture`, degrading an over-cap image to the tier-2 fallback
instead of failing the share, and making the media-fetch timeout a per-share budget rather
than a per-candidate one — all land in `harvest()` and `fetchMedia()`. Three changes to an
unverified file was the thing to fix first.

## Build-only, and that is the same argument one job up

`ios-packages` already says it:

> There is no `swift test` row because SwiftPM cannot run a test bundle without a simulator
> host; the compile IS the gate.

The same holds here, harder. `AtelierRefsMobileUITests` needs a booted simulator, and
`Tier2ShareUITests` needs Safari and a real share sheet — so the tests cannot ride this job
even if the targets could. What a compile catches is what this is for.

`generic/platform=iOS Simulator` rather than a named device: a build needs nothing booted,
and `name=iPhone 16` would make the job fail the day a runner image retires that device
instead of the day the code breaks.

Both schemes as a matrix, though building the app drags the extension in as an embedded
dependency anyway. Two rows means a failure names the target instead of leaving it to be
read out of a log.

## Files changed

- `.github/workflows/ci.yml` — new `ios-app` job, matrix over `AtelierRefsMobile` /
  `AtelierRefsShare`; header comment updated to describe five jobs rather than four.

## Verification

Both schemes built with the job's exact invocation:

```
xcodebuild build -project AtelierRefs/AtelierRefs.xcodeproj \
  -scheme <AtelierRefsMobile|AtelierRefsShare> \
  -destination 'generic/platform=iOS Simulator' \
  -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO
```

`** BUILD SUCCEEDED **` for each.

## Migration notes

None. Additive, and it needs the same Xcode 26 runner the `app` and `ios-packages` jobs
already document — if GitHub-hosted images don't ship it, this job moves to the same
self-hosted runner they do.
