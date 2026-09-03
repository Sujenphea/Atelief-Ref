# 476 — the palette is the second window

[099 · P6](../.docs/099-mac-backlog-plan.md) closes a backlog line the user wrote with
its own evidence attached: *"Floating always-on-top reference palette. Not started; the
app still declares one window group."*

**The claim was checked before anything was written, and it was true.**
`AtelierRefsApp.swift` declared exactly two scenes: one `WindowGroup { ContentView(…) }`
and the standard `Settings { SettingsView(…) }`. No `Window`, no second `WindowGroup`,
no `MenuBarExtra`, no `openWindow` call anywhere in the target. Every auxiliary surface
the app had — the snapshots sheet, the duplicates sheet, the shortcuts sheet, ⌘K's
panel — was raised INSIDE that one window, and P5's `SwitcherPanel` is the clearest
case: it is an `NSPanel` that is a CHILD of the shell precisely because there was no
second scene to be.

There is now: `Window("Reference Palette", id: "palette")`, at
`.windowLevel(.floating)`, a 360 × 620 strip, resizable, hidden title bar.

## Why `Window` and not `WindowGroup`, which is what the doc asked for

[011](../.docs/feature-todo/011-ux-features.md) · Cluster D sketches
`WindowGroup(id: "palette", for: Space.ID.self)`, and the same bullet list rejects
*"pinning multiple palettes (one window, one focus)"* two lines later. Those two
sentences cannot both be honoured: a `WindowGroup` opens a NEW instance for every
`openWindow(id:)`, so "one window" would have had to be a rule enforced somewhere —
a flag, a check, a controller — and a rule enforced by code is a rule that can be
broken by code.

A `Window` scene raises the one instance that exists. So *one window, one focus* stops
being a promise and becomes a property of the scene graph, and there is nothing to
test because there is nothing that could go wrong. The UI flow says so where it would
otherwise have asserted a window count: *"asserting a window count after a second press
would be testing SwiftUI."*

The `for: Space.ID.self` half goes with it. What the palette shows is app-level state
that outlives any particular window (`PaletteModel`), remembered per library — not a
value carried in a window's identity.

## A Space in the palette is NOT in v1, and the reason is structural

Cluster D says *"one chosen space or collection"*. This ships the collection half plus
saved searches, and refuses the Space.

Not for effort. `MasonryGridHost` could be made read-only for the price of three flags
because its interaction is already routed through seams — a selection STORE, a menu
STYLE, a key DECODER — each of which has an "off". `CanvasHostView` is an editing model
end to end: `SpaceModel` owns placements, a selection, its own undo stack and a drop
router whose job is to write tile positions. "A board, read-only" is not a
configuration of that; it is a second renderer of the same data, and a second renderer
is a second thing to keep in step with every canvas change forever.

So the refusal is written down as `PaletteDestinations.canShow(_:)` — a `switch` with
**no `default`**, the discipline `SidebarItem.acceptsAssetDrops` and
`SwitcherRecents.token(for:)` already established for this enum. A new destination has
to answer for itself, and `canShowIsCollectionsAndSavedSearchesOnly` walks every case.
The day someone wants a board in the palette, the honest shape is a static
`CanvasRenderer` snapshot rather than a hosted `CanvasHostView`, and that is a design,
not a flag.

## ⇧⌘P, chosen against the map rather than picked

