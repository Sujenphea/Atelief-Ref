# 062 — Spaces Text Resizing: one behaviour, plus handles

> **Amended by [063](./063-spaces-text-autowidth-plan.md).** §2's decision to drop
> auto-width was **reversed**, on the grounds 062 itself named. Its objection was that
> the mode would be reachable only by gesture — *"a hidden consequence of an action
> rather than a state the user can see"* — and that was correct at the time, because
> the segmented picker had just been deleted and the format bubble did not yet exist in
> its current form. 063 gives the mode a labelled Width control in both the bubble and
> the inspector, which is the condition 062 set. Everything else here stands, including
> the invariant that matters most: **the height is always derived from the text and is
> never the user's to set.** 063 extends that reasoning to the width for boxes that opt
> in; it does not weaken it. The legacy `resizeMode` field remains inert — 063 uses a
> new `textAutoWidth` flag precisely so pre-062 rows stay unaffected.

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

**Snapping** applies to both gestures — `ResizeSnapping` was renamed
`CanvasSnapping` once moves started using it, since the name would otherwise be
actively misleading. A **resize** snaps the dragged point; a **move** snaps the
carried set's BOUNDING BOX, which can align on any of its three lines per axis
(leading edge, centre, trailing edge) against any of a candidate's three — that is
what makes both "line this up under that" and "centre it on that" fall out of one
gesture. Snapping the box rather than each tile is what keeps a group from tearing
itself apart, and carried tiles are excluded as targets or the drag would seize up
snapping to itself.

Two rules carry the design:

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

## 7. Resizing the tile being edited

A text box can be resized **while its inline editor is open**, and nothing about
this was designed — it fell out of two independent decisions and was broken until
262.

While `editingTileID` is set, `sync()` blanks that tile's `CATextLayer` (054 §5.2)
so the `NSTextView` above it isn't doubled. Everything §2–§4 specifies about a live
resize — the fitted height, the shaping width taken from `displayWorldFrame` — is
drawn through that layer. So for the one tile being edited, **the entire glyph path
is inert**: the text on screen belongs to the editor, and the engine is drawing only
the box, the border and the handles.

The editor places its overlay imperatively from the tile's on-screen frame, and
until 262 its only cue to do that again was `onTransformChanged`. A resize moves the
box with the camera standing still, so the cue never came: the box narrowed and the
text, still laid out for the old width, spilled out of it.

Two smaller decisions let the gesture start at all, and both are worth keeping:
`handleTile` doesn't consult `editingTileID` (so the handles stay live on a box you
are editing, as in Figma), and `PassThroughContainer.hitTest` returns `nil` for its
own area, so a press on the outer half of a handle's grab zone reaches the canvas.

The fix is a second notification, `onLiveFrameChanged`, fired per resize tick and on
commit. It is deliberately **not** `onTransformChanged`: the camera did not move, and
a notification that misreports its cause is worse than a second one. Both land on
`CanvasEditingBridge.geometryDidChange()`, since the editor only needs to know that
the frame moved — its `reposition()` already re-measures the current string against
the tile's width.

The general rule this leaves behind: **anything that changes a tile's displayed frame
must notify, whoever moved it.** The engine is not the only thing drawing that tile.

### The box must grow while you type

The same split has a second half. 054 §5.2 (R16) kept the canvas out of the keystroke
path on purpose — the editor grew its own overlay, the engine was left alone. That was
right when a `.fixed` box's height was the user's and had no business chasing the text.
**062 removed the premise:** the height is derived from the text now, so a box that
doesn't grow as you type is showing a size that stopped being true at the first
keystroke, with its own border and handles sitting inside its glyphs until commit.

So the editor pushes its measured world height to `setEditingBoxHeight(_:)` from
`reposition()` — not from `textDidChange` — so the two stay in step whatever moved
them. The engine applies it to `editingTileID`'s displayed frame, **height only and
last**, after the drag/resize overrides. That ordering is the 062 split made literal:
the width is the user's (stored, or the one a handle drag is setting this instant),
the height is the text's, and while an editor holds the text it holds the height.

It is transient by design — not a provider mutation, not a write. Nothing persists
until the edit commits, so an abandoned edit leaves no trace and the undo stack gets
one entry rather than one per keystroke.

