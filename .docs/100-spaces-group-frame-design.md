# 100 — Spaces: ⌘G wraps a selection in a frame

> Direction (user): *"is there a group function — select few things to 'group' so
> that it can be moved together"*, then *"so what does Figma do"*. The answer was
> that a board has **frame-as-group** and nothing else: a multi-selection drag
> carries its members, but the association dies with the selection.
>
> Extends [062](./062-spaces-text-resize-design.md) §6, which settled frame
> membership as derived-from-containment and named visibility — not different
> behaviour — as the remedy for its one defect. This doc adds the missing *verb*
> without touching that model.

## 1. What exists, and what is actually missing

Two things already move tiles together:

| | mechanism | lifetime |
| --- | --- | --- |
| multi-selection drag | engine unions the dragged tile with the rest of the selection (`CanvasEngine.swift:381`) | the selection |
| frame-as-group | `SpaceContent.groupMembers` — every tile whose **centre** is inside the frame's world rect (`SpaceContent.swift:192`) | the frame |

So "move together" is solved. What is missing is the one-keystroke way to *get*
a frame around tiles you have already selected. Today it is: note where the
cluster sits, press `F`, drag a rect around it by eye, and hope you enclosed the
centres you meant.

**⌘G is that keystroke, and nothing more.** It creates an ordinary frame at the
selection's bounding box. It does not create a new entity, a stored member set,
or a parent pointer.

## 2. Why not a real group

Figma has two containers: a **group**, whose bounds *are* its children's bounds
and whose membership is stored parentage; and a **frame**, an independent
rectangle that also stores parentage but *establishes* it geometrically, once, at
drop. Resizing a group scales its contents; resizing a frame applies per-child
constraints, defaulting to Left+Top.

062 §6 already took the frame half of that and rejected the group half, on
grounds that hold here unchanged: on a moodboard you draw a rect around a cluster
and later drag its edge out to fit more in, and the references you placed must
not move or grow.

The user was asked directly whether membership should become stored parentage,
and chose to **keep it derived**. ⌘G therefore inherits containment semantics
wholesale. Every consequence below follows from that one decision.

## 3. The adoption problem

A frame drawn at the selection's bounding box contains every selected tile by
construction — a bounding box contains its members' centres. It may also contain
tiles that were **not** selected, when one happens to sit between the ones that
were:

```
   ▣ selected        ◻ not selected

   ┌──────────────────────┐
   │  ▣          ◻        │   ◻'s centre is inside the box,
   │        ▣             │   so the frame adopts it — and a
   │  ▣            ▣      │   later drag will carry it.
   └──────────────────────┘
```

Three ways out were put to the user:

1. **Accept it silently.** The frame means "this region"; the resize wash already
   makes membership legible the moment anyone touches the edge.
2. **Shrink to exclude.** Nudge the bounds inward to the tightest rect holding
   every selected centre and no other. Rejected: it can fail outright (a stray
   tile dead in the middle has no such rect), so the feature would sometimes
   silently do something other than what it says.
3. **Wash at creation.** Create the frame at the honest bounding box, and wash
   the adopted-but-unselected tiles the way a resize already washes prospective
   members.

**Chosen: 3.** It is 062 §6's own principle applied to a second gesture — *"the
fix is visibility, not different behaviour"* — and it reuses that fix's machinery
rather than inventing a rule. Option 2 was the only one that would have made ⌘G
mean something different from `F` plus a careful drag, and a shortcut that
quietly reshapes your geometry is worse than one that shows you what it did.

## 4. Behaviour

**Binding.** ⌘G on a board, live at any selection of **2 or more** tiles.
Withdrawn while a text box is being edited, the bargain `undoRedoBar` and
`duplicateButton` already strike: a key equivalent is dispatched before `keyDown`
reaches the first responder, so a live binding would fire mid-sentence.

**Geometry.** The union of the selected tiles' world frames, outset by a padding
constant. Padding is what makes the result look drawn rather than computed — a
frame flush against its contents reads as a bug.

**z.** Lowest, via the existing `behind: true` path in `addFrame` — frames sit
under board content so the references they group draw on top.

**Selection after.** The new frame, alone. `addElement` already does this, and it
is right: the frame is what you just made, and it is what you will drag.

**Undo.** One step, "Group in Frame", through the existing `registerReversible`
seam in `addElement`. It reverses to exactly the prior state because nothing but
the frame was created — no tile was moved, restacked, or reparented. This is a
direct dividend of derived membership.

**Single selection.** Disabled. One tile in a frame is not a group, and the
gesture would read as decoration.

**A selected frame among the selection.** No special case. It contributes its
world frame to the union like anything else, and the new frame ends up behind it.
Nested frames are not a hierarchy here — each independently asks the same
containment question — so nothing needs to be taught about nesting.

## 5. The wash at creation

The engine's membership highlight is already a general mechanism: a set of ids
(`prospectiveMemberIDs`), a layer pool, and `updateMembershipHighlights` drawing
a **fill** — deliberately not a border, since the border idiom belongs to
selection and these tiles are not selected (`CanvasEngine.swift:1049`).

Resize is currently its only driver. This adds a second: a timed wash the host
can raise for a set of ids and that clears itself. The drawing code, the layer
pool, and the recycling rules do not change.

Only the **adopted** tiles are washed — members that were not in the selection.
Washing all members would say "here is what is in the frame", which the user can
see; washing the adopted ones says "here is what you did not ask for", which is
the only new information the gesture produces. When the selection is exactly the
membership, nothing flashes, which is the common case and correctly silent.

## 6. Phases

Each phase is independently committable and leaves the app working.

**P1 — model.** A pure `groupBounds(for:in:)` returning the padded union plus the
adopted-id set, and `SpaceModel.groupSelectionInFrame()` calling `addFrame`.
Tests: padding; adoption detected; a selected frame contributes its own rect;
fewer than two tiles is a no-op.

**P2 — binding.** The ⌘G button and shortcut in `SpaceView` (mounted so the
binding survives, withdrawn while editing), and the `KeyMap` row in
`spaceShortcuts` with its `source:`. `KeyMapTests`' collision check must stay
green — `G` is unbound today on every scope, so it should.

**P3 — wash.** The engine's timed-wash driver, and `SpaceView` raising it for the
adopted set after creation. Tests: the wash clears itself; an empty adopted set
raises nothing.

## 7. What this does not do

No stored parentage, so a resize still silently changes membership — visible
mid-gesture, per 062 §6, and unchanged here. No drill-in selection: clicking a
tile inside a frame still selects that tile, which the user confirmed. No
⇧⌘G ungroup — the inverse of ⌘G is deleting the frame, which ⌫ already does, and
a second chord for it would imply a binding that does not exist. No camera
framing shortcut; the open-time fit stays the only camera move.
