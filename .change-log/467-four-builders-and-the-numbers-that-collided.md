# 467 — four builders, and the numbers that collided

099 · P7. Two sessions had been writing on one branch for a week: 098 closed the iOS
companion on `feat/ios-ingest` (32 commits past the fork), and 099 built the Mac's
foundations on `feat/mac-backlog` (five). This phase is where they meet — the rebase, the
changelog numbers both sessions allocated from the same counter, and decision **5A**, the
one item 099 deliberately left until 098 · P4 had landed because it was P4's file.

The phase was scheduled after P6 and the user moved it to now (issue 19A): 098 finished,
and every phase from here would otherwise have been written against a tree that was 32
commits stale.

## The rebase — five commits, three conflicts

`git rebase feat/ios-ingest` at `395e471`. Two of the five commits replayed clean
(`b24c010` → `e89069d`, the drift gate; `622f163` → `e58b857`, the 099 doc). Three files
conflicted, and one more is worth naming because it did NOT.

**`AtelierArchive/Package.swift` — both sides, both kept.** 098 · P1 added
`AtelierCaptureTestSupport` to the test target's dependencies (the shared JPEG builder);
099 · P0 added `resources: [.copy("Fixtures")]` to the same target for 12A. They are
different arguments of the same `.testTarget` call and git could not see that. Kept both,
in that order.

**`AtelierCore/…/AppServices.swift` — a 2,000-line conflict with one line of content.**
099 · P0 split a 4,200-line file into nine; 098 · `c12a01a` added one function,
`collectionItem(in:id:includeArchived:)`, in the middle of the region that moved. Git
presented the whole moved region as one hunk. Resolved by taking the split file verbatim
and **hand-carrying the new function, with its whole doc comment, into
`AppServices+Collections.swift`**, directly after `collectionItems(in:sort:includeArchived:)`
— the function it is a primary-key variant of, which is where the split would have put it
had both existed at once. Nothing was dropped and nothing was rewritten: `git show
c12a01a` and the function as it now stands are the same 47 lines.

That one was the reason to check `AssetReadSurfaceTests.swift`, which auto-merged and
could easily have merged into something wrong. 098 added `"collectionItem"` to the pinned
read surface; 099 · P0 changed the scan from "read `AppServices.swift`" to "read
`AppServices*.swift`, discovered by directory listing". Both landed, and they need each
other: without P0's change the canary would have scanned a tenth of the surface, and
without 098's row the new function would have failed the pin. The merge is correct as it
stands and the suite proves it.

**`AtelierRefsMobile/LibraryStore.swift` — the file our change was in had been deleted.**
098 · P3 moved the phone's whole store into `AtelierBrowse/BrowseStore.swift` and its
error table into `AtelierBrowse/BrowseFailure.swift`, leaving a 55-line file holding a
`typealias` and two lines of environment. 099 · P1's 6A had edited exactly one arm of that
error table. Took 098's file whole.

### The one judgement call, named because it changes nothing and could have

6A's rule is that one `default:` arm must not answer for eighteen error cases, and P1
applied it to five tables plus, as a sixth, the phone's `LibraryStore.message(for:)`:
`default: "The library couldn't be read."` became `error.localizedDescription`.

098 · P3 moved that function to `BrowseFailure.message(for:)`, **kept the generic
sentence, wrote down why, and added `BrowseFailureTests` to pin it** — six named
`AtelierError` cases asserted equal to that exact string, with the reason in the test:
browse makes no writes (091 · D1), so a validation case arriving there means the read
itself failed, and what is being pinned is that none of them falls through to the
"couldn't be OPENED" sentence and sends a user to check their provisioning.

**098's version was kept.** Three reasons, in order: the file 099 edited no longer exists;
the peer's version is argued and tested where 099's was neither; and `AtelierError`'s
sentences are written for the Mac's surfaces ("that folder", "this smart collection") — on
a phone browse screen "The library couldn't be read." is the better sentence, which is the
argument 098 · P3 actually makes. Keeping it is also the resolution that changes no
behaviour relative to the rebase base. 6A's stated deliverable is intact: the five tables
`AtelierError.swift`'s own doc comment names — `IngestionModel.message(for:)`,
`SpaceModel.message(for:)` and three controller copies — all collapsed, and the sixth was
never one of them.

