# 455 — what the move found

[454](454-the-phone-drains-its-own-inbox.md) shipped the phone's drain and closed with a
confession:

> `InboxDrainScheduler` has no unit test, and `AtelierRefsMobile` has no test target. The
> three properties the design turns on — an activation dropped while a pass runs, an export
> waiting out a running pass, and a deferred activation running after an export — are
> asserted by construction and by the build, and by nothing else.

This phase moves that policy somewhere `swift test` can reach and tests it. **Two of the
three properties were wrong.** Not subtly mis-documented — wrong in the direction the
changelog's own prose claimed they were right. Both are fixed here, and both are fixed
because a test could finally ask.

Then the app was run. On a simulator, with a real share from a real Safari, watched from
outside. That had also never happened.

## Where the policy went, and why it is AtelierBrowse

`AtelierBrowse/Sources/AtelierBrowse/InboxDrainPolicy.swift`. 454 rejected this and named
the package while doing it:

> **Extracting the scheduler's gate into a package** so `swift test` could reach it.
> `AtelierIngestion` is deliberately kept free of UI-shaped cadence — its own header says
> so — and `AtelierBrowse` is the read-only browse seam.

The first half still holds and is why this is not in AtelierIngestion. The second half was
reading the package's **name** rather than its charter. Its manifest states the charter in
one sentence and it is not about reading:

> Logic that lives in `AtelierRefsMobile` is logic nothing runs but a person with a phone.
> Here it is `swift test` on macOS, in the suite style the other five packages use.

That sentence describes this file better than anything else in the program. "Browse" was
accurate while the phone only read; 454 gave the phone a writer, and the thing that decides
when the writer runs is the same kind of thing the package already holds — a companion-app
decision that is not a view.

**A new package was the alternative and it loses.** `InboxDrainPolicy` imports Foundation
and nothing else; a package for it would be a manifest, a `Package.resolved`, two CI matrix
rows and an entry in the project's package graph, bought with a name. 092 · S4b's rule
about when a boundary is the finding cuts the same way it did in 454 — there is no new
boundary here, only a file on the correct side of one that already exists.

**AtelierCapture was the near miss.** It owns `InboxLayout`, `InboxWriter` and
`InboxRetirement`, so "who may touch `inbox/` right now" reads like its subject. It is also
linked into the share extension, whose measured ~120 MB ceiling ([423](423-the-extension-measures-itself.md))
is the reason that binary is kept to appending two files and returning. Putting a scheduler
in the one package the extension cannot avoid linking, for the benefit of an app that
already links AtelierBrowse, is a cost with no payer.

## Generic over what a pass returns

`InboxDrainPolicy<Outcome>`, where the app instantiates `InboxDrainPolicy<DrainSummary>`
behind the typealias `InboxDrainScheduler`.

The alternative was AtelierBrowse depending on AtelierIngestion, which builds for iOS as of
[452](452-the-factories-were-never-the-appkit-part.md) and would therefore have compiled.
It would have meant linking an entire ingest pipeline into the read seam to name the return
type of one closure the policy hands straight back to its caller without looking inside. The
type parameter says that fact out loud, and the tests instantiate it with `Int` — which is
the assertion that it really is never looked at.

## What stayed in the app, and it is one enum

`ScenePhase` is a SwiftUI type. `ScenePhaseKind` is its three cases without the import, and
`AtelierRefsMobile/InboxDrainScheduler.swift` is now the map between them plus the log
lines and the `DrainSummary` → `onIngest` mapping. `ContentView` and `CaptureExport` are
unchanged at every call site: `scenePhaseChanged(to: phase)` still takes a `ScenePhase`
(an overload in the app), and `InboxDrainScheduler(pass:onIngest:)` is still the
initializer (a convenience init in the app).

The mirror is three cases rather than "active and not active" because a two-case enum makes
the mapping lossy in a way the next reader has to reconstruct from the call site, and
because `@unknown default` needs somewhere honest to land. It lands on `.inactive`: a phase
this build has never seen must not be mapped to the one value that starts work.

## Bug 1 — the guard that answered first

454's header, and the file's:

> an activation dropped while an **export** holds the inbox is remembered and run
> afterwards. The Mac's argument for dropping rests on there being a pass in flight to
> inherit it; during an export there is none, so dropping would lose the activation.

The code was:

```swift
guard inFlight == nil else { /* dropped */ return }
guard exportsHolding == 0 else { missedActivation = true; return }
```

`inFlight` deliberately does not record **which kind** of holder it is — one property,
because "may I touch the inbox" is one question. That is right for the overlap guard and
wrong for this one. An export claims `inFlight` for the whole of its body, so for the entire
duration of an archive write or a retirement — precisely the window the deferral was written
for — an activation took the **first** branch and was lost. The second branch was reachable
only in the sliver where an export sat queued with the inbox momentarily free, which needs
two overlapping exports and is not a state one export at a time can produce.

