# 475 — the switcher is its own surface

[099 · P5](../.docs/099-mac-backlog-plan.md) closes a backlog line the user wrote with
its own open question attached: *"⌘K quick switcher. Not built. The open question is
whether it reuses the existing destination list or is its own surface."*

The question was already answered — **its own surface, the shared ordering** — and the
code had been saying so for a while. `DestinationPicker.swift`'s header, written at
024 · K3, states outright that *"[011] C-1's ⌘K type-ahead machinery is deliberately
NOT built here"*, and gives the reason: that picker files ASSETS into a collection, so
a filter field on it would be a second feature riding a first one's popover. A switcher
is the other verb. It moves *you*.

What it is NOT allowed to be is a second opinion about where you can go. So the
candidates are built from `CollectionTargets.destinationTree`, `SpaceTargets.ordered`
and the saved-search list the sidebar already draws, in the sidebar's own top-to-bottom
order, and the cursor walk is the destination picker's own — see *one step*, below.

## The ranking, written down where it is implemented

The plan asked for "a documented ranking". A ranking that lives only in a changelog is
a ranking the next reader has to reverse-engineer, so it is in `SwitcherRanking`'s doc
comment, in full, as three sort keys applied in order:

1. **Tier** — `prefix` before `wordStart` before `substring`. A candidate matching none
   of the three is not a result at all.
2. **Recents** — within a tier, a destination in the MRU comes before one that is not,
   most recently visited first.
3. **The shared ordering** — ties fall back to the candidate's position in the list
   above: the three fixed destinations, then Spaces, then Smart, then the collection
   tree pre-order with Unsorted pinned.

**Each tier has its own test, and so does each sort key.** That is the part of the
brief with teeth: `prefixTier`, `wordStartTier` and `substringTier` assert the three
separately, `tierIsTheFirstSortKey` / `recentsAreTheSecondSortKey` /
`sharedOrderingIsTheLastSortKey` assert the three keys separately, and
`recencyNeverBeatsTheTier` asserts the one interaction between them that is easy to get
backwards. A ranking asserted only end-to-end — "typing `con` opens Concrete" — passes
for the wrong reason the moment the library has two Concretes.

Four decisions inside the ranking are worth stating because each is a place a later
reader will otherwise assume the opposite:

* **A word boundary is any character that is not a letter or a digit** — space, `-`,
  `_`, `/`, `.`, `(`, `&`. Camel case is deliberately NOT one: collection names in this
  app are prose the user typed ("Warm Tones", "Type / Serif"), and splitting `TypeSerif`
  would also split `iOS` at the `O`. `camelCaseIsNotABoundary` pins the trade rather
  than leaving it to look like an oversight.
* **The BEST occurrence in a title decides its tier.** `Repost Posters` matched against
  `post` is a word-start match, not a substring one — a scan that stopped at the first
  hit would rank it below every genuine word-start match, which is exactly the
  disappointing behaviour a switcher is judged on. `bestOccurrenceWins`.
* **An empty query is a prefix of everything**, which is the absence of a special case
  rather than one: with every candidate at tier `prefix`, the resting list falls out of
  the same sort as *recents first, then the sidebar's order*, and is testable with the
  same function as a typed one.
* **Only the title is matched.** A nested collection's ancestor path is SHOWN (so two
  `Inspiration`s under different parents can be told apart) but not matched — typing
  `Textures` answers with `Textures`, not with its eleven children. `onlyTheTitleIsMatched`.

**There is no subsequence ("fzf") tier**, and that is a scope decision rather than an
omission. P5 names exactly three tiers; a fourth would change which rows appear at all
rather than only their order, which is a larger promise than this phase was given.

## The MRU, and the key shape it matched

`library.<id>.switcherRecents`, capped at eight, most recent first, de-duplicated.

The shape is **`ClipboardWatcher.enabledKey(libraryID:)`'s** — `library.<id>.` per
016 §C item 3, whose whole point is that multi-library needs no migration later because
every new preference adopts the prefix now. This is the third to do so (the clipboard
toggle, the backup cadence, this). `keyMatchesTheClipboardPreferencesShape` compares the
two keys directly rather than restating a format string, so the day someone changes the
namespace they have to change it in both places or fail.

