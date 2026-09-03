# 478 — the colours learn to say "and"

[099 · P10](../.docs/099-mac-backlog-plan.md) closes a backlog line the user wrote with
two halves: *"Color filter: the 'match all' mode has no UI, and a color wheel is not
reachable from the stored data."* One half is built. The other is refused, in writing,
at the doc that refused it first.

## What was already there — which is nearly all of it

The line was read against the code before anything was written, because "has no UI"
implies the rest of it exists, and the phase brief said to check the default before
adding a parameter. It does exist, and there was nothing to add below the app target:

* `AppServices.searchAssets(…, colorBuckets:, colorMatch: TagMatch = .any, …)` —
  `AppServices+Search.swift:72`, with the switch that builds the conjunct at `:341`.
* `AppServices.semanticSearchAssets(…, colorMatch: TagMatch = .any, …)` —
  `AppServices+Analysis.swift:485`, switch at `:552`. Both arms, not one.
* `SearchRules.colorMatch` — stored, `color_match` in the JSON, decoded tolerantly with
  its own `.any` fallback rather than the tag field's `.all`.
* `AppServices.evaluate(rules:)` passes `colorMatch: rules.colorMatch`
  (`AppServices+SavedSearches.swift:134`).

So `.all` worked end to end and could be reached by exactly one route: hand-writing a
`saved_search.rules` blob. [085](../.docs/085-color-filter-plan.md) says so itself, in
the sentence that answered its own open question — *"`.all` is reachable through the API
and has tests; no UI offers it yet"* — and that sentence had been true for four docs.

**Two things were genuinely missing, and the second one is the interesting one.**

1. **`LibrarySearchQuery` had no `colorMatch`.** The live query is the ONLY way the app
   reaches `searchAssets`, and it never named the argument, so every search anyone has
   ever run in this app took the service's `.any` default. Not a bug — `.any` is the
   right default — but it meant the value was not a value, it was a constant with a
   parameter's shape.
2. **The 099 · 4A bridge PINNED it.** `SearchRules.init(query:)` wrote
   `colorMatch: .any` under a comment explaining that the query "cannot express" the
   mode. That was true when [466](466-the-app-target-gets-its-foundations.md) wrote it.
   This phase is what made it false, so the pin came out and the field crosses. Left in,
   it would have been the 011 favorites incident exactly — a filter a user can see, set
   and run, dropped on the way into storage — which is the incident the bridge exists
   because of.

## The canary was confirmed to fail before the field was mapped

The brief asked for this and it is worth the paragraph, because an exhaustiveness test
is only worth what it costs to prove it works.

