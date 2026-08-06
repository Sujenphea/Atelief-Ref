# 075 — Right-Click Can't Reach a Sub-Subfolder; Delete Can't Reach a Whole Post

**Status: shipped** — G1 in `c08129d`, G2 and G3 in `16e9fca`. Nested `NSMenu`,
current collection present-but-disabled, "Move here" / "Add here" rows following
the verb. The perf worry did not materialise: the recursive build measures
**0.157 ms** on a 40-folder, 4-deep fixture against the ~326 ms/pass hazard the
cache was built for. `MoveTargets` and `moveTargets(from:…)` were deleted rather
than left available, and `moveTargetTree` is now a flatten of the same tree the
menu walks.

> Two grid bugs with the same shape: a code path that computes a *narrower* answer
> than the correct one that already exists two functions away. **Move to ▸ shows
> one level of nesting** where the multi-select bar shows the whole tree; and
> **⌫ on a carousel tile deletes one image** where the context menu deletes all
> four.

## A — Move to ▸ / Add to ▸ stop one level deep

### Current state (verified)

The grid's native context menu builds its submenus from `configuration.moveTargets`
(`MasonryGridHost.swift:1230-1245`), rendered by `targetSubmenu` (`:1282-1295`):

```swift
for c in dests.subfolders { submenu.addItem(…) }
if !dests.subfolders.isEmpty && !dests.roots.isEmpty { submenu.addItem(.separator()) }
for c in dests.roots { submenu.addItem(…) }
```

`MoveTargets` (`CollectionTargets.swift:193`) is exactly two flat groups, produced
by `moveTargets(from:folders:unsortedID:)` (`:45`):

> "the current collection's **DIRECT** subfolders first, then every ROOT"

So from `Refs`, you can file into `Refs/Type` and into any root — but **not** into
`Refs/Type/Serif`, and not into `Photography/Portraits`. Anything two levels down
is unreachable by right-click, at any depth, forever.

The multi-select bar does it correctly. `CollectionView.moveTargetTree`
(`CollectionView.swift:500-506`) calls `CollectionTargets.moveTargetTree` (`:62`) —
the **whole** hierarchy as indented `MoveTargetNode`s, roots in gallery order
(Unsorted pinned), children in manual order, current collection included but
disabled — and `destinationList` (`:511-540`) renders it indented, capped at
240pt, scrolled.

The user's phrasing is the fix: *"should follow the multi select move to / add to
functionality."*

The sidebar's folder-reparent menu has the same split but is *correct* for a
different reason — `CollectionMoveToMenu` (`CollectionMoveToMenu.swift:35`) uses
`folderMoveTargets`, which excludes cycles and is flat on purpose. Leave it alone.

### The design

Replace `MoveTargets` in the grid menu with the tree, as a **nested NSMenu**
(native submenus are the right idiom here — an NSMenu can nest, so indentation
isn't needed and 40 folders don't produce a 40-row flat list):

```
Move to ▸  Unsorted
           ─────────
           Refs ▸  (Move here)
                   ─────────
                   Type ▸  (Move here)
                           Serif
                           Sans
           Photography ▸ …
```

Each parent row gets a leading **"(Move here)"** item plus a separator, because a
submenu-bearing row cannot itself be clicked — that is the one real cost of
nesting, and it is the standard macOS answer to it.

Mechanics:

- One recursive builder from `moveTargetTree`'s output (or better, from the
  `childrenByParent` grouping directly — the flat+depth shape exists for SwiftUI
  indentation and is the wrong shape for NSMenu).
- The current collection stays listed but **disabled**, matching the selection
  bar's greyed row — the list then reads as the complete tree, which is what makes
  it navigable.
- `MoveTargetsCache` (`CollectionTargets.swift:215`) exists because the menu used
  to build **eagerly per visible cell** at ~326ms/pass. The native menu now builds
  lazily on right-click only (`gridMenu(for:)`, `:1199`), so the cache is far less
  load-bearing — but keep it, keyed the same way, and **re-measure** after the
  change. A recursive build over a deep tree is more work per invocation than the
  flat one it replaces, and this file's history is a long argument about exactly
  that cost.

Do it once: extract `CollectionDestinationMenu` (AppKit) beside the shared SwiftUI
`CollectionDestinationList` that [078] §A extracts. Same data, two renderers,
**one ordering**.

Same treatment for the `.looseAssets` menu style's "Add to Collection"
(`:1260-1265`) and for the Space canvas's context menu if [077] §C's M/A land
there.

## B — ⌫ on a carousel tile deletes one image

### Current state (verified)

The widening machinery is correct and thorough:

- `widenedForAction(_:)` (`IngestionModel.swift:583`) expands a collapsed post's
  item id to all its members, and deliberately does *not* widen an **opened** post
  (so you can delete one bad frame from a carousel you opened — the comment says
  exactly this).
