# 298 — Unsorted means not filed

## Summary

Unsorted is a real collection with real memberships, and nothing ever removed one.
So "Add to ▸", the ⌥-drag, and the Item Detail chips all left an asset showing in
Unsorted **and** the folder it had just been filed into — the triage pile never
drained. The reverse hole existed too: the grid's Remove dropped the last
membership and left the asset in no collection at all, reachable only from search.

Unsorted now means exactly one thing, enforced in the funnel:

> An asset is in Unsorted **if and only if** it is in no other collection.

## The two rules

Both live in `AppServices`, inside the same transaction as the write that triggers
them — so every caller (app, capture server, chips, undo, a future one) inherits
them, and neither can half-apply.

1. **Filed ⇒ not unsorted.** Gaining a membership in a real collection drops the
   Unsorted one.
2. **Unfiled ⇒ unsorted.** Losing the last membership re-homes the asset to
   Unsorted, appended to its manual order.

Applied by `addAssets`, `removeAssets`, `moveAssets`, and both ingest funnels
(where it only bites on the 18A dedup path — a re-capture of bytes already in the
library).

## Three deliberate exemptions

**Removing FROM Unsorted** does not re-home. Rule 2 would otherwise re-add what the
verb just removed and the Unsorted grid could never be cleared. Delete is the verb
for leaving the library.

**Adding TO Unsorted while already filed** is skipped, not honoured. Dragging back
to Unsorted was legitimate un-triage; it still is for an asset with nowhere else to
live, but for a filed asset it would recreate exactly the state this removes. It is
a no-op rather than a strip of the real memberships — a drag onto a sidebar row
should not silently unfile something from three folders.

**Restore is verbatim.** `restoreDeletedAssets` and snapshot restore re-insert
membership rows directly, untouched by the rules: delete-undo must be an exact
inverse, and legacy both-places rows are the migration's job, not restore's.

## Migration v16

Data-only, no schema change (like v9). Back-fills both rules over existing
libraries: drops the redundant Unsorted membership of every filed asset, and gives
an Unsorted membership to every asset that belongs to no collection at all —
including the ones today's Remove already stranded.

Re-homed rows are appended to Unsorted's manual order oldest-first, and carry the
asset's own `created_at` as `added_at`: the membership is a repair of history, not a
fresh filing (and a migration has no clock). Idempotent — a second pass matches
nothing.

**First launch after this ships, Unsorted's count changes.** It shrinks by the
number of already-filed items that were double-listed, and grows by any stranded
ones.

## One wording change

⌥-drag / "Add to ▸" out of Unsorted now behaves exactly like a move — the source row
disappears, because the asset is filed and therefore no longer unsorted. The notice
said "Added N to X" while the user watched the row vanish, so `copyToCollection`
takes the source folder and says **"Moved"** when it is Unsorted. Callers with no
folder source (search results) pass `nil` and keep "Added".

## Files changed

- `AtelierCore/…/Services/AppServices.swift` — the rules in `addAssets` /
  `removeAssets` / `moveAssets`, the shared `placeIngested` for both ingest funnels,
  and four private helpers (`isFiled`, `evictFromUnsorted`, `rehomeUnfiled`,
  `placeIngested`) under a MARK documenting the invariant and its exemptions.
- `AtelierCore/…/Persistence/Migrator.swift` — `v16` + `reconcileV16Unsorted`.
- `AtelierRefs/IngestionModel.swift` — `copyToCollection(…, from:)` and the verb.
- `AtelierRefs/CollectionView.swift`, `CollectionsOutlineView.swift` — pass the
  source folder (the sidebar drop passes `payload.sourceCollectionID`).
- `AtelierRefs/AssetTagsStore.swift` — the chips' hand-rolled re-home deleted; it was
  a second round-trip that could fail on its own, and the funnel owns it now.

## Migration notes

Callers that relied on `addAssets` being purely additive get one new side effect: the
Unsorted membership goes. No API signature changed in Core. `copyToCollection` gained
a defaulted `from:` parameter, so existing call sites still compile.

## Verified

- `swift test` in `AtelierCore` → **576 tests in 85 suites passed**, including 13 new
  invariant tests (`ServicesUnsortedInvariantTests`) and 4 new v16 migration tests.
- One existing test changed: `ServicesMoveTests.notInSourceStillAdds` pinned the old
  behaviour (a stale-payload move left the Unsorted row). Its 9A intent — the asset
  still lands in the target — is unchanged; the Unsorted assertion is now inverted.
- `-only-testing:AtelierRefsTests` → `** TEST SUCCEEDED **`; app builds clean.
- `AtelierRefsUITests/testLaunchAndNavigateShell` fails on "Sweeps toolbar entry
  missing" — pre-existing, reproduced with these changes stashed.
- Not exercised in the running app: the migration's effect on a real library.