`colorMatch` was added to `LibrarySearchQuery` **alone** — no bridge change, no
allowlist entry — and `SearchRulesBridgeTests` was run. `exhaustiveness()` failed, on
both parallel workers, with the sentence it was written to print (recovered with
`xcresulttool`, since `xcodebuild`'s own log records the failure and not its text —
[469](469-the-cache-that-was-never-promised.md)'s finding, still true):

```
Expectation failed: (unaccounted → ["colorMatch"]).isEmpty → false: LibrarySearchQuery
grew colorMatch. Either map it in SearchRulesBridge.swift, or add it to the allowlist
in SearchRulesBridgeTests with the reason it cannot cross.
```

The field is then **MAPPED, not allowlisted** — and that is itself pinned, because
`exhaustiveness` is satisfied by either list. `colorMatchIsMappedNotAllowlisted` asserts
which list it is in, so a later hand cannot quiet the canary by moving the field to the
allowlist and silently stop persisting it. That move is precisely the failure this suite
exists for, and the canary alone cannot see it.

One more thing came out of the same pass: `fullyPopulated`, the fixture whose whole job
is that every dimension is non-default, was leaving `colorMatch` at its default. A
bridge that dropped the field entirely would have round-tripped through it happily. It
is `.all` now.

## Where the control lives, and why it hides

An *Any / All* segmented control in `ColorFilterPicker`'s popover, under a `Divider`,
above "Clear colors" — a `DialogRow("Match")` around a `SegmentedControl`, which is the
app's one popover vocabulary (`DialogControls.swift`) rather than a stock AppKit picker.

**It appears only once two colours are on.** With one chip, `.any` and `.all` select
the same pictures; with none, both select nothing. So below two it is a switch with one
position, and the file it lives in already refuses to draw exactly that — its "Clear
colors" button is conditional under a comment calling a permanently-visible control that
does nothing most of the time *"the kind of dead affordance the sub-floor chips of
[378](378-the-gate-that-knew-which-way-was-warm.md) already were."* This is that rule
applied a second time, one colour later.

The rule is `LibrarySearchModel.showsColorMatchControl` — a pure property with a test —
rather than a condition spelled in the view, so it is asserted rather than looked at.

**The mode is not a token, unlike every colour it governs.** A `SearchToken` is a
filter; this is how two filters read together. Carried as a token it would have put a
chip in the field that means nothing on its own and removes itself when you click its
`×`. It lives beside `mode` and `scope`, which are the other two "how this query is
read" fields, and it gets their treatment: its own `@Published`, its own
`colorMatchChanged()` hook, its own `.onChange` in `LibrarySearchable`. A `tokens`
mutation could not have carried it — nothing about the token SET changes when the mode
does.

**The tooltip is where the mode is legible with the popover shut.** "Filtering by Red,
Blue" became "Filtering by Red **or** Blue" / "Red **and** Blue". The chips in the
search field cannot say this, because they are one chip each; the button's help is the
only surface that sees both colours and the mode at once.

## Which clears reset it, and which do not

Three verbs could plausibly own the default and only one does.

* **`reset()` restores `.any`.** It is the whole-model reset — a new pane, a new
  library, a navigation — so the default belongs to it.
* **`clearQuery()` (the field's `×` and Esc) leaves it.** It already leaves `scope` and
  `mode` for the same reason.
* **`clearColorFilters()` (the picker's own clear) leaves it too.** This is the one
  worth arguing about, and the argument is that "match all of them" is something the
  user said about how they search, not one of the filters they asked to clear. Someone
  who clears four chips to pick three different ones did not ask to go back to `.any`.

`colorMatchResetRules` asserts all three in one test, so the distinction cannot decay
into whichever behaviour a later edit happens to produce.

## ⇧⌘C — the first keyboard route this surface has ever had

The picker had none. That matters more than it looks: with no chord, the Any / All
control this phase added sits behind a mouse-only popover, which is most of the way back
to the "no UI" the backlog line complained about.

**⇧⌘C, and the shift is the whole decision.** Plain ⌘C is Copy, bound in `.collection`
(`MasonryGridHost.swift:1617`) and on a board (`CanvasHostView.swift:1365`). The row is
`.global` — a `ToolbarItem`'s `keyboardShortcut` hangs off the scene, not off the search
field, which is ⌘S's structural argument from
[473](473-the-saved-search-becomes-a-place.md) — and a `.global` row is matched before
every surface row, so an unshifted colour row would have shadowed both copies.
`collisions(in:)` would have said so; the answer is not to argue with copy-paste.

The chord was checked against the current table and not a remembered one, because the
two nearest rows are both recent: **⌘K** (P5, [475](475-the-switcher-is-its-own-surface.md))
and **⇧⌘P** (P6, [476](476-the-palette-is-the-second-window.md)). The shift-command rows
in every scope are ⇧⌘Z, ⇧⌘], ⇧⌘[, ⇧⌘E and ⇧⌘P; ⇧⌘C was claimed by nothing.
`shiftCommandCIsTheColorFilter` says exactly one row holds it and it is `.global`;
`commandCIsCopyAndStaysLocal` says the near miss stays a miss — ⌘C is bound on
`.collection` and `.space` and on no global row — so a later phase that wants to make
⌘C global has to delete an assertion to do it.

## The colour wheel is refused, not forgotten

The backlog's second half. [085](../.docs/085-color-filter-plan.md) named it as a risk
when the schema was designed and the schema is why: `asset_color` stores a palette
bucket **integer** and a coverage, and a wheel needs real Lab coordinates per swatch. An
integer cannot be drawn as a wheel and cannot be matched by proximity on one.

The door is open by design — adding `l, a, b` columns is additive, and the derivation
pass that would fill them is the one C1 already built — so this is a schema change plus
a re-derivation of every analysed asset, which is a phase and not a control. 085's risk
entry now says that at this phase's name, and its "no UI offers it yet" sentence is
struck through and amended, so neither claim can be read as current.

## Tests

**Eleven added; `@Test` count 4,376 → 4,387 across the repo.** Nothing was removed, no
assertion was relaxed, and no test file is new.

`LibrarySearchModelTests` (+7) — `colorMatchDefaultsToAny`,
`colorMatchAllReachesTheQuery`, `colorMatchReachesTheSemanticQuery`,
`colorMatchChangeRerunsTheQuery`, `colorMatchControlNeedsTwoColours`,
`colorMatchResetRules`, `colorMatchDoesNotActivate`.

`SearchRulesBridgeTests` (+2) — `colorMatchCrossesBothWays` (parameterised over both
modes, in memory and through the encoded blob) and `colorMatchIsMappedNotAllowlisted`.

`KeyMapTests` (+2, in the contract suite) — `shiftCommandCIsTheColorFilter`,
`commandCIsCopyAndStaysLocal`.

**Two existing tests were rewritten to say something stronger, not something weaker.**
`matchModesArePinned` asserted `rules.colorMatch == .any` beside `tagMatch == .all`; the
first half is no longer true, so it now asserts that `tagMatch` is still the one field
the bridge invents, that `colorMatch` carries `.all` AND `.any` off the query, and that
an unset rule still means the service's `.any`. `exoticMatchModesDegradeRatherThanCrash`
covered two unreachable modes and now covers one — it keeps every assertion it had, adds
that the query carries `colorMatch: .all` back, and adds that re-saving the rebuilt query
keeps the colour mode while the tag mode falls back. `roundTripRuleIsPopulated` changed
one expected value, because the fixture it reads is now genuinely populated.

**The `.any` case is not padding.** A bridge that hard-coded `.all` would pass the `.all`
case of `colorMatchCrossesBothWays` and fail its `.any` case — which is the mirror of the
bug the pin itself was.

**No wait is a sleep, and none of them is a poll either** (099 · 11A). The four query
tests await `LibrarySearchModel.events` through `EventRecorder` — 11A's actual
preference, *"where the object under test can SAY it finished … await the signal; it is
exact"* — rather than the shared `poll` helper the colour tests above them use. Those
predate the signal and were left alone. The difference is not cosmetic: on the first
gate run of this diff **every polled test in this suite timed out at ~21 s and all four
of these went with them** (the cause is in the gate section below, and it was not the
tests); converted, they run in 0.24 s each and were green on every run afterwards,
including the four in which the suite's remaining polls still failed. `colorMatchChangeRerunsTheQuery` awaits the SECOND
settle and then asserts the query count, so "the mode change is a new search" is a
statement about how many searches ran, not about which one finished first.

The three non-async additions are pure — `showsColorMatchControl`, the reset rules and
`isActive` — as are both bridge tests and both `KeyMap` ones.

## The gate

`./scripts/verify.sh` full, thirteen stages, **exit 0**:

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

`⚠ Extension` is the stale Instagram drift fixture, non-fatal by design since
[464](464-the-gate-tells-its-two-arms-apart.md), and not this phase's.
`App target (UI)` is not in the list and has not been since
[474](474-the-gate-stops-claiming-a-window.md); nothing here adds a smoke flow, so there
is nothing ungated to declare. No `project.pbxproj` change was needed — every file
touched already existed — so `xcodebuild -list` had nothing to re-verify, and
`git status` shows the project file untouched.

### It took six runs, and the fifth one said why

**This is the useful part of this entry for whoever hits it next**, because four runs of
this gate failed for a reason that looked exactly like a code problem and was not one.

Runs 1–4 failed `App target`, and once `CanvasRenderer` as well. The shape never varied:

* **Never a value.** Every failure was a TIMEOUT — 14.9 s, 16.5 s, 21 s, or a flat 60 s
  against the suite time limit. Not one `#expect` ever reported a wrong answer.
* **Always somebody else's test.** `PollTests/settlesEarly()`,
  `CollectionActivationTests/sidebarDraftCommitSelectsNewCollection()`,
  `CollectionReadModelTests/ingestBurstCollapses()`, and up to eleven pre-existing
  `poll`-based tests in `LibrarySearchModelTests`. `CanvasRenderer` fell over on
  `CanvasBenchmark.testFrameUpdateWithinBudget` — a wall-clock 120 fps budget — at
  8.45 ms and then 8.86 ms against 8.33, in a package this diff does not touch by one
  character.
* **A control run on an unchanged `HEAD` failed the same way**, with the whole phase
  stashed: `ingestBurstCollapses()` at 60.000 s. So the diff was exonerated, and the
  question became what the machine was doing.

Load was the obvious suspect — two sibling agents were building on this machine and the
load average ran 13 to 22 — and it was the wrong one. Waiting for a quiet window (load
6.5) and re-running produced *the same eleven failures*.

**Run 5 answered it: `no space left on device`.** The `Extension` stage died on it
outright, and `df` said the data volume was at **100 %, with 798 MB free**. That is what
every one of those timeouts was: `xcodebuild` and the test runner writing logs,
diagnostics and result bundles into a volume with nothing left, and stalling — which
surfaces as a poll that never settles, and looks for all the world like a race.

Freeing the volume (26 GB back: a 122 MB `.xcresult` this phase had written, ~1.6 GB of
earlier phases' scratch, and thirty-one stale `AtelierRefs-*` DerivedData trees) made
run 6 pass every stage **at load 10.6** — higher than the quiet window that had failed.
So the load was a red herring and the disk was the cause.

**Two things follow.** First, `PollTests/settlesEarly()`, `LibrarySearchModelTests` and
`CollectionActivationTests` are named in 099 as load-induced flakes; on this evidence at
least some of what has been read as load is disk pressure, and it is worth checking `df`
before blaming the scheduler next time. Second, **the DerivedData sweep was blunter than
intended and this entry says so**: the `find … -newermt "-24 hours"` guard meant to spare
today's trees is not supported by the `find` on this machine (`bfs`), it errored on every
directory, and the age test silently passed for all of them — so all thirty-one went,
including the two belonging to the sibling agents. Nothing is lost (DerivedData is a
cache, and Xcode rebuilds it), but a sibling's in-flight build would have failed at that
moment and its next one paid a full rebuild.

## Files changed

* `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `LibrarySearchQuery.colorMatch`;
  `LibrarySearchModel.colorMatch` (`@Published`), `showsColorMatchControl`,
  `colorMatchChanged()`; `reset()` restores the default; both query constructions and
  both live seams (`searchAssets`, `semanticSearchAssets`) forward it; the pane's
  `.onChange`.
* `AtelierRefs/AtelierRefs/ColorFilterPicker.swift` — the Any / All row, the mode-aware
  tooltip, `.keyboardShortcut("c", modifiers: [.command, .shift])`, and a header section
  recording both halves of the backlog line.
* `AtelierRefs/AtelierRefs/SearchRulesBridge.swift` — `colorMatch` crosses in both
  initialisers; the header's "pinned" paragraph is rewritten to cover `tagMatch` alone
  and to say why the colour pin came out.
* `AtelierRefs/AtelierRefs/KeyMap.swift` — the ⇧⌘C row, `.global`, with the ⌘C note.
* `AtelierRefs/AtelierRefsTests/LibrarySearchModelTests.swift`,
  `SearchRulesBridgeTests.swift`, `KeyMapTests.swift` — as above.
* `.docs/085-color-filter-plan.md` — the "no UI offers it yet" answer struck through and
  amended; the colour-wheel risk entry names P10 as the phase that re-confirmed it.
* `.docs/099-mac-backlog-plan.md` — P10's Done note and status row.

## What is still NOT covered

**Nobody has clicked the control.** `showsColorMatchControl` is tested, the mode's route
to both services is tested, the round trip is tested — and that the `SegmentedControl`
inside a popover is actually reachable, sized and legible in a 275pt card is read, not
run. `App target (UI)` left the gate in [474](474-the-gate-stops-claiming-a-window.md)
and `verify.sh ui` cannot run on this machine at all (issue 23C), so no smoke flow was
added here rather than adding one that nothing executes. **A person should open the
picker with two colours on and look at the row once.**

**`LibrarySearchQuery(rules:)` still has no production caller.** The reverse half of the
4A bridge is exercised only by its tests. Concretely: opening a smart collection runs
`evaluate(rules:)`, which honours a stored `.all` correctly — but it does not seed the
search field, so the picker shows `.any` while the grid is showing an `.all` result. That
gap predates this phase and covers every rule field equally (the text, the tags and the
colours are all missing from the field too), so it was not opened here; it is worth
naming because `colorMatch` is the first field where the two can visibly disagree about
a MODE rather than about a value.

**Re-saving from an open smart collection re-rules it from the LIVE query**, colour mode
included. That is P4's behaviour and it is correct, but combined with the paragraph
above it means: open a smart collection saved with `.all`, type a new query, press ⌘S,
and the stored mode becomes whatever the picker currently shows — which is `.any`,
because nothing seeded it. The fix is the seeding, not the save.

**The archive still cannot carry a saved search**, so a rules blob's `colorMatch` cannot
cross libraries either. [473](473-the-saved-search-becomes-a-place.md) found 057's claim
false and pinned the gap with `savedSearchesDoNotYetCrossTheArchive`; nothing here
changes it.

**`tagMatch` remains unreachable from the live field.** The search field ANDs tags,
always, and this phase deliberately did not give tags the control it gave colours — 085
settled the colour default against a user-visible reading ("red then blue" widens) and
no doc has done the equivalent for tags. `matchModesArePinned` now says explicitly that
`tagMatch` is the last pinned field, so the day someone wants an Any / All for tags the
assertion names the file.

**No colour wheel, and no Lab columns**, for the reason above. If it is ever wanted, the
shape is `asset_color` gaining `l, a, b`, C1's derivation pass filling them, and a
proximity predicate replacing the bucket equality — none of which is a control.

**The three named flakes were not diagnosed, only survived.** The gate section above
shows they fail identically on an unchanged `HEAD` and stop failing when the disk has
room, which is evidence about the machine and not a fix for the tests: `PollTests
/settlesEarly()`, `CollectionActivationTests` and the eleven remaining `poll` waits in
`LibrarySearchModelTests` are all still polls, and all still fail together the moment
the volume fills. Converting them to the signals their subjects already publish is the
work; this phase converted only the four it wrote. **Whoever picks that up should read
the gate section first**, because "load-induced" is at best half the diagnosis.

**Out of scope, as directed, and untouched:** the three load-induced timeout flakes; the
`JSONDecoder`-per-row finding at `JSONValue+GRDB.swift:36`
([472](472-the-feed-gets-a-model-of-its-own.md)); issue 23C's signing work;
`.github/workflows/ci.yml` (decision 9C).
