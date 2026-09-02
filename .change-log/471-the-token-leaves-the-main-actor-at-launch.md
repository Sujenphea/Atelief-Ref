# 471 — the token leaves the main actor at launch

[470](470-the-second-cache-takes-the-same-seam.md) finished its work, could not commit it,
and closed by naming the thing in the way:

> **The UI stage's keychain blocker is diagnosed, not fixed.** … the fix is a judgement
> the user has to make: answer the prompt each time the app is rebuilt; or move
> `CaptureTokenStore` to the data-protection keychain; or take the blocking
> `SecItemCopyMatching` off the launch path so a stalled keychain cannot stall the
> window. **The last of those is worth doing on its own merits** — a keychain round trip
> on the main actor at launch is a hang the app can suffer in the wild, not only under a
> UI test — but it is a production change and nothing in 099 authorises it.

The user authorised it as **issue 22A**, and asked for both halves: the production fix,
and a UI suite that does not need the endpoint at all. This entry is that phase, and it
carries **two commits** — its own, and 470's, which had been sitting finished behind this
gate.

So the diagnosis is not redone here. 470 established where the main thread was, that the
item lives in the file-based `login.keychain-db`, and that the ACL binds to the reading
binary's code signature — which an ad-hoc-signed rebuild cannot satisfy without a
`SecurityAgent` prompt that unattended `xcodebuild` will never answer. What 22A had to
find out was narrower and, it turned out, not what was expected: **why the code was on
the main actor in the first place.**

## What actually forced the hop — two build settings, and the second is the trap

The brief's own framing was "check whether they are already `nonisolated`". They were
not, and the reason is invisible in the file:

```
$ xcodebuild -target AtelierRefs -showBuildSettings | grep SWIFT_
    SWIFT_APPROACHABLE_CONCURRENCY = YES
    SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
    SWIFT_VERSION = 6.0
```

**1. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** `CaptureTokenStore` is a bare `enum`
with no isolation annotation anywhere in it, so every one of its statics is *implicitly*
`@MainActor` (SE-0466). The blocking `SecItemCopyMatching` was not merely *called from*
the main actor by `IngestionModel` — it **was** main-actor code. That distinction is the
whole difficulty: the obvious fix, "wrap the call in a `Task` and `await` it", would have
hopped **onto** the main actor and blocked it in exactly the same place, and the gate
would have failed for reasons that looked like a different bug.

**2. `SWIFT_APPROACHABLE_CONCURRENCY = YES`.** This turns on
`nonisolated(nonsending)`-by-default (SE-0461), under which a plain `nonisolated async`
function runs **on its caller's actor**. So even after marking the type `nonisolated` and
the entry point `async`, a call from `startCaptureEndpoint` would still have executed on
the main actor. `@concurrent` is the opt-out that actually guarantees the global executor,
and it is the load-bearing token in this diff.

This is not reasoning from the manual; it is measured, below, by deleting the attribute
and watching exactly one test fail.

## The production fix

`CaptureTokenStore` is now `nonisolated`, and grew two `@concurrent` entry points:

```swift
@concurrent static func loadOrCreate(service:defaults:) async -> String
@concurrent static func regenerate(service:) async -> String
```

`IngestionModel.loadOrCreateCaptureToken()` is **deleted** — its three lines moved into
`loadOrCreate` unchanged — and `startCaptureEndpoint` now says `await
CaptureTokenStore.loadOrCreate()`. `regenerateCaptureToken()`'s `save` moved the same way:
that one is a button rather than a launch, so it could not hang a window that had not
opened yet, but it is the same blocking XPC call behind the same dialog and there was no
case for leaving the smaller version of the bug behind.

**The three primitives stay synchronous.** `load` / `save` / `delete` are the Keychain
operations, and off the main actor a blocking keychain call is the right thing; a test
also has to be able to drive them from a `defer`, which cannot `await`. What changed is
that the app no longer calls them directly — the two `@concurrent` functions are the only
entry points production uses, and the file's header says so.

**One thing the type system forced that is worth recording.** `UserDefaults` is documented
thread-safe — this app already leans on that in as many words, in the `consentGranted`
closure three lines below the call site — but Foundation does not mark it `Sendable`, so
handing one to a `@concurrent` function is *"sending 'defaults' risks causing data races"*
and the build stops. The `defaults:` seam could not simply be dropped: it is what the
isolation test uses to see which thread the store ran on. So there is now a
`CaptureTokenStore.SendableDefaults` — an `@unchecked Sendable` wrapper around one value,
with the justification next to it. The alternative, a retroactive `extension UserDefaults:
@unchecked Sendable`, makes that promise on Foundation's behalf for every `UserDefaults`
in the module, which is a much larger claim than the one that is true.

