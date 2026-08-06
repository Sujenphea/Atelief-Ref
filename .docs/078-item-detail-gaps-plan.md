# 078 — The Item Detail Page: Three Gaps

**Status: shipped** — I1 in `16e9fca`, I2 in `ef5201d`, I3 in `53d58bc`. Open
questions 1 and 2 answered: ⌫ steps like ⌘⌫, and deleting the last item in a run
steps back rather than closing. I4 ([070]'s carousel chip) remains deliberately
optional and unbuilt.

Two departures worth knowing. The step gate carries a **collection stamp** as
well as an item id — an id-only gate steps to a stranger if you switch
collections before the async reload lands, which is the exact failure the gate
exists to prevent. And §A's shared list forced the detail page's Add chip from a
`Menu` to a `Button` + `.popover`: a SwiftUI `Menu`'s content becomes `NSMenu`
items, which cannot host the list's `ScrollView`, so the 240pt cap and the `Menu`
were mutually exclusive.

> Three requests on one screen: the sidebar's **"add to collection" menu is a
> weird flat list**; the page has **no delete bindings**; and **deleting steps out
> of the page** instead of on to the next item. All three are small; the third is
> the one that makes the page usable for triage.

## Current state (verified)

### A — the add-to-collection menu

`CollectionsField` (`ItemDetailView.swift:1095-1137`):

```swift
private var addable: [Collection] {
    let current = Set(collections.map(\.id))
    return allCollections.filter { !current.contains($0.id) }
}
…
ForEach(addable) { c in Button(c.name) { onAdd(c) } }
```

`allCollections` comes from `AssetTagsStore.refresh` →
`services.listCollections()` (`AssetTagsStore.swift:146`), which is documented as
a **flat `(name, id)` order** with manual sibling order deliberately *not*
applied (`AppServices.swift:1650-1660`) — because "the UI regroups this flat list
into the tree and sorts each parent group itself."

This call site never regroups. So the menu is:

- **flat** — a nested `Refs / Type / Serif` appears as a bare `Serif` beside
  unrelated roots, with no indication of where it lives;
- **alphabetical across the whole tree**, so two folders named `Inspiration` under
  different parents are indistinguishable;
- **includes Unsorted** as an ordinary row, unpinned;
- **unbounded** — no scroll cap, so a 40-folder library produces a menu taller
  than the window.

Meanwhile the *correct* list already exists and is used by the selection bar:
`CollectionTargets.moveTargetTree` (`CollectionTargets.swift:62`) returns the whole
hierarchy as indented `MoveTargetNode`s, roots in gallery order (Unsorted pinned),
children in manual order — and `CollectionView.destinationList`
(`CollectionView.swift:511-540`) renders it with indentation and a 240pt scroll cap.

### B — no delete bindings

Remove / Delete exist only in the overflow menu
(`ItemDetailView.overflowMenu`), wired at `CollectionView.swift:1104-1105` to
`removeFromFolder(assetIDs:[…])` and `requestDelete(assetIDs:[…])`. No ⌫, no ⌘⌫.
The page *does* hold first responder while it is up — `DetailKeyCatcher`
(`ItemDetailView.swift:1424`) borrows it precisely so ←/→ reach the pager — so
there is a place for the keys to go; it simply has no cases for them
(`detailStepDelta`, `:1399`, returns only ±1).

### C — delete closes the page

`CollectionDetailHost` (`CollectionView.swift:1040-1047`):

```swift
.onChange(of: model.contentsVersion) { _, _ in
    if let id = session.currentID,
       !model.items.contains(where: { $0.item.id == id }) {
        nav.presentedItemID = nil
    }
}
```

Documented as "auto-dismiss on delete (parity with the old `leadItem == nil`
gate)". It fires for **any** reason the shown item leaves the feed — delete,
remove-from-folder, a move out of this collection. So the triage loop
(open → judge → delete → judge the next one) costs a round trip through the grid
on every single item, and lands you at whatever the grid's cursor happens to be
rather than at the next item in the run.

## The design

### A — one destination list, indented

Replace `CollectionsField`'s `addable` with `moveTargetTree`, minus the
collections the asset is already in, rendered with `node.depth` indentation and
the same 240pt scroll cap. Concretely: lift `CollectionView.destinationList` into
a shared `CollectionDestinationList` view and use it in both places.

That is the same move [075] makes for the grid's right-click submenu, and the
reason both docs exist: **there is one correct destination list in this codebase
and three renderings of it.** Whichever lands first should build the shared view;
the other consumes it.

Keep the "No other collections" empty state. Keep the `DetailAddChip` trigger and
its `.menuStyle(.button)` / `.plain` chrome fix (`:1127-1129`) — that was hard-won.

### B — ⌫ / ⌘⌫ on the page

[073] owns the semantics; this is the wiring. `DetailKeyCatcher.keyDown`
(`:1516`) gains the `deleteIntent` decode beside `detailStepDelta`:

- **⌫** → `actions.removeFromFolder` (the collection the page was opened from —
  the host knows it, `detail.item.collectionID`, already used for the drag
  payload at `CollectionView.swift:1073`).
- **⌘⌫** → `actions.requestDelete` → the shared confirmation.

