# 053 — Spaces Text (Phase 2): Rich Style, Inline Editing & Resize-Mode

> Direction (user): Phase 2 of the Figma-grade Spaces epic ([050](./050-spaces-figma-overview.md)).
> "Variable text" = **rich text controls**, not variable-font axes. Scope was
> pinned with the user (2026-07-26) by confirming each recommendation:
>
> - **Design all of Phase 2 up front** — one overview → design → plan before code.
> - **2A native rich style** (fontFamily / fontWeight / textAlign) — **in**.
> - **2B inline on-canvas editing** — **in** (the fiddliest UI work in the epic).
> - **Resize-mode** (auto-width / auto-height / fixed) — **in**.
> - **Letter-spacing / line-height** — **out** for now.
>
> That last exclusion is load-bearing: it's the only pair of the six targets with
> **no `CATextLayer` property**, so leaving it out means the native text render
> path **stays** and we avoid the throwaway `NSAttributedString`/`CTFont` rewrite
> ("2C"). Resize-mode still needs text **measurement**, but measurement is a pure
> add-on, not a render-path swap.

This overview is the synthesis + decisions. The spec is [054](./054-spaces-text-design.md);
the implementation plan is [055](./055-spaces-text-plan.md).

## Current state (verified)

Reconnaissance across the model, renderer, and editing/coordinate seams:

- **Model** — `ElementStyle` (`AtelierCore/.../Domain/SpaceItem.swift:29–73`) is an
  all-optional `Codable` serialized to the opaque `space_item.style` TEXT column
  (`Migrator.swift:403`). It carries `text` / `fontSize` / `textColor` /
  `fillColor` / `strokeColor` / `strokeWidth` only. **No** fontFamily, weight,
  alignment, resizeMode. Because every field is optional, there are no custom
  `CodingKeys`, and `JSONDecoder` drops unknown keys, **adding fields needs zero
  schema migration** — old rows decode with the new fields `nil`.
- **Renderer** — text is one `CATextLayer` per tile held OUTSIDE the recycled
  `LayerPool`, keyed by tile id (`CanvasEngine.swift:41`), written by
  `setTextOverlay` (`:447–472`). It sets `string`, `fontSize` (world × zoom),
  `foregroundColor`; `isWrapped`/`truncationMode`/`alignmentMode` are **hardcoded**
  (`.left`), and **no font family is ever set** (renders default Helvetica). The
  seam struct `TextStyle` (`TileContent.swift:76–86`) is a 3-field value
  (`string`/`fontSize`/`color`). `ElementRendering.tileContent` (`ElementRendering.swift:43–69`)
  bridges `ElementStyle → TextStyle`.
- **Coordinate math is built and centralized** — `CanvasTransform`
  (`CanvasTransform.swift`) is the single source of truth for world↔screen
  (`worldToScreen(CGRect)`, `screenToWorld`), and
  `CanvasEngine.currentScreenFrame(forTileID:)` (`CanvasEngine.swift:117–120`)
  already yields a tile's exact on-screen rect. **But neither is reachable from
  the SwiftUI/`SpaceView` layer, and pan/zoom mutate the transform with no
  outward notification.** Pan/zoom enter at `CanvasHostView.scrollWheel`
  (`:198`), `magnify` (`:202`), `performAutoPan` (`:504`), and `layout` (`:177`).
- **Editing is popover-only, deliberately** — `ElementInspector.swift:5–9`
  documents choosing the popover *specifically to avoid* overlay↔canvas
  coordinate mapping under pan/zoom. Double-click a text/frame element opens it
  (`SpaceView.swift:186–188`). It commits a local `ElementStyle` copy on Done /
  on click-outside (`ElementInspector.swift:82–86`).
- **No text measurement exists anywhere** — the tile rect is authoritative; text
  never drives size. Resize-mode is a genuinely new (small) subsystem.

The foundation (selection, batched writes, undo ping-pong, the transform) is
solid. Phase 2 adds **model fields**, **renderer style passthrough**, **one pure
measurement helper**, and **the SwiftUI-boundary seam** for an inline editor.

## The three slices

| Slice | What | Risk | Depends on |
|---|---|---|---|
| **2A — Native rich style** | `fontFamily` / `fontWeight` / `textAlign` through `ElementStyle → TextStyle → CATextLayer` + inspector controls | Low | — |
| **2B — Inline editing** | double-click → `NSTextView` overlay; expose `transform` + `currentScreenFrame` + a pan/zoom callback at the SwiftUI boundary | Med–High | — (parallel to 2A) |
| **2C — Resize-mode** | `resizeMode` field + a pure world-space text-measurement helper; auto-size writes `w/h` back as one undoable edit | Medium | 2A (measures with the same font) |

Design all three now; **2A → 2C → 2B** is the natural build order (2A gives the
font model 2C measures against; 2B is orthogonal and lands last as it's the
riskiest). Full sequencing in [055](./055-spaces-text-plan.md).

