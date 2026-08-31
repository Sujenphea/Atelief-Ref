# 454 — the phone drains its own inbox

`InboxDrain` was written in 092 · S3 and has had a caller on exactly one platform ever
since. [452](452-the-factories-were-never-the-appkit-part.md) made the package build for
iOS; [453](453-the-inbox-becomes-an-outbox.md) made a drained record survive for export.
Both changelogs end on the same sentence — *what is still missing is a caller, not a
compile*. This is the caller.

Until now a share made on the phone landed in `inbox/` and was invisible on the phone. The
empty grid said so out loud:

> Items you share arrive after your Mac has taken them in.

It does not say that any more.

## Linked into the app, and only the app

`AtelierIngestion` is now a product dependency of `AtelierRefsMobile`. It is **not** one of
`AtelierRefsShare`, and that is the load-bearing half: the share extension has a measured
~120 MB ceiling ([423](423-the-extension-measures-itself.md)) and its whole job is to
append two files to a directory and return. An ingest pipeline in that process would be a
decode path inside the one binary in the program that must not decode.

The extension's link line is unchanged and was checked rather than asserted — its
`LinkFileList` after this change is `AtelierCapture.o AtelierCore.o AtelierTokens.o GRDB.o
ShareCard.o ShareViewController.o`, with no `AtelierIngestion.o`; the app's has it.

## A separate scheduler, because the question is asked by a different system

`AtelierRefsMobile/InboxDrainScheduler.swift` shares a filename with the Mac's and no code
with it. The Mac subscribes to `NSApplication.didBecomeActiveNotification`; the phone is
told about activation through SwiftUI's `ScenePhase`, which is not a notification, is
delivered to a View rather than an object, and does not fire for the value a scene launches
in. Sharing the implementation would have meant an `#if os(macOS)` around most of its body
and an AppKit import in an iOS target.

What is shared is the **policy**, restated:

- **launch, and every return to the foreground.** No timer, no `FSEvents` equivalent, and
  deliberately no `BGTaskScheduler` — that would drain where nobody is looking, in exchange
  for a background-modes entitlement, a second lifetime to own and a code path that only
  ever runs unobserved. Nothing has to have happened before the app opens, because the only
  surface that reads the result is the grid being opened;
- **one pass at a time.** An activation that finds a pass running is dropped, not queued:
  the drain re-enumerates from scratch, so the running pass sees whatever the dropped one
  would have;
- **the guard is a `@MainActor` read-then-write**, one synchronous step with no suspension
  in it.

**The grid is not gated on the pass.** `bootstrap()` returns, the feed renders what the
library already holds, and the drain runs behind it. A pass that ingests something bumps
`LibraryStore.ingestGeneration`, every screen is keyed on that alongside its collection id,
and the feed re-reads. So launch latency is a database read and never a backlog of image
decodes — which matters most on exactly the phone with the biggest backlog.

Every screen re-reads, not just the visible one: a pass resolves each record's own target
collection and reports only counts, so *which* grid changed is not knowable here. That is
the same trade `IngestionModel.refreshAfterIngest(touching:)` takes on the Mac, and the same
reason — the alternative is a grid that silently omits a capture the user watched arrive.

## The export is the second writer the Mac never had

This is the part with no macOS precedent. `CaptureExport` reads every record in the inbox
and moves the ones it sent into `inbox/sent/`; a pass moves records into `inbox/ingested/`.
Since 453, `InboxArchive.pendingRecords(in:)` reads **both** sets and resolves a payload
from either site. A record that moves between them while an archive is being written is a
record whose payload the copy may resolve from a site it has just left.

**Id-dedup does not absorb that.** It de-duplicates a record seen twice; it says nothing
about a file that moved mid-copy. So the export takes the inbox exclusively:

    exportsHolding += 1                   // claimed BEFORE the wait
    while let holder = inFlight { await holder.value }
    inFlight = work                       // now nobody else can start

`exportsHolding` is a count and not folded into `inFlight` for a specific reason. An export
that is *waiting* has not claimed `inFlight` yet — the pass it is waiting for still holds
it — and without the count, an activation arriving in that window would start a pass the
instant the previous one released, ahead of an export that had been waiting longer. A count
rather than a `Bool` so two overlapping exports cannot have the first to finish clear the
gate out from under the second. The wait is a `while` loop rather than one `await` for the
same reason: what is being waited for can change while waiting.

`retire()` runs under the same exclusion, and for a sharper version of the argument — it
moves and *deletes* records.

One place the phone's policy diverges from "drop it, the running pass will see it": an
activation dropped while an **export** holds the inbox is remembered and run afterwards. The
Mac's argument for dropping rests on there being a pass in flight to inherit it; during an
export there is none, so dropping would lose the activation until the next foreground.

## "Pending" had quietly come to mean two things

