# 063 — Spaces text: auto-width boxes

> Reinstates the hug-your-text sizing mode that [062](./062-spaces-text-resize-design.md)
> deleted, as a persistent per-box state with a visible control.
> Follows [060](./060-spaces-text-render-design.md) / [061](./061-spaces-text-render-plan.md)
> (zoom-stable rendering) and 062 (resize handles, derived height).
>
> **Status: implemented**, all six stages. See §10 for where the build departed from
> this plan and why.

## 1. The problem

A click-placed text box is born at a width nobody chose:

```swift
// CanvasHostView.swift:932
static let defaultTextWorldWidth: CGFloat = 260
```

`finishCreate` already separates the two create gestures — a rubber-band drag gives you
the rect you dragged, a click below `minCreateWorldEdge` falls back to that 260×72 box.
`SpaceModel.addText` then measures only the **height** against that width. So the width
of a click-placed box is a literal, and the first thing a short label does is wrap
inside a box three times wider than it needs.

## 2. Reversing 062, and why that is honest

062 considered exactly this and rejected it:

> Keeping `.autoWidth` (hug the text) alongside was tempting — it is genuinely useful
> for short labels, and it was already built and tested. It was rejected because the
> mode has to be *reachable*: with no picker it can only be entered by a gesture, and
> the only sensible gesture (drag a side handle → become fixed-width) makes the mode a
> hidden consequence of an action rather than a state the user can see.

**That objection is answered, not overruled.** 062's premise was that the mode would
have no UI — it had just deleted the inspector's segmented picker and the format bubble
did not yet exist in its current form. It does now, and §3.5 gives auto-width a visible,
labelled, reversible control in both places a text box is styled from. The mode becomes
a state the user sets and can see, which is the condition 062 named.

What survives from 062 untouched is its actual invariant — **the height is always
derived from the text, never set by the user**. Auto-width does not weaken that; it
extends the same reasoning to the width for boxes that opt in.

What 062 got right and this plan keeps: one rule per box, visible in the UI, with the
conversion gesture (drag a side handle → fixed) as a *confirmation* of a state the user
can already see rather than the only way to discover it.

### 2.1 What is left over from the old implementation

The measurement half was never removed. `TextMetrics.size(for:maxWidth:)` documents
`nil` as *"unconstrained (one line / autoWidth)"*, `TextShaper.shape` still implements
that path (pass 1 uses `CTFramesetterSuggestFrameSizeWithConstraints` with an infinite
width and `boxWidth = ceil(suggested.width)`), and `TextMetricsTests` still has a
`// MARK: - Unconstrained (autoWidth: maxWidth == nil)` section. So the shaping work is
done; what is missing is the persisted bit, the live sideways growth, and the control.

## 3. Design

### 3.1 The persisted state — a new field, deliberately not `resizeMode`

`ElementStyle.resizeMode` still exists, carrying `fixed` / `autoWidth` / `autoHeight`
from before 062, retained only so old rows round-trip. **Do not revive it.** Rows
written by pre-062 builds carry those strings, and giving them meaning again would
silently re-flow existing boards — the pre-062 `.autoWidth` rows are precisely the ones
062 describes as *"one runaway line; never wrapped"*.

Add a new, unambiguous field instead:

```swift
/// Text hugs its own width (063): the box's WIDTH is derived from the text, exactly
/// as 062 derives the height, and it never wraps — only an explicit newline breaks a
/// line. nil / false → 062's behaviour: the user owns the width via the handles.
/// Deliberately NOT the legacy `resizeMode`, whose pre-062 values must stay inert.
public var textAutoWidth: Bool?
```

with the accessor pattern the file already uses for `weight` / `align`:

```swift
var hugsWidth: Bool { textAutoWidth ?? false }
```

Migration: none. Every existing row reads `false` and behaves exactly as it does today.

### 3.2 Sizing — `SpaceModel`

`autosizedFrame(item:style:)` gains one branch, and starts returning a rect that can
differ in **x and width**, not only height:

