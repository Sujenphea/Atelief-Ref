# 098 — iOS companion: the completion pass (plan)

> What is left between the companion as it stands on `feat/ios-ingest` (2026-09-02,
> HEAD `bb841bd`) and a v1 that is *finished* rather than *landed*. Planned against the
> code, not the earlier docs: every claim below was read at the file cited today.
>
> **State at the time of writing.** Every slice [092](092-ios-companion-plan.md) named is
> built and has run — S0–S4a on the host, S4b–S6 on a simulator and, for the share sheet
> and AirDrop, on a device. [452](../.change-log/452-the-factories-were-never-the-appkit-part.md)–[455](../.change-log/455-what-the-move-found.md)
> then gave the phone its own drain, so a share appears in the phone's grid without a
> Mac. The capture-to-library loop is closed on both ends.
>
> What is NOT here: tier 3. [096](096-tier3-plan.md) is gated on T0, and T0 is a device
> session ([097](097-tier3-t0-protocol.md)) — thirty popup openings per platform on a
> phone in someone's hand. Nothing an agent does today moves it, and 096 says in its own
> words not to start T1 before it is answered. This plan does not.

## What "complete" means for this pass

The companion has a habit, recorded in every changelog since 454, of closing with a
paragraph titled *what is still NOT covered*. This pass is that paragraph, worked through:
the seams the last six changelogs named and left, plus the things a person installing
the app notices before they read any of them — its name, its icon, the flash before its
first frame.

Six phases. Each is one agent, one changelog, one commit, run in order because four of
them touch files the next one reads. None of them needs a device or a decision the user
has not already made; the ones that do are listed at the end, unclaimed.

## The review, and what was decided

Reviewed under the same four headings every pass here uses. Each finding carries its
options, the recommendation, and — because this pass runs unattended — the decision
taken and the phase that carries it. Where the honest recommendation was *do nothing*,
it says so and stops.

### Architecture

**1. Two drain cadences, two copies of `report()`.** The Mac's
`AtelierRefs/InboxDrainScheduler.swift` and the phone's `InboxDrainPolicy` restate one
policy — launch, every activation, one pass at a time — in two files with no shared
line, and their `report(_:)` bodies are the same four log lines twice
(`InboxDrainScheduler.swift:143` on the Mac, `AtelierRefsMobile/InboxDrainScheduler.swift:112`
on the phone). 455 named it and left it: *"The two policies are still stated twice, in
two files, and nothing but a reader keeps them in agreement."*

- **A — the Mac adopts `InboxDrainPolicy`.** The Mac app links `AtelierBrowse`; its
  scheduler becomes the same adapter shape the phone has, over
  `NSApplication.didBecomeActiveNotification` instead of `ScenePhase`. Effort ~half a
  day; risk is the `project.pbxproj` edit (a product dependency and a build file on two
  targets, the shape 448 and 454 already wrote); the Mac's 243-line scheduler suite has to
  be re-pointed at the policy. Maintenance: one policy, one suite.
- **B — share only the vocabulary.** `DrainSummary` grows a pure `reportLines` in
  `AtelierIngestion` — what to log and at what level — tested there; both apps log it.
  Two hours, no pbxproj, and the cadence stays duplicated.
- **C — do nothing.** The Mac's copy has its own tests and has not drifted.

Recommendation: **B, then A**, as one phase — B is the part with no risk and it stands on
its own if A has to stop. This is the finding the DRY preference is for: the duplication
is not two similar things, it is one policy written twice by two slices a fortnight
apart. **Phase 6.**

**2. `LibraryLocation` reads the wrong bundle in a test runner.**
`appGroupIdentifier(rawValue:)` defaults to `Bundle.main`
(`LibraryLocation.swift:117`), and in a UI test `Bundle.main` is `XCTRunner.app`, not the
`.xctest` bundle whose Info.plist carries the key. That is why `Tier2ShareUITests` fails
before it reaches Safari (455). 455 called it *"a decision about `LibraryLocation`'s
bundle lookup that belongs to whoever owns that file."*

- **A — a `bundle:` parameter, defaulted to `.main`.** One overload; the test passes
  `Bundle(for: Self.self)`. Testable on the host with a bundle built in a temp directory.
- **B — the test reads its own plist and passes a root in.** Works, and leaves the
  seam's default silently wrong for the next runner.
