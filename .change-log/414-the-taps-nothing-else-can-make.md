# 414 — the taps nothing else can make

[409](409-the-rhythm-that-decomposed.md) and [411](411-recognised-by-their-contents.md)
shipped a phone UI whose claims were verified two ways: by argument, and by screenshots
taken with the sheet forced open by a temporary edit. Both are fine as far as they go. What
neither could reach is the gesture — whether the navigation TITLE is actually a control,
whether a parent row expands, whether choosing a collection retitles the grid, whether a
tile pushes its detail. Those need a finger.

`AtelierRefsMobileUITests` is the target that supplies one. Four tests, all passing on
`iPhone 17 Pro / iOS 26.5`.

## What it is not

Not a second home for logic tests. A UI test is the slowest and flakiest kind there is; the
only reason to accept that cost is that a tap cannot be simulated any other way. The
ordering, the tree, the masonry decomposition and the cover fallback stay in `swift test`
where they run in milliseconds and need no simulator.

So the suite is deliberately four tests long, and each one is a claim from
[093](../.docs/093-ios-visual-design.md) § 2 that has a gesture in it:

| test | the claim |
|---|---|
| `testTitleTapPresentsTheCollectionTree` | *"the title IS the switcher"* |
| `testParentRowExpandsToItsChildren` | a subfolder is reachable, and the outline still indents with a 36pt square in the row |
| `testChoosingACollectionRetitlesTheGrid` | picking a collection swaps the root, title and items together |
| `testTileOpensTheItemDetail` | *"item detail pushes onto the same stack"*, with the three 041 sections in the Mac's order |

## The fixture problem, and why the app seeds itself

A UI test runs in its own process with its own container. It cannot write into the app's.
And browse is read-only by design (091 · D1) — there is no verb the UI could be driven to
that would make content. So a UI test against a fresh install would be a test of the empty
state, which is not what any of the four claims are about.

Something inside the app has to write the fixture. `FixtureLibrary` is that, and it is
guarded three ways, because seeding writes to a library and a library is someone's
collection of things they cannot get back:

1. `#if DEBUG` — not in a Release build at all.
2. `-seed-fixture-library` has to be on the command line.
3. **The root must be an override.** With no `-library-root` / `ATELIER_LIBRARY_ROOT`, it
   throws rather than touching the default root. That third guard is what makes "wipe the
   root first" safe — the only root it can ever delete is a throwaway one a test named.

It wipes rather than merges so a re-run asserts against the same library as the first run.
A UI test that passes only on a clean simulator fails on someone else's machine at the
worst possible moment.

The precedent for a launch-argument seam in this app is two files over:
`-atelier-log-tile-bodies` (`MasonryGridView.swift:86`) exists to make the laziness of the
column stacks observable from outside, and the Mac has a whole `Debug/` folder of the same
kind. This is that pattern with a stricter guard.

The fixture is shaped to be worth asserting against: `Textures` with two children (one with
pictures, one deliberately empty), `Posters` with an **explicit cover that is not its newest
member**, `Type` empty, `Swatches` holding only a colour. That is one collection per branch
of 410's cover rule, so the screenshot attached by the first test is a picture of the whole
rule at once.

## Three things the run found that reading could not

**The `Details` section is conditional.** It holds the Mac's editable surface and is omitted
when there is nothing in it (`ItemDetailScreen.swift:109`), so a freshly captured asset has
two sections, not three, and the first version of the detail test failed asserting
otherwise. The app is right and the test was wrong. The fixture now puts a **note** — not a
name — on one item: a name would replace that tile's accessibility label, which is exactly
how the test finds a known tile to tap.

**An outline row publishes two elements under the same label**, the cell and the button
inside it, so `app.buttons["Textures"].tap()` throws on ambiguity rather than tapping. The
fix is `.firstMatch`, and it is only obviously the fix once you have read the tree.

**A tile is a `Button` labelled by its provenance title**, which is what lets a test tap a
KNOWN picture instead of "whichever one is first". That came out of dumping the real
accessibility hierarchy rather than assuming one; the assumption in the first draft
(matching on `identifier`) matched nothing.

## What is still not asserted, on purpose

Whether a row shows a cover or a folder. A thumbnail has no accessibility identity, and
giving one to a decorative image would put a VoiceOver stop on something that says nothing
the row's name does not — the switcher went out of its way to avoid that
(`CollectionSwitcher.swift`, `.accessibilityHidden(true)`). So the picture-vs-folder
distinction is carried by screenshot attachments, for a human, deliberately rather than by
omission. `switcher-nested-rows` is the one image that did not exist before this target: a
nested row with a picture beside a nested row without, which is where an indentation eaten
by a 36pt square would show. It is not eaten.

## The project edit

`objectVersion = 77` with file-system-synchronized groups, so the target is a synchronized
root group, three empty build phases, a product reference, two configurations, a
configuration list, a dependency on the app it drives, and entries in the project's
`targets` / `TargetAttributes`. Written by hand, in the same style as the mobile target
before it (401), and `plutil -lint`-clean.

One setting differs from every other target here: `SWIFT_DEFAULT_ACTOR_ISOLATION =
nonisolated`. `XCTestCase`'s initialisers and `setUp()` are nonisolated, and a subclass
compiled with MainActor-by-default cannot override them — the target does not build
otherwise. The unit-test target keeps `MainActor` because swift-testing's `@Test` functions
override nothing.

## Files

    AtelierRefs/AtelierRefsMobileUITests/       4 tests + the fixture helpers
      SwitcherUITests.swift

    AtelierRefs/AtelierRefsMobile/Debug/        the DEBUG-only, argument-gated,
      FixtureLibrary.swift                      override-root-only seeder

    AtelierRefs/AtelierRefsMobile/              seeds before the library is opened, so no
      LibraryStore.swift                        pool is left holding a deleted file

    AtelierRefs/AtelierRefs.xcodeproj/          the new UI-testing target
      project.pbxproj

## Migration notes

Nothing changes for a Release build: `FixtureLibrary` is not compiled into one, and the
seeding call in `LibraryStore.bootstrap()` is inside the same `#if DEBUG`.

**Running them:** `xcodebuild test -scheme AtelierRefsMobile -destination 'id=<simulator>'`.
They are NOT in `scripts/verify.sh` or CI yet — a simulator boot is a different order of
cost from the jobs there now, and adding it is a decision about CI minutes rather than about
this target.
