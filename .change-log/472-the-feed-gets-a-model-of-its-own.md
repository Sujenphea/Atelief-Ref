# 472 — the feed gets a model of its own

[099 · P3](../.docs/099-mac-backlog-plan.md) is the plan's largest phase and the one P4,
P5 and P6 stand on. It carries four decisions — **1A** (a per-window `CollectionReadModel`
with an injected fetcher), **6A**'s collapse (one write funnel; navigation out of the undo
inverses), **13A** (a generalised `Coalescer`, plus 071 · Phase 0a as a measurement gate)
and **14A**'s app half (confirm the reorder path through the seam).

Everything below happened. One thing deliberately did **not**, and the reason is a number:
**071 §6.1's narrow summary row was measured, found not to be what the gate asked for, and
not built.**

## 1A — the feed moves out of the god-object

`IngestionModel` held ONE `items` array for the whole application. Every window, every pane
and every grid read the same object's single feed, so "what is on screen" and "what a write
just touched" were the same variable. `CollectionReadModel` is that feed, extracted:

```swift
@MainActor final class CollectionReadModel: ObservableObject {
    @Published private(set) var items: [CollectionItemDetail] { didSet { rebuildItemDerivations() } }
    @Published private(set) var loadedCollectionID: UUID?
    @Published private(set) var subfolders: [Collection]
    @Published private(set) var contentsVersion: Int
    var feed: CollectionFeed
    let selectionStore: GridSelectionStore
    func load(_ id: UUID)
    func follow(_ changes: some Publisher<UUID?, Never>)
}
```

It owns everything `rebuildItemDerivations` built — `postGroups`, `displayItems`,
`detailRun`, `itemsVersion`, `assetIDByItemID`, the selected-asset cache, `expandedPosts`,
`groupCarousels` — plus the two things that are *deltas against that array* and therefore
belong beside it: the pending Jump selection, and the not-yet-baked view counts that were
`pendingReorderBumps`. "Cleared whenever a load re-syncs `items`" is now one line of
`publish(_:for:)` rather than a rule two objects had to remember.

**`load()`'s race guard is 004's, moved verbatim.** It was read before it was moved: two
reads can finish out of order, so a stale one bails *before publishing anything* — including
before `lastError`, so a superseded failure cannot raise an alert about a collection the
user has already left. That last clause was already true and is now asserted.

### The fetcher is injected, and that is the point

```swift
CollectionFeed.collection(services, sort:)   // collectionItems(in:sort:includeArchived:) + childCollections
CollectionFeed.savedSearch(services)         // evaluate(rules:) behind the stored blob
CollectionFeed.idle                          // no library yet — publishes nothing at all
```

Rows are `CollectionItemDetail` either way, which the search-results grid has consumed
through `looseItems(for:)` since 048. The one thing that differs is `carriesMembership`, and
it is not decoration: `applyReorder` returns `nil` without touching anything on a feed that
has none, because [057](../.docs/057-smart-collections-overview.md) is explicit that a
saved search has no manual order. A saved-search feed also reports no subfolders — a query
is not a container — and carries its own `.notFound` noun, so the sentence a failed load
shows is the feed's rather than a `switch` at the call site.

`.idle` reads *nothing* rather than reading empty: a window built before the Library opens
must show the loading skeleton, not an empty collection that reads as "you have nothing
here".

### The ~300 call sites did not churn

`IngestionModel` keeps computed **forwards** — `items`, `subfolders`, `loadedCollectionID`,
`contentsVersion`, `displayItems`, `detailRun`, `postGroups`, `itemsVersion`,
`expandedPosts`, `groupCarousels`, `leadItem`, `selectedAssetIDs`, `actionTargets`,
`itemIDsForAction`, `assetID(forItem:)`, `displayTile`, `detailRunIndex`,
`toggleExpansion` — and republishes the read model's `objectWillChange` as its own. Nested
`ObservableObject`s do not compose on their own, and every one of the hundreds of views in
this app names `IngestionModel`; the forward is what keeps `model.items` a live read for all
of them, repainting at exactly the moments it did when `items` was `@Published` here.

