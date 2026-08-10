# 368 — The Archived Destination

[084](../.docs/084-archive-shelf-plan.md) phase **A2**. The
shelf is now a place you can go: a sidebar destination beside Home and Capture,
showing every archived item newest-first, with Unarchive as its verb.

## `ShelfController`

A `@MainActor final class … ObservableObject` beside the other feature
controllers, following `DuplicateReviewController` → `LibraryStatsController`:
state on the main actor, services passed per call, the controller owning nothing
but that state. Not ~200 more lines inside `IngestionModel.swift`, which is
already the largest file in the repo and shares nothing with this surface.

Two decisions in it are load-bearing:

**Three empty states, not one.** An empty `items` array means "not read yet",
"read, and nothing is archived", or "the read failed" — and the pane must say
something different for each. `hasLoaded` separates the first; a failed load
**keeps the last good list** rather than blanking, because "I could not check" is
not "there is nothing here", and showing the second for the first is how a
transient error reads as data loss.

**The newest read wins, not the last to arrive.** The pane reloads on appear, on
a navigation pulse, on `contentsVersion` and after every verb, so overlapping
reads are the normal case — and `await` means they can finish out of order. Each
load takes a ticket and a superseded one drops its result. Mutation-verified:
without the ticket the test sees the stale answer.

## The pane

`ShelfView` renders through the **same** `MasonryGridHost` as the collection and
search grids, over the same synthetic-membership bridge search already had.
Selection, marquee, arrows, ⌘A, Esc, ⌘±, the native drag image and the layout
cache all arrive already built and already tested.

Those shared pieces were named for search when search was their only caller.
Renamed for the shape now that there are two: `searchItems(for:)` →
`looseItems(for:)`, `SearchDetailContext` → `LooseDetailContext`,
`SearchDetailOverlay` → `LooseDetailOverlay`. No behaviour change; the detail
page walks an ordered `[AssetDetail]` with no container, which is exactly what
both surfaces have.

### What the shelf deliberately refuses

- **No move, add-to, reorder or cover.** A new `GridMenuStyle.shelf` offers
  Unarchive and Delete, and that is the complete list. An archive you can file
  into and rearrange is just another collection.
- **No drag out, and no ⌘C.** Both are an *add*, and an added-but-still-archived
  item is invisible in the collection it lands in — every browsing read hides it
  (A1). A verb whose visible outcome is "nothing appeared to happen" is worse
  than one that isn't offered. The only way off the shelf is Unarchive. (If
  copy-out is wanted later, the honest version is add-implies-unarchive, which is
  a rule change in the paste path, not a flag here.)
- **No search within it.** The pane wraps in `LibrarySearchable` like every other
  so the toolbar height never shifts, but search never returns archived items.
  Typing leaves the shelf; it does not filter it.

Delete stays, because leaving the library means the same thing from every
surface — and it is the ordinary recoverable delete, with the same ⌘Z. A restored
item comes back **archived**, so it reappears here, which is why the pane watches
`contentsVersion`.

## Tests — 10 new, app-side

`ShelfControllerTests`, over a real temp `AppServices`. Two of them exist only
because of a seam: `readShelf` is overridable exactly as
`LibrarySearchModel.runQuery` is, because there is no way to make a live SQLite
read fail on demand or to force two reads to complete out of order — and those
are the two branches most worth asserting. A `defaultReaderIsLive` test pins that
the seam's default really is `AppServices.shelfAssets`, so the other cases cannot
pass against a fiction.

## Files changed

- New: `ShelfController.swift`, `ShelfView.swift`, `ShelfControllerTests.swift`
- `NavModel.swift` (`SidebarItem.shelf`), `SidebarView.swift` (the row),
  `AppShellView.swift` (the arm)
- `MasonryGridHost.swift` (`GridMenuStyle.shelf`, `onUnarchive`)
- `LibrarySearch.swift` (renames only)

## Migration notes

None. `SidebarItem.shelf` is additive and nothing persists it — `restoredSelection()`
only ever reconstructs `.home` or `.collection`, and `reconciled(selection:path:existing:)`
only rewrites `.collection`, so the new case passes through both untouched.