The consequence the clipboard watcher already lives with applies here too and is
inherited rather than worked around: **until the library is open and its id resolves
there is no MRU at all**, and the switcher ranks by the shared ordering alone. A
per-library list cannot be read before we know which library we are in, and
`recordBeforeActivateWritesNothing` asserts that nothing is written to an
un-namespaced key "for now".

Tokens are `home` / `capture` / `shelf` / `collection:<uuid>` / `space:<uuid>` /
`savedSearch:<uuid>`, and `token(for:)` is a `switch` with **no `default`** — the
discipline `SidebarItem.acceptsAssetDrops` established for the same enum, so a new
destination has to decide whether ⌘K remembers it. `tokensRoundTrip` asserts the
spellings as literals, because they are persisted: changing one silently drops
everybody's MRU rather than failing anything.

## Verbs are not in v1, and here is why

"New Space" and "Snapshot Now" are the obvious next rows and they are deliberately
absent. **Both already have menu items with key equivalents** — ⌘N through
`NewItemCommand`, File ▸ Snapshot Now through `SnapshotCommands` — so a switcher row
would be a third spelling of a binding that is already discoverable in two places. It
would also open a door this version has no design for: the first verb that took an
argument ("New Space *called what*") needs a second mode inside the panel, and a palette
with two modes is not the thing 011 · U4 asked for. The file header says this where the
rows would go, so the next person to want one meets the reason before the code.

## The panel, and the responder rule that is the whole of it

`SwitcherPanel` is a SwiftUI query field over the ranked list, hosted in an `NSPanel`
that is a CHILD WINDOW of the shell. A sheet was wrong (modal to a window, and it says
"answer this before you carry on"); a popover was impossible (it needs an anchor view,
and ⌘K is pressed from wherever the keyboard is — including the full-window item-detail
overlay and a Space board, neither of which has a control to hang one on).

**The load-bearing part is that first responder is handed back on close**, which is
`DestinationPicker`'s existing discipline and the reason its header exists at all. A
panel that takes the responder and does not give it back leaves the shell alive but
deaf: the grid's arrows, the canvas's tools and the detail page's ← → all stop, with
nothing on screen to say why. So `SwitcherPanelController` captures
`host.firstResponder` **before** the panel is ordered in and restores it on every close
path — Escape, Return, a row click, a click on the window behind, the view being
dismantled — and `dismiss()` is idempotent because two of those routinely arrive in the
same runloop turn. `theHostWindowGetsItsResponderBack` drives a real `NSWindow` and a
real panel, and drops the host's responder in between so the restore is doing work
rather than agreeing with itself.

Three smaller things the window needed, each of which is a bug if got wrong:

* **`canBecomeKey` is overridden to `true`.** A borderless window refuses key status by
  default, so without it the field would never see a keystroke.
* **`canBecomeMain` is overridden to `false`.** The shell stays the main window, so its
  focused-scene values stay resolved while the panel is up — which is what lets ⌘K be
  pressed on a Space board and still commit into the window that raised it.
* **Two resizes are followed, and the second is easy to miss.** The host's, so the panel
  stays centred while the window is dragged; and the PANEL'S OWN, because
  `sizingOptions = [.preferredContentSize]` lets SwiftUI change its height and an
  `NSWindow` resize keeps its BOTTOM-left origin. Without that observer the panel climbs
  upward off its anchor the first time a query stops matching. The arithmetic is pure
  (`origin(forPanelSize:over:)`, `width(forHostWidth:)`) so it is two tests rather than
  a screenshot.

The anchor the panel hangs off is a zero-framed `NSView` in the shell's `.background`
that returns `nil` from `hitTest` — it is in the window so the controller can find one,
and it is out of the mouse's world entirely so a background spanning the whole shell can
never answer for a click.

## The ordering P5 states as a requirement

*"Inside the detail overlay and on a Space board the panel still opens, and a
destination it commits pops the overlay first."*

Both halves are mechanical rather than aspirational, and both are asserted.

**It opens everywhere** because the binding is a MENU KEY EQUIVALENT (View ▸ *Go to…*,
⌘K), and `NSMenu` matches those before the event reaches any first responder. That is
the same platform behaviour `DeleteCommands` documents as a hazard for a bare ⌫; here it
is the point. The Space canvas's `keyDown` and the detail page's key catcher both read
bare keys and would never forward a chord they do not recognise, so a scoped binding
would have worked everywhere except the two places the phase names. ⌘K was claimed by no
row in any scope before this one, and `KeyMap.collisions` keeps saying so.

