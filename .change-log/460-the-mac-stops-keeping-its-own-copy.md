# 460 — the Mac stops keeping its own copy

[098](../.docs/098-ios-companion-completion-plan.md) · **P4**: findings 5, 6, 11 and the
last piece of 12. The first phase of this pass that edits the Mac app, and the only one
that edits `project.pbxproj`.

Every phase so far has moved logic OUT of an app target and into a package where
`swift test` can reach it — [457](457-one-spelling-of-each-rule.md) the fixtures,
[458](458-the-fate-a-capture-gets.md) the drain's fates,
[459](459-the-phone-hands-over-its-logic.md) the phone's store and export controller. Each
one left the same sentence behind: the Mac has its own copy of this, and we cannot touch it.

This is the phase that touches it. `AtelierBrowse` is now a product dependency of
`AtelierRefs`, and five things the Mac had been spelling for itself — a drain cadence, a
date format, nine platform labels, an author rule, a collection ordering and a pair of
aspect clamps — are spelled once, in the package, by the code both platforms run.

**The Mac deleted more than it gained.** `InboxDrainScheduler` lost its guard-and-claim,
`ItemDetailView` lost `DetailFormat` and an author rule, `CollectionTargets` lost three
functions and a struct, `MasonryLayout` lost two constants and a function. What arrived is
one import line in six files and a `typealias`.

## The copy that had already drifted, and nobody could have seen it

098 · finding 6 named one real defect among the restatements, and it is the whole argument
for this phase in one line:

```swift
// AtelierRefs/ItemDetailView.swift            AtelierBrowse/BrowseFormat.swift
.trimmingCharacters(in: .whitespaces)          TextRules.nonBlank(…)   // …AndNewlines
```

An `authorName` of `"Ada\n"` — which a page extractor produces from a wrapped byline — was
`"Ada"` on the phone and `"Ada\n"` on the Mac: a name followed by a blank line inside a
`Text`, from one database row, on two screens showing the same capture. Nothing failed.
Nothing logged. The two files had been in the repository together, agreeing about
everything else, for two slices.

The stricter rule wins on both, and it now has the cases: `"Ada\n"`, `"\nAda"` with
`"@ada\n"`, `"\n"` alone, `"\r\n"`, and — the case that says what "stricter" does NOT mean —
`"Ada\nLovelace"`, which is data and is left alone. That is the only user-visible behaviour
change in this changelog.

## The fate nobody had a word for

098 · finding 5 asked for `report(_:)` to move, on the grounds that the Mac's and the
phone's were byte-identical apart from `AppLog` vs `MobileLog`. They were. What the move
found is what they were identically MISSING.

[458](458-the-fate-a-capture-gets.md) added `DrainSummary.skippedExhausted` — a capture the
phone tried three times and gave up on, kept in the pending set anyway because
`inbox/failed/` is a place the export does not read. It is the fate that phase invented for
the phone, and **neither app's `report(_:)` mentioned it**. A device that had permanently
stopped trying a capture said so in no log, on either platform, for two changelogs.

`DrainSummary.reportLines` in `AtelierIngestion` now decides the sentences, their order and
their level, and it has a line for that one:

```
N capture(s) out of attempts; kept for export
```

At `.notice`, not `.error`, and that is the one place it differs from a quarantine. A
quarantine happens once and takes the record out of the enumerated set. An
exhausted-but-retained record stays pending, so **every** pass for the rest of the library's
life counts it again — an `.error` on every foreground for a condition that recurs by design
is how a log stops being read. Nothing is lost either: the record is still in the pending
set and the export still sends it, which is the whole reason the fate exists.

It is a line of its own rather than a fourth count on the existing notice, because only
`.retainForExport` can produce it: folding it in would print `, 0 exhausted` on the Mac
forever, for a fate the Mac does not have.

Fifteen tests, over every combination the type can produce — including the silent one. A
pass that did nothing emits no lines at all, so "log every line of `reportLines`" needs no
guard at the call site, and a phone with an empty inbox stays quiet on every activation.

