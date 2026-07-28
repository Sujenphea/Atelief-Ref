# 274 — Duplicate, and a clipboard that understands the board

## Summary

Three gaps with one cause — the board could only clone **assets**:

- no duplicate at all (no ⌘D; ⌥-drag was taken by drag-out);
- **⌘C on a text box copied nothing** — `onCopyTiles` `compactMap`ed the selection down
  to rows that have an asset, so element rows were dropped by design;
- **⌘V of plain text created nothing** — `importExternal` only makes assets.

## What landed

- **⌘D** duplicates the selection, offset down-right, selecting the copies.
- **⌥-drag duplicates element tiles.** Asset tiles keep ⌥ for drag-out (059 · SP7).
- **⌘C writes two representations** of one selection — the existing asset one, plus a
  new `SpaceElementPayload` carrying every row with its relative layout.
- **⌘V** rebuilds a copied piece of board, or falls through to the importer, or — last —
  makes a text box from plain text.

## The decisions worth knowing

**⌥'s tie-break is "can these tiles leave the board".** Element tiles yield no drag-out
payload and *already* fell through to a plain move, so duplicate takes exactly that room
and no existing gesture changes meaning. The precedence is a pure function
(`CanvasHostView.dragIntent`) because gesture ordering in that file has shipped a bug
before.

**A drag latches its meaning at the start.** Re-reading ⌥ at drop would let releasing the
key mid-drag turn a duplicate into a move — losing the copy *and* moving the original.

**Paste order is the design.** Plain text is last, because a pasteboard carrying a URL
also carries it as a string — running it earlier would turn every pasted link into a text
box. The board payload is first for the mirror reason: a copied text box also puts its
string on the pasteboard.

**Copy order is load-bearing.** `AssetPasteboardWriter.write` calls `clearContents()`, so
the board representation is written after it — and an element-only selection skips the
asset writer entirely, which would otherwise report "0 copied" for a copy that worked.

**One clone core.** ⌘D, the ⌥-drop and paste all end in `insertRows`, routed through
`performBatch` — the primitive create/delete undo already uses. Because a row carries
`kind` and `assetID`, one function serves a text box, a frame and an asset placement;
duplicating an asset row makes another *placement*, never another asset.

## Known limitation

A frame containing asset children carries a drag-out payload through those children, so
⌥-dragging it drags out rather than duplicating. ⌘D covers that case. This follows from
"drag-out wins wherever it applies"; the alternative would make ⌥ depend on where within
a group you grabbed.

Also accepted: during an ⌥-drag the **originals** move and the copies are created at the
drop (the originals then snap back). End state matches Figma; only the in-flight look
differs. The exact version needs a renderer tile that outlives no database row yet, which
`reconcile` could drop mid-drag — noted as a follow-up.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceModel.swift` — the clone core, paste, `pasteText`
- new: `AtelierRefs/AtelierRefs/SpaceElementPayload.swift`
- `AtelierRefs/AtelierRefs/SpaceView.swift` — ⌘D, `onDuplicateTiles`, copy + paste order
- `CanvasRenderer/.../Host/{CanvasHostView,CanvasEngine,CanvasView}.swift`
- new tests: `SpaceDuplicateTests` (13), `HostDragIntentTests` (4)

## Migration notes

None. No schema change — a duplicate and a paste both create ordinary `space_item` rows.
The new pasteboard type is app-private and needs no `Info.plist` entry, since it is only
ever read by this app's own paste rather than by a drag destination.

## Tests

370 renderer tests, 810 app tests. Full write-up in
`.docs/065-spaces-duplicate-clipboard-plan.md`.