**The overlay pops first** because the commit routes through `NavModel.selectSidebar`,
which has cleared `presentedItemID` before assigning the selection since 355. The
sequence now lives in `NavModel.commitSwitcher(_:recents:)` — close the panel, record
the visit, navigate — rather than in a `ViewBuilder` closure, precisely so it can be a
test. `overlayPopsBeforeTheRouteChanges` observes `$sidebarSelection`, which fires in
`willSet`, and asserts that `presentedItemID` already reads `nil` inside that sink.
`recommittingTheOpenDestinationStillPopsTheOverlay` covers the case an implementation
that only cleaned up on a *real* navigation would get wrong: ⌘K to the pane you are
already on, which is exactly how someone gets out of a picture.

## One step, not two

`CollectionDestinationList.step(from:in:by:)` — the clamped cursor walk 024 · K3 wrote
for the destination picker — is now **generic over the row type**. Nothing about it was
ever collection-specific (it never looked at a `Collection`), so the switcher's cursor,
whose rows are `SidebarItem`s, walks the same four rules rather than a second copy of
them: clamped at both ends, `nil` enters at the first row going down and the last going
up, an id that has left the list re-enters rather than stranding the cursor.

Every existing call still infers `UUID`. One assertion in `MoveAddShortcutTests` needed
`[UUID]()` where it had `[]` — an empty literal with a `nil` cursor leaves the compiler
nothing to infer the row type from. **The assertion itself is unchanged**, and no test
was removed or relaxed anywhere in this phase.

## How much of P4's keyboard gap this closes

[473](473-the-saved-search-becomes-a-place.md) closed by naming what decision 7A cost:
*"The sidebar's Smart rows have no keyboard. The two AppKit outlines get ↑/↓, →/← and
Return-to-rename from `NSOutlineView`; a SwiftUI `ForEach` of buttons gets none of
them."*

**⌘K closes the reachability half and none of the rest.** A saved search is a switcher
candidate, so *going to* one is now a keyboard route — four letters and Return, from any
surface, without touching the mouse or the sidebar. That is genuinely the first keyboard
path to a smart collection, and it is a better one than the outlines have (they still
require arrowing to the row).

It does **not** give the Smart section a keyboard. Everything that needs the ROW rather
than the destination is still pointer-only there: ↑/↓ between smart rows, Return to
rename, the delete verb. ⌘K navigates; it does not operate on what it navigates to, and
it is not an outline view. 7A's cost stands, reduced by one — and the same is true, note,
of the collections tree and the Spaces list, which now have a second keyboard route as
well.

## The smoke flow: written, and NOT gated

The plan gave this phase a flow for the smoke target — *⌘K → type the nested
collection's name → Return → the grid shows it* — and it is written
(`testCommandKGoesToTheNestedCollection`). The nested collection is the deliberate
target: `Concrete` is not in the accessibility hierarchy at all until its parent is
disclosed, so reaching it by typing is the one claim a switcher makes that the sidebar
cannot.

**It will not gate anything, and it could not be observed passing.** Two separate facts,
and both belong here rather than in an optimistic sentence:

1. [474](474-the-gate-stops-claiming-a-window.md) took `App target (UI)` out of
   `verify.sh full` (issue 23D). Nothing runs this flow unless a person types
   `./scripts/verify.sh ui`.
2. On this machine, `./scripts/verify.sh ui` fails **all four** flows with *"the app
   opened no window"* — including `testLaunchShowsTheSeededCollectionOnHome`, which this
   phase does not touch. **The control run is the answer, as it was in 473**: with every
   change of this phase STASHED — a tree identical to `0cc2b79` — that unchanged launch
   flow fails the same way, in 63 seconds, with the same sentence. This is the ad-hoc
   signing blocker 474 removed the stage for; it is not the diff.

So the flow is a written artefact awaiting a machine that can run it, and the phase's
real coverage is `swift test`: **fifty new `@Test`s**, including the one thing about the
panel that a unit test CAN make — `theHostWindowGetsItsResponderBack` builds a real
window, presents a real child panel and asserts the hand-back.

What that leaves unproven is named in full below, because "the model tests carry the
weight" must not be read as "everything is covered".