## 8. Formatting where the text is

The last piece of Nook's text model is not sizing at all — it is that formatting
lives **on the canvas**: a bubble by the box rather than a glyph in the bottom bar
and a 280pt form.

Ported as SwiftUI chrome over the renderer rather than, as Nook does, rects drawn
into the canvas view and hit-tested in `mouseDown`. `CanvasRenderer` has no business
knowing what an `ElementStyle` is — the seam the inline editor already respects — and
SwiftUI gives us the popovers, hover and keyboard handling for nothing.

**One panel, three segments: `Aa` · size · colour.** Nook floats a second panel of
eleven colour dots permanently above the box, and that is the one part of its layout
we tried and dropped. The strip is 252pt wide — wider than many of the boxes it
formats — so the chrome dwarfed its subject, and two floating panels needed a rule
for what happens when both want the same side of the box at a viewport edge. Folding
the palette into a single dot that opens the eleven removes the panel, the rule, and
the ugliness in one go, at the cost of one click on a recolour.

What remains is pure arithmetic (`SpaceTextChromeLayout`): below the box, centred,
flipped above when the viewport's bottom leaves no room, clamped at either side. It
is tested across a sweep of box positions rather than eyeballed, because the flip is
conditional and a case the branch misses shows up at an edge, where it is hardest to
notice by hand.

The panel is **fixed screen size** — chrome, not content, so the zoom does not
reach it. It tracks the box through one published `CGRect`
(`SpaceTextChromeAnchor`), off the `SpaceView` body diff, from the same two geometry
notifications the editor listens to. That is what surfaced the last hole in §7's
notification: it fired for a resize drag but not a move drag, so chrome anchored on a
dragged tile detached and snapped back at the drop. `updateDrag` / `endDrag` now fire
it too, `endDrag` only when a drag was actually running.

**It shows while you are editing, not while you have selected.** Formatting belongs
to the act of writing; chrome that appears on every selection is chrome in the way of
every drag. Nook shows its bubble for a selected text object too, and that is the one
piece of its behaviour we deliberately did not take.

The exception is a popover the chrome itself opened. Presenting one takes key-window
focus, which blurs the `NSTextView` and commits — so "only while editing", read
literally, would unmount the bubble the instant its popover appeared. While a popover
is open the target therefore falls through to the sole selected `.text` element,
which is the box that was being edited a moment ago. The popover flags live in
`SpaceView`, not in the chrome, precisely because they have to outlive it.

**Formatting mid-edit.** If the edit does survive the click — a palette swatch opens
no popover, so it should — the restyle arrives while the `NSTextView` is live, and
the editor re-applies typography when the style moves (guarded, so an unchanged style
never resets the font mid-word). The restyle writes the **stored** string, never the
one being typed: a restyle followed by Esc must still abandon the edit. The box stays
the right height meanwhile because the editing height is applied last (§7).

## 9. Known gaps

- **Editor and canvas still use different text engines** (TextKit vs CoreText).
  Unchanged from 060; both now lay out at the same world size against the same world
  width, but Nook uses TextKit for both and concluded the two "can't be made to
  agree". Revisit if a wrap mismatch appears at an edit boundary.
- **The engine still can't measure an uncommitted string itself.** It doesn't need
  to — the editor pushes the height (§7) — but that means the box is only as correct
  as the editor's TextKit measurement while an edit is open, and as correct as
  CoreText's the moment it commits. The two agree today because both lay out at the
  same world size against the same world width; a wrap mismatch would surface here
  first, as a box that changes height slightly on commit.
- **Moves have no membership preview.** Only resizes do. Dragging a tile into a
  frame changes membership just as silently.
- **The floating chrome is text-only and single-target.** A frame has both a fill
  and a stroke, so "recolour" doesn't say which — frames keep the inspector. Nook's
  palette recolours a whole selection; ours formats one box, which is where
  `SpaceModel.updateStyle` writes today.
- **A click on the chrome ends an open edit** (§8), costing a second undo entry and
  the caret. Keeping the edit alive would need the panels in a non-activating window.
- **No spacing/distribution snapping.** Only edge and centre alignment; equal-gap
  snapping between three or more tiles is a bigger feature.