`KeyMap` is a description, and its collision test is the reason it exists — so the key
was resolved there before the command was written. The `.global` scope holds ⌘Z, ⇧⌘Z,
⌘N, ⌘⌫, ⌘[, ⌘,, ⌘/, ⌘S and — as of two commits ago — **⌘K**, which is exactly the near
miss worth naming: P5 added it in [475](475-the-switcher-is-its-own-surface.md), so
every ⌘-chord was re-read against the current table rather than against a remembered
one. The shifted rows in every scope are ⇧⌘Z (global), ⇧⌘], ⇧⌘[ and ⇧⌘E (all `.space`).

**⇧⌘P, and plain ⌘P is deliberately left alone.** ⌘P is Print on this platform, this
app has no Print item to argue with it, and a user who reaches for it out of habit
should get the system's answer rather than a palette appearing. `commandPIsFree` pins
that as an assertion, so a later phase that wants ⌘P has to delete a test to take it —
which is the point. `shiftCommandPIsTheReferencePalette` pins the other half: exactly
one row claims the chord, and it is `.global`.

`.global` is structural here, not a category. A menu key equivalent is matched by
`NSMenu` before the event reaches any first responder — the platform behaviour
`DeleteCommands` documents as a hazard and `GoToCommand` relies on — so ⇧⌘P opens the
palette from inside the item-detail overlay and from a Space board, both of which
swallow bare keys. It also has to work while the PALETTE ITSELF is key, which is why
`ShowPaletteCommand` is the one command in that file with **no** `@FocusedObject` gate:
the palette scene publishes no focused-scene values, so a gate would grey the item out
at exactly the moment a user pressed it to bring the palette back.

## The picker is P5's search. The seam it needed was two words

The brief was explicit: reuse P5's ranking, and if it needs a seam to be reusable, add
the seam and say so. It needed almost nothing, which is the interesting part.

`SwitcherRanking.results(for:in:recents:)` was already generic over a candidate ARRAY,
and `SwitcherModel.open(candidates:recents:)` already took one — so a second surface
that wants a different set of destinations was, structurally, already supported. The
palette owns a `SwitcherModel` and hands it a narrower list. **There is no second
ranking, no second cursor walk and no second row view.**

Two seams were added, both small:

* **`SwitcherRow` is internal rather than `private`**, and takes an optional
  `identifier` (defaulted to ⌘K's spelling). Two surfaces that search one list of
  destinations must not disagree about what a destination LOOKS like either; the
  identifier parameter exists because both pickers can be on screen at once and a UI
  flow that could not tell them apart would pass while reading the wrong one.
* **`PaletteDestinations.candidates(…)`** wraps `SwitcherRanking.candidates(…)` with
  one filter. It passes the spaces IN and then drops them, which is deliberate:
  handing the builder an empty array would make the exclusion invisible, and a bug
  would look identical to the decision. `aSpaceIsASwitcherCandidateAndNotAPaletteOne`
  drives both builders over the same library and asserts they differ in exactly that
  way, and `paletteCandidatesAreASubsequenceOfTheSharedOrdering` asserts the filter
  narrows without ever re-ordering — so the two pickers agree about which of two
  `Inspiration`s comes first.

`thePickerIsTheSharedRanking` goes further and compares the palette's live results
against `SwitcherRanking.results` computed directly, so a future "small tweak" to one
surface's ordering fails here rather than shipping two switchers that disagree.

**One deliberate difference: the palette's picker reads no MRU.** ⌘K's recents answer
*where have I navigated*; the palette's memory answers *what do I keep beside my work*,
and that is one destination, not a list. `thePickerDoesNotUseTheSwitcherMru` asserts the
resting order is the shared ordering alone, and — for contrast, in the same test — that
the same candidates WITH a recent do get boosted, so the assertion is about a choice
rather than about a list that happened to be empty.

**One finding to report rather than fix:** P5's ranking matches only the title and has
no subsequence tier, and the palette wanted neither differently. A palette picker is
opened by a button, over a list the user can see, on a narrower set of destinations than
⌘K's — if anything it needs LESS fuzziness, not more. The scope-filter was the whole of
the difference.

## What a drag out of the palette carries — the handoff that was load-bearing

This is the inherited item that mattered, and it has a three-phase history:

* **P3** stamped `selectedFolderID` — the IMPORT target — as a drag's source. Wrong in
  principle, invisible in practice: one window on a collection makes the two agree.
* **P4** ([473](473-the-saved-search-becomes-a-place.md)) corrected it to
  `contents.loadedCollectionID`, with `AssetDragPayload.nilSourceID` when the feed
  carries no memberships. Correct — and written on `IngestionModel`, which reads
  exactly ONE read model.
* **P6 opens a second window with a second feed.** Left where P4 put it, that rule
  would have re-created the very bug it fixed, one level up: a drag out of the PALETTE
  would have carried the MAIN WINDOW's collection as its source, and `routeDrop` reads
  a real source as permission to MOVE. Dropping a palette tile onto a sidebar row would
  have removed the asset from a folder the user was not looking at.

So the rule moved down to the object that can answer it: `CollectionReadModel
.dragSourceID` and `.dragPayload(forCellItemID:)`. `IngestionModel` forwards (no call
site changed), and `SmartCollectionView` stopped spelling `nilSourceID` itself — its
feed already says `carriesMembership == false`, so two statements that agreed today
became one that cannot drift.

**Concretely, a drag out of the palette carries:**

| the palette is showing | `sourceCollectionID` | what a drop does |
|---|---|---|
| a collection | that collection's id | move (or reorder, where offered) |
| a saved search | `AssetDragPayload.nilSourceID` | copy — there is nothing to move out of |
| nothing loaded yet | `AssetDragPayload.nilSourceID` | copy |

`PaletteDragSourceTests` pins it, and the assertion that would have caught the bug is
`twoWindowsDragFromTheirOwnFeeds`: two read models loaded on two collections, asked at
the same instant, answering with their own. `aPaletteOnASavedSearchIsSourcelessBesideACollectionWindow`
covers the mixed case. A rule living on the shared writing model could not make either
true.

## The read-only grid

`GridHostConfiguration` gains `interaction: GridInteraction`, three booleans:
`allowsSelection`, `allowsContextMenu`, `allowsKeyboard`. Defaulted to `.full`, so
**not one existing call site changed** — `fullIsTheDefault` asserts that against a
configuration built with nothing optional set.

Every grid before this said what it could not do by passing a no-op closure or a
narrower menu style, which works while "cannot" means "has nothing to act on" (search
has no collection to move out of; the shelf has no cover to set). The palette is the
first surface that is read-only as a DECISION, so the denial is stated positively and
once, rather than inferred from six closures that do nothing.

Four routes had to be closed, and they are four because AppKit delivers by four paths:

* `gridCellMouseDown` skips the selection routing — but still classifies the press,
  because a drag out of it is the one thing the palette does. It also stops taking
  first responder: there is no keyboard verb to focus for, and stealing the responder
  from the palette's picker would be a bug with no upside.
* `makeMarqueeController` is not built at all, so the three background-mouse handlers
  are structurally inert rather than fed and ignored.
* `gridMenu(for:)` returns `nil` — the same answer a right-click on a gap already
  gives, so there is no third state to draw.
* `gridKeyDown`, `gridPerformKeyEquivalent`, `gridDeleteCommand` and `gridCopyCommand`
  each return early. Four guards and not one, because ⌫ arrives by `deleteBackward:`
  off the responder chain, ⌘⌫ by `performKeyEquivalent` walking the VIEW hierarchy, and
  bare keys by `keyDown` — three different doors into the same room.

They return `false` rather than swallowing, which is the rule
`GridHostConfiguration.onDestinationVerb` states for one letter applied to the whole
keyboard: the event carries on up, so the palette window's keys and every menu
equivalent still work over the grid.

**Drag-out is deliberately not one of the flags**, and that is asserted rather than
assumed: `dragOutIsNotOneOfTheFlags` reflects over `GridInteraction` and requires that
no flag's name mentions dragging, and `readOnlyDeniesEveryFlag` requires that
`.readOnly` denies EVERY stored `Bool` there is — so a fourth flag added later fails
this test until `readOnly` answers for it.

The cell's enter-selection circle needed one more thing. It shows on hover, and on a
read-only grid that is an invitation to a gesture that does nothing — worse than no
circle. `CellSelectionState` gains `allowsSelection` and the rule became a pure
function, `showsSelectionCircle(hovered:)`, so it is a test and not a screenshot.

**Not a drop target either**, and for free: `canReorder: false` is what
`gridDraggingOperation` reads to refuse a hovering drag outright.

## Two smaller decisions worth stating

**The palette's density is its own — two columns, fixed.** `GridViewPreferences` is
global on purpose (011-B2: one muscle memory across every collection), but it stores a
COLUMN COUNT, and a count chosen for a 1400pt window renders 30pt cells in a 360pt one.
The palette pins two and offers no ⌘±, which is also the honest reading of "no keyboard
verbs".

**Carousels are ungrouped in the palette**, and this one is correctness rather than
taste: a collapsed post hides its other members behind a chip, the chip is an
interaction, and a read-only grid has none — so grouping would leave some assets
undraggable. Every image is its own tile.

## The memory: `library.<id>.paletteDestination`

The fourth preference to take 016 §C's `library.<id>.` prefix (the clipboard toggle,
the backup cadence, ⌘K's MRU, this), and `keyMatchesTheSwitcherRecentsShape` compares it
against `SwitcherRecents.defaultsKey(libraryID:)` directly rather than restating a
format string — [475](475-the-switcher-is-its-own-surface.md)'s rule, so the day someone
changes the namespace they change it in both places or fail.

**The stored value is a `SwitcherRecents` token**, not a second encoding of a
destination. `collection:<uuid>` written two ways in two files is how a rename of one
silently orphans the other; `theStoredValueIsASwitcherToken` asserts the sharing.
A token that no longer parses, or that names something the palette cannot show — a
`space:` row hand-edited into the plist, or one persisted by a later version — is
dropped and the palette opens on its picker.

Two rules around it are each a test because each is a way the feature stops being true:

* **Nothing is written before the library id resolves.** `SwitcherRecents.record(_:)`'s
  rule and 016 §C's: writing to an un-namespaced key "for now" is exactly the migration
  the prefix exists to avoid. The palette still SHOWS the destination for that session.
* **`reconcile` will not run against an empty folder list.** Every library has an
  Unsorted row, so an empty list means the library has not published yet — and
  reconciling against it would drop the restored destination on every launch, which
  looks exactly like the memory not working.
  `reconcileBeforeTheLibraryPublishesKeepsTheDestination` is the guard, and it is the
  single most likely way a future edit breaks "remembers what it last showed".

## How the window is asked for, twice, for two different reasons

⇧⌘P calls `openWindow(id:)` directly from the menu command. "Open in Palette" on a
sidebar row cannot: the collections tree is an `NSOutlineView` and its row menu is built
by `CollectionsOutlineCoordinator`, which can set model state and cannot call a SwiftUI
environment action. So it calls `PaletteModel.show(_:)`, which records the destination
and bumps `openPulse`; the shell observes the pulse and raises the window. One place
decides WHAT the palette shows; two places ask for the window, because the two asks are
different — one opens the palette, the other opens a destination in it.

`openPulse` is a **counter, not a flag**, and `showRaisesTheWindowEveryTime` says why:
two "Open in Palette" clicks on the same row must both raise it, and a boolean would
need whoever consumed it to reset it — which is how the second click comes to do
nothing. The picker inside the palette commits through `choose` instead, which does NOT
pulse: the window is already up, and an always-on-top window that orders itself forward
over the app you are designing in is the one thing it must not do unasked
(`chooseDoesNotRaiseTheWindow`).

"Open in Palette" sits ABOVE the Unsorted guard in the outline's row menu, deliberately:
Unsorted is protected from rename, move and delete because those change it, and looking
at it changes nothing. It is also the one collection that is always there, so refusing
it would be the palette's least explicable gap.

## The smoke flow: written, and NOT gated — and not runnable either

`testShiftCommandPOpensTheReferencePalette` is written:
⇧⌘P → a second window carrying the palette's control → its picker → type `Concrete` →
Return → the palette names `Concrete` while the main window is still on Home.

That last clause is the flow's reason for existing. "A second window exists" is what the
⌘, flow already asserts; what a palette claims that nothing in this app claimed before is
that **two windows can show different feeds at the same time** — which was the point of
099 · 1A's per-window read model and could not be demonstrated until there was a second
window to demonstrate it in.

**It will not gate anything, and it could not be observed passing.** Both facts, plainly,
as [475](475-the-switcher-is-its-own-surface.md) put them:

1. [474](474-the-gate-stops-claiming-a-window.md) took `App target (UI)` out of
   `verify.sh full` (issue 23D). Nothing runs this flow unless a person types
   `./scripts/verify.sh ui`.
2. That command cannot succeed on this machine (issue 23C): the runner must sign
   ad-hoc, an ad-hoc signature's designated requirement is the exact cdhash, and every
   rebuild is therefore a binary macOS has never granted automation to. P5 established
   this with a control run on an unchanged tree and this phase did not re-litigate it.

**Two things the flow would not have asserted even if it ran**, named in its own doc
comment rather than left to look like coverage:

* **`.windowLevel(.floating)`.** It is a scene modifier with no accessibility surface —
  XCUITest can ask a window for its frame and its elements, never its `NSWindow.Level`.
  There is no assertion to write. **A person should drag the palette over another app
  once before trusting it.**
* **That a second ⇧⌘P does not spawn a second palette.** It cannot: a `Window` scene has
  one instance by construction. Asserting a window count would be testing SwiftUI.

The real weight is in `swift test`, as directed.

## Tests

**Forty-two added; `@Test` count 4,334 → 4,376 across the repo.** Nothing was removed
and no assertion was relaxed.

`PaletteModelTests` (23) — `canShowIsCollectionsAndSavedSearchesOnly`,
`aSpaceIsASwitcherCandidateAndNotAPaletteOne`, `fixedDestinationsAreNotPaletteCandidates`,
`paletteCandidatesAreASubsequenceOfTheSharedOrdering`, `thePickerIsTheSharedRanking`,
`thePickerDoesNotUseTheSwitcherMru`, `feedIDOfEachDestination`,
`keyIsNamespacedByLibrary`, `keyMatchesTheSwitcherRecentsShape`,
`theLastShownDestinationIsRemembered`, `aSavedSearchIsRemembered`,
`twoLibrariesDoNotShareADestination`, `showBeforeActivateWritesNothing`,
`anUnshowableStoredTokenIsIgnored`, `anUnparsableStoredTokenIsIgnored`,
`theStoredValueIsASwitcherToken`, `showRaisesTheWindowEveryTime`,
`chooseDoesNotRaiseTheWindow`, `unshowableDestinationsAreRefused`,
`reconcileForgetsADeletedCollection`, `reconcileForgetsADeletedSavedSearch`,
`reconcileKeepsALiveDestination`, `reconcileBeforeTheLibraryPublishesKeepsTheDestination`.

`GridReadOnlyTests` (11) — `fullIsTheDefault`, `readOnlyDeniesEveryFlag`,
`dragOutIsNotOneOfTheFlags`, `deleteResponderIsInertWhenReadOnly`,
`copyResponderIsInertWhenReadOnly`, `keyDownFallsThroughWhenReadOnly`,
`performKeyEquivalentFallsThroughWhenReadOnly`, `noContextMenuWhenReadOnly`,
`hasSelectionIsFalseWhenReadOnly`, `theCircleIsGatedByAllowsSelection`,
`inertCellStateAllowsSelection`.

`PaletteDragSourceTests` (6) — `collectionFeedCarriesItsCollection`,
`savedSearchDragsCarryNoSource`, `anUnloadedCollectionFeedCarriesTheSentinel`,
`twoWindowsDragFromTheirOwnFeeds`,
`aPaletteOnASavedSearchIsSourcelessBesideACollectionWindow`, `aVanishedCellHasNoPayload`.

`KeyMapTests` (+2) — `shiftCommandPIsTheReferencePalette`, `commandPIsFree`. The
existing `noCollisions` covers the other half over the whole table and needed no change.

Plus one XCUITest, `SmokeUITests.testShiftCommandPOpensTheReferencePalette` — written,
ungated, unobserved. Not counted above because it is not a `@Test` and, more to the
point, because nothing runs it.

**No wait is a sleep** (099 · 11A). `PaletteDragSourceTests` awaits
`CollectionReadModel.events` through `EventRecorder` — it reuses
`CollectionReadModelTests.StubFeed` rather than writing a second one — and everything
else in the three suites is pure or a `UserDefaults` suite per test. The UI flow's one
new wait is `waitForLabel`, a state-change poll modelled on the file's existing
`waitForHittable`.

## The gate

`./scripts/verify.sh` full, thirteen stages, **exit 0** against this exact diff:

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

**No `project.pbxproj` change was needed, and that was checked rather than assumed.**
Both new source files and all three new test files join through
`PBXFileSystemSynchronizedRootGroup` — [471](471-the-token-leaves-the-main-actor-at-launch.md)
found the same thing. `xcodebuild -list` was run anyway and `git status` shows the
project file untouched.

## Files changed

* **new** `AtelierRefs/AtelierRefs/PaletteModel.swift` — `PaletteDestinations` (the
  scope `switch` and the filtered candidate list) and `PaletteModel` (the destination,
  the open pulse, the picker, the per-library memory).
* **new** `AtelierRefs/AtelierRefs/PaletteView.swift` — the window's content,
  `PaletteDestinationPicker` and `PaletteLayout`.
* **new** `AtelierRefs/AtelierRefsTests/PaletteModelTests.swift`,
  `GridReadOnlyTests.swift`, `PaletteDragSourceTests.swift`.
* `AtelierRefsApp.swift` — the `Window` scene, `ShowPaletteCommand` (View ▸ *Show
  Reference Palette*, ⇧⌘P, below Back behind a separator), and the app-level
  `PaletteModel`.
* `MasonryGridHost.swift` — `GridInteraction`, the configuration's `interaction` field,
  and the six guards.
* `MasonryGridItem.swift` — `CellSelectionState.allowsSelection` and the pure
  `showsSelectionCircle(hovered:)`.
* `CollectionReadModel.swift` — `dragSourceID` and `dragPayload(forCellItemID:)`, moved
  down from `IngestionModel`.
* `IngestionModel.swift` — both now forward; `openLibraryID` is published so an
  App-scene-owned model can bind its per-library preference.
* `SmartCollectionView.swift` — its drag payload comes from the read model; the
  `nilSourceID` spelling is gone.
* `AppShellView.swift` — the `openPulse` → `openWindow` bridge and the palette's
  library binding.
* `ContentView.swift`, `SidebarView.swift`, `CollectionsOutlineView.swift` — the palette
  threaded through, and "Open in Palette" on a collections-tree row and on a Smart row.
* `SwitcherPanel.swift` — `SwitcherRow` is internal and takes an `identifier`.
* `KeyMap.swift` — the ⇧⌘P row, `.global`, with the ⌘P note.
* `AccessibilityIdentifiers.swift` — `paletteDestinationButton`, `paletteField`,
  `paletteRow(_:)`, `paletteEmptyState`.
* `AtelierRefsTests/KeyMapTests.swift` — two rows for the chord.
* `AtelierRefsTests/CollectionActivationTests.swift` — one initialiser call site gains
  `palette:` (no assertion changed).
* `AtelierRefsUITests/SmokeUITests.swift` — the palette flow, `waitForLabel`, four
  fixture names.
* `.docs/099-mac-backlog-plan.md` — P6's status row and a Done note.
* `.docs/feature-todo/011-ux-features.md` — Cluster D's status block (the two departures
  from the sketch) and U6 marked shipped.

## What is still NOT covered

**Nobody has watched the palette float.** `.windowLevel(.floating)` is asserted by
nothing that runs on this machine and by nothing that COULD run: XCUITest cannot read a
window's level, and `verify.sh ui` fails before it starts (issue 23C). The scene
modifier is one line and it is the feature's entire premise. **A person should press
⇧⌘P once, drag the palette over another app, and look.**

**Nor has anyone watched a drag out of it.** The source id is pinned by six unit tests
and the file-promise path is `AssetFilePromiseProvider`'s, unchanged and already tested
— but "a tile dragged from the palette lands in Figma as a JPEG" crosses two processes
and a pasteboard, and nothing here can make that claim. It is the repo's standing
convention for media and drag (011 · Cluster A's own verification note), not a new gap;
it is worth saying because drag-out is the one thing the palette exists to do.

**The AppKit routing of the read-only flags is not exercised.** Four of the six guards
are asserted through the coordinator directly (`gridDeleteCommand`, `gridCopyCommand`,
`gridKeyDown`, `gridPerformKeyEquivalent`, plus `gridMenu` and `gridHasSelection`). The
two that are NOT are the mouse ones — `gridCellMouseDown`'s read-only arm and the
unbuilt marquee — because they need a solved layout in a live `NSCollectionView` in a
window, which `MasonryGridHostTests` has said is not headlessly reachable since 036. So
"a click in the palette selects nothing" is true by construction and by reading, not by
a test.

**The palette does not close on ⇧⌘P**, the same gap [475](475-the-switcher-is-its-own-surface.md)
records for ⌘K: a second press raises what is already raised. A toggle is the obvious
refinement and is not built. There is also no ⌘W handling written for it — the standard
close works, and re-opening restores the remembered destination, which is the behaviour
that matters.

**A Space in the palette is the named follow-up**, for the structural reason in this
entry's third section. The shape that would work is a static `CanvasRenderer` snapshot
rather than a hosted `CanvasHostView`; that is a design nobody has written.

**The palette has no scroll-position memory and no per-destination state.** Swapping
subject and swapping back starts at the top. The read model reloads from the database on
every `libraryChanged` that names its feed, as every other feed does, so a palette left
open all day re-reads; nothing measures what that costs on a large collection, and 072's
grid-scale work never considered a second concurrent feed.

**Nothing prunes a palette destination that is deleted while the palette is closed** in
the same session — `reconcile` runs from the palette's own view, so it needs the window
to be open to notice. The next launch handles it (the restored token names a collection
that is gone, the feed reports `.notFound`, and the first `folders` publish clears it),
but between a delete and the palette being opened the stored token is stale. It is a
plist string, not a leak.

**Out of scope, as directed, and untouched:** the three load-induced timeout flakes
(`PollTests/settlesEarly()`, `LibrarySearchModelTests`, `CollectionActivationTests`);
[472](472-the-feed-gets-a-model-of-its-own.md)'s `JSONDecoder`-per-row finding at
`JSONValue+GRDB.swift:36`; issue 23C, the runner's signing identity — still the single
change that would let P5's smoke flow, P4's, and this one actually run; and P5's two open
items (⌘K does not toggle shut, nothing prunes the ⌘K MRU).

**Two things noticed and not acted on**, for the record rather than the diff. First,
`.docs/feature-todo/011-ux-features.md`'s phased list still describes **U4** as *"the
switcher itself is outstanding"* — P5 shipped it and did not update that line; this
phase updated only its own (U6) rather than editing another phase's status on its
behalf. Second, `PaletteModel.activate(libraryID:)` is called from two places (the shell
and the palette) because the two need it for opposite reasons — the shell so "Open in
Palette" can persist before the window exists, the palette so ⇧⌘P works when the shell
is closed. It is idempotent and both calls are commented, but a third caller would be a
sign the binding wants to live somewhere else.
