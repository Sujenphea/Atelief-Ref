# 343 — One Destination List

Two surfaces were computing their own answer to "which collections can I file
this into". Both were wrong, in different directions. Now there is **one
ordering** — `CollectionTargets.destinationTree` — and **two renderers** that
consume it, with a contract test that says so.

## The two bugs

**Right-click stopped one level deep.** The grid's `Move to ▸` / `Add to ▸` built
from `MoveTargets` — the current collection's *direct* subfolders, then every
root. From `Refs` you could file into `Refs/Type` but not into `Refs/Type/Serif`,
and not into `Photography/Portraits`. Anything two levels down was unreachable by
right-click at any depth, in any collection, forever. The multi-select bar had had
the correct list (`moveTargetTree`) the whole time, two functions away.

**The item detail page's add chip was a flat alphabetical dump.** It filtered
`listCollections()`, which is documented as a flat `(name, id)` order with manual
sibling order deliberately *not* applied, because "the UI regroups this flat list
into the tree". That call site never regrouped. So a nested `Refs/Type/Serif`
appeared as a bare `Serif` beside unrelated roots; two `Inspiration` folders under
different parents were indistinguishable; Unsorted was an ordinary unpinned row;
and nothing capped the height, so a 40-folder library produced a menu taller than
the window.

## One ordering, two renderers

`CollectionTargets.destinationTree` is now the single source: the whole hierarchy,
roots in gallery order (Unsorted pinned), children in manual `sortIndex` order,
the current collection **included**. `moveTargetTree` became a pre-order flatten
of it, so the flat+depth shape the SwiftUI list wants and the nested shape
`NSMenu` wants cannot describe different libraries.

- **`CollectionDestinationList`** (SwiftUI) — the indented, 240pt-capped,
  scrolling list, lifted out of `CollectionView.destinationList`. The selection
  bar's behaviour is unchanged by the lift; the detail page's add chip now renders
  the same list, passing the asset's existing memberships as `excluded`.
- **`CollectionDestinationMenu`** (AppKit) — nested `NSMenu` submenus, one
  recursive builder, replacing all three of the grid's flat submenus (`Move to`,
  `Add to`, and search's `Add to Collection`).

The current collection is **listed and greyed** rather than omitted, in both
renderers. That is what makes the menu read as the complete tree, which is what
makes it navigable.

## The cost of nesting

A row with a submenu cannot itself be clicked — AppKit gives it no action. So
every row that has children gains a leading **"Move here"** (or "Add here", which
follows the caller's verb) plus a separator. Only rows with children get one;
adding one to a leaf would double the row count for nothing.

**The depth is not capped.** A 6-level hierarchy makes a 6-deep submenu chain,
which is unpleasant but honest; a silent cap makes folders unreachable, which is
the bug being fixed. If depth ever becomes a real complaint the answer is a
searchable picker, not truncation — said in a comment where someone would
otherwise be tempted.

## Performance

`MoveTargetsCache` exists because the SwiftUI menu once built eagerly per visible
cell at ~326ms/pass. It is kept, and now memoizes the destination *tree*; `from`
dropped out of its key, because the tree is the same seen from anywhere now that
the current collection is a render-time disable rather than a filter. Measured on
a 40-folder, 4-deep fixture: a cold build plus menu materialization is **0.157ms**
(Debug, `-Onone`, arm64), and 200 body passes over an unchanged folder list produce
**one** build — asserted, not assumed, so "not on the scroll path" is a test rather
than a claim.

## Files changed

- `AtelierRefs/AtelierRefs/CollectionTargets.swift` — `destinationTree` +
  `flatten`; `moveTargetTree` re-expressed on top of them; `moveTargets` and the
  `MoveTargets` type deleted; `MoveTargetsCache` re-pointed at the tree.
- `AtelierRefs/AtelierRefs/CollectionDestinationList.swift` (new) — the SwiftUI
  renderer.
- `AtelierRefs/AtelierRefs/CollectionDestinationMenu.swift` (new) — the pure
  `[DestinationTreeNode] -> [DestinationMenuItem]` builder and its `NSMenu` walk.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — configuration carries the tree
  + disabled set instead of `MoveTargets`; both menu styles use the nested builder;
  `BlockMenuItem` is internal so the new file can share it.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — `destinationList` delegates to
  the shared view; the cache feeds the grid the tree.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — search's bespoke flat
  all-collections-as-roots list replaced by the shared tree.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — the add chip is a popover over
  `CollectionDestinationList` instead of a flat `Menu`.
- `AtelierRefs/AtelierRefsTests/CollectionDestinationTests.swift` (new) — the
  builder, the list rows, the contract, and the build-cost/memo assertions.
- `AtelierRefs/AtelierRefsTests/CollectionTargetsTests.swift` — the three
  `moveTargets` split tests replaced by destination-tree tests (recursion, manual
  order, cycle safety, a 6-deep chain).

Untouched on purpose: `CollectionMoveToMenu`, which reparents *folders* and is
flat because it excludes cycles — correct for a different reason.

## Migration notes

None.
