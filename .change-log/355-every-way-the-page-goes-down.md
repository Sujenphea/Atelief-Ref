# 355 — Every Way The Page Goes Down

[354] fixed the one verb that reached the item detail page's step and found it
disarmed. This is the audit that should have come with it: every action that can
take the page down, what each one currently does, and the three that were wrong.

## The three ways it goes down

|  | What runs | Grid cursor |
|---|---|---|
| **`close()`** | flush view bumps → lead to the shown item → drop route → deferred reorder | lands on the item |
| **`.close` outcome** | dropped the route, nothing else | left wherever it was |
| **unmount** | nothing — the host leaves the tree | route left set |

Everything below is one of those three.

## What was wrong

**A membership chip is the page's ⌫ in different chrome.** Removing the chip for the
collection in view takes the shown item out of this feed exactly as ⌫ does, and it
closed the page. The verb is raised by `AssetTagsStore`, which speaks ASSET ids and
knows nothing about the run, so `onMembershipChanged` now carries the collection a
chip removed from (`nil` for an add — an add cannot drop the item from anywhere) and
the model arms the step when that collection is the loaded one.

**A drag out of the page onto a sidebar collection is a move**, completed by the
outline view, which knows even less: a set of asset ids and a destination. Same
answer, reached the same way.

Both needed something neither surface has — *which item is the page showing?* After
any number of ← / → that is neither the route (which stays on the id the page was
opened at) nor the lead (which stepping deliberately never moves). So
`IngestionModel` gains a plain `detailShownItemID`, kept in step with the session by
the host, in the shape `isDetailPresented` established: not `@Published`, because
nothing renders from it and a publish would re-run the grid under the overlay.

**Leaving the pane left the route pointing at a page that was gone.** Home, Capture
and a Space are separate arms of the shell's `switch`, so selecting one unmounts
`CollectionView` — and only `SpaceView` is `.id()`-keyed, which is why
collection→collection survives and this did not. `NavModel` never cleared
`presentedItemID`, so nothing ran and the id stayed. That left the sidebar collapsed
(`AppShellView`'s observer only fires on *change*), and on return to that collection:
the floating + hidden, `Edit ▸ Remove / Delete` greyed (as of [354]), and the grid's
keyboard entirely dead — `gridKeyDown` opens with `if configuration.isDetailPresented
{ return false }`, and the flag is read off the route. It cleared itself the moment
you opened and closed any item, which is why it reads as flakiness rather than a bug.

`selectSidebar` and `goBack` now drop the route, *before* changing the selection so
the host is still mounted to tear the session down. `reconcile` does too, but only
when the route actually moves — it runs on every folder refresh, and must leave a
live page alone.

## What was already right

⌫, ⌘⌫ and the overflow menu step ([346], [354]). Deleting the last item steps back;
an emptied collection closes. A chip ADDING another collection, a sort change, a
reorder, a favourite, and every ingestion path (clipboard, extension, drop) reload
with the item still in the feed and the page stays put. A collection switch closes,
which is the behaviour the intent's collection stamp was written to protect. ⌥-drag
is a copy and never leaves the feed.

## The cursor on the closes that remain

A `.close` still happens — an undo that moves the item away, a delete from the
duplicate sheet, an archive restore that does not carry it, a collection switch — and
it dropped the route without touching the grid's cursor, so the user landed wherever
they last clicked. That is the complaint [346] was written to kill, still true for
every close that is not a step.

The host now records where the shown item sat, and lands the cursor on whatever took
that slot — `min(index, count - 1)`, the same clamp the step uses, for the same
reason. Guarded on the run's own collection: a folder switch reaches this branch too,
and moving the newly-loaded folder's cursor to an index carried over from the folder
just left is the exact mistake the intent's stamp prevents elsewhere.

## Files changed

- `AtelierRefs/AtelierRefs/AssetTagsStore.swift` — `onMembershipChanged` carries the
  removed collection (`nil` for an add).
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `detailShownItemID`;
  `reloadAfterMembershipChange(removedFrom:)` arms for a chip on the loaded
  collection; `moveToCollection` arms via `armDetailStepIfShown(assetIDs:leaving:)`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — the host tracks the shown item +
  its slot off `session.state`, lands the cursor on `.close`, clears both plain flags
  on `onDisappear`, and passes the chip's collection through.
- `AtelierRefs/AtelierRefs/NavModel.swift` — `selectSidebar`, `goBack` and a
  route-moving `reconcile` drop `presentedItemID`.
- `AtelierRefs/AtelierRefsTests/DetailStepTests.swift` — four tests: a chip on the
  collection in view arms; an add and a chip for elsewhere do not; a move carrying the
  shown item arms; a move of another item, or with no page up, does not.
- `AtelierRefs/AtelierRefsTests/NavModelTests.swift` — three tests: sidebar selection
  and `goBack` drop the route, a no-op back does not, and `reconcile` clears only when
  the route moves.
- `AtelierRefs/AtelierRefsTests/AssetTagsStoreCollectionsTests.swift` — the callback
  test now pins the argument, `[nil, temp2.id]`.

## Migration notes

**Behaviour change.** Removing the current collection's chip, or dragging the picture
onto another collection, steps the page instead of closing it. Navigating away from a
collection closes its detail page rather than leaving it half-open. Closes that are
not steps land the grid's cursor where the page was, not where it last was.

`onMembershipChanged` takes an argument now. `CollectionDetailHost` is its only
setter in the app; `SpaceView` and `LibrarySearch` create stores but never set it.
No schema, no settings.
