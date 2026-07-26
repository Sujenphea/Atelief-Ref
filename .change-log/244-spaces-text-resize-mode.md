# 244 — Spaces text: resize-mode auto-width / auto-height (2C)

Slice 2C of the Spaces Text Phase-2 epic (design: `.docs/053–055`, Steps 4–5).
Wires the `TextResize` mode (modelled in 2A) to a pure world-space text
measurement helper: an auto-sized text element's `w`/`h` is now derived from its
glyphs and persisted **atomically with the restyle** as one undo step. Builds on
2A's `CanvasFont.resolve` (same font for measuring and drawing, so the box can
never drift from the glyphs). No schema migration.

## Summary

- **Renderer (CanvasRenderer):** new `TextMetrics.size(for:maxWidth:)` — pure,
  **mode-agnostic** (R1): it never sees the domain `TextResize`. `maxWidth == nil`
  measures unconstrained (one line / autoWidth); a value measures wrapped to that
  width (autoHeight, height grows with line count). Measures with the drawing font
  (`CanvasFont.resolve`) at the world `fontSize`, so it is zoom-independent; empty
  string → ~one line height; results ceiled. New `TextMetrics.padding` (world-space
  inset). `TextMetrics` is `public` so the app layer can measure with the same
  source the renderer draws with.
- **Padding reconciliation (R12):** `setTextOverlay` now insets a `.text` tile by
  the **world-space** pad (`TextMetrics.padding × scale`) so the drawn inset equals
  the world inset the app measured against at **every** zoom (draw ≡ measure).
  Frame **labels** keep the legacy screen-space pad (`min(6, width·0.04)`).
- **Atomic transaction (AtelierCore):** new
  `AppServices.updateSpaceItemStyleAndPlacement(itemID:style:placement:)` writes
  style + (optional) geometry in ONE `db.write {}` — style and derived size can
  never half-persist. `placement == nil` writes style only (the common `.fixed`
  path adds zero geometry writes).
- **App (AtelierRefs):** `SpaceModel.autosizedFrame(item:style:)` maps
  `TextResize → maxWidth?` (skips `fixed`), adds `2·padding`, freezes `x`/`y`/`z`
  (top-left anchor; `autoHeight` also freezes `w` at the create-time width — no
  resize handles in Phase 2, D7). `updateStyle` builds the style, computes the
  auto-frame, and calls the combined service through the reworked `performRestyle`
  → **one** undo step (`"Restyle Text"` for text, `"Restyle"` for frames), **one**
  `renderRevision` bump when geometry changes (none on a style-only / `.fixed`
  restyle). One ⌘Z reverts both text and size. `ElementRendering.textStyle(for:)`
  extracted (DRY) as the single `ElementStyle → TextStyle` bridge, reused by both
  the draw path and the auto-size measurement.

## Files changed

- `CanvasRenderer/Sources/CanvasRenderer/TextMetrics.swift` — new public
  `TextMetrics` enum (`size(for:maxWidth:)` + `padding`).
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `setTextOverlay` gains `worldPadded`; `.text` tiles use the world pad.
- `AtelierCore/Sources/AtelierCore/Services/AppServices.swift` — combined
  `updateSpaceItemStyleAndPlacement`.
- `AtelierRefs/AtelierRefs/SpaceModel.swift` — `autosizedFrame`, reworked
  `performRestyle` (optional placement) + `updateStyle` (auto-size + one undo).
- `AtelierRefs/AtelierRefs/ElementRendering.swift` — extracted `textStyle(for:)`,
  reused by `tileContent`.
- Tests: `CanvasRendererTests/TextMetricsTests.swift` (new),
  `CanvasRendererTests/EngineVectorTests.swift` (padding reconciliation),
  `AtelierCoreTests/ServicesSpaceStylePlacementTests.swift` (new),
  `AtelierRefsTests/SpaceTextResizeTests.swift` (new).

## Migration / behavioural notes

- **Intentional pixel change (R12):** `.text` tiles now inset by a fixed
  **world-space** pad (`4 × scale`) instead of the old screen-space
  `min(6, width·0.04)`. This changes text-tile inset pixels at zoom ≠ the old
  crossover — the deliberate cost of making draw inset ≡ measure inset across zoom.
  Frame labels are byte-identical (they keep the screen pad).
- Default resize-mode stays `.fixed` (legacy rows and new elements render exactly
  as before until a mode is chosen); auto-size never fires for `.fixed`.

## Verification

- `swift test` in `CanvasRenderer` — **163 tests passed** (incl. new
  `TextMetricsTests`; padding-reconciliation across zoom {0.5,1,2,4}; frame-label
  byte-identical).
- `swift test` in `AtelierCore` — **543 tests passed** (incl. new
  `ServicesSpaceStylePlacementTests`: atomic style+geometry, nil = style-only,
  unknown id → notFound).
- `xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'
  -only-testing:AtelierRefsTests` — **TEST SUCCEEDED** (incl. new
  `SpaceTextResizeTests`: autoWidth updates `w`/freezes `x`/`y`/`z`, anchor
  invariance across grow AND shrink, autoHeight shrink-back, one undo step reverts
  text + size, fixed↔auto transitions, `.fixed` writes no geometry / no
  renderRevision bump).