`AtelierLibraryPaths/…/LibraryLocationTests.swift` and `AtelierRefs/…/ItemDetailView.swift`
auto-merged cleanly (098's `withoutLeavingDefaultRoot` helper beside 099's two
`overrideValue` arms; 098's detail refactor beside 099's `moveTargetsCache` memo).

## The numbers — 457–460 became 463–466

Both sessions allocated from `ls .change-log | tail -1` and both got 457. Four numbers
existed twice with entirely different content. 098's are on the base branch and stay;
099's renumber above 098's highest, which is 462.

| was | is | title |
|---|---|---|
| 457 | **463** | the packages get their foundations |
| 458 | **464** | the gate tells its two arms apart |
| 459 | **465** | the corpus goes resident |
| 460 | **466** | the app target gets its foundations |

`git mv`, so history follows. CLAUDE.md's rule is that indices are never reused **because
docs cross-reference each other by number**, so every reference moved with them: five in
`.docs/099-mac-backlog-plan.md` (four status rows and one line of prose in the gate
section), one in 463, three in 465, five in 466. `grep -n '\b45[789]\b\|\b460\b'` over
those five files now returns nothing.

Everything else that says 457, 458 or 459 means **098's**, and was left alone —
including four code comments that predate the fork (`AppServices.swift:72`,
`LibraryLocation.swift:41`, `:111`, `:166`), which the 098 session wrote against its
forthcoming number before committing the doc.

One reference the renumbering did not cause but the rebase did: 465 cites the commit it
re-measured, and the rebase rewrote that hash. `d9e149e` → `0632320`.

## 5A — the four tree builders, as the plan predicted them and as they were

The plan counted four spellings of *group the flat `[Collection]` by parent, sort each
sibling group, recurse*: `FolderNode.tree` (dead), `CollectionNode.tree` (live, no cycle
guard), `CollectionTargets.destinationTree` (live, guarded), `BrowseCollectionTree.tree`
(a verbatim copy). Re-established against the post-098 tree:

| builder | plan said | found after 098 | now |
|---|---|---|---|
| `BrowseCollectionTree.tree` | a verbatim copy | **the one implementation** | unchanged |
| `CollectionTargets.destinationTree` | live, guarded | **already a one-line forward** (098 · P4) | unchanged |
| `CollectionNode.tree` | live, no guard | **still its own builder, still no guard** | a projection |
| `FolderNode.tree` | dead | **still dead** | deleted |

098 · P4 did half of it, and did it more thoroughly than the plan assumed: it also deleted
`CollectionTargets.galleryRoots` and `.byManualOrder` for `BrowseCollectionTree`'s, and
made `DestinationTreeNode` a `typealias` for `BrowseCollectionNode` rather than a second
struct with the same three members. What it did not touch was
`CollectionsOutlineView.swift` — it repointed that file's *comparator* to the package and
left the recursion and the missing guard where they were.

**`folderTree` was still consumer-free.** `grep -rn 'FolderNode\|folderTree'` over the
whole tree returns its own declaration, its `var folderTree` accessor, and two doc
comments that mention it. Nothing reads it, and nothing has since the sidebar became an
`NSOutlineView` at 208. Deleted, with a note in its place saying what it was: it was also
the one of the four that ordered roots **without pinning Unsorted**, so anyone who revived
it would have got a sidebar that disagreed with every other surface.

**`CollectionNode.tree` is now a projection.** It maps `BrowseCollectionTree.tree`'s nodes
into `CollectionNode`s and does nothing else. The split is deliberate: the ORDER is the
package's, and the IDENTITY is AppKit's — `CollectionNode` is an `NSObject` with id-based
equality because `NSOutlineView` diffs by identity and must keep expansion state across a
reload, which a `Sendable` package struct cannot do. The post-hoc Unsorted `remove`/`insert`
went too: `BrowseCollectionTree.roots` pins it while ordering, so doing it again afterwards
was a second chance to disagree.

### The cycle test, and what actually distinguishes a guarded builder

The obvious fixture does not discriminate. Two rows naming each other as parent means
neither is a root, so both builders return an empty tree and both terminate. A row has one
parent, so a cycle component has no root and is unreachable from one — which is why the
unguarded builder had survived.

The input that separates them is a back edge **spelled as a second row with an existing
id**: `Unsorted → C → D`, plus a row that is `C` again with `D` as its parent. Descending
reaches C, then D, then C. Measured against the pre-5A walk in a harness that capped the
depth: 2,001 nodes and still descending at level 2,000. In a test process, that is the
stack and the whole run with it. The guarded walk returns three nodes.

