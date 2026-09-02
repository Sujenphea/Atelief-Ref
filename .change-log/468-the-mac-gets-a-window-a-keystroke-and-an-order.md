# 468 — the Mac gets a window, a keystroke and an order

Three claims about the Mac app were true only by inspection: that it launches at all
against a library on disk, that ⌘, still opens a Settings window, and that the sidebar
draws collections in the order `BrowseCollectionTree` computes. The first two are
statements about a **process** and a **window server**, which no `swift test` can make.
The third has a unit test for the ordering (`CollectionTargetsTests`) and nothing at all
for the rendering of it — the gap between "the array is right" and "the sidebar is right".

[467](467-four-builders-and-the-numbers-that-collided.md) established the ground truth
this phase was built on, and it replaced two bullets 099 had written before 098 landed.

## What 099's brief got wrong, and 467 corrected

**The seeder's argument.** 099 invented `-ui-test-seed <name>`. 098 had already shipped
`-seed-fixture-library` with three guards and a `Names` enum. A second spelling for one
job is the duplication this plan exists to remove, so the Mac's seeder is 098's shape
with the Mac's contents — the argument name, the three guards and the `Names` discipline
are shared; the fixture is not, because a Space and a saved search have no phone surface.

**The identifiers.** 099 did not mention them. The Mac target had **zero**
`accessibilityIdentifier` calls, so a UI test could only match on visible text — and the
visible text is ambiguous the moment two surfaces name the same thing. The seeded
library's "Textures" is on a Home card *and* on a sidebar row; a test matching the string
would have passed while asserting the wrong element. Adding the four names the flows need
was most of this phase.

## The three guards on a seeder that wipes

Seeding wipes a library, and a library is the thing this app exists to not lose. The
seeder runs only when all three hold: `#if DEBUG`, so it is not in a Release binary at
all; the launch argument is present; and **the root is an override**
(`LibraryLocation.overrideValue() != nil`) — it throws rather than seeding otherwise. The
third is what makes "wipe first" safe: the only root it can ever wipe is one a test
pointed it at. It wipes rather than merges so a re-run asserts against the same library
as the first run.

The fixture: three collections (Textures, Concrete nested under it, Posters), four assets
spread so every collection has a non-zero count, one Space, one saved search. The saved
search is seeded and **unasserted on purpose** — P4 inherits the fixture rather than
growing it.

## Four identifiers, all on leaves

098's rule is a demonstrated bug class, not a style note: on the phone, `export.sent` on
an enclosing `VStack` renamed everything inside it and neither child could be found. So
every name here lands on the element that *is* the accessibility leaf — a SwiftUI
`Button` whose label SwiftUI has already merged, a leaf `Text`, an `NSTextField`, an
`NSButton`. **No `.accessibilityElement(children:)` was changed to make a flow easier**;
those calls are correct for VoiceOver and were left alone.

`home.collection.<name>`, `sidebar.collection.<name>`, the same `+ ".disclosure"`, and
`settings.capture.endpoint`. Nothing else was added: an identifier no test reads is a
name to keep in sync for no reader. The Spaces list is the **same widget** as the
collections tree, so `SidebarCell` takes the prefix per cell rather than from a constant
— and the Spaces coordinator deliberately passes none, with a comment naming P6 as the
phase that will want `sidebar.space.`.

One trap, handled: the prefix is re-stamped in `configure(name:expandable:expanded:)`,
not set once at init. `NSOutlineView` recycles cells, and a row wearing a previous
occupant's identifier is worse than a row with none.

## Three failures the flows hit, and none of them fixed with a sleep

- **The runner was SIGKILLed before it connected.** Every other app stage in `verify.sh`
  passes `CODE_SIGNING_ALLOWED=NO`. A UI-test bundle ships a *runner* app whose executable
  is `lipo`-extracted from Xcode's `XCTRunner.app`, and an unsigned arm64 binary is killed
  by the kernel: *"Early unexpected exit … Test crashed with signal kill before
  establishing connection"*, with no compile error and no test output to explain it. The
  UI stage signs **ad-hoc** (`CODE_SIGN_IDENTITY=-`) — the smallest signature that
  launches, needing no keychain identity and no profile, and it still applies the app's
  entitlements, so the app under test is sandboxed exactly as it ships. That in turn is
  why `ATELIER_LIBRARY_ROOT` is a **relative** value: it resolves inside the container,
  and an absolute path is not writable from there.
- **⌘, was typed at nothing.** A key event goes to the frontmost application, not to
  whatever `XCUIApplication` a test is holding, and a cold first launch in a batch can
  finish behind the runner. `app.activate()` states that precondition. It is not a
  settling delay.
- **A click selected the row and never pressed the chevron.** A click into an *inactive*
  AppKit window is consumed by activating it unless the view under the pointer accepts
  the first mouse — `NSTableView` does, `NSButton` does not. A failing run's hierarchy
  showed exactly that: row selected, glyph still "Expand". `activate()` again.

There is no `sleep` in the suite. Waits are `waitForExistence(timeout:)`.

## The assertions are narrow on purpose

The launch flow asserts a **named** card, not a count: an empty gallery and a gallery of
the wrong library both look like a number. The ⌘, flow remembers the launch window's
identifier and asks the window that is *not* it for a control only Settings draws — a
window count alone would pass if ⌘, opened a second main window, and a title match would
pin a string macOS composes out of the display name and a localised word. The order flow
reads **identifiers, not values**, because the row's label is an `NSTextField` whose
accessibility value is its string, which would also match the Home card.

