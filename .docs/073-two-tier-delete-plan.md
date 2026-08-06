# 073 — Two Deletes, Everywhere: ⌫ Removes, ⌘⌫ Destroys

**Status: shipped** — D1 in `c08129d`, D2–D5 in `ef5201d`. ⌫ in Unsorted is a
no-op with a toast; ⌘⌫ keeps its confirmation; boards gained a real destroy.
Two things the implementation settled that this doc did not anticipate: Edit ▸
Remove carries **no ⌫ key equivalent** (an `NSMenu` equivalent is matched before
the first responder is consulted, so it would swallow Backspace in every text
field), and the menu commands read a per-pane `DeleteVerbs` focused value rather
than the scene-wide model. The Home gallery was missed by this doc and is
handled separately — see `.change-log/345-home-delete-gate.md`.

> Requested: **⌫ = remove from this collection**, **⌘⌫ = delete from the app**,
> and the pair must mean the same thing on **every** surface — collections,
> spaces, search, item detail. Today ⌫ means a different thing on each surface,
> ⌘⌫ is bound nowhere, and Spaces has no way to delete an asset at all.

## Current state (verified)

| Surface | ⌫ does | ⌘⌫ does | Remove-from-container reachable? |
|---|---|---|---|
| Collection grid | **Delete from library** (confirm dialog) | nothing | context menu only |
| Space canvas | Remove the placement | nothing¹ | context menu ("Remove from Folder" *and* "Delete" — identical) |
| Search results | Delete from library | nothing | n/a (no membership) |
| Item detail page | nothing | nothing | overflow menu only |

¹ `CanvasHostView.keyDown` checks `keyCode` without inspecting modifiers
(`CanvasHostView.swift:1146`), so a ⌘⌫ that reaches `keyDown` is treated as a bare
⌫ — the modifier is not rejected, it is simply not read.

Detail:

- **Grid.** `MasonryGridHost.swift:327-328` — `deleteBackward:`/`deleteForward:`
  both call `gridDeleteCommand()` → `configuration.onRequestDelete()` (`:1516`) →
  `CollectionView.swift:698` → `model.requestDeleteSelected()`
  (`IngestionModel.swift:2393`) → the destructive path. So the *softest* key on the
  keyboard is wired to the *hardest* verb. `gridKeyCommand`
  (`MasonryGridHost.swift:1776`) does not decode `\u{7f}` at all, so there is no
  seam where a modifier could be read.
- **The remove verb already exists and is dead code.**
  `IngestionModel.removeSelectedFromFolder()` (`:2381`) has **zero callers** — it
  was written for exactly this binding and never wired.
- **Space.** `SpaceView.swift:274-281` passes the *same closure body*
  (`space.removeTiles`) to both `onRemoveTiles` and `onDeleteTiles`, with a comment
  saying so. The canvas's context menu offers two labels for one behaviour
  (`CanvasHostView.swift:1129-1137`). There is no path from a board to
  `deleteAssetsRecoverable`.
- **Detail page.** Remove / Delete live only in the overflow menu
  (`ItemDetailView.swift` overflow, wired at `CollectionView.swift:1104-1105`), each
  acting on `[detail.asset.id]`. No key binding.