- `rebuildSelectedAssetIDs` (`:679`) runs every selection through it, so
  `selectedAssetIDs` is always post-widened.
- `actionTargets(forCellItemID:)` (`:618`) widens the unselected right-click case
  too, with a comment naming the failure it prevents: *"otherwise 'Delete' on a
  tile reading ⧉4 would remove one image and leave the tile behind."*

And then:

```swift
private var keyboardActionTargets: [UUID] {
    selection.isSelecting ? selectedAssetIDs : (leadItem.map { [$0.asset.id] } ?? [])
}
```
`IngestionModel.swift:2281`

The **lead branch takes the asset id raw**. `selection.isSelecting` is
`!ids.isEmpty` (`GridSelection.swift:43`), so any keyboard-driven cursor with no
explicit selection — arrow to a tile, press ⌫ — hits the unwidened path. On a
⧉4 tile that deletes one image and leaves the tile behind: the precise outcome
`actionTargets` documents itself as preventing.

Both consumers are affected: `requestDeleteSelected()` (`:2393`) and
`removeSelectedFromFolder()` (`:2381`) — the latter is currently dead code that
[073] is about to wire, so fixing this **before** [073] D2 is the cheap ordering.

### The fix

```swift
private var keyboardActionTargets: [UUID] {
    selection.isSelecting
        ? selectedAssetIDs
        : (leadItem.map { assetIDs(for: widenedForAction([$0.item.id])) } ?? [])
}
```

— i.e. route the lead through the same two functions the right-click path uses
(`assetIDs(for:)`, `:2266`; `widenedForAction`, `:583`). Note it must widen the
**item** id, not the asset id: `widenedForAction` speaks membership ids.

`favoriteActionWouldStar` / `canToggleFavorite` (`:2290-2299`) read the same
property, so ⌘D on a lead carousel tile also currently stars one image of four.
The fix corrects that too — which is the argument for fixing the shared property
rather than each verb.

## Schema / migration impact

**None.** Both are pure UI/model corrections.

## Phased implementation

1. **G1 (XS)** — `keyboardActionTargets` widening. One line + tests. Do this
   first; it is a real data-correctness bug and it unblocks [073] D2.
2. **G2 (M)** — `CollectionDestinationMenu` recursive NSMenu + swap the grid's two
   submenus onto it; re-measure the menu build.
3. **G3 (S)** — same menu for `.looseAssets` (search) and the Space canvas.

## Test strategy

- **G1**, pure and off-main (the widening helpers already are):
  - lead on a collapsed ⧉4 tile, no selection → 4 asset ids;
  - lead on a member of an **opened** post → 1 id (the deliberate exception);
  - lead on an ungrouped item → 1 id;
  - `groupCarousels` off → 1 id;
  - selection non-empty → unchanged (`selectedAssetIDs` path);
  - no lead → empty.
  - Plus: ⌘D over a lead carousel stars all four.
- **G2**: the recursive menu builder as a pure `[Collection] -> MenuNode` tree —
  depth, ordering (Unsorted pinned at root, manual order per parent), current
  collection present-but-disabled, "(Move here)" injected only on rows that have
  children, empty library. Then a contract test asserting the AppKit builder and
  the SwiftUI `destinationList` derive from the same function.
- Perf: re-run the menu-build measurement from [035]/[038] over a 40-folder,
  4-deep fixture; assert the build stays off the scroll path (it is lazy now, so
  the assertion is "not called during scroll", not a millisecond budget).

## Effort: **G1: XS · G2: M · G3: S**

## Risks & edge cases

- **Deep or wide trees make deep or wide menus.** A 6-level hierarchy produces a
  6-deep submenu chain, which is unpleasant but honest; the flat list's
  alternative is unreachable folders. If depth becomes a real complaint, the
  answer is a searchable picker ([011](feature-todo/011-ux-features.md) C-1's ⌘K machinery), not a truncated menu —
  do **not** cap the depth silently.
- "(Move here)" doubles the row count on parent rows. Only add it where the row
  has children.
- G1 changes what ⌫ does on a carousel from "one" to "all four" — which is the
  intent, but it lands at the same time [073] flips ⌫ from destroy to remove.
  Sequence them in one window and describe both in one changelog entry, or the
  behaviour change reads as two unrelated surprises.
- `MoveTargetsCache`'s key includes the whole `folders` array; a recursive build
  makes a cache miss more expensive. Verify the cache still hits across renders.

## Open questions

1. Nested NSMenu (recommended) vs the SwiftUI-style flat indented list in an
   NSMenu? Nested is native and scales; indented matches the selection bar
   visually. Pick one and use it for both, or accept the divergence explicitly.
2. Should the current collection appear disabled (recommended, matches the bar)
   or be omitted entirely (matches today's `moveTargets`, which excludes it)?
3. Does the Space canvas context menu get destinations at all, or does [077] §C's
   M/A cover it?
