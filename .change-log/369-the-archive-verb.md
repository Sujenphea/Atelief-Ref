# 369 — The Archive Verb, Everywhere an Item Is

[084](../.docs/084-archive-shelf-plan.md) phase **A3**. The
shelf now has something to put on it: `E` and an Archive menu item on every
surface an item appears on.

## `ShelfIntent` — one rule, four consumers

    The verb ARCHIVES unless every target is already archived,
    in which case it UNARCHIVES.

Deliberately the **same rule ⌘D already uses for the star** (011 · U5): a mixed
selection *converges* rather than flipping each item, which is the only outcome
a user can predict without inspecting every tile — and a second press is still
the inverse, so it reads as a toggle without being a per-item one. Inventing a
second convention for archive when the app already has one would be two things
to remember.

It gets its own file for the reason `DeleteIntent` does: four surfaces consume
it (collection grid, search results, detail page, Space board), and "the verb
means the same thing everywhere" has to be a property of the code.

**There is no `surface` parameter, deliberately** — the plan asked for "per
selection and surface", and the surface turns out to be redundant. A browsing
read hides archived items (A1), so a collection selection is all-unarchived *by
construction* and the shelf is all-archived by construction. A surface argument
would be a second source of truth for the same fact, free to disagree with the
first — and the case where it disagreed (a selection left stale by a change
underneath it) is exactly the case worth getting right.

Unsorted is not special here either, and that is written down rather than left
to be rediscovered: archive changes no membership, so the F3 invariant survives,
and triaging the to-do pile with "not now" is arguably the verb's best use.

## Where it landed

| Surface | Reached by |
|---|---|
| Collection grid | `E`, and Archive in the cell menu |
| Search results | `E`, and Archive in the cell menu |
| Archive shelf | `E` (resolves to Unarchive), and the menu's Unarchive |
| Item detail | the overflow menu, titled from the item's own state |
| Space board | Archive in the tile menu — the tile vanishes and returns in place |

`E` is bare, ⇧ tolerated, ⌘ / ⌥ / ⌃ disqualifying — the same guard `M` and `A`
carry, which is what leaves ⇧⌘E (Export moodboard) alone. It is one key for both
directions: the data decides which, not which pane is open. The 077 table gains
a row, and `KeyMapTests` already pins that every `.grid` row decodes.

The board's Archive item needed a new `onArchiveTiles` on `CanvasHostView`. The
renderer deliberately does **not** decide the verb's direction or title — that is
an app-level rule with no business being duplicated in a rendering package.

## A bug the tests caught

`toggleArchived` was first written as fire-and-forget: it read the archived set
inside a detached `Task`, then wrote. That put the read **outside the undo
stack's serial write chain**, so `waitForWrites()` — how every caller and every
test knows the verb is finished — returned before the verb had decided anything.
Eight tests failed together; running one alone passed on timing luck.

It is now `async`, and callers wrap it in a `Task` at the call site where the
concurrency is visible.

## Tests — 22 new

- **`ShelfIntentTests` (11)** — the full matrix in the `DeleteIntentTests` shape:
  empty, none, all, mixed, second-press-is-the-inverse, archived ids outside the
  target set, duplicate targets collapsing (a widened post can name an asset
  twice, and the menu's count must not double), and the titles.
- **`AppArchiveTests` (11)** — the verb through the model, over a real temp
  `AppServices`, shaped after `AppFavoritesTests`. The load-bearing one:
  **undoing a mixed-selection archive restores the MIXTURE**, not a clean slate.
  A "just toggle everything" implementation passes every single-state test and
  fails that one.

The toast counts even at one — "Archived 1 item.", not "Archived." — for the
same reason the favorites toast does: a mixed press changes fewer rows than it
was aimed at, and the bare word would let the user read it as all of them.

## Files changed

- New: `ShelfIntent.swift`, `ShelfIntentTests.swift`, `AppArchiveTests.swift`
- `IngestionModel.swift` (`setArchived`, `toggleArchived`, `toggleArchivedSelected`)
- `MasonryGridHost.swift` (`GridKeyCommand.archiveVerb`, `onArchive`,
  `onArchiveVerb`, Archive in both browsing menus), `KeyMap.swift`
- `CollectionView.swift`, `LibrarySearch.swift`, `ShelfView.swift`,
  `SpaceView.swift`, `ItemDetailView.swift`
- `CanvasRenderer`: `CanvasHostView.swift`, `CanvasView.swift` (`onArchiveTiles`)

## Migration notes

None. `E` was unbound; `onArchive` / `onArchiveVerb` / `onArchiveTiles` are all
defaulted or optional, so a surface that binds none is unchanged.
`toggleArchived` is `async` — call it inside a `Task`.