And the order asserted is not the alphabet: Unsorted is pinned first, then creation order
— Textures, then Posters. **An alphabetical sidebar would put Posters first and pass every
existing unit test.** The disclosure click is the suite's only interaction, and it is
there because a collapsed child is not merely invisible; it is not in the accessibility
hierarchy at all.

## The fourteenth stage

`App target (UI)` is a **second app stage**, not a second `-only-testing` on the first. A
UI failure and a unit failure have nothing to do with each other — one means a window, a
keystroke or an identifier moved, the other means a value is wrong — and one summary line
covering both would tell a reader neither. It is a plain `run_stage`: a UI failure is a
real failure, not a `WARN_STATUS=2` warning. Full mode only; `fast` stays in the seconds.

`.github/workflows/ci.yml` is untouched (decision 9C). 098's UI gate is CI-only and CI
has not run since 2026-08-06, so `verify.sh` remains the only gate that runs.

`./scripts/verify.sh full`, after the disclosure fix:

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

Exit 0. Fourteen stages — `App target (UI)` is this phase's. `⚠ Extension` is the stale
Instagram drift fixture, non-fatal since [464](464-the-gate-tells-its-two-arms-apart.md).

It took three full runs to get this, and the two that failed are written up above rather
than dropped: the first on the thumbnail suites (not this phase's, still open), the third
on this suite's own disclosure flow (this phase's, diagnosed and fixed).

## The disclosure flow flaked on the gate, and `activate()` was why

The third gate run failed this suite's own third flow:

```
SmokeUITests.swift:156: XCTAssertTrue failed
  — disclosing “Textures” did not reveal “Concrete”
```

The bare `app.activate()` above that click was written to fix exactly this, and it was
not enough. **`activate()` is a request, not a transition.** It returns before the window
server has made the app frontmost, so the click could still land into an inactive window
and be spent activating it — which is the failure the call was added to prevent, merely
made rarer.

Two helpers replace it, and neither is a sleep:

- **`bringToFront(_:)`** calls `activate()` and then waits on `.runningForeground`. That
  is the state change itself, so it is a signal; the flow proceeds when the precondition
  is *true*, not when it has probably become true. Both `activate()` sites use it.
- **`waitForHittable(_:timeout:)`** polls `isHittable`, the one XCUITest predicate with
  no `waitForExistence` of its own. An element can exist, and be the right element, and
  still refuse a click because something is over it or its window is not key. The first
  version of this flow activated, clicked, and trusted.

Verified by **four consecutive runs of the suite, all green** — one pass does not
distinguish a fix from a lucky draw. The source comments that described the old mechanism
were corrected rather than left to mislead the next reader.

## The unit stage failed once, and it is not this phase's doing

The first `verify.sh full` after this work came back `✗ App target` with **42 failure
entries across 15 tests** — the whole of `ThumbnailPipelineTests` and
`ThumbnailWindowPrefetcherTests`. The UI stage passed in that same run.

What was established, by running rather than reasoning:

- **The same code passed on a re-run** of `-only-testing:AtelierRefsTests`, with nothing
  changed in between.
- **`concurrentRequestsCoalesceWithAFastDecode` passes 3/3 in isolation.**
- **This is the second sighting.** [465](465-the-corpus-goes-resident.md) records the
  same two suites failing on its own second run, and its third was clean.
- The failing set includes `exactHitWins` and `fallsBackToLargerBucket` — plain cache
  lookups with no concurrency in them — so it is not a race in any single test.
- The invariant the loudest test guards is **not** broken: `join` does re-check the cache
  under the lock (`ThumbnailPipeline.swift`), which is the fix that test exists to pin.

What was **not** established: the mechanism. The log records one line per failing test
(`failed … (15.110 seconds)`) and emits **no assertion text, no recorded issue and no
timeout**, so nothing here says which `#expect` gave way or whether one did. Two
hypotheses were entertained and neither survives as stated: system starvation (the
passing re-run has an identical duration profile, so the durations in that log are not
per-test elapsed and prove nothing), and the suites' `.timeLimit(.minutes(1))` (the
failing test is recorded at 15 seconds, well inside it).

One mechanism worth the next look, offered as a hypothesis and not a finding: the cache
is an `NSCache`, which evicts on its own schedule under memory pressure, and most of the
failing tests assert on cache contents. A parallel `xcodebuild test` is exactly the
condition that would trigger that, and it would fail many cache tests at once while
leaving the pipeline's logic correct — which is the shape of what happened.

**This is not P2's to fix and P2 did not fix it.** It is 099 · 11A's unfinished business:
P1's brief named specific sleeps in these files and replaced them, and these suites were
not among the cases it was pointed at. It is recorded here because it will block phases
that have nothing to do with thumbnails until someone takes it, and because a gate that
fails once in two runs is on its way to being a gate nobody reads — the same road
[464](464-the-gate-tells-its-two-arms-apart.md) was written to get off.

## What is still NOT covered

**This phase was finished by hand.** The agent that wrote it stalled at the verification
step with everything written and nothing committed; the code below the stall — the gate
run, this entry, the commit — was done by the session. The work was reviewed rather than
taken on trust, but it was not re-derived.

The suite is three flows and asserts nothing about layout — no frame, colour or size is
read, by design. `AtelierRefs` has **no shared scheme** (only `AtelierRefsMobile` and
`AtelierRefsShare` do), so the test action that picks this target up is Xcode's
auto-created one; it works, and it is not checked in, which means it is not pinned
against a future project edit. The UI stage does not share build products with the two
stages that sign differently, so it pays a full app build of its own.

Nothing here drives ⌘K or the palette — P5 and P6 own those flows. The saved search is
seeded and unasserted. The Spaces tree has no identifiers. And the seeder's own three
guards have no test: they are argued in a doc comment and exercised only by the suite
running at all.