The fix is the order. `exportsHolding` is asked first, so an export holding **or queued for**
the inbox defers; only a drain pass with no export anywhere near it drops. Deferring where a
pass would have inherited the activation costs one extra `contentsOfDirectory` over an inbox
that pass just emptied; dropping costs a capture until the next foreground.

**Who saw this.** A user who shares while an export is in flight, or who leaves and returns
to the app during one. On a phone with a small inbox the archive write is milliseconds and
the window is nearly closed; the whole point of the drain is the phone with the backlog,
where it is not.

## Bug 2 — two exports could live-lock the main actor

`exclusively(_:)` waited like this:

```swift
while let holder = inFlight { await holder.value }
let work = Task { @MainActor in await body() }
inFlight = work
await work.value
inFlight = nil          // ← after the task, not inside it
```

A drain pass clears `inFlight` from **inside** its task, before the task completes. The
export cleared it from outside, after. That asymmetry is the bug.

Everything awaiting a task resumes when it completes, and the loop re-reads `inFlight` on
each resumption — which is the property that makes two exports serialize. But a second
export woken **before the first's own continuation gets a turn** reads a task that has
finished, awaits a value that is already there, which does not suspend, re-reads the same
finished task, and goes round again. On the main actor. The first export is never scheduled
to clear the flag, so the loop never ends.

100% of one core, forever, with the UI frozen — in exactly the two-overlapping-exports case
the `exportsHolding` comment says the count exists to handle. It is not reachable through
the app's current controls (the send button disables on `.working`, and clear only appears
after a share sheet is dismissed), which is why it never showed up. It became reachable the
moment a test did what the code claims to support, and the first run of the new suite hung
at 100% CPU rather than failing.

The fix is to make the export release the inbox the way the drain already does — inside the
task, before it completes — so a waiter that resumes on completion always observes a
released inbox and there is no window in which a finished task is still the holder. The
post-await `inFlight = nil` goes, because by then another export may legitimately hold it.

`twoExportsDoNotSpin` is the regression case, and it queues both exports (`exportsHolding
== 2`) before releasing either, so it is deterministic rather than lucky.

## An observation hook, so the debug lines survive the move

`InboxDrainEvent` — `.activationDroppedDuringPass` / `.activationDeferredDuringExport` —
reported through an optional `observe:` closure. The app's closure writes the same two
`.debug` lines phase 3 wrote from inside the scheduler; `os.Logger` is the app's and does
not belong in a package that must build without a device.

It is optional and defaulted to `nil` because it is an observation and not a policy — a
caller that passes none gets the same cadence, and there is a test that says so. Its second
job is in the tests: both branches are invisible in every other record of what the app did
(the dropped one is absorbed, the deferred one becomes an ordinary pass later), so without
this they could only be told apart by their consequences.

`exportsHolding` also became publicly readable. It is the one piece of this type's state
whose going wrong is silent — a count left above zero stops the phone draining for the rest
of the launch and nothing reports it — and the `defer` that keeps it balanced deserved an
assertion rather than a paragraph.

## The tests — 39 of them

`AtelierBrowse/Tests/AtelierBrowseTests/InboxDrainPolicyTests.swift`, in six suites. The
pass is injected and parks on a gate, so the overlapping case is deterministic rather than
rare, and every pass, report, export body and dropped activation appends to one trace that
the ordering claims are read off. No test sleeps and then looks at a counter.

**Launch and idempotence (5).** Nothing runs before `start()`. `start()` runs exactly one
pass. A second and third `start()` are no-ops. `start()` after a completed pass is still a
no-op. `start()` arriving while an activation's pass is already in flight is swallowed by
the overlap guard **and still marks the launch as done** — a real ordering, since the scene
can become active before `bootstrap()` returns.

**Active, and only active (4).** `.active` drains; `.inactive` and `.background` do not;
over `ScenePhaseKind.allCases`, exactly one case drains, so a phase added to the mirror
later has to be reasoned about; three activations with nothing in flight are three passes;
a background → foreground round trip drains once, on the way in.

**One pass at a time (5).** Three activations against a parked pass produce one pass and
three `.activationDroppedDuringPass` events, and — the half that distinguishes a drop from a
deferral — **still one pass after it finishes**. A dropped activation produces no report.
The guard is not a latch. The claim is synchronous: after `drain()` returns, `isDraining` is
already true and the pass body has not been entered, so a second `drain()` on the next line
is dropped. And the observe hook changes no decision.