- **C — do nothing.** The test stays unrunnable.

Recommendation: **A.** Explicit over clever; the default stays exactly what it was.
**Phase 2.**

**3. `Tier2ShareUITests` was broken by 454, and nobody could see it.** Its
`inboxRecords()` reads `pendingRecordURLs()` only (`Tier2ShareUITests.swift:178`). Since
454 the app drains at launch, and `pendingCount()` launches the app — so by the time the
test looks for the record that landed, the drain has moved it to `inbox/ingested/`, and
`landed.count == 1` fails by construction. The test could not run (finding 2), so the
regression is latent, not observed.

- **A — read the union**, pending plus ingested, exactly as `InboxArchive.pendingRecords(in:)`
  does — `InboxLayout` already exposes both enumerations.
- **B — suppress the launch drain under a test flag.** A behaviour switch in the product
  for one test.
- **C — do nothing.**

Recommendation: **A. Phase 2**, beside finding 2, since the two are what stand between
the test and a run.

**4. CI never compiles the UI test target.** `ios-app` runs `xcodebuild build`
(`ci.yml:154`), which builds the app and not its test bundle. `AtelierRefsMobileUITests`
is 700 lines with the same standing 439 gave the share extension — no test host, so the
compile *is* the gate — and it has none.

- **A — `build-for-testing`** on the `AtelierRefsMobile` scheme, whose Test action already
  lists the UI bundle. One flag.
- **B — a third matrix row** naming the test target. More rows, same compile.
- **C — do nothing.**

Recommendation: **A. Phase 2.** The agent has to verify that a UI test bundle carrying an
entitlements file builds under `CODE_SIGNING_ALLOWED=NO`; if it does not, the row is
still worth having with signing allowed on a runner that has a team.

### Code quality and completeness

**5. The app has no name, no icon, a blue accent and a black launch.** There is no
`INFOPLIST_KEY_CFBundleDisplayName` on `AtelierRefsMobile`, so the home screen and the
share sheet row read *AtelierRefsMobile* (the Tier2 test's header records learning that
the hard way). `Assets.xcassets/AppIcon.appiconset` has three slots and no image, while
the Mac's catalog has a 1024 px `icon_512@2x.png`. `AccentColor` is empty, so every
UIKit surface the app does not draw — the export's `UIActivityViewController` above all —
tints system blue in a monochrome app (093 § 4). And `INFOPLIST_KEY_UILaunchScreen_Generation`
gives a launch screen on `systemBackground`, which under `UIUserInterfaceStyle = Dark` is
`#000000`, one frame before `canvasOuter` `#131313` paints.

- **A — all four.** Display name `AtelierRefs` on both configurations (one bundle id, so
  the two builds cannot coexist and a *Dev* suffix would name nothing); the Mac's 1024 as
  the universal iOS icon; `AccentColor` = `inkPrimary`; a `UILaunchScreen` dictionary in
  the target's real Info.plist with `UIColorName` on a `LaunchBackground` colour set at
  `canvasOuter`, replacing the generation key. Verified by reading the keys back out of
  the built product, which 401 established is the only check that means anything here.
- **B — name and icon only.**
- **C — do nothing.** 093 § 7 lists icon and launch screen as things it does not design.

Recommendation: **A. Phase 1.** 093 declined to *design* them; it did not decide that a
share sheet should say *AtelierRefsMobile*. Reusing the Mac's icon is the choice that
adds no design surface — a phone-specific mark is the user's call, later.

**6. The detail screen reads the whole collection to show one item, and the feed reads
the collection twice.** `ItemScreen` does `store.items(in:).first { … }`
(`ContentView.swift:327`): a full P14 join, filtered in Swift, to find one row. And
`CollectionFeed.load` reads `collection(id:)` and `items(in:)` in parallel
(`LibraryStore.swift:224`), while `BrowseLibrary.items(in:)` reads the collection *again*
for its `sortMode` (`BrowseLibrary.swift:88`). 450 measured the collection read at 0.29 s
for 5,000 items, so neither is slow today; both are the shape that becomes slow.

- **A — two reads in the package.** `BrowseLibrary.feed(for:)` returns the collection,
  its items and its subcollections from one collection read, with the parallelism inside
  the package where `swift test` can assert it; `BrowseLibrary.item(_:in:)` reads one
  membership over a new `AppServices.collectionItem(id:in:includeArchived:)` in
  `AtelierCore` — the same joins as `collectionItems`, one row.