### Ordering — what had to keep working

`bootstrap()` already `await`ed `startCaptureEndpoint`, so the sequencing is untouched:
the endpoint is still up, and `captureToken` / `captureEndpointRunning` still published,
before `bootstrap()` moves on to `activateInboxDrain` and the blob pass. What is new is a
**suspension point** inside `startCaptureEndpoint`, before `self.captureToken = token`.
Other main-actor work can now interleave in that window where previously the thread was
simply blocked — which is the improvement, not a regression: before, nothing could draw
during that window at all, including the window itself.

## Production behaviour — what changed, and what did not

**It changed, and that is the point.** 470's entry could say "nothing changed"; this one
cannot, and should not pretend to. The app no longer blocks its main thread on `securityd`
at launch. A user whose keychain is locked, or whose ACL prompt is waiting, now gets a
window and a usable app while the token resolves behind it, where before they got a beach
ball for as long as the dialog stood unanswered.

**Everything the token itself does is identical.** Same service name
(`so.atelier.refs.capture-token`, still asserted by `productionNameUnchanged`), same
first-run generate-and-store through `CaptureToken.generate()`, same one-shot G6 migration
out of `UserDefaults` with the cleartext copy removed after, same token handed back, same
`CaptureAuth` binding. `regenerateCaptureToken` still stops the server, persists, restarts
bound to the new secret and raises the same toast, in that order.

The one visible difference is a consequence of not blocking: `captureToken` is published a
few milliseconds later relative to other main-actor work, so the Settings pane can now
render for an instant with an empty pairing token. `CaptureCopy.hasToken` already gates the
copy button and the regenerate button on exactly that, so the empty state is one the UI was
already written to draw.

## The DEBUG flag

`-skip-capture-endpoint`, declared in `AtelierRefs/Debug/CaptureEndpointFlag.swift` and
honoured at the top of `IngestionModel.startCaptureEndpoint` inside `#if DEBUG`.

Half 1 stops the app **hanging** on the keychain. It does not stop macOS **asking**, and a
flow that waits on a dialog nobody will click still times out at 30 s. The three smoke
flows assert a window, a Settings scene and the sidebar's order; not one of them speaks to
the browser extension. An endpoint nothing asserts is an endpoint the suite should not be
starting.

The conventions were followed rather than reinvented:

- **`#if DEBUG`**, 099 · 8A's rule for launch arguments. The type is not in a Release
  build, and neither is the guard reading it — so there is no argument a shipped app could
  be launched with that would quietly leave a user unpaired. `App target (Release)` is the
  stage that proves the other side of that `#if` still compiles.
- **The spelling matches 098's seeder**, `-seed-fixture-library`: leading dash, hyphenated,
  verb first.
- **`isRequested(in: [String] = CommandLine.arguments)`** — the defaulted-argument-vector
  shape `BakeoffAutorun.parse(arguments:)` and `CanvasPinchBakeoff.parse(arguments:)`
  already use in `Debug/`, and the only shape a unit test can drive: a test process's
  `CommandLine.arguments` belong to the xctest runner.

**And it goes LAST in `SmokeUITests.launch()`.** That file already carried the reason in a
paragraph, and the paragraph was read before the array was touched: `UserDefaults` parses
launch arguments as `-key value` pairs, so `-AtelierDidCompleteOnboarding YES` must come
first and bare flags must follow, or the pair swallows the flag as its value and the
first-run onboarding sheet covers every flow. There are now two bare flags, both after the
pair, and the comment says so.

Checked before relying on it: `settings.capture.endpoint` is on the leaf `Text` of the
Endpoint row, which `SettingsView` renders unconditionally — only its `foregroundStyle`
depends on `captureEndpointRunning`. So the ⌘, flow's proof that the second window is the
Settings scene costs nothing to the flag.

## Tests — nine added, none removed

`CaptureTokenStoreTests` 9 → 15, and a new `CaptureEndpointFlagTests` with 3. No test was
weakened or deleted; the nine pre-existing synchronous cases are untouched, which is itself
the check that the primitives still behave.

