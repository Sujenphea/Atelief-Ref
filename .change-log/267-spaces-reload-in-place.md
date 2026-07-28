# 267 — A reload keeps the board's camera

## Summary

The board's zoom and pan jumped on ordinary edits: deleting a tile, creating a text
box, pasting an image, changing z-order, and — most obviously — undoing any of them.

One line explains all of it:

```swift
// SpaceView.swift
.id(space.contentVersion)
```

`contentVersion` was bumped in exactly one place, `SpaceModel.load()`. Every bump made
SwiftUI throw the `CanvasHostView` away and build a fresh one, and a fresh host frames
the board to fit on its first layout. So the question is only "what calls `load()`",
and the answer is nearly everything: opening the space, `performBatch` (delete, and the
undo of a delete), `insertPlaced` (drop / paste / add-from-library), `addElement`
(create a frame or text box), both z-ops, and **every undo/redo closure
`applyPlacementEdit` registers — those always pass `reload: true`**, whatever the
forward direction did.

That last one is why the report mentioned alignment. `arrange` itself is clean: it
persists with `reload: false` and signals through `renderRevision`. It is the *undo* of
an align that reloaded, and a z-order click sits in the same `multiBar` row.

`SpaceContent.setElementStyle` already carried a doc-comment naming this exact hazard —
"WITHOUT rebuilding the host (which would reset pan/zoom and drop the double-click
sequence)". 252 fixed it for restyles. This entry generalises that fix to every reload.

## Fix

**A reload updates the `SpaceContent` the renderer already holds, instead of handing it
a new one.** `SpaceModel.load()` now calls `content().reconcile(items:)` and bumps
`renderRevision`; `content()` returns one instance for the model's life; the `.id` is
gone. The host is never torn down, so there is no first layout to reframe on, so the
camera is simply never touched.

### The part that made this more than a one-line change: tile identity

`Tile.id` **was the array index** into `SpaceContent.tiles`/`rows`. That made it a
position, not an identity — and `AppServices.spaceItems` orders rows by `(z, id)`, so a
bring-to-front *already* renumbered every tile on the board. It was survivable only
because a z-op rebuilt the host and reset everything keyed on those ids.

Stop rebuilding and that becomes an active correctness bug. Eleven things in the engine
are keyed on tile id (`selectedTileIDs`, `editingTileID`, `dragTileID`, `dragGroupIDs`,
`resizeTileID`, `textLayers`, `active`, `keyByTile`, `badges`, `selectionLayers`,
`membershipLayers`), plus `SpaceView.editingTileID`, the format chrome's anchor, and the
inline editor's own `tileID`. A renumbering id repoints all of them at different rows.

So the id is now **handed out once and never reused**:

- `nextTileID` allocates monotonically; `indexByTileID` maps id → array slot;
  `tileIDBySpaceItemID` maps row → id.
- Every id-keyed accessor goes through a private `index(ofTileID:)`, and
  `tile(forTileID:)` replaces subscripting `tiles` by id at every call site.
- **Two functions were returning array indices as tile ids** and are fixed:
  `groupMembers(forTileID:in:)` and `tileID(forSpaceItemID:)`.

This was chosen over computing an old→new id remap on each reload. A remap has to be
applied correctly at eleven engine sites plus three app ones, every time, and a remap
bug means the wrong tile is selected or edited — the exact failure class being removed.
Stable ids delete the problem rather than solving it repeatedly. It is safe because
`CanvasEngine.tile(withID:)` already probes `tiles[id].id == id` and falls back to a
linear scan (the index invariant is documented as an optimisation, not a requirement),
and because nothing depends on array order: the culler sorts what it returns by
`(z, id)`, and draw order comes from `tile.z`.

`reconcile(items:)` keeps survivors in their slots with their ids, refreshes them from
the incoming rows (a reload *is* the durable truth, geometry included), drops absentees,
and appends newcomers with fresh ids. `keyByHash` only ever grows, so a row that leaves
and comes back — an undone delete — reuses its decoded bitmap.

### The prerequisite: framing had to move first