**What did NOT move is the level mapping.** Four lines in each app, deliberately: `os` is a
system framework no package here imports, and handing `Logger` a pre-built `String` gives up
the `privacy:` control every other call site in the program keeps.

## The Mac's scheduler is now an adapter, and its tests did not move an inch

`AtelierRefs/InboxDrainScheduler.swift` held the guard-and-claim in ten lines.
[454](454-the-phone-drains-its-own-inbox.md) restated it for the phone,
[455](455-what-the-move-found.md) named the duplication and left it, and 096 · 4 phase 4 then
moved the phone's copy into `AtelierBrowse/InboxDrainPolicy.swift` — where 39 tests found
**two live bugs** in a rule both platforms had been reading and agreeing with for months: a
guard order that lost every activation during an export body, and a live-lock between two
overlapping exports. The Mac kept the untested copy of half that rule until now.

What is left in the file is the two things that genuinely are the Mac's:

1. **`NSApplication.didBecomeActiveNotification`.** The Mac is asked "are you active?" by
   AppKit, through a notification, delivered to an observer object; the phone is told by
   SwiftUI's `ScenePhase`, which is not a notification and does not fire for the value a
   scene launches in. That is why there are two adapters over one policy — and why this one
   is a class holding a policy rather than the phone's `typealias`: the subscription is
   state, and the policy has nowhere to put it.
2. **`AppLog`.**

`currentPass` forwards to the policy's `inFlight`; `isDraining` forwards to `isDraining`.
All eight cases in `InboxDrainSchedulerTests` run **unchanged**, against the same
`start()` / `drain()` / `currentPass` / `isDraining` surface, and not one assertion was
weakened, softened or deleted. That was the condition P4 set for this item and it was met
without argument, because those tests were written against the rule rather than against the
implementation.

Two idempotence guards now exist and both are wanted: `activation == nil` protects the
SUBSCRIPTION (a second one would drain twice per activation for the app's life, and the
policy cannot see it), `hasStarted` protects the launch pass.

**Nothing calls `exclusively(_:)` on this host, and that is a no-op by construction rather
than by an argument passed in.** The Mac's inbox has exactly one reader; the export half of
the policy exists for the phone, whose export moves records into `inbox/sent/` while a pass
moves them into `inbox/ingested/`. `exportsHolding` starts at 0 and only `exclusively`
raises it, so the export guard is a branch never taken. `.activationDeferredDuringExport` is
handled anyway — a `switch` that assumed otherwise would be wrong the day the Mac grows an
archive writer.

## The exclusion, finally run over the thing it is for

098 · finding 11: `InboxDrainPolicyTests` proves the export exclusion 39 times, and every
one of those runs it over `Outcome == Int` with an export body that appends a string. Both
stand-ins are deliberate — the policy is generic precisely so `AtelierBrowse` never names
`DrainSummary` — and together they mean the rule had never once been run over:

> a real `.retainForExport` drain moving records out of the inbox top level while a real
> `InboxArchive.write` resolves each record's payload from whichever of the two sites it is
> in.

That needs `AtelierBrowse`, `AtelierIngestion` and `AtelierArchive` on one link line. The
packages cannot see each other by design; the phone app can and has no unit-test bundle. So
the phone's integration test lives in `AtelierRefsTests`, and nothing in the file is a Mac
behaviour.

Three cases, 30 captures each, over the real `InboxWriter`, the real `IngestPipeline` at
width 2 with the phone's two tiers, the real retaining `InboxDrain`, and the real
`InboxArchive.pendingRecords` + `.write`:

- **an export fired mid-drain** — the pass is held mid-flight by the pipeline's own `timing`
  sink, which opens the shared `Gate` the test parks on, so "the export was requested while
  a pass was running" is established rather than hoped for. Zero skips, zero unreadable, 30
  captures, 30 files, every manifest `file` present on disk, `exportsHolding` back to 0,
  pending + ingested == 30, and the two passes as `DrainSummary` values;
- **the same inbox with nothing running** — the control, because every assertion above would
  also pass if `exclusively` did nothing and the two happened not to collide;