They are **computed properties, never storage**, and `modelForwardsRatherThanCopies` asserts
it: if anyone reintroduces a stored `items` on `IngestionModel`, that test stops agreeing.
That is also why the **231** `model.items` / `model.displayItems` / `model.detailRun` reads
across the other suites (120 + 67 + 44) were left alone: they already assert the read
model's state, and rewriting each to `model.contents.items` would have been churn that
clarifies nothing and buries this phase's real diff in a rename.

## 6A — the boilerplate collapses, and navigation stops being a side effect

The **eight `apply*` workers** (`applyRename`, `applyMoveFolder`, `applyOrder`,
`applyReorder`, `applyRemove`, `applyRestoreMemberships`, `applyMoveAssets`,
`applyMoveBack`) and the **two `perform` overloads** are gone. In their place:

```swift
@discardableResult
private func performWrite(
    focus: UUID? = nil,
    reload scope: ContentScope,
    _ body: @escaping (AppServices) async throws -> Void
) async -> Bool
```

They differed in four ways and agreed on everything else: whether they refreshed the tree,
which collection they reloaded, whether they moved the selected folder, and — in the two
that reloaded a folder the window was not showing — whether they were right to. Those became
two parameters and a deleted mistake.

`mutateContents` went too. It had **zero callers**; its last one had left and nobody
noticed.

### The counted reload sites: 47 of 67, not 69

The plan said "the 69 internal reload sites become one `publishChange(...)`". Counted today,
under the widest reasonable definition — every call inside `IngestionModel.swift` to one of
its own reload entry points, excluding declarations and doc comments — there are **67**:

| entry point | sites |
|---|---:|
| `loadContents(of:)` | 26 |
| `refreshFolders()` | 21 |
| `refreshSpaces()` | 9 |
| `refreshPendingRestore()` | 3 |
| `refreshBackupFolder()`, `refreshSpaceStackPreviews()`, `reloadAfterMembershipChange()` | 2 each |
| `refreshSweeps()`, `refreshCollectionCovers()` | 1 each |

69 was measured before P1 removed `applyOrder`'s membership pre-read and P7 deleted
`FolderNode`; the two-site difference is those.

**47 of them — the 26 `loadContents` and the 21 `refreshFolders` — are the collection-feed
reloads this phase collapses. 41 became `publishChange(_:)`** (through `performWrite`, or
directly where the caller is not a write). **Six survive, deliberately**, and none of them
is a write reaching into the feed:

| survivor | why |
|---|---|
| `bootstrap` (×2: tree, then first load) | nothing to publish to yet |
| `requestJumpSelection` | 011-B4 — a Jump into the ALREADY-open collection must still apply its pending selection, and no change event fires because nothing changed |
| `createFolder`'s select-on-create | 259 — `onCreated` is a navigation hook running inside the write, before the window's deferred sync |
| `setSortMode` | the optimistic reload in the new order, ahead of the persist |
| `flushViewBumps` | the fallback when the `recordViews` write did NOT land, so local order cannot drift from the truth |

The single remaining internal `refreshFolders()` is `publishChange`'s own. The 20
space/backup/sweep refreshes are a different domain and were never in scope.

```swift
let libraryChanged = PassthroughSubject<UUID?, Never>()
enum ContentScope { case collections([UUID]); case unknown; case treeOnly }
```

A read model reloads when the published id matches what it has loaded, or when it is `nil`.

**`ContentScope` names collections plural, and that fixed a real gap.** Every verb used to
reload exactly one folder — `selectedFolderID` — but the F3 Unsorted invariant means
`removeAssets` re-homes an asset that has just lost its last membership *into* Unsorted, and
`addAssets` into a real collection *evicts* it from Unsorted. Neither is visible from the
verb's arguments. A window sitting on Unsorted while a move happened elsewhere kept showing
rows that were no longer there; `membershipScope(_:)` now says so out loud.