Removing the `.id` on its own would have made **every board open blank**.
`SpaceModel.init` fires `Task { await load() }`, and AppKit lays the host out before
that async read returns — so the first `layout()` ran with zero tiles, set
`hasFramedContent = true`, and `frameToContent()` silently no-opped on empty content.
Boards were only ever visible because the post-load `contentVersion` bump built a
*second* host that framed properly.

So the private per-instance `hasFramedContent` is replaced by an explicit contract:

- `CanvasEngine.hasDrawableContent` — the precondition `frameToContent` silently needed.
- `CanvasHostView.framesContentWhenReady` (armed by the app) + `onDidFrameContent`
  (fired the one time framing actually happened, never for a no-op attempt).
- Checked from **both** `layout()` and the `syncToken` didSet, because content now
  arrives with no bounds change and `layout()` alone would never notice it.
- `SpaceView` owns `@State didFrameBoard`. Its identity is stable, so this is a fact
  about the *board* rather than about a view instance — the camera survives even if the
  host is ever rebuilt for some unrelated reason.

## What was planned and dropped

A separate step to make undo/redo apply placements in memory instead of passing
`reload: true`. Once `load()` stopped rebuilding the host, its premise was gone: a
reload no longer moves the camera, so `reload: true` on the undo path is merely a
database read, not a defect. Doing it anyway would have been a speculative refactor of
the undo path for no user-visible gain.

## Files changed

- `AtelierRefs/AtelierRefs/SpaceContent.swift` — stable tile identity (`nextTileID`,
  `indexByTileID`, `tileIDBySpaceItemID`), `tile(forTileID:)`, `append(_:)`,
  `reconcile(items:)`; every accessor routed through `index(ofTileID:)`
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `load()` reconciles; `content()` is a
  single instance; `cachedVersion` deleted; the doc-comments that asserted the old
  rebuild behaviour corrected
- `AtelierRefs/AtelierRefs/SpaceView.swift` — `.id(space.contentVersion)` removed;
  `didFrameBoard` arms the framing one-shot
- `CanvasRenderer/.../Host/CanvasEngine.swift` — `hasDrawableContent`
- `CanvasRenderer/.../Host/CanvasHostView.swift` — `framesContentWhenReady`,
  `onDidFrameContent`, `frameContentIfNeeded()`; checked from `layout()` and `syncToken`
- `CanvasRenderer/.../Host/CanvasView.swift` — the two new pass-throughs, applied
  *before* `syncToken` so its didSet sees current state
- Tests: new `AtelierRefsTests/SpaceContentReconcileTests.swift` (12 cases),
  `AtelierRefsTests/SpaceReloadInPlaceTests.swift` (5),
  `CanvasRendererTests/HostFramingTests.swift` (5); updated
  `SpaceLayoutTests`, `SpaceTextResizeTests`

## Migration notes

**`Tile.id` is no longer an array index.** Never subscript `SpaceContent.tiles` with a
tile id — use `tile(forTileID:)`. Any new provider seam that returns tile references
must return `tile.id`, not a position. (`CanvasContent`, the collections-grid provider,
is untouched and still index-based; it has no reload-in-place path.)

**`contentVersion` is observability only.** Nothing is `.id`-bound to it. It now means
"a reload added or removed a row", and does not bump for a geometry-only reload.

**`renderRevision` bumps on reload too.** It is the canvas's only redraw signal now that
there is no `.id` swap. `SpaceTextResizeTests.textChangeGrowsHeightFreezesBox` was
updated for this: a restyle followed by an explicit `load()` is two bumps, and the test
now pins both separately rather than asserting one.

**`CanvasHostView` no longer frames itself.** A host constructed without
`framesContentWhenReady` still defaults to `true`, so existing callers are unaffected,
but a caller that wants the camera left alone must pass `false`.

Both suites green: 326 in `CanvasRenderer`, and the `AtelierRefsTests` target.

## Still open

Entering edit mode still re-wraps the text: committed glyphs are laid out by CoreText
(`TextShaper`), the editor's by TextKit (`NSTextView`). One engine — TextKit — for both,
tracked for `.docs/063`. Note that on macOS 26 `NSTextView` defaults to TextKit **2**,
so which TextKit has to be settled before the port, not during it.
