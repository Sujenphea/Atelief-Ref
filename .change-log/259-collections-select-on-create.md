# 259 — Collections: select-on-create + authoritative sidebar clicks

Fixes the reported "⌘V pastes into the wrong collection". The import pipeline was
targeting correctly all along — the SIDEBAR was lying about which collection was
active, so the user pasted while a different collection was still the live one.

## Root cause

Creating a collection from the sidebar's inline draft row never ACTIVATED it:

1. `endDraft(commit:)` called `model.createFolder(...)`, which discarded the created
   collection (`_ = try await services.createCollection(...)`). Nothing ever called
   `nav.selectSidebar(.collection(newID))`.
2. The committed draft row is deliberately drawn with the selected-row highlight
   (`forceSelected`, so it reads as active while typing) but is NOT selectable
   (`shouldSelectItem` returns `false` for it). So the new collection LOOKED active
   and clicking it did nothing — no selection change, no delegate callback, no nav
   update.
3. `nav.sidebarSelection` therefore stayed on the previously selected collection,
   which is what `CollectionView` bakes into its ⌘V import target — so the paste
   went to the old collection, correctly, per a stale selection.

## Summary

- **Select-on-create.** `IngestionModel.createFolder(name:parent:onCreated:)` now
  surfaces the created `Collection` through an optional callback fired AFTER
  `refreshFolders()` has published it — selecting before the refresh would leave the
  outline unable to resolve the new row (and would skip `expandAncestors` for a
  subfolder, via `syncSelection`'s `changed` guard). The sidebar coordinator uses it
  to `nav.selectSidebar(.collection(created.id))`, so highlight, detail panel, and
  paste target all agree the moment the collection exists.
- **Clicks are authoritative for nav.** `rowClicked` now syncs
  `nav.sidebarSelection` to the clicked row whenever they disagree.
  `outlineViewSelectionDidChange` fires only when the outline's selection actually
  CHANGES, so a click on an already-highlighted row could not heal a highlight/nav
  drift — exactly the state such a click is trying to correct. Expand/collapse
  behaviour for parent rows is unchanged (it just moved below the nav sync so leaf
  rows reach it too).
- **Imports reload where they LANDED.** `IngestionModel.run(inputs:undecoded:)`
  reloaded `selectedFolderID`, not the folder the batch targeted. Each input bakes
  in its destination at decode (the pasting view's own `collectionID`), so if the
  selection hadn't caught up, imported assets went in correctly but never appeared
  in the grid — reading as "the paste vanished". Now reloads the inputs' uniform
  target, falling back to the selection for a mixed-target batch.

## Follow-up: the "Loading collection" skeleton on a new collection

Select-on-create exposed a second, older bug — previously unreachable, because you
never actually got to the new collection. Pasting into it left the grid stuck on
`gridSkeleton` ("Loading collection"), i.e. `loadedCollectionID != collectionID`.

Cause: `selectedFolderID` lags the sidebar selection by a runloop hop —
`AppShellView` syncs it from `.onChange` + `DispatchQueue.main.async` — and two
paths read it instead of the view's own `collectionID`:

- **A pasted URL.** `dispatch(inputs:webURL:)` falls through to
  `ingestRemoteImage(from:)` when the pasteboard carries a web URL and no image
  bytes. That read `selectedFolderID`, so the item was ingested into the PREVIOUS
  collection and `run` then reloaded the previous collection — pinning the visible
  one on its skeleton indefinitely. It now takes an explicit `into folder:`, and
  `CollectionView` passes `collectionID` — the same target the byte path bakes into
  its `IngestInput`s. (The canvas equivalent, `importRemoteURL(_:into:)`, already
  took an explicit folder; this brings the grid path in line.)
- **Everything else "add to the current folder".** Add Color / Add Link also read
  `selectedFolderID`. The sidebar's `onCreated` now sets `model.selectedFolderID`
  in the same turn it selects on `nav`, so the window where those verbs would
  target the previous collection no longer exists. `createFolder`'s trailing
  `loadContents(of: selectedFolderID)` consequently reloads the NEW folder too.

## The actual root cause: a stale ⌘V action closure

The two fixes above were necessary but NOT sufficient — pasting still imported into
the wrong collection. Runtime tracing (`os_log`, since every unit test passed while
the app misbehaved) showed why. At the instant of a paste:

```
onCreated fired id=AABE052F                 ← the new collection
after selectSidebar nav=collection(AABE052F) ← nav correct
rootContent builds CollectionView id=AABE052F ← view rebuilt with the new id
syncActiveCollection → AABE052F              ← model correct
PASTE collectionID=45C6A86F selectedFolderID=AABE052F
```

`paste()` ran with `collectionID = 45C6A86F` — the collection open when the app
LAUNCHED. Three consecutive pastes all reported it, so the target was frozen at
launch, not lagging by one step.

`CollectionView` carries no collection-keyed `.id(...)` — deliberately, because the
AppKit grid host is reused across switches instead of being torn down (036 §2 A4).
So SwiftUI keeps ONE view identity for every collection, and the hidden ⌘V
`Button`'s action closure is registered against that identity and never
re-registered when the struct is rebuilt with a new `collectionID`. It stays bound
to the first capture. (`spaceDestination` avoids this for `SpaceView` with
`.id(id)`, whose comment already warns "the panel keeps showing the previous
space".)

Fix: resolve the target at INVOCATION instead of relying on closure freshness.
`CollectionView.importTargetID` reads the selection off `nav` when the import
actually fires; `nav` is a reference type, so even a stale closure holds the live
model. All three import surfaces (⌘V, drop, web-URL) now use it. Adding
`.id(collectionID)` would also have worked but would rebuild the grid host on every
collection switch — the exact cost 036 engineered away.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `createFolder` gains `onCreated`
  (and no longer routes through `perform`, which cannot return the created value);
  `run(inputs:)` reloads the batch's target folder; `ingestRemoteImage` takes an
  explicit `into folder:`.
- `AtelierRefs/AtelierRefs/CollectionsOutlineView.swift` — `endDraft` activates the
  new collection on both `model` and `nav`; `rowClicked` syncs nav on disagreement.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `importTargetID` (+ its pure,
  testable half `resolveImportTarget(path:sidebar:fallback:)`) resolves the import
  target from `nav` at invocation; `paste`, `handleDrop`, and the web-URL branch of
  `dispatch` all route through it.
- Tests: `AtelierRefs/AtelierRefsTests/CollectionActivationTests.swift` — new.

## Migration notes

None. No schema change. `createFolder`'s new parameter is defaulted, so the other
call site (`CollectionsGalleryView`'s "New Subfolder" alert) is source-compatible
and intentionally unchanged — the gallery is a browse surface, and jumping the
selection away from it on create would be a UX change beyond this fix.

## Verification

`xcodebuild test -scheme AtelierRefs -only-testing:AtelierRefsTests` — **TEST
SUCCEEDED**, including four new `CollectionActivationTests` that drive the real
create → activate → import sequence and assert `loadedCollectionID` (the exact
value `CollectionView.isLoaded` compares, so a failure IS the skeleton):

- activate deferred, as `AppShellView` does;
- activate synchronously — proves `createFolder`'s trailing reload of the previous
  folder can't win the race;
- activate the way the sidebar actually does, with NO deferred sync simulated —
  the regression guard for the skeleton bug above;
- reload the import target after create.

`run(inputs:)` itself can't be unit-tested: it requires the `private` ingest
coordinator, which the test-only `init(services:store:)` doesn't build. The tests
drive the reload ordering it performs rather than the ingest.

Verified in the RUNNING app (the unit tests all passed while it was still broken,
so this mattered) — three create-then-paste rounds, each landing correctly:

```
09:15:39 CREATE temp-03 → 09:15:41 IMPORT→ temp-03
09:15:44 CREATE temp-06 → 09:15:47 IMPORT→ temp-06
09:15:52 CREATE temp-10 → 09:15:55 IMPORT→ temp-10
```

with the trace confirming the mechanism: `collectionID` stayed pinned at the launch
collection across all three while the resolved `target` followed each new one.

## Note for future debugging

Unit tests passing is NOT evidence this screen works. The failure lived entirely in
SwiftUI's view-identity/closure-registration behaviour, which no test here
reproduces — the coordinator-level test drives the real `NSOutlineView` and still
went green. Trace the running app (`/usr/bin/log show --predicate 'subsystem ==
"com.atelierrefs.app"'`) before trusting a green suite on import targeting.

Database forensics on the live library confirmed the diagnosis before the fix: the
single `local_paste` asset was created 19s after the "Inspiration" collection and
its only membership IS Inspiration, while "temp-01" holds nothing but three
July-22 Twitter captures — i.e. no asset ever misrouted, the view was just showing
a different collection than the sidebar implied.
