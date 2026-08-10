# 371 — Archive, in the Selection Bar

[084](../.docs/084-archive-shelf-plan.md) follow-up. A3 put the archive verb on
`E` and in every context menu and stopped there — the floating "N selected" bar
never got it. Reported from use, which is how a missing second path usually
surfaces.

## The gap

`CountSelectionBar` has four callers. The shelf passed an Unarchive extra; the
collection grid and the search results passed none. Home's gallery bar is
correctly excluded — it selects collections and spaces, not assets, and
archiving a whole collection is a different feature.

**Archive now sits beside Delete and Remove** in both, rather than under the
collection bar's `…` overflow. The argument is adjacency, not room: Archive is
the RECOVERABLE alternative to Delete, and Delete is in the bar's fixed leading
run. A bar where the irreversible verb is one click and the reversible one is
two nudges toward the wrong one every time. Thirty points of width is a cheap
price for not doing that.

Both route through `toggleArchived` — the same call the cell menu and `E` make —
so the three paths cannot drift. Neither consults `shelfVerb` for a direction:
every visible item is unarchived by construction (A1), which is the same reason
`addArchiveItem` doesn't either.

## A bug the pass turned up

The shelf's own extra was `Button("Unarchive")`. `floatingBarChrome` sets no
button style, so that draws the **system's bordered push button, accent bezel and
all**, inside a capsule whose premise is that this app has no coloured accent.
Every other bar item is a `SelectionBarButton` glyph in the shared 30×28 slot;
this one had been a stray since A2. It is now `tray.and.arrow.up` with the word
in its tooltip.

The second half of that fix matters more than the look: it took
`selection.ids` **raw**, while the bar's Delete beside it went through
`actionTargetsForKey()`. So a collapsed ⧉4 tile would delete all four and
unarchive one. Both verbs now ask the same function.

## Two copies of the widening rule, removed

`requestDeleteTargets()` in both `ShelfView` and `LibrarySearch` re-derived the
scope inline instead of calling the `actionTargetsForKey()` sitting directly
above it. The shelf's copy had already rotted into dead code — it computed a
`scope` local and then discarded it. Both now call the one function, which is
what makes "the bar and the key agree" a property rather than a coincidence.

## Tests

None added, and deliberately. What is new here is chrome with no seam; the rule
underneath it — `shelfVerb`, `toggleArchived`, the widening — is already covered
by the 22 tests from A3, and a test asserting a closure is non-nil would assert
nothing about what the button does. Verified by hand on all three bars.

## Files changed

- `ShelfView.swift` (glyph, widened targets, dead-code removal)
- `CollectionView.swift`, `LibrarySearch.swift` (the Archive glyph; search's bar
  gains its first extra)

## Migration notes

None. No API or schema change.
