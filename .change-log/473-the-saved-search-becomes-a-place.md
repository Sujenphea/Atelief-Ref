# 473 — the saved search becomes a place

[099 · P4](../.docs/099-mac-backlog-plan.md) closes one of the user's own backlog
items, and it is the bluntest one on the list: *"Smart collections UI. Saved searches
exist only in the core package with zero references in the app, so they are
unreachable."*

That was exactly true. `AppServices+SavedSearches.swift` has carried
`createSavedSearch`, `savedSearches`, `renameSavedSearch`, `updateSavedSearchRules`,
`deleteSavedSearch`, `evaluateSavedSearch`, `evaluate(rules:)` and
`savedSearchMissingTags` since 015, all migrated, all covered by
`ServicesSavedSearchTests` — and until this commit **the string `savedSearch` did not
appear in a single app-target file except a doc comment and a test fixture.** The
feature was finished and had no door.

This phase is the door. It honours
[057](../.docs/057-smart-collections-overview.md) as written, with one thing 057
claims that turned out not to be true — see *the archive*, below, which is the finding
of this phase rather than a footnote to it.

## 7A — a SwiftUI section, and the trigger for the coordinator that was not written

`SidebarItem.savedSearch(UUID)` is a top-level destination beside `.collection` and
`.space`, for the reason 057 rejected a `type` flag on the `collection` table: a saved
search has no memberships, no manual order, no nesting and cannot hold a drop, so
putting it in the collections tree would make every collection consumer grow a
discriminator check (057's own citation of the 005 O3 lesson).

The Smart section sits below Spaces and is **SwiftUI**, which is decision 7A. The two
AppKit outlines above it each exist for one thing this list does not do: live drag
reorder, and — for collections — nesting. 057 · open question 2 keeps the list flat
"until it hurts"; a query has no `sortIndex` to drag into at all. Everything else those
coordinators buy is already shared: the row chrome is `Theme` tokens, and the inline
rename runs through **`SidebarEditState`**, the same pure state machine, so Escape
cancels, an empty name cancels, and a rename that ends on the name it started with
writes nothing — no spurious `updated_at` bump, no undo entry that reverses nothing.

**The trigger for extracting a generic outline coordinator is A THIRD REORDERABLE
SIDEBAR LIST.** Writing it down is part of the deliverable, so here it is with its
reasoning. Two are not evidence of a pattern: `CollectionsOutlineView` and
`SpacesOutlineView` already share every primitive that CAN be shared (`SidebarOutlineKit`
— the outline subclass, the row view, the cell, the draft cell, the edit state, the
block menu item), and what is left in each is its data source and its drag routing —
which is precisely the part a generic coordinator would have to be parameterised over.
Parameterising two implementations costs about what the second implementation cost.
A third makes it cheaper than the copy. **This section is not that third**, because it
does not reorder, and a coordinator generic enough to cover a list with no drag at all
would be generic over the one thing the other two are actually for.

The section header takes no "+". A smart collection is created by SAVING A SEARCH
(057: the search field IS the rule editor), so a "+" there would have to open a rule
builder this version deliberately does not have.

## The grid is the read model's saved-search feed

[472](472-the-feed-gets-a-model-of-its-own.md) closed by saying its real claim —
*"a second window can now have its own feed without touching the writes"* — was
demonstrated by a stub and by the shape, not by a second window, and that the first
real one would be P4's. `SmartCollectionView` is it: a `@StateObject`
`CollectionReadModel` on `CollectionFeed.savedSearch`, its own `GridSelectionStore`,
and not one line of `IngestionModel`'s feed. The shape held. Nothing in the read model
had to change to mount a second one, which is the thing 1A was for.

**Sort is 007's modes minus `.manual`, and it is derived rather than typed out.**
`SmartCollectionSort.offered` is `SortMode.allCases.compactMap(SmartCollectionSort.init)`,
so a fourth mode 007 adds lands in `offered` or in `excluded` the day it is added, and
`SmartCollectionSortTests` asserts the exclusion is exactly `{ .manual }` and that the
two lists partition `SortMode.allCases`. A hand-written list would have gone stale
silently, which is 057's own "rule drift" risk arriving by a different road.

The sort has to be applied over the fetched page, and that is worth stating because it
looks like a shortcut and is not. `evaluate(rules:)` passes no `sort:` at all — sort is
display, not part of what a saved search MEANS (`SearchRules`' own header says so), and
`searchAssets`' `SearchSort` has only `.newest` and `.relevance` anyway. So `.newest`
IS the service's order untouched, and `.mostViewed` is `mostViewedSorted` — the
comparator `MostViewedReorder.swift` exists to keep byte-identical with core's
`view_count DESC, created_at DESC, id DESC`. Split out of `mostViewedReorder(items:bumps:)`
with no change to what it does, because a second `sorted(by:)` beside it would be the
divergence that file's whole header is a warning about.

Everything else the grid does is what 057 says:

* **No drag-reorder.** `canReorder: false` on the host, AND `applyReorder` returning
  `nil` on a membership-less feed. Both, deliberately: the flag stops the live preview
  ever *promising* a reorder, the model stops one being *applied* if some other path
  asked. `SmartCollectionExclusionTests` adds a third — `routeDrop` refuses a
  membership-less payload at a slot in every `SortMode`.
* **No ⌫**, no ⌘V, no drop target. A hit belongs to the query, not to a container, so
  "remove it from where you are looking" has no answer — search results and the shelf
  already gave that answer, and this is the third surface to give it.
* **Drag-out and drag-to-a-collection still work**, which 057 is equally explicit
  about. They carry `AssetDragPayload.nilSourceID`, so `routeDrop` resolves every
  landing as a **copy**: there is no collection to move OUT of. That is not a
  weakening of 057's "drag-to-move still works" so much as the only thing it can mean
  without a source, and it is the existing, tested rule for every membership-less
  surface (009 · N3's `sourceless` arm).

**057's own named test is `savedSearchItemThatStopsMatchingVanishes`.** The saved
search is `favoritesOnly`, so un-starring a hit is the smallest real way to make an
item stop matching without deleting it: the asset stays in the library and in its
collection, and the only thing that changed is whether it answers the query. Both hits
are selected first, one is un-starred, the feed reloads — the row is gone, the selection
is pruned to the survivor, the lead does not point at a row that left, and the
collection still holds all three items. Which is 057's *"an item can legitimately
vanish mid-triage… the grid animates removal rather than pretending"*, asserted.

## "Save this search…", and the fact that it has two meanings

The control lives beside the search field on every pane, disabled while the query is
empty. What it DOES is a pure function, `saveSearchAction(isActive:sidebar:)`, because
057 settles creation and editing in one sentence — *"Save this search" … + rename/edit-
by-rerunning-and-resaving* — and that makes the destination the decider:

| where you are | the control |
|---|---|
| anywhere else | `.save` — name it, create it, navigate to it |
| an OPEN smart collection | `.update(id)` — replace THAT search's rules, no name prompt |

Prompting for a name on the update path would invite two searches called the same
thing, which is not what "re-run and re-save" means. The button's title says which it
is (`Update “Serif”`), so the two cannot be confused at the moment of pressing.

Both paths clear the field afterwards, and that is not tidiness: the pane behind the
results grid is now running exactly this query, so leaving the grid up would show the
same rows twice with only one of them named — and on the create path the navigation
would land behind a live query.

The rule is built by **P1's bridge**, `SearchRules(query:)`, over a new
`LibrarySearchModel.keywordQuery` — the keyword-shaped query extracted out of
`runSearch` so there is ONE construction rather than two. Two would be 4A's own drift
risk one level up. Two consequences fall out and are asserted rather than assumed:

* the half-typed `tag:` needle does **not** cross (it is an input method, and 4A's
  allowlist already named it), so `tag:edit` saves as a rule that says nothing about
  tags rather than one that says "edit";
* a `.meaning` query saves as its keyword FILTERS. A `SearchRules` has no
  semantic-mode field and cannot usefully grow one — `evaluate(rules:)` runs
  `searchAssets` for every saved search — so what is persisted is the part of the
  query that is a filter, which is all a rule has ever meant.

⌘S carries it, recorded in `KeyMap` as a **`.global`** row, which is what it honestly
is: a `ToolbarItem` lives on the scene, not inside the field, so its `keyboardShortcut`
fires wherever the keyboard is. It is disabled whenever the query is empty — most of
the time — and there is nothing else in this app called "save", which is what leaves
⌘S free for the one thing there is. `KeyMap.scope(forSidebar:)` answers `.collection`
for a smart collection: the pane IS a collection grid (same host, same `gridKeyCommand`,
same arrows / ⌘A / Esc / ⌘± / `E`), and a second sheet section restating those rows
would be a copy that drifts. The two rows that section carries which a saved search
does not bind — ⌫ *Remove from this collection* and ⌘V *Paste into this collection* —
are the two verbs that need a membership, and both are inert here rather than wrong.

## The badges

`SmartCollectionBadge` is one value with two cases, rendered by one view
(`SmartCollectionBadgeLabel`) on both the sidebar row (glyph + tooltip) and the grid
header (glyph + sentence), so the two surfaces cannot describe the same search
differently — 316's "two lists, one of them unseen", avoided by having one.

* **`.missingTags(count:)`** — `savedSearchMissingTags(id:)`, which has existed in
  Core since 015 with no caller. The search STILL RUNS: `evaluate(rules:)` drops the
  missing conjunct and the surviving tags filter, so without the badge the result set
  would simply be quietly wider than the name promises.
* **`.unreadableRules`** — a `rules` blob that will not decode at all. It cannot run;
  `evaluateSavedSearch` throws `.invalidSavedSearchRules`, and the empty state says so
  rather than "nothing matches", which is the lie an unexplained empty grid tells.

`stillRuns` is the property that keeps those two apart, and the badge decides the
pane's empty state as well as the row's glyph.

**One production bug was found by writing these tests and is fixed here.** Every verb
set `lastError` and then reloaded — and the reload's own `lastError = nil` on success
wiped it. A rejected rename therefore reported nothing at all while quietly not
renaming anything. The verbs now run through `perform(_:on:_:)`, which reloads (the
list is the database's, whatever the verb did) and then re-states the failure.
`renameRejected` is the test that caught it.

## Exclusion, asserted not assumed

057 states most of what a smart collection is by saying what it is NOT, and every one
of those rules lives in the ABSENCE of code — an `.onDrop` nobody attached, a row
nobody appended. An absence is exactly what a refactor deletes without failing
anything, so `SmartCollectionExclusionTests` writes each as a positive claim over the
real code path:

* a library holding two collections (one nested), Unsorted and two saved searches
  produces a `destinationTree` / `moveTargetTree` / `folderMoveTargets` whose ids are
  the collections' and contain neither search — the one tree every `CollectionTargets`
  consumer resolves through;
* `SidebarItem.acceptsAssetDrops` is a `switch` with no `default`, walked over every
  case, so a new destination cannot be added without deciding;
* `routeDrop` copies and never moves, ⌥ or no ⌥, and never resolves a reorder slot;
* `canvasDropRoute` still PLACES a smart-collection drag on a board (drag-out works)
  while `CanvasDropContents` has no case for a saved search at all — the exclusion
  there is in the type rather than in a guard;
* the three `CardTint` shades differ, because "a distinct tint" that quietly resolved
  to the same colour twice would look exactly like a card given the wrong kind.

Home's cards come AFTER the real collections, additive like Spaces (no heading at all
in a library with no saved searches), and always draw the placeholder branch — a query
has no cover, because `Set as Cover` writes `collection.cover_asset_id` and there is no
collection. `CoverCard`'s `accent: Bool` became `tint: CardTint` for that: a third
state needed a third value, and two booleans could have disagreed. The three shades are
three steps of the same grey ladder (`mediaBackdrop` → `field` → `selection`), which is
what "a distinct tint" has to mean in a palette that states it has no accent hue.

The Home cards are deliberately **not** marquee-selectable. Home's ⌘⌫ runs
`deleteCards(collectionIDs:spaceIDs:)` — two kinds, each with its own recoverable
delete. A saved search has neither an undo nor a third parameter, and sweeping queries
up in a marquee aimed at pictures is not a trade worth making. Delete is on the card's
own menu, where it is aimed.

## P3's three handoffs

**1. The badge path.** Built, above. `CollectionFeed.savedSearch` still surfaces
`.notFound` and `.invalidSavedSearchRules` as a `lastError` sentence — that is what a
grid does with a failed load and it is right — but the two badges now have a value, a
view and two places to draw.

**2. `dragPayload` stamped `selectedFolderID`.** Fixed. It now stamps `dragSourceID`:
the loaded feed's id when the feed carries memberships, `nilSourceID` when it does not.
The two fields are different questions — `selectedFolderID` is *where the next paste
lands*, `loadedCollectionID` is *what these rows came from* — and `sourceCollectionID`
is read by `routeDrop` to decide MOVE vs COPY and by `DropTarget.slot` to decide whether
a drag is a reorder at all. In one window on a collection they agree, which is why the
bug was invisible; the moment they do not — an undo has repointed the import target, or
a second window is showing something else — a drag out of the grid would have moved
items out of a folder the user was not looking at. `dragSourceIsTheFeed` makes the two
disagree and asserts which one the drag carries.

**3. The trailing run was not cancellable.** Fixed, and the smaller half is the one
that matters. The `Task` now captures `[weak self]`, so a model that goes away
mid-window is no longer kept alive inside its own debounce — that is the retention P3
named. The handle is what makes it *assertable*: `trailingReloads` holds the task,
`hasPendingIngestReload(touching:)` reads it, `cancelPendingIngestReloads()` drops it.
Cancelling also has to tell the coalescer, or the key stays marked as owing a run and
every signal for the rest of that window answers `.held`, waiting on a task that no
longer exists — hence `Coalescer.cancelTrailing(_:)`, which frees the key WITHOUT
moving `lastRun`, because nothing ran. `cancelPendingIngestReloads()` has no production
caller today: `IngestionModel` still lives as long as the process, and the short-lived
model this phase introduces is `CollectionReadModel`, which does not use the coalescer.
It is the teardown seam for the window that will.

## The archive — 057 says it is portable, and it is not

The brief said, from the plan, that *"the archive manifest already carries `saved_search`
rows (doc 081)"*, and asked for the round trip to be confirmed rather than assumed.
Confirmed: **it does not.** `ArchiveManifest` carries `sources`, `assets` and
`collections`, and no fourth list. [081](../.docs/081-backup-plan.md) never mentions
saved searches anywhere — the claim is 057's alone, written before the manifest was.

It was not simply added, and the reason is structural rather than effort. **A
`SearchRules` blob references TAG IDS, and the manifest deliberately carries no tag id
at all**: `TagEntry` is `(name, source)`, documented as *"No tag id — an importer mints
its own, so exporting ours would be data an importer must ignore."* The importer
likewise mints new collection ids and maps by key. So a rules blob copied verbatim into
a second library would point at ids present in neither its tag table nor its collection
table: it would import as a smart collection matching the wrong things, or nothing, and
then **badge itself as referencing deleted tags** — using the very badge this phase
just built. Making it work needs a rule-remapping design (tag ids in the manifest, or a
name-keyed rule translation) that no doc specifies, and inventing one under an "add the
case if it is missing" instruction would be the silent choice this plan's rules forbid.

So the gap is pinned instead. `savedSearchesDoNotYetCrossTheArchive` seeds a saved
search whose rules name a real tag and a real collection, exports, asserts the manifest
JSON contains neither `saved_search` nor `savedSearches`, imports, and asserts the
pictures crossed and the query did not. The day someone adds `saved_searches` to the
manifest, that test fails and whoever does it has to say what they did about the ids.
057's status block now says the same thing.

## Tests

**Forty-two added; `@Test` count 4,242 → 4,284 across the repo.** Nothing was removed
and no assertion was relaxed.

`SavedSearchesSidebarModelTests` (18) — `listsNewestFirst`, `loadedAndEmpty`,
`failedLoadKeepsTheList`, `renameWritesAndReloads`, `renameRejected`,
`updateRulesKeepsTheName`, `deleteStagesAndTakesOnlyTheQuery`, `cancelDeleteLeavesIt`,
`badgeForMissingTag`, `noBadgeWhenEveryTagIsLive`, `badgeForUnreadableRules`,
`badgeSentences`, `reconcileOnDelete`, `reconcileOnDeletingTheLast`,
`reconcileIgnoresAnUnreadList`, `reconcileLeavesALiveSelection`, `fallbackIsScoped`,
`inlineRenameOutcomes`.

`SmartCollectionSortTests` (3) — `offeredIsSevenModesMinusManual`, `roundTrip`,
`labels`.

`SaveThisSearchTests` (7) — `unavailableWithAnEmptyQuery`, `savesFromAnywhereElse`,
`reSavingUpdatesTheOpenSearch`, `savedRuleIsTheFilters`, `theTagNeedleDoesNotCross`,
`meaningQuerySavesItsFilters`, `emptyFieldIsNotActive`.

`SmartCollectionExclusionTests` (8) — `savedSearchesAreNotDestinations`,
`sidebarDropTargets`, `smartDragCopiesNeverMoves`, `smartDragNeverReorders`,
`smartDragPlacesOnABoard`, `dragSourceIsTheFeed`, `membershipLessFeedDragsSourceless`,
`cardTintsDiffer`.

`CollectionReadModelTests` (+2) — `savedSearchItemThatStopsMatchingVanishes` (057's
named test), `savedSearchFeedSorts`.

`CoalescerCancellationTests` (3) — `cancelTrailingFreesTheKey`,
`cancelTrailingOnAnIdleKey`, `pendingIngestReloadIsCancellable`.

`LibraryArchiveRoundTripTests` (+1) — `savedSearchesDoNotYetCrossTheArchive`.

Two notes on how they are written. **No wait is a sleep** (099 · 11A): the read-model
tests await `CollectionReadModel.events` through `EventRecorder`, and the sidebar
model got its own `EventSignal` for the same reason. And **`savedSearchFeedSorts`
asserts `.newest` against the SERVICE's order rather than against a list retyped in the
test** — three colours ingested in one millisecond tie on `created_at` and fall through
to `id DESC`, which a test has no business predicting. It failed exactly once that way
before the assertion was rewritten, which is the flake caught at writing time instead
of on somebody else's gate run.

## The gate

`./scripts/verify.sh` full, fourteen stages, **exit 0 on the first run** against this
exact code diff — no stage re-run, nothing skipped:

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

`⚠ Extension` is the stale Instagram drift fixture, non-fatal by design since `b24c010`.

### …and then the machine stopped launching the app, and it is NOT this diff

Only markdown changed after that run — this file, 099's status row, 057's status block —
and the gate was run again as a formality. It went red, and kept going red. The sequence,
because "re-run it once and say so" is the rule and this went past once:

| run | result |
|---|---|
| 1 (full) | **exit 0**, 14/14, the block above |
| 2 (full) | ✗ `CanvasRenderer`, ✗ `App target (UI)` |
| `CanvasRenderer` alone | **green** — 437 tests, 52 suites |
| `App target (UI)` alone | ✗ 2 of 3 |
| **`App target (UI)` on `HEAD`, this phase's work stashed** | **✗ 3 of 3** |
| 3 (full) | ✗ `App target (UI)` only — 3 of 3 |
| `App target (UI)` alone, again | ✗ 3 of 3 |

**The control run is the answer.** With every change of this phase stashed — a tree
identical to `e4181e1` — the UI stage fails all three flows, one MORE than it fails with
the diff applied. And the failure text moved from an assertion about content to
`"the app opened no window"` on all three, including
`testCommandCommaOpensASettingsWindow`, which never touches a collection, a saved search
or anything else this phase wrote. The app under test stops LAUNCHING; nothing in a diff
can do that selectively to a stage that signs differently from the two beside it.

That is the ad-hoc-signing blocker [470](470-the-second-cache-takes-the-same-seam.md)
diagnosed and [471](471-the-token-leaves-the-main-actor-at-launch.md) cleared once
already: this stage is the one stage that must sign ad-hoc (468), every rebuild presents
a fresh signature, and an unattended `xcodebuild` cannot answer what the system raises in
response. 471 removed the keychain read that made it a 30-second hang; it did not — and
could not — retire the prompt itself, which 471 says in as many words. Load average sat
between 4.5 and 7.5 across these runs, all of it this session's own builds.

`CanvasRenderer`'s single failure in run 2 was `CanvasBenchmark.testFrameUpdateWithinBudget`
at 9.04 ms against an 8.33 ms budget — a wall-clock perf assertion in a package this
phase does not touch, green in isolation immediately after, and green again in run 3.

**What this leaves for the user, and it is the same thing 470 left:** the UI stage on
this machine needs either the prompt answered at the keyboard, or a fresh login session.
Until then it will report a red gate for every phase that rebuilds the app, whatever the
diff contains. The thirteen stages that do not sign ad-hoc are green on every run above,
`App target` and `App target (Release)` included.

## Files changed

* **new** `AtelierRefs/AtelierRefs/SmartCollections.swift` — `SmartCollectionSort`,
  `SmartCollectionBadge`, `SaveSearchAction` + `saveSearchAction(isActive:sidebar:)`,
  and `SavedSearchesSidebarModel`.
* **new** `AtelierRefs/AtelierRefs/SmartCollectionView.swift` — the pane, and
  `SmartCollectionBadgeLabel`.
* **new** `AtelierRefs/AtelierRefsTests/SavedSearchesSidebarModelTests.swift`,
  `SmartCollectionExclusionTests.swift`.
* `NavModel.swift` — `SidebarItem.savedSearch`, `openSavedSearch`,
  `reconcileSavedSearches(using:hasLoaded:)`, `fallBackFromSavedSearch`,
  `SidebarItem.acceptsAssetDrops`.
* `SidebarView.swift` — the Smart section; `sectionHeader`'s "+" became optional.
* `AppShellView.swift` — the `.savedSearch` route and the delete reconcile.
* `CollectionsGalleryView.swift` — Home's Smart section, its card and its menu.
* `LibrarySearch.swift` — `keywordQuery` extracted out of `runSearch`; the save
  control, its alert and its two commit paths.
* `CollectionReadModel.swift` — `savedSearch(_:sort:limit:)`.
* `MostViewedReorder.swift` — `mostViewedSorted` split out.
* `IngestionModel.swift` — `smartCollections`, the two observation hops, `dragSourceID`,
  the cancellable trailing reload.
* `Coalescer.swift` — `cancelTrailing(_:)`.
* `ContentView.swift` — the shared delete confirmation.
* `SharedThumbnail.swift` — `CardTint`; `CoverCard.accent` → `tint`.
* `KeyMap.swift` — the ⌘S row, and `.savedSearch` → `.collection`.
* `.docs/099-mac-backlog-plan.md` — P4's status row and a Done note under its section,
  including the correction to its archive bullet. **P3's row is corrected too**: it
  still read *"not started"* while its own section above it reads *"· **done**
  ([472])"*. That is a clerical slip rather than a decision, and a status table the
  next phase reads should not disagree with the section it summarises.
* `.docs/057-smart-collections-overview.md` — a status block: what V2 shipped, the
  archive claim that is not true and why it was not made true, and open question 1
  answered (yes, in the rail; read-only, non-drop).

## What is still NOT covered

**Saved searches do not survive an export.** Named above, tested as a gap, and it is
the largest thing this phase leaves. Until the manifest carries a rule-remapping shape,
a user who restores a library gets their pictures and loses their queries. Nothing in
the app tells them that, either — the import report counts assets and collections and
has no line for a thing it never carried.

**There is no rule builder, and 057 says there should not be — but the consequence is
sharper now than when it was written.** The search field cannot express a platform,
`tagMatch: .any`, or `colorMatch: .all`, so a rule that carries one can be created only
by hand and, once created, can never be re-saved from the field without losing it: the
update path replaces the WHOLE blob with `SearchRules(query:)`. `SearchRulesBridge`
already names `platform` as the reverse gap; this phase is what makes that gap
destructive rather than merely invisible. A rule the field cannot express should
probably refuse to be re-ruled, or warn — and neither is built.

**The results are capped at 500 and nothing says so.** `CollectionFeed.savedSearch`
takes the search grid's limit, so a query matching 2,000 items shows 500 of them and
the header says "500 items" as though that were the answer. The collection grid has the
same cap and the same silence (071 is the doc that owns paging), so this is not new —
but a smart collection is the surface where a user is most likely to write a query that
matches everything.

**The count is the loaded page, not a `COUNT`.** 057 specifies *"Result count on the
card is one `COUNT` query (cheap; cache per gallery visit)"*. Home's smart cards show
no count at all — they show a subtitle. Adding one means either a count query per card
per gallery visit, or evaluating every saved search on every Home render; the first is
what 057 asks for and the second is what a naive read would do. Neither is built, so
the cards are honest about showing nothing rather than wrong about showing a number.

**The badge is refreshed on a load, not on a tag delete.** `SavedSearchesSidebarModel`
reloads on library open, on a sidebar re-mount and after each of its own verbs. It does
not follow `libraryChanged`, so deleting a tag elsewhere leaves the badge stale until
one of those happens. Following the change stream would re-read the whole
`saved_search` table plus an `IN` query per row on every asset move, for a badge that
changes when a tag is deleted — which the app has no UI for today.

**`SmartCollectionView` has no Quick Look and no `M` / `A` keys.** Quick Look matches
the search grid's own gap (a parity gap, noted there since 048). `M` / `A` are absent
because `onDestinationVerb` is `nil`: `M` has no meaning without a source, and binding
`A` alone would leave the pair half-bound. The right-click *Add to Collection* submenu
is the whole destination affordance here.

**The sidebar's Smart rows have no keyboard.** The two AppKit outlines get ↑/↓, →/←
and Return-to-rename from `NSOutlineView`; a SwiftUI `ForEach` of buttons gets none of
them, and `KeyMap`'s `.sidebar` rows still cite `CollectionsOutlineView`. Rename is
reachable from the context menu on both surfaces, so nothing is unreachable — but the
section is keyboard-poorer than its neighbours, and that is the cost decision 7A bought
the simplicity with.

**No smoke flow opens a smart collection.** The fixture library seeds one, so the
section and the card render during all three existing flows, but nothing clicks either.
P5's ⌘K flow is the natural place to add one, since a saved search is a switcher
candidate there.

**No smoke flow can run on this machine any more, and that is not this phase's.** The
gate section above has the six-run sequence and the stashed-`HEAD` control. It is worth
repeating here because it is what the next phase will meet first: `App target (UI)` is
red until the ad-hoc signing prompt is answered at the keyboard, and it is red on `HEAD`
too.

**The three load-induced timeout flakes are untouched**, as directed:
`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests`
remain the recorded risk from [469](469-the-cache-that-was-never-promised.md) and
[470](470-the-second-cache-takes-the-same-seam.md). So is the `JSONDecoder`-per-row
finding 472 recorded at `JSONValue+GRDB.swift:36`, which this phase's saved-search reads
pay exactly as the collection reads do.