- **an export before any drain has run** — the phone's first send, with all 30 records still
  in the inbox top level, which is the *other* half of the two-site payload resolution. The
  activation fired inside the export body is deferred, nothing moves for the whole body, and
  the deferred pass then ingests all 30.

**No `Task.sleep` anywhere in the file.** Every assertion is an invariant over the inbox and
the archive rather than an ordering — the only kind worth making about a concurrency rule.

The third case also corrected an assumption: an early draft asserted `isDraining == false`
inside the export body. It is `true`, and correctly so — `inFlight` deliberately does not say
which KIND of holder it is, which is the policy's own design decision, recorded in its
header. The assertion moved onto the directory, where the actual claim lives.

## What the `pbxproj` edit found

The scar [448](448-the-boundary-was-the-finding.md) and
[454](454-the-phone-drains-its-own-inbox.md) documented — a product dependency plus a build
file, ids allocated without collision — held. `xcodebuild -list` was run after **every** one
of the four writes and parsed every time.

What was not in the precedent: **adding one package product to `AtelierRefsTests` broke the
link of a package it had never declared.** The bundle imports `AtelierCore` in about a
hundred files and had resolved those symbols transitively through the app's debug dylib,
declaring only `AtelierLibraryPaths`. The moment `AtelierBrowse` — which depends on
`AtelierCore` — went on its own link line, 149 `AtelierCore` symbols came back undefined.
Not a stale build: it reproduced after `xcodebuild clean`.

The fix is the honest one rather than a flag: the test target now declares `AtelierCore`
explicitly, alongside `AtelierBrowse` and `AtelierCaptureTestSupport`. These are dynamic
`PackageFrameworks`, so the app and the bundle load the same dylib and there is no second
copy of any type. The rule to carry forward: **a test target that imports a package should
declare it**, and the transitive resolution it may have been getting for free is not a
property anything guarantees.

## The fixtures, finished

457 moved the JPEG builder and one `Gate` into `AtelierCaptureTestSupport` and deleted the
copies it could reach. It could not reach two, because the Mac's bundle did not link the
package. Both are gone now:

- `InboxArchiveImportTests`' hand-rolled `CGImageDestination` JPEG builder →
  `FixtureImages.solidImage(width:height:format: .jpeg)`, keeping the named wrapper because
  `jpeg(width:height:)` is what that rig's vocabulary calls a payload. Three imports
  (`CoreGraphics`, `ImageIO`, `UniformTypeIdentifiers`) went with it;
- `InboxDrainSchedulerTests`' `@MainActor` `Gate`, the third of three shapes → the shared
  `Mutex`-guarded one, whose `open()` is synchronous **by design**: an actor would insert a
  suspension point between opening the gate and the next assertion and reorder every claim a
  test makes about what happened next.

There is now one `Gate` and one JPEG builder in the program.

## Files changed

**Packages**

- `AtelierIngestion/Sources/AtelierIngestion/Input/DrainReport.swift` — **new**.
  `DrainReportLevel`, `DrainReportLine`, `DrainSummary.reportLines`.
- `AtelierIngestion/Tests/AtelierIngestionTests/DrainReportTests.swift` — **new**, 15 tests.
- `AtelierBrowse/Tests/AtelierBrowseTests/BrowseFormatTests.swift` — the newline cases for
  `BrowseFormat.author`.

**The Mac app**

- `AtelierRefs/AtelierRefs/InboxDrainScheduler.swift` — rewritten as an adapter over
  `InboxDrainPolicy<DrainSummary>`; the guard-and-claim and the report wording deleted.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `DetailFormat` deleted;
  `SourceSection.author` and the inline dimensions string replaced by `BrowseFormat`.
- `AtelierRefs/AtelierRefs/CollectionTargets.swift` — `galleryRoots`, `byManualOrder` and
  `destinationTree`'s body deleted; `DestinationTreeNode` is now a `typealias` for
  `BrowseCollectionNode`.
