# 055 — Spaces Text (Phase 2): Implementation Plan

> The build plan for [053](./053-spaces-text-overview.md) / [054](./054-spaces-text-design.md).
> Order: **2A → 2C → 2B**. Each step is independently buildable + testable and
> lands as its own commit; nothing here changes the DB schema.
>
> **Revised 2026-07-26** after the full review — deltas marked *(Rn)*.

## Step 1 — Model vocabulary + typed accessors (2A/2C foundation)

**Files:** `AtelierCore/.../Domain/SpaceItem.swift`.

- Add `fontFamily` / `fontWeight` / `textAlign` / `resizeMode` (`String?`) to
  `ElementStyle`; add `TextWeight` / `TextAlign` / `TextResize` enums.
- Add the **typed accessors** `weight` / `align` / `resize` — one owned default
  per field *(R7)*. No `CodingKeys`, no migration (D1).

**Tests** (`AtelierCoreTests`): round-trip with all fields set; **legacy JSON
(no new keys) decodes with the four `nil`** and the accessors return
regular/left/fixed; **unknown/malformed token → default** via the accessor;
`jsonString()`/`init?(jsonString:)` stability.

## Step 2 — Renderer seam + memoized font source (2A)

**Files:** `CanvasRenderer/.../TileContent.swift`, new
`CanvasRenderer/.../TextMetrics.swift`, `CanvasRenderer/.../Host/CanvasEngine.swift`.

- Extend `TextStyle` with `fontFamily`/`weight`/`alignment` (defaulted init).
- Add `FontWeight`/`TextAlignment` (rawValues match `AtelierCore` tokens).
- `CanvasFont.resolve(family:weight:)` → `CTFont`, **memoized by (family,weight)**
  *(R13)*, system fallback (never nil).
- `setTextOverlay`: set `text.font` (cached) + `text.alignmentMode`; `fontSize`
  stays per-frame.

**Tests** (`CanvasRendererTests`) *(R10)*: `CanvasFont` — nil family → system at
weight; known family resolves; unknown → system (never nil); assert the
**resolved font's family/weight/pointSize**, not pixels. Overlay: alignment/font
applied.

## Step 3 — Bridge + inspector controls + conformance guard (2A)

**Files:** `AtelierRefs/.../ElementRendering.swift`,
`AtelierRefs/.../ElementInspector.swift`, `AtelierRefsTests/…`.

- `tileContent` passes the new fields via the typed accessors (`rawValue` hop).
- Inspector `.text` editor: **drop the string `TextField`** *(R3)*; add family /
  weight / alignment / resize-mode pickers. `.frame` editor keeps its label field.
  `builtStyle()` writes the tokens.

**Tests** (`AtelierRefsTests`): **enum conformance** — every `AtelierCore`
weight/align token maps to a `CanvasRenderer` token, both directions *(R5)*;
`tileContent` maps each weight/alignment (incl. unknown-token→default). Inspector
body stays compile-only.

**→ Commit A: `feat: spaces - rich text font family/weight/alignment (2A)`**

## Step 4 — Measurement helper (2C core)

**Files:** `CanvasRenderer/.../TextMetrics.swift`.

- `TextMetrics.size(for: TextStyle, maxWidth: CGFloat?) -> CGSize` — **mode-
  agnostic** *(R1)*: nil = unconstrained, value = width-constrained; uses
  `CanvasFont.resolve` (same font as drawing). Define `TextMetrics.padding`.

**Tests** (`CanvasRendererTests`) *(R10)*: `maxWidth: nil` grows with longer
strings + larger `fontSize` (monotonic); constrained grows with line count; empty
→ ~one line-height; padding not part of `size` (caller adds it) — assert
**bounded + monotonic**, no brittle exact pins.

## Step 5 — Auto-size write path + atomic commit (2C)

**Files:** `AtelierRefs/.../SpaceModel.swift`, `AtelierCore/.../AppServices…`,
`AtelierRefs/.../ElementRendering.swift`, `CanvasRenderer/.../Host/CanvasEngine.swift`.

- `SpaceModel.autosizedFrame(item:style:)` maps `TextResize → maxWidth?` (skip
  `fixed`), adds `2·padding`, freezes `x/y/z`, top-left anchor *(R4: create-time
  width for `autoHeight`; no width-drag)*.
- **Combined transaction** *(R6)*: `AppServices.updateSpaceItemStyleAndPlacement`
  writes style + placement in one `db.write {}`; `performRestyle` calls it with an
  optional placement → **one** undo step ("Restyle Text"), **one** `renderRevision`
  bump.
- **Padding reconciliation** *(R12)*: `.text` tiles use world-space padding
  (`×scale` at draw); frame labels keep the screen pad.