**The report (4).** Once per pass, with that pass's outcome, in order. The last outcome
repeats once the script runs out. The report runs after the pass. And the inbox is released
**before** the report — asserted by a report that checks `isDraining == false` and starts
the next pass from inside itself, which is what the app's report doing UI work must be
allowed to do.

**An export takes the inbox (13).** Both orders, and then some: an export over an idle
inbox; the inbox held for the body's duration and released after; an export waiting out a
running pass and not beginning until it ends; a pass not starting while an export holds
(**deferred**, the bug-1 regression); five activations during one export producing **one**
pass afterwards; no activation during an export producing **no** pass; the deferred pass
running after the export **body** rather than after its wait; the deferral not replaying on
the next export; two exports serializing; an activation unable to slip between two exports;
a pass then two queued exports then the deferred pass; the exclusion not being a latch;
`exclusively(_:)` returning only after its body; the two-export live-lock (bug 2); the
holder count returning to zero for 1, 2 and 5 exports; and ten exports interleaved with ten
activations, asserting every body ran exactly once and no two were ever open at once.

**A pass that went wrong (4).** A pass whose work throws — caught at the seam, which is
where `drainOnce()` catches it — releases the inbox and the next activation drains. A pass
cancelled mid-flight releases the inbox. An export whose body does nothing hands it back.
A hundred activations against one parked pass cost exactly one pass and one report.

Serialization is asserted as "no two bodies were ever open at once", not as "a ran before
b". Two exports parked on one drain pass are woken by the same task completing, and the
order the runtime resumes two continuations in is not something a policy can promise.

## What was seen when it was actually run

iPhone 13 Pro simulator (iOS 26.5, 390×844), Debug, `group.sujenphea.AtelierRefs.dev`.
Built, installed, launched, and driven through **Safari's real share sheet** — not a
hand-written inbox record. `xcrun simctl get_app_container … groups` resolved the container,
so the App Group is real on this build and `LibraryLocation` is not falling back to
anything.

**Cold launch, empty library.** The grid rendered "Nothing here yet / Anything you share
arrives in Unsorted." — 454's replacement sentence, and it is true. No export control, which
is correct for an inbox of zero.

**One share from Safari.** A fixture page over `127.0.0.1` with `og:site_name` and a 600×400
JPEG. What landed in `inbox/` was a 342-byte record and a 35,254-byte payload, and the
record carries `authorName: "Atelier Fixture"` — which comes from the DOM snapshot and no
other route — plus `capturedVia: ios_share`. A genuine tier-2 capture, not a degrade.

**Cold launch with one capture pending.** The process started at 17:10:52.673 and logged

    [sujenphea.AtelierRefsMobile:capture] inbox drain: 1 ingested, 0 retrying, 0 incomplete

at 17:10:53.030 — **357 ms after launch**, behind a grid that had already painted. On disk:
the record and its payload had **moved to `inbox/ingested/`**, `.retainForExport` doing
exactly what 453 built it for; one blob under `blobs/87/14/…jpeg`; and **two** thumbnails,
`@512.jpg` and `@1280.jpg`, with **no `@128`** — 454's narrowed tiers, confirmed against a
real device's filesystem rather than against a test's expectations. The screenshot shows one
masonry tile with the fixture's orange image in it and the export control reading **1**,
which is the union count meaning "still owed to the Mac".

**The activation path, which 454 could only assume.** With the app left running and
backgrounded (pid 62383), a second share was made from Safari, landing a second pending
record. Foregrounding the app — same pid, no relaunch — produced

    17:12:38.035 … inbox drain: 1 ingested, 0 retrying, 0 incomplete

**0.7 s after the foreground**, with the inbox top level empty and both records in
`ingested/`. The screenshot shows **two** tiles and the count at **2**. So `ScenePhase`
does reach the scheduler on a return to the foreground, a pass runs off it, and
`ingestGeneration` re-keys the visible feed without a relaunch. 454 listed all three of
those as assumed.

The library ended with 2 assets, 2 sources, **1 blob** and 2 thumbnail files: the two
captures are the same bytes from two fixture runs on different ports, so 18A blob-hash dedup
collapsed the storage while `originalURL` correctly kept them as two captures.

Nothing was broken that needed fixing on the app's side. The two things that were broken
were the two bugs above, and both were found by the tests before the simulator was booted.

## Files changed

- `AtelierBrowse/Sources/AtelierBrowse/InboxDrainPolicy.swift` — new. The whole policy,
  `ScenePhaseKind`, `InboxDrainEvent`, and the two typealiases `CaptureExport` is built
  with. Both fixes are here, each with the argument at the line.