- `AtelierRefs/AtelierRefs/MasonryLayout.swift` — `minAspect`, `maxAspect` and
  `columnWidth` deleted; `aspect(for:)` forwards to `MasonryColumns.aspect(_:)`.
- `AtelierRefs/AtelierRefs/CollectionsGalleryView.swift`,
  `CollectionsOutlineView.swift`, `CollectionDestinationMenu.swift`, `SidebarView.swift` —
  call sites and one stale citation.

**The phone app** (the single permitted exception, for finding 5 only)

- `AtelierRefs/AtelierRefsMobile/InboxDrainScheduler.swift` — `report(_:)` routes
  `reportLines` to `MobileLog`. Nothing else in that directory was touched.

**Tests**

- `AtelierRefs/AtelierRefsTests/InboxDrainExportIntegrationTests.swift` — **new**, 3 tests.
- `AtelierRefs/AtelierRefsTests/InboxDrainSchedulerTests.swift` — the local `Gate` deleted;
  all eight cases unchanged.
- `AtelierRefs/AtelierRefsTests/InboxArchiveImportTests.swift` — the JPEG builder deleted.
- `AtelierRefs/AtelierRefsTests/CollectionTargetsTests.swift` — three cases re-pointed at
  `BrowseCollectionTree.roots`; every assertion identical.

**Project**

- `AtelierRefs/AtelierRefs.xcodeproj/project.pbxproj` — `AtelierBrowse` on the `AtelierRefs`
  app target (`JA…0004` / `JA…0005`); `AtelierBrowse` (`JA…0006` / `JA…0007`), `AtelierCore`
  (`DA…0006` / `DA…0007`) and `AtelierCaptureTestSupport` (`IA…000A` / `IA…000B`) on
  `AtelierRefsTests`. Six new ids, all checked for collision before writing.

## Verification

Everything below was run on this tree.

| suite | before | after |
| --- | --- | --- |
| `AtelierCore` | 786 | **786** |
| `AtelierCapture` | 172 | **172** |
| `AtelierLibraryPaths` | 32 | **32** |
| `AtelierBrowse` | 181 | **182** |
| `AtelierArchive` | 82 | **82** |
| `AtelierIngestion` | 502 | **517** |
| `AtelierTokens` | 9 | **9** |
| `AtelierServer` | 62 | **62** |
| `AtelierRefsTests` (Mac) | 1633 | **1636** |

All passing. The Mac count is distinct test cases including 3 that skip by design
(`BakeoffSeedTests`, two `ShareMenuProbeTests`); the raw `xcodebuild` line count is higher
because parallel workers report some cases twice.

- `xcodebuild -list -project AtelierRefs/AtelierRefs.xcodeproj` — after each of the four
  `pbxproj` writes. Parsed every time.
- iOS package builds, `--sdk` as CI does, `--triple arm64-apple-ios26.0`: `AtelierCore`,
  `AtelierCapture`, `AtelierLibraryPaths`, `AtelierBrowse`, `AtelierArchive`,
  `AtelierTokens`, `AtelierIngestion` — all OK.
- `xcodebuild build -scheme AtelierRefsMobile -destination 'generic/platform=iOS Simulator'`
  — OK. `build-for-testing` on `platform=iOS Simulator,name=iPhone 17` — OK, so the phone
  app and the UI-test bundle still compile.
- `xcodebuild build -scheme AtelierRefs -destination 'platform=macOS'` — OK.
- `xcodebuild test … -only-testing:AtelierRefsTests` — `** TEST SUCCEEDED **`.

**The Mac app was launched**, since this phase changes its drain scheduler and its detail
formatting and no automated test opens a window. It opened one window titled "AtelierRefs
Dev" with 60 accessibility elements, and its log shows `starting server 127.0.0.1:47322` —
which `bootstrap()` reaches only AFTER `refreshFolders()`, `refreshSpaces()` and
`loadContents(of:)`, so the library opened and the sidebar's data loaded without throwing.
`activateInboxDrain` runs on the next line. No error line, and no drain report line — an
empty inbox now produces no `reportLines` at all, which is the new behaviour working.