`CollectionTargetsTests` gains both cases, and a third test asserting the sidebar tree and
the destination tree are equal node for node — the two Mac renderings of the one ordering,
which is the drift 027 · G2 named.

**`MasonryLayout` reads `MasonryColumns`' constants, and no copy was left.** 098 · P4
deleted `minAspect`, `maxAspect` and `columnWidth` from `MasonryLayout` and made
`aspect(for:)` a one-line forward. `grep` over every Swift file finds `minAspect` /
`maxAspect` declared exactly once, in `MasonryColumns`. Nothing to remove. (`CollectionView.swift:819`
computes a column width inline for the SwiftUI fallback grid — the same arithmetic, not a
copy of the constants, and a different grid path. Left alone; named here so the next
reader does not have to re-derive that.)

## P2's ground truth — what 098 built, and what P2 should build instead

The brief asked this phase to establish what `c9d4a51` ("the suites that never ran, and a
gate for them") leaves for P2. **Nothing was built here; this is the finding.**

### What exists

- **`AtelierRefsMobileUITests`** — an **iOS** UI-test bundle on the `AtelierRefsMobile`
  scheme. Ten cases: `SwitcherUITests` (5), `ExportUITests` (4), `Tier2ShareUITests` (1,
  opt-in behind `ATELIER_RUN_SAFARI_TESTS` and blocked on a signing problem only the user
  can fix — the runner bundle needs an App ID with App Groups).
- **A DEBUG-only in-app seeder**, `AtelierRefsMobile/Debug/FixtureLibrary.swift`, behind
  the launch argument `-seed-fixture-library`, with three guards: `#if DEBUG`, the
  argument, and **the root must be an override** (`-library-root` / `ATELIER_LIBRARY_ROOT`)
  so the only library it can ever wipe is a throwaway one a test named. It wipes rather
  than merges, deliberately. Its fixture strings are `static let`s in an `enum Names` so a
  change to the fixture breaks compilation rather than an expectation.
- **The leaf-identifier rule.** Driving Clear and Keep found that neither identifier
  existed at runtime: `export.sent` on the enclosing `VStack` renamed everything inside
  it. Every notice identifier sits on a leaf now. This is a real, demonstrated bug class,
  not a style note.
- **A gate — in `.github/workflows/ci.yml` only.** A new `ios-ui-tests` job runs the two
  runnable suites on a pinned iPhone 17, and `ios-app` moved from `build` to
  `build-for-testing` so the UI bundle compiles at all.

### What P2 should now build

- **The macOS target is still entirely absent.** There is no `AtelierRefsUITests`, no
  macOS UI-test product in `project.pbxproj`, and no macOS UI test anywhere. P2's first
  bullet stands as written.
- **Do not invent `-ui-test-seed <name>`.** 098's `-seed-fixture-library` is the same idea
  with its guards already argued, and its third guard is exactly what makes a wiping
  seeder safe. P2 should mirror the shape and the argument name in a Mac
  `Debug/FixtureLibrary.swift`, with the Mac's own fixture set (three collections one
  nested, one space, four assets, one saved search — the phone has no surface for the last
  two, so the seeder itself cannot be shared as it stands). 099 · 8A already left the two
  arms where P2 needs them: `-library-root` DEBUG-only, `ATELIER_LIBRARY_ROOT`
  unconditional.
- **P2 must add accessibility identifiers before it can assert on anything.** The Mac
  target has **zero** `accessibilityIdentifier` calls — thirteen `accessibilityLabel`s and
  eight `.accessibilityElement` calls, which is 098's container
  problem in its other form: `.combine` merges children into one element and hides them
  from a UI test. This is not in P2's brief and it is most of P2's work.
- **The `verify.sh` UI stage neither conflicts nor is superseded.** `scripts/verify.sh` was
  not touched by 098 at all — the gate they added is CI-only, and CI has not run a step
  since 2026-08-06 (decision 9C leaves it that way). `verify.sh full` still has exactly
  thirteen stages and no UI stage. P2's `-only-testing:AtelierRefsUITests` second app stage
  should land as planned, and it is the only gate that will actually run.