Screen capture was also unavailable (`screencapture` and `CGWindowListCopyWindowInfo`
both return nothing without a Screen Recording grant), so the panel was not confirmed by
eye either. The app itself does launch and stay up against the fixture library with this
diff applied, which is the most that could be checked without a permission only the user
can give.

## Tests

**Fifty added; `@Test` count 4,284 → 4,334 across the repo.** Nothing was removed and no
assertion was relaxed.

`SwitcherRankingTests` (22) — `prefixTier`, `wordStartTier`, `wordStartSeparators`,
`camelCaseIsNotABoundary`, `substringTier`, `noMatch`, `bestOccurrenceWins`,
`caseAndDiacriticsFold`, `emptyQueryIsAPrefixOfEverything`, `tierIsTheFirstSortKey`,
`recentsAreTheSecondSortKey`, `recencyNeverBeatsTheTier`, `staleRecentsAreIgnored`,
`sharedOrderingIsTheLastSortKey`, `emptyQueryIsTheRestingList`, `resultsAreCapped`,
`candidatesAreTheSharedOrdering`, `detailLinesSayWhereARowLives`,
`onlyTheTitleIsMatched`, `spacesAndSavedSearchesAreCandidates`,
`spacesUseTheSharedSpaceOrdering`, `nonDestinationsAreAbsent`.

`SwitcherRecentsTests` (9) — `keyIsNamespacedByLibrary`,
`keyMatchesTheClipboardPreferencesShape`, `tokensRoundTrip`, `unparsableTokensAreDropped`,
`recordIsMostRecentFirstAndDeduplicates`, `recordIsCapped`, `activateReadsTheStoredList`,
`twoLibrariesDoNotShareAList`, `recordBeforeActivateWritesNothing`.

`SwitcherModelTests` (9) — `openSeedsTheCursor`, `openClearsThePreviousQuery`,
`openHonoursTheMru`, `cursorSurvivesAKeystrokeWhenItsRowDoes`,
`cursorReseedsWhenItsRowIsFilteredOut`, `noResultsMeansNothingToCommit`,
`arrowsAreClamped`, `highlightIgnoresARowThatIsNotOffered`, `emptyLibrary`.

`SwitcherNavigationTests` (10) — `overlayPopsBeforeTheRouteChanges`,
`recommittingTheOpenDestinationStillPopsTheOverlay`, `commitFromASpaceBoard`,
`commitClosesThePanelAndRecordsTheVisit`, `commandKIsGlobalAndUncontested`,
`bareKIsNotBoundEither`, `theHostWindowGetsItsResponderBack`,
`presentAndDismissAreIdempotent`, `panelGeometryIsAnchoredToTheTop`,
`panelWidthClampsToTheHost`.

Plus one XCUITest, `SmokeUITests.testCommandKGoesToTheNestedCollection` — written,
ungated, unobserved. It is not counted above because it is not a `@Test` and, more to the
point, because nothing runs it.

**No wait is a sleep** (099 · 11A). Nothing in these four suites waits at all: they are
pure functions, a `UserDefaults` suite per test, and one real `NSWindow`. The UI flow's
two new waits are `waitForAbsence`, a state-change poll modelled on the file's existing
`waitForHittable` — a row that stopped being offered, and a panel that closed — not a
settling delay.

## The gate

`./scripts/verify.sh` full, thirteen stages, **exit 0 on the first run** against this
exact code diff:

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

`⚠ Extension` is the stale Instagram drift fixture, non-fatal by design since 464, and
not this phase's.

## Files changed

* **new** `AtelierRefs/AtelierRefs/SwitcherModel.swift` — `SwitcherCandidate`,
  `SwitcherRank`, `SwitcherMatch`, `SwitcherRanking` (the candidates, the tiers, the
  sort), `SwitcherRecents` (the per-library MRU) and `SwitcherModel` (the query, the
  results, the cursor).
* **new** `AtelierRefs/AtelierRefs/SwitcherPanel.swift` — the SwiftUI panel and its row,
  `SwitcherLayout`, `SwitcherPanelWindow`, `SwitcherPanelController` and the
  `SwitcherPanelHost` seam.
* **new** `AtelierRefs/AtelierRefsTests/SwitcherRankingTests.swift`,
  `SwitcherRecentsTests.swift`, `SwitcherModelTests.swift`,
  `SwitcherNavigationTests.swift`.