**What was not verified: the pixels.** This session had no Screen Recording permission, so no
screenshot was captured and the accessibility tree would not yield element names. "The
sidebar drew" is inferred from the bootstrap ordering above, not seen.

## What is still NOT covered

- **The Mac's `report(_:)` and the phone's are still two four-line `switch`es.** The wording
  is shared; the level → `Logger` mapping is not, and is not tested on either side. It is
  four lines whose only failure mode is logging at the wrong level.
- **`skippedExhausted` still has no producer on the Mac**, by design — `.discardWhenIngested`
  quarantines instead — so the new line is exercised by `DrainReportTests` and by no running
  app on this platform. The phone's is a device case.
- **The integration test does not prove a torn read is impossible.** It proves the exclusion
  holds over the real types, and the control case proves the archive is identical when
  nothing races. Removing `exclusively` would not deterministically fail it: it would make
  the outcome depend on timing, which is the thing being prevented and not a thing a test can
  assert directly.
- **`MasonryLayout`'s solver is still the Mac's alone.** Only the clamps and the column-width
  arithmetic are shared. The frame solver exists because the marquee hit-tests offscreen
  cells; the phone has no marquee, so there is nothing to share it with.
- **`CollectionTargets.flatten`, `folderMoveTargets`, `routeOutlineDrop`, `canReparent` and
  `descendantIDs` stay on the Mac**, because the phone has no surface for any of them.
  `BrowseCollectionTree.flattened` returns tuples and the Mac needs `Identifiable` rows, so
  the two flattens still differ — same order, different shape.
- **`ThumbnailPipelineTests` and `ThumbnailWindowPrefetcherTests` flaked once** in a full run
  taken immediately after a clean build (14 cases, timing-sensitive decode tests, machine
  under I/O load); they passed alone and in every later full run. Not investigated, not
  caused by anything here, and worth a look by whoever next sees them fail.
- **The share extension** is P5 and untouched. **The UI tests, the app icon and the docs** are
  P6 and untouched.

## Migration notes

- **`AtelierRefs` links `AtelierBrowse`.** The Mac app now depends on a package it did not
  before. The package already builds for macOS 26 and has no new transitive dependency.
- **`AtelierRefsTests` links `AtelierBrowse`, `AtelierCore` and `AtelierCaptureTestSupport`.**
  `AtelierCore` is not new to the bundle's SOURCE — it is new to its declaration, and it is
  required: see "What the `pbxproj` edit found". A test target that imports a package should
  declare it.
- **Deleted types.** `DetailFormat` (use `BrowseFormat.savedDate` / `.platform`),
  `CollectionTargets.galleryRoots` (use `BrowseCollectionTree.roots`),
  `CollectionTargets.byManualOrder` (use `BrowseCollectionTree.byManualOrder`),
  `MasonryLayout.minAspect` / `.maxAspect` / `.columnWidth` (use `MasonryColumns`).
  `CollectionTargets.destinationTree` and `aspect(for:)` keep their names as one-line
  forwards. `DestinationTreeNode` is a `typealias` for `BrowseCollectionNode` — same three
  members, same `Identifiable` conformance, and `let` rather than `var` (nothing mutated one).
- **The trim rule changed on the Mac.** `SourceSection.author` trimmed `.whitespaces` and now
  trims `.whitespacesAndNewlines`. Who this affects: anyone whose stored `authorName` or
  `authorHandle` ends in a newline or carriage return — a page extractor with a wrapped
  byline is the realistic source. Their Author row loses a trailing blank line, and a value
  that was ONLY whitespace-and-newlines now correctly reads as absent, so the row is omitted
  rather than drawn empty. No data changes; this is a read-time rule.
- **Log output changed on both platforms.** The three existing lines are byte-identical. A
  fourth is possible on the phone (`N capture(s) out of attempts; kept for export`), and all
  four now go out with `privacy: .public` — they contain counts and no user data, and were
  previously interpolated with `os`'s default privacy for their integer arguments.