- **One risk P2's brief does not name.** Only `AtelierRefsMobile` and `AtelierRefsShare`
  have shared schemes; `AtelierRefs` is auto-created, which is why `-scheme AtelierRefs`
  works. A new UI-test target has to end up in that scheme's test action, and P2 should
  verify that with `xcodebuild test -scheme AtelierRefs -only-testing:AtelierRefsUITests`
  rather than assuming it, on top of 098's `xcodebuild -list` rule.

## Verification

`./scripts/verify.sh full` — thirteen stages, exit 0:

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
  ✓ App target (Release)
  ⚠ Extension

All 13 stages passed, 1 with a warning above.
```

`⚠ Extension` is 464's stale Instagram fixture (exit 2, not a failure), untouched by this
phase; no code here goes near `extension/`.

### The first run after a rebase can fail for a reason that is not the code

The run above is the second. The first came back `✗ AtelierServer`, on a **compile** error
inside a package it only depends on:

```
AtelierCapture/Sources/AtelierCaptureTestSupport/CaptureFixtures.swift:34:14:
    error: cannot find 'FixtureImages' in scope
```

`FixtureImages.swift` sits in that same module, five files away, and `AtelierCapture`'s own
stage had passed minutes earlier. Re-run with nothing changed, `swift build --build-tests`
in `AtelierServer` compiles `FixtureImages.swift` and completes in 10 s, and the full gate
is green.

What happened is the rebase. A path dependency is built inside the DEPENDENT's `.build`, so
`AtelierServer/.build` was holding a plan for `AtelierCaptureTestSupport` from before the
rebase — a version of that module in which `FixtureImages.swift` did not exist, because 098
added it and 099's branch had never seen it. The first build after the checkout moved did
not re-scan far enough to notice. 464 recorded the same class of thing from the other side
("deleting `AtelierCore/.build`").

Named here because the next agent to rebase will hit it and should not spend the time this
phase did deciding whether it broke something: **a compile error naming a symbol that is
plainly in scope, in a package the current phase did not touch, on the first gate run after
a rebase, is a stale build plan.** Re-run before investigating. It is a phantom, not a
flake — it does not come back.

**The `@Test` count did not go down.** Counted as `@Test` occurrences in git-tracked
`*.swift`:

| tree | count |
|---|---|
| fork point `3bf4d7e` | 3,820 |
| 099 before the rebase | 3,966 |
| 098 tip `395e471` | 4,057 |
| after the rebase | 4,203 |
| after this phase | 4,205 |

4,057 + (3,966 − 3,820) = 4,203 exactly, so the rebase carried every test on both sides
and dropped none. The two added are this phase's.

## Tests added

`AtelierRefsTests/CollectionTargetsTests.swift`, in a new *the sidebar's tree is the same
tree* section:

- `sidebarTreeMatchesDestinationTree` — `CollectionNode.tree` and
  `CollectionTargets.destinationTree` flatten to the same names in the same order over a
  five-collection fixture whose Unsorted sorts last on every rule but the pin.
- `sidebarTreeIsCycleSafe` — the two-row mutual cycle returns empty, and the reachable
  back edge returns rather than recursing, with the shape it returns asserted (the descent
  stops at the repeat).

## What is still NOT covered

**The Instagram drift fixture is still stale**, and only a fresh capture from a logged-in
session clears it. 464 said so; it is still true, and every phase from here will still see
`⚠ Extension`.

**No UI test runs anywhere on macOS**, and nothing in this phase changed that. P2 owns it,
and the finding above is bigger than P2's brief: the identifiers do not exist yet.

**The cycle guard is proven, not exercised in production.** The input that distinguishes a
guarded builder from an unguarded one requires two rows sharing an id, which the database's
primary key makes impossible. The guard is defence against a corrupt or hand-edited
library and against a future caller that assembles `[Collection]` from somewhere other than
`listCollections()`; it is not a bug anyone has hit. What 5A actually bought is that there
is now one walk to reason about instead of four, and the reasoning is in one file.

**`BrowseCollectionTree`'s header cites `CollectionTargets.swift` line numbers** in the
three doc comments 093 § 2 wrote when the walk was restated. The file header now says the
restatement is over and the package is the only copy, but the individual `///` comments on
`byManualOrder`, `roots` and `tree` still name lines in a file that no longer holds that
code. Cosmetic, and left rather than churned in a rebase commit.

**Nothing was done about the Mac's `.accessibilityElement(children: .combine)` sites.**
They are correct for VoiceOver and wrong for XCUITest, and which way each should go is
P2's call to make against a real flow, not this phase's to guess.