`CaptureExport.refresh()` counted `pendingRecordURLs()`. On a phone that drains, that number
falls to **zero** the moment a pass runs — and the send control is shown only when it is
above zero. The toolbar would have withdrawn itself from a phone with three captures still
owed to the Mac, silently, as a direct consequence of the feature landing.

It now counts the union, which is what `InboxArchive.pendingRecords(in:)` sends. Counted
rather than decoded: the archive dedups ids across the two sets, so a hand-edited inbox
holding one id in both places would be counted twice and sent once — not a state retention
can produce, since it *moves*, and paying a decode of every record on every activation to be
exact about an impossible state is a real cost against a fake one.

## Two constants that are not the Mac's

Both live in `MobileIngest`, with the argument attached, because a number without its
argument is a number the next person tidies.

**Tiers: `[.medium, .large]`, not `ThumbnailTier.allCases`.** `IngestPipeline` has always
taken a `tiers:` argument and every caller in the program has always taken the default. The
128 px tier exists for the Mac's canvas LOD, and the phone has no canvas — it opens exactly
two files, `LibraryMediaPaths.gridThumbnailSize` (512) for a masonry tile and
`.detailThumbnailSize` (1280) for the item screen, which are the only two thumbnail readers
in the app. A third tier here is a decode, a JPEG encode and a file write per capture for a
file nothing on the device will open. Narrowing cost the pipeline nothing and restructured
nothing — P14 already regenerates missing tiers per tier — so the "stop and report" branch
of the brief was not needed.

It is spelled as the two cases rather than derived from the two integers because
`ThumbnailTier(rawValue:)` is failable and a `compactMap` that dropped one would silently
stop generating a tier the grid draws. The agreement is a test, not a hope.

**Concurrency: 2, against the coordinator's default of 4. A cautious default, and the code
says so.** Nothing in this program has profiled a drain on a device. What it rests on: the 4
was chosen for a Mac, where guessing high costs a slow minute; an iOS app has a jetsam
ceiling instead, enforced by termination with no partial degradation; the expensive step is
thumbnail generation and each in-flight capture holds the source bytes *and* a decoded
bitmap, with a backlog being the case the drain exists for; and this app is also holding a
96 MB `ThumbnailCache` and a live grid while the pass runs behind it. Two rather than one,
because the drain chunks at exactly this width and 1 would give a fifty-share backlog
strictly serial decoding — the shape `InboxDrain`'s header rejects in the other direction.

## One pool, opened by the app

`LibraryStore` now opens `AppServices` itself and composes it into `BrowseLibrary(root:
services:)` — an initializer that already existed for the tests. Letting
`BrowseLibrary(root:)` open its own would have made two pools and two migration passes over
one file, in a process that now reads *and* writes.

`BrowseLibrary` keeps its `services` private and gains no write verb. That seam's whole
argument is that read-only survives contact with a UI by the UI not being handed the verb;
the drain is not the UI, so it is wired from beside the seam rather than through it.

## What was rejected

- **`BGTaskScheduler`** — above.
- **Sharing the Mac's scheduler** — above.
- **Relying on the export's id-dedup** instead of serializing — above.
- **A new iOS unit-test target for the scheduler.** An iOS app's unit tests run on a
  simulator, not on the host, so the tests would have been unrunnable by `swift test` and
  out of scope for this phase either way; and standing up a `PBXNativeTarget` with its
  configuration list, phases, synchronized group and scheme is a great deal of new object id
  in the one file this repo has a scar from ([446](446-a-count-is-not-a-tier.md)). Named in
  full under **What is not covered by a test** below rather than left implied.
- **Extracting the scheduler's gate into a package** so `swift test` could reach it.
  `AtelierIngestion` is deliberately kept free of UI-shaped cadence — its own header says
  so — and `AtelierBrowse` is the read-only browse seam. Neither is a home for a scene-phase
  policy, and inventing a package for one type contradicts 092 · S4b's own rule about when a
  boundary is the finding.

## The pbxproj

Three objects, in the shape `AtelierBrowse` and `AtelierArchive` already have for this
target. The `XCLocalSwiftPackageReference "../AtelierIngestion"` already existed
(`EA…0001`); what was missing was a second product dependency and its build file.

| id | kind |
|---|---|
| `EA0000000000000000000004` | `XCSwiftPackageProductDependency` → `AtelierRefsMobile`'s `packageProductDependencies` |
| `EA0000000000000000000005` | `PBXBuildFile` → `B10000000000000000000005` (the mobile Frameworks phase) |

Both were proved unused before being written — `grep -c` over the whole file returned 0 for
each, which is the check 446 needed and did not do: the collision there was with a
`PBXFileSystemSynchronizedBuildFileExceptionSet`, invisible to an eye scanning the
package sections and perfectly visible to a whole-file grep. Afterwards the two ids appear
3 and 2 times respectively — exactly the counts `EA…0002` and `EA…0003` have.

