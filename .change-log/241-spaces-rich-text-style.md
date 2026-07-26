# 241 — Spaces rich text: font family / weight / alignment (2A)

Slice 2A of the Spaces Text Phase-2 epic (design: `.docs/053–055`). Adds native
rich-text style — font family, weight, and alignment — through the whole stack:
`ElementStyle` → `TextStyle` → `CATextLayer`, plus inspector controls. Keeps the
native `CATextLayer` render path (D2); no schema migration (D1). Resize-mode
(`TextResize`) is modelled here but not yet wired to measurement (that lands in
2C, Steps 4–5).

## Summary

- **Model (AtelierCore):** `ElementStyle` gains four optional `String?` tokens —
  `fontFamily` / `fontWeight` / `textAlign` / `resizeMode` — plus the enums
  `TextWeight {regular,medium,semibold,bold}`, `TextAlign {left,center,right}`,
  `TextResize {fixed,autoWidth,autoHeight}`. One-owned-default typed accessors
  `weight` / `align` / `resize` (unknown/nil → regular/left/fixed). No
  `CodingKeys`, no migration — legacy rows decode with the four fields nil.
- **Renderer (CanvasRenderer):** `TextStyle` gains `fontFamily` / `weight` /
  `alignment` (defaulted init, so existing call sites compile unchanged), mirrored
  by `FontWeight` / `TextAlignment` whose rawValues match the AtelierCore tokens
  (the bridge is a rawValue hop). New `CanvasFont.resolve(family:weight:)` builds
  a `CTFont`, memoized by `(family, weight)`, system fallback (never nil).
  `setTextOverlay` now sets `text.font` (cached) + `text.alignmentMode`; `fontSize`
  stays per-frame. The renderer does not import AtelierCore — `TextResize` stays
  domain/app-only.
- **App (AtelierRefs):** `ElementRendering.tileContent` passes the new fields via
  the typed accessors (rawValue hop). The `.text` inspector drops its string
  `TextField` (R3 — the string is edited on-canvas in 2B) and adds font-family /
  weight / alignment / resize-mode pickers; the `.frame` inspector keeps its label
  field. `builtStyle()` writes the four tokens for `.text`.

## Files changed

- `AtelierCore/Sources/AtelierCore/Domain/SpaceItem.swift` — new enums, fields,
  accessors.
- `CanvasRenderer/Sources/CanvasRenderer/TileContent.swift` — `FontWeight` /
  `TextAlignment` (CaseIterable, for the conformance guard) + `TextStyle` fields.
- `CanvasRenderer/Sources/CanvasRenderer/TextMetrics.swift` — **new**; memoized
  `CanvasFont.resolve` + weight/alignment mappings.
- `CanvasRenderer/Sources/CanvasRenderer/Host/CanvasEngine.swift` —
  `setTextOverlay` applies font + alignment; `textLayer(forTileID:)` test accessor.
- `AtelierRefs/AtelierRefs/ElementRendering.swift` — `.text` bridge passes the new
  fields.
- `AtelierRefs/AtelierRefs/ElementInspector.swift` — new `.text` style pickers;
  drops the string field; `builtStyle()` writes tokens.
- Tests: `AtelierCoreTests/ElementStyleTextTests.swift`,
  `CanvasRendererTests/CanvasFontTests.swift`,
  `CanvasRendererTests/EngineVectorTests.swift` (overlay font/alignment),
  `AtelierRefsTests/SpaceTextStyleTests.swift`.

## Interpretation notes

- The design spec (§2) declared `FontWeight` / `TextAlignment` without
  `CaseIterable`; the plan's conformance test (§8/R5) requires enumerating **both**
  vocabularies via `allCases`. Added `CaseIterable` to the two renderer enums —
  additive, and it makes the drift guard exact (fails CI if the two token sets
  diverge in either direction).
- `CanvasFont` carries a fixed `referenceSize` (16pt): `CATextLayer` sizes via its
  own `fontSize`, so the typeface's point size is nominal — pinned so the cache key
  stays `(family, weight)` and tests can assert `pointSize`.

## Verification

- `swift test` in `AtelierCore` — **540 tests passed**.
- `swift test` in `CanvasRenderer` — **153 tests passed** (incl. new
  `CanvasFontTests`, overlay font/alignment).
- `xcodebuild test -scheme AtelierRefs -destination 'platform=macOS'
  -only-testing:AtelierRefsTests` — **TEST SUCCEEDED** (incl. new
  `SpaceTextStyleTests`: enum conformance both directions, tileContent weight/
  alignment mapping incl. unknown→default, inspector compile-only).