> **Reviewed 2026-07-26** (architecture / code-quality / test / performance, 16
> issues, all resolved). The decisions below and the spec/plan reflect that pass;
> notable revisions: the measurement helper is **mode-agnostic** in the renderer
> (D4), auto-resize commits as **one atomic transaction** (D5), resize **handles
> are deferred** (D7), and the inline editor repositions **imperatively** (D6).

## Settled decisions

- **D1 — No migration.** New `ElementStyle` fields are optional; old rows decode
  with `nil` and read as today's defaults (left-aligned, system font, `fixed`
  resize). Round-trip is the only model test needed.
- **D2 — Keep the native `CATextLayer` render path.** Family/weight/alignment are
  native `CATextLayer` properties; setting `text.font` (a `CTFont` built from
  family + weight) + `alignmentMode` covers 2A with no attributed-string rewrite.
  Justified only because letter-spacing/line-height are out (D-excluded).
  > **Reopened 2026-07-27 by [059](./059-spaces-text-render-overview.md).** Overflow
  > text reflows on zoom because `CATextLayer` re-lays-out per `fontSize`; the render
  > path moves to a CoreText shape-once / draw-scaled layer (design
  > [060](./060-spaces-text-render-design.md), plan [061](./061-spaces-text-render-plan.md)).
  > D2's measurement-only shaping (D4) is unchanged and is now the same call that draws.
- **D3 — Split typing from styling (single writer per string).** Inline editing
  (2B) edits the **string** on canvas; the inspector popover keeps the **style**
  controls (family / weight / align / size / colour / resize-mode). Double-click
  text → inline edit; the single-select bar's Edit button → style popover.
  (Figma-shaped: type in place, style in the panel.) The popover's string
  `TextField` is **dropped for the `.text` kind** so the string has exactly one
  writer, but **kept for frame labels** (frames have no inline path). 050's
  "replacing popover-only editing" is refined: inline replaces popover *for the
  text string*, not for style.
- **D4 — One measurement source of truth; mode-agnostic in the renderer.** Font
  construction + text metrics live in ONE pure helper in `CanvasRenderer` (mirrors
  the `CanvasTransform` "single source" rule): both `setTextOverlay` (drawing) and
  `SpaceModel` (auto-size) build the font the same way, so measured size can never
  drift from drawn size. The helper takes `maxWidth: CGFloat?` (nil = autoWidth, a
  value = autoHeight) — **it does not know about `TextResize`**, so no domain type
  crosses into the renderer; the app maps the mode. Resolved fonts are **memoized
  by `(family, weight)`** so the per-frame `sync()` path stays allocation-free.
- **D5 — Auto-size is a geometry edit, committed atomically with the restyle.**
  When a style/text change alters an auto-sized element's fit, the style write and
  the new `w/h` write are one **GRDB transaction** and **one undo step** — style
  and derived size can never half-persist; one ⌘Z reverts both text and size.
- **D6 — Inline editor lives in the app layer, repositioned imperatively.** The
  `NSTextView` overlay is a `SpaceView` concern; its `NSViewRepresentable`
  coordinator sets its own frame directly from the newly-exposed
  `screenFrame(forTileID:)` on each `onTransformChanged` — **off** the SwiftUI
  diff path (no per-frame body re-eval). `onTransformChanged` originates at
  `CanvasEngine`'s transform mutations (pan/zoom/setTransform), not the host's
  gesture handlers, so future transform sources (zoom-to-fit, nudge) are covered
  for free. Trade-off vs. hosting the editor inside the engine is in
  [054](./054-spaces-text-design.md).
- **D7 — Resize handles deferred to Phase 3.** The canvas has no tile-resize
  affordance today; adding one is a whole gesture/hit-test subsystem. Phase 2
  ships auto-fit on the **create-time width**: `autoWidth` is fully text-driven,
  `autoHeight` grows down from the width you drew, `fixed` is as-drawn.
  Width-adjust (resize handles) lands in the Phase-3 usability set (050).

## Excluded (and why)

- **Letter-spacing, line-height** — no `CATextLayer` property; would force the
  attributed-text render rewrite. User deferred. If ever wanted, D2 is the seam
  to revisit (the render path becomes `NSAttributedString`, measurement in D4
  already uses it, so 2C's helper is forward-compatible).
- **Variable-font axes / design tokens** — user confirmed "variable text" means
  rich controls, not axes (050 open-Q 1).

## Resolved product questions (2026-07-26)

1. **Font picker scope** → the **full system list** (`NSFontManager.availableFontFamilies`),
   "System" = the nil default. (Revisit with a curated shortlist only if unwieldy.)
2. **Weight granularity** → the **4-token set** {regular, medium, semibold, bold}
   (not the 100–900 scale). See D-Weight.
3. **Default resize-mode on creation** → always **`fixed`** until changed
   (back-compat parity; users opt into auto modes explicitly).
