# 065 — Duplicate, and a clipboard that understands the board

> ⌘D, ⌥-drag, and making ⌘C / ⌘V work on text boxes and frames instead of silently
> doing nothing. Follows [062](./062-spaces-text-resize-design.md) (elements are
> first-class board content) and 059 · SP7 (drag-out).

## 1. The problem

Three complaints, one cause — **the board could only clone assets**:

- No duplicate at all. No ⌘D, and ⌥-drag was already spoken for by drag-out.
- **⌘C on a text box copied nothing.** `SpaceView.onCopyTiles` `compactMap`ed the
  selection down to rows that *have* an asset, so element rows were dropped on the
  floor by design — and ⌘V had nothing to rebuild them from.
- **⌘V of plain text created nothing.** `importExternal` only knows how to turn a
  pasteboard into *assets*.

## 2. Decisions

### 2.1 ⌥ is overloaded, and drag-out keeps it

⌥-drag already starts a board→board / board→collection `NSDraggingSession`
(059 · SP7). Rather than move a shipped gesture, the tie-break is **"can these tiles
leave the board at all"**:

| grabbed | ⌥-drag |
| --- | --- |
| asset tiles (anything with a drag-out payload) | drag-OUT, unchanged |
| element tiles — frame, text — which yield no payload | **duplicate** |

That second row is not new territory: ⌥ on element tiles *already* fell through to a
plain move, because there was nothing to drag out. 065 takes exactly that room and
nothing else, so no existing gesture changes meaning.

The precedence lives in one pure function, `CanvasHostView.dragIntent`, for the same
reason `canvasPressTarget` does: gesture ordering in this file has shipped a bug before
(the double-click that lost to a resize handle), and an ordering that matters belongs
somewhere a test can pin it.

**Known limitation, accepted.** A frame containing asset children carries a drag-out
payload *through its children*, so ⌥-dragging it drags out rather than duplicating.
⌘D covers that case. This follows directly from "drag-out wins wherever it applies",
and the alternative — inspecting the grabbed tile rather than the carried set — would
make ⌥ mean different things for the same drag depending on where you grabbed it.

### 2.2 A drag latches its meaning at the start

`isDuplicatingDrag` is set when the drag passes the threshold, from the modifier state
captured at **mouse-down**. Re-reading ⌥ at drop would let releasing the key mid-drag
silently turn a duplicate into a move — losing the copy and moving the original instead.

### 2.3 The originals move during an ⌥-drag; the copies land at the drop

Figma leaves the original visible and drags the copy. Ours drags the originals, and on
mouse-up reports the offset *without* persisting the move — so the originals snap back
and the copies are created at the drop. **The end state is identical**; only the
in-flight appearance differs.

The visually exact version needs a tile that exists in the renderer before its database
row does. `SpaceContent.nextTileID` now makes that expressible, but `reconcile` could
drop such a tile mid-flight, so it is a follow-up rather than the first cut.

### 2.4 Two representations of one copy

⌘C writes **both**, and the destination decides what the copy meant:

- the existing asset representation (052 · B1) — what a collection or another app uses;
- `SpaceElementPayload` — every row *including* frames and text boxes, with relative
  layout, for pasting onto a board.

Order is load-bearing: `AssetPasteboardWriter.write` calls `clearContents()`, so the
board representation must be written **after** it. And a selection of only text boxes
skips the asset writer entirely — it would clear, write nothing, and report *"0 copied"*
at the user for a copy that in fact succeeded.

`SpaceElementPayload` stores geometry **relative to the selection's top-left** and
normalises `z` to start at zero, which is what makes a copy independent of where it came
from — the whole point of a clipboard. It deliberately does *not* carry `id`, `spaceID`
or timestamps: those are facts about the row it was copied from, and carrying them would
invite a paste that re-uses them.

Unlike `AssetDragPayload` it needs **no `Info.plist` `UTExportedTypeDeclarations`
entry** — that declaration exists so the OS recognises the identifier at a *drag*
destination, and this type is only ever read by this app's own paste.

### 2.5 Paste order is the design

```
1. a copied piece of a board  → rebuild it, layout intact
2. importable external content → unchanged (files, images, URLs)
3. plain text                  → a text box
```

**Plain text must be last.** A pasteboard carrying a URL also carries that URL as a
string, so running branch 3 earlier would turn every pasted link into a text box instead
of a reference. Branch 1 must be first for the mirror-image reason: a copied text box
*also* puts its string on the pasteboard, and branch 3 would happily consume it.

An empty payload decodes as `nil` rather than as an empty hit, so a copy that carried
nothing cannot stop the chain at branch 1.

## 3. One clone core

⌘D, the ⌥-drag drop and a paste all end in `SpaceModel.insertRows(_:name:)`, which
routes through `performBatch` — the same primitive create/delete undo already uses.
All three **are** creates; giving any of them its own write path is how they drift.

`duplicatedRows` is pure and holds the three rules that are each a bug if missed:
fresh `id` with everything visible carried; relative `z` order preserved; `spaceID`
carried rather than re-read (a paste rewrites it, a duplicate does not).

Because a row carries `kind` and `assetID`, **one function serves a text box, a frame
and an asset placement** — and duplicating an asset row makes a second *placement* of
the same asset, never a second asset.

## 4. Files changed

- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `duplicatedRows`, `insertRows`,
  `duplicate`, `duplicateSelection`, `duplicateTiles`, `pasteElements`, `pasteText`,
  `addText(worldRect:string:)`
- new: `AtelierRefs/AtelierRefs/SpaceElementPayload.swift`
- `AtelierRefs/AtelierRefs/SpaceView.swift` — ⌘D button, `onDuplicateTiles`, the two-
  representation copy, `pasteOntoBoard`'s branch order
- `CanvasRenderer/.../Host/CanvasHostView.swift` — `onDuplicateTiles`, `dragIntent`,
  `isDuplicatingDrag`, the duplicate branch in `mouseUp`
- `CanvasRenderer/.../Host/CanvasEngine.swift` — `currentDragWorldOffset()`
- `CanvasRenderer/.../Host/CanvasView.swift` — pass the callback through

## 5. Tests

`SpaceDuplicateTests` (13) and `HostDragIntentTests` (4). The ones that would catch a
real regression:

- **⌥ precedence**, all four combinations — the one that matters is
  `optionDown + hasDragOutPayload` resolving to `.dragOut`; if that ever flips,
  board→collection drag breaks silently.
- **relative `z` survives a duplicate**, with deliberately out-of-order input, since
  sources arrive from a `Set`.
- **an empty payload reads as `nil`** — the guard that stops branch 1 swallowing a
  paste.
- **a payload is position-independent** and rebuilds its layout on any board.
- **⌘D is one undo step** for N, and redo brings them back.
- **whitespace-only text pastes nothing**.

## 6. Manual verification

1. ⌘D a text box → a copy appears down-right, selected; ⌘Z removes it in one step.
2. ⌥-drag a text box or frame → the copy lands at the drop, the original stays.
3. ⌥-drag an **asset** tile to a sidebar collection → drag-out still works.
4. ⌘C a text box, ⌘V → it comes back with its style; ⌘V on a *different* board too.
5. Copy a mixed selection (an image + a text box) → pasting on a board gives both,
   pasting into a collection still gives the image.
6. Copy a URL from a browser, ⌘V → still a reference, **not** a text box.
7. Copy a paragraph from any app, ⌘V → a text box, height derived from the text.
8. ⌘D while typing in a text box → nothing duplicates, the keystroke is not eaten.
