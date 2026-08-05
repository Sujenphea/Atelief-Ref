# 340 — ⌫ Removes, ⌘⌫ Destroys

[022] D2–D5. **The Delete key in the collection grid no longer deletes from the
library.** It removes the item from the collection you are looking at — undoably,
with no dialog. **⌘⌫ is the destructive key now**, and it keeps the confirmation.

This is an inversion of the previous binding, and it is deliberate: the softest key
on the keyboard was wired to the hardest verb, and the modifier is now what you have
to reach for to leave the library. The mitigation is that ⌫ is reversible and says
so — "Removed 3 from “Refs”. — Undo" — so the change is legible on the first press.

## The rule, once

> **⌫ removes the item from where you are looking. ⌘⌫ removes it from the app.**

"Where you are looking" is the only per-surface knowledge:

| Surface | ⌫ | ⌘⌫ |
|---|---|---|
| Collection grid | membership in this collection (undoable, no dialog) | destroy, confirmed |
| Collection grid, **in Unsorted** | **nothing** — a toast reads "Unsorted is the fallback — press ⌘⌫ to delete." | destroy, confirmed |
| Space canvas | the tile placement (unchanged) | destroy, confirmed — **new capability** |
| Item detail page | membership in the collection the page was opened from | destroy, confirmed |
| Search results | **nothing** — a hit has no container to be removed from | destroy, confirmed |

One destructive path throughout: every ⌘⌫ ends at the shared confirmation →
`deleteAssetsRecoverable` → ⌘Z-undoable, blobs reaped at the next launch. No second
delete implementation was added.

## Why each surface changed

- **Grid.** `deleteBackward:`/`deleteForward:` and `keyDown` landed on one
  `onRequestDelete` closure → `requestDeleteSelected()`. The configuration seam is now
  a pair (`onRequestRemove` / `onRequestDelete`), and `deleteIntent` decides which one
  a press meant. `IngestionModel.removeSelectedFromFolder()` — written for exactly this
  binding and, until now, with **zero callers** — is the remove branch. ⌘⌫ arrives
  through `performKeyEquivalent`, where a modified Delete is actually delivered
  (AppKit never sends `deleteBackward:` for one). A side effect worth naming: ⌥⌫ and
  ⌃⌫ are word/line deletes and now fall through instead of running the destructive
  verb, which the old bare `gridIsDeleteKey` test let them do.
- **Unsorted.** `AppServices.removeAssets` exempts Unsorted from the F3 re-home,
  precisely because removing there would re-add what it just removed. So a removal in
  Unsorted either does nothing or quietly orphans. It says so instead, and names the
  key that does leave the library. The Edit-menu item is disabled there.
- **Space.** `CanvasHostView.keyDown` tested `keyCode == 51 || 117` and never looked
  at the modifiers — a ⌘⌫ was not rejected, it was simply not read — and `SpaceView`
  handed the *same closure body* to `onRemoveTiles` and `onDeleteTiles`, so the canvas
  context menu offered two labels for one behaviour and a board had no path to a
  delete at all. The two are now different verbs, the menu items say where each acts
  ("Remove from Board" / "Delete from Library…"), and the delete keys moved inside the
  existing `editingTileID` guard — a text box waiting for focus used to lose its tile
  to a Backspace. Deleting an asset CASCADEs `space_item`, so the board reloads on the
  model's contents bump; that also fixes a board left open behind a collection keeping
  a tile whose picture was deleted elsewhere.
- **Item detail.** Both keys go in `DetailKeyCatcher.keyDown`, beside the arrows —
  **not** a `.keyboardShortcut`, which fires before the first responder is consulted
  and cannot see that the responder is the sidebar's Name or Note field. The guard
  that makes it safe is `armIfNeeded` declining to steal focus from `NSText`, and it is
  load-bearing in a way it never was for the arrows: a swallowed ← is an annoyance, a
  swallowed ⌫ eats the word you were correcting *and* deletes a picture. A host that
  wires neither action (a Space board, a search hit) binds neither key, which is
  correct rather than a gap.
- **Menus.** Edit ▸ "Remove from Collection" / "Remove from Board" and Edit ▸
  "Delete" (⌘⌫), fed by a `DeleteVerbs` focused value each pane publishes. A focused
  value rather than a read of the shared model, because "where you are looking" is
  exactly what the model does not know — it holds the grid's selection, so a
  model-reading command would destroy the grid's items while a board had focus.

### One judgement call: no bare-⌫ key equivalent on the menu

The brief asked for ⌫ on the Remove menu item. It does not have one, and cannot: an
`NSMenu` key equivalent is matched before the event reaches the first responder, so a
bare ⌫ registered there would swallow Backspace in **every text field in the app** —
the sidebar rename row, the search field, the detail page's Name and Note. This is the
same platform behaviour that killed the canvas's V/F/T shortcuts ([269]) and the detail
page's arrows ([069]); it is documented on `DeleteCommands`. ⌫ is delivered by the
surfaces themselves, each of which knows whether a field has the keyboard. ⌘⌫ *is*
registered — it is nobody's text-entry key, it is the one that most needs to be
discoverable, and it always raises the confirmation first.

