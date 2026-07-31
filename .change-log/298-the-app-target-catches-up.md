# 298 — the app target catches up to Swift 6

## Summary

All five local packages have shipped `swiftLanguageModes: [.v6]` since they were
written. The Xcode project did not: `SWIFT_VERSION = 5.0` on all six build configs.
So the app — the one target that owns every AppKit seam, every drag, and every
`Task` — was the last Swift 5 island in the repo, consuming Swift 6 modules while
opting out of the checking that makes them safe.

It is now `6.0` on all six.

## The MainActor default is per-target, on purpose

| Target | `SWIFT_DEFAULT_ACTOR_ISOLATION` |
| --- | --- |
| `AtelierRefs` | `MainActor` — already set |
| `AtelierRefsTests` | `MainActor` — **added** |
| `AtelierRefsUITests` | *unset*, deliberately |

The unit target is Swift Testing against a MainActor app; matching the app's default
is what makes `@testable` types usable without annotating every test.

The UI target is XCTest, and `XCTestCase` is nonisolated by design — its `setUp`,
`tearDown` and `test…` methods override nonisolated requirements. Defaulting that
target to MainActor would put every override in conflict with what it overrides, to
no benefit: a UI test drives the app through `XCUIApplication`, out of process, and
touches none of its actor-isolated state.

## 17 files, and every one of them is an annotation

No logic moved. The fixes fall into four groups:

**AppKit overrides that must stay nonisolated** — `NSObject.isEqual`/`hash` on the
two outline nodes, `NSFilePromiseProvider`'s pasteboard methods, and both
`NSMenuItem` subclasses. AppKit calls these from wherever it is diffing rows or
servicing a pasteboard; MainActor-by-default would have inferred isolation that does
not match the requirement. The menu items instead type the *handler* `@MainActor`,
which is where the isolation actually belongs — the item merely carries the closure.

**`@unchecked Sendable` helpers contradicting themselves** — `BakeoffThumbnailStore`
and the three test decode probes each claim `Sendable` and are each handed to a
`@Sendable` closure parameter, while the target's default would isolate them to
main. `nonisolated` states what the `@unchecked` was already asserting.

**Pure values built off-main** — `PostRestoreBlobReport` is constructed inside the
post-restore reconcile's `Task.detached`, and the three `CGImage` factories in the
tests run on the probes' decode. Same reason 285 marked the value types the
`#expect` macro touches.

**Two real transfers, both across the drop path** —
`DirectInputReader.inputs(from:…)` now takes `sending [NSItemProvider]`, and
`CollectionView`'s drop handler asserts the transfer with `nonisolated(unsafe)`
before the `Task`. `NSItemProvider` is not `Sendable`; SwiftUI hands the array over
and never touches it again, but that is not visible to the compiler through a closure
parameter it does not own. The alternative was decoding on the main actor, which is
the one thing that path exists to avoid.

## The two changes that are not purely annotations

`AssetDragPayload.loadFirst` replaced `DispatchQueue.main.async { completion(…) }`
with `Task { @MainActor in completion(…) }`, and the completion type gained
`@MainActor @Sendable`. Same destination, checked instead of assumed. The hop is now
an async-context enqueue rather than a runloop enqueue, so it is not bit-identical in
ordering against other `DispatchQueue.main` work — the callback only opens a drop, so
nothing races it.

`FrameTimeRecorder.step` reads `link.timestamp` and `link.targetTimestamp` out of the
`CADisplayLink` *before* `MainActor.assumeIsolated`, because that closure is `sending`
and `CADisplayLink` is not `Sendable`. Two `Double`s carry everything the body needed.
The arithmetic is unchanged.

## Files changed

`project.pbxproj` (6 configs), 12 app sources, 4 test sources, and
`AtelierIngestion/Input/DirectInputReader.swift`.

## Migration notes

`DirectInputReader.inputs(from:into:now:)` is public API and its first parameter is
now `sending`. Callers that need the array afterwards must copy it first; the app's
one caller does not.

## Verified

`build-for-testing` → `** TEST BUILD SUCCEEDED **` (all three targets compile) and
`-only-testing:AtelierRefsTests test` → `** TEST SUCCEEDED **`.

The UI tests are not run here and do not pass, for a reason that predates this change:
`testLaunchAndNavigateShell:39` asserts a top-level "Sweeps" toolbar button that no
longer exists — Sweeps opens from the Capture pane (`AppShellView.swift:264`). It is
asserting the same removed toolbar that orphaned `status` in 289.