**Tests** (`AtelierRefsTests`, real temp `AppServices`, at the `SpaceArrangeTests`
bar *(R9)*): `autoWidth` text change updates `w`, freezes `x/y/z`; **anchor
invariance across grow AND shrink**; **shrink-back** reduces `h` on `autoHeight`;
"exactly one undo step" via next-undo-name; ⌘Z reverts **both** text and size;
`fixed→autoWidth` re-fits; `autoWidth→fixed` freezes; a `.fixed` restyle writes
**no** geometry and does **not** bump `renderRevision`.
**Renderer** (`CanvasRendererTests`) *(R12)*: drawn text inset ==
`TextMetrics.padding × scale` at zoom ∈ {0.5, 1, 2, 4}; frame-label byte-identical.

**→ Commit B: `feat: spaces - text resize-mode auto-width/height (2C)`**

## Step 6 — Boundary seam for the editor (2B infra)

**Files:** `CanvasRenderer/.../Host/CanvasEngine.swift`,
`CanvasRenderer/.../Host/CanvasHostView.swift`, `CanvasRenderer/.../Host/CanvasView.swift`.

- **Engine-sourced** `onTransformChanged` *(R2)*: emit inside `pan`/`zoom`/
  `setTransform`; host forwards it.
- `CanvasHostView`: `var transform`, `func screenFrame(forTileID:)`.
- `CanvasView`: forward `onTransformChanged` + an `editingTileID: Int?` input.
  **No `Binding<CGRect?>`** *(R15)*.

**Tests** (`CanvasRendererTests`, headless) *(R11)*: after a known pan,
`screenFrame(forTileID:)` == pre-pan frame **shifted by exactly that delta**; a
zoom scales the frame about the anchor; `onTransformChanged` fires **once per**
`pan`/`zoom`/`setTransform` (spy count), incl. via `frameToContent`.

## Step 7 — Inline editor overlay (2B)

**Files:** `AtelierRefs/.../SpaceView.swift`, new
`AtelierRefs/.../InlineTextEditor.swift` (`NSViewRepresentable` + Coordinator).

- Double-click `.text` → `editingTileID` (frames still open the popover);
  new-text-box create → enter edit immediately.
- **Imperative reposition** *(R15)*: the Coordinator sets `textView.frame` from
  `screenFrame(forTileID:)` on each `onTransformChanged` — off the SwiftUI diff.
- Blank the underlying `CATextLayer` while editing; **editor-only** live re-measure
  per keystroke for auto-modes — **no** `sync()` per keystroke *(R16, R14)*.
- Commit on ⌘↵ / blur → `updateStyle` (one undo step, **one** `sync()`); Esc =
  cancel; tile leaves viewport → commit-and-exit.

**Tests:** the **pure** `inlineEditOutcome` matrix *(R8)* — cancel / persist /
`deleteElement` incl. delete-empty-new-box; the "tile-left-viewport → commit"
predicate; the double-commit guard. Commit→style+autosize+undo is covered
model-side (Step 5). The `NSTextView` first-responder/IME/blur lifecycle is
verified **live** (double-click → type → pan → commit → ⌘Z), recorded in the
changelog.

**→ Commit C: `feat: spaces - inline on-canvas text editing (2B)`**

## Test posture

Every pure unit — token parsing/accessors, enum conformance, `CanvasFont`
resolution, `TextMetrics` sizing, the auto-size write path + atomic undo, the
transform→frame invariant, the `inlineEditOutcome` matrix — is tested (prefer too
many). The only live-only surface is the `NSTextView` overlay's first-responder/
IME/blur lifecycle (Step 7); its *logic* (outcome predicate + commit→style+
autosize+undo) is fully covered headlessly.

## Risk / sequencing notes

- **2A + 2C** land first — additive passthrough, a memoized font source, one pure
  helper, and one combined transaction; no interaction rework.
- **The §4.4 padding reconciliation** is the one non-additive renderer change;
  it's `.text`-only and pinned by the draw≡measure characterization test across
  zoom (Step 5) — the "byte-identical" claim is retained only for frame labels
  *(R12, resolving the earlier Step 2/5 contradiction)*.
- **2B is the risk** — the engine-sourced `onTransformChanged` + imperative
  overlay are new SwiftUI↔AppKit plumbing and the editor lifecycle is live-only.
  It's last so 2A/2C ship value regardless; it can pause after Step 6 (the seam is
  independently useful).
- Do **not** fold these commits with the unrelated in-flight `200-item-detail` /
  B3-export work.

## Changelog

One entry per commit under `.change-log/` (`feat: spaces - …`), files-changed +
verification. Commit B's notes the intentional `.text`-tile pixel change from the
world-padding switch; Commit C's records the live double-click/type/pan/undo pass.