**The isolation is asserted directly, not as a duration.** A timing assertion would be a
bet on a loaded machine and would pass for the wrong reason on a fast one. The seam is the
`defaults:` parameter P1 already added: `load` calls `defaults.string(forKey:)` itself, so a
`UserDefaults` subclass that records `Thread.isMainThread` reports the executor **the store
was actually running on, at the moment it did the work**.

| Test | What it pins |
|---|---|
| `loadOrCreateRunsOffTheMainThread` | the store's own keychain work is not on the main thread |
| `primitivesAreReachableOffTheMainActor` | `load`/`save` are callable from a `Task.detached` at all |
| `loadOrCreateReturnsStored` | an existing token is returned, not re-minted |
| `loadOrCreateMintsOnFirstRun` | first run mints **and stores**; the second finds the same one |
| `loadOrCreateMigratesLegacy` | G6 still migrates and still clears the plist, through the async path |
| `regenerateReplaces` | a fresh token, different, and persisted |
| `CaptureEndpointFlagTests/spelling` | the string `SmokeUITests` passes, spelled twice across two modules |
| `…/present` | the flag is seen where the UI test actually puts it — last, after a pair and another flag |
| `…/absent` | every ordinary launch takes the other arm; a near-miss (`-skip-capture-endpoints`) is not a match |

`primitivesAreReachableOffTheMainActor` is half a **compile-time** assertion and says so:
before 22A the statics were implicitly `@MainActor`, and a `Task.detached` closure — which
is nonisolated — could not have called them synchronously at all. The runtime half checks
the detached task really was off the main thread, so the compile-time property is not
vacuous.

Two things the compiler had to teach, both now written down beside the code: `Thread.isMainThread`
is *unavailable from asynchronous contexts*, so the probe reads it from a synchronous
`nonisolated` helper; and the recording `UserDefaults` subclass had to be `nonisolated`
itself, because the **test target carries the same `SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`** — a probe for main-actor isolation that is itself pinned to the main actor
could only ever have reported `true`.

### The discrimination check

Not a tally — a deletion. Removing `@concurrent` from `loadOrCreate` and re-running the
suite:

```
Test case 'CaptureTokenStoreTests/loadOrCreateRunsOffTheMainThread()' failed
Test case 'CaptureTokenStoreTests/primitivesAreReachableOffTheMainActor()' passed
** TEST FAILED **
```

**Exactly one test fails, and it is the right one.** That is simultaneously the proof that
the test tests something and the measurement behind the SE-0461 claim above: with
`SWIFT_APPROACHABLE_CONCURRENCY = YES`, `nonisolated` + `async` really does still run on
the caller's actor, and `@concurrent` really is what moves it. The attribute was restored
immediately afterwards.

## The gate

`./scripts/verify.sh` full — **exit 0**:

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

`⚠ Extension` is the stale Instagram drift fixture, non-fatal by design since
[464](464-the-gate-tells-its-two-arms-apart.md) and not this phase's.

### `App target (UI)`, verified the hard way

A pass on an already-authorised binary proves nothing here — that is precisely the case
470 recorded as passing while a rebuild failed. So the stage was **also** run on its own
with a fresh `-derivedDataPath`, which forces a full rebuild and a new ad-hoc signature —
the exact condition under which HEAD failed all three flows:

```
Test case 'SmokeUITests.testLaunchShowsTheSeededCollectionOnHome()' passed (4.842 seconds)
Test case 'SmokeUITests.testSidebarListsTheSeededCollectionsInOrder()' passed (6.958 seconds)
Test case 'SmokeUITests.testCommandCommaOpensASettingsWindow()' passed (10.925 seconds)
** TEST SUCCEEDED **
```

Five seconds, seven seconds, eleven seconds — against the 30-second main-thread timeout all
three used to hit. The binary was compiled and ad-hoc-signed from scratch at a path macOS
had never seen, which is the condition 470 showed HEAD failing under.

**The first attempt at that run failed, and not for this reason — which is worth writing
down.** It ended at:

```
AtelierRefsUITests-Runner encountered an error (The test runner failed to initialize for
UI testing. (Underlying Error: Timed out while enabling automation mode.))
```