- `AtelierBrowse/Tests/AtelierBrowseTests/InboxDrainPolicyTests.swift` — new, 39 tests.
- `AtelierBrowse/Package.swift` — header only: the package is not only the read side any
  more, and the "no AtelierIngestion" line now gives the reason it actually has.
- `AtelierRefs/AtelierRefsMobile/InboxDrainScheduler.swift` — rewritten as the adapter:
  the typealias, the `ScenePhase` map, the `onIngest:` convenience init, `report(_:)` and
  the two `.debug` lines.
- `AtelierRefs/AtelierRefsMobile/CaptureExport.swift` — `import AtelierBrowse`, and one
  doc reference renamed to the type that now holds the argument.

`project.pbxproj` is **untouched**: `AtelierRefsMobile` already had AtelierBrowse as a
product dependency, and nothing else moved between targets.

## Verification

`swift test`, before → after:

| package | before | after |
|---|---:|---:|
| AtelierCapture | 133 | **133** |
| AtelierIngestion | 483 | **483** |
| AtelierArchive | 65 | **65** |
| AtelierCore | 771 | **771** |
| AtelierBrowse | 43 | **82** |

All passing; nothing dropped. The policy suite was run three times over to check it is not
flaky: 39 tests, 2.03 s / 2.06 s / 2.09 s, green each time.

`xcodebuild -list -project AtelierRefs.xcodeproj` → parses, five targets.
`xcodebuild build -scheme AtelierRefsMobile -destination 'platform=iOS Simulator,…13 Pro'`
→ **BUILD SUCCEEDED**.
`xcodebuild build -scheme AtelierRefsShare -destination 'generic/platform=iOS Simulator'` →
**BUILD SUCCEEDED**. Link line checked rather than asserted, and unchanged: `ShareCard.o
ShareViewController.o AtelierLibraryPaths.o AtelierCapture.o AtelierCore.o GRDB.o
AtelierTokens.o` — no `AtelierBrowse.o`, no `AtelierIngestion.o`.
`xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` → **BUILD SUCCEEDED**.
`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'` → `** TEST SUCCEEDED **`.

No `ci.yml` change: AtelierBrowse is already in both the `spm` and the `ios-packages`
matrices, and no package's dependency line moved.

## What is still NOT covered, stated rather than implied

**`Tier2ShareUITests` cannot run, and this phase did not fix it.** It fails before it
reaches Safari, at `LibraryLocation.appGroupIdentifier()`:
`appGroupIdentifierMissing(key: "AtelierAppGroupIdentifier")`. The reason is that a UI
test's `Bundle.main` is `XCTRunner.app`, not the `.xctest` bundle whose Info.plist carries
that key — so the target's one-key plist, which its header describes at length, is not
where the lookup goes. This is pre-existing, it is not in CI (the iOS row is `swift build`
and the app row is `AtelierRefsTests` only), and fixing it is a decision about
`LibraryLocation`'s bundle lookup that belongs to whoever owns that file.

The share used to exercise the drain here was driven by a **temporary** copy of that test's
Safari half, with every App Group read removed, run and then deleted. It is not in this
commit. So a real share sheet drove a real extension into a real inbox, and there is still
no committed test that does that unattended.

**The export's side of the exclusion was not exercised on the simulator.** Both bugs fixed
here are on that path, and both are covered by the new tests over a stand-in body — not by
an archive actually being written while an activation arrives. Driving the send control and
its share sheet needs the same UI automation the paragraph above is about.

**Two overlapping exports remain unreachable through the app's own controls.** The
live-lock is fixed and pinned by a test; nothing proves a user could have hit it. The
argument for fixing it is that the code claims to support the case in a comment.

**The concurrency limit of 2 is still unmeasured**, exactly as 454 left it. This phase
watched two captures drain, which measures nothing about a backlog.

**Nothing has run on a device.** A simulator has no jetsam pressure worth the name, no real
thermals and a host filesystem. Everything above is a simulator's answer.

**The Mac's `InboxDrainScheduler` did not move and shares no code with this.** The two
policies are still stated twice, in two files, and nothing but a reader keeps them in
agreement. That was 454's arrangement and this phase does not change it — the Mac's has its
own tests in `AtelierRefsTests`, which is the reason it was never the one that needed
moving.

## Migration notes

None. The app's observable behaviour is identical apart from the two bugs, both of which
turn a lost or hung state into the documented one. No file format, no schema, no on-disk
layout, and no user-facing string changed. The Mac is untouched in every sense: it does not
link AtelierBrowse, its scheduler is a different file, and its build and test runs are
unchanged.

`InboxWork` and `InboxExclusion` are now `public` in AtelierBrowse rather than internal to
the app target; `CaptureExport` gains one import and nothing else. Any future caller of
`InboxDrainPolicy` supplies `pass:` and `report:`, with `observe:` optional.
