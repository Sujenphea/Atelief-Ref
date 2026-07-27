# 062 — Spaces Text Resizing: one behaviour, plus handles

> Retires the three-way text resize mode and gives text boxes drag handles.
> Modelled on Nook's Easel (`ref/Nook`), which solves this with a single rule.
> Follows [060](./060-spaces-text-render-design.md) / [061](./061-spaces-text-render-plan.md),
> which made text *rendering* zoom-stable; this makes text *sizing* controllable.

## 1. The problem

Text carried a three-way `resizeMode`, and every option failed a user who simply
wanted a paragraph to wrap to a width they chose:

| mode | behaviour | outcome |
| --- | --- | --- |
| `.fixed` (**the default**) | `autosizedFrame` returned `nil`; the box never grew | text overflowed and the canvas shaper truncated it with `…` |
| `.autoWidth` | shaped with `maxWidth: nil` | one runaway line; never wrapped |
| `.autoHeight` | width frozen at `item.w` | correct — but the width was set at create time and unreachable forever after |

The root cause was not any one mode: **nothing on the canvas could be resized.**
`CanvasHostView` had move, marquee, and create drag modes and no resize. The
existing code said so outright — *"the width that `autoHeight` wraps to is the
create-time width (no resize handles in Phase 2)"*. So the only width control was a
segmented picker in an inspector popover, and none of its three options meant "wrap
to a width I choose".

A secondary mismatch made `.fixed` worse than it looked: neither the editor nor
`TextRenderLayer` sets `clipsToBounds`, so overflowing text **spilled visibly while
typing** and was then cut with `…` on commit.

## 2. The decision — Nook's model

Nook has no resize mode. A text object obeys one rule:

> **The user owns the width. The height is always derived from the text wrapped to
> that width.**

`refitTextHeight` runs at exactly four moments — create, every keystroke, every
style change, and the end of a resize drag — so the box is re-fitted after anything
that could change how the text lays out. All eight handles are live; the vertical
component of a drag is simply discarded by the refit. Resizing never scales glyphs
(font size is a style, changed only through the format controls).

We adopt this wholesale. `TextResize` is deleted.

### Why this and not a two-mode variant

Keeping `.autoWidth` (hug the text) alongside was tempting — it is genuinely useful
for short labels, and it was already built and tested. It was rejected because the
mode has to be *reachable*: with no picker it can only be entered by a gesture, and
the only sensible gesture (drag a side handle → become fixed-width) makes the mode a
hidden consequence of an action rather than a state the user can see. One rule that
always holds beats two rules the user has to infer. A box that hugs its text is
still one drag away.

**Consequence, accepted:** boxes that were silently truncated under `.fixed` grow
downward on first load to reveal their full text. Existing boards re-flow. That is
the fix working, but it does change already-placed layouts.

## 3. Design

### 3.1 Sizing — `SpaceModel`

`autosizedFrame(item:style:)` loses its switch. It freezes `x`, `y` and `w`,
measures the text through `TextMetrics` (→ `TextShaper`, the same shaping the canvas
draws with, per 060) at `w − 2·padding`, and returns a frame differing only in
height — or `nil` when the height already matches.

Because the same function runs after every text and style edit, **truncation becomes
unreachable**: the box always fits its content. `addText` derives the height at
create time too, so a box is never born at the dragged height.

### 3.2 Handles — `CanvasRenderer`

`ResizeHandles.swift` holds the pure geometry, split deliberately across two spaces:

- **Hit-testing is in SCREEN space.** A grab zone must stay the same physical size
  at every zoom; expressed in world units it would shrink with the box and become
  unhittable when zoomed out. 22pt grab, 8pt dot.
- **The resulting frame is in WORLD space.** That is what gets persisted.

This is the same world-vs-screen discipline 060 settled for glyphs. Corners are
tested first over a square zone and edge bands exclude the corner zones, so the
overlap resolves to the corner — the handle that does strictly more.

`CanvasEngine` gates handles to a **single selected tile** — a multi-selection shows
none, because resizing several boxes at once has no one sensible meaning. Which
kinds qualify, and how each answers a new width, is §5. The live resize mirrors
the drag path exactly — transient frame, provider untouched, host persists then
syncs — and each update recomputes from the frame captured at `beginResize` rather
than accumulating, so a long drag cannot drift.

### 3.3 Commit — one gesture, one undo step

`SpaceModel.resizeTile(tileID:to:in:)` takes the dragged rect, treats its origin and
**width** as authoritative, re-derives the **height**, and writes both as one
placement edit named `"Resize"`. One ⌘Z restores the previous width and height
together — the same folding `updateStyle` already does for restyle + auto-size.

### 3.4 Storage

`resizeMode` stays in `ElementStyle` as a legacy, unread field. Rows written by
older builds keep decoding and round-tripping; removing the property would silently
discard the key on the next save. Nothing reads it, and nothing writes it any more.

## 4. Test posture

Pure and headless throughout:

