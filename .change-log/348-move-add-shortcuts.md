# 348 — M Files It, A Copies It

[024] K3 — the last phase of the keyboard map. `M` opens **Move to…**, `A` opens
**Add to…**, both on the collection grid; on a Space board `A` is bound and **`M` is
not**. The picker they raise is the destination list [343] already built, given a
keyboard cursor.

K1, K2 and K4 shipped in `3b507fb`; the `M` / `A` rows have sat in
`KeyMap.planned` — written down, deliberately not bound — since then. They are now
in `KeyMap.all`, and `planned` is empty.

## The board has no `M`, and that is the decision

[024] §C recommended "M = Move to…, A = Add to…, on **every** surface with a
selection". That was taken for the grid and **rejected for the board**.

On a grid, `M` is a plain reparent: a membership leaves one collection and joins
another. On a board there is no membership to move — a board owns **placements**
(019 · C1) — so `M` would have had to mean *file the assets **and** delete their
placements*: a composite whose second half quietly destroys a layout the user
arranged by hand, wearing the same key that means "reparent" one screen over. Same
key, same-looking selection, two very different amounts of damage.

So the board gets the verb it actually has. **`A` files the selected tiles' assets
into a collection and leaves every placement exactly where it was** — one
`addAssets` call, undoable, nothing to explain. Filing *and* clearing the board is
still reachable, as two deliberate acts: `A`, then ⌫.

This retires [024]'s "Space `M` is destructive-adjacent — it needs a toast that names
both halves" risk and the composite-undo test that went with it. There is no
composite left to get wrong. §C carries the amendment in full, the way K4 amended
[011].

## What the keys act on

**The selection when there is one; the keyboard cursor's post when there isn't** —
the same rule ⌫ and ⌘D already follow, reached through the same property
(`IngestionModel.keyboardActionTargets`, now also exposed as
`destinationActionTargets`).

That sharing is the point rather than a convenience. The one action path that
computed its own answer produced [027] G1's bug, where a cursor on a tile reading ⧉4
acted on a single image and left the tile behind reading 3. So `M` on a collapsed
carousel tile files all four, and `M` inside an *opened* post files the one frame
under the cursor — the exception lives in `widenedForAction`, and nothing here
re-decides it.

## Decoding: bare means bare

Both existing pure decoders were extended; no fifth key-handling mechanism was added.

- **Grid** — `gridKeyCommand` gains `.moveTo` / `.addTo`. `⌘A` is still Select All;
  `⌘M` is still nobody's; `⌥A` still types `å` into a text field. ⇧ **is** tolerated
  on `M` / `A` (unlike `X`, which stays strict): these are verbs a user types, and a
  stray capital still meant the verb.
- **Board** — a new `CanvasHostView.boardShortcut`, a **sibling** of `toolShortcut`
  rather than a case inside it. `CanvasTool` is the canvas's *mode* — the value the
  tool picker binds to and `onCreateElement` switches over — and filing is a one-shot
  verb with no mode to be in; an `.addToCollection` case would have had to be excluded
  by hand from the picker, from the create path and from the host's own `tool`
  property. The two decoders share one `isBareLetter` guard so the modifier rule
  cannot drift between them.

`boardShortcut` returns `nil` for `m` at every modifier combination, and a test says
so — because that is where a board `M` would come back.

## The bare-letter guard, traced

A bare letter must never fire while a text box has the keyboard. Each existing
mechanism was checked rather than assumed, and `M` / `A` reuse them:

- **Canvas** — `keyDown` returns early on `editingTileID != nil`, and an open editor
  holds first responder anyway, so the key never arrives. `A` sits inside that gate,
  after the delete and tool branches.
- **Grid** — `gridKeyCommand` runs from `MasonryNSCollectionView.keyDown`, which only
  reaches a **first responder**. The grid has no text entry of its own; the sidebar's
  inline rename / draft field lives in the same window, and while it is editing it —
  not the grid — is the responder. A `keyboardShortcut` would have been the wrong
  home for exactly this reason (a key equivalent is matched *before* the responder is
  consulted), which is why `AtelierRefsApp`'s Edit ▸ Remove still carries no bare ⌫.
- **Item detail** — `DetailKeyCatcher.armIfNeeded` declines to steal first responder
  from an `NSText`, and it is a different surface with its own decoder; `M` / `A` are
  unbound there.
- **Search field / detail sidebar Name + Note** — all `NSText`-backed and all take
  first responder on focus, so the grid and canvas `keyDown` paths are not reached.

Net: typing `M` mid-rename types an `M`, and it does not also open a picker.

## The picker