- **B — the single-item read only.**
- **C — do nothing**, on 450's numbers.

Recommendation: **A. Phase 3.** The item read is the one a reviewer would flag; the feed
read is the DRY half of the same finding, and moving the parallel read into the package
takes app-target logic somewhere tests reach.

**7. Export folders accumulate in Caches, and the export's statics are untested.**
`CaptureExport.write` removes a folder of the *same name* before writing
(`CaptureExport.swift:214`) — a name that carries the minute — so every export at a
different minute leaves its predecessor behind. A copy of the inbox per send, for the life
of the device, or until the system purges Caches on its own schedule. `folderName(_:)`
and `write(...)` are `nonisolated static` in the app target, where nothing runs them.

- **A — `InboxArchive.writeExport(records:layout:under:appVersion:now:)`** in
  `AtelierArchive`: clears every sibling export folder under the parent, creates the
  timestamped one, writes, and returns the folder plus the exported ids. Tested with a
  temp parent holding stale siblings. `CaptureExport` calls it.
- **B — clear stale siblings in the app**, untested.
- **C — rely on the purge.**

Recommendation: **A. Phase 4.** The cleanup is safe because an export runs under
`InboxExclusion` with the send control disabled on `.working`, and the previous folder's
share sheet is modal — nothing is reading a stale folder when the next one starts.

**8. The failure vocabulary is app-target logic.** `LibraryStore.message(for:)`
(`LibraryStore.swift:186`) is the mapping 093 § 7 asked to exist — a typed App Group
failure rendered as a sentence — and it is untested for the same reason everything in that
target is. Small, and the reason to move it is the one 455 gave for the policy.

- **A — `BrowseFailure.message(for:)` in `AtelierBrowse`**, tested over every case it
  distinguishes.
- **B — leave it.**

Recommendation: **A. Phase 4**, beside finding 7, which moves the export's sentences the
same way.

### Tests

Findings 2, 3 and 4 are the test findings; 6, 7, 8 and 10 each carry their own coverage.
One more, stated so it is not implied: **`AtelierRefsMobile` still has no unit-test
target**, and this plan does not add one, for 454's reason — the pbxproj cost of a native
test target against the size of what would move into it, when the package charter already
takes every non-view decision.

### Performance

**9. Nothing new in the database path.** 450 answered the paging question with a
measurement, `collectionItems` is one joined read, and the thumbnail resolvers are
unstat'ed by design. Finding 6 is the only read-side shape worth changing.

**10. The thumbnail cache decodes twice and never stops.** `ThumbnailCache.image(at:)`
(`ThumbnailImage.swift:75`) has no in-flight coalescing — two views asking for one key
at once decode it twice — and its `Task.detached` inherits no cancellation, so a
flick-scroll decodes every tile that passed, after it has passed. Small JPEGs, so this is
milliseconds per tile rather than a stall; it is also the kind of work a phone should not
do while the user's thumb is still moving.

- **A — a generic `DecodeCache` in `AtelierBrowse`**: keyed, cost-bounded, coalescing,
  cancellation-aware, decode injected; tested with a fake decoder that counts calls and
  parks on a gate. The `CGImageSource` decode stays in the app.
- **B — a cancellation check only**, in the app, untested.
- **C — do nothing.**

Recommendation: **A. Phase 5.** The 96 MB budget and the count limit move with it and
keep their arguments.

**11. The concurrency limit of 2 is unmeasured.** `MobileIngest.maxConcurrent`. Still a
device measurement, still not this pass's — see the end.

---

## P1 — the app as a thing on a home screen

Finding 5. `project.pbxproj` gains `INFOPLIST_KEY_CFBundleDisplayName = AtelierRefs` on
both `AtelierRefsMobile` configurations and loses
`INFOPLIST_KEY_UILaunchScreen_Generation`; `AtelierRefsMobile/Info.plist` gains the
`UILaunchScreen` dictionary; the asset catalog gains the icon, the accent and the launch
colour. The share extension's display name stays `AtelierRefsShare` — the share sheet
labels the row by the host app, so it is the host's name that shows.

**Don't** touch the Mac target, and don't invent an iOS icon: the Mac's 1024 is the icon.