- `ResizeHandleTests` — placement, hit-testing (including corner-beats-edge, a
  forgiving near miss, and a box smaller than its own handles), per-handle edge
  ownership, and clamping when a drag crosses its own anchor.
- `EngineResizeTests` — the policy (single selection; image ratio locked, text not),
  hit-testing through the transform (including a zoomed-out grab, the screen-space
  regression), the live-drag machine (no provider mutation, no accumulation drift,
  safe no-ops), and snapping end-to-end (snaps to a neighbour, never to itself, ⌘
  disables, the radius follows the zoom).
- `ResizeSnappingTests` — the snapping rules in isolation: nearest target wins, a
  side handle never snaps off-axis, a corner resolves each axis independently, a
  ratio-locked snap preserves the ratio exactly and refuses to breach the minimum.
- `SpaceTextResizeTests` — the model contract: height follows the text, `x`/`y`/`w`
  never move on their own, the box always fits its text, a resize is one undo step.
- `SpaceInlineEditGeometryTests` — the editor's box is still byte-identical across
  0.25×–8× (060's guarantee, re-pinned against the simplified geometry).

The only non-headless surface is the drag itself — cursor feel and grab accuracy —
recorded in the changelog as a manual check.

## 5. Snapping and ratio lock

Added in the same series, modelled on Nook again.

**Handles reach every kind.** Aspect lock is meaningless on text — `fittedFrame`
overrides the height with the text's — so it only becomes a real feature once
images and frames can be resized. Each kind answers a width differently, and that
difference lives in one place rather than in the gesture: text re-derives its
height, an **image holds its ratio permanently** (a distorted photograph is never
what the user meant, so the lock is the default rather than something to remember),
and a frame simply takes the rect — it is a boundary, not a scaler, so its contents
keep their own positions.

**⇧ locks any tile's ratio; ⌘ turns snapping off** — the same "put it exactly where
I say" escape the move gesture offers.

**Snapping** pulls a dragged edge onto a nearby box's edge or centre. Two rules
carry the design:

- The threshold is **6 SCREEN points**, divided by the zoom. A fixed world radius
  would be unusably sticky zoomed out and imperceptible zoomed in.
- A **ratio-locked** snap cannot move the point — that would break the ratio — so
  the frame is scaled uniformly about its anchor by whatever factor lands a moving
  edge on the target. Only the single nearest snap applies, because two would need
  two different scales and there is only one.

Candidates are the **visible** tiles minus the one being resized. Visible, because
snapping to a box the user cannot see reads as the drag sticking for no reason; and
minus itself, because a box that snapped to its own edge could never be nudged.

A snap may never breach the minimum size — `snapAspectFrame` refuses rather than
scaling below it.

## 6. Frames: resize is a boundary change

Considered and rejected: making a frame resize carry (scale) its contents, to match
the way dragging one moves them.

**Figma settles it.** Figma distinguishes *groups*, which scale their contents
because a group's bounds ARE its contents' bounds, from *frames*, which apply
per-child **constraints** — horizontal Left / Right / Left-and-Right / Center /
Scale, and the vertical equivalents. The default for a new child is **Left + Top**:
resizing a frame leaves children exactly where and what size they were. `Scale` is
opt-in per child.

Ours is a frame, not a group, and the expected outcome is Figma's default. On a
moodboard you draw a frame around a cluster of references and later drag its edge
out to fit more in; the references you carefully placed must not move or grow.
Constraints earn their complexity when a frame is a screen that must adapt at
several sizes — a moodboard has no such requirement, so the whole system (five
options per axis, per child, plus UI to set them) would buy almost nothing.

The move/resize asymmetry this leaves is **not** an inconsistency: Figma has the
same one, because the two gestures answer different questions. Moving a frame
preserves its membership; resizing it is how membership is *changed*.

### The real defect, and the fix

Where we genuinely differ from Figma is that our membership is **derived from
containment** (`groupMembers` returns tiles whose centre is inside the rect), not
stored parentage. So a resize silently evicts or adopts tiles, and the user finds
out later — when they drag the frame and the wrong things move.

The fix is visibility, not different behaviour: while a frame is being resized, the
tiles it will contain on release are washed in accent blue. A fill, not a border —
the border idiom belongs to selection, and these tiles are not selected.

Crucially the engine **asks the provider** (`groupMembers(forTileID:in:)`) rather
than re-deriving containment, and `SpaceContent`'s drag-time query delegates to that
same method with the stored rect. One rule, two callers: the set highlighted mid-
resize is by construction the set a later drag carries.

## 7. Known gaps

- **Editor and canvas still use different text engines** (TextKit vs CoreText).
  Unchanged from 060; both now lay out at the same world size against the same world
  width, but Nook uses TextKit for both and concluded the two "can't be made to
  agree". Revisit if a wrap mismatch appears at an edit boundary.
- **Moves don't snap.** Only resizes do. Nook snaps a dragged object's bounding
  box on move as well; `ResizeSnapping.snapPoint` is reusable for it.
- **Moves have no membership preview.** Only resizes do. Dragging a tile into a
  frame changes membership just as silently.
