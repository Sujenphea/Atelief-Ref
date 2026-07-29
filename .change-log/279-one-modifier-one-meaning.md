# 279 — One modifier, one meaning

## Summary

065 shipped duplicate and drag-out on the **same key**, split by whether the carried
tiles could leave the board. So ⌥ meant *drag-out* on a photo and *duplicate* on a text
box — a modifier whose meaning depends on what you happen to have grabbed. It also meant
an asset could not be ⌥-duplicated at all.

Each gesture now has its own key:

| gesture | before | after |
| --- | --- | --- |
| duplicate | ⌥-drag, elements only | **⌥-drag, every tile** |
| drag-out | ⌥-drag, assets only | **⌘-drag** |
| toggle selection | ⌘-click | **⇧-click** |
| add to selection | ⇧-click | ⇧-click (same key, now toggles) |
| snapping off | ⌘ mid-drag | ⌘ mid-drag (unchanged) |

## ⌘ could not be taken without moving two things first

**⌘-click toggled selection on the press edge.** A modifier that mutates the selection
as the mouse goes down cannot also start a drag: ⌘-pressing a selected tile would remove
it from the selection and then drag out a set no longer containing the tile under the
cursor. ⌘ is gone from `canvasPressRouting` entirely, so it falls through to the plain
press rules — which is what a drag-out wants anyway (grab an unselected tile and it
becomes the selection; grab a selected one and the whole selection goes).

**⇧ absorbed the toggle.** ⇧ was `.add` and ⌘ was `.toggle`, which is two modifiers for
one job — and on a board with no order, "additive" was never the distinction it is in a
list. ⇧ now toggles, so nothing is lost: ⇧-click an unselected tile adds it, a selected
one removes it.

## ⌘ still means two things, and that is fine

`⌘ mid-drag` turns snapping off, and it stays. The two never collide because the drag-out
read is **latched at mouse-down** while the snapping read is **live**: held from the
start it is a drag-out, which returns before the snapping line executes; pressed once a
move is running it suppresses snapping.

One gesture is genuinely lost: **⌘-dragging an asset to move it without snapping** now
drags it out. Press ⌘ after starting the drag to get the old behaviour.

## ⌘ on tiles nothing can accept does nothing

A frame or text box yields no drag-out payload, and `CanvasDragIntent` gained a `.none`
case for it — the drag never begins. Falling through to a plain move was the obvious
alternative and was rejected: it would restore exactly the ambiguity this change removes,
with ⌘ meaning "leave the board" on an asset and "move without snapping" on a frame.

Giving elements a real drag-out payload is the natural follow-up — 065 already built
`SpaceElementPayload` for the clipboard, so ⌘-dragging a frame to another *board* could
work while a collection refuses it. Strictly additive; not built here.

## Known gap

The duplicate still materialises on **mouse-up**, not at drag start: the original moves
under the pointer and the copy appears when you let go. The end state is right, but
mid-drag the gesture looks like a plain move, so what it will do is invisible until it
is done. Tracked as the next piece of work on this path.

## Files changed

- `CanvasRenderer/.../CanvasSelection.swift` — ⇧ toggles; ⌘ dropped from both routers
- `CanvasRenderer/.../Host/CanvasHostView.swift` — `pressCommandDown`, `dragIntent`
  takes `commandDown`, `.none` early-out, payload built under ⌘
- `AtelierRefs/AtelierRefs/SpaceView.swift` — comments

## Migration notes

None in data. Two behaviour changes users will feel: ⌘-click no longer toggles selection
(use ⇧), and ⌘-drag on an asset drags out rather than moving without snapping.

## Tests

392 renderer, 851 app, 553 core. `HostDragIntentTests` rewritten for the two-key matrix
including both-held precedence; `CanvasSelectionTests` updated for ⇧-toggle and gained a
case pinning that a ⌘ press routes as a plain press.