## The decoder, in two copies

`CanvasRenderer` is a standalone package declared with **zero dependencies** so the
compiler enforces its view-agnostic boundary. Rather than give it a dependency on the
app, or move a decoder whose vocabulary is "remove from a collection" into a renderer,
it carries an eight-line copy (`CanvasHostView.deleteIntent`). `DeleteIntentContractTests`
is the only place both are visible at once and runs the whole key × modifier matrix
through both: a divergence fails a build instead of shipping a board where ⌘⌫ means
something else.

## Files changed

- `AtelierRefs/AtelierRefs/IngestionModel.swift` — `removeSelectedFromFolder()` gains
  the Unsorted rule and an empty-target guard; new `removeFromCurrentFolder(assetIDs:)`
  (the detail page's one-item entry) and `canRemoveFromCurrentFolder`.
- `AtelierRefs/AtelierRefs/MasonryGridHost.swift` — `onRequestDelete` splits into
  `onRequestRemove` / `onRequestDelete`; `gridKeyDown` and `gridPerformKeyEquivalent`
  decode through `deleteIntent`; `gridDeleteCommand()` is the remove verb. The ⌘⌫ branch
  is gated on `isDetailPresented` — `performKeyEquivalent` walks the view hierarchy, not
  the responder chain, so the grid behind the page would otherwise have destroyed its
  own selection while the user was looking at one item.
- `AtelierRefs/AtelierRefs/CollectionView.swift` — grid wired to both verbs; the detail
  page's Remove routed through `removeFromCurrentFolder`; publishes `DeleteVerbs`.
- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — `onRequestRemove: {}` (no container);
  publishes `DeleteVerbs` with `canRemove: false`.
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `onDeleteTiles` un-aliased and routed to
  `model.requestDelete`; board reloads on `model.contentsVersion`; publishes
  `DeleteVerbs` naming the placement.
- `AtelierRefs/AtelierRefs/ItemDetailView.swift` — `DetailKeyCatcher` gains
  `onRemove` / `onDestroy` and decodes them in `keyDown`.
- `AtelierRefs/AtelierRefs/AtelierRefsApp.swift` — `DeleteVerbs`, its `FocusedValues`
  key, and `DeleteCommands` in the Edit menu.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `CanvasDeleteIntent`
  + `deleteIntent(characters:modifiers:)`; `keyDown` reads the modifier and sits inside
  the `editingTileID` guard; the two context-menu items renamed and un-synonymed;
  `onRemoveTiles` / `onDeleteTiles` documented as the two different verbs they now are.
- `AtelierRefs/AtelierRefsTests/TwoTierDeleteTests.swift` (new) — 13 tests: ⌫ over a
  selection / a bare cursor / a widened ⧉4 post; the Unsorted no-op and its notice; no
  targets is silent; search removes nothing but still stages a delete; last-membership
  removal re-homes to Unsorted (the F3 invariant, through the new caller); ⌫ then ⌘Z
  restores the membership at its old position; the detail page's Remove; a board's
  remove-vs-destroy including "the placement survives until the confirmation is
  answered"; and the two-decoder contract.
- `CanvasRenderer/Tests/CanvasRendererTests/HostDeleteKeyTests.swift` (new) — 10 tests:
  the mapping matrix, ⌫ → `onRemoveTiles` and ⌘⌫ → `onDeleteTiles` through real
  `NSEvent`s, ⌥⌫ doing nothing, an empty selection, and an open text edit swallowing
  neither verb.
- `CanvasRenderer/Tests/CanvasRendererTests/HostToolKeyTests.swift` — `deleteStillWins`
  updated: a bare ⌫ still beats the tool keys, but it now fires `onRemoveTiles`.

## Migration notes

**No schema change.** The behaviour change *is* the migration note:

- **⌫ in the collection grid no longer deletes from the library.** Muscle memory
  trained on the old binding will press ⌫ expecting a confirmation dialog and get a
  silent removal from the current collection instead. It is undoable (⌘Z, or the toast's
  Undo button), the item is never orphaned (it re-homes to Unsorted if that was its last
  membership), and no files are touched.
- **⌘⌫ is the destructive key.** It behaves exactly as ⌫ used to: the same confirmation,
  the same `deleteAssetsRecoverable`, the same ⌘Z undo, the same deferred blob reap.
- **⌫ on a board is unchanged** (it still drops the placement); ⌘⌫ there is new.
- ⌥⌫ and ⌃⌫ no longer do anything on any surface — they are text-editing keys.