`DestinationPicker` — **not a third picker.** The rows, their order, the indentation
by depth, the pinned Unsorted, the greyed current collection, the 240pt cap and the
empty state all still come from `CollectionDestinationList` ([343]'s "one destination
list, one ordering, everywhere"). What is new is the two things a pointer never
needed:

- **A cursor.** ↑ / ↓ walk, Return files, Escape dismisses. The walk is over
  `CollectionDestinationList.navigableIDs` — derived from the same `rows` the list
  draws, minus the greyed ones, so the cursor can never walk an order the eye does
  not see. Steps clamp at both ends rather than wrapping: a ↓ at the last row that
  jumped back to Unsorted would file into the one collection the list pins above
  everything for being different.
- **Giving the keyboard back.** However it closes — a pick, Escape, a click outside —
  first responder returns to the grid (via a new `GridFocusHandle`) or to the canvas
  (via `SpaceView.restoreCanvasFocus`, which already existed for the bar's other
  popovers). Without it the arrow keys stay dead until the next click; that is the
  same discipline `DetailKeyCatcher.restoreResponder` follows.

It opens from the corner the selection bar's `…` overflow opens from, upward, wearing
the same chrome and the same words ("Move to" / "Add to", now a `Verb.title` so the
menu, the accordion and the picker cannot drift). The grid greys the collection in
view; a board greys nothing, because a board is not a collection.

[011] C-1's ⌘K type-ahead machinery is **not** built. The list is height-capped and
the cursor scrolls with it, which is the cheap ninety percent.

## Add is undoable now

`IngestionModel.copyToCollection` registered no undo. Move and Remove both register a
reversible action and raise an "…— Undo" toast; Add published a plain notice and left
nothing to press. That asymmetry was survivable while Add cost a right-click and a
submenu walk; it is not survivable when a single bare `A` fires it.

The inverse removes **only the memberships the forward pass actually created**,
measured by reading the target's membership before and after rather than by
predicting it — `addAssets` skips existing members *and*, into Unsorted, skips
anything already filed (the F3 invariant), and re-deriving both rules here is how an
inverse silently starts deleting a membership the user had before. So undoing an `A`
over a half-filed selection leaves the half that predated it alone.

This is the one change here that goes beyond the letter of K3. It is app-wide: the
drag-add, the right-click Add to ▸, the selection bar's accordion and the detail
page's chip all gain the same undo, which is the point — one verb, one behaviour.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `onFileTiles`,
  `CanvasBoardCommand`, `boardShortcut`, the shared `isBareLetter` guard; `keyDown`
  reads it after the tool keys.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasView.swift` — `onFileTiles`
  passed through.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — `GridKeyCommand.moveTo` /
  `.addTo`; `gridKeyCommand` decodes bare `m` / `a`; `GridHostConfiguration
  .onDestinationVerb` + `.focusHandle`; the new `GridFocusHandle`.
- `AtelierRefs/AtelierRefs/DestinationPicker.swift` (new) — `DestinationRequest` and
  the keyboard-navigable popover body.
- `AtelierRefs/AtelierRefs/CollectionDestinationList.swift` — `highlighted`, the pure
  `navigableIDs` / `step`, scroll-to-cursor.
- `AtelierRefs/AtelierRefs/SelectionActionBar.swift` — `SelectionMenuRow
  .isHighlighted` (the keyboard cursor outranks hover).
- `AtelierRefs/AtelierRefs/CollectionDestinationMenu.swift` — `Verb.title`.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — raises the picker on `M` / `A`,
  restores grid focus on dismiss.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — raises it on `A`, restores canvas focus.
- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `destinationActionTargets`;
  `copyToCollection` undoable (`applyAdd` / `applyUnadd` / `AddedMemberships`).
- `AtelierRefs/AtelierRefs/KeyMap.swift` — three rows promoted; `ShortcutDecoder
  .canvasBoard`; `planned` now empty (the seam kept, the rows gone).
- `AtelierRefs/AtelierRefsTests/MoveAddShortcutTests.swift` (new).
- `AtelierRefs/AtelierRefsTests/KeyMapTests.swift` — the board-has-A-not-M assertion,
  the `.canvasBoard` contract row, and the "free" test rewritten as "taking them left
  the ⌘-combos alone".
- `AtelierRefs/AtelierRefsTests/SelectionCellDeltaTests.swift` — the bare-`a`
  assertion updated, a bare-`m` one added.
- `.docs/feature-todo/024-keyboard-map-and-shortcuts-page.md` — §C amendment.

## Verification

`xcodebuild build … -destination 'generic/platform=macOS'` clean. Full suite measured
before and after on this branch: **1509 → 1532 passed, 0 failed**. `swift test` in
`CanvasRenderer/` (its own suite, since `CanvasHostView` changed): 418 tests in 50
suites, all passing.

One existing assertion changed rather than broke:
`SelectionCellDeltaTests.selectAll` said "⌘A selects all; the letter alone does
nothing", which stopped being true. It now asserts the pair — ⌘ picks the meaning,
neither spelling reaches the other's — with a `moveTo` sibling beside it.

The collision test did **not** trip on promotion — bare `M` / `A` collide with
nothing, and the near misses the reservation was watching (`X` on the grid,
`V`/`F`/`T` on the canvas) are different letters.

The picker is view code, so it is compile-only plus manual. Worth a human pass:
`M` in a grid with a selection; `M` with only a keyboard cursor, on a carousel tile;
`A` on a board leaving the tiles in place; `M` doing nothing on a board; typing `M`
while renaming a sidebar row, while in the search field, and while editing a canvas
text box; Escape returning focus so the arrows still work.

## Migration notes

**No schema change.** Behaviour changes worth knowing:

- **Two bare letters are now live in the grid and one on a board.** Anything that
  starts reading typed text on those surfaces must take first responder (an `NSText`
  does this by construction) rather than relying on the keys being free.
- **Add is undoable everywhere**, not just from the shortcut. The toast it raises now
  carries an Undo button where it used to be a plain notice, and it pushes an entry
  onto `IngestionModel`'s undo stack — so a ⌘Z immediately after any Add now reverses
  the Add rather than whatever preceded it.
- `KeyMap.planned` is empty. It and `ShortcutStatus` are kept as the seam for the next
  doc-reserved chord; the collision test still runs over `all + planned`.
- The search grid is **unaffected**: `onDestinationVerb` defaults to a no-op, which is
  the right answer on a membership-less surface — there is no collection to move out
  of, so the keys do nothing there rather than opening a picker whose "Move" could not
  mean anything.