Two scopes went the other way. `setCollectionCover` is `.treeOnly` — a cover is a property
*of* the collection, drawn by the gallery card, and the reload the old `perform` did there
was always wasted. `applyFavorite` and `applyArchived` became `.unknown` — a star and an
archive are properties of the ASSET, visible in every feed that holds it, and reloading only
the folder the ⌘D was pressed in was under-reloading, not over-.

### What the undo/navigation separation actually fixes

The inverses used to assign `selectedFolderID` directly. That field is two things at once:
the import target, and — via `loadContents(of: selectedFolderID)` — the content pointer. So
**undoing a move or a remove that had been performed in a different collection silently
repointed the shared feed at that collection.** Concretely, with the user looking at B and
⌘Z reversing a move out of A:

1. `applyMoveBack` set `selectedFolderID = A` and loaded A into the shared `items`;
2. `loadedCollectionID` became A, and `CollectionView.isLoaded` compares it to its own
   `collectionID` — so **the grid on screen fell back to the "Loading collection"
   skeleton**, with no event coming that would clear it;
3. and `selectedFolderID` was now A, so **the next paste, drop or Add Color landed in a
   folder nobody was looking at** — the exact failure `addColor(hex:into:)`'s doc comment
   was written to prevent for its own path.

Now the inverse publishes a `FocusIntent` and `AppShellView` decides, honouring it by
*navigating* — which is what the user asked for when they pressed ⌘Z, and what makes the
restored items visible instead of invisible. The model suppresses an intent for the
collection it already has loaded, so the ordinary undo (same collection, same window)
publishes nothing and the shell's `.onChange` never fires.

**One `selectedFolderID` write survives, and the distinction is the point.**
`deleteFolder` still repoints the import target to Unsorted when the deleted folder *was*
the target: the id is about to stop existing and every verb reading it would target a dead
collection. Repairing state that has become invalid is not navigation. Where to *look*
after a delete is still the window's call — `NavModel.reconcile(using:)` already falls a
deleted sidebar selection back to Home on the tree refresh.

**`createFolder` also survives, explicitly.** Its `onCreated` is a navigation hook (259 —
the sidebar selects the row it has just made) that runs synchronously inside the write,
before the window's own deferred sync. If it moved the target off what this window shows,
the write loads the new collection. Without that, `CollectionActivationTests/sidebarCallbackActivatesImmediately`
fails — which is the suite doing its job, and the assertion was kept strong rather than
relaxed.

**`performWrite` publishes the change even when `body` throws.** A multi-statement body can
fail halfway — `moveMemberships` moves memberships and then restores their order — and a
reload to the database truth is the only honest response to "some of that landed". It costs
one read on a path that has already failed. `focus` is published only on success: a failed
undo should not navigate anywhere.

## 13A — one coalescer, and the reload that was firing in a loop

`ViewBumpCoalescer` is now `Coalescer<Key>` with two faces and a `typealias`, so 007 G4's
call sites and its whole suite are untouched:

* the **tally** — `record` / `drain`, unchanged;
* the **throttle** — `admit(_:interval:at:)` / `release(_:at:)`, leading-edge with a
  trailing run.

Both are pure. The throttle takes its instant as a parameter and owns no clock and no
scheduler, which is what lets `CoalescerThrottleTests` drive a burst across a window
boundary without sleeping through one.

`refreshAfterIngest(touching:)` runs behind it at **≤1 reload per 500 ms per collection**,
keyed by `UUID?` so the "producer cannot say which" case throttles alongside the rest
rather than escaping the limit. It used to reload the visible folder on **every** capture
batch: a sweep landing forty images ran forty full `collectionItems` reads of the same
collection, and the table below prices one of those at 59 ms over 2,000 rows and 639 ms over
20,000. The leading edge still lands immediately — a capture the user just watched arrive
must not wait half a second — and `.hold` is distinct from `.held` precisely so the *last*
batch of a burst is never the one that goes missing.

Every other reload in the file is user-paced and publishes straight through. This is the
one site a producer can fire in a tight loop.