Both actions are already plumbed through `ItemDetailActions`; they are optional,
so a Space-hosted or search-hosted detail that passes `nil` simply doesn't bind
the key — which is the right behaviour for a surface with no membership.

The guard that matters: the sidebar's Name / Note fields hold the field editor,
and `armIfNeeded` already refuses to steal from `NSText` (`:1489`). ⌫ in a text
field must delete a character. That guard is what makes this safe, so don't
route these through a `.keyboardShortcut` (which would fire regardless).

### C — step, don't dismiss

The host already has everything needed: `model.detailRun` (`IngestionModel.swift:485`)
is the ordered run the pager walks, and `detailRunIndex(of:)` (`:491`) is an O(1)
position lookup.

Change the `contentsVersion` observer to, when the shown id has vanished:

1. Take the **pre-reload** index of the departed id (capture it *before* the
   reload replaces `detailRun` — the observer currently only ever reads the new
   state, so this needs the index remembered at the moment the delete is issued,
   or recomputed from the old run kept alongside).
2. Present `newRun[min(oldIndex, newRun.count - 1)]` — i.e. **the item that took
   its place**, which is "next" for every case except deleting the last item,
   where it is correctly "previous".
3. Only when `newRun` is **empty** does the page close.

Two constraints:

- **It must not step on a non-delete reload.** A move-out-of-collection, a
  reorder that drops the item, or switching collections while the page is up
  would all hit this path. Gate on "the run shrank and the id is gone", and have
  the delete/remove verbs mark their intent (a one-shot `expectsDetailStep` flag
  the host consumes) rather than inferring it. Inferring is how a collection
  switch leaves the page open showing a stranger.
- **The close-time lead sync stays correct.** `close()` (`CollectionView.swift:1140-1150`)
  maps the shown id through `displayTile(for:)` (`:512`) to land the grid cursor on
  a real tile. After stepping, the shown id is a different one — that already
  works, since `close()` reads `session.currentID` at close time.

This is what turns the page into a triage surface, and it is why [073]'s
bindings and this change want to land together.

## Carousel awareness (the fourth gap, unbuilt)

[070] proposed bringing the grid's fanned-pile vocabulary onto the page: a
`⧉ 2 of 4 in this post` chip beside the pager, the pile drawn behind the artwork
from `fanRotations` seeded by the post id, and a spread-on-hover fan for random
access. It is an **exploration, not a commitment** — none of it is implemented;
`ItemDetailView` is still fed an asset + source + navigator and has no idea a
post exists.

Recorded here so it is not re-discovered: after [069] the page *behaves*
correctly inside a post (the run keeps a post contiguous) and *communicates*
nothing. If the delete-steps-to-next loop lands, the chip becomes more valuable,
not less — you need to know whether the next ← is still inside the post you are
judging.

## Schema / migration impact

**None.**

## Phased implementation

1. **I1 (S)** — shared `CollectionDestinationList`; `CollectionsField` consumes it.
2. **I2 (S)** — ⌫ / ⌘⌫ in `DetailKeyCatcher` (after [073] D1's `deleteIntent`).
3. **I3 (M)** — step-instead-of-dismiss, with the explicit intent flag.
4. **I4** — [070]'s carousel chip, if wanted.

## Test strategy

- Destination list: pure over a fixture tree — indentation depth, Unsorted first,
  already-member collections excluded, empty state.
- `deleteIntent` decode inside the detail scope (shared with [073]'s suite);
  a focused `NSText` sees the key and the catcher does not.
- Step-on-delete as a **pure function**: `(oldRun, oldIndex, newRun) -> next id?`
  — middle item, first item, last item, run of one, run emptied, and the
  not-a-delete case (id still present). This is where the off-by-one lives, so it
  should not be tested through the view.
- Manual: delete five in a row without the page closing; delete the last item;
  switch collections while the page is up.

## Effort: **I1: S · I2: S · I3: M · I4: M (optional)**

## Risks & edge cases

- Deleting the shown item while its **thumbnail preload** is in flight — the
  session's `displayTask` supersedes by identity re-check (`DetailSession.swift`),
  so a step during a decode is already handled; verify with a large image.
- The **confirmation dialog** for ⌘⌫ opens over the page. It must not steal first
  responder permanently — `DetailKeyCatcher` arms once per presentation
  (`armIfNeeded`, `:1478`), so after the dialog dismisses, arrows must still work.
  This is the most likely regression in I2.
- ⌫ on an item whose only membership is the current collection re-homes it to
  Unsorted (the F3 invariant) — it does **not** leave the run empty, and the page
  should then step, since the id left *this* collection's feed. Confirm the
  behaviour reads as intended rather than as a failed delete.
- [070]'s pile draws *behind* the artwork; the media area is also the drag-out
  source and the zoom surface. Any pile view must be `hitTest`-transparent, the
  same discipline `DetailKeyCatcher` uses (`:1465`).

## Open questions

1. On ⌫ (remove from collection), should the page step, or close? Recommended:
   **step** — same triage loop, same reasoning.
2. Deleting the last item in the run: step back (recommended) or close?
3. Is [070]'s carousel chip wanted now, or does the pager counter suffice?