- **No menu items.** `AtelierRefsApp.swift`'s command set is Undo/Redo, ⌘D, ⌘N,
  ⌘[ — there is no Edit ▸ Delete, so neither verb is discoverable *or*
  system-bindable.

## The design

### The rule, stated once

> **⌫ removes the item from where you are looking. ⌘⌫ removes it from the app.**

"Where you are looking" resolves per surface, and the resolution is the only
per-surface knowledge:

| Surface | ⌫ target |
|---|---|
| Collection grid | membership in the current collection |
| Space canvas | the tile placement |
| Item detail (opened from a collection) | membership in that collection |
| Search results | **⌫ is a no-op** — there is no container to remove from |

⌘⌫ is identical everywhere: stage `requestDelete(assetIDs:)`, which raises the
shared confirmation and lands on `deleteRecoverably` (⌘Z-undoable, blobs reaped at
next launch). One destructive path, unchanged.

### Where it is decided

A single pure `deleteIntent(characters:modifiers:) -> DeleteIntent?`
(`.remove` / `.destroy`), living beside `gridKeyCommand` and consumed by all four
surfaces — same discipline as `detailStepDelta` / `toolShortcut`. That is what
makes "global" a property of the code and not of four remembered conventions.

Mechanics per surface:

- **Grid** — `gridKeyCommand` learns `\u{7f}` / `NSDeleteFunctionKey` and returns
  the intent; `deleteBackward:`/`deleteForward:` (`:327`) keep working for the bare
  case, and the ⌘ case arrives through `performKeyEquivalent` (`:1504`), which
  already routes there. `onRequestDelete` splits into
  `onRequestRemove` / `onRequestDelete`, wiring the already-written
  `removeSelectedFromFolder()`.
- **Space** — `CanvasHostView.keyDown` reads the modifier before dispatching;
  `onDeleteTiles` stops being an alias and reaches
  `IngestionModel.requestDelete`. The canvas context menu's two items stop being
  synonyms.
- **Detail** — the page needs a key catcher for these; `DetailKeyCatcher`
  (`ItemDetailView.swift:1424`) already holds first responder while the page is up,
  so both bindings go in its `keyDown` next to the arrows. Post-delete navigation
  is [078]'s problem, not this doc's.
- **Menus** — Edit ▸ "Remove from Collection" (⌫) and "Delete" (⌘⌫), titles
  tracking the focused surface, so both verbs are discoverable and the shortcuts
  are visible where macOS users look for them. This is also the surface [077]'s
  shortcuts page reads from.

### Confirmation policy

- ⌫ / remove: **no dialog**, undoable via ⌘Z (it is a membership edit; the
  Unsorted-invariant re-home in `AppServices.removeAssets` means it can never
  orphan).
- ⌘⌫ / delete: keep the existing confirmation. It is the only irreversible-feeling
  verb and the dialog is the thing that makes the inversion below safe.

### Carousel scope

Both verbs act on the post-widened id set. The lead-only path is currently
**not** widened — see [075] §B; that bug must be fixed in the same window or
⌫ will remove one frame of a four-image post and leave the tile.

## Schema / migration impact

**None.** Both verbs already exist in `AppServices`
(`removeAssets(_:from:)` `:1197`, `deleteAssetsRecoverable(_:)` `:1371`).

## Phased implementation

1. **D1 (S)** — pure `deleteIntent` + tests. No behaviour change.
2. **D2 (M)** — grid: split remove/delete, wire `removeSelectedFromFolder`,
   fix the lead-widening ([075] §B).
3. **D3 (S)** — space: read the modifier, un-alias the two handlers, wire destroy.
4. **D4 (S)** — detail page bindings (composes with [078]).
5. **D5 (S)** — Edit-menu items with focused titles.

## Test strategy

- `deleteIntent`: bare ⌫/⌦ → `.remove`; ⌘⌫/⌘⌦ → `.destroy`; ⌥⌫ / ⌃⌫ → `nil`
  (a word-delete in a field must never be either); ⇧ tolerated.
- Model: `removeSelectedFromFolder` over a selection, over a lead-only cursor,
  over a widened carousel; last-membership removal re-homes to Unsorted (existing
  F3 suite, extended to the new caller).
- Space: `onDeleteTiles` reaches `requestDelete` and the placement survives until
  confirmation; `onRemoveTiles` still drops only the placement.
- Search: ⌫ is a no-op (assert nothing is staged), ⌘⌫ stages.
- Undo: ⌫ then ⌘Z restores the membership at its old position.

## Effort: **D1–D5 ≈ M total**

## Risks & edge cases

- **This inverts the current grid binding.** Someone with muscle memory will press
  ⌫ expecting a confirm dialog and get a silent removal instead. The removal is
  undoable and shows a toast, and the *dangerous* direction now requires a
  modifier, so the change strictly reduces harm — but ship it with a toast that
  names the verb ("Removed 3 from Refs — ⌘Z to undo") so the difference is
  legible on the first press.
- Unsorted is the one collection where remove ≈ destroy in feel (there is nowhere
  to fall back to). Decide explicitly: recommended is that ⌫ in Unsorted is a
  no-op with a toast saying "Unsorted is the fallback — use ⌘⌫ to delete."
- A text field must never see either binding: the detail sidebar's Name/Note
  fields hold the field editor, and `DetailKeyCatcher` already declines to steal
  from `NSText` (`:1489`) — keep that guard load-bearing.
- Spaces gaining a real destroy is a genuinely new capability on that surface;
  the confirmation copy must say "from the library", not "from this board".

## Open questions

1. ⌫ in Unsorted — no-op with explanation (recommended) or treat as destroy?
2. Should the detail page's ⌫ remove from *the collection it was opened from*
   even when the item lives in several? (Recommended: yes — that is "where you
   are looking".)
3. Keep the confirm dialog for ⌘⌫, or move to toast-with-undo like remove?
   (Recommended: keep the dialog; it is the backstop the inversion relies on.)