**Verify:** `xcodebuild -list` parses after every pbxproj write; the app builds on Debug
and Release; `CFBundleDisplayName`, `UILaunchScreen.UIColorName` and the icon file are
read out of the built product; the Tier2 test's `BEGINSWITH 'AtelierRefs'` still matches.

## P2 — the test that could not run, and the CI row that never compiled it

Findings 2, 3, 4. `LibraryLocation.appGroupIdentifier(bundle:)` and
`defaultRoot(bundle:)` with `.main` defaults; tests over a bundle written to a temp
directory (present, absent, blank). `Tier2ShareUITests` passes its own bundle and reads
pending ∪ ingested. `ci.yml`'s `ios-app` row runs `build-for-testing` for the
`AtelierRefsMobile` scheme so the UI bundle compiles.

**Don't** change what `Bundle.main` resolves to for the app and the extension — the
default is the whole of their behaviour.

**Verify:** `AtelierLibraryPaths` tests; `xcodebuild build-for-testing` for the mobile
scheme locally, signed and with `CODE_SIGNING_ALLOWED=NO`; the extension and app still
build. The test itself still needs the App ID step listed at the end.

## P3 — the feed reads once, the item reads one

Finding 6. `AppServices.collectionItem(id:in:includeArchived:)` in `AtelierCore` with
tests (present, absent, archived-hidden, wrong collection);
`BrowseLibrary.feed(for:)` returning a `BrowseFeed` and `BrowseLibrary.item(_:in:)`,
with tests; `CollectionFeed.load` and `ItemScreen` call them.

**Verify:** `AtelierCore` and `AtelierBrowse` suites; the app builds; `BrowseScaleTests`'
ceilings hold.

## P4 — the folder, and the sentences

Findings 7, 8. `InboxArchive.writeExport(...)` in `AtelierArchive`, tested for the stale
sibling, the fresh folder, the name, and the exported ids; `BrowseFailure` in
`AtelierBrowse`, tested per case. `CaptureExport` and `LibraryStore` shrink to callers.

**Verify:** `AtelierArchive` and `AtelierBrowse` suites; the app builds;
`InboxArchiveImportTests` on the Mac still passes — it is the only test that runs both
ends of the export.

## P5 — one decode per key, none after the scroll has moved on

Finding 10. `DecodeCache<Value: AnyObject>` in `AtelierBrowse` — `NSCache` inside, the
byte budget and count limit carried over with their arguments, coalescing by key,
cancellation observed before a decode starts. `ThumbnailCache` becomes the app's
instantiation over `CGImageSourceCreateThumbnailAtIndex`.

**Verify:** the `AtelierBrowse` suite, with the coalescing and cancellation cases driven
by a parked fake decoder rather than by timing; the app builds.

## P6 — one drain policy

Finding 1, in the order the recommendation gives. `DrainSummary.reportLines` in
`AtelierIngestion`, tested, and both apps' `report(_:)` reduced to logging it. Then, if
the Mac's scheduler suite can be re-pointed at `InboxDrainPolicy` without weakening an
assertion: the Mac app links `AtelierBrowse` and its scheduler becomes an adapter. If it
cannot, stop after the first half and say so in the changelog.

**Verify:** `AtelierIngestion`, `AtelierBrowse` and `AtelierRefsTests`; both apps build;
`xcodebuild -list` after every pbxproj write.

---

## Left to the user, and blocking nothing here

- **T0** ([097](097-tier3-t0-protocol.md)) — the focal-post session. Tier 3 waits on it.
- **`sujenphea.AtelierRefsMobileUITests` as an App ID with App Groups** (446, 097). P2
  makes the test correct; this is what makes it run signed.
- **`MobileIngest.maxConcurrent`** — a drain of a real backlog on a device, watched.
- **093 open question 1** — one write on the phone, *move to collection*. A product call.
- **093 open question 2** — `successDismissDelay`, set once on a device.
- **App Store presence** — a privacy manifest, version numbers, screenshots. 093 § 7
  excluded it and this pass does too.

## Out of scope, named so it is not mistaken for this

The Mac app's backlog — the ⌘K switcher, the floating palette, a Mac Safari extension,
the competitor importers, the Instagram export backfill, the RedNote sweep, smart
collections, the search and Spaces and detail lists, the color filter's second mode,
multi-library, undo-of-delete, the one code `TODO` in `twitter.js`, and the deferred
capture work — is a different product surface and is not touched by any phase above.