That is a **TCC automation grant** for a runner binary at a path the system had no record
of — not a keychain event, and nothing to do with the token: the runner never initialised,
so no app was launched and no flow ran. Re-running against the same already-built products
cleared it, and all three flows then passed. So the UI stage has a *second* unattended
permission trap in it, independent of the one 22A fixes, and it is armed by a **novel
derived-data path** rather than by a rebuild. `verify.sh` itself never trips it — it uses
the default derived-data location, which is why its own `App target (UI)` is green above on
the first try — but a future phase that runs this stage somewhere new will meet it once.

**Both commits are covered by this one gate run.** 22A landed first and P2c second, and the
tree the gate ran against is the tree after both — which is the only honest way to describe
it, and is said here rather than implied.

## Files

- `AtelierRefs/AtelierRefs/CaptureTokenStore.swift` — `nonisolated` on the type;
  `@concurrent loadOrCreate` and `regenerate`; `SendableDefaults`; a header that names both
  build settings and the rule they leave behind.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `loadOrCreateCaptureToken()` deleted,
  `await CaptureTokenStore.loadOrCreate()` in its place; the regenerate path awaits too; the
  DEBUG skip guard.
- `AtelierRefs/AtelierRefs/Debug/CaptureEndpointFlag.swift` — **new.** The flag, its three
  properties, and why it exists.
- `AtelierRefs/AtelierRefsTests/CaptureTokenStoreTests.swift` — 9 → 15, plus the
  thread-recording defaults and the `isOnMainThread` helper.
- `AtelierRefs/AtelierRefsTests/CaptureEndpointFlagTests.swift` — **new**, 3 tests.
- `AtelierRefs/AtelierRefsUITests/SmokeUITests.swift` — the flag, last in the array, and the
  ordering paragraph extended to say why there are now two bare flags.
- `.docs/099-mac-backlog-plan.md` — a 22A section and status row.

No `project.pbxproj` change: `AtelierRefs`, `AtelierRefsTests` and `AtelierRefsUITests` are
`PBXFileSystemSynchronizedRootGroup`s, so the two new files join their targets by existing.
`xcodebuild -showBuildSettings` and the gate's fourteen stages both resolve them.

## What is still NOT covered

**The prompt itself is not gone, and 22A does not claim it is.** The login-keychain ACL is
still bound to the binary's cdhash, macOS will still raise `SecurityAgent` on a rebuilt
ad-hoc-signed app, and a developer running the app from Xcode after a rebuild will still
see the dialog. What changed is that the app no longer **hangs** behind it and the UI suite
no longer **waits** for it. Moving the item to the data-protection keychain
(`kSecUseDataProtectionKeychain`), whose access is entitlement-based rather than
signature-based, is the change that would actually retire it — and it is a migration, not a
flag: every existing user's token lives in the file keychain today and would have to be
carried across. Nothing here does that.

**Nothing asserts that the app skips the endpoint.** `CaptureEndpointFlagTests` pins the
predicate, which is a pure function; the claim that `startCaptureEndpoint` then returns
early is carried only by the UI stage passing. A unit test cannot make it —
`IngestionModel.bootstrap()` runs off `init()` against a real library — and one that mocked
its way to the assertion would be asserting the mock. If the guard were deleted, the three
smoke flows would go back to timing out, which is a slow and indirect alarm.

**The endpoint's own launch path is now less covered by the UI suite than it was.** It was
never *asserted* there — no flow touched it — but it was *exercised*, and a crash inside
`startCaptureEndpoint` would have failed the suite. It no longer would. That is a real
reduction and it is a deliberate trade, not an oversight.

**`@concurrent` is asserted at one call site, not as a rule.** `loadOrCreateRunsOffTheMainThread`
covers `loadOrCreate`. `regenerate` has no equivalent probe — it takes no `defaults`, so it
has no seam to record a thread through, and its test asserts only the token. A future edit
that dropped `@concurrent` from `regenerate` would put a blocking keychain write back on the
main actor and nothing in this repo would say so.

**Whether the launch is measurably faster is not measured.** No before/after timing was
taken. The argument here is structural — the work is provably on another executor — and a
duration is exactly the kind of evidence this phase decided not to rest on. On a machine
whose keychain is unlocked and whose ACL is already satisfied, the difference is likely
below noise; the case for the change is the machine where it is not.

**The three load-induced timeout flakes are untouched**, as the user directed:
`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests` remain
a recorded risk from 469 and 470. They are timeout-shaped, not keychain-shaped, and nothing
here changes what the right bound is.