| state | measured with | result |
| --- | --- | --- |
| fixed (062) | `maxWidth: item.w − 2·padding` | x, y, w frozen; h derived |
| auto-width (063) | `maxWidth: nil` | y frozen; w = measured + 2·padding; h derived; **x anchored** |

The anchor is the whole subtlety, so it is its own pure function, tested directly:

```swift
/// Where a hugging box's left edge goes when its width changes. The alignment names
/// the edge the user thinks of as fixed: left-aligned text grows rightwards from a
/// stationary left edge, right-aligned grows leftwards, centred grows both ways.
/// Called on every keystroke of an open edit, so it must be exact rather than
/// approximately right — a half-pixel drift per character is a visible crawl.
static func anchoredMinX(
    oldMinX: CGFloat, oldWidth: CGFloat, newWidth: CGFloat, alignment: TextAlign
) -> CGFloat
```

`refitTextRows` needs no change beyond following `autosizedFrame` — a hugging row is
re-derived in memory on load exactly as 062 re-derives heights, and for the same reason.

`addText` decides the birth state from the gesture, which `finishCreate` already
distinguishes:

- **click** (`worldRect` came from `defaultTextWorldWidth`) → `textAutoWidth = true`,
  and the width is measured from the default string rather than taken from the rect;
- **drag** → fixed, at the width the user dragged. They chose it; honour it.

This means `CanvasHostView` must tell the app which gesture happened. Cheapest honest
signal: `finishCreate` reports the click fallback as a **zero-width** world rect (origin
only) and lets `SpaceModel.addText` supply the measured width, deleting
`defaultTextWorldWidth` outright. That removes the magic constant rather than working
around it, and keeps the "how wide is a text box" decision in the one place that can
measure text.

### 3.3 Live growth — the renderer

Three changes, in dependency order.

**(a) The flag crosses the seam on `TextStyle`.** The editor measures through
`CanvasEngine.textStyle(forTileID:)`, so it needs to know. `TileContent.text(TextStyle)`
is already documented as carrying *"everything the glyphs need"*; hugging is a property
of how the text lays out, so it belongs there:

```swift
/// The box's width is derived from the text rather than given (063). Read by the
/// inline editor to decide whether to measure unconstrained; the DRAW path ignores it,
/// because a committed hugging box has its hugged width stored in `tile.w` already.
public var hugsWidth: Bool = false
```

Note it rides into `TextShaper.ShapeKey` (which stores the whole style) without
affecting shaping — `maxWidth` comes from the caller. Harmless; worth a comment so a
future reader doesn't take it for a shaping input.

**(b) The engine gains a horizontal override beside the vertical one.**
`displayWorldFrame` currently applies `editingWorldHeight` last and height-only, with a
comment explaining that under 062 *"the width stays the user's"*. For a hugging box the
width stops being the user's, so it gets the same treatment — under one guard:

```swift
private var editingWorldHeight: CGFloat?
/// Auto-width only (063): the live minX + width the editor needs. Never set for a
/// fixed box, and never applied while a resize drag owns this tile — a drag is the
/// user taking the width back, and what they see during it must be what they get.
private var editingWorldSpan: (minX: CGFloat, width: CGFloat)?
```

applied in `displayWorldFrame` only when `tile.id != resizeTileID`. Both are cleared by
the `editingTileID` didSet that already clears the height, for the reason already
documented there.

**(c) `CanvasTextEditController.reposition()` branches on the flag.** Today:

```swift
let measured = TextMetrics.size(
    for: style, maxWidth: max(1, frame.width / scale - 2 * TextMetrics.padding))
```

Hugging (and not being resized) instead measures `maxWidth: nil`, derives the width, and
pushes the span. `canvasInlineEditorWorldBox` — whose doc currently says *"The width is
the tile's — the user owns it"* — takes the measured width in that case, and that
sentence is retracted in the same commit.

