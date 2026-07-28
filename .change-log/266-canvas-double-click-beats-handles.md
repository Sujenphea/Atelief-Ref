# 266 — A double-click reaches the text editor again

## Summary

Double-clicking a text box to edit it did nothing most of the time. No caret
appeared, and because the canvas had already taken first responder, the keystrokes
that followed went to `CanvasHostView` and beeped.

It was not a race and not the editor's fault. `mouseDown` resolved its gesture
precedence in this order:

```swift
// Gesture precedence (049 · D8 · 062), highest to lowest:
//  1. A create tool (`.frame` / `.text`) → rubber-band a NEW element.
//  2. `.select` on a resize HANDLE → a resize candidate.
//  3. `.select` on a TILE → a drag candidate (press routing selects).
//  4. `.select` on EMPTY space → a marquee candidate (or click-to-clear).
```

`onActivateTile` — the only double-click hook there has ever been — lived inside
step 3. Step 2 returned early. So the question is whether a double-click's second
press can land on a handle, and the answer is: almost always.

- The first click of a double-click applies its selection **synchronously**
  (`applySelection` → `engine.setSelected`), so by the second press the eight
  handles are live.
- Handles belong to the single selected tile, and every kind is resizable.
- `ResizeGeometry.handleHitSize` is 22 screen points **centred on each handle**, so
  each zone reaches 11 points inward from every edge and corner.

A text box is short by nature. At 16pt (the 265 default) it is about 28 screen
points tall, so the top band claims 11 points, the bottom band another 11, and the
corners take the ends — leaving a strip about 6 points tall across the middle as
the only part of the box that was double-clickable. Below roughly 1× zoom, none of
it was. `PressTargetTests.shortBoxIsAlmostEntirelyHandle` pins that arithmetic so
the geometry can't quietly drift back.

## Fix

**Precedence moved out of `mouseDown` into a pure function.** `canvasPressTarget`
returns a `CanvasPressTarget` — `.create` / `.activate` / `.resize` / `.tile` /
`.empty` — and a double-click on a tile now resolves to `.activate` *ahead of* the
handles. Activation is not a geometry gesture, so it takes the press outright and
arms nothing: no drag candidate, no resize candidate, an inert mouse-up.

The order is now pinned by `PressTargetTests` rather than implied by the shape of a
nested `if` chain inside an `NSView` no headless test can reach. This is the same
posture the file already had for `exceedsDragThreshold`, `normalizedRect` and
`canvasPressRouting`.

Two behaviours were preserved deliberately:

- **Above two clicks the handle keeps precedence**, exactly as before — a third
  click is not an activation, and the press is a resize candidate again.
- **Resizing while editing still works** (262 / 263). The fix is in the *press*
  ordering, not in the handles: excluding `editingTileID` from `handleTile` would
  have made double-click work by deleting a shipped feature.

The selection now lands on the down edge (`applySelection(.selectOnly(tileID))`)
where the old path deferred it to `pendingClickAction` on the up edge. Same
outcome, one event sooner, and it no longer depends on a mouse-up the activation
has made inert.

## Second defect, same path: the editor committed itself on mount

`CanvasEngine.currentScreenFrame(forTileID:)` resolved its tile out of
`currentVisibleTiles()`, which returns nothing at all while `viewportSize` is still
`.zero` — i.e. before the first `layout()`. `InlineTextEditor.reposition()` read
that `nil` as *the tile left the viewport* and called `finish(committed: true)`
immediately (§5.4), from inside a SwiftUI view-insertion pass, which also mutated
`@State editingTileID` during a view update.

The culler is a rendering optimisation, not a statement about whether a tile
exists. So the two questions are now separate:

- `CanvasEngine.screenFrame(forTileID:)` — **where** a tile is. `nil` only when the
  id resolves to no tile.
- `CanvasEngine.isVisible(tileID:)` — whether it can be **seen**.
- `currentScreenFrame(forTileID:)` is kept, redefined as
  `isVisible ? screenFrame : nil`. Callers depend on exactly that: the drag-out
  snapshot has no image to make for an off-screen tile.

`inlineEditShouldCommitOnViewportExit` takes the visibility answer plus the
viewport size and a `hasPositioned` flag, so an editor that has never placed itself
holds its ground and only a tile that *was* on screen and then left commits.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/CanvasSelection.swift` — new
  `CanvasPressTarget` + `canvasPressTarget(...)`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `mouseDown`
  switches on the target; `screenFrame(forTileID:)` no longer visibility-gated; new
  `isTileVisible(_:)` and `viewportSize`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — new
  `screenFrame(forTileID:)` / `isVisible(tileID:)`; `currentScreenFrame` derived
- `AtelierRefs/AtelierRefs/InlineTextEditor.swift` — the re-cut exit predicate, a
  `hasPositioned` flag, and bridge passthroughs for visibility / viewport
- `CanvasRenderer/Tests/CanvasRendererTests/PressTargetTests.swift` — new, 10 cases
- `CanvasRenderer/Tests/CanvasRendererTests/TransformSeamTests.swift` — the
  gated/ungated split
- `AtelierRefs/AtelierRefsTests/SpaceInlineEditTests.swift` — the new predicate
  arity plus the first-layout-never-commits case

## Migration notes

`CanvasEngine.currentScreenFrame(forTileID:)` and
`CanvasHostView.screenFrame(forTileID:)` no longer mean the same thing. The host's
accessor is now the **ungated** one; anything that wants "nil when off-screen" must
say so, either by using the engine's `currentScreenFrame` or by asking
`isTileVisible(_:)`.

`inlineEditShouldCommitOnViewportExit(screenFrame:)` is gone; the replacement takes
`(isVisible:viewportSize:hasPositioned:)`.

Nothing persisted changes, and no behaviour outside these two paths moves. Both
suites are green: 321 in `CanvasRenderer`, and the `AtelierRefsTests` target.

## Still open

This entry fixes the double-click and the self-commit. The other two defects
reported alongside them are separate work:

- **Entering edit mode re-wraps the text.** Committed glyphs are laid out by
  CoreText (`TextShaper`), the editor's by TextKit (`NSTextView`), and the two break
  lines differently. The fix is one engine, TextKit, for both — see `.docs/063`.
- **The board's zoom/pan jumps** on delete, on create, and on any undo.
  `SpaceView` binds the canvas with `.id(space.contentVersion)`, and every
  `SpaceModel.load()` bumps it, so the host is rebuilt and the new instance reframes
  to content. The fix is an in-place reload.
