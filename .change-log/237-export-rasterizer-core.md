# 237 — Moodboard / PDF rasterizer core (`AtelierExport`)

052 · Track B · **B2**. The pure layout + render engine that turns a selection of
board references into a moodboard PDF or PNG. Core only — no app UI yet (that is
B3); this ships as a standalone, fully-tested SPM package.

## Summary

New **`AtelierExport`** local Swift package (052 · 3A) with **zero product
dependencies** — CoreGraphics / CoreText / ImageIO over a package-local input
model. It never imports AtelierCore (so never pulls GRDB) and never imports
AppKit, which keeps every bit of it headless-unit-testable via `swift test`.

- **Input model** (`MoodboardElement` / `MoodboardContent` / `TextStyle` /
  `FrameStyle` / `RGBA`) — world-space value types the app maps its `SpaceItem`
  geometry + `AssetContent` / `ElementStyle` into. `RGBA` owns the one
  `#rgb`/`#rrggbb`/`#rrggbbaa` hex parser.
- **Layout engine** (`MoodboardLayout` → `[LayoutPage]`) — pure arithmetic, two
  mappings sharing one world→page (y-down → y-up) conversion:
  - `fitToSinglePage(_:maxDimension:)` — whole board scaled onto one page,
    never upscaled past 1:1.
  - `paginate(_:pageSize:scale:)` — fixed scale tiled row-major across
    fixed-size pages; boundary-straddling elements emit on each page they touch,
    clipped to that page's content area.
- **Renderer** (`MoodboardRenderer`) — one draw routine feeds both
  `renderPDF(pages:…)` (multi-page vector container) and `renderPNG(page:…)`
  (raster at `pixelsPerPoint`). Draws every kind (image / colour / text / frame)
  in `z` order. Full fidelity: text + frame elements render from their style via
  CoreText.
  - **Memory (13A):** images pulled one at a time through the
    `MoodboardImageProvider` seam, sized to the element's on-page footprint,
    inside a per-element `autoreleasepool` — peak ≈ one item, not the board.
  - **Errors (7A):** hard failures throw typed `ExportError`; a missing image is
    a soft per-element skip collected in `RenderResult.skipped`.
  - **Threading (15A):** synchronous + cancellable via an `isCancelled` closure
    (`{ Task.isCancelled }`); no global/main-actor state.

The layout output (`LayoutPage`) and the renderer are the **shared engine**: the
moodboard is the first producer of `[LayoutPage]`; the contact sheet (B4) becomes
a second producer feeding the same renderer with no rework.

## Tests (052 · 10A)

29 tests, all passing (`swift test`):

- **Layer 1 (pure, exact values):** `RGBATests` (hex parsing, shorthand
  expansion, clamping, malformed → nil) and `MoodboardLayoutTests` (bounding box,
  fit downscale / no-upscale / y-flip / clip, pagination column tiling,
  off-page exclusion, scale, degenerate rejection) — every expected coordinate
  hand-computed in-comment.
- **Layer 2 (structural):** PDF page count + media-box size via `CGPDFDocument`;
  PNG pixel dimensions.
- **Layer 3 (pixel probe, no committed golden files):** render known content and
  read back pixels — background fill, colour swatch, provider image (plus the
  13A footprint-size assertion). Also: skip-report (missing / no-provider) and
  cancellation.

## Files changed

- `AtelierExport/` — **new package** (`Package.swift`, `Sources/AtelierExport/**`,
  `Tests/AtelierExportTests/**`).
- `.github/workflows/ci.yml` — added `AtelierExport` to the `swift-packages`
  test matrix.

## Migration notes

- No behaviour change to the app: `AtelierExport` is not yet linked into the
  Xcode app target. That wiring (local package reference + product dependency)
  plus the `NSSavePanel` glue, progress/cancel UI, and `ToastCenter` summary land
  in **B3**, when app code first imports the package.
- The app→package mapping (`SpaceItem` + `AssetContent`/`ElementStyle` →
  `MoodboardElement`) and the `MoodboardImageProvider` implementation over
  `ImageDecoding.thumbnailCGImage(from:maxPixelSize:)` (16A) are B3 work.