* `NavModel.swift` — `showSwitcher`, and `commitSwitcher(_:recents:)` with the ordering
  it exists to make testable.
* `AppShellView.swift` — the panel host in the shell's background, framed to zero, and
  the candidate/MRU closures that are read once per presentation rather than once per
  publish.
* `AtelierRefsApp.swift` — `GoToCommand` (View ▸ *Go to…*, ⌘K), above Back in the same
  group.
* `KeyMap.swift` — the ⌘K row, `.global`, with the note on why the panel's own
  ↑ / ↓ / ↩ / esc are deliberately not rows (`DestinationPicker`'s precedent).
* `CollectionDestinationList.swift` — `step` is generic over the row type.
* `CollectionView.swift` — an accessibility identifier on the pane's title leaf.
* `AccessibilityIdentifiers.swift` — `switcherField`, `switcherRow(_:)`,
  `collectionTitle(_:)`.
* `IngestionModel.swift` — the `SwitcherRecents` instance, activated at bootstrap beside
  the clipboard watcher's and the backup cadence's per-library binding.
* `AtelierRefsTests/MoveAddShortcutTests.swift` — `[UUID]()` for `[]` at one call site
  (type inference only; the assertion is unchanged).
* `AtelierRefsUITests/SmokeUITests.swift` — the ⌘K flow, `waitForAbsence`, and a header
  note that this target is no longer gated.
* `.docs/099-mac-backlog-plan.md` — P5's status row and a Done note; P5's and P6's smoke
  bullets amended to say the flow is written and not gated; **and the gate paragraph
  corrected from "fourteen stages" to thirteen**, which 474 changed and left standing.

## What is still NOT covered

**Nothing has watched ⌘K open.** The panel's window machinery is tested against a real
`NSWindow` and the ranking is tested exhaustively, but the three links between them —
the menu item firing, SwiftUI focus landing in the field, and a keystroke reaching a
child window — are asserted by nothing that runs on this machine. `verify.sh ui` fails
before it can try (474's blocker, reproduced on a stashed `HEAD`), and screen capture is
not permitted here. **A person should press ⌘K once before trusting this.**

**Arrow keys inside a `TextField` are the specific thing to watch when they do.** ↑ and ↓
are read with `.onKeyPress` on the field itself — the shape `LibrarySearch`'s search
field already uses for Escape, and the reason that precedent was followed — and both
handlers return `.handled` so the field editor never sees them. If the cursor does not
move, that is where it is.

**The panel does not close on ⌘K.** ⌘K while it is up re-raises what is already up (a
no-op). A second press toggling it shut is the obvious refinement and is not built.

**There is no fuzzy subsequence match.** Typing `cnrt` finds nothing, where an fzf-style
switcher would find `Concrete`. Three tiers is what P5 specified and what is tested; the
fourth is a scope decision, recorded on `SwitcherRank`, not an oversight — and it is the
first thing to add if the switcher feels literal-minded in use.

**Nothing prunes the MRU.** A collection that is deleted stays in the stored list
forever; it is simply never a result, because ranking runs over live candidates
(`staleRecentsAreIgnored`). At a cap of eight this is a few stale strings in a plist, not
a leak — but a library churned hard enough could carry an MRU of eight tombstones and
effectively have no MRU at all, and nothing detects that.

**Nothing outside `verify.sh` runs any of this.** CI has not executed a step since
2026-08-06 and its runners are `macos-15` against packages that floor at macOS 26 (9C).

**The three load-induced timeout flakes are untouched**, as directed:
`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests`.
So is 472's `JSONDecoder`-per-row finding at `JSONValue+GRDB.swift:36`. So is issue 23C,
the runner's signing identity — which remains the single change that would let this
phase's smoke flow, 473's, and every future one actually run.

**One thing noticed and not acted on**, for the report rather than the diff: the shell's
`headerContent` is rendered three times (once hidden, to measure its height; once in the
skeleton branch; once inside the AppKit header band), so the new `collection.title.<name>`
identifier is on a view that exists more than once in the tree. SwiftUI's `.hidden()`
takes the measurement copy out of the accessibility hierarchy and the other two are
mutually exclusive branches, so exactly one should ever match — but the UI flow reads it
with `.firstMatch` rather than depending on that, and a future flow should too.