The `NSTextView` itself needs no mode: its container tracks the view width, and the view
is sized to the measurement, so with the box exactly as wide as the longest line there
is nothing to wrap.

**The risk this section named did not materialise, and is now measured rather than
argued.** The concern was that the measurement is CoreText's and the editor's layout is
TextKit's, and that the two disagree about line breaking — which here would show as the
last word jumping to a second line mid-typing. Two things closed it:

- [067](./067-spaces-text-engine-research.md) measured **0/384** line-break
  disagreements between CoreText, TextKit 1 and TextKit 2. The premise was wrong, not
  merely unlikely.
- `TextAutoWidthTests` pins the specific arithmetic anyway, because engine agreement
  does not by itself guarantee that *measure → +2·padding → re-shape at that width*
  round-trips. `noWrapAtTheHuggedWidth` and `editorAgreesAtTheHuggedWidth` both pass
  across the full matrix, the second including an unbreakable token and CJK.

The 1pt-container-slack fallback was therefore not needed and is **not** in the build.

### 3.4 Conversion — the gesture

`SpaceModel.resizeTile` already anchors on the dragged geometry before deriving. It
gains one rule: **a drag that actually changes the width turns hugging off**, folded
into the same single undo step as the geometry (062 §3.1's "one ⌘Z restores both"). A
`.top` / `.bottom` drag changes no width and leaves the box hugging, which is the
behaviour the handle implies.

Turning it back **on** is the control in §3.5, not a gesture — that is the asymmetry
062 objected to, and it is only acceptable because the state is now visible.

### 3.5 The control — visible in both places text is styled

A segmented picker, mirroring the `Weight` and `Align` pickers it sits beside:

```
Width   [ Auto | Fixed ]
```

- **`SpaceTextFontPopover`** (the format bubble's style popover) — a third row under
  Weight and Align. No new layout math: `fontPopoverWidth` is already sized by the
  four-way weight picker, which is wider than two segments.
- **`ElementInspector.textEditor`** — the same picker. Its current comment says
  *"Sizing is not a setting: the box's width follows its resize handles and its height
  follows the text (062)"*; that becomes half true and must be rewritten, not left.

Selecting **Fixed** freezes the box at its current hugged width. Selecting **Auto**
re-measures unconstrained and re-anchors. Both route through `applyRestyle`, which
already carries derived geometry alongside a style change in one undo step.

### 3.6 A width cap

Figma grows an auto-width box without limit. This app is a moodboard where text
regularly arrives by paste, and a pasted paragraph would produce a box tens of
thousands of world units wide — one line, unreadable at any zoom that fits it.

So: `TextMetrics.maxAutoWidth` (proposed **1200** world units, a wide but readable
column). Past it the box wraps and behaves as a fixed box of that width while staying
flagged auto — so deleting text lets it hug again. This is a deliberate deviation from
Figma; it is a safety valve, not a mode.

### 3.7 What does not change

- **The committed draw path.** A hugging box stores its hugged width in `tile.w`, so the
  engine wraps at a width that produces exactly the lines it measured. The renderer stays
  mode-agnostic, which is 054 §R1's rule.
- **`.frame` labels.** They truncate to the frame's own width; a frame is not text.
- **`MoodboardExport`.** It draws from stored geometry; a hugged width is a stored width.
- **060's zoom invariant.** Layout is still world-space and zoom is still pure
  rasterization; nothing here is measured in screen units.

## 4. Stages

Each stage builds and tests on its own.

**Stage 1 — the persisted bit.** `refactor: spaces - text carries an auto-width flag`
`ElementStyle.textAutoWidth` + the `hugsWidth` accessor + a round-trip test. No reader,
no behaviour change. Confirms the legacy `resizeMode` stays inert.

**Stage 2 — sizing.** `feat: spaces - a text box can hug its own text`
`anchoredMinX`, the `autosizedFrame` branch, `addText` deciding the birth state,
`finishCreate` reporting a click as an origin-only rect, `defaultTextWorldWidth` deleted.
After this a click-placed box is born hugging and re-hugs on every style edit — it just
does not yet grow *while* you type.

**Stage 3 — live growth.** `feat: canvas - an auto-width box grows as you type`
`TextStyle.hugsWidth`, `editingWorldSpan`, the `reposition()` branch, the retraction in
`canvasInlineEditorWorldBox`'s doc. This is the stage with the CoreText/TextKit risk.

**Stage 4 — conversion.** `fix: spaces - resizing a hugging box makes it fixed`
The `resizeTile` rule, in one undo step.

**Stage 5 — the control.** `feat: spaces - a width control for text boxes`
The picker in both hosts; the two stale comments rewritten.

**Stage 6 — docs.** This file marked done, `.change-log/273-text-auto-width.md`, and an
amendment block on 062 recording that its §2 decision was reversed and on what grounds
— 062 should not be left reading as current.

## 5. Tests

Per stage, and these are the ones that would catch a real regression:

- **`ElementStyleTextTests`** — `textAutoWidth` round-trips; absent → `false`; a row
  carrying a legacy `resizeMode: "autoWidth"` still reads as **not** hugging.
- **`SpaceTextResizeTests`** (new cases) — `anchoredMinX` for all three alignments,
  including a *shrink*; `autosizedFrame` returns `nil` when a hugging box's derived
  frame already matches; a fixed box is untouched; a `.top` drag keeps hugging while a
  `.left` drag clears it; both halves land in one undo entry.
- **`SpaceInlineEditTests` / model** — a click-created box is born hugging with a
  measured width; a drag-created one is fixed at the dragged width.
- **`HostEditingTests`** — the editor pushes a span only when hugging; a live resize
  drag suppresses it; ending an edit clears both overrides.
- **The one that matters most — no wrap on commit.** For a matrix of strings (short
  label, a string with an explicit newline, CJK, a long unbreakable token) × sizes ×
  weights, measure unconstrained, store `measured + 2·padding` as the width, then
  re-shape *constrained* to that width and require **the same line count**. This is the
  CoreText-vs-itself half of §3.3's risk and it is cheap to pin.
- **A headless `NSTextView` parity check** for the TextKit half: configured as the
  editor configures it and given the hugged width, it must report the same line count.
  If this one fails, §3.3's slack fallback applies.
- **`CanvasBenchmark`** unchanged and still green — auto-width adds an unconstrained
  measure per keystroke, which is one `TextShaper` cache lookup after the first.

## 6. Manual verification

1. Click the text tool on empty canvas → the box is born snug around "Text", not 260 wide.
2. Type a long line → it grows rightwards, never wraps, and the format bubble tracks it.
3. Delete back down → it shrinks again.
4. Set alignment to centre, type → it grows both ways. Set right → it grows leftwards.
5. Drag a side handle → it becomes fixed and wraps at the width you dropped; the bubble's
   Width picker now reads **Fixed**. ⌘Z restores both the width and the hugging state.
6. Set it back to **Auto** in the picker → it re-hugs.
7. Drag the top handle on a hugging box → still hugging.
8. Paste a paragraph → it stops growing at the cap and wraps.
9. Reopen the board → every box is exactly as wide as it was left.
10. Zoom to 0.3× and 3× mid-edit → no line break moves (060's invariant, unaffected).

## 7. Risks

| risk | severity | handling |
| --- | --- | --- |
| CoreText measures narrower than TextKit lays out → last word wraps mid-typing | high if it bites, unlikely | §5's two parity tests; fallback is 1pt container slack |
| Reversing a documented decision (062 §2) | medium | §2 states the grounds; 062 gets an amendment block rather than being left stale |
| x moving per keystroke under centre/right alignment feels jittery | medium | `anchoredMinX` is exact, not rounded; verify by hand at step 4 |
| A hugging box's width changing on load (`refitTextRows`) surprises the user | low | same in-memory-only treatment 062 gave heights; no write, no undo entry |
| Two controls writing one state drift apart | low | both build an `ElementStyle` and route through `applyRestyle`; the existing pattern |

## 8. Key files

- `AtelierCore/Sources/AtelierCore/Domain/SpaceItem.swift` — `textAutoWidth`, `hugsWidth`
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `anchoredMinX`, `autosizedFrame`,
  `addText`, `resizeTile`, `refitTextRows`
- `AtelierRefs/AtelierRefs/ElementRendering.swift` — carry the flag into `TextStyle`
- `AtelierRefs/AtelierRefs/SpaceFormatChrome.swift` — the Width picker
- `AtelierRefs/AtelierRefs/ElementInspector.swift` — the Width picker; the stale comment
- `CanvasRenderer/Sources/CanvasRenderer/TileContent.swift` — `TextStyle.hugsWidth`
- `CanvasRenderer/Sources/CanvasRenderer/TextMetrics.swift` — `maxAutoWidth`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` — `editingWorldSpan`,
  `displayWorldFrame`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasTextEditController.swift` —
  `reposition()`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasTextEdit.swift` —
  `canvasInlineEditorWorldBox`
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasHostView.swift` — `finishCreate`,
  `defaultTextWorldWidth` (deleted)

## 9. Reference

- `.docs/062-spaces-text-resize-design.md` §1–§3 — the decision being reversed, and the
  derived-height invariant being kept.
- `.docs/060-spaces-text-render-design.md` — world-space layout; unaffected.
- `.docs/054-spaces-text-design.md` §4.1–4.3 — `autosizedFrame`, restyle-folds-autosize.
- `ref/Nook/Components/Easel/InfiniteCanvasView.swift:1408-1443` — auto-grow + debounced
  persist. Nook grows height only, so it is prior art for the loop, not for the mode.


## 10. What the build changed about this plan

Three departures, all in the same direction — one copy of each rule instead of two.

**`anchoredMinX` and the capped measure live in the RENDERER, not `SpaceModel`.** The
plan put both in the app layer. That could not survive Stage 3: the inline editor is
inside `CanvasRenderer` and needs both to derive the live box, so the app-layer versions
would have had renderer twins. Two answers to *"how wide is this box"* and *"where does
its left edge go"* is precisely the drift 060 exists to prevent, so they became
`TextMetrics.size(for:hugging:outerWidth:)` and
`canvasInlineEditorAnchoredMinX(oldMinX:oldWidth:newWidth:alignment:)`, and `SpaceModel`
calls them.

**The editor anchors on `storedWorldFrame`, a new engine accessor.** Not in the plan, and
load-bearing. `reposition()` runs per keystroke, and `screenFrame(forTileID:)` already
includes the editor's own span override — so anchoring against it would mean anchoring
against the previous keystroke's answer, compounding into a sideways crawl for a centred
box. Anchoring against the committed frame is idempotent, which is what makes the live
box and the committed box land in the same place.

**Conversion routes through `applyRestyle`, not `applyPlacementEdit`.** §3.4 said the
rule folds into "the same single undo step as the geometry", but a conversion changes
the *style* as well, and the placement path carries no style. Registering a second
reversible next to it would have meant two ⌘Zs to undo one drag, with a half-converted
box in between. `applyRestyle` already folds style + geometry into one entry, so the
converting branch uses it and the non-converting one is untouched.

Also worth recording: **`defaultTextWorldHeight` went with `defaultTextWorldWidth`.** The
plan only named the width, but once a click reports an origin-only rect the height
literal has nothing to size either — the height was always derived.

## 11. Verified

- 851 app tests, 390 renderer tests, 553 core tests. New: `SpaceTextAutoWidthTests` (19),
  `TextAutoWidthTests` (9), `ElementStyleTextTests` +4, `EngineResizeTests` +7.
- The risk table's top row — the CoreText/TextKit wrap disagreement, rated *"high if it
  bites"* — is measured closed (§3.3).
- §6's manual checklist is **not** yet run; it is the remaining verification.