## 071 · Phase 0a — the split, and the gate it closed

[071](../.docs/071-grid-scale-paging-plan.md) measured the TOTAL at every N and never the
parts, so §6.1's narrow row rested on a hypothesis — *"decode dominates the SQL scan"* —
with a number attached to the whole read rather than to the half it blames.
`ScaleHarnessTests` now splits it: one snapshot, warm, in the order a row travels, with
§6.1's projection and the one decode the hypothesis names measured beside it.

**Release build, `ATELIER_SCALE_N`, this machine (Xcode 26.6 / macOS 26.5). Milliseconds.**

| N | total (warm) | 1 query (scan) | 2 row decode | 3 struct decode | 4 publish | `raw_metadata` alone | §6.1 narrow row |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 2,000 | 58.99 | 1.21 | 4.86 | 52.06 | 0.44 | 12.86 | 5.95 |
| 5,000 | 145.79 | 3.44 | 10.85 | 131.43 | 0.83 | 32.52 | 14.96 |
| 10,000 | 297.67 | 8.71 | 24.98 | 263.20 | 2.07 | 63.47 | 32.01 |
| 20,000 | 639.25 | 20.19 | 54.53 | 525.40 | 4.73 | 128.03 | 72.88 |

* **query** = `SELECT COUNT(*)` over the identical join — SQLite visits every row and
  decodes nothing.
* **row decode** = `Row.fetchAll` over the identical request, minus the scan — every column
  materialized into a GRDB `Row`.
* **struct decode** = `CollectionItemRow.fetchAll` minus the row fetch — ~6 UUID parses per
  row (C5 stores ids as lowercase TEXT) plus `raw_metadata` through `JSONDecoder`.
* **publish** = the map to the public `[CollectionItemDetail]` that crosses the boundary,
  timed on already-decoded rows.

The COLD totals the harness still prints reproduce 071's table closely — 64.70 / 152.25 /
307.17 / 631.14 against its 64.75 / 149.29 / 305.98 / 750.05 — so the split is a split of
*that* number and not of a different one.

### The verdict: no summary row, and here is why

At 20,000, of 639.25 ms:

| stage | ms | share |
|---|---:|---:|
| query (scan) | 20.19 | 3.2 % |
| row decode | 54.53 | 8.5 % |
| **struct decode** | **525.40** | **82.2 %** |
| publish | 4.73 | 0.7 % |
| — of which `raw_metadata` | 128.03 | **20.0 %** of the total, 24.4 % of the struct decode |

**071 §3's hypothesis is confirmed: decode dominates the scan, by 26×.** But the gate this
phase was given is narrower and it is not met. `rawMetadata` decode is a fifth of the read —
steady at 20–22 % across every N — and three quarters of the struct decode is *not* it. It
does not dominate, so **the narrow summary row is not built here.** It was not built on the
assumption that it was needed, which is what the brief asked for.

Two things the numbers do say, recorded for whoever picks 071 up:

1. **§6.1 would work.** The narrow row is 72.88 ms against 639.25 — an **8.8× speedup**, and
   that is its *cheapest* shape (the probe leaves `raw_metadata` as undecoded `String`, the
   §6.3 fallback). It is simply not this phase's decision to make.
2. **The cheapest available win on that 128 ms is not §6.1 at all.** The harness seeds
   `raw_metadata = '{}'` — two bytes — and decoding 20,000 of them costs **6.4 µs each**.
   That is `JSONValue.fromDatabaseValue` constructing a fresh `JSONDecoder` per row, not
   JSON parsing. A shared decoder, or a `JSONValue` that stays lazy until read, would
   collect most of a fifth of the read without touching a single call site.

And the honest caveat 071 already wrote down: this corpus is lean. A real library with
tweets and links carries fat `raw_metadata`, so 128 ms is a **floor** on that column rather
than a ceiling. Even tripled it would be ~45 % — still short of dominating, and still fixed
by the decoder rather than by the row.

## 14A (app) — confirmed, not rebuilt

