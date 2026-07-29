# 067 — Text engine characterization: Stage 4's premise does not hold

> The prerequisite measurement for "unify the text engine on TextKit". It was supposed
> to decide *how* to port. It decided **not to**.

## 1. What Stage 4 claimed

The plan's diagnosis was that the board runs two text layout engines that disagree:

> Committed text is laid out and drawn with **CoreText** … The inline editor's glyphs
> are laid out by **TextKit** (`NSTextView`) … TextKit and CoreText break lines
> differently. Hence line breaks change on entering edit and revert on commit.

and that this was unfixable without switching engines, because TextKit applies a
paragraph-level line-break strategy *"that CoreText has no equivalent for and no API to
disable"*. The remedy was to replace the CoreText shaping/drawing path for `.text` tiles
**and** `.frame` labels — a rewrite of the text layer, with 060's measured frame budget
declared void and needing re-measurement.

The plan also, correctly, refused to start without measuring first:

> **This is the biggest correctness risk in the stage and must be resolved before, not
> during, the port.**

## 2. What the measurement says

`TextEngineParityTests`, 384 cases — 8 strings (ordinary wrapping, an unbreakable token,
CJK, mixed script, an explicit newline, hyphen-joined words, widow bait) × 4 widths ×
3 sizes × 2 weights × 2 families:

```
cases: 384   actually compared: 384   of which multi-line in all 3: 305

CoreText  vs TextKit 1  — line breaks differ in 0/384
CoreText  vs TextKit 2  — line breaks differ in 0/384
TextKit 1 vs TextKit 2  — line breaks differ in 0/384
NSStringDrawing vs TK1  — heights differ (>0.5pt) in 114/384
```

**Zero line-break disagreements between the engines**, and separately:

- an `NSTextView` configured the way `CanvasTextEditController` configures its own is
  **TextKit 2** on this OS — so the TK1-vs-TK2 trapdoor the plan feared is real, and
  irrelevant, because all three agree anyway;
- **the editor and the renderer agree at the live tile geometry**, including the
  padding-as-container-inset arithmetic (`frame.width = tile.w` with
  `textContainerInset = padding` lands on the same wrap width as shaping at
  `tile.w − 2·padding`);
- **divergence #2 is already closed.** The shaper and the editor build the *same*
  `CTFont` — same PostScript name, same size — because Stage 3 pointed both at
  `CanvasFont`. The plan listed this as an open problem; it was fixed in passing.

The `compared == total` and "305 of 384 actually wrapped" assertions exist because
without them this suite could report perfect agreement by comparing nothing: a skipped
case and two empty line arrays both read as equality.

## 3. Conclusion — do not do Stage 4

The stated cause does not reproduce. There is no engine disagreement to fix, so a
rewrite of the text layer would be large, risky, performance-regressing work aimed at a
mechanism that is not there.

Two consequences for the record:

- **060 §6 was closer to right than the Stage 4 plan was.** The plan asserted that
  060's "rare difference, already contained" reasoning *"is wrong and must be
  retracted"*. On this evidence the difference is not merely rare, it is absent across
  the matrix, and it is the retraction that should be withdrawn.
- **Nook is not evidence for the port either — but not for the reason first written
  here.** An earlier draft of this section said Nook "ships the mixed configuration its
  own comment claims to have unified". That was wrong: Nook deliberately excludes text
  from its Core Text tile path (`InfiniteCanvasView.swift:2422`) and draws it in a
  screen-space overlay instead.

  What Nook's comment — *"the tile's Core Text path can't be made to agree"* — is
  actually comparing is not two engines. Its tile path lays out at **tile scale**
  (`max(8 / pts, 14)`, font size varying with the rasterization scale); its overlay lays
  out at a fixed reference size and applies zoom as a geometric transform. That is the
  fused layout/rasterization bug 060 §2 describes, not an engine difference. Nook
  changed engine *and* removed the zoom-baking in one move and credited the engine. We
  removed the zoom-baking and kept Core Text — and the matrix above says the engine half
  was never carrying weight.

  Copying Nook's engine choice would also be a downgrade. It measures with
  `NSLayoutManager` and draws with `NSString.draw`, and that pair is the **only**
  combination measured here that disagrees — 114/384 on height. `TextShaper` both
  measures and draws, so our measurement and rendering cannot drift by construction.

## 4. The re-wrap does not reproduce — verified by hand

**Confirmed fixed.** The symptom was reported *before* Stage 3, which both unified font
construction and zeroed `lineFragmentPadding`; a wrapped box double-clicked today does
not move a break. So Stage 4 would have been a rewrite of the text layer aimed at a bug
that was already gone, diagnosed to a mechanism that was never there.

One asymmetry remains open, and it is ours rather than anything to do with Nook: the
shaper keeps its paragraph style **alignment-free on purpose**
(`TextShaper.swift:154`) and applies alignment as a per-line flush offset, while the
editor sets `textView.alignment`, which installs an aligned paragraph style. Alignment
does not affect word wrapping in either engine, so this is not the fixed symptom coming
back — but it is a real difference between the two configurations and worth closing if
anything in this area is ever reported again. Nook sidesteps it by stripping
`.paragraphStyle` from the editor's storage entirely (`InfiniteCanvasView.swift:1375`).

## 4a. Where we already match Nook

Worth recording, because it is the part that turned out to matter. The editor's
zoom handling is the same design in both codebases — a screen-space frame over a
world-space bounds, so the text view lays out in world units at scale 1 and the zoom is
pure rasterization:

| | Atelier | Nook |
| --- | --- | --- |
| editor container | `CanvasTextEditController.swift:227-232` | `InfiniteCanvasView.swift:1382-1384` |
| `lineFragmentPadding` | 0 | 0 |
| layout point size | world size, zoom-independent | world size, zoom-independent |
| renderer | `drawScale` only; zoom excluded from `ShapeKey` | reference-size raster, geometric scale |

The engine is the one thing that differs, and §3 covers why it should stay that way.

## 5. What to keep

The suite stays, and two of its cases are real regression guards rather than
documentation:

- **editor-vs-renderer at the same geometry** fails if anyone changes the padding/inset
  arithmetic on either side so the two wrap differently — the exact class of bug this
  investigation was chasing;
- **font construction agrees** fails if the editor ever again builds its own font
  instead of going through `CanvasFont`, reopening divergence #2.

The characterization test itself asserts only its own validity, deliberately: it exists
to report platform behaviour, and failing the build on a platform disagreement would be
reporting it in the one form that stops the work.

## 6. Files

- new: `CanvasRenderer/Tests/CanvasRendererTests/TextEngineParityTests.swift`
