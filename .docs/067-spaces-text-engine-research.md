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
- **Nook is not evidence for the port either.** It measures with TextKit 1, draws with
  `NSString.draw`, and edits in an `NSTextView` it never downgrades — i.e. it ships the
  mixed configuration its own comment claims to have unified. Note also that
  `NSStringDrawing` disagrees with TextKit 1 on height in 114/384 cases here, so Nook's
  measure path and draw path are not the single engine that comment describes.

## 4. If the re-wrap still reproduces

It was reported before Stage 3 landed, and Stage 3 both unified font construction and
zeroed `lineFragmentPadding` — either of which could have been the actual cause. **Check
by hand first**: a box whose text wraps onto 3+ lines, double-clicked, should not move a
single break.

If it still moves, this suite has ruled out: the engines, the TextKit version, font
construction, and the wrap-width arithmetic. What remains unexamined is the live path
around them — the world-width the editor is handed at fractional zoom, the paragraph
style `textView.alignment` writes versus the shaper's alignment-free one, and the
`ShapeKey` 1/16pt width quantization. Those are all small, local investigations, and
none of them is a port.

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