P1 removed `applyOrder`'s membership pre-read. This phase only had to confirm the reorder
path through the seam, and moving the display-space solve into
`CollectionReadModel.applyReorder(movingAssetIDs:insertAt:)` did that: the same drag through
a membership-carrying feed reorders and through a membership-less one returns `nil` without
touching anything, asserted side by side in one test so the refusal is visibly the feed's
rule and not a broken solve. `setOrder(_:to:)` carries the pre-read's obituary in its doc
comment, where the behaviour it explains now lives.

## Tests

**Seventeen added; `@Test` count 4,225 → 4,242 across the repo** (app suites 1,724 →
1,741). Nothing was removed and no assertion was relaxed.

`CollectionReadModelTests` (11) — `loadPublishes`, `supersededLoadPublishesNothing`,
`supersededFailureSetsNoError`, `selectionPrunedToSurvivors`, `fetchFailureSetsLastError`,
`fetchFailureFallsThroughToLocalizedDescription`, `changeEventReloadsOnlyMatchingID`,
`savedSearchFeedHasNoMemberships`, `savedSearchFeedRefusesReorder`,
`modelForwardsRatherThanCopies`, `ingestBurstCollapses`.

`CoalescerThrottleTests` (6) — `leadingEdgeRuns`, `burstCollapsesToOneTrailingRun`,
`windowsAreIndependent`, `nilKeyThrottles`, `windowExpiryRuns`, `releaseRestartsTheWindow`.

Most drive a **stub feed** rather than a real library, and that is the phase's own point
rather than a shortcut: because the read is injected, "a superseded load publishes nothing"
is asserted by holding one read open and releasing it, instead of by racing two real queries
and hoping. Every wait is a signal (099 · 11A) — `CollectionReadModel.events` says which
load landed and which was superseded, and `EventRecorder` records from before the work
starts, so no wait can lose a race it was written to win. `ingestBurstCollapses` fires ten
batches and asserts **two** loads (leading edge + one trailing), then a third only after the
window; there is no `Task.sleep` anywhere in it.

`changeEventReloadsOnlyMatchingID` also pins the rule that a read model which has never
loaded anything fetches nothing, whatever arrives on the subject. A window that has not
shown a collection has no business reading one.

## The gate

`./scripts/verify.sh` full, fourteen stages:

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

**One observation worth recording, because it is a trap and not a result.** Across four
full runs of this gate on the same tree, the UI stage failed **once** — two of the three
smoke flows, `testCommandCommaOpensASettingsWindow` (55.7 s) and
`testSidebarListsTheSeededCollectionsInOrder` (21.2 s), both timing out on assertions that
normally settle in under eight seconds. The two flows have nothing in common at the model
level (one opens the Settings scene and never touches a collection), which is what says it
is the environment rather than the diff. Re-running `-only-testing:AtelierRefsUITests`
against the same tree immediately afterwards passed all three in 7.6 / 4.7 / 7.2 s, and the
next full run was clean. This is the ad-hoc-signing note 099 already carries for this
stage — the first launch of a freshly signed binary pays a grant the unattended run cannot
answer quickly — and it should be expected to recur rather than diagnosed again.

## Files changed

* **new** `AtelierRefs/AtelierRefs/CollectionReadModel.swift` — the read model and
  `CollectionFeed`.
* **new** `AtelierRefs/AtelierRefsTests/CollectionReadModelTests.swift`.
* `AtelierRefs/AtelierRefs/ViewBumpCoalescer.swift` → `Coalescer.swift` — generalised;
  `ViewBumpCoalescer` survives as a `typealias`.
* `AtelierRefs/AtelierRefs/IngestionModel.swift` — 3,904 → 3,760 lines; the feed, its
  derivations and its race guard out, one write funnel in.
* `AtelierRefs/AtelierRefs/AppShellView.swift` — honours `focusIntent`.
* `AtelierRefs/AtelierRefsTests/ViewBumpCoalescerTests.swift` — the throttle suite beside
  the tally suite.
* `AtelierCore/Tests/AtelierCoreTests/ScaleHarnessTests.swift` — 071 · Phase 0a.