`xcodebuild -list` was run after **each** of the three writes, not once at the end, because
446's failure mode is `error: Unable to read project` naming nothing while `plutil -lint`
reports the file as fine.

## Files changed

- `AtelierRefs/AtelierRefsMobile/MobileIngest.swift` — new. The composition root: the two
  constants with their arguments, `MobileLog`, and `makeDrain(libraryRoot:services:)`
  stating `.retainForExport`.
- `AtelierRefs/AtelierRefsMobile/InboxDrainScheduler.swift` — new. Scene-phase cadence, the
  one-at-a-time guard, `exclusively(_:)`, and the log-only report.
- `AtelierRefs/AtelierRefsMobile/LibraryStore.swift` — opens `AppServices` and exposes it;
  `ingestGeneration` + `noteIngest()`.
- `AtelierRefs/AtelierRefsMobile/CaptureExport.swift` — `refresh()` counts both sets;
  `export()` and `retire()` run under `InboxExclusion`, which has no default.
- `AtelierRefs/AtelierRefsMobile/ContentView.swift` — `startInbox()`, the scene-phase hand-
  off, the feed's reload key, and an empty-state sentence that is true again.
- `AtelierBrowse/Sources/AtelierBrowse/BrowseLibrary.swift` — header only: the paragraph
  saying no host drains on iOS was actively misleading as of this commit.
- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — the two ids above.
- `AtelierIngestion/Tests/…/NarrowedThumbnailTiersTests.swift` — new, 7 tests.

## Verification

`swift test`, before → after:

| package | before | after |
|---|---:|---:|
| AtelierCapture | 133 | **133** |
| AtelierIngestion | 476 | **483** |
| AtelierArchive | 65 | **65** |
| AtelierCore | 771 | **771** |

All passing; nothing dropped.

`xcodebuild -list -project AtelierRefs.xcodeproj` → parses, five targets, after every
pbxproj write.

`xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'`
→ **BUILD SUCCEEDED**, no warnings.
`xcodebuild build -scheme AtelierRefsShare` → **BUILD SUCCEEDED**, link line unchanged.
`xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` → **BUILD SUCCEEDED**.
`xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'` → `** TEST SUCCEEDED **`.

The seven new tests pin what a narrowed pipeline actually writes, which nothing did before:
that `[.medium, .large]` produces exactly two thumbnail files and no third (a count, so a
fourth file from anywhere fails it); that the omitted tier is one no reader resolves a path
to; that the pipeline's **default** is still every tier, so nobody "helpfully" narrows it for
the Mac; that a full-tier host fills the missing tier back in on the same asset rather than
forking a second one; and the phone's drain end to end — narrowed tiers, width 2,
`.retainForExport` — leaving two tiers on disk and the record in `ingested/`, with a second
pass over the same inbox a genuine no-op.

## What is NOT covered by a test, stated rather than implied

**`InboxDrainScheduler` has no unit test, and `AtelierRefsMobile` has no test target.** The
three properties the design turns on — an activation dropped while a pass runs, an export
waiting out a running pass, and a deferred activation running after an export — are asserted
by construction and by the build, and by nothing else. The Mac's equivalent is tested in
`AtelierRefsTests` because that target runs on the host; an iOS app's unit tests run on a
simulator, which is the next phase's ground and not this one's. The type is built so that a
test target can drive it without changing it: `pass` and `onIngest` are injected, `drain()`
is internal rather than private, and `inFlight` is `private(set)` so a test can await the
work it started instead of sleeping for it — the same three seams the Mac's `Rig` uses.

**Nothing here has run on a device or a simulator.** The build proves it compiles and links;
it does not prove the App Group container resolves (`CODE_SIGNING_ALLOWED=NO`), that a share
from Safari drains, or that the grid refreshes when one does.

**The concurrency limit of 2 is unmeasured**, and the code says so at the constant. It is
reasoning about jetsam and about where the allocation goes, not a profile.

**`ScenePhase` delivery is assumed, not observed** — specifically that a launch delivers
`.inactive` → `.active` and therefore fires one activation pass immediately after the launch
pass. That overlap is harmless by the guard, but which passes actually run at launch is a
fact about SwiftUI that only a simulator can confirm.

## Migration notes

None on disk. A phone whose drain has never run has an inbox in exactly the shape 453 left
it; the first pass creates `inbox/ingested/` lazily and moves records into it. The Mac is
untouched — same scheduler, same `.discardWhenIngested`, same tiers, same width.

The one user-visible change to an existing surface is the toolbar count, which now means
"waiting to reach the Mac" (pending **plus** ingested) rather than "waiting in `inbox/`".
Before this commit the two sets were the same one on a phone, so no existing device sees the
number change.