## What is still NOT covered

**There is still exactly ONE read model.** `IngestionModel` builds it, holds it as a `let`,
and forwards to it. Nothing yet constructs a second — the saved-search feed is written,
tested and unused until P4 mounts a window on it, and P6's palette does not exist. So the
claim this phase is really making, *"a second window can now have its own feed without
touching the writes"*, is demonstrated by a stub and by the shape, not by a second window.
The first real one is P4's, and it is where the shape gets tested for real.

**`CollectionFeed.savedSearch` has no badge path.** It surfaces `.notFound` and
`.invalidSavedSearchRules` as a `lastError` sentence, which is what a grid does with a
failed load. 057's badges — *references a deleted tag*, *can't read this search* — need
`savedSearchMissingTags(id:)` and a place on the row and the header, and both are P4.

**`subfolders` is still a read, not a projection.** `childCollections(of:)` is a second
round-trip whose answer is derivable from the flat `folders` array the tree already holds.
Because it is a read, a renamed or reparented child's chip is stale until the feed reloads
— which is precisely why `rename` and `reparent` publish `.unknown` and reload every feed
for what is a metadata change. That is no worse than the `loadContents(of: selectedFolderID)`
they replaced, and it is a reload that a projection would delete outright. Left because
1A specifies `childCollections` as part of the collection fetcher.

**The `focusIntent` → navigation hop is untested.** `requestFocus`'s suppression rule is
exercised implicitly by the undo suites (they publish nothing, because verb and inverse run
in the same collection), but the *cross-collection* case — undo while looking somewhere
else, shell navigates, grid shows the restored rows — has no test. It needs a `NavModel`
and an `AppShellView`, so it is a UI-suite flow (10A / P5) rather than a unit test, and no
smoke flow covers undo today.

**The throttle's trailing run is not cancellable.** A `refreshAfterIngest` that holds
schedules a `Task` around a `Task.sleep`, and that task holds `self` strongly, so the model
outlives its own last reference by up to the window. There is no token to cancel it with
and nothing asserts there is not one. Harmless in an app whose model lives as long as the
process; a real cost the moment a second window's model is short-lived, which is P4.

**500 ms is asserted as a constant, not as a felt rate.** `CoalescerThrottleTests` pins the
arithmetic and `ingestBurstCollapses` pins the shape, but nothing says 500 ms is the right
number for a sweep. It is the plan's, and the only evidence for it is that the reload it
guards costs 59–639 ms.

**`applyReorder` publishes optimistically and the write may still fail.** That was true
before and is unchanged: the read model rewrites `items` in the dragged order immediately,
`setOrder` persists, and a failure surfaces through `lastError` while the funnel's reload
puts the grid back to the truth. Nothing asserts the failure path end to end.

**`dragPayload` still stamps `selectedFolderID` as the drag's source**, not
`loadedCollectionID`. In one window they are the same; in the second window P4 builds they
need not be, and a drag out of a saved-search grid has no source collection at all. Left
exactly as it was rather than changed under cover of a refactor — but it is a seam P4 must
look at.

**The three load-induced timeout flakes are untouched**, as directed:
`PollTests/settlesEarly()`, `LibrarySearchModelTests` and `CollectionActivationTests` remain
the recorded risk from [469](469-the-cache-that-was-never-promised.md) and
[470](470-the-second-cache-takes-the-same-seam.md). Worth noting for whoever takes them:
`CollectionActivationTests`' own comment says *"`loadContents` is fire-and-forget, so there
is no write chain to await"*, and after this phase there **is** one —
`model.contents.events` emits `.loaded(collectionID:count:)`. Its three-second polls now
have an exact signal to become. That is a one-file change and it was deliberately not made
here.

**071 §6.2 and §6.3 are not started, and §6.1 is now a decision someone else gets to
make.** The numbers above are what it should be made on. Note that the 20,000-row *cold*
total on this machine is 631 ms against 071's published 750 ms, so any threshold argument
should be re-measured rather than quoted.
